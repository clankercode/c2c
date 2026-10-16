(* P7.M1.E2.T001: host-owned mailboxes must reject every raw CLI consumer.

   These cases execute the shipped binaries with a known alias, rather than
   relying on inherited identity variables.  That is the important regression:
   a native provider child can always spell [--alias TARGET] explicitly. *)

open Alcotest

let ( // ) = Filename.concat

let remove path =
  if Sys.file_exists path then
    try Sys.remove path with _ -> ()

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
    really_input_string ic (in_channel_length ic))

let run ~exe ~root args =
  let out = Filename.temp_file "c2c-raw-guard-out-" ".txt" in
  let err = Filename.temp_file "c2c-raw-guard-err-" ".txt" in
  Fun.protect
    ~finally:(fun () -> remove out; remove err)
    (fun () ->
      let env =
        Unix.environment ()
        |> Array.to_list
        |> List.filter (fun value ->
               not (String.starts_with ~prefix:"C2C_HOST_OWNED_MAILBOX=" value)
               && not (String.starts_with ~prefix:"C2C_MCP_DISABLED=" value)
               && not (String.starts_with ~prefix:"C2C_NO_AUTO_REGISTER=" value)
               && not (String.starts_with ~prefix:"C2C_MCP_SESSION_ID=" value)
               && not (String.starts_with ~prefix:"C2C_MCP_BROKER_ROOT=" value))
        |> fun values ->
        ( "C2C_HOST_OWNED_MAILBOX=1"
        :: ("C2C_MCP_BROKER_ROOT=" ^ root) :: values )
        |> Array.of_list
      in
      let ofd = Unix.openfile out [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
      let efd = Unix.openfile err [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
      let pid = Unix.create_process_env exe
          (Array.of_list (exe :: args)) env Unix.stdin ofd efd in
      Unix.close ofd;
      Unix.close efd;
      let _, status = Unix.waitpid [] pid in
      let output = read_file out in
      let error = read_file err in
      status, output, error)

let status_code = function
  | Unix.WEXITED n -> n
  | Unix.WSIGNALED n -> 128 + n
  | Unix.WSTOPPED n -> 128 + n

let assert_rejected ~label (status, _output, error) =
  check bool (label ^ " exits nonzero") true (status_code status <> 0);
  check bool (label ^ " explains host ownership") true
    (String.contains error 'h'
     && let lower = String.lowercase_ascii error in
        let needle = "host owns this mailbox" in
        let n = String.length needle in
        let rec has i =
          i + n <= String.length lower
          && (String.sub lower i n = needle || has (i + 1))
        in
        has 0)

let temp_root () =
  let path = Filename.temp_file "c2c-raw-guard-root-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter (fun name -> rm_rf (path // name)) (Sys.readdir path);
      Unix.rmdir path
    end else Sys.remove path

let with_fixture f =
  let root = temp_root () in
  Fun.protect ~finally:(fun () -> rm_rf root) (fun () ->
    let broker = C2c_mcp.Broker.create ~root in
    let sid = "host-owned-target-session" in
    let alias = "host-owned-target" in
    C2c_mcp.Broker.register broker ~session_id:sid ~alias
      ~pid:None ~pid_start_time:None ();
    C2c_mcp.Broker.enqueue_message broker ~from_alias:"peer"
      ~to_alias:alias ~content:"queued DATA must remain" ();
    f ~root ~sid ~alias ~broker)

let c2c_path () =
  let exe = Sys.executable_name in
  let exe = if Filename.is_relative exe then Filename.concat (Sys.getcwd ()) exe else exe in
  let test_dir = Filename.dirname (try Unix.realpath exe with _ -> exe) in
  Filename.concat (Filename.dirname test_dir) "cli/c2c.exe"

let deliver_path () = Filename.concat (Filename.dirname (c2c_path ())) "c2c_deliver_inbox.exe"

let test_direct_alias_consumers_rejected () =
  with_fixture (fun ~root ~sid ~alias ~broker ->
    let c2c = c2c_path () in
    let commands = [
      ("poll-inbox", ["poll-inbox"; "--alias"; alias]);
      ("poll-inbox --wait", ["poll-inbox"; "--wait"; "--timeout"; "0.01"; "--alias"; alias]);
      ("wait-inbox", ["wait-inbox"; "--timeout"; "0.01"; "--alias"; alias]);
      ("peek-inbox", ["peek-inbox"; "--alias"; alias]);
      ("inbox", ["inbox"; "--alias"; alias]);
      ("monitor", ["monitor"; "--alias"; alias]);
      ("deliver watch", ["deliver"; "watch"; "--session-id"; sid]);
      ("deliver wake-watch", ["deliver"; "wake-watch"; "--session-id"; sid; "--once"]);
      ("deliver wake-watch unknown alias", ["deliver"; "wake-watch"; "--alias"; "unknown-host-owned-alias"; "--once"]);
      ("oc-plugin drain", ["oc-plugin"; "drain-inbox-to-spool"; "--spool-path"; root // "spool.json"; "--session-id"; sid]);
    ] in
    List.iter (fun (label, args) ->
      assert_rejected ~label (run ~exe:c2c ~root args);
      check int (label ^ " leaves queued DATA") 1
        (List.length (C2c_mcp.Broker.read_inbox broker ~session_id:sid))) commands)

let test_standalone_deliver_rejected () =
  with_fixture (fun ~root ~sid ~alias:_ ~broker ->
    assert_rejected ~label:"deliver-inbox"
      (run ~exe:(deliver_path ()) ~root ["--session-id"; sid]);
    check int "standalone deliver leaves queued DATA" 1
      (List.length (C2c_mcp.Broker.read_inbox broker ~session_id:sid)))

let test_host_transport_remains_available () =
  let root = temp_root () in
  Fun.protect ~finally:(fun () -> rm_rf root) (fun () ->
    let c2c = c2c_path () in
    let bind_status, bind_output, bind_error =
      run ~exe:c2c ~root
        [ "host"; "bind"; "--environment-id"; "guard-test-env";
          "--thread-id"; "guard-test-thread"; "--workspace"; root;
          "--owner-id"; "guard-test-owner"; "--broker-root"; root ]
    in
    check int "host bind remains available" 0 (status_code bind_status);
    check string "host bind has no stderr" "" bind_error;
    let binding = Yojson.Safe.from_string bind_output |> Yojson.Safe.Util.member "binding" in
    let get key = Yojson.Safe.Util.member key binding |> Yojson.Safe.Util.to_string in
    let peek_status, peek_output, _ =
      run ~exe:c2c ~root
        [ "host"; "peek"; "--environment-id"; "guard-test-env";
          "--thread-id"; "guard-test-thread"; "--broker-root"; root;
          "--generation"; get "generation" ]
    in
    check int "host peek remains available" 0 (status_code peek_status);
    check bool "host peek returns a response" true
      (String.length peek_output > 0))

let test_guard_predicate_env_contract () =
  let saved key = Sys.getenv_opt key in
  let restore key = function
    | Some value -> Unix.putenv key value
    | None -> Unix.putenv key ""
  in
  let previous = List.map (fun key -> key, saved key)
    ["C2C_HOST_OWNED_MAILBOX"; "C2C_MCP_DISABLED"; "C2C_NO_AUTO_REGISTER"] in
  Fun.protect
    ~finally:(fun () -> List.iter (fun (key, value) -> restore key value) previous)
    (fun () ->
      List.iter (fun key -> Unix.putenv key "") ["C2C_HOST_OWNED_MAILBOX"; "C2C_MCP_DISABLED"; "C2C_NO_AUTO_REGISTER"];
      check bool "raw consumers allowed by default" false
        (C2c_mcp.raw_consumers_disabled ());
      Unix.putenv "C2C_HOST_OWNED_MAILBOX" "1";
      check bool "host mode disables raw consumers" true
        (C2c_mcp.raw_consumers_disabled ());
      Unix.putenv "C2C_HOST_OWNED_MAILBOX" "";
      Unix.putenv "C2C_NO_AUTO_REGISTER" "1";
      check bool "no-auto-register disables raw consumers" true
        (C2c_mcp.raw_consumers_disabled ()))

let () =
  Alcotest.run "c2c raw consumer guard"
    [ ("guard", [
        ("direct alias consumers", `Quick, test_direct_alias_consumers_rejected)
      ; ("standalone deliver", `Quick, test_standalone_deliver_rejected)
      ; ("host transport", `Quick, test_host_transport_remains_available)
      ; ("predicate env contract", `Quick, test_guard_predicate_env_contract)
      ]) ]
