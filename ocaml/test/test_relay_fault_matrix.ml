(* test_relay_fault_matrix — F5b + H7 (friction-cn): P0 process/adverse fault
   matrix. Rows A006-A008/A083/A088; B027/B044-B045/B074/B080/B087-B092/
   B094-B101/B110/B113-B114/B119/B122-B129/B173/B185/B187/B189-B197/B211;
   C024/C047/C056 (row-ID tags below are best-effort mappings from the
   reconciliation plan; the matrix ledger itself lives on the
   friction-adr0-decision-ledger branch).

   WHAT THIS PROVES: what the REAL compiled c2c binary does AS A PROCESS
   when the relay misbehaves. Every cell drives `c2c.exe` as a subprocess
   (never in-process calls) against the F5a scripted fault server
   (Relay_test_support) and asserts, per fault:
     - exit code (nonzero on failure),
     - the failure is NAMED on a diagnostic surface (for relay subcommands
       that surface is the stdout JSON result: error_code / error fields —
       stderr carries only fix-it hints on specific auth failures),
     - retry behavior matches what the code claims (the ONLY retry in the
       relay client is the single PoW minted retry in Pow_client
       .post_with_retry; there is NO generic retry/backoff — 429 is
       single-shot, pinned here),
     - NO FALSE SUCCESS: a faulted request never prints ok:true / exits 0.

   KNOWN DEFECTS FOUND BY THIS MATRIX — both FIXED by the H7
   status-honesty slice; the fixed contract is pinned green below:
     1. (was) Relay_client.request IGNORED the HTTP status line: a 5xx
        response whose body said {"ok":true} was treated as SUCCESS.
        Now the status is reconciled with the body: a non-2xx can never
        yield ok:true — an honest ok:false body passes through (annotated
        with http_status), anything else is overridden with
        error_code=http_error_<status>. See
        `http_5xx_ok_body_never_success`.
     2. (was) `c2c doctor --relay` reported relay.reachable = PASS when
        the relay was CONNECTION-REFUSED (Relay_client swallows the
        network error into a synthesized connection_error JSON, and
        check_reachable treated ANY parsed JSON as proof of
        reachability). Now client-synthesized transport errors carry
        transport:true and probe_relay folds them back into the
        health=None unreachable branch, so relay.reachable FAILs and
        relay.lease / relay.capabilities inherit the honest verdict. See
        `doctor_refused_reachable_fails`.

   Hermetic: kernel-assigned loopback ports only, isolated $HOME and broker
   root per test, no production relay, no external network. No
   sleeps-as-sync: scripted [delay_s] responses are the fault under test
   and every wait is bounded by a client-side timeout. *)

(* ------------------------------------------------------------------ *)
(* Helpers                                                             *)
(* ------------------------------------------------------------------ *)

let c2c_bin =
  let dir = Filename.dirname Sys.executable_name in
  let candidate =
    Filename.concat (Filename.concat (Filename.dirname dir) "cli") "c2c.exe"
  in
  if Sys.file_exists candidate then candidate else "c2c"

let contains ~needle hay =
  let nl = String.length needle and hl = String.length hay in
  if nl = 0 then true
  else
    let rec go i =
      if i + nl > hl then false
      else if String.sub hay i nl = needle then true
      else go (i + 1)
    in
    go 0

let mkdtemp () =
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "c2c-f5b-fault-%d-%d" (Unix.getpid ())
         (Random.int 1_000_000))
  in
  Unix.mkdir base 0o700;
  base

let mkdir_p path =
  let rec go p =
    if p = "/" || p = "." || Sys.file_exists p then ()
    else begin
      go (Filename.dirname p);
      (try Unix.mkdir p 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
    end
  in
  go path

(* Isolated env: fresh HOME (no relay config, no identity unless a test
   creates one), isolated broker root. [extra] appends e.g. C2C_RELAY_URL. *)
let run_c2c ?(extra = []) ~tmp args =
  let broker = Filename.concat tmp "broker" in
  mkdir_p broker;
  let out_path =
    Filename.concat tmp (Printf.sprintf "out-%d" (Random.int 1_000_000))
  in
  let err_path = out_path ^ ".err" in
  let env =
    Array.of_list
      ([ "PATH=" ^ (try Sys.getenv "PATH" with Not_found -> "/usr/bin:/bin");
         "HOME=" ^ tmp;
         "C2C_MCP_SESSION_ID=f5bx-fault-matrix-test";
         "C2C_MCP_BROKER_ROOT=" ^ broker;
       ]
       @ extra)
  in
  let out_fd = Unix.openfile out_path [ Unix.O_WRONLY; Unix.O_CREAT ] 0o600 in
  let err_fd = Unix.openfile err_path [ Unix.O_WRONLY; Unix.O_CREAT ] 0o600 in
  let pid =
    Unix.create_process_env c2c_bin
      (Array.of_list (c2c_bin :: args))
      env Unix.stdin out_fd err_fd
  in
  Unix.close out_fd;
  Unix.close err_fd;
  let _, status = Unix.waitpid [] pid in
  let code = match status with Unix.WEXITED c -> c | _ -> -1 in
  let slurp path =
    let ic = open_in_bin path in
    let s = really_input_string ic (in_channel_length ic) in
    close_in ic;
    s
  in
  (code, slurp out_path, slurp err_path)

let member key = function
  | `Assoc fields -> Option.value ~default:`Null (List.assoc_opt key fields)
  | _ -> `Null

let str_member key json =
  match member key json with `String s -> Some s | _ -> None

(* Relay subcommands print exactly one JSON document (the relay result) on
   stdout and exit 0 iff its "ok" field is `true` (print_result_and_exit).
   The honest-failure contract asserted for every faulted cell:
     rc = 1, parsed stdout has ok != true, and error_code/error names the
     failure (contains [needle]). NO FALSE SUCCESS: ok:true absent. *)
let assert_honest_failure ~what ~needle (rc, out, _err) =
  Alcotest.(check int) (what ^ ": exit code 1") 1 rc;
  let json =
    try Yojson.Safe.from_string out
    with _ ->
      Alcotest.fail
        (Printf.sprintf "%s: stdout is not a JSON result: %S" what out)
  in
  (match member "ok" json with
   | `Bool true -> Alcotest.fail (what ^ ": FALSE SUCCESS — ok:true printed")
   | _ -> ());
  let named =
    match (str_member "error_code" json, str_member "error" json) with
    | Some c, _ when contains ~needle c -> true
    | _, Some e when contains ~needle e -> true
    | _ -> false
  in
  Alcotest.(check bool)
    (Printf.sprintf "%s: failure names %S (got: %s)" what needle out)
    true named

let requests_for ~path srv =
  List.filter
    (fun r -> r.Relay_test_support.path = path)
    (Relay_test_support.requests srv)

let json_response ?(status = 200) body =
  Relay_test_support.response ~status (Yojson.Safe.to_string body)

let err_body ~error_code ~error =
  `Assoc
    [ ("ok", `Bool false);
      ("error_code", `String error_code);
      ("error", `String error);
    ]

(* ------------------------------------------------------------------ *)
(* Shared fault fixtures                                               *)
(* ------------------------------------------------------------------ *)

(* Run [cmd_of_url] (a c2c argv builder) against a single scripted route
   and hand the result + server to [k]. *)
let with_fault ~meth ~path responses k =
  Relay_test_support.with_server
    ~routes:[ Relay_test_support.route ~meth ~path responses ]
    (fun srv ->
      k srv (Relay_test_support.url srv))

let register_args ~url = [ "relay"; "register"; "--alias"; "f5bx-reg"; "--relay-url"; url ]
let dm_send_args ~url =
  [ "relay"; "dm"; "send"; "f5bx-dst"; "hello"; "--alias"; "f5bx-src"; "--relay-url"; url ]

(* Status-code faults where the relay still answers well-formed JSON
   {"ok":false,...}: the client's honesty comes from the ok-field contract.
   Since H7 the HTTP status is also reconciled: an honest ok:false body
   keeps its own error_code (asserted here — the needle must stay the
   body's code, NOT http_error_<status>) and gains an http_status
   annotation; a non-2xx body claiming success is overridden (pinned by
   `http_5xx_ok_body_never_success`). *)
let check_status_fault ~what ~args_of_url ~path ~status ~error_code () =
  let tmp = mkdtemp () in
  with_fault ~meth:"POST" ~path
    [ json_response ~status (err_body ~error_code ~error:(error_code ^ " from relay")) ]
    (fun srv url ->
      let ((_, out, _) as res) = run_c2c ~tmp (args_of_url ~url) in
      assert_honest_failure ~what ~needle:error_code res;
      (* H7 annotation half of the contract: an honest ok:false body keeps
         its own error_code (asserted above) and gains an http_status field
         matching the actual status line. *)
      (match member "http_status" (Yojson.Safe.from_string out) with
       | `Int s when s = status -> ()
       | other ->
           Alcotest.fail
             (Printf.sprintf "%s: http_status must be %d, got %s" what status
                (Yojson.Safe.to_string other)));
      Alcotest.(check int) (what ^ ": exactly one request (single-shot, no blind retry)")
        1 (List.length (requests_for ~path srv)))

(* Transport-level faults (truncation, malformed JSON, refused, empty):
   the client maps all of them to error_code=connection_error. *)
let check_transport_fault ~what ~args_of_url ~path response () =
  let tmp = mkdtemp () in
  with_fault ~meth:"POST" ~path [ response ] (fun _srv url ->
      let res = run_c2c ~tmp (args_of_url ~url) in
      assert_honest_failure ~what ~needle:"connection_error" res)

let check_refused ~what ~args_of_url () =
  let tmp = mkdtemp () in
  let url =
    Printf.sprintf "http://127.0.0.1:%d" (Relay_test_support.closed_port ())
  in
  let res = run_c2c ~tmp (args_of_url ~url) in
  assert_honest_failure ~what ~needle:"connection_error" res

(* ------------------------------------------------------------------ *)
(* Matrix: `c2c relay register` × faults                               *)
(* ------------------------------------------------------------------ *)

let reg_401 () =
  check_status_fault ~what:"register vs 401" ~args_of_url:register_args
    ~path:"/register" ~status:401 ~error_code:"unauthorized" ()

let reg_429 () =
  check_status_fault ~what:"register vs 429" ~args_of_url:register_args
    ~path:"/register" ~status:429 ~error_code:"rate_limited" ()

let reg_500 () =
  check_status_fault ~what:"register vs 500" ~args_of_url:register_args
    ~path:"/register" ~status:500 ~error_code:"internal_error" ()

let reg_503_non_json () =
  check_transport_fault ~what:"register vs 503 non-JSON body"
    ~args_of_url:register_args ~path:"/register"
    (Relay_test_support.response ~status:503 ~content_type:"text/html"
       "<html><body>Service Unavailable</body></html>")
    ()

let reg_truncated () =
  check_transport_fault ~what:"register vs truncated JSON"
    ~args_of_url:register_args ~path:"/register"
    (Relay_test_support.response ~truncate_body_at:12
       {|{"ok":true,"lease":{"alias":"f5bx-reg","ttl":300}}|})
    ()

let reg_malformed () =
  check_transport_fault ~what:"register vs malformed JSON"
    ~args_of_url:register_args ~path:"/register"
    (Relay_test_support.malformed_json_response ())
    ()

let reg_refused () =
  check_refused ~what:"register vs connection refused"
    ~args_of_url:register_args ()

let reg_empty_response () =
  check_transport_fault ~what:"register vs empty response"
    ~args_of_url:register_args ~path:"/register"
    (Relay_test_support.response ~close_without_response:true "")
    ()

(* KNOWN DEFECT 1 — FIXED (H7 status-honesty): Relay_client.request used to
   ignore the HTTP status line, so an HTTP 500 whose body claimed
   {"ok":true} was a FALSE SUCCESS (rc=0, ok:true printed — reproduced
   empirically 2026-07-10). The fixed contract, pinned here: a non-2xx
   status can NEVER produce ok:true. When the body does not honestly
   report ok:false, the client overrides it with
   error_code=http_error_<status>, attaches http_status, and preserves the
   dishonest body under relay_response. Single request — an http_error is
   never blindly retried. *)
let http_5xx_ok_body_never_success () =
  let tmp = mkdtemp () in
  with_fault ~meth:"POST" ~path:"/register"
    [ json_response ~status:500 (`Assoc [ ("ok", `Bool true) ]) ]
    (fun srv url ->
      let ((_, out, _) as res) = run_c2c ~tmp (register_args ~url) in
      assert_honest_failure ~what:"register vs 500 + ok:true body"
        ~needle:"http_error_500" res;
      let json = Yojson.Safe.from_string out in
      (match member "http_status" json with
       | `Int 500 -> ()
       | other ->
           Alcotest.fail
             (Printf.sprintf "http_status must be 500, got %s"
                (Yojson.Safe.to_string other)));
      (* The dishonest body is preserved for diagnosis, not believed. *)
      (match member "relay_response" json with
       | `Assoc _ -> ()
       | other ->
           Alcotest.fail
             (Printf.sprintf "relay_response must carry the body, got %s"
                (Yojson.Safe.to_string other)));
      Alcotest.(check int) "exactly one request (no blind retry)" 1
        (List.length (requests_for ~path:"/register" srv)))

(* ------------------------------------------------------------------ *)
(* Matrix: `c2c relay dm send` × faults                                *)
(* ------------------------------------------------------------------ *)

let dm_401 () =
  check_status_fault ~what:"dm send vs 401" ~args_of_url:dm_send_args
    ~path:"/send" ~status:401 ~error_code:"unauthorized" ()

let dm_429 () =
  check_status_fault ~what:"dm send vs 429" ~args_of_url:dm_send_args
    ~path:"/send" ~status:429 ~error_code:"rate_limited" ()

let dm_500 () =
  check_status_fault ~what:"dm send vs 500" ~args_of_url:dm_send_args
    ~path:"/send" ~status:500 ~error_code:"internal_error" ()

let dm_truncated () =
  check_transport_fault ~what:"dm send vs truncated JSON"
    ~args_of_url:dm_send_args ~path:"/send"
    (Relay_test_support.response ~truncate_body_at:10
       {|{"ok":true,"message_id":"f5bx-fake"}|})
    ()

let dm_malformed () =
  check_transport_fault ~what:"dm send vs malformed JSON"
    ~args_of_url:dm_send_args ~path:"/send"
    (Relay_test_support.malformed_json_response ())
    ()

let dm_refused () =
  check_refused ~what:"dm send vs connection refused" ~args_of_url:dm_send_args ()

let dm_empty_response () =
  check_transport_fault ~what:"dm send vs empty response"
    ~args_of_url:dm_send_args ~path:"/send"
    (Relay_test_support.response ~close_without_response:true "")
    ()

let dm_poll_malformed () =
  check_transport_fault ~what:"dm poll vs malformed JSON"
    ~args_of_url:(fun ~url ->
      [ "relay"; "dm"; "poll"; "--alias"; "f5bx-src"; "--relay-url"; url ])
    ~path:"/poll_inbox"
    (Relay_test_support.malformed_json_response ())
    ()

(* ------------------------------------------------------------------ *)
(* Matrix: `c2c relay status` (health) × faults + timeout              *)
(* ------------------------------------------------------------------ *)

let status_args ~url = [ "relay"; "status"; "--relay-url"; url ]

let status_refused () =
  check_refused ~what:"status vs connection refused" ~args_of_url:status_args ()

let status_500_json () =
  let tmp = mkdtemp () in
  with_fault ~meth:"GET" ~path:"/health"
    [ json_response ~status:500 (err_body ~error_code:"internal_error" ~error:"boom") ]
    (fun _srv url ->
      assert_honest_failure ~what:"status vs 500"
        ~needle:"internal_error"
        (run_c2c ~tmp (status_args ~url)))

(* Positive control: the honest-failure assertions above are meaningful
   only if the same command exits 0 against a healthy scripted relay. *)
let status_ok_control () =
  let tmp = mkdtemp () in
  with_fault ~meth:"GET" ~path:"/health"
    [ json_response (`Assoc [ ("ok", `Bool true); ("version", `String "f5b") ]) ]
    (fun _srv url ->
      let rc, out, _ = run_c2c ~tmp (status_args ~url) in
      Alcotest.(check int) "healthy relay: exit 0" 0 rc;
      Alcotest.(check bool) "healthy relay: ok:true printed" true
        (contains ~needle:{|"ok": true|} out))

(* All relay subcommands share Relay_client.request, whose client timeout
   is hardwired to 10.0s (Lwt.pick against a sleep). One representative
   row pins it: a response delayed past the timeout fails honestly as
   connection_error/request_timeout. Bounded: client aborts at ~10s; the
   forked server child (asleep in the scripted delay) is SIGKILLed by the
   bracket. *)
let status_client_timeout_hardwired () =
  let tmp = mkdtemp () in
  with_fault ~meth:"GET" ~path:"/health"
    [ Relay_test_support.response ~delay_s:12.0 {|{"ok":true}|} ]
    (fun _srv url ->
      let t0 = Unix.gettimeofday () in
      let res = run_c2c ~tmp (status_args ~url) in
      let elapsed = Unix.gettimeofday () -. t0 in
      assert_honest_failure ~what:"status vs 12s delay (10s client timeout)"
        ~needle:"request_timeout" res;
      Alcotest.(check bool)
        (Printf.sprintf "timeout fired near the 10s deadline (%.1fs)" elapsed)
        true
        (elapsed >= 9.0 && elapsed < 13.0))

(* `c2c list --relay` is the one relay path with a CLI timeout knob
   (--relay-timeout). Its offline contract (H6) is NONFATAL degradation:
   exit 0, local rows survive, relay failure surfaced as relay_error data —
   never as silent success (relay rows absent, error string names the
   timeout). *)
let list_relay_timeout_nonfatal () =
  let tmp = mkdtemp () in
  with_fault ~meth:"GET" ~path:"/list"
    [ Relay_test_support.response ~delay_s:3.0 {|{"ok":true,"peers":[]}|} ]
    (fun _srv url ->
      let rc, out, _ =
        run_c2c ~tmp
          [ "list"; "--relay"; "--relay-url"; url; "--relay-timeout"; "0.5";
            "--json" ]
      in
      Alcotest.(check int) "list --relay timeout: exit 0 (nonfatal)" 0 rc;
      let json = Yojson.Safe.from_string out in
      (match member "relay_error" json with
       | `String msg ->
           Alcotest.(check bool)
             (Printf.sprintf "relay_error names the timeout (got %S)" msg)
             true (contains ~needle:"request_timeout" msg)
       | other ->
           Alcotest.fail
             (Printf.sprintf "expected relay_error string, got %s"
                (Yojson.Safe.to_string other)));
      match member "peers" json with
      | `List [] -> ()
      | `List l ->
          Alcotest.fail
            (Printf.sprintf "no relay rows may appear on timeout (got %d)"
               (List.length l))
      | _ -> Alcotest.fail "peers array missing")

(* ------------------------------------------------------------------ *)
(* Matrix: PoW adverse (register challenge handling)                   *)
(* ------------------------------------------------------------------ *)

let pow_required_body ?(difficulty = 1) ?(ctx = "c2c/v1/pow") () =
  `Assoc
    [ ("ok", `Bool false);
      ("error_code", `String "pow_required");
      ("required",
       `Assoc
         [ ("difficulty", `Int difficulty);
           ("epoch", `Int 1);
           ("server_nonce", `String "f5bx-nonce");
           ("ctx", `String ctx);
         ]);
    ]

(* Give the isolated HOME an Ed25519 identity so /register goes signed and
   the PoW actor_id is non-empty (the minted-retry path requires it). *)
let init_identity tmp =
  mkdir_p (Filename.concat (Filename.concat tmp ".config") "c2c");
  let rc, _, err = run_c2c ~tmp [ "relay"; "identity"; "init" ] in
  if rc <> 0 then
    Alcotest.fail (Printf.sprintf "relay identity init failed rc=%d: %s" rc err)

(* No pre-existing identity: since B114 the CLI auto-creates an Ed25519
   identity and registers SIGNED (the unsigned register fallback is gone,
   so the old pow_actor_id_missing state is unreachable via the CLI). A
   pow_required challenge therefore mints against the fresh identity and
   retries exactly ONCE, then fails honestly — still bounded, no loop. *)
let pow_unsigned_actor_missing () =
  let tmp = mkdtemp () in
  with_fault ~meth:"POST" ~path:"/register"
    [ json_response ~status:429 (pow_required_body ());
      json_response ~status:429 (pow_required_body ()) ]
    (fun srv url ->
      assert_honest_failure ~what:"identity-less register vs pow_required"
        ~needle:"pow_retry_failed"
        (run_c2c ~tmp (register_args ~url));
      Alcotest.(check int) "exactly two requests (one minted retry, no loop)" 2
        (List.length (requests_for ~path:"/register" srv));
      (* The identity must have been auto-created in the isolated HOME. *)
      let id_path =
        Filename.concat tmp ".config/c2c/identity.json"
      in
      Alcotest.(check bool) "identity auto-created for signed register" true
        (Sys.file_exists id_path))

(* Garbage challenge: pow_required with a null/malformed [required] object
   must fail honestly (pow_bad_required) after ONE request — no loop. *)
let pow_garbage_challenge () =
  let tmp = mkdtemp () in
  init_identity tmp;
  with_fault ~meth:"POST" ~path:"/register"
    [ json_response ~status:429
        (`Assoc
          [ ("ok", `Bool false);
            ("error_code", `String "pow_required");
            ("required", `Null);
          ]) ]
    (fun srv url ->
      assert_honest_failure ~what:"register vs garbage PoW challenge"
        ~needle:"pow_bad_required"
        (run_c2c ~tmp (register_args ~url));
      Alcotest.(check int) "exactly one request (bounded, no loop)" 1
        (List.length (requests_for ~path:"/register" srv)))

(* Unsupported ctx: refuse to mint for a challenge domain we don't speak. *)
let pow_wrong_ctx () =
  let tmp = mkdtemp () in
  init_identity tmp;
  with_fault ~meth:"POST" ~path:"/register"
    [ json_response ~status:429 (pow_required_body ~ctx:"evil/ctx" ()) ]
    (fun srv url ->
      assert_honest_failure ~what:"register vs wrong-ctx PoW challenge"
        ~needle:"pow_unsupported_ctx"
        (run_c2c ~tmp (register_args ~url));
      Alcotest.(check int) "exactly one request" 1
        (List.length (requests_for ~path:"/register" srv)))

(* Accept-then-401: valid challenge, mint succeeds, retry is SENT (with
   pow fields), relay then rejects with 401 — the final failure is honest
   and there are exactly TWO requests (the claimed one-retry contract). *)
let pow_accept_then_401 () =
  let tmp = mkdtemp () in
  init_identity tmp;
  with_fault ~meth:"POST" ~path:"/register"
    [ json_response ~status:429 (pow_required_body ());
      json_response ~status:401
        (err_body ~error_code:"unauthorized" ~error:"unauthorized");
    ]
    (fun srv url ->
      assert_honest_failure ~what:"register vs PoW-then-401"
        ~needle:"unauthorized"
        (run_c2c ~tmp (register_args ~url));
      let reqs = requests_for ~path:"/register" srv in
      Alcotest.(check int) "exactly two requests (one minted retry)" 2
        (List.length reqs);
      match reqs with
      | [ first; second ] ->
          Alcotest.(check bool) "first request carries no pow_nonce" false
            (contains ~needle:"pow_nonce" first.Relay_test_support.body);
          Alcotest.(check bool) "retry carries the minted pow_nonce" true
            (contains ~needle:"pow_nonce" second.Relay_test_support.body)
      | _ -> Alcotest.fail "expected exactly two captured requests")

(* Challenge loop: relay keeps demanding PoW after the minted retry. The
   client must stop after ONE retry (pow_retry_failed) — bounded, never an
   infinite mint loop. *)
let pow_required_forever_bounded () =
  let tmp = mkdtemp () in
  init_identity tmp;
  with_fault ~meth:"POST" ~path:"/register"
    [ json_response ~status:429 (pow_required_body ()) ]
    (* single scripted response: the last repeats forever *)
    (fun srv url ->
      assert_honest_failure ~what:"register vs endless pow_required"
        ~needle:"pow_retry_failed"
        (run_c2c ~tmp (register_args ~url));
      Alcotest.(check int) "exactly two requests (retry bound holds)" 2
        (List.length (requests_for ~path:"/register" srv)))

(* Retry-honesty positive control: challenge then success — the retry
   actually happens and the success is annotated with the difficulty the
   client had to mint (pow_minted_difficulty, B010). *)
let pow_mint_then_success () =
  let tmp = mkdtemp () in
  init_identity tmp;
  with_fault ~meth:"POST" ~path:"/register"
    [ json_response ~status:429 (pow_required_body ());
      json_response (`Assoc [ ("ok", `Bool true) ]);
    ]
    (fun srv url ->
      let rc, out, _ = run_c2c ~tmp (register_args ~url) in
      Alcotest.(check int) "minted retry succeeds: exit 0" 0 rc;
      Alcotest.(check bool) "success annotated with pow_minted_difficulty" true
        (contains ~needle:"pow_minted_difficulty" out);
      Alcotest.(check int) "exactly two requests" 2
        (List.length (requests_for ~path:"/register" srv)))

(* ------------------------------------------------------------------ *)
(* Matrix: `c2c doctor --relay --json` × faulted relay                 *)
(* ------------------------------------------------------------------ *)

let doctor_checks json =
  match member "checks" json with
  | `List checks -> checks
  | _ -> Alcotest.fail "doctor --json: checks array missing"

let doctor_check ~id json =
  match
    List.find_opt (fun c -> str_member "check_id" c = Some id)
      (doctor_checks json)
  with
  | Some c -> c
  | None -> Alcotest.fail (Printf.sprintf "doctor --json: %s check missing" id)

(* Doctor exit-code contract vs a refused relay: the JSON report is
   well-formed, summary.any_fail is honest against its own checks list,
   and the process exit is 1 iff any check FAILs. (In a fresh isolated
   broker root the relay.connector check deterministically FAILs — no
   connector process, no sync state — so exit must be 1.) The
   relay.reachable check itself is pinned by the FIXME below. *)
let doctor_refused_exit_contract () =
  let tmp = mkdtemp () in
  let url =
    Printf.sprintf "http://127.0.0.1:%d" (Relay_test_support.closed_port ())
  in
  let rc, out, _ =
    run_c2c ~tmp ~extra:[ "C2C_RELAY_URL=" ^ url ]
      [ "doctor"; "--relay"; "--json" ]
  in
  let json = Yojson.Safe.from_string out in
  let checks = doctor_checks json in
  let n_fail =
    List.length
      (List.filter (fun c -> str_member "status" c = Some "FAIL") checks)
  in
  (match member "summary" json with
   | `Assoc _ as s ->
       (match member "any_fail" s with
        | `Bool b ->
            Alcotest.(check bool) "summary.any_fail matches the checks list"
              (n_fail > 0) b
        | _ -> Alcotest.fail "summary.any_fail missing")
   | _ -> Alcotest.fail "summary missing");
  Alcotest.(check bool) "fresh broker root: connector check FAILs" true
    (str_member "status" (doctor_check ~id:"relay.connector" json)
     = Some "FAIL");
  Alcotest.(check int) "doctor exits 1 when any check FAILs" 1 rc;
  (* No check may claim a lease/peer signal from a dead relay. *)
  Alcotest.(check bool) "lease check does not PASS against a dead relay" true
    (str_member "status" (doctor_check ~id:"relay.lease" json) <> Some "PASS")

(* KNOWN DEFECT 2 — FIXED (H7 status-honesty): against a CONNECTION-REFUSED
   relay, `c2c doctor --relay` used to report relay.reachable = PASS
   ("relay reachable (responded; ok=false ...)") because Relay_client
   swallows the network error into a synthesized connection_error JSON and
   check_reachable treated ANY parsed JSON as proof the relay responded
   (reproduced empirically 2026-07-10). Fixed contract, pinned here:
   client-synthesized transport errors carry transport:true; probe_relay
   folds them back into the health=None unreachable branch, so
   relay.reachable = FAIL (message names unreachability + the error) and
   relay.lease reports itself skipped rather than judging leases against a
   relay nobody reached. Full-report consistency pinned like the C047
   exit-contract cell: summary.any_fail true, exit 1. *)
let doctor_refused_reachable_fails () =
  let tmp = mkdtemp () in
  let url =
    Printf.sprintf "http://127.0.0.1:%d" (Relay_test_support.closed_port ())
  in
  let rc, out, _ =
    run_c2c ~tmp ~extra:[ "C2C_RELAY_URL=" ^ url ]
      [ "doctor"; "--relay"; "--json" ]
  in
  let json = Yojson.Safe.from_string out in
  let reachable = doctor_check ~id:"relay.reachable" json in
  Alcotest.(check (option string)) "relay.reachable FAILs on refused relay"
    (Some "FAIL") (str_member "status" reachable);
  Alcotest.(check bool)
    (Printf.sprintf "reachable message names unreachability (got %s)"
       (Option.value ~default:"<none>" (str_member "message" reachable)))
    true
    (match str_member "message" reachable with
     | Some m -> contains ~needle:"unreachable" m
     | None -> false);
  Alcotest.(check (option string))
    "relay.lease is INCONCLUSIVE (skipped), never judged against a dead relay"
    (Some "INCONCLUSIVE")
    (str_member "status" (doctor_check ~id:"relay.lease" json));
  (match member "summary" json with
   | `Assoc _ as s ->
       (match member "any_fail" s with
        | `Bool b ->
            Alcotest.(check bool) "summary.any_fail true (reachable FAILed)"
              true b
        | _ -> Alcotest.fail "summary.any_fail missing")
   | _ -> Alcotest.fail "summary missing");
  Alcotest.(check int) "doctor exits 1" 1 rc

(* ------------------------------------------------------------------ *)
(* Strict B098 vector (process level)                                  *)
(* ------------------------------------------------------------------ *)

(* B098 "bus, never RPC", end-to-end through the REAL binary and the REAL
   relay->inbox delivery path:

     scripted relay serves a verdict-looking DM ("<token> allow" from a
     CONFIGURED supervisor, relay-form sender)
       -> `c2c relay connect --once` (real connector) registers the local
          session against the scripted relay, polls /poll_inbox, and
          delivers the message into the local broker inbox
       -> `c2c await-reply` (real binary) with the pending token: the
          relay-delivered verdict is INERT — exit 1, no verdict printed
       -> `c2c approval-reply` (host-local CLI verdict file) still
          resolves it — exit 0, verdict printed.

   This is the process-level strengthening of H1's unit/CLI-seam
   regression (test_remote_message_cannot_reach_approval_path): here the
   hostile message travels the genuine relay transport (HTTP poll ->
   connector -> inbox file), not a hand-written inbox fixture. *)
let b098_relay_delivered_verdict_is_inert () =
  let tmp = mkdtemp () in
  let broker_root = Filename.concat tmp "broker" in
  mkdir_p broker_root;
  let session_id = "f5bx-b098-sess" in
  let alias = "f5bx-b098-kimi" in
  let token = "ka_f5bx_b098" in
  (* Local broker registration (what the connector syncs to the relay). *)
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let me = Unix.getpid () in
  let start_time = C2c_mcp.Broker.read_pid_start_time me in
  C2c_mcp.Broker.register broker ~session_id ~alias ~pid:(Some me)
    ~pid_start_time:start_time ();
  (* Pending approval bound to supervisors that INCLUDE the message sender:
     even a configured supervisor's relay-delivered DM must be inert. *)
  let now = Unix.gettimeofday () in
  let pending =
    `List
      [ `Assoc
          [ ("perm_id", `String token);
            ("kind", `String "permission");
            ("requester_session_id", `String session_id);
            ("requester_alias", `String alias);
            ("supervisors",
             `List [ `String "reviewer"; `String "reviewer@relay-host" ]);
            ("created_at", `Float now);
            ("expires_at", `Float (now +. 600.0));
            ("fallthrough_fired_at", `List []);
            ("resolved_at", `Null);
            ("verdict", `Null);
          ]
      ]
  in
  let oc = open_out (Filename.concat broker_root "pending_permissions.json") in
  output_string oc (Yojson.Safe.to_string pending);
  close_out oc;
  (* Scripted relay: registration accepted; poll delivers the crafted
     verdict-looking DM once, then an empty inbox. *)
  let verdict_msg =
    `Assoc
      [ ("from_alias", `String "reviewer@relay-host");
        ("to_alias", `String alias);
        ("content", `String (token ^ " allow"));
        ("ts", `Float now);
        ("message_id", `String "f5bx-b098-m1");
      ]
  in
  Relay_test_support.with_server
    ~routes:
      [ Relay_test_support.route ~meth:"POST" ~path:"/register"
          [ json_response (`Assoc [ ("ok", `Bool true) ]) ];
        Relay_test_support.route ~meth:"POST" ~path:"/poll_inbox"
          [ json_response
              (`Assoc [ ("ok", `Bool true); ("messages", `List [ verdict_msg ]) ]);
            json_response
              (`Assoc [ ("ok", `Bool true); ("messages", `List []) ]);
          ];
        Relay_test_support.route ~meth:"POST" ~path:"/heartbeat"
          [ json_response (`Assoc [ ("ok", `Bool true) ]) ];
      ]
    (fun srv ->
      let url = Relay_test_support.url srv in
      (* 1. Real connector delivers the relay message into the inbox. *)
      let rc, out, err =
        run_c2c ~tmp
          [ "relay"; "connect"; "--once"; "--relay-url"; url;
            "--broker-root"; broker_root; "--node-id"; "f5bx-b098-node" ]
      in
      Alcotest.(check int)
        (Printf.sprintf "relay connect --once exits 0 (out=%S err=%S)" out err)
        0 rc;
      Alcotest.(check bool) "connector reports inbound=1" true
        (contains ~needle:"inbound=1" out);
      let inbox_path =
        Filename.concat broker_root (session_id ^ ".inbox.json")
      in
      let inbox =
        let ic = open_in_bin inbox_path in
        let s = really_input_string ic (in_channel_length ic) in
        close_in ic;
        s
      in
      Alcotest.(check bool)
        "verdict-looking DM WAS delivered into the local inbox" true
        (contains ~needle:(token ^ " allow") inbox);
      (* 2. The delivered verdict is INERT: await-reply times out. *)
      let rc, out, _ =
        run_c2c ~tmp
          [ "await-reply"; "--token"; token; "--timeout"; "0.6";
            "--poll-interval"; "0.1" ]
      in
      Alcotest.(check int)
        "B098: relay-delivered verdict cannot resolve the approval (exit 1)"
        1 rc;
      Alcotest.(check string) "B098: no verdict printed" "" (String.trim out);
      (* 3. The host-local verdict file still resolves it. *)
      let rc, _, err =
        run_c2c ~tmp
          [ "approval-reply"; token; "allow"; "--reviewer"; "reviewer";
            "--broker-root"; broker_root ]
      in
      Alcotest.(check int)
        (Printf.sprintf "host-local approval-reply succeeds (err=%S)" err)
        0 rc;
      let rc, out, _ =
        run_c2c ~tmp
          [ "await-reply"; "--token"; token; "--timeout"; "1";
            "--poll-interval"; "0.1" ]
      in
      Alcotest.(check int) "local verdict file resolves the approval" 0 rc;
      Alcotest.(check string) "verdict is allow" "allow" (String.trim out))

(* ------------------------------------------------------------------ *)
(* Runner                                                              *)
(* ------------------------------------------------------------------ *)

let () =
  Random.self_init ();
  Alcotest.run "relay_fault_matrix"
    [
      ( "relay register faults",
        [ Alcotest.test_case "B094 401 register fails honestly" `Quick reg_401;
          Alcotest.test_case "B080 429 register single-shot honest failure"
            `Quick reg_429;
          Alcotest.test_case "B090 500 JSON register fails honestly" `Quick
            reg_500;
          Alcotest.test_case "B087 503 non-JSON register fails honestly" `Quick
            reg_503_non_json;
          Alcotest.test_case "B091 truncated JSON is not success" `Quick
            reg_truncated;
          Alcotest.test_case "B092 malformed JSON is not success" `Quick
            reg_malformed;
          Alcotest.test_case "B089 connection refused register fails honestly"
            `Quick reg_refused;
          Alcotest.test_case "B095 empty response register fails honestly"
            `Quick reg_empty_response;
          Alcotest.test_case
            "B090 5xx with ok:true body is an honest http_error_500 failure"
            `Quick http_5xx_ok_body_never_success;
        ] );
      ( "relay dm faults",
        [ Alcotest.test_case "B094 401 dm send fails honestly" `Quick dm_401;
          Alcotest.test_case "B080 429 dm send single-shot honest failure"
            `Quick dm_429;
          Alcotest.test_case "B090 500 dm send fails honestly" `Quick dm_500;
          Alcotest.test_case "B091 truncated dm send is not success" `Quick
            dm_truncated;
          Alcotest.test_case "B092 malformed dm send is not success" `Quick
            dm_malformed;
          Alcotest.test_case "B089 refused dm send fails honestly" `Quick
            dm_refused;
          Alcotest.test_case "B095 empty-response dm send fails honestly"
            `Quick dm_empty_response;
          Alcotest.test_case "B096 malformed dm poll fails honestly" `Quick
            dm_poll_malformed;
        ] );
      ( "relay status + timeout",
        [ Alcotest.test_case "A006 refused status fails honestly" `Quick
            status_refused;
          Alcotest.test_case "A007 500 status fails honestly" `Quick
            status_500_json;
          Alcotest.test_case "A008 healthy status exits 0 (positive control)"
            `Quick status_ok_control;
          Alcotest.test_case
            "B074 hardwired 10s client timeout fails honestly" `Slow
            status_client_timeout_hardwired;
          Alcotest.test_case "B074 list --relay timeout nonfatal + honest"
            `Quick list_relay_timeout_nonfatal;
        ] );
      ( "PoW adverse",
        [ Alcotest.test_case
            "A083 identity-less register auto-signs; pow_required bounded"
            `Quick pow_unsigned_actor_missing;
          Alcotest.test_case "A088 garbage PoW challenge bounded honest fail"
            `Quick pow_garbage_challenge;
          Alcotest.test_case "A088 wrong-ctx PoW challenge honest fail" `Quick
            pow_wrong_ctx;
          Alcotest.test_case "B088 PoW accept-then-401 one retry then honest fail"
            `Quick pow_accept_then_401;
          Alcotest.test_case
            "B088 endless pow_required bounded at one retry (no loop)" `Quick
            pow_required_forever_bounded;
          Alcotest.test_case
            "B088 minted retry succeeds + pow_minted_difficulty annotated"
            `Quick pow_mint_then_success;
        ] );
      ( "doctor vs faulted relay",
        [ Alcotest.test_case
            "C047 doctor --json refused relay: well-formed, exit=any_fail"
            `Quick doctor_refused_exit_contract;
          Alcotest.test_case
            "C047 relay.reachable FAILs on refused relay (honest doctor)"
            `Quick doctor_refused_reachable_fails;
        ] );
      ( "B098 strict vector",
        [ Alcotest.test_case
            "B098 relay-delivered verdict inert; local verdict file resolves"
            `Quick b098_relay_delivered_verdict_is_inert;
        ] );
    ]
