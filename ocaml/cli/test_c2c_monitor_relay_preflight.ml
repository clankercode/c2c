open Alcotest
open Lwt.Infix

module P = C2c_monitor_relay_preflight
module RTSR = Relay_test_support_real

let relay_token = "b206-test-token"

let with_identity f =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "c2c-b206-preflight-%08x" (Random.bits ()))
  in
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () ->
      let identity_path = Filename.concat dir "identity.json" in
      let identity =
        Relay_identity.load_or_create_at
          ~path:identity_path ~alias_hint:"b206-probe"
      in
      f identity identity_path)

let is_bound relay alias =
  Option.is_some (Relay.InMemoryRelay.identity_pk_of relay ~alias)

let test_missing_binding_does_not_register () =
  with_identity (fun identity _identity_path ->
      RTSR.with_server ~token:relay_token (fun ~base_url ~relay ->
          P.check_lwt ~url:base_url ~token:relay_token ~alias:"b206-unbound"
            ~identity ~context:P.Direct_cli
            ~registration_policy:P.Registration_disabled ()
          >|= fun outcome ->
          (match outcome with
           | P.Off reason ->
               check bool "actionable off reason" true
                 (String.length reason > 0 && String.contains reason '`')
           | P.Ready _ -> fail "unbound alias must not arm relay watch");
          check bool "no implicit binding" false
            (is_bound relay "b206-unbound")))

let test_explicit_registration_binds_then_arms () =
  with_identity (fun identity _identity_path ->
      RTSR.with_server ~token:relay_token (fun ~base_url ~relay ->
          P.check_lwt ~url:base_url ~token:relay_token ~alias:"b206-explicit"
            ~identity ~context:P.Direct_cli
            ~registration_policy:P.Registration_allowed ()
          >|= fun outcome ->
          (match outcome with
           | P.Ready { registered = true } -> ()
           | _ -> fail "explicit registration should bind and arm");
          check bool "relay binding created" true
            (is_bound relay "b206-explicit")))

let test_refusal_never_binds () =
  with_identity (fun identity _identity_path ->
      RTSR.with_server ~token:relay_token (fun ~base_url ~relay ->
          P.check_lwt ~url:base_url ~token:relay_token ~alias:"b206-custom"
            ~identity ~context:P.Custom_key
            ~registration_policy:(P.Registration_refused "custom key") ()
          >|= fun outcome ->
          (match outcome with
           | P.Off reason ->
               check bool "refusal surfaced" true
                 (String.length reason >= String.length "relay alias registration refused")
           | P.Ready _ -> fail "refused registration must not arm");
          check bool "refusal did not bind" false
            (is_bound relay "b206-custom")))

let test_bound_alias_needs_no_registration () =
  with_identity (fun identity _identity_path ->
      RTSR.with_server ~token:relay_token (fun ~base_url ~relay ->
          P.register_alias_signed ~url:base_url ~token:relay_token ~alias:"b206-bound"
            ~identity ()
          >>= fun _ ->
          P.check_lwt ~url:base_url ~token:relay_token ~alias:"b206-bound"
            ~identity ~context:P.Direct_cli
            ~registration_policy:P.Registration_disabled ()
          >|= fun outcome ->
          (match outcome with
           | P.Ready { registered = false } -> ()
           | _ -> fail "bound alias should arm without a second registration");
          check bool "binding remains" true (is_bound relay "b206-bound")))

let slurp path =
  match open_in_bin path with
  | exception _ -> ""
  | ic ->
      Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
          really_input_string ic (in_channel_length ic))

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec loop i =
    i + nl <= hl && (String.sub haystack i nl = needle || loop (i + 1))
  in
  nl = 0 || loop 0

let wait_for ~timeout path needle =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    if contains (slurp path) needle then true
    else if Unix.gettimeofday () >= deadline then false
    else (Unix.sleepf 0.05; loop ())
  in
  loop ()

let c2c_bin = Filename.concat (Filename.dirname Sys.executable_name) "c2c.exe"

(* Command-level B206 regression: a session-registry alias changes while the
   monitor is alive. The replacement alias is also unbound. The monitor must
   issue a second signed /list preflight, keep relay OFF, and remain alive for
   local inbox watching instead of arming a doomed relay peek. *)
let test_unbound_rebind_keeps_local_monitor_alive () =
  let missing alias =
    Relay_test_support.response ~status:401
      (Yojson.Safe.to_string
         (`Assoc
           [ ("ok", `Bool false)
           ; ("error_code", `String "unauthorized")
           ; ("error", `String (Printf.sprintf "alias %S has no identity binding" alias))
           ]))
  in
  (* The response matcher need not know which signed alias was used; request
     capture below proves startup and rebind each probed /list. *)
  let route =
    Relay_test_support.route ~meth:"GET" ~path:"/list"
      [ missing "b206-unbound" ]
  in
  Relay_test_support.with_server ~routes:[ route ] (fun server ->
      with_identity (fun identity identity_path ->
          let base = Filename.dirname identity_path in
          let broker_root = Filename.concat base "broker" in
          Unix.mkdir broker_root 0o700;
          let broker = C2c_mcp.Broker.create ~root:broker_root in
          let sid = "b206-rebind-session" in
          C2c_mcp.Broker.register broker ~session_id:sid ~alias:"b206-old"
            ~pid:(Some (Unix.getpid ()))
            ~pid_start_time:(C2c_mcp.Broker.read_pid_start_time (Unix.getpid ())) ();
          let out_path = Filename.concat base "monitor.out" in
          let err_path = Filename.concat base "monitor.err" in
          let out_fd = Unix.openfile out_path [ Unix.O_WRONLY; Unix.O_CREAT ] 0o600 in
          let err_fd = Unix.openfile err_path [ Unix.O_WRONLY; Unix.O_CREAT ] 0o600 in
          let env =
            [| "PATH=" ^ Option.value (Sys.getenv_opt "PATH") ~default:"/usr/bin:/bin"
             ; "HOME=" ^ base
             ; "C2C_MCP_BROKER_ROOT=" ^ broker_root
             ; "C2C_MCP_SESSION_ID=" ^ sid
             ; "C2C_RELAY_URL=" ^ Relay_test_support.url server
             ; "C2C_RELAY_IDENTITY_PATH=" ^ identity_path
            |]
          in
          let pid =
            Unix.create_process_env c2c_bin
              [| c2c_bin; "monitor"; "--relay-interval"; "0.1" |]
              env Unix.stdin out_fd err_fd
          in
          Unix.close out_fd;
          Unix.close err_fd;
          Fun.protect
            ~finally:(fun () ->
              (try Unix.kill pid Sys.sigkill with _ -> ());
              (try ignore (Unix.waitpid [] pid) with _ -> ()))
            (fun () ->
              check bool "startup missing binding keeps relay off" true
                (wait_for ~timeout:4.0 out_path "local inbox watch continues");
              (match C2c_mcp.Broker.rename_alias broker ~session_id:sid
                       ~new_alias:"b206-new" with
               | Ok _ -> ()
               | Error e -> fail ("rename fixture failed: " ^ e));
              check bool "identity rebind observed" true
                (wait_for ~timeout:4.0 out_path "identity rebind:");
              check bool "rebind also keeps relay off" true
                (contains (slurp out_path) "b206-new is not registered"
                 || contains (slurp out_path) "alias \"b206-new\" is not registered");
              check bool "local monitor remains alive" true
                (try Unix.kill pid 0; true with _ -> false);
              let list_probes =
                Relay_test_support.requests server
                |> List.filter (fun r -> r.Relay_test_support.path = "/list")
              in
              check bool "startup + rebind each preflight" true
                (List.length list_probes >= 2))))

let () =
  run "c2c monitor relay preflight"
    [ ( "production loopback relay",
        [ test_case "missing binding stays off and does not bind" `Quick
            test_missing_binding_does_not_register
        ; test_case "explicit registration binds and arms" `Quick
            test_explicit_registration_binds_then_arms
        ; test_case "refused registration never binds" `Quick
            test_refusal_never_binds
        ; test_case "bound alias arms without registration" `Quick
            test_bound_alias_needs_no_registration
        ; test_case "unbound live rebind keeps local monitor alive" `Quick
            test_unbound_rebind_keeps_local_monitor_alive
        ] ) ]
