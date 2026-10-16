(* Real stdio entrypoints with hostile inherited identity/delivery configuration.
   Disabled mode must remain protocol-valid without becoming a second consumer. *)
open Yojson.Safe.Util
module B = C2c_mcp.Broker
let check = Alcotest.(check bool)
let temp () = let p=Filename.temp_file "c2c-disabled-" "" in Sys.remove p; Unix.mkdir p 0o700; p
let rec remove p =
  if Sys.is_directory p then begin Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p); Unix.rmdir p end
  else Sys.remove p
let with_root f = let p=temp () in Fun.protect ~finally:(fun () -> remove p) (fun () -> f p)
let rec snapshot root =
  if not (Sys.file_exists root) then [] else
  Sys.readdir root |> Array.to_list |> List.sort String.compare |> List.concat_map (fun name ->
    let path=Filename.concat root name in
    if Sys.is_directory path then (path,"directory") :: snapshot path
    else [path,C2c_io.read_file path])
let rpc id meth params = `Assoc ["jsonrpc",`String "2.0";"id",`Int id;"method",`String meth;"params",params]
let call id name args = rpc id "tools/call" (`Assoc ["name",`String name;"arguments",args])
let requests = [
  rpc 1 "initialize" (`Assoc ["protocolVersion",`String "2024-11-05";
    "capabilities",`Assoc ["experimental",`Assoc ["claude/channel",`Assoc []]];
    "clientInfo",`Assoc ["name",`String "disabled-test";"version",`String "1"]]);
  rpc 2 "tools/list" (`Assoc []);
  call 3 "poll_inbox" (`Assoc []);
  call 4 "register" (`Assoc ["alias",`String "must-not-register"]);
  call 5 "send" (`Assoc ["to_alias",`String "native";"content",`String "PRIVATE-MUST-NOT-LEAK"]);
  call 6 "join_room" (`Assoc ["room_id",`String "must-not-join"]);
  rpc 7 "prompts/list" (`Assoc []);
  rpc 8 "prompts/get" (`Assoc ["name",`String "c2c"]);
  rpc 9 "ping" (`Assoc []) ]
let inherited_env ~home ~broker =
  let overrides = [
    "HOME",home; "C2C_MCP_BROKER_ROOT",broker; "C2C_MCP_DISABLED","1";
    "C2C_MCP_SESSION_ID","native-session"; "C2C_MCP_AUTO_REGISTER_ALIAS","native";
    "C2C_MCP_AUTO_JOIN_ROOMS","must-not-join"; "C2C_NO_AUTO_REGISTER","0";
    "C2C_MCP_DEBUG","1"; "C2C_MCP_AUTO_DRAIN_CHANNEL","1";
    "C2C_MCP_CHANNEL_DELIVERY","1"; "C2C_MCP_SCHEDULE_TIMER","1";
    "C2C_MCP_FORCE_CAPABILITIES","experimental.claude/channel";
    "C2C_NUDGE_CADENCE_MINUTES","0.001"; "C2C_NUDGE_IDLE_MINUTES","0" ] in
  let inherited = Unix.environment () |> Array.to_list |> List.filter (fun entry ->
    not (List.exists (fun (key,_) -> String.starts_with ~prefix:(key^"=") entry) overrides)) in
  Array.of_list (List.map (fun (k,v) -> k^"="^v) overrides @ inherited)
let endpoints () =
  let dir=Filename.dirname Sys.executable_name in
  [Filename.concat dir "c2c_mcp_server.exe",[];
   Filename.concat dir "c2c_mcp_server_inner_bin.exe",[];
   Filename.concat dir "../cli/c2c.exe",["serve"];
   Filename.concat dir "../cli/c2c.exe",["mcp"]]
let run_process root env (exe,args) input_text =
  let input=Filename.concat root "input" and output=Filename.concat root "output"
  and err=Filename.concat root "stderr" in
  C2c_io.write_file input input_text;
  let infd=Unix.openfile input [Unix.O_RDONLY] 0 in
  let outfd=Unix.openfile output [Unix.O_WRONLY;Unix.O_CREAT;Unix.O_TRUNC] 0o600 in
  let errfd=Unix.openfile err [Unix.O_WRONLY;Unix.O_CREAT;Unix.O_TRUNC] 0o600 in
  let pid=Unix.create_process_env exe (Array.of_list (exe::args)) env infd outfd errfd in
  List.iter Unix.close [infd;outfd;errfd];
  let deadline=Unix.gettimeofday ()+.20. in
  let rec wait () = match Unix.waitpid [Unix.WNOHANG] pid with
    | 0,_ when Unix.gettimeofday () < deadline -> Unix.sleepf 0.01; wait ()
    | 0,_ -> Unix.kill pid Sys.sigkill; ignore (Unix.waitpid [] pid); Alcotest.fail "disabled MCP did not stop at EOF"
    | _,status -> status in
  let status=wait () in
  status, C2c_io.read_file output

let run root ~home ~broker endpoint =
  let status,raw=run_process root (inherited_env ~home ~broker) endpoint
    (String.concat "\n" (List.map Yojson.Safe.to_string requests)^"\n") in
  check "disabled MCP exits cleanly" true (status=Unix.WEXITED 0);
  let rows=String.split_on_char '\n' raw |> List.filter (fun s -> String.trim s<>"") |> List.map Yojson.Safe.from_string in
  Alcotest.(check int) "one response per request and no notifications" 9 (List.length rows);
  let response id=List.find (fun row -> row |> member "id" = `Int id) rows |> member "result" in
  check "initialize keeps protocol" true (response 1 |> member "protocolVersion" = `String "2024-11-05");
  check "no tool capability" true (response 1 |> member "capabilities" = `Assoc []);
  check "tool inventory empty" true (response 2 |> member "tools" = `List []);
  List.iter (fun id -> check "forced tool call rejected" true (response id |> member "isError" = `Bool true)) [3;4;5;6];
  check "no prompt inventory" true (response 7 |> member "prompts" = `List []);
  check "ping remains valid" true (response 9 = `Assoc []);
  check "body not reflected in disabled error" false
    (let needle="PRIVATE-MUST-NOT-LEAK" in
     let rec contains i = i+String.length needle<=String.length raw &&
       (String.sub raw i (String.length needle)=needle || contains (i+1)) in contains 0)
let test_existing_broker () = with_root (fun root ->
  let home=Filename.concat root "home" and broker=Filename.concat root "broker" in
  Unix.mkdir home 0o700;
  let b=B.create ~root:broker in
  B.register b ~session_id:"native-session" ~alias:"native" ~pid:None ~pid_start_time:None ();
  B.enqueue_message b ~from_alias:"peer" ~to_alias:"native" ~content:"retained" ();
  B.save_inbox b ~session_id:"orphan-source" [List.hd (B.read_inbox b ~session_id:"native-session")];
  ignore (B.capture_orphan_for_restart b ~session_id:"orphan-source");
  let orphan=Filename.concat broker "pending-orphan-replay.orphan-source.json" in
  Unix.rename orphan (Filename.concat broker "pending-orphan-replay.native-session.json");
  let expected=snapshot broker and expected_home=snapshot home in
  List.iter (fun endpoint ->
    run root ~home ~broker endpoint;
    check "broker remains byte-for-byte unchanged" true (snapshot broker=expected);
    check "no startup/debug files in HOME" true (snapshot home=expected_home)) (endpoints ()))
let test_absent_broker () = with_root (fun root ->
  let home=Filename.concat root "home" and broker=Filename.concat root "absent-broker" in
  Unix.mkdir home 0o700;
  List.iter (fun endpoint -> run root ~home ~broker endpoint;
    check "disabled server never creates broker" false (Sys.file_exists broker)) (endpoints ()))
let test_dispatch_guard () = with_root (fun root ->
  let b=B.create ~root in
  let before=snapshot root in
  let old=Sys.getenv_opt "C2C_MCP_DISABLED" in
  Unix.putenv "C2C_MCP_DISABLED" "1";
  Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_DISABLED" (Option.value old ~default:"")) (fun () ->
    let result=Lwt_main.run (C2c_mcp.handle_tool_call ~broker:b ~session_id_override:(Some "native-session")
      ~tool_name:"register" ~arguments:(`Assoc ["alias",`String "must-not-register"])) in
    check "direct dispatcher rejected" true (result |> member "isError" = `Bool true);
    check "direct dispatch has no broker mutation" true (snapshot root=before)))
let test_host_cli_unaffected () = with_root (fun root ->
  let home=Filename.concat root "home" and broker=Filename.concat root "broker" in
  Unix.mkdir home 0o700;
  let exe=Filename.concat (Filename.dirname Sys.executable_name) "../cli/c2c.exe" in
  let args=["host";"bind";"--environment-id";"host-env";"--thread-id";"host-thread";
    "--owner-id";"opaque-owner";"--owner-pid";string_of_int (Unix.getpid ());
    "--workspace";root;"--broker-root";broker] in
  let status,out=run_process root (inherited_env ~home ~broker) (exe,args) "" in
  check "host bind still succeeds" true (status=Unix.WEXITED 0);
  let result=Yojson.Safe.from_string out in
  check "host response stays versioned" true (result |> member "schema_version" = `Int 1);
  check "host is allowed to create its own registry" true (Sys.file_exists (Filename.concat broker "registry.json")))
let () = Alcotest.run "disabled MCP" ["host exclusion",[
  Alcotest.test_case "all real entrypoints preserve existing mail" `Quick test_existing_broker;
  Alcotest.test_case "all real entrypoints avoid bootstrap" `Quick test_absent_broker;
  Alcotest.test_case "direct dispatcher cannot bypass disabled mode" `Quick test_dispatch_guard;
  Alcotest.test_case "host CLI remains enabled" `Quick test_host_cli_unaffected]]
