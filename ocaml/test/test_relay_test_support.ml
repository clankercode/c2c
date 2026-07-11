(* test_relay_test_support — F5a (friction-cn): self-tests pinning the
   shared loopback relay HTTP/fault test support.
   Rows B075/B082-B086/B192/B236; C024/C056.

   Coverage:
   - lifecycle: repeated start/stop without port/process leaks, idempotent
     stop, child actually reaped (waitpid after stop -> ECHILD), stopped
     port refuses connections;
   - scripted responses: per-route status codes (401/429/500/503), default
     fallback, per-route response sequencing (429 then 200; last repeats);
   - fault modes observable by a real HTTP client: delay -> client
     timeout, truncated body (headers complete, body short of
     Content-Length, unparseable as JSON), malformed JSON (valid HTTP,
     invalid body), connection refused via closed_port,
     close-without-response;
   - request capture: method/path/headers/body recorded, query stripped
     for routing, ordering preserved;
   - real-handler bracket (Relay_test_support_real): production
     Relay_server(InMemoryRelay) served in-process — /health answers ok,
     /list reflects backend registrations.

   F5c adds two groups (appended AFTER the F5a groups):
   - schema-mismatch faults: the relay answers with well-formed HTTP +
     well-formed JSON that does NOT match the expected response schema
     (wrong-typed fields, missing required keys, non-object documents) and
     the c2c client paths (Relay.Relay_client, C2c_relay_connector,
     Relay_state, Relay_client_hints) must fail honestly — error result /
     recorded sync error / nonzero exit — never an uncaught crash, never
     garbage-as-success. Rows B093/B095/B120/B232/B238/B249; C024/C056.
   - fake/real equality: the SAME semantic request vectors issued to the
     scripted server (serving hand-written canned fixtures) and to the
     production Relay_server(InMemoryRelay) yield equal responses after
     normalizing nondeterministic fields — pinning that the F5a/F5b fake
     is faithful where it claims to be.

   ORDERING NOTE: the fork-based F5a Relay_test_support cases run FIRST
   and the Lwt-based cases run after them, so no Lwt engine state precedes
   the pure-fork cases. The F5c groups (last) interleave forked scripted
   servers with Lwt-based clients (Relay_client / connector / real
   handler); that is safe with this harness because the forked child never
   touches the inherited Lwt engine — it runs the pure-Unix serve loop and
   leaves via [Unix._exit] (no at_exit, no Lwt teardown), so any engine
   state inherited across the fork is inert in the child. *)

open Alcotest
module S = Relay_test_support
module Real = Relay_test_support_real

let ok_body = {|{"ok":true,"src":"f5a"}|}

let fail_result name = function
  | S.Http { S.code; _ } ->
      fail (Printf.sprintf "%s: unexpected Http %d" name code)
  | S.Refused -> fail (name ^ ": unexpected Refused")
  | S.Timeout -> fail (name ^ ": unexpected Timeout")
  | S.No_response -> fail (name ^ ": unexpected No_response")
  | S.Bad_response raw ->
      fail (Printf.sprintf "%s: unexpected Bad_response %S" name raw)

(* --- lifecycle ---------------------------------------------------------- *)

let test_lifecycle_repeated () =
  for i = 1 to 5 do
    let t = S.start ~default:(S.response ok_body) () in
    (match S.http_request ~port:t.S.port ~path:"/probe" () with
     | S.Http { S.code; body_text; body_complete; _ } ->
         check int (Printf.sprintf "iteration %d: 200" i) 200 code;
         check string "canned body served" ok_body body_text;
         check bool "body complete" true body_complete
     | r -> fail_result "lifecycle serve" r);
    S.stop t;
    S.stop t (* idempotent: second stop is a no-op, must not raise/hang *);
    (match Unix.waitpid [ Unix.WNOHANG ] t.S.pid with
     | exception Unix.Unix_error (Unix.ECHILD, _, _) -> ()
     | _ -> fail "stop must reap the child (no zombies/orphans)");
    (match S.http_request ~timeout_s:1.0 ~port:t.S.port ~path:"/probe" () with
     | S.Refused -> ()
     | r -> fail_result "stopped port must refuse" r);
    try Sys.remove t.S.capture_path with _ -> ()
  done

(* --- scripted statuses + default fallback ------------------------------- *)

let test_scripted_statuses () =
  let routes =
    [ S.route ~path:"/a401"
        [ S.response ~status:401 {|{"ok":false,"error":"unauthorized"}|} ];
      S.route ~path:"/a429"
        [ S.response ~status:429 {|{"ok":false,"error":"rate_limited"}|} ];
      S.route ~path:"/a500"
        [ S.response ~status:500 {|{"ok":false,"error":"boom"}|} ];
      S.route ~path:"/a503"
        [ S.response ~status:503 {|{"ok":false,"error":"maintenance"}|} ];
    ]
  in
  S.with_server ~routes (fun t ->
      List.iter
        (fun (path, expect) ->
          match S.http_request ~port:t.S.port ~path () with
          | S.Http { S.code; body_complete; _ } ->
              check int path expect code;
              check bool (path ^ " body complete") true body_complete
          | r -> fail_result path r)
        [ ("/a401", 401); ("/a429", 429); ("/a500", 500); ("/a503", 503) ];
      match S.http_request ~port:t.S.port ~path:"/unrouted" () with
      | S.Http { S.code; _ } -> check int "default fallback is 404" 404 code
      | r -> fail_result "default fallback" r)

let test_response_sequencing () =
  let routes =
    [ S.route ~path:"/flaky"
        [ S.response ~status:429 {|{"ok":false,"error":"slow_down"}|};
          S.response ok_body ];
    ]
  in
  S.with_server ~routes (fun t ->
      let code_of name =
        match S.http_request ~port:t.S.port ~path:"/flaky" () with
        | S.Http { S.code; _ } -> code
        | r -> fail_result name r
      in
      check int "1st call: scripted 429" 429 (code_of "seq 1");
      check int "2nd call: scripted 200" 200 (code_of "seq 2");
      check int "3rd call: last response repeats" 200 (code_of "seq 3"))

(* --- fault modes --------------------------------------------------------- *)

let test_delay_client_timeout () =
  let routes =
    [ S.route ~path:"/slow" [ S.response ~delay_s:3.0 ok_body ] ]
  in
  S.with_server ~routes (fun t ->
      let t0 = Unix.gettimeofday () in
      match S.http_request ~timeout_s:0.3 ~port:t.S.port ~path:"/slow" () with
      | S.Timeout ->
          check bool "timed out around the client deadline, not the delay"
            true
            (Unix.gettimeofday () -. t0 < 2.0)
      | r -> fail_result "delayed route" r)
(* with_server's finally SIGKILLs the still-sleeping child — the bracket
   is what guarantees no orphan survives this test. *)

let test_truncated_body () =
  let full =
    {|{"ok":true,"padding":"0123456789012345678901234567890123456789"}|}
  in
  let routes =
    [ S.route ~path:"/trunc" [ S.response ~truncate_body_at:10 full ] ]
  in
  S.with_server ~routes (fun t ->
      match S.http_request ~port:t.S.port ~path:"/trunc" () with
      | S.Http { S.code; body_text; body_complete; _ } ->
          check int "envelope still 200" 200 code;
          check bool "body_complete=false (short of Content-Length)" false
            body_complete;
          check int "exactly the truncation prefix arrived" 10
            (String.length body_text);
          let parsed =
            try Some (Yojson.Safe.from_string body_text) with _ -> None
          in
          check bool "truncated body is not parseable JSON" true
            (parsed = None)
      | r -> fail_result "truncated route" r)

let test_malformed_json () =
  S.with_server ~default:(S.malformed_json_response ()) (fun t ->
      match S.http_request ~port:t.S.port ~path:"/anything" () with
      | S.Http { S.code; body_text; body_complete; _ } ->
          check int "valid HTTP envelope" 200 code;
          check bool "full body delivered" true body_complete;
          let parsed =
            try Some (Yojson.Safe.from_string body_text) with _ -> None
          in
          check bool "body rejects as JSON" true (parsed = None)
      | r -> fail_result "malformed json" r)

let test_connection_refused () =
  match S.http_request ~port:(S.closed_port ()) ~path:"/" () with
  | S.Refused -> ()
  | r -> fail_result "closed_port" r

let test_close_without_response () =
  let routes =
    [ S.route ~path:"/drop" [ S.response ~close_without_response:true "" ] ]
  in
  S.with_server ~routes (fun t ->
      match S.http_request ~port:t.S.port ~path:"/drop" () with
      | S.No_response -> ()
      | r -> fail_result "close-without-response route" r)

(* --- request capture ------------------------------------------------------ *)

let test_request_capture () =
  let routes =
    [ S.route ~meth:"POST" ~path:"/register" [ S.response ok_body ] ]
  in
  S.with_server ~routes (fun t ->
      (match
         S.http_request ~meth:"POST"
           ~headers:
             [ ("X-F5A-Probe", "yes"); ("Content-Type", "application/json") ]
           ~body:{|{"alias":"f5a-probe"}|} ~port:t.S.port
           ~path:"/register?src=selftest" ()
       with
       | S.Http { S.code; _ } ->
           check int "routed despite query string" 200 code
       | r -> fail_result "capture POST" r);
      (match S.http_request ~port:t.S.port ~path:"/second" () with
       | S.Http { S.code; _ } -> check int "second request 404" 404 code
       | r -> fail_result "capture GET" r);
      match S.requests t with
      | [ first; second ] ->
          check string "method captured" "POST" first.S.meth_;
          check string "path captured with query stripped" "/register"
            first.S.path;
          check (option string) "custom header captured (case-insensitive)"
            (Some "yes")
            (S.header first "x-f5a-probe");
          check string "body captured" {|{"alias":"f5a-probe"}|} first.S.body;
          check string "ordering preserved" "GET" second.S.meth_;
          check string "second path" "/second" second.S.path
      | l ->
          fail
            (Printf.sprintf "expected 2 captured requests, got %d"
               (List.length l)))

(* --- real-handler bracket (production Relay_server over loopback) -------- *)

let with_pow_env_off f =
  let previous = Sys.getenv_opt "C2C_RELAY_POW" in
  let restore () =
    match previous with
    | Some v -> Unix.putenv "C2C_RELAY_POW" v
    | None -> Unix.putenv "C2C_RELAY_POW" ""
  in
  Unix.putenv "C2C_RELAY_POW" "";
  Fun.protect ~finally:restore f

(* B115: the F5c fake/real vector polls /poll_inbox UNSIGNED against the
   real production callback. Since B115, unsigned inbox reads fail closed
   even on a tokenless relay, so the vector's legacy poll semantics need
   the explicit development-only gate armed for the real capture. This
   suite asserts fake/real response-shape equality, not auth policy —
   the auth policy itself is locked by test_relay_remote_broker.ml. *)
let with_unsigned_inbox_allowed f =
  let var = "C2C_RELAY_ALLOW_UNSIGNED_INBOX" in
  let previous = Sys.getenv_opt var in
  let restore () =
    match previous with
    | Some v -> Unix.putenv var v
    | None -> Unix.putenv var ""
  in
  Unix.putenv var "1";
  Fun.protect ~finally:restore f

let json_member name = function
  | `Assoc fields -> List.assoc_opt name fields |> Option.value ~default:`Null
  | _ -> `Null

let test_real_relay_health_and_list () =
  with_pow_env_off @@ fun () ->
  Real.with_server (fun ~base_url ~relay ->
      let open Lwt.Infix in
      let _status, _lease =
        Relay.InMemoryRelay.register relay ~node_id:"node-f5a"
          ~session_id:"sess-f5a" ~alias:"f5a-realprobe" ()
      in
      Real.call_json ~base_url ~meth:`GET ~path:"/health" ()
      >>= fun health ->
      check int "/health is 200 from the production handler" 200
        (Real.status_code health);
      (match health.Real.json with
       | Some j ->
           check bool "/health body says ok:true" true
             (json_member "ok" j = `Bool true)
       | None -> fail "/health body was not JSON");
      Real.call_json ~base_url ~meth:`GET ~path:"/list" ()
      >>= fun listing ->
      check int "/list is 200" 200 (Real.status_code listing);
      (match listing.Real.json with
       | Some j -> (
           match json_member "peers" j with
           | `List peers ->
               let aliases =
                 List.filter_map
                   (fun p ->
                     match json_member "alias" p with
                     | `String a -> Some a
                     | _ -> None)
                   peers
               in
               check bool
                 "backend registration visible through the real handler" true
                 (List.mem "f5a-realprobe" aliases)
           | _ -> fail "/list body missing peers array")
       | None -> fail "/list body was not JSON");
      Lwt.return_unit)

(* ======================================================================== *)
(* F5c: schema-mismatch faults                                              *)
(*                                                                          *)
(* The relay answers with well-formed HTTP + well-formed JSON that does     *)
(* NOT match the expected response schema. Each case pins the observed     *)
(* HONEST behavior of a real client path. Rows: B232 (invalid-JSON /       *)
(* wrong-shape response handling), B238 (garbage never reported as         *)
(* success), B093/B095 (connector sync errors recorded + surfaced),        *)
(* B120 (lease-state classification degrades conservatively), B249         *)
(* (non-object responses cannot crash the operator surface silently).      *)
(* ======================================================================== *)

(* --- small local fs helpers (hermetic temp broker roots) --- *)

let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun e -> rm_rf (Filename.concat path e)) (Sys.readdir path);
      (try Unix.rmdir path with _ -> ())
  | _ -> ( try Sys.remove path with _ -> ())

let with_temp_broker_root f =
  let dir = Filename.temp_file "c2c-f5c-broker-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let write_file path s =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc s)

let sm_session = "sess-f5c-sm"
let sm_alias = "f5c-sm-probe"

let write_registry broker_root =
  write_file
    (Filename.concat broker_root "registry.json")
    (Yojson.Safe.to_string
       (`List
         [ `Assoc
             [ ("session_id", `String sm_session);
               ("alias", `String sm_alias);
               ("client_type", `String "test");
             ];
         ]))

let make_connector ~relay_url ~broker_root : C2c_relay_connector.t =
  { C2c_relay_connector.relay_url;
    token = None;
    identity = None;
    broker_root;
    node_id = "n-f5c-sm";
    heartbeat_ttl = 60.0;
    interval = 1.0;
    verbose = false;
    registered = [];
    active_ws_bindings = [];
    alert_state = C2c_relay_alert.initial_state;
  }

(* [sync] eagerly performs its own inner Lwt_main.run HTTP calls while the
   expression is evaluated, exactly as production [start] invokes it. *)
let run_sync t = Lwt_main.run (C2c_relay_connector.sync t)

(* --- Relay.Relay_client (production HTTP client) vs wrong bodies --- *)

let test_client_malformed_json_is_error () =
  (* B232: valid HTTP envelope, body no JSON parser accepts. The client
     must return its structured connection_error result — not raise. *)
  S.with_server ~default:(S.malformed_json_response ()) (fun t ->
      let client = Relay.Relay_client.make ~timeout:5.0 (S.url t) in
      let json = Lwt_main.run (Relay.Relay_client.health client) in
      check bool "ok:false" true (json_member "ok" json = `Bool false);
      check bool "error_code=connection_error" true
        (json_member "error_code" json = `String "connection_error");
      check bool "error names invalid_json_response" true
        (json_member "error" json = `String "invalid_json_response"))

let test_client_truncated_body_is_error () =
  (* B232: headers promise the full Content-Length, wire delivers a JSON
     prefix. Whether cohttp surfaces a short read or the JSON parse fails,
     the client must land on the same honest connection_error result. *)
  let full =
    {|{"ok":true,"padding":"0123456789012345678901234567890123456789"}|}
  in
  let routes =
    [ S.route ~path:"/health" [ S.response ~truncate_body_at:12 full ] ]
  in
  S.with_server ~routes (fun t ->
      let client = Relay.Relay_client.make ~timeout:5.0 (S.url t) in
      let json = Lwt_main.run (Relay.Relay_client.health client) in
      check bool "ok:false" true (json_member "ok" json = `Bool false);
      check bool "error_code=connection_error" true
        (json_member "error_code" json = `String "connection_error"))

let test_client_non_object_json_passes_through () =
  (* A 200 whose body is valid JSON but NOT an object. Relay_client's
     documented contract is "returns the parsed JSON response" — shape
     validation is caller-owned. Pin: no exception, the value comes back
     verbatim, and in particular it can never read as ok:true. The
     consumer-side consequences are pinned separately
     (test_connector_non_object_response_start_once). *)
  let routes = [ S.route ~path:"/health" [ S.response {|[1,2,3]|} ] ] in
  S.with_server ~routes (fun t ->
      let client = Relay.Relay_client.make ~timeout:5.0 (S.url t) in
      let json = Lwt_main.run (Relay.Relay_client.health client) in
      check bool "non-object returned verbatim" true
        (json = `List [ `Int 1; `Int 2; `Int 3 ]))

(* --- C2c_relay_connector.sync vs schema-wrong register/poll bodies --- *)

let test_connector_register_ok_wrong_type () =
  (* B093/B238: register answers 200 with ok as a STRING ("true"). The
     connector must not treat it as success: the alias stays unregistered
     and the sync error is recorded (surfaced via connector-state + exit
     code in --once mode). *)
  let routes =
    [ S.route ~meth:"POST" ~path:"/register"
        [ S.response {|{"ok":"true","result":"ok"}|} ];
    ]
  in
  S.with_server ~routes (fun srv ->
      with_temp_broker_root (fun broker_root ->
          write_registry broker_root;
          let t = make_connector ~relay_url:(S.url srv) ~broker_root in
          let (r : C2c_relay_connector.sync_result) = run_sync t in
          check (list string) "nothing registered" [] r.registered;
          check int "nothing delivered" 0 r.inbound_delivered;
          match r.last_error with
          | Some e ->
              check string "error op is register" "register"
                e.C2c_relay_connector.err_op
          | None -> fail "wrong-typed ok must record a sync error"))

let test_connector_register_missing_ok () =
  (* B093/B238: register answers 200 with a body that simply lacks the
     required "ok" field. Absent evidence of success is failure. *)
  let routes =
    [ S.route ~meth:"POST" ~path:"/register"
        [ S.response {|{"result":"ok","lease":{}}|} ];
    ]
  in
  S.with_server ~routes (fun srv ->
      with_temp_broker_root (fun broker_root ->
          write_registry broker_root;
          let t = make_connector ~relay_url:(S.url srv) ~broker_root in
          let (r : C2c_relay_connector.sync_result) = run_sync t in
          check (list string) "nothing registered" [] r.registered;
          match r.last_error with
          | Some e ->
              check string "error op is register" "register"
                e.C2c_relay_connector.err_op
          | None -> fail "missing ok must record a sync error"))

let test_connector_poll_messages_wrong_type () =
  (* B095: poll_inbox answers ok:true but "messages" is not a list. The
     connector tolerates the unrecognized shape WITHOUT fabricating
     deliveries: zero delivered, no inbox file written, sync otherwise
     clean. (Lenient-ignore, but never garbage-as-success.) *)
  let routes =
    [ S.route ~meth:"POST" ~path:"/register"
        [ S.response {|{"ok":true,"result":"ok"}|} ];
      S.route ~meth:"POST" ~path:"/poll_inbox"
        [ S.response {|{"ok":true,"messages":{"not":"a list"}}|} ];
    ]
  in
  S.with_server ~routes (fun srv ->
      with_temp_broker_root (fun broker_root ->
          write_registry broker_root;
          let t = make_connector ~relay_url:(S.url srv) ~broker_root in
          let (r : C2c_relay_connector.sync_result) = run_sync t in
          check (list string) "registered" [ sm_alias ] r.registered;
          check int "nothing delivered" 0 r.inbound_delivered;
          check bool "no sync error" true (r.last_error = None);
          check bool "no inbox file materialized" false
            (Sys.file_exists
               (Filename.concat broker_root (sm_session ^ ".inbox.json")))))

(* H9 fix (rows B095/B238; closes the F5c dishonest cell): poll_inbox rows
   that fail the minimum broker-inbox contract — string from_alias /
   to_alias / content, exactly what C2c_broker.message_of_json REQUIRES —
   are dropped BEFORE append_to_local_inbox, with the drop recorded as a
   poll_inbox sync error. Valid rows in the same batch still deliver
   (partial-batch delivery); dropped rows never count in
   inbound_delivered; and the local inbox file stays parseable by the
   broker layer. Pre-fix (verified dishonest 2026-07-10 on fbb16453),
   garbage rows were appended verbatim, counted as delivered with
   last_error=None, and one such row made C2c_broker.load_inbox raise
   Yojson Type_error for the WHOLE inbox on every subsequent read. *)
let h9_good_row =
  `Assoc
    [ ("from_alias", `String "f5c-sm-peer");
      ("to_alias", `String sm_alias);
      ("content", `String "valid-row");
      ("ts", `Float 1700000003.0);
      ("message_id", `String "m-h9-good") ]

let test_connector_poll_garbage_rows_dropped () =
  let poll_body =
    Yojson.Safe.to_string
      (`Assoc
        [ ("ok", `Bool true);
          ("messages",
           `List
             [ `Assoc [ ("bogus", `Int 1) ] (* no required key at all *);
               h9_good_row;
               `Assoc
                 [ ("from_alias", `Int 7) (* wrong-typed sender *);
                   ("to_alias", `String sm_alias);
                   ("content", `String "wrong-typed from_alias") ];
             ]) ])
  in
  let routes =
    [ S.route ~meth:"POST" ~path:"/register"
        [ S.response {|{"ok":true,"result":"ok"}|} ];
      S.route ~meth:"POST" ~path:"/poll_inbox" [ S.response poll_body ];
    ]
  in
  S.with_server ~routes (fun srv ->
      with_temp_broker_root (fun broker_root ->
          write_registry broker_root;
          let t = make_connector ~relay_url:(S.url srv) ~broker_root in
          let (r : C2c_relay_connector.sync_result) = run_sync t in
          check (list string) "registered" [ sm_alias ] r.registered;
          check int "only the valid row delivered" 1 r.inbound_delivered;
          check int "both garbage rows counted as rejected" 2
            r.inbound_rejected;
          (match r.last_error with
           | Some e ->
               check string "dropped rows recorded as poll_inbox error"
                 "poll_inbox" e.C2c_relay_connector.err_op
           | None -> fail "dropped rows must record a sync error");
          let inbox_path =
            Filename.concat broker_root (sm_session ^ ".inbox.json")
          in
          check bool "inbox file written for the valid row" true
            (Sys.file_exists inbox_path);
          (match Yojson.Safe.from_file inbox_path with
           | `List [ row ] ->
               check bool "inbox contains exactly the valid row verbatim"
                 true (row = h9_good_row)
           | other ->
               fail
                 ("inbox file must hold only the valid row, got: "
                  ^ Yojson.Safe.to_string other));
          (* End-to-end honesty: the file the connector wrote must be
             readable by the broker layer (the pre-fix poisoned file made
             this raise Yojson Type_error). *)
          let broker = C2c_mcp.Broker.create ~root:broker_root in
          match C2c_mcp.Broker.read_inbox broker ~session_id:sm_session with
          | [ msg ] ->
              check string "broker parses the delivered row" "valid-row"
                msg.C2c_mcp.content
          | msgs ->
              fail
                (Printf.sprintf "broker read %d messages, expected 1"
                   (List.length msgs))))

let test_connector_non_object_response_start_once () =
  (* B249/B093 — repinned by H10 item 5 (non-object hardening): a
     non-object JSON answer (here to /register) used to make the sync
     pass raise (Yojson Type_error via [member] on a list) and abort the
     WHOLE pass — start --once exited 1 with last_error_op="sync". The
     response helpers ([json_bool_member], [json_list_member],
     [response_is_rate_limited], [response_is_pow_retry_failed],
     [classify_error]) are now total on non-objects, so the non-object
     response records a normal PER-OP error instead: registered stays
     empty, last_error_op="register", and --once exits 2 via the B087
     completed-with-errors path. *)
  let routes =
    [ S.route ~meth:"POST" ~path:"/register" [ S.response {|[1,2,3]|} ] ]
  in
  S.with_server ~routes (fun srv ->
      with_temp_broker_root (fun broker_root ->
          write_registry broker_root;
          let rc =
            C2c_relay_connector.start ~relay_url:(S.url srv) ~token:None
              ~identity:None ~broker_root ~node_id:"n-f5c-sm"
              ~heartbeat_ttl:60.0 ~interval:1.0 ~verbose:false ~once:true
          in
          check int "start --once exits 2 (per-op error, not exception)" 2 rc;
          match C2c_relay_connector.read_connector_state broker_root with
          | None -> fail "connector-state.json must be written on failure"
          | Some st ->
              check (list string) "nothing registered" []
                st.C2c_relay_connector.cs_registered;
              check (option string) "failure recorded as a register op error"
                (Some "register") st.C2c_relay_connector.cs_last_error_op;
              check bool "last_error_detail non-empty" true
                (match st.C2c_relay_connector.cs_last_error_detail with
                 | Some d -> String.length d > 0
                 | None -> false)))

(* ======================================================================== *)
(* H10: connector inline Relay_client HTTP-status honesty (Q1-DEFECT-1)     *)
(*                                                                          *)
(* The connector has its own inline Relay_client whose [request] used to    *)
(* bind [(_resp, resp_body)] — discarding the HTTP status line entirely     *)
(* (same defect class as H7 in ocaml/relay_client.ml, B090). A relay        *)
(* answering HTTP 500 with a dishonest {"ok":true,...} body made            *)
(* `c2c relay connect --once` report FALSE SUCCESS: exit 0, registered      *)
(* counted, no last_error. Finding:                                         *)
(* .collab/findings/2026-07-10T12-17-07Z-q1-worker-connector-dishonest-     *)
(* 500-false-success.md                                                     *)
(*                                                                          *)
(* Contract under test (port of H7's four branches):                        *)
(*   2xx                        -> parsed body passthrough (unchanged);     *)
(*   non-2xx + honest ok:false  -> passthrough, own error_code wins,        *)
(*                                 http_status:<code> annotated;            *)
(*   non-2xx + NOT ok:false     -> overridden ok:false /                    *)
(*                                 error_code=http_error_<code> /           *)
(*                                 http_status, body under relay_response;  *)
(*   transport failure          -> existing connection_error (unchanged).   *)
(* Consequence: dishonest non-2xx on register/send/poll paths records a     *)
(* per-op sync error (never counted registered/delivered) and --once        *)
(* exits 2 via the existing B087 sync-with-errors path.                     *)
(* ======================================================================== *)

let contains_substr ~sub s =
  let n = String.length sub and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = sub || go (i + 1)) in
  n = 0 || go 0

let last_error_detail (r : C2c_relay_connector.sync_result) =
  match r.C2c_relay_connector.last_error with
  | Some e -> e.C2c_relay_connector.err_detail
  | None -> ""

let test_connector_register_dishonest_500_ok_true () =
  (* The Q1 finding's exact repro: every /register answers HTTP 500 with a
     body claiming {"ok":true}. Pre-H10 this was a FALSE SUCCESS (alias
     counted registered, last_error=None, --once exit 0). *)
  let routes =
    [ S.route ~meth:"POST" ~path:"/register"
        [ S.response ~status:500 {|{"ok":true,"result":"ok"}|} ];
    ]
  in
  S.with_server ~routes (fun srv ->
      with_temp_broker_root (fun broker_root ->
          write_registry broker_root;
          let t = make_connector ~relay_url:(S.url srv) ~broker_root in
          let (r : C2c_relay_connector.sync_result) = run_sync t in
          (* no-false-success trap *)
          check (list string) "dishonest 500 must never count as registered"
            [] r.registered;
          check bool "session not remembered as registered" true
            (t.C2c_relay_connector.registered = []);
          (* failure named per-op *)
          (match r.last_error with
           | Some e ->
               check string "error op is register" "register"
                 e.C2c_relay_connector.err_op;
               check bool "detail carries http_error_500" true
                 (contains_substr ~sub:"http_error_500"
                    e.C2c_relay_connector.err_detail);
               check bool "detail preserves the dishonest body" true
                 (contains_substr ~sub:"relay_response"
                    e.C2c_relay_connector.err_detail)
           | None ->
               fail "dishonest 500 must record a sync error, got last_error=None"));
      (* operator surface: --once exits 2 (B087 completed-with-errors),
         connector-state records the per-op failure *)
      with_temp_broker_root (fun broker_root ->
          write_registry broker_root;
          let rc =
            C2c_relay_connector.start ~relay_url:(S.url srv) ~token:None
              ~identity:None ~broker_root ~node_id:"n-f5c-sm"
              ~heartbeat_ttl:60.0 ~interval:1.0 ~verbose:false ~once:true
          in
          check int "start --once exits 2 on dishonest 500" 2 rc;
          match C2c_relay_connector.read_connector_state broker_root with
          | None -> fail "connector-state.json must be written"
          | Some st ->
              check (list string) "state records nothing registered" []
                st.C2c_relay_connector.cs_registered;
              check (option string) "state names the register failure"
                (Some "register") st.C2c_relay_connector.cs_last_error_op))

let test_connector_poll_dishonest_500_ok_true () =
  (* poll_inbox answers HTTP 500 with a dishonest ok:true body CARRYING
     schema-valid message rows. The status line wins: nothing may be
     delivered off a 500, no inbox file appears, and the failure is
     recorded as a poll_inbox per-op error. *)
  let poll_body =
    Yojson.Safe.to_string
      (`Assoc
        [ ("ok", `Bool true);
          ("messages", `List [ h9_good_row ]) ])
  in
  let routes =
    [ S.route ~meth:"POST" ~path:"/register"
        [ S.response {|{"ok":true,"result":"ok"}|} ];
      S.route ~meth:"POST" ~path:"/poll_inbox"
        [ S.response ~status:500 poll_body ];
    ]
  in
  S.with_server ~routes (fun srv ->
      with_temp_broker_root (fun broker_root ->
          write_registry broker_root;
          let t = make_connector ~relay_url:(S.url srv) ~broker_root in
          let (r : C2c_relay_connector.sync_result) = run_sync t in
          check (list string) "register (200 ok) still succeeds" [ sm_alias ]
            r.registered;
          (* no-false-success trap: rows riding a 500 never deliver *)
          check int "nothing delivered off a dishonest 500" 0
            r.inbound_delivered;
          check int "nothing counted rejected (whole response refused)" 0
            r.inbound_rejected;
          check bool "no inbox file materialized" false
            (Sys.file_exists
               (Filename.concat broker_root (sm_session ^ ".inbox.json")));
          match r.last_error with
          | Some e ->
              check string "error op is poll_inbox" "poll_inbox"
                e.C2c_relay_connector.err_op;
              check bool "detail carries http_error_500" true
                (contains_substr ~sub:"http_error_500"
                   e.C2c_relay_connector.err_detail)
          | None ->
              fail "dishonest 500 poll must record a sync error"))

let test_connector_register_honest_503_passthrough () =
  (* Honest-error branch: non-2xx whose body already reports ok:false
     passes through — its OWN error_code wins (never rewritten to
     http_error_503) and the http_status annotation is added. *)
  let routes =
    [ S.route ~meth:"POST" ~path:"/register"
        [ S.response ~status:503
            {|{"ok":false,"error_code":"maintenance_mode","error":"relay down for maintenance"}|} ];
    ]
  in
  S.with_server ~routes (fun srv ->
      with_temp_broker_root (fun broker_root ->
          write_registry broker_root;
          let t = make_connector ~relay_url:(S.url srv) ~broker_root in
          let (r : C2c_relay_connector.sync_result) = run_sync t in
          check (list string) "nothing registered" [] r.registered;
          let detail = last_error_detail r in
          check bool "own error_code wins (maintenance_mode)" true
            (contains_substr ~sub:"maintenance_mode" detail);
          check bool "http_status:503 annotated" true
            (contains_substr ~sub:{|"http_status":503|} detail);
          check bool "honest body never rewritten to http_error_503" false
            (contains_substr ~sub:"http_error_503" detail)))

let test_connector_pow_and_rate_limit_flows_preserved () =
  (* Guard for the PoW/rate-limit helpers that key on HONEST non-2xx
     bodies — the honest-passthrough branch must keep them working.
     (a) An honest 429 pow_required challenge still enters the
         Pow_client retry path: with no identity the mint attempt fails
         as pow_actor_id_missing — proof the challenge was RECOGNIZED
         (a broken passthrough would surface raw pow_required instead).
     (b) An honest 429 rate_limit_exceeded still trips
         response_is_rate_limited -> a Broadcast alert is emitted. *)
  let pow_challenge =
    {|{"ok":false,"error_code":"pow_required","error":"pow required",|}
    ^ {|"required":{"difficulty":8,"epoch":1,"server_nonce":"sn","ctx":"c2c-relay-pow-v1"}}|}
  in
  let routes =
    [ S.route ~meth:"POST" ~path:"/register"
        [ S.response ~status:429 pow_challenge ] ]
  in
  S.with_server ~routes (fun srv ->
      with_temp_broker_root (fun broker_root ->
          write_registry broker_root;
          let t = make_connector ~relay_url:(S.url srv) ~broker_root in
          let (r : C2c_relay_connector.sync_result) = run_sync t in
          check (list string) "nothing registered" [] r.registered;
          let detail = last_error_detail r in
          check bool "pow challenge recognized (mint attempted)" true
            (contains_substr ~sub:"pow_actor_id_missing" detail)));
  let routes =
    [ S.route ~meth:"POST" ~path:"/register"
        [ S.response ~status:429
            {|{"ok":false,"error_code":"rate_limit_exceeded","error":"rate_limit_exceeded"}|} ];
    ]
  in
  S.with_server ~routes (fun srv ->
      with_temp_broker_root (fun broker_root ->
          write_registry broker_root;
          let t = make_connector ~relay_url:(S.url srv) ~broker_root in
          let (r : C2c_relay_connector.sync_result) = run_sync t in
          check (list string) "nothing registered" [] r.registered;
          check bool "honest 429 still detected as rate-limited (alert)" true
            (r.alerts_emitted >= 1);
          let detail = last_error_detail r in
          check bool "own error_code wins (rate_limit_exceeded)" true
            (contains_substr ~sub:"rate_limit_exceeded" detail)))

(* --- pure classifier/hint surfaces vs schema-wrong inputs --- *)

let test_lease_json_wrong_types_never_live () =
  (* B120: lease JSON with wrong-typed alive/alias_reserved (or a non-object
     lease) must degrade CONSERVATIVELY: never classify Registered_live. *)
  let expect_not_live label lease_json =
    let reg = Relay_state.registration_of_lease_json lease_json in
    (match reg with
     | Relay_state.Reg_lease { alive; reserved } ->
         check bool (label ^ ": alive coerces false") false alive;
         check bool (label ^ ": reserved coerces false") false reserved
     | _ -> fail (label ^ ": expected Reg_lease evidence"));
    let c =
      Relay_state.classify ~relay_configured:true ~has_identity:true
        ~has_alias:true ~registration:reg ~connector_live:true
        ~local_reg_evidence:true
    in
    check bool (label ^ ": never classified live") true
      (c.Relay_state.state <> Relay_state.Registered_live)
  in
  expect_not_live "string alive"
    (`Assoc [ ("alive", `String "yes"); ("alias_reserved", `Int 1) ]);
  expect_not_live "int alive"
    (`Assoc [ ("alive", `Int 1); ("alias_reserved", `String "true") ]);
  expect_not_live "non-object lease" (`String "lease")

let test_client_hints_total_on_garbage () =
  (* C056-adjacent: the error-hint path must be total on schema-wrong
     responses — no hint, no crash — and still fire on the real shape. *)
  let source = Relay_client_hints.Explicit "f5c-sm-probe" in
  List.iter
    (fun (label, json) ->
      check bool label true
        (Relay_client_hints.hint_for_response ~alias_source:source json = None))
    [ ("non-object list", `List [ `Int 1 ]);
      ("non-object string", `String "unauthorized");
      ("wrong-typed ok", `Assoc [ ("ok", `String "false") ]);
      ("wrong-typed error", `Assoc [ ("ok", `Bool false);
                                     ("error_code", `String "unauthorized");
                                     ("error", `Int 7) ]);
    ];
  check bool "real missing-binding shape still hints" true
    (Relay_client_hints.hint_for_response ~alias_source:source
       (`Assoc
         [ ("ok", `Bool false);
           ("error_code", `String "unauthorized");
           ("error", `String {|alias "f5c-sm-probe" has no identity binding|});
         ])
     <> None)

(* ======================================================================== *)
(* F5c: fake/real vector equality (shared semantic vectors)                 *)
(*                                                                          *)
(* The same request vectors are issued to BOTH servers:                     *)
(*   fake = Relay_test_support serving the hand-written fixtures below      *)
(*   real = Relay_test_support_real (production make_callback on           *)
(*          InMemoryRelay, dev auth, PoW off)                               *)
(* and the responses must be equal after normalization. This pins that      *)
(* fault-matrix results obtained against the scripted server (F5b) are      *)
(* meaningful: the fake is faithful where it claims to be.                  *)
(*                                                                          *)
(* NORMALIZATION (applied to both sides):                                   *)
(*   - assoc keys sorted recursively (key ORDER is not part of the JSON     *)
(*     contract; presence/absence and types are);                           *)
(*   - wall-clock float fields are nondeterministic by nature and are      *)
(*     replaced by "<ts>" ONLY when they are JSON numbers (a wrong-typed    *)
(*     ts still fails the comparison): ts, registered_at, last_seen,        *)
(*     alias_warning_since, alias_release_at;                               *)
(*   - git_hash (health) is environment-derived and replaced by "<opaque>"  *)
(*     only when it is a JSON string.                                       *)
(*   Everything else — statuses, ok flags, enum-ish result strings, error   *)
(*   codes/messages, lease ttl/alive/alias_reserved, message identity and   *)
(*   content (message_id is supplied by the client, so deterministic) —    *)
(*   is compared exactly.                                                   *)
(* ======================================================================== *)

let volatile_number_keys =
  [ "ts"; "registered_at"; "last_seen"; "alias_warning_since";
    "alias_release_at" ]

let volatile_string_keys = [ "git_hash" ]

let rec normalize (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc kvs ->
      let kvs =
        List.map
          (fun (k, v) ->
            if List.mem k volatile_number_keys then
              (match v with
               | `Float _ | `Int _ -> (k, `String "<ts>")
               | other -> (k, other) (* wrong-typed volatile: keep + mismatch *))
            else if List.mem k volatile_string_keys then
              (match v with
               | `String _ -> (k, `String "<opaque>")
               | other -> (k, other))
            else (k, normalize v))
          kvs
      in
      `Assoc (List.sort (fun (a, _) (b, _) -> compare a b) kvs)
  | `List xs -> `List (List.map normalize xs)
  | other -> other

(* --- the shared semantic vectors --- *)

let eq_node = "n-f5c-eq"
let eq_sess = "sess-f5c-eq"
let eq_alias = "f5c-eq-probe"
let eq_sender = "f5c-eq-sender"
let eq_ghost = "f5c-eq-ghost"
let eq_mid = "m-f5c-eq-1"
let eq_mid2 = "m-f5c-eq-2"
let eq_content = "hello-f5c"

(* requests *)
let req_register_ok =
  `Assoc
    [ ("node_id", `String eq_node); ("session_id", `String eq_sess);
      ("alias", `String eq_alias); ("client_type", `String "test");
      ("ttl", `Int 0) ]

let req_register_bad =
  (* alias missing — deterministic 400 from the production handler *)
  `Assoc [ ("node_id", `String eq_node); ("session_id", `String eq_sess) ]

let req_send_ok =
  `Assoc
    [ ("from_alias", `String eq_sender); ("to_alias", `String eq_alias);
      ("content", `String eq_content); ("message_id", `String eq_mid) ]

let req_send_unknown =
  `Assoc
    [ ("from_alias", `String eq_sender); ("to_alias", `String eq_ghost);
      ("content", `String eq_content); ("message_id", `String eq_mid2) ]

let req_poll =
  `Assoc [ ("node_id", `String eq_node); ("session_id", `String eq_sess) ]

(* hand-written canned response fixtures the fake serves (what a fault
   suite would write by hand). ttl mirrors the server-side clamp of the
   requested ttl=0 up to the default lease ttl; version/scheme are build
   constants, not wall-clock values. *)
let fixture_lease =
  `Assoc
    [ ("node_id", `String eq_node); ("session_id", `String eq_sess);
      ("alias", `String eq_alias); ("client_type", `String "test");
      ("registered_at", `Float 1700000000.0);
      ("last_seen", `Float 1700000000.0);
      ("ttl", `Float Relay.default_lease_ttl);
      ("alive", `Bool true);
      ("alias_reserved", `Bool true);
      ("alias_warning_since", `Float 1707776000.0);
      ("alias_release_at", `Float 1731104000.0);
      ("alias_release_warning", `Bool false) ]

let fixture_register_ok =
  `Assoc
    [ ("ok", `Bool true); ("result", `String "ok");
      ("lease", fixture_lease) ]

let fixture_register_bad =
  `Assoc
    [ ("ok", `Bool false); ("error_code", `String "bad_request");
      ("error", `String "node_id, session_id, and alias are required") ]

let fixture_send_ok =
  `Assoc
    [ ("ok", `Bool true); ("result", `String "ok");
      ("ts", `Float 1700000001.0) ]

let fixture_send_dup =
  `Assoc
    [ ("ok", `Bool true); ("result", `String "duplicate");
      ("ts", `Float 1700000002.0) ]

let fixture_send_unknown =
  `Assoc
    [ ("ok", `Bool false); ("error_code", `String "unknown_alias");
      ("error",
       `String (Printf.sprintf "no registration for alias %S" eq_ghost)) ]

let fixture_poll_full =
  `Assoc
    [ ("ok", `Bool true);
      ("messages",
       `List
         [ `Assoc
             [ ("message_id", `String eq_mid);
               ("from_alias", `String eq_sender);
               ("to_alias", `String eq_alias);
               ("content", `String eq_content);
               ("ts", `Float 1700000001.0) ];
         ]) ]

let fixture_poll_empty = `Assoc [ ("ok", `Bool true); ("messages", `List []) ]

let fixture_health =
  `Assoc
    [ ("ok", `Bool true);
      ("version", `String Version.version);
      ("git_hash", `String "0000000");
      ("protocol_version", `Int Version.relay_protocol_version);
      ("min_client_protocol_version",
       `Int Version.relay_min_client_protocol_version);
      ("auth_mode", `String "dev");
      ("pow",
       `Assoc
         [ ("enabled", `Bool false); ("scheme", `String Pow.scheme_id) ]) ]

let fixture_list =
  `Assoc [ ("ok", `Bool true); ("peers", `List [ fixture_lease ]) ]

(* canonical vector order — both captures issue exactly this sequence *)
let vector_labels =
  [ "register-ok"; "register-bad"; "send-ok"; "send-duplicate";
    "send-unknown-alias"; "poll-full"; "poll-empty"; "health"; "list" ]

let capture_fake () : (string * int * Yojson.Safe.t) list =
  let body j = Yojson.Safe.to_string j in
  let routes =
    [ S.route ~meth:"POST" ~path:"/register"
        [ S.response (body fixture_register_ok);
          S.response ~status:400 (body fixture_register_bad) ];
      S.route ~meth:"POST" ~path:"/send"
        [ S.response (body fixture_send_ok);
          S.response (body fixture_send_dup);
          S.response (body fixture_send_unknown) ];
      S.route ~meth:"POST" ~path:"/poll_inbox"
        [ S.response (body fixture_poll_full);
          S.response (body fixture_poll_empty) ];
      S.route ~meth:"GET" ~path:"/health" [ S.response (body fixture_health) ];
      S.route ~meth:"GET" ~path:"/list" [ S.response (body fixture_list) ];
    ]
  in
  S.with_server ~routes (fun t ->
      let call label ~meth ~path ?req () =
        match
          S.http_request ~meth
            ~headers:[ ("Content-Type", "application/json") ]
            ?body:(Option.map Yojson.Safe.to_string req) ~port:t.S.port ~path
            ()
        with
        | S.Http { S.code; body_text; body_complete; _ } ->
            check bool (label ^ ": fake body complete") true body_complete;
            (label, code, Yojson.Safe.from_string body_text)
        | r -> fail_result ("fake " ^ label) r
      in
      (* explicit lets: OCaml list expressions evaluate elements
         right-to-left, which would invert the per-route sequencing *)
      let v1 = call "register-ok" ~meth:"POST" ~path:"/register" ~req:req_register_ok () in
      let v2 = call "register-bad" ~meth:"POST" ~path:"/register" ~req:req_register_bad () in
      let v3 = call "send-ok" ~meth:"POST" ~path:"/send" ~req:req_send_ok () in
      let v4 = call "send-duplicate" ~meth:"POST" ~path:"/send" ~req:req_send_ok () in
      let v5 = call "send-unknown-alias" ~meth:"POST" ~path:"/send" ~req:req_send_unknown () in
      let v6 = call "poll-full" ~meth:"POST" ~path:"/poll_inbox" ~req:req_poll () in
      let v7 = call "poll-empty" ~meth:"POST" ~path:"/poll_inbox" ~req:req_poll () in
      let v8 = call "health" ~meth:"GET" ~path:"/health" () in
      let v9 = call "list" ~meth:"GET" ~path:"/list" () in
      [ v1; v2; v3; v4; v5; v6; v7; v8; v9 ])

let capture_real () : (string * int * Yojson.Safe.t) list =
  with_pow_env_off @@ fun () ->
  with_unsigned_inbox_allowed @@ fun () ->
  Real.with_server (fun ~base_url ~relay:_ ->
      let open Lwt.Infix in
      let one label ~meth ~path ?req () =
        (match req with
         | Some body -> Real.call_json ~base_url ~meth ~path ~body ()
         | None -> Real.call_json ~base_url ~meth ~path ())
        >|= fun r ->
        match r.Real.json with
        | Some j -> (label, Real.status_code r, j)
        | None ->
            fail
              (Printf.sprintf "real %s: body is not JSON: %S" label
                 r.Real.body_text)
      in
      one "register-ok" ~meth:`POST ~path:"/register" ~req:req_register_ok ()
      >>= fun v1 ->
      one "register-bad" ~meth:`POST ~path:"/register" ~req:req_register_bad ()
      >>= fun v2 ->
      one "send-ok" ~meth:`POST ~path:"/send" ~req:req_send_ok () >>= fun v3 ->
      one "send-duplicate" ~meth:`POST ~path:"/send" ~req:req_send_ok ()
      >>= fun v4 ->
      one "send-unknown-alias" ~meth:`POST ~path:"/send" ~req:req_send_unknown ()
      >>= fun v5 ->
      one "poll-full" ~meth:`POST ~path:"/poll_inbox" ~req:req_poll ()
      >>= fun v6 ->
      one "poll-empty" ~meth:`POST ~path:"/poll_inbox" ~req:req_poll ()
      >>= fun v7 ->
      one "health" ~meth:`GET ~path:"/health" () >>= fun v8 ->
      one "list" ~meth:`GET ~path:"/list" () >>= fun v9 ->
      Lwt.return [ v1; v2; v3; v4; v5; v6; v7; v8; v9 ])

let test_fake_real_vector_equality () =
  (* fake first (forked scripted server, blocking client), real second
     (in-process Lwt bracket) — never both live at once. *)
  let fake = capture_fake () in
  let real = capture_real () in
  check (list string) "vector sequence" vector_labels
    (List.map (fun (l, _, _) -> l) fake);
  check (list string) "both sides ran the same sequence"
    (List.map (fun (l, _, _) -> l) fake)
    (List.map (fun (l, _, _) -> l) real);
  List.iter2
    (fun (label, fake_code, fake_json) (_, real_code, real_json) ->
      check int (label ^ ": status code (real is truth)") real_code fake_code;
      check string
        (label ^ ": normalized body (real is truth)")
        (Yojson.Safe.to_string (normalize real_json))
        (Yojson.Safe.to_string (normalize fake_json)))
    fake real

(* --- runner ---------------------------------------------------------------- *)

let () =
  run "relay_test_support"
    [
      ( "lifecycle",
        [ test_case "repeated start/stop, reaped child, port refuses" `Quick
            test_lifecycle_repeated ] );
      ( "scripted responses",
        [ test_case "status codes + default fallback" `Quick
            test_scripted_statuses;
          test_case "per-route sequencing (429 then 200)" `Quick
            test_response_sequencing ] );
      ( "fault modes",
        [ test_case "delay -> client timeout" `Quick test_delay_client_timeout;
          test_case "truncated body short of Content-Length" `Quick
            test_truncated_body;
          test_case "malformed JSON in a valid envelope" `Quick
            test_malformed_json;
          test_case "connection refused via closed_port" `Quick
            test_connection_refused;
          test_case "close without response" `Quick
            test_close_without_response ] );
      ( "request capture",
        [ test_case "method/path/headers/body + ordering" `Quick
            test_request_capture ] );
      (* Lwt-based cases from here on: no Lwt engine state before the pure
         forking cases above. The F5c groups interleave forked scripted
         servers with Lwt clients — safe per the ordering note in the
         header (children never run Lwt; Unix._exit). *)
      ( "real handler (in-process production relay)",
        [ test_case "/health + /list over loopback" `Quick
            test_real_relay_health_and_list ] );
      ( "schema-mismatch faults (F5c)",
        [ test_case "lease JSON wrong types never classify live" `Quick
            test_lease_json_wrong_types_never_live;
          test_case "error-hint path total on garbage responses" `Quick
            test_client_hints_total_on_garbage;
          test_case "Relay_client: malformed JSON -> connection_error" `Quick
            test_client_malformed_json_is_error;
          test_case "Relay_client: truncated body -> connection_error" `Quick
            test_client_truncated_body_is_error;
          test_case "Relay_client: non-object JSON returned verbatim" `Quick
            test_client_non_object_json_passes_through;
          test_case "connector: register ok wrong-typed -> sync error" `Quick
            test_connector_register_ok_wrong_type;
          test_case "connector: register missing ok -> sync error" `Quick
            test_connector_register_missing_ok;
          test_case "connector: poll messages wrong-typed -> zero delivered"
            `Quick test_connector_poll_messages_wrong_type;
          test_case
            "connector: poll garbage rows dropped, valid rows delivered (H9)"
            `Quick test_connector_poll_garbage_rows_dropped;
          test_case
            "connector: non-object response -> per-op error, --once exit 2"
            `Quick test_connector_non_object_response_start_once ] );
      ( "connector status honesty (H10)",
        [ test_case "register: dishonest 500+ok:true -> error, --once exit 2"
            `Quick test_connector_register_dishonest_500_ok_true;
          test_case "poll: dishonest 500+ok:true delivers nothing" `Quick
            test_connector_poll_dishonest_500_ok_true;
          test_case "register: honest 503 body passes through annotated"
            `Quick test_connector_register_honest_503_passthrough;
          test_case "PoW + rate-limit flows preserved on honest 429" `Quick
            test_connector_pow_and_rate_limit_flows_preserved ] );
      ( "fake/real equality (F5c)",
        [ test_case "shared semantic vectors match after normalization"
            `Quick test_fake_real_vector_equality ] );
    ]
