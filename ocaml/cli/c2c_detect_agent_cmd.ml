(* c2c_detect_agent_cmd — `c2c dev detect-agent-type` (B288).

   Prints the detected host client type and the raw signals detection consulted
   (env markers, PATH uniqueness, process ancestry, managed session-id prefix,
   resolved session id) so client detection can be verified from any shell
   without guessing which signal won. Useful for dogfooding B288 where a
   cursor-agent shell exports no CURSOR_* env and must still self-label
   `cursor`.

   Reuses the SAME detection entry points as init and MCP — no third detector
   (B134): [detected_client] is exactly [C2c_init_cmd.detect_client ()], and
   every displayed signal is a shared helper that detection itself consults
   ([C2c_mcp.inferred_client_type_from_env], [C2c_init_cmd.path_detected_clients],
   [C2c_init_cmd.session_id_prefix_match], [C2c_mcp.ancestor_command_names],
   [C2c_mcp.cursor_agent_process_ancestor]). Read-only; no message-triggered
   effect (B098 safe). *)

open Cmdliner.Term.Syntax

(* Client-type / session-id env markers detection reads, in the same spirit as
   [inferred_client_type_from_env]. Presence here is informational only — the
   authoritative verdict is [C2c_init_cmd.detect_client]. *)
let marker_env_vars =
  [ "C2C_MCP_CLIENT_TYPE"
  ; "C2C_MCP_SESSION_ID"
  ; "CODEX_THREAD_ID"
  ; "CLAUDE_SESSION_ID"
  ; "CLAUDE_CODE_SESSION_ID"
  ; "C2C_OPENCODE_SESSION_ID"
  ; "GROK_SESSION_ID"
  ; "GROK_AGENT"
  ; "ANTIGRAVITY_CONVERSATION_ID"
  ; "ANTIGRAVITY_HOOK_EVENT"
  ; "ANTIGRAVITY_LS_ADDRESS"
  ; "CURSOR_AGENT"
  ; "CURSOR_INVOKED_AS"
  ; "CURSOR_ASKPASS_SOCKET"
  ; "C2C_DETECT_ANCESTOR_COMMS"
  ]

let present_env_markers () =
  List.filter_map
    (fun k ->
      match Sys.getenv_opt k with
      | Some v when String.trim v <> "" -> Some (k, v)
      | _ -> None)
    marker_env_vars

type report =
  { detected : string option
  ; alias_prefix : string
  ; inferred_client_type : string option
  ; resolved_session_id : string option
  ; mcp_session_id : string option
  ; session_id_prefix_match : string option
  ; path_detected_clients : string list
  ; process_ancestry : string list
  ; cursor_agent_ancestor : bool
  ; env_markers : (string * string) list
  ; configurable_clients : string list
  }

let gather () : report =
  let detected = C2c_init_cmd.detect_client () in
  let mcp_session_id = Sys.getenv_opt "C2C_MCP_SESSION_ID" in
  let session_id_prefix_match =
    match mcp_session_id with
    | Some sid when String.trim sid <> "" ->
        C2c_init_cmd.session_id_prefix_match sid
    | _ -> None
  in
  { detected
  ; alias_prefix =
      C2c_setup.default_alias_prefix (Option.value ~default:"" detected)
    (* Shared MCP/init inference — [inferred_client_type_from_env] now folds in
       process ancestry as its last branch (B288), so this is NOT purely an
       env signal; the human/JSON labels say so. *)
  ; inferred_client_type = C2c_mcp.inferred_client_type_from_env ()
    (* Resolve the session id the SAME way the detected client would: the kimi
       (B233) and cursor (B284) fallbacks are keyed on [client_type], so a
       PATH-detected kimi with KIMI_SESSION_ID resolves rather than showing
       (none). *)
  ; resolved_session_id = C2c_mcp.session_id_from_env ?client_type:detected ()
  ; mcp_session_id
  ; session_id_prefix_match
  ; path_detected_clients = C2c_init_cmd.path_detected_clients ()
  ; process_ancestry = C2c_mcp.ancestor_command_names ()
  ; cursor_agent_ancestor = C2c_mcp.cursor_agent_process_ancestor ()
  ; env_markers = present_env_markers ()
  ; configurable_clients = C2c_setup.init_configurable_clients
  }

let json_of_report r =
  let so = function Some s -> `String s | None -> `Null in
  let sl xs = `List (List.map (fun s -> `String s) xs) in
  `Assoc
    [ ("detected_client", so r.detected)
    ; ("alias_prefix", `String r.alias_prefix)
    ; ("inferred_client_type", so r.inferred_client_type)
    ; ("resolved_session_id", so r.resolved_session_id)
    ; ("mcp_session_id", so r.mcp_session_id)
    ; ("session_id_prefix_match", so r.session_id_prefix_match)
    ; ("path_detected_clients", sl r.path_detected_clients)
    ; ("process_ancestry", sl r.process_ancestry)
    ; ("cursor_agent_ancestor", `Bool r.cursor_agent_ancestor)
    ; ( "env_markers"
      , `Assoc (List.map (fun (k, v) -> (k, `String v)) r.env_markers) )
    ; ("configurable_clients", sl r.configurable_clients)
    ]

let render_human r =
  let b = Buffer.create 512 in
  let p fmt = Printf.ksprintf (Buffer.add_string b) fmt in
  let opt = function Some s -> s | None -> "(none)" in
  p "Detected client:   %s\n" (opt r.detected);
  p "Alias prefix:      %s-\n" r.alias_prefix;
  p "Inferred (env+ancestry): %s\n" (opt r.inferred_client_type);
  p "Resolved session:  %s\n" (opt r.resolved_session_id);
  p "\nEnv markers:\n";
  (match r.env_markers with
   | [] -> p "  (none of the known client markers are set)\n"
   | ms -> List.iter (fun (k, v) -> p "  %s=%s\n" k v) ms);
  p "\nSession-id prefix: %s\n"
    (match r.mcp_session_id with
     | None | Some "" -> "C2C_MCP_SESSION_ID unset"
     | Some sid ->
         Printf.sprintf "%s -> %s" sid
           (match r.session_id_prefix_match with
            | Some c -> c
            | None -> "(no prefix match)"));
  p "PATH-detected:     %s\n"
    (match r.path_detected_clients with
     | [] -> "(none)"
     | cs -> String.concat ", " cs);
  p "Process ancestry:  %s\n"
    (match r.process_ancestry with
     | [] -> "(none)"
     | a -> String.concat ", " a);
  p "cursor-agent ancestor: %s\n"
    (if r.cursor_agent_ancestor then "yes" else "no");
  p "\nConfigurable clients (install/setup): %s\n"
    (String.concat ", " r.configurable_clients);
  Buffer.contents b

let run ~json =
  let r = gather () in
  if json then C2c_cli_helpers.print_json (json_of_report r)
  else print_string (render_human r)

let detect_agent_type_cmd =
  let+ json = C2c_cli_helpers.json_flag in
  run ~json

let detect_agent_type =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "detect-agent-type"
       ~doc:
         "Print the detected host client type and the detection signals \
          (env markers, PATH uniqueness, process ancestry, managed \
          session-id prefix). Read-only; useful for verifying client \
          detection (B288). Pass --json for machine-readable output.")
    detect_agent_type_cmd
