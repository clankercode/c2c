(* test_c2c_hook_kimi — SessionStart/SessionEnd for Kimi Code.

   Kimi receives inbound messages via REST prompt injection. The hook
   auto-registers on SessionStart, writes a c2c-session identity skill with a
   receive-path nudge (B238), and deregisters on SessionEnd. Tests set
   C2C_KIMI_HOOK_SKIP_NOTIFIER=1 so we never fork a real notifier daemon. *)

open Alcotest

let ( // ) = Filename.concat

let contains ~haystack ~needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else
    let rec at i =
      i + nl <= hl && (String.sub haystack i nl = needle || at (i + 1))
    in
    at 0

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun child -> remove_tree (path // child)) (Sys.readdir path);
    Unix.rmdir path
  end else
    Sys.remove path

let mkdir_p path =
  let rec loop p =
    if Sys.file_exists p then ()
    else begin
      loop (Filename.dirname p);
      try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  if path <> "" && path <> Filename.dirname path then loop path

let read_file path =
  if not (Sys.file_exists path) then ""
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      really_input_string ic (in_channel_length ic))

let write_file path content =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc content)

let c2c_binary = Filename.dirname Sys.executable_name // "c2c.exe"

type env_ctx = { home : string; broker_root : string }

let with_ctx f =
  let base = Filename.get_temp_dir_name () in
  let dir = base // Printf.sprintf "c2c-hook-kimi-%08x" (Random.bits ()) in
  let home = dir // "home" in
  let broker_root = dir // "broker" in
  mkdir_p home;
  mkdir_p broker_root;
  Fun.protect
    ~finally:(fun () -> try remove_tree dir with _ -> ())
    (fun () -> f { home; broker_root })

let run_hook ?(extra_env = []) ctx ~payload =
  let dir = Filename.dirname ctx.home in
  let payload_path = dir // "payload.json" in
  let out_path = dir // "hook.out" in
  let err_path = dir // "hook.err" in
  write_file payload_path payload;
  (* Always skip real notifier fork in hermetic tests (B238). *)
  let extra_env =
    ("C2C_KIMI_HOOK_SKIP_NOTIFIER", "1") :: extra_env
  in
  let extra =
    String.concat " "
      (List.map (fun (k, v) -> Printf.sprintf "%s=%s" k (Filename.quote v))
         extra_env)
  in
  let cmd =
    Printf.sprintf
      "env -i HOME=%s PATH=%s C2C_MCP_BROKER_ROOT=%s %s %s hook kimi < %s > %s 2> %s"
      (Filename.quote ctx.home)
      (Filename.quote (Sys.getenv "PATH"))
      (Filename.quote ctx.broker_root)
      extra
      (Filename.quote c2c_binary)
      (Filename.quote payload_path)
      (Filename.quote out_path)
      (Filename.quote err_path)
  in
  let rc = Sys.command cmd in
  (rc, read_file out_path, read_file err_path)

let identity_skill_path ctx =
  ctx.home // ".kimi-code" // "skills" // "c2c-session" // "SKILL.md"

let session_id = "019f4fb9-3c7a-7720-96c2-5cacb719d951"

let session_start_payload =
  Printf.sprintf
    {|{"hook_event_name":"SessionStart","session_id":"%s","cwd":"/tmp/proj"}|}
    session_id

let session_end_payload =
  Printf.sprintf
    {|{"hook_event_name":"SessionEnd","session_id":"%s"}|}
    session_id

let list_aliases broker_root =
  let registry = broker_root // "registry.json" in
  if not (Sys.file_exists registry) then []
  else
    let extract_regs = function
      | `List regs -> regs
      | `Assoc fields ->
          (match List.assoc_opt "registrations" fields with
           | Some (`List regs) -> regs
           | _ -> [])
      | _ -> []
    in
    extract_regs (Yojson.Safe.from_string (read_file registry))
    |> List.filter_map (function
         | `Assoc r ->
             (match List.assoc_opt "alias" r with
              | Some (`String a) -> Some a
              | _ -> None)
         | _ -> None)

let list_registrations broker_root =
  let registry = broker_root // "registry.json" in
  if not (Sys.file_exists registry) then []
  else
    let extract_regs = function
      | `List regs -> regs
      | `Assoc fields ->
          (match List.assoc_opt "registrations" fields with
           | Some (`List regs) -> regs
           | _ -> [])
      | _ -> []
    in
    extract_regs (Yojson.Safe.from_string (read_file registry))
    |> List.filter_map (function
         | `Assoc r ->
             (match List.assoc_opt "session_id" r, List.assoc_opt "alias" r with
              | Some (`String sid), Some (`String a) -> Some (sid, a)
              | _ -> None)
         | _ -> None)

let test_session_start_auto_registers_from_env_alias () =
  with_ctx (fun ctx ->
    let rc, stdout, stderr =
      run_hook ctx ~payload:session_start_payload
        ~extra_env:
          [ ("C2C_MCP_SESSION_ID", session_id)
          ; ("C2C_MCP_AUTO_REGISTER_ALIAS", "kimi-env-alias")
          ; ("C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN", "1")
          ]
    in
    check int "exit 0" 0 rc;
    check string "empty stdout" "" (String.trim stdout);
    let regs = list_registrations ctx.broker_root in
    check bool "registered exactly one alias" true (List.length regs = 1);
    let sid, alias = List.hd regs in
    check string "session id matches" session_id sid;
    check string "alias from env" "kimi-env-alias" alias;
    if String.trim stderr <> "" && contains ~haystack:stderr ~needle:"failed"
    then failf "unexpected stderr: %s" stderr;
    (* B238: identity skill with receive-path nudge *)
    let skill = read_file (identity_skill_path ctx) in
    check bool "identity skill written" true (String.length skill > 0);
    check bool "skill names alias" true
      (contains ~haystack:skill ~needle:"kimi-env-alias");
    check bool "skill mentions receive path" true
      (contains ~haystack:skill ~needle:"Monitor"
       || contains ~haystack:skill ~needle:"poll-inbox"
       || contains ~haystack:skill ~needle:"notifier"))

let test_session_start_auto_registers_with_auto_gen_alias () =
  with_ctx (fun ctx ->
    let rc, stdout, _ =
      run_hook ctx ~payload:session_start_payload
        ~extra_env:[ ("C2C_MCP_SESSION_ID", session_id) ]
    in
    check int "exit 0" 0 rc;
    check string "empty stdout" "" (String.trim stdout);
    let aliases = list_aliases ctx.broker_root in
    check bool "registered exactly one alias" true (List.length aliases = 1);
    let alias = List.hd aliases in
    check bool ("alias starts with kimi-: " ^ alias) true
      (String.starts_with ~prefix:"kimi-" alias))

let test_session_end_deregisters () =
  with_ctx (fun ctx ->
    let rc1, _, _ =
      run_hook ctx ~payload:session_start_payload
        ~extra_env:
          [ ("C2C_MCP_SESSION_ID", session_id)
          ; ("C2C_MCP_AUTO_REGISTER_ALIAS", "kimi-end-test")
          ; ("C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN", "1")
          ]
    in
    check int "start exit 0" 0 rc1;
    check bool "registered before end" true
      (List.mem "kimi-end-test" (list_aliases ctx.broker_root));
    check bool "identity skill present before end" true
      (Sys.file_exists (identity_skill_path ctx));
    let rc2, _, _ =
      run_hook ctx ~payload:session_end_payload
        ~extra_env:[ ("C2C_MCP_SESSION_ID", session_id) ]
    in
    check int "end exit 0" 0 rc2;
    check bool "deregistered after end" false
      (List.mem "kimi-end-test" (list_aliases ctx.broker_root));
    check bool "identity skill removed on end" false
      (Sys.file_exists (identity_skill_path ctx)))

let test_malformed_payload_exits_0 () =
  with_ctx (fun ctx ->
    let rc, stdout, _ = run_hook ctx ~payload:"not-json{" in
    check int "exit 0" 0 rc;
    check string "empty stdout" "" (String.trim stdout))

let () =
  Random.self_init ();
  run "c2c_hook_kimi"
    [ ( "hook_kimi"
      , [ test_case "SessionStart registers from env alias" `Quick
            test_session_start_auto_registers_from_env_alias
        ; test_case "SessionStart auto-generates kimi- alias" `Quick
            test_session_start_auto_registers_with_auto_gen_alias
        ; test_case "SessionEnd deregisters" `Quick
            test_session_end_deregisters
        ; test_case "malformed payload exit 0" `Quick
            test_malformed_payload_exits_0
        ] )
    ]
