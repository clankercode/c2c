(* Focused tests for C2c_t3_client: pure decoders, PKCE, runtime discovery on a
   fake /proc tree, private credential files, and the bounded MCP transport
   against an in-process loopback fixture server. *)
open Lwt.Infix
module T = C2c_t3_client

let ok = function Ok v -> v | Error e -> Alcotest.failf "unexpected error: %s" (T.error_to_string e)
let is_err pred = function Error e -> pred e | Ok _ -> false
let check_err name pred r = Alcotest.(check bool) name true (is_err pred r)
let contains ~sub s =
  let n = String.length sub and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = sub || go (i + 1)) in
  go 0

let tmpdir () =
  let d = Filename.temp_file "t3c" "" in
  Sys.remove d; Unix.mkdir d 0o700; d

let write ?(perm = 0o600) path content =
  let rec mk d = if not (Sys.file_exists d) then (mk (Filename.dirname d); Unix.mkdir d 0o700) in
  mk (Filename.dirname path);
  let oc = open_out_gen [ Open_wronly; Open_creat; Open_trunc ] perm path in
  output_string oc content; close_out oc; Unix.chmod path perm

(* ---- pure decoding ---- *)

let rpc ?(ct = "application/json") body = T.parse_rpc ~max_bytes:65536 ~content_type:ct ~id:1 body

let test_json_sse () =
  Alcotest.(check bool) "json" true
    (ok (rpc {|{"jsonrpc":"2.0","id":1,"result":{"a":1}}|}) = `Assoc [ ("a", `Int 1) ]);
  let sse = "event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"n\"}\r\n\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\r\n\r\n" in
  Alcotest.(check bool) "sse ignores notifications" true
    (ok (rpc ~ct:"text/event-stream; charset=utf-8" sse) = `Assoc []);
  Alcotest.(check bool) "multi-line data joins" true
    (ok (rpc ~ct:"text/event-stream" "data: {\"jsonrpc\":\"2.0\",\ndata: \"id\":1,\"result\":null}\n\n") = `Null)

let test_malformed () =
  let proto = function T.Protocol _ -> true | _ -> false in
  check_err "unterminated sse" proto (rpc ~ct:"text/event-stream" "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n");
  check_err "no terminator at all" proto (rpc ~ct:"text/event-stream" "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}");
  check_err "bad content type" proto (rpc ~ct:"text/plain" "{}");
  check_err "two matches" proto (rpc ~ct:"text/event-stream" "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":1}\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":2}\n\n");
  check_err "no match" proto (rpc {|{"jsonrpc":"2.0","id":2,"result":{}}|});
  check_err "wrong jsonrpc" proto (rpc {|{"jsonrpc":"1.0","id":1,"result":{}}|});
  check_err "result and error" proto (rpc {|{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":1}}|});
  check_err "truncated json" proto (rpc {|{"jsonrpc":"2.0","id":1,"res|});
  check_err "NaN" proto (rpc {|{"jsonrpc":"2.0","id":1,"result":NaN}|});
  check_err "duplicate keys" proto (rpc {|{"jsonrpc":"2.0","id":1,"result":{"a":1,"a":2}}|});
  check_err "trailing garbage" proto (rpc {|{"jsonrpc":"2.0","id":1,"result":{}} x|});
  check_err "rpc error" (function T.Rpc_error (-32601) -> true | _ -> false)
    (rpc {|{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"secret"}}|});
  check_err "oversize" (function T.Oversize _ -> true | _ -> false)
    (T.parse_rpc ~max_bytes:10 ~content_type:"application/json" ~id:1 {|{"jsonrpc":"2.0","id":1,"result":{}}|})

let test_pkce () =
  (* RFC 7636 appendix B *)
  Alcotest.(check string) "S256 vector" "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    (T.pkce_challenge "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk");
  let v = T.pkce_verifier () in
  Alcotest.(check int) "verifier length" 43 (String.length v);
  Alcotest.(check bool) "fresh" true (v <> T.pkce_verifier ())

let test_group () =
  let passwd = "max:x:1000:1000::/home/max:/bin/sh\nother:x:1001:1001::/h:/bin/sh\n" in
  let excl g = T.is_exclusive_user_group ~group_row:g ~passwd_rows:passwd ~username:"max" ~uid:1000 ~gid:1000 in
  Alcotest.(check bool) "private group" true (excl "max:x:1000:");
  Alcotest.(check bool) "extra member" false (excl "max:x:1000:other");
  Alcotest.(check bool) "wrong name" false (excl "staff:x:1000:");
  Alcotest.(check bool) "shared primary" false
    (T.is_exclusive_user_group ~group_row:"max:x:1000:" ~username:"max" ~uid:1000 ~gid:1000
       ~passwd_rows:(passwd ^ "x:x:1002:1000::/h:/bin/sh\n"))

let test_resolve_home () =
  let env l k = List.assoc_opt k l in
  Alcotest.(check string) "T3CODE_HOME wins" "/x/t3"
    (ok (T.resolve_home ~getenv:(env [ ("T3CODE_HOME", "/x/t3"); ("HOME", "/h") ]) ()));
  Alcotest.(check string) "HOME fallback" "/h/.t3" (ok (T.resolve_home ~getenv:(env [ ("HOME", "/h") ]) ()));
  check_err "relative refused" (function T.Discovery _ -> true | _ -> false)
    (T.resolve_home ~getenv:(env [ ("T3CODE_HOME", "rel") ]) ());
  check_err "none" (function T.Discovery _ -> true | _ -> false) (T.resolve_home ~getenv:(fun _ -> None) ())

(* ---- discovery on a fake /proc ---- *)

let port = 3773
let pid = 4242

type fx = { home : string; proc : string; record : string }

let make_fx ?(rel = "userdata") ?(listener = true) ?(status_stream = false)
    ?(started_at = "1970-01-01T00:16:42Z")
    ?(origin = Printf.sprintf "http://127.0.0.1:%d" port) () =
  let root = tmpdir () in
  let home = Filename.concat root "home" and proc = Filename.concat root "proc" in
  let record = Filename.concat (Filename.concat home rel) "server-runtime.json" in
  write record (Printf.sprintf {|{"origin":"%s","port":%d,"pid":%d,"startedAt":"%s","version":"0.1.0"}|} origin port pid started_at);
  Unix.chmod home 0o700;
  Unix.chmod (Filename.dirname record) 0o700;
  let p = Filename.concat proc (string_of_int pid) in
  write (Filename.concat proc "stat") "cpu 1\nbtime 1000\n";
  write (Filename.concat proc "sys/kernel/random/boot_id") "boot-1\n";
  let status = Filename.concat p "status" in
  if status_stream then (
    Unix.mkdir p 0o700;
    Unix.mkfifo status 0o600
  )
  else write status (Printf.sprintf "Name:\tt3\nTgid:\t%d\n" pid);
  write (Filename.concat p "stat") (Printf.sprintf "%d (t3 server) S %s\n" pid (String.concat " " (List.init 19 (fun _ -> "0") @ [ "100" ])));
  Unix.mkdir (Filename.concat p "fd") 0o700;
  Unix.symlink "socket:[555]" (Filename.concat p "fd/3");
  write (Filename.concat p "exe-target") "bin";
  Unix.symlink (Filename.concat p "exe-target") (Filename.concat p "exe");
  write
    (Filename.concat p "net/tcp")
    (Printf.sprintf
       "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   0: 0100007F:%04X 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 %d 1 0\n"
       port (if listener then 555 else 999));
  { home; proc; record }

let discover ?(now = 1100.) fx = T.discover ~proc_root:fx.proc ~now ~t3_home:fx.home ()

let test_discovery_ok () =
  let fx = make_fx () in
  let rt = ok (discover fx) in
  Alcotest.(check string) "origin" "http://127.0.0.1:3773" rt.T.origin;
  Alcotest.(check int) "pid" pid rt.T.pid;
  Alcotest.(check (list string)) "listener" [ "555" ] rt.T.proof.T.listeners;
  Alcotest.(check bool) "dev record" true (ok (discover (make_fx ~rel:"dev" ())) |> fun r -> r.T.pid = pid)

let test_discovery_procfs_stream () =
  (* A FIFO models procfs' stream-like files: [in_channel_length] cannot be
     used, while [input] still returns the complete status document. *)
  let fx = make_fx ~status_stream:true () in
  let status = Filename.concat (Filename.concat fx.proc (string_of_int pid)) "status" in
  let writer = Unix.fork () in
  if writer = 0 then (
    try
      let oc = open_out_bin status in
      output_string oc (Printf.sprintf "Name:\tt3\nTgid:\t%d\n" pid);
      close_out oc;
      exit 0
    with _ -> exit 1)
  else
    let result = discover fx in
    let _, process_status = Unix.waitpid [] writer in
    (match process_status with
    | Unix.WEXITED 0 -> ()
    | _ -> Alcotest.fail "proc-like status writer failed");
    let rt = ok result in
    Alcotest.(check int) "stream status still proves pid" pid rt.T.pid

let test_discovery_refusals () =
  let any_err = function _ -> true in
  ignore any_err;
  check_err "listener not owned" (function T.Discovery _ -> true | _ -> false) (discover (make_fx ~listener:false ()));
  check_err "stale pid" (function T.Discovery _ -> true | _ -> false)
    (let fx = make_fx () in
     ignore (Sys.command ("/usr/bin/rm -r " ^ Filename.quote (Filename.concat fx.proc (string_of_int pid))));
     discover fx);
  check_err "incarnation mismatch" (function T.Discovery _ -> true | _ -> false)
    (discover (make_fx ~started_at:"1970-01-01T01:00:00Z" ()));
  check_err "non-loopback origin" (function T.Discovery _ -> true | _ -> false)
    (discover (make_fx ~origin:"http://192.168.1.2:3773" ()));
  check_err "https origin" (function T.Discovery _ -> true | _ -> false)
    (discover (make_fx ~origin:"https://127.0.0.1:3773" ()));
  let fx = make_fx () in
  Unix.chmod fx.record 0o666;
  check_err "world-writable record" (function T.Discovery _ -> true | _ -> false) (discover fx);
  let fx = make_fx () in
  Unix.chmod fx.record 0o660;
  check_err "group-writable, no group db" (function T.Discovery _ -> true | _ -> false)
    (T.discover ~proc_root:fx.proc ~now:1100. ~group_file:"/nonexistent" ~passwd_file:"/nonexistent" ~t3_home:fx.home ());
  check_err "missing home" (function T.Discovery _ -> true | _ -> false)
    (T.discover ~t3_home:"/nonexistent/t3-home" ())

let test_discovery_ambiguous () =
  let fx = make_fx () in
  let dev = Filename.concat fx.home "dev/server-runtime.json" in
  write dev (let ic = open_in fx.record in let s = really_input_string ic (in_channel_length ic) in close_in ic; s);
  Unix.chmod (Filename.dirname dev) 0o700;
  check_err "both live" (function T.Ambiguous [ _; _ ] -> true | _ -> false) (discover fx);
  (* A stale dev record next to a live production record is not ambiguous. *)
  write dev {|{"origin":"http://127.0.0.1:1","port":1,"pid":99999,"startedAt":"1970-01-01T00:16:42Z"}|};
  Alcotest.(check int) "stale dev ignored" pid (ok (discover fx)).T.pid

(* ---- credentials ---- *)

let proof = { T.pid; start_ticks = 100; boot_id = "boot-1"; listeners = [ "555" ]; exe_dev = 1; exe_ino = 2 }
let token = "tok-SECRET-123"

let cred ?(scopes = T.required_scopes) ?(generation = 1) origin =
  T.make_credential ~origin ~t3_home:"/h" ~token ~client_id:"cid" ~scopes ~generation ~issued_at:"2026-01-01T00:00:00Z" ~expires_in:(Some 60) ~proof

let test_credential_files () =
  let dir = Filename.concat (tmpdir ()) "cfg" in
  let c = cred "http://127.0.0.1:3773" in
  ok (T.save_credential ~config_dir:dir ~replace:false c);
  let path = T.credential_path ~config_dir:dir in
  Alcotest.(check int) "mode 0600" 0o600 ((Unix.stat path).Unix.st_perm land 0o777);
  Alcotest.(check int) "dir mode 0700" 0o700 ((Unix.stat dir).Unix.st_perm land 0o777);
  check_err "no-replace refuses" (function T.Credential _ -> true | _ -> false) (T.save_credential ~config_dir:dir ~replace:false c);
  ok (T.save_credential ~config_dir:dir ~replace:true (cred ~generation:2 "http://127.0.0.1:3773"));
  let l = ok (T.load_credential ~config_dir:dir) in
  Alcotest.(check int) "generation" 2 (T.credential_generation l);
  Alcotest.(check bool) "proof roundtrip" true (T.credential_proof l = proof);
  Alcotest.(check (list string)) "no stray temp files" [ "credential.json" ] (Array.to_list (Sys.readdir dir));
  Unix.chmod path 0o640;
  check_err "group-readable refused" (function T.Unsafe_state _ -> true | _ -> false) (T.load_credential ~config_dir:dir);
  Unix.chmod path 0o600;
  Unix.chmod dir 0o755;
  check_err "open dir refused on save" (function T.Unsafe_state _ -> true | _ -> false) (T.save_credential ~config_dir:dir ~replace:true c);
  check_err "missing" (function T.Credential _ -> true | _ -> false) (T.load_credential ~config_dir:"/nonexistent/c2c-t3")

(* ---- bounded MCP transport against an in-process server ---- *)

type fixture = {
  mutable requests : int;
  mutable sessions : string list;
  mutable auth_ok : bool;
  mutable behaviour : [ `Normal | `Redirect | `Deny | `Slow | `Big | `Missing_tool | `Bad_protocol ];
}

let tools =
  [ "orchestrator_capabilities"; "t3_project_list"; "t3_thread_list"; "t3_thread_read"; "t3_thread_send"; "t3_queue_list"; "t3_environment_read" ]

let reply id result = Yojson.Safe.to_string (`Assoc [ ("jsonrpc", `String "2.0"); ("id", `Int id); ("result", result) ])
let tool_result s = `Assoc [ ("structuredContent", s) ]

let handle fx name args =
  match name with
  | "orchestrator_capabilities" ->
      tool_result (`Assoc [ ("runtimeMode", `String "auto");
        ("providers", `List [ `Assoc [ ("providerInstanceId", `String "p1"); ("driverKind", `String "codex"); ("models", `List [ `Assoc [ ("id", `String "m") ] ]) ]; `Assoc [ ("models", `List []) ] ]) ])
  | "t3_project_list" ->
      let next = match Yojson.Safe.Util.member "cursor" args with `Int _ -> `Null | _ -> `Int 1 in
      tool_result (`Assoc [ ("projects", `List [ `Assoc [ ("id", `String "a") ] ]); ("nextCursor", next) ])
  | "t3_thread_list" -> tool_result (`Assoc [ ("threads", `List []); ("nextCursor", `Null) ])
  | "t3_thread_read" ->
      tool_result (`Assoc [ ("thread", `Assoc [ ("threadId", `String "t1"); ("activeRunId", `Null); ("parentThreadId", `Null) ]);
        ("items", `List [ `Assoc [ ("itemId", `String "i"); ("textTruncated", `Bool true) ] ]);
        ("recentRuns", `List [ `Assoc [ ("runId", `String "r1"); ("status", `String "failed") ] ]); ("hasMore", `Bool false) ])
  | "t3_queue_list" -> tool_result (`Assoc [ ("items", `List [ `Assoc [ ("queuedRunId", `String "q1"); ("text", `String "PRIVATE") ] ]); ("nextCursor", `Null) ])
  | "t3_thread_send" ->
      let tid = match Yojson.Safe.Util.member "threadId" args with `String s -> s | _ -> "" in
      if tid = "full" then
        `Assoc [ ("isError", `Bool true); ("content", `List [ `Assoc [ ("type", `String "text"); ("text", `String {|{"code":"runtime_mode_escalation_denied","detail":"tok-SECRET-123"}|}) ] ]) ]
      else tool_result (`Assoc [ ("threadId", `String tid); ("messageId", `String "m1"); ("runId", `String "r2") ])
  | _ -> ignore fx; `Assoc [ ("isError", `Bool true) ]

let callback fx _conn req body =
  fx.requests <- fx.requests + 1;
  (match Cohttp.Header.get (Cohttp.Request.headers req) "mcp-session-id" with Some s -> fx.sessions <- s :: fx.sessions | None -> ());
  let json_hdr = Cohttp.Header.of_list [ ("content-type", "application/json"); ("mcp-session-id", "sess-1") ] in
  Cohttp_lwt.Body.to_string body >>= fun b ->
  let j = Yojson.Safe.from_string b in
  let meth = match Yojson.Safe.Util.member "method" j with `String s -> s | _ -> "" in
  let id = match Yojson.Safe.Util.member "id" j with `Int i -> i | _ -> 0 in
  let params = Yojson.Safe.Util.member "params" j in
  match fx.behaviour with
  | `Redirect -> Cohttp_lwt_unix.Server.respond_redirect ~uri:(Uri.of_string "http://127.0.0.1:1/") ()
  | `Deny -> Cohttp_lwt_unix.Server.respond_string ~status:`Unauthorized ~body:"bad token tok-SECRET-123" ()
  | `Slow -> Lwt_unix.sleep 2. >>= fun () -> Cohttp_lwt_unix.Server.respond_string ~status:`OK ~headers:json_hdr ~body:(reply id (`Assoc [])) ()
  | `Big -> Cohttp_lwt_unix.Server.respond_string ~status:`OK ~headers:json_hdr ~body:(String.make 100_000 'x') ()
  | _ -> (
      match meth with
      | "initialize" ->
          let v = if fx.behaviour = `Bad_protocol then "1999-01-01" else T.protocol_version in
          Cohttp_lwt_unix.Server.respond_string ~status:`OK ~headers:json_hdr ~body:(reply id (`Assoc [ ("protocolVersion", `String v) ])) ()
      | "notifications/initialized" -> Cohttp_lwt_unix.Server.respond_string ~status:`Accepted ~body:"" ()
      | "tools/list" ->
          let names = if fx.behaviour = `Missing_tool then List.tl tools else tools in
          let body = "event: message\ndata: " ^ reply id (`Assoc [ ("tools", `List (List.map (fun n -> `Assoc [ ("name", `String n) ]) names)) ]) ^ "\n\n" in
          Cohttp_lwt_unix.Server.respond_string ~status:`OK ~headers:(Cohttp.Header.of_list [ ("content-type", "text/event-stream") ]) ~body ()
      | "tools/call" ->
          let name = match Yojson.Safe.Util.member "name" params with `String s -> s | _ -> "" in
          Cohttp_lwt_unix.Server.respond_string ~status:`OK ~headers:json_hdr
            ~body:(reply id (handle fx name (Yojson.Safe.Util.member "arguments" params))) ()
      | _ -> Cohttp_lwt_unix.Server.respond_string ~status:`Not_found ~body:"" ())

let free_port () =
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind s (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let p = match Unix.getsockname s with Unix.ADDR_INET (_, p) -> p | _ -> 0 in
  Unix.close s; p

let with_fixture ?(limits = T.default_limits) ?(validate = fun () -> Ok ()) behaviour f =
  let fx = { requests = 0; sessions = []; auth_ok = true; behaviour } in
  let p = free_port () in
  let stop, wake = Lwt.wait () in
  Lwt.async (fun () ->
      Cohttp_lwt_unix.Server.create ~stop ~mode:(`TCP (`Port p)) (Cohttp_lwt_unix.Server.make ~callback:(callback fx) ()));
  let origin = Printf.sprintf "http://127.0.0.1:%d" p in
  let client = T.create ~limits ~origin ~credential:(cred origin) ~validate () in
  Lwt_main.run
    ( Lwt_unix.sleep 0.1 >>= fun () ->
      Lwt.finalize (fun () -> f fx client) (fun () -> Lwt.wakeup wake (); Lwt.return_unit) )

let test_happy_path () =
  with_fixture `Normal (fun fx c ->
      T.initialize c >>= fun r -> ok r;
      Alcotest.(check int) "epoch" 1 (T.transport_epoch c);
      T.capabilities c >>= fun caps ->
      let caps = ok caps in
      Alcotest.(check bool) "auto ceiling" true (caps.T.runtime_mode = T.Known "auto");
      Alcotest.(check bool) "omitted interaction mode stays unknown" true (caps.T.interaction_mode = T.Unknown);
      (match caps.T.providers with
      | [ a; b ] ->
          Alcotest.(check bool) "driver" true (a.T.driver_kind = T.Known "codex");
          Alcotest.(check bool) "omitted driver unknown" true (b.T.driver_kind = T.Unknown)
      | _ -> Alcotest.fail "providers");
      Alcotest.(check bool) "session header reused" true (List.mem "sess-1" fx.sessions);
      T.list_projects c >>= fun p ->
      Alcotest.(check int) "two pages aggregated" 2 (List.length (ok p).T.items);
      Alcotest.(check bool) "complete" true (ok p).T.complete;
      T.read_activity c ~thread_id:"t1" () >>= fun a ->
      let a = ok a in
      Alcotest.(check bool) "complete" true a.T.complete;
      Alcotest.(check bool) "text truncation surfaced" true a.T.text_truncated;
      Alcotest.(check bool) "active run null known" true (a.T.active_run_id = T.Known None);
      Alcotest.(check bool) "mode omitted unknown" true (a.T.runtime_mode = T.Unknown);
      T.list_queue c ~thread_id:"t1" >>= fun q ->
      Alcotest.(check (list string)) "queue ids only" [ "q1" ] (ok q).T.queued_run_ids;
      T.send_message c ~thread_id:"t1" ~message:"hi" ~mode:`Auto ~client_request_id:"req" >>= fun s ->
      Alcotest.(check string) "message id" "m1" (ok s).T.message_id;
      T.send_message c ~thread_id:"full" ~message:"hi" ~mode:`Auto ~client_request_id:"req2" >>= fun s ->
      (match s with
      | Error (T.Tool_rejected { code = "runtime_mode_escalation_denied"; _ } as e) ->
          Alcotest.(check bool) "no secret in tool error" false (contains ~sub:token (T.error_to_string e))
      | _ -> Alcotest.fail "expected escalation denial");
      (* Reconnect reinitializes transport with the same credential. *)
      T.reconnect c >|= fun r -> ok r;
      Alcotest.(check int) "epoch bumped" 2 (T.transport_epoch c);
      Alcotest.(check int) "same generation" 1 (T.credential_generation_of c))

let test_paging_bound () =
  with_fixture ~limits:{ T.default_limits with max_pages = 1 } `Normal (fun _ c ->
      T.initialize c >>= fun r -> ok r;
      T.list_projects c >|= fun p ->
      Alcotest.(check bool) "incomplete, not success-as-complete" false (ok p).T.complete)

let test_redirect () =
  with_fixture `Redirect (fun _ c ->
      T.initialize c >|= check_err "redirect refused" (function T.Redirect_refused 302 -> true | _ -> false))

let test_auth_denied () =
  with_fixture `Deny (fun fx c ->
      T.initialize c >>= fun r ->
      check_err "auth denied" T.is_auth_error r;
      (match r with Error e -> Alcotest.(check bool) "no token in error" false (contains ~sub:token (T.error_to_string e)) | Ok _ -> ());
      let before = fx.requests in
      T.reconnect c >|= fun r ->
      check_err "reconnect refused after revocation" T.is_auth_error r;
      Alcotest.(check int) "no hammering" before fx.requests)

let test_validate_blocks_send () =
  let changed = ref false in
  with_fixture ~validate:(fun () -> if !changed then Error (T.Runtime_changed "pid replaced") else Ok ()) `Normal (fun fx c ->
      T.initialize c >>= fun r -> ok r;
      changed := true;
      let before = fx.requests in
      T.capabilities c >|= fun r ->
      check_err "stale incarnation" (function T.Runtime_changed _ -> true | _ -> false) r;
      Alcotest.(check int) "nothing sent to a replaced endpoint" before fx.requests)

let test_limits () =
  with_fixture ~limits:{ T.default_limits with max_response_bytes = 1000 } `Big (fun _ c ->
      T.initialize c >|= check_err "oversize" (function T.Oversize _ -> true | _ -> false))

let test_timeout () =
  with_fixture ~limits:{ T.default_limits with request_timeout_s = 0.2 } `Slow (fun _ c ->
      T.initialize c >|= check_err "timeout" (function T.Timeout _ -> true | _ -> false))

let test_server_shape () =
  with_fixture `Missing_tool (fun _ c ->
      T.initialize c >|= check_err "missing required tool" (function T.Unsupported _ -> true | _ -> false))
  |> fun () ->
  with_fixture `Bad_protocol (fun _ c ->
      T.initialize c >|= check_err "wrong protocol" (function T.Unsupported _ -> true | _ -> false))

let test_allowlist () =
  Alcotest.(check bool) "no settings/source-control tools" true
    (List.for_all (fun t -> not (contains ~sub:"settings" t || contains ~sub:"source" t)) T.supported_tools);
  Alcotest.(check (list string)) "scopes" [ "orchestration:operate"; "orchestration:read" ] T.required_scopes

let () =
  Alcotest.run "c2c_t3_client"
    [ ( "decode", [ Alcotest.test_case "json+sse" `Quick test_json_sse; Alcotest.test_case "malformed" `Quick test_malformed ] );
      ( "pure", [ Alcotest.test_case "pkce" `Quick test_pkce; Alcotest.test_case "group" `Quick test_group;
                  Alcotest.test_case "home" `Quick test_resolve_home; Alcotest.test_case "allowlist" `Quick test_allowlist ] );
      ( "discovery", [ Alcotest.test_case "ok" `Quick test_discovery_ok;
                       Alcotest.test_case "proc-like stream" `Quick test_discovery_procfs_stream;
                       Alcotest.test_case "refusals" `Quick test_discovery_refusals;
                       Alcotest.test_case "ambiguous" `Quick test_discovery_ambiguous ] );
      ( "credential", [ Alcotest.test_case "private files" `Quick test_credential_files ] );
      ( "transport", [ Alcotest.test_case "happy path + reconnect" `Quick test_happy_path;
                       Alcotest.test_case "paging bound" `Quick test_paging_bound;
                       Alcotest.test_case "redirect" `Quick test_redirect;
                       Alcotest.test_case "auth denied" `Quick test_auth_denied;
                       Alcotest.test_case "validate before send" `Quick test_validate_blocks_send;
                       Alcotest.test_case "oversize" `Quick test_limits;
                       Alcotest.test_case "timeout" `Quick test_timeout;
                       Alcotest.test_case "server shape" `Quick test_server_shape ] ) ]
