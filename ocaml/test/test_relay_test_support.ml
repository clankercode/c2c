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

   ORDERING NOTE: the fork-based Relay_test_support cases run FIRST and
   the Lwt-based real-handler case runs LAST, so no Lwt engine state ever
   precedes a fork. *)

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
      (* Lwt-based case LAST: no Lwt engine state before the forking cases. *)
      ( "real handler (in-process production relay)",
        [ test_case "/health + /list over loopback" `Quick
            test_real_relay_health_and_list ] );
    ]
