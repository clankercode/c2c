(* test_c2c_hook_grok — SessionStart/SessionEnd for Grok (CLI-first).

   Grok cannot emit additionalContext; assert register + identity skill +
   SessionEnd deregister instead. *)

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
  end else Sys.remove path

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
  let dir = base // Printf.sprintf "c2c-hook-grok-%08x" (Random.bits ()) in
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
  let extra =
    String.concat " "
      (List.map (fun (k, v) -> Printf.sprintf "%s=%s" k (Filename.quote v))
         extra_env)
  in
  let cmd =
    Printf.sprintf
      "env -i HOME=%s PATH=%s C2C_MCP_BROKER_ROOT=%s %s %s hook grok < %s > %s 2> %s"
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

let session_id = "019f4fb9-3c7a-7720-96c2-5cacb719d951"

let session_start_payload_for sid =
  Printf.sprintf
    {|{"hook_event_name":"SessionStart","session_id":"%s","cwd":"/tmp/proj"}|}
    sid

let session_start_payload = session_start_payload_for session_id

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

let first_alias broker_root =
  match list_aliases broker_root with
  | a :: _ -> a
  | [] -> ""

let test_session_start_registers_and_writes_identity_skill () =
  with_ctx (fun ctx ->
    (* B173: seed a foreign default-alias — Grok must ignore it and mint grok-*. *)
    let alias_path = ctx.home // ".config" // "c2c" // "default-alias" in
    write_file alias_path "codex-stale-from-other-client\n";
    let rc, stdout, stderr =
      run_hook ctx ~payload:session_start_payload
        ~extra_env:[ ("GROK_SESSION_ID", session_id) ]
    in
    check int "exit 0" 0 rc;
    check string "no additionalContext stdout" "" (String.trim stdout);
    let aliases = list_aliases ctx.broker_root in
    check bool "registered exactly one alias" true (List.length aliases = 1);
    let alias = first_alias ctx.broker_root in
    check bool ("alias starts with grok-: " ^ alias) true
      (String.starts_with ~prefix:"grok-" alias);
    check bool "did not adopt foreign default-alias" true
      (not (List.mem "codex-stale-from-other-client" aliases));
    let id_skill =
      ctx.home // ".grok" // "skills" // "c2c-session" // "SKILL.md"
    in
    check bool "identity skill written" true (Sys.file_exists id_skill);
    let body = read_file id_skill in
    (* #22: identity-agnostic — must point at `c2c whoami` and must NOT embed
       the concrete alias or session_id (which would clobber across sessions). *)
    check bool "points at c2c whoami" true
      (contains ~haystack:body ~needle:"c2c whoami");
    check bool "concrete alias NOT embedded" false
      (contains ~haystack:body ~needle:alias);
    check bool "concrete session_id NOT embedded" false
      (contains ~haystack:body ~needle:session_id);
    if String.trim stderr <> "" && contains ~haystack:stderr ~needle:"failed"
    then failf "unexpected stderr: %s" stderr)

(* #22: two SessionStarts with DIFFERENT sessions (→ different aliases) must
   write byte-identical identity-skill content, so the fixed-path clobber is a
   harmless no-op instead of a last-writer-wins identity race. *)
let test_identity_skill_byte_stable_across_sessions () =
  with_ctx (fun ctx ->
    let sid1 = "019f4fb9-3c7a-7720-96c2-5cacb719d951" in
    let sid2 = "019aaaaa-1111-7222-8333-444455556666" in
    let id_skill =
      ctx.home // ".grok" // "skills" // "c2c-session" // "SKILL.md"
    in
    let rc1, _, _ =
      run_hook ctx ~payload:(session_start_payload_for sid1)
        ~extra_env:[ ("GROK_SESSION_ID", sid1) ]
    in
    check int "start1 exit 0" 0 rc1;
    check bool "skill written after start1" true (Sys.file_exists id_skill);
    let body1 = read_file id_skill in
    let rc2, _, _ =
      run_hook ctx ~payload:(session_start_payload_for sid2)
        ~extra_env:[ ("GROK_SESSION_ID", sid2) ]
    in
    check int "start2 exit 0" 0 rc2;
    let body2 = read_file id_skill in
    check string "identity skill byte-identical after 2nd SessionStart"
      body1 body2;
    (* Two distinct grok- aliases are now registered, yet neither leaks into
       the shared identity skill. *)
    let aliases = list_aliases ctx.broker_root in
    check bool "two distinct aliases registered" true
      (List.length (List.sort_uniq String.compare aliases) >= 2);
    List.iter
      (fun a ->
        check bool ("alias not embedded in skill: " ^ a) false
          (contains ~haystack:body1 ~needle:a))
      aliases)

let test_session_end_deregisters () =
  with_ctx (fun ctx ->
    (* Foreign default-alias must not become the registered identity. *)
    write_file
      (ctx.home // ".config" // "c2c" // "default-alias")
      "codex-should-not-register\n";
    let rc1, _, _ =
      run_hook ctx ~payload:session_start_payload
        ~extra_env:[ ("GROK_SESSION_ID", session_id) ]
    in
    check int "start exit 0" 0 rc1;
    let alias = first_alias ctx.broker_root in
    check bool ("registered grok- alias before end: " ^ alias) true
      (String.starts_with ~prefix:"grok-" alias);
    let rc2, _, _ =
      run_hook ctx ~payload:session_end_payload
        ~extra_env:[ ("GROK_SESSION_ID", session_id) ]
    in
    check int "end exit 0" 0 rc2;
    check bool "deregistered after end" false
      (List.mem alias (list_aliases ctx.broker_root));
    let id_skill =
      ctx.home // ".grok" // "skills" // "c2c-session" // "SKILL.md"
    in
    check bool "identity skill removed on SessionEnd" false
      (Sys.file_exists id_skill))

let test_malformed_payload_exits_0 () =
  with_ctx (fun ctx ->
    let rc, stdout, _ = run_hook ctx ~payload:"not-json{" in
    check int "exit 0" 0 rc;
    check string "empty stdout" "" (String.trim stdout))

let () =
  Random.self_init ();
  run "c2c_hook_grok"
    [ ( "hook_grok"
      , [ test_case "SessionStart registers + identity skill" `Quick
            test_session_start_registers_and_writes_identity_skill
        ; test_case "identity skill byte-stable across sessions" `Quick
            test_identity_skill_byte_stable_across_sessions
        ; test_case "SessionEnd deregisters" `Quick
            test_session_end_deregisters
        ; test_case "malformed payload exit 0" `Quick
            test_malformed_payload_exits_0
        ] )
    ]
