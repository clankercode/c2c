(* test_c2c_agent_help.ml — drift guard for `c2c agent-help` (B006).

   The whole point of agent-help is that it cannot drift from the binary's
   real surface. These tests enforce that structurally:

   Pure (no binary):
   - The topic set equals the MCP tool registry [C2c_mcp.base_tool_names].
     Add/remove/rename a tool and this fails until agent-help follows.
   - Every advertised topic renders an MCP call + a CLI section.
   - Topic normalization accepts MCP/CLI/qualified/group forms.

   Integration (drives the built c2c.exe):
   - `c2c agent-help` and `c2c agent-help <topic>` resolve (exit 0) for every
     advertised topic — the literal "every advertised topic resolves" guard.
   - An unknown topic exits non-zero.
   - Every derived CLI command path resolves against the live binary
     (`c2c <path> --help` exits 0) — proving the name correspondence in
     c2c_agent_help.ml points only at real commands. *)

module SS = Set.Make (String)

(* Resolve c2c.exe relative to this test binary (staged alongside via the
   [(deps c2c.exe)] dune stanza). Mirrors test_c2c_await_reply.ml. *)
let c2c_binary =
  let exe = Sys.executable_name in
  Filename.concat (Filename.dirname exe) "c2c.exe"

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> try close_in ic with _ -> ())
    (fun () ->
      let n = in_channel_length ic in
      really_input_string ic n)

(* Run a c2c invocation with C2C_MCP_SESSION_ID cleared (so the run is a
   plain operator session and all tiers/groups are visible). Returns rc. *)
let run_rc args =
  Sys.command
    (Printf.sprintf "env -u C2C_MCP_SESSION_ID %s %s >/dev/null 2>&1"
       (Filename.quote c2c_binary) args)

(* As [run_rc] but captures stdout. *)
let run_capture args =
  let out = Filename.temp_file "c2c-agenthelp-" ".out" in
  let rc =
    Sys.command
      (Printf.sprintf "env -u C2C_MCP_SESSION_ID %s %s > %s 2>/dev/null"
         (Filename.quote c2c_binary) args (Filename.quote out))
  in
  let content = read_file out in
  (try Sys.remove out with _ -> ());
  (rc, content)

let contains ~needle s =
  let nl = String.length needle and sl = String.length s in
  if nl = 0 then true
  else
    let rec go i = if i + nl > sl then false
      else if String.sub s i nl = needle then true else go (i + 1)
    in
    go 0

(* --- pure tests --------------------------------------------------------- *)

let test_topics_match_mcp () =
  let topics = SS.of_list (C2c_agent_help.topic_names ()) in
  let mcp = SS.of_list C2c_mcp.base_tool_names in
  Alcotest.(check bool) "topic set is non-empty" true (not (SS.is_empty topics));
  Alcotest.(check (list string))
    "agent-help topics exactly match the MCP base tool registry"
    (SS.elements mcp) (SS.elements topics)

let test_every_topic_renders () =
  List.iter
    (fun t ->
      match C2c_agent_help.find_tool t with
      | None -> Alcotest.failf "topic %S did not resolve via find_tool" t
      | Some tool ->
          let out = C2c_agent_help.render_detail tool in
          Alcotest.(check bool)
            (Printf.sprintf "%s detail shows the MCP tool call" t)
            true
            (contains ~needle:("mcp__c2c__" ^ t) out);
          Alcotest.(check bool)
            (Printf.sprintf "%s detail has a CLI section" t)
            true (contains ~needle:"CLI:" out))
    (C2c_agent_help.topic_names ())

let test_normalize_forms () =
  let resolves thing expect =
    match C2c_agent_help.find_tool thing with
    | Some t ->
        Alcotest.(check string)
          (Printf.sprintf "%S resolves to %s" thing expect)
          expect t.C2c_agent_help.t_name
    | None -> Alcotest.failf "%S did not resolve" thing
  in
  resolves "poll_inbox" "poll_inbox";   (* MCP tool name *)
  resolves "poll-inbox" "poll_inbox";   (* CLI form *)
  resolves "mcp__c2c__send" "send";     (* fully-qualified MCP name *)
  resolves "SEND" "send";               (* case-insensitive *)
  resolves "rooms join" "join_room";    (* group CLI path *)
  resolves "server-info" "server_info"; (* mechanical hyphenation *)
  Alcotest.(check bool) "unknown topic resolves to None" true
    (C2c_agent_help.find_tool "definitely-not-a-topic" = None)

let test_cli_path_mapping () =
  (* MCP-only tools must have no CLI path; group tools must map to a path. *)
  Alcotest.(check bool) "set_dnd is MCP-only" true
    (C2c_agent_help.cli_path_for "set_dnd" = None);
  Alcotest.(check (option string)) "join_room -> rooms join"
    (Some "rooms join") (C2c_agent_help.cli_path_for "join_room");
  Alcotest.(check (option string)) "poll_inbox -> poll-inbox (mechanical)"
    (Some "poll-inbox") (C2c_agent_help.cli_path_for "poll_inbox")

(* --- integration tests (drive the live binary) -------------------------- *)

let test_overview_runs_and_lists_all () =
  let rc, out = run_capture "agent-help" in
  Alcotest.(check int) "`c2c agent-help` exits 0" 0 rc;
  List.iter
    (fun t ->
      Alcotest.(check bool)
        (Printf.sprintf "overview lists topic %s" t)
        true (contains ~needle:t out))
    (C2c_agent_help.topic_names ())

let test_every_topic_resolves_live () =
  List.iter
    (fun t ->
      let rc, out = run_capture (Printf.sprintf "agent-help %s" (Filename.quote t)) in
      Alcotest.(check int) (Printf.sprintf "`c2c agent-help %s` exits 0" t) 0 rc;
      Alcotest.(check bool)
        (Printf.sprintf "`c2c agent-help %s` shows an MCP call" t)
        true (contains ~needle:"mcp__c2c__" out))
    (C2c_agent_help.topic_names ())

let test_unknown_topic_errors () =
  let rc = run_rc "agent-help definitely-not-a-topic" in
  Alcotest.(check bool) "unknown topic exits non-zero" true (rc <> 0)

let test_cli_paths_exist_live () =
  List.iter
    (fun t ->
      match C2c_agent_help.cli_path_for t with
      | None -> ()
      | Some path ->
          let rc = run_rc (Printf.sprintf "%s --help" path) in
          Alcotest.(check int)
            (Printf.sprintf "`c2c %s --help` resolves (CLI path is real)" path)
            0 rc)
    (C2c_agent_help.topic_names ())

let () =
  Alcotest.run "c2c_agent_help"
    [ ( "pure",
        [ Alcotest.test_case "topics match the MCP registry" `Quick test_topics_match_mcp
        ; Alcotest.test_case "every topic renders MCP + CLI" `Quick test_every_topic_renders
        ; Alcotest.test_case "topic normalization forms" `Quick test_normalize_forms
        ; Alcotest.test_case "MCP-only vs group CLI mapping" `Quick test_cli_path_mapping
        ] )
    ; ( "integration",
        [ Alcotest.test_case "overview runs and lists all topics" `Quick test_overview_runs_and_lists_all
        ; Alcotest.test_case "every advertised topic resolves" `Quick test_every_topic_resolves_live
        ; Alcotest.test_case "unknown topic errors" `Quick test_unknown_topic_errors
        ; Alcotest.test_case "every CLI path resolves on the live binary" `Quick test_cli_paths_exist_live
        ] )
    ]
