(* test_inbox_hook_harness — end-to-end + latency harness for the
   PostToolUse inbox hook (ocaml/tools/c2c_inbox_hook.ml).

   This test exercises the BUILT `c2c_inbox_hook.exe` as a subprocess
   (feeding it real stdin, checking stdout JSON) and measures its
   wall-clock latency. It is intentionally complementary to
   `test_session_id_delivery.ml` — that file already covers the
   canonical happy path + path-escape rejection. This file adds the
   edge cases that the canonical tests skip plus a speed harness so
   latency regressions are caught at `dune test` time.

   The hook itself does (P0, see commit d7b1a925):
     1. Read up to 64 KiB from stdin, extract `session_id` from the JSON.
     2. Fall back to env `C2C_MCP_SESSION_ID` if stdin lacks it.
     3. Fast-path exit 0 if no session_id is resolvable.
     4. Validate via `C2c_name.is_valid`; exit 1 on invalid.
     5. Drain repo broker (if `C2C_MCP_BROKER_ROOT` set) and the global
        sessions broker (`C2C_SESSIONS_BROKER_ROOT`).
     6. Emit cold-boot context (once per session, marker file at
        `<broker_root>/.cold_boot_done/<sid>`).
     7. Print `{"hookSpecificOutput":{"hookEventName":"PostToolUse",
        "additionalContext":"<envelopes>+<ctx>"}}` to stdout.

   Edge cases covered here:
     * N=1 / N>1 messages drained in a single call (destructive).
     * Empty inbox → no stdout, exit 0.
     * Malformed stdin JSON → falls back to env.
     * Empty stdin → falls back to env.
     * No session_id anywhere → fast-path, exit 0, no crash.
     * session_id at start of a payload that just fits the 64 KiB scan
       bound → extracted.
     * session_id beyond 64 KiB scan bound → falls back to env (or
       fast-path exits 0 if no env).
     * Cold-boot context is emitted on first call, suppressed on the
       second (marker persists across invocations).

   Speed harness:
     * K iterations of the basic case (one queued message).
     * Wall-clock measured around the `Sys.command` call.
     * Min/median/max ms printed regardless.
     * Hard upper bound asserted only when `C2C_HOOK_SPEED_STRICT=1`
       (machine-variance guard, matches the existing
       `C2C_RELAY_E2E_STRICT_V2` pattern). *)

open Alcotest

(* ------------------------------------------------------------------ *)
(* Path resolution                                                    *)
(* ------------------------------------------------------------------ *)

(* dune test may run the test with a relative `argv[0]`, so resolve
   to absolute via the current working directory before walking up. *)
let abs_path p =
  if Filename.is_relative p then Filename.concat (Unix.getcwd ()) p else p

(* `Sys.executable_name` for the test exe is something like
   `<worktree>/_build/default/ocaml/test/test_inbox_hook_harness.exe`
   (or relative under `dune test` — see abs_path above). The hook exe
   sits two levels up under `tools/`. *)
let hook_bin () : string =
  let exe = abs_path Sys.executable_name in
  let exe_dir = Filename.dirname exe in
  let ocaml_dir = Filename.dirname exe_dir in
  let hook = Filename.concat ocaml_dir "tools/c2c_inbox_hook.exe" in
  if not (Sys.file_exists hook) then
    Alcotest.fail
      (Printf.sprintf "hook binary not found at %s (test exe=%s)" hook exe);
  hook

(* ------------------------------------------------------------------ *)
(* Filesystem helpers                                                  *)
(* ------------------------------------------------------------------ *)

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base
      (Printf.sprintf "c2c-hook-harness-%08x" (Random.bits ()))
  in
  (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) ->
     ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
     Unix.mkdir dir 0o700);
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let write_file path contents =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc contents)

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    really_input_string ic (in_channel_length ic))

let string_contains haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= hay_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let json_list_length path =
  let raw = read_file path in
  match Yojson.Safe.from_string (String.trim raw) with
  | `List items -> List.length items
  | _ -> Alcotest.fail ("expected JSON list in " ^ path)

(* ------------------------------------------------------------------ *)
(* Subprocess driver                                                   *)
(* ------------------------------------------------------------------ *)

(* Env var directive: either set to a value, or unset. *)
type env_op = Set of string * string | Unset of string

(* GNU env requires all -u options BEFORE any NAME=VALUE assignment, so emit
   unsets first regardless of input order. Later assignments override earlier
   ones (and an earlier -u for the same key), so base env can be prepended and
   still overridden by a caller that Sets the same key. *)
let env_op_to_args ops =
  let unsets =
    List.filter_map
      (function Unset k -> Some (Printf.sprintf "-u %s" k) | _ -> None) ops
  in
  let sets =
    List.filter_map
      (function
        | Set (k, v) -> Some (Printf.sprintf "%s=%s" k (Filename.quote v))
        | _ -> None)
      ops
  in
  unsets @ sets

(* Result of one hook invocation. *)
type hook_result = {
  rc : int;
  stdout : string;
  stderr : string;
  elapsed_ms : float;
}

(* Hermetic sandbox for the hook subprocess. Since C2c_hook_lib.resolve_hook_
   broker_root now falls back to the canonical repo-fingerprint broker
   ($HOME/.c2c/repos/<fp>/broker, or $C2C_STATE_HOME/... when set) whenever
   C2C_MCP_BROKER_ROOT is unset, a hook run from inside this git repo with
   the real $HOME would resolve — and DRAIN — the developer's live broker.
   Pointing both HOME and C2C_STATE_HOME at a fresh EMPTY temp tree forces
   that fallback to a path with no registry.json, so the helper returns ""
   and the repo drain is skipped exactly as before. C2C_STATE_HOME wins in
   resolve_broker_root_fallback; HOME is belt-and-suspenders + keeps any
   statefile writes off real ~. *)
let with_hermetic_home f =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "c2c-hook-hermetic-%08x" (Random.bits ()))
  in
  (try Unix.mkdir dir 0o700
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let run_hook ?(env=[]) ~stdin_payload () : hook_result =
  let hook = hook_bin () in
  let stdin_path = Filename.temp_file "c2c-hook-harness-in" ".json" in
  let out = Filename.temp_file "c2c-hook-harness-out" ".json" in
  let err = Filename.temp_file "c2c-hook-harness-err" ".txt" in
  with_hermetic_home @@ fun hermetic ->
  let base_env =
    [ Unset "C2C_MCP_BROKER_ROOT"
    ; Set ("HOME", hermetic)
    ; Set ("C2C_STATE_HOME", hermetic)
    ]
  in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove stdin_path with _ -> ());
      (try Sys.remove out with _ -> ());
      (try Sys.remove err with _ -> ()))
    (fun () ->
      write_file stdin_path stdin_payload;
      let env_args = env_op_to_args (base_env @ env) in
      let env_str = String.concat " " env_args in
      let cmd =
        Printf.sprintf
          "env %s %s < %s > %s 2> %s"
          env_str
          (Filename.quote hook)
          (Filename.quote stdin_path)
          (Filename.quote out)
          (Filename.quote err)
      in
      let t0 = Unix.gettimeofday () in
      let rc = Sys.command cmd in
      let t1 = Unix.gettimeofday () in
      let stdout = if Sys.file_exists out then read_file out else "" in
      let stderr = if Sys.file_exists err then read_file err else "" in
      { rc; stdout; stderr; elapsed_ms = (t1 -. t0) *. 1000.0 })

(* Parse stdout into the additionalContext string, or None if hook
   emitted nothing (the fast path / no-messages case). *)
let parse_additional_context result : string option =
  let s = String.trim result.stdout in
  if s = "" then None
  else
    try
      let json = Yojson.Safe.from_string s in
      let open Yojson.Safe.Util in
      match json |> member "hookSpecificOutput" with
      | `Assoc _ ->
          (match json |> member "hookSpecificOutput" |> member "additionalContext"
                |> to_string_option with
           | Some ctx -> Some ctx
           | None -> None)
      | _ -> None
    with _ -> None

(* ------------------------------------------------------------------ *)
(* Inbox seeding                                                       *)
(* ------------------------------------------------------------------ *)

let seed_inbox ~dir ~sid n =
  let inbox_path = Filename.concat dir (sid ^ ".inbox.json") in
  let items = List.init n (fun i ->
    Printf.sprintf
      {|{"from_alias":"sender-%d","to_alias":%S,"content":"msg-%d-for-%s","ts":%d.0}|}
      i sid i sid (i + 1))
  in
  let body = "[" ^ String.concat "," items ^ "]" in
  write_file inbox_path body;
  inbox_path

(* ------------------------------------------------------------------ *)
(* Correctness tests                                                   *)
(* ------------------------------------------------------------------ *)

let test_drains_single_message_and_destructive_drain () =
  with_temp_dir (fun dir ->
    let sid = "harness-single" in
    let inbox = seed_inbox ~dir ~sid 1 in
    let payload = Printf.sprintf {|{"session_id":%S,"hook_event_name":"PostToolUse"}|} sid in
    let r = run_hook ~env:[Unset "C2C_MCP_SESSION_ID"; Unset "C2C_MCP_BROKER_ROOT";
                           Set ("C2C_SESSIONS_BROKER_ROOT", dir)]
                ~stdin_payload:payload () in
    check int "hook exits 0" 0 r.rc;
    let ctx = match parse_additional_context r with
      | Some s -> s
      | None -> Alcotest.fail "expected additionalContext, got no stdout"
    in
    check bool "additionalContext has c2c envelope" true
      (string_contains ctx "<c2c ");
    check bool "additionalContext has message content" true
      (string_contains ctx "msg-0-for-harness-single");
    check bool "additionalContext closes c2c envelope" true
      (string_contains ctx "</c2c>");
    check int "inbox drained destructively" 0 (json_list_length inbox))

let test_drains_multiple_messages_in_one_call () =
  with_temp_dir (fun dir ->
    let sid = "harness-multi" in
    let inbox = seed_inbox ~dir ~sid 3 in
    let payload = Printf.sprintf {|{"session_id":%S}|} sid in
    let r = run_hook ~env:[Set ("C2C_SESSIONS_BROKER_ROOT", dir)]
                ~stdin_payload:payload () in
    check int "hook exits 0" 0 r.rc;
    let ctx = match parse_additional_context r with
      | Some s -> s
      | None -> Alcotest.fail "expected additionalContext"
    in
    List.iter (fun i ->
      check bool (Printf.sprintf "delivers msg-%d" i) true
        (string_contains ctx (Printf.sprintf "msg-%d-for-harness-multi" i)))
      [0; 1; 2];
    check int "inbox drained to 0" 0 (json_list_length inbox))

let test_empty_inbox_emits_no_output () =
  with_temp_dir (fun dir ->
    let sid = "harness-empty" in
    (* No inbox file written at all — `drain_global_messages` is a no-op
       when the file doesn't exist. *)
    let payload = Printf.sprintf {|{"session_id":%S}|} sid in
    let r = run_hook ~env:[Set ("C2C_SESSIONS_BROKER_ROOT", dir)]
                ~stdin_payload:payload () in
    check int "hook exits 0" 0 r.rc;
    check bool "no stdout emitted on empty inbox" true
      (String.trim r.stdout = "");
    check bool "no additionalContext" true
      (parse_additional_context r = None))

let test_env_fallback_when_stdin_malformed () =
  with_temp_dir (fun dir ->
    let sid = "harness-malformed" in
    let inbox = seed_inbox ~dir ~sid 1 in
    let payload = {|this is not valid json at all {[|} in
    let r = run_hook ~env:[Unset "C2C_MCP_BROKER_ROOT";
                           Set ("C2C_MCP_SESSION_ID", sid);
                           Set ("C2C_SESSIONS_BROKER_ROOT", dir)]
                ~stdin_payload:payload () in
    check int "hook exits 0 via env fallback" 0 r.rc;
    let ctx = match parse_additional_context r with
      | Some s -> s
      | None -> Alcotest.fail "expected env-fallback to deliver message"
    in
    check bool "env fallback delivered message" true
      (string_contains ctx "msg-0-for-harness-malformed");
    check int "inbox drained via env fallback" 0 (json_list_length inbox))

let test_env_fallback_when_stdin_empty () =
  with_temp_dir (fun dir ->
    let sid = "harness-stdin-empty" in
    let inbox = seed_inbox ~dir ~sid 1 in
    let r = run_hook ~env:[Set ("C2C_MCP_SESSION_ID", sid);
                           Set ("C2C_SESSIONS_BROKER_ROOT", dir)]
                ~stdin_payload:"" () in
    check int "hook exits 0 via env fallback" 0 r.rc;
    let ctx = match parse_additional_context r with
      | Some s -> s
      | None -> Alcotest.fail "expected env-fallback to deliver message"
    in
    check bool "env fallback delivered message" true
      (string_contains ctx "msg-0-for-harness-stdin-empty");
    check int "inbox drained via env fallback" 0 (json_list_length inbox))

let test_no_session_id_anywhere_silent () =
  with_temp_dir (fun dir ->
    let payload = {|{"hook_event_name":"PostToolUse","tool_name":"Read"}|} in
    let r = run_hook ~env:[Unset "C2C_MCP_SESSION_ID";
                           Unset "C2C_MCP_BROKER_ROOT";
                           Set ("C2C_SESSIONS_BROKER_ROOT", dir)]
                ~stdin_payload:payload () in
    check int "fast-path exit 0" 0 r.rc;
    check bool "no stdout on fast path" true (String.trim r.stdout = "");
    check bool "no additionalContext" true (parse_additional_context r = None))

let test_session_id_at_start_of_large_payload_extracts () =
  with_temp_dir (fun dir ->
    let sid = "harness-large-start" in
    let inbox = seed_inbox ~dir ~sid 1 in
    (* Build a payload where `session_id` appears first and is followed
       by a 32 KiB `tool_response` field — well within the 64 KiB
       scan bound. The bounded scan should extract the session_id
       without ever parsing the rest. *)
    let pad_len = 32 * 1024 in
    let payload =
      Printf.sprintf {|{"session_id":%S,"tool_response":%S}|}
        sid (String.make pad_len 'x')
    in
    let r = run_hook ~env:[Set ("C2C_SESSIONS_BROKER_ROOT", dir)]
                ~stdin_payload:payload () in
    check int "hook exits 0" 0 r.rc;
    let ctx = match parse_additional_context r with
      | Some s -> s
      | None -> Alcotest.fail "expected message to be delivered"
    in
    check bool "large-payload delivered message" true
      (string_contains ctx "msg-0-for-harness-large-start");
    check int "inbox drained" 0 (json_list_length inbox))

let test_session_id_beyond_scan_bound_uses_env () =
  with_temp_dir (fun dir ->
    let sid = "harness-beyond-bound" in
    let inbox = seed_inbox ~dir ~sid 1 in
    (* Build a payload whose first 64 KiB contains a long junk field
       and whose session_id sits just past the bound. The bounded
       scan will give up before finding it; env fallback kicks in. *)
    let pad_len = 64 * 1024 in
    let pad = String.make pad_len 'y' in
    let payload =
      Printf.sprintf {|{"junk":%S,"session_id":%S}|}
        pad sid
    in
    check bool "payload exceeds bound" true
      (String.length payload > pad_len);
    let r = run_hook ~env:[Set ("C2C_MCP_SESSION_ID", sid);
                           Set ("C2C_SESSIONS_BROKER_ROOT", dir)]
                ~stdin_payload:payload () in
    check int "hook exits 0 via env fallback" 0 r.rc;
    let ctx = match parse_additional_context r with
      | Some s -> s
      | None -> Alcotest.fail "expected env-fallback to deliver"
    in
    check bool "beyond-bound delivered via env" true
      (string_contains ctx "msg-0-for-harness-beyond-bound");
    check int "inbox drained" 0 (json_list_length inbox))

let test_session_id_beyond_scan_bound_no_env_silent () =
  with_temp_dir (fun dir ->
    let sid = "harness-beyond-no-env" in
    (* Seed an inbox so we can verify the fast path leaves it intact.
       If the test never wrote the inbox, the "left alone" assertion
       is vacuously true and the regression value drops to zero. *)
    let inbox = seed_inbox ~dir ~sid 1 in
    check int "inbox pre-seeded with 1 message" 1 (json_list_length inbox);
    let pad_len = 64 * 1024 in
    let payload =
      Printf.sprintf {|{"junk":%S,"session_id":%S}|}
        (String.make pad_len 'z') sid
    in
    let r = run_hook ~env:[Unset "C2C_MCP_SESSION_ID";
                           Set ("C2C_SESSIONS_BROKER_ROOT", dir)]
                ~stdin_payload:payload () in
    check int "fast-path exit 0 when session unresolvable" 0 r.rc;
    check bool "no stdout on fast path" true (String.trim r.stdout = "");
    (* Fast path exits before drain — the inbox must remain unchanged. *)
    check bool "inbox still present" true (Sys.file_exists inbox);
    check int "inbox still has 1 message (drain never reached)" 1
      (json_list_length inbox))

let test_cold_boot_marker_persists_across_invocations () =
  with_temp_dir (fun global_dir ->
    with_temp_dir (fun repo_dir ->
      let sid = "harness-cold-boot" in
      let alias = "harness-agent" in
      let broker = C2c_mcp.Broker.create ~root:repo_dir in
      C2c_mcp.Broker.register broker ~session_id:sid ~alias ~pid:None
        ~pid_start_time:None ();
      let inbox = seed_inbox ~dir:global_dir ~sid 1 in
      let payload = Printf.sprintf {|{"session_id":%S}|} sid in
      (* First call: drains message + emits cold-boot context + writes marker. *)
      let r1 = run_hook ~env:[Set ("C2C_MCP_SESSION_ID", sid);
                              Set ("C2C_MCP_BROKER_ROOT", repo_dir);
                              Set ("C2C_SESSIONS_BROKER_ROOT", global_dir)]
                   ~stdin_payload:payload () in
      check int "first call exits 0" 0 r1.rc;
      let ctx1 = match parse_additional_context r1 with
        | Some s -> s
        | None -> Alcotest.fail "first call should emit additionalContext"
      in
      check bool "first call has message" true
        (string_contains ctx1 "msg-0-for-harness-cold-boot");
      check bool "first call has cold-boot ctx" true
        (string_contains ctx1 {|kind="cold-boot"|});
      let marker =
        Filename.concat (Filename.concat repo_dir ".cold_boot_done") sid
      in
      check bool "marker file written" true (Sys.file_exists marker);
      (* Second call: re-seed inbox (was drained), no cold-boot ctx this time. *)
      let _ = seed_inbox ~dir:global_dir ~sid 1 in
      let r2 = run_hook ~env:[Set ("C2C_MCP_SESSION_ID", sid);
                              Set ("C2C_MCP_BROKER_ROOT", repo_dir);
                              Set ("C2C_SESSIONS_BROKER_ROOT", global_dir)]
                   ~stdin_payload:payload () in
      check int "second call exits 0" 0 r2.rc;
      let ctx2 = match parse_additional_context r2 with
        | Some s -> s
        | None -> Alcotest.fail "second call should emit additionalContext"
      in
      check bool "second call still has message" true
        (string_contains ctx2 "msg-0-for-harness-cold-boot");
      check bool "second call has no cold-boot ctx" false
        (string_contains ctx2 {|kind="cold-boot"|});
      check int "inbox drained on second call" 0
        (json_list_length inbox)))

(* ------------------------------------------------------------------ *)
(* Speed harness                                                       *)
(* ------------------------------------------------------------------ *)

(* K iterations is small enough to keep the dune test under ~10s on
   this machine but large enough to get a stable median. *)
let speed_iterations = 50

(* Strict-mode upper bound. Documented rationale: the probe run
   measured min=14ms / median=21.5ms / max=79ms for K=50. We pick
   250ms for median — roughly 10x measured median — to absorb:
     * 2-3x slowdowns on a contended CI runner,
     * the cost of the `env` wrapper + shell parsing (we use
       `/bin/sh -c` indirectly via `Sys.command`),
     * the dune sandbox + tmpfs variance on shared hardware.
   Median is used (not max) because post-tool-use latency is what
   the agent experiences per call, and one slow outlier shouldn't
   flap CI. *)
let speed_median_ceiling_ms = 250.0

let speed_strict () =
  match Sys.getenv_opt "C2C_HOOK_SPEED_STRICT" with
  | Some v ->
      let v = String.trim (String.lowercase_ascii v) in
      v = "1" || v = "true" || v = "yes" || v = "on"
  | None -> false

let median_of_sorted sorted =
  let n = List.length sorted in
  if n = 0 then 0.0
  else if n mod 2 = 1 then
    List.nth sorted (n / 2)
  else
    let a = List.nth sorted (n / 2 - 1) in
    let b = List.nth sorted (n / 2) in
    (a +. b) /. 2.0

let time_hook_invocations ~n_messages () : float list =
  with_temp_dir (fun dir ->
    let sid = "harness-speed" in
    let payload = Printf.sprintf {|{"session_id":%S}|} sid in
    (* Explicitly UNSET repo-broker + session-id env so a stray
       parent env can't influence the synthetic speed path. The
       behavior is benign (the "harness-speed" session won't be in
       any real broker) but we want symmetry with the correctness
       harness and bit-identical numbers across CI hosts. *)
    let env = [ Unset "C2C_MCP_BROKER_ROOT"
              ; Unset "C2C_MCP_SESSION_ID"
              ; Set ("C2C_SESSIONS_BROKER_ROOT", dir)
              ] in
    let results = ref [] in
    for _i = 1 to speed_iterations do
      (* Re-seed the inbox between iterations; the hook drains
         destructively, so without re-seeding iteration N>1 would
         short-circuit on the empty-inbox fast path and skew the
         numbers. *)
      let _ = seed_inbox ~dir ~sid n_messages in
      let r = run_hook ~env ~stdin_payload:payload () in
      results := r.elapsed_ms :: !results
    done;
    List.rev !results)

let speed_check ~name ~n_messages =
  let timings = time_hook_invocations ~n_messages () in
  let sorted = List.sort compare timings in
  let min_ms = List.hd sorted in
  let max_ms = List.hd (List.rev sorted) in
  let med_ms = median_of_sorted sorted in
  let line =
    Printf.sprintf
      "[hook-speed:%s] K=%d min=%.1fms median=%.1fms max=%.1fms (n_messages=%d)"
      name (List.length sorted) min_ms med_ms max_ms n_messages
  in
  Printf.eprintf "%s\n%!" line;
  (* Persist timings to a per-run report file so the numbers are
     available for review (e.g. when investigating a slowdown) even
     on a green run. Alcotest captures stdout/stderr per-test, so
     the per-test output file is the canonical "report". The
     /tmp summary is a redundant convenience. *)
  let report_path =
    Printf.sprintf "/tmp/c2c-hook-harness-speed-%d.txt" (Unix.getpid ())
  in
  (try
     let oc = open_out_gen [Open_wronly; Open_creat; Open_append] 0o644
       report_path in
     output_string oc (line ^ "\n");
     close_out oc
   with _ -> ());
  let name_msg = Printf.sprintf "%s median within ceiling" name in
  if speed_strict () then
    Alcotest.(check bool) name_msg true (med_ms < speed_median_ceiling_ms)
  else
    (* In non-strict mode we still want a non-flapping check: only
       fail if the median is wildly off (10x ceiling). The point is
       to catch obvious regressions, not slow CI. *)
    Alcotest.(check bool) (name_msg ^ " (lenient)") true
      (med_ms < 10.0 *. speed_median_ceiling_ms)

let test_speed_median_one_message () = speed_check ~name:"one_message" ~n_messages:1
let test_speed_median_empty_inbox () = speed_check ~name:"empty_inbox" ~n_messages:0

(* ------------------------------------------------------------------ *)
(* Test runner                                                         *)
(* ------------------------------------------------------------------ *)

let () =
  let strict = speed_strict () in
  let speed_label =
    if strict then "speed-strict (C2C_HOOK_SPEED_STRICT=1)"
    else "speed-record-only (set C2C_HOOK_SPEED_STRICT=1 to assert)"
  in
  Alcotest.run "inbox_hook_harness"
    [ ( "correctness",
        [ ( "drains single message + destructive drain", `Quick,
            test_drains_single_message_and_destructive_drain )
        ; ( "drains multiple messages in one call", `Quick,
            test_drains_multiple_messages_in_one_call )
        ; ( "empty inbox emits no output", `Quick,
            test_empty_inbox_emits_no_output )
        ; ( "env fallback when stdin JSON is malformed", `Quick,
            test_env_fallback_when_stdin_malformed )
        ; ( "env fallback when stdin is empty", `Quick,
            test_env_fallback_when_stdin_empty )
        ; ( "no session_id anywhere -> fast-path exit 0", `Quick,
            test_no_session_id_anywhere_silent )
        ; ( "session_id at start of 64KiB-ok payload extracts", `Quick,
            test_session_id_at_start_of_large_payload_extracts )
        ; ( "session_id beyond 64KiB scan bound uses env", `Quick,
            test_session_id_beyond_scan_bound_uses_env )
        ; ( "session_id beyond 64KiB with no env -> fast-path", `Quick,
            test_session_id_beyond_scan_bound_no_env_silent )
        ; ( "cold-boot marker persists across invocations", `Quick,
            test_cold_boot_marker_persists_across_invocations )
        ] )
    ; ( "speed",
        [ ( "median latency -- one queued message -- " ^ speed_label, `Slow,
            test_speed_median_one_message )
        ; ( "median latency -- empty inbox -- " ^ speed_label, `Slow,
            test_speed_median_empty_inbox )
        ] )
    ]
