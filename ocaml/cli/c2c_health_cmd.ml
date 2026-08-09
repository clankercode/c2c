(* c2c_health_cmd — health, connect, verify, and host-id subcommands.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open Cmdliner.Term.Syntax
open C2c_cli_helpers
open C2c_types

let ( // ) = Filename.concat

let check_supervisor_config () =
  let env_sup =
    match Sys.getenv_opt "C2C_PERMISSION_SUPERVISOR" with
    | Some v when String.trim v <> "" -> Some v
    | _ -> (match Sys.getenv_opt "C2C_SUPERVISORS" with Some v when String.trim v <> "" -> Some v | _ -> None)
  in
  match env_sup with
  | Some v -> (`Green, Printf.sprintf "supervisor: %s (from env)" v)
  | None ->
      let sidecar = Filename.concat (Sys.getcwd ()) ".opencode/c2c-plugin.json" in
      let sidecar_sup =
        if Sys.file_exists sidecar then
          try
            let ic = open_in sidecar in
            let data = Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
              let n = in_channel_length ic in really_input_string ic n) in
            let j = Yojson.Safe.from_string data in
            let sup = Yojson.Safe.Util.(j |> member "supervisors") in
            let single = Yojson.Safe.Util.(j |> member "supervisor") in
            (match sup, single with
             | `List items, _ ->
                 let names = List.filter_map (function `String s -> Some s | _ -> None) items in
                 if names <> [] then Some (String.concat ", " names) else None
             | _, `String s when s <> "" -> Some s
             | _ -> None)
          with _ -> None
        else None
      in
      let repo_sup =
        let repo_cfg_path = Filename.concat (Sys.getcwd ()) ".c2c/repo.json" in
        if Sys.file_exists repo_cfg_path then
          try
            let ic = open_in repo_cfg_path in
            let data = Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
              let n = in_channel_length ic in really_input_string ic n) in
            let j = Yojson.Safe.from_string data in
            let sup = Yojson.Safe.Util.(j |> member "supervisors") in
            (match sup with
             | `List items ->
                 let names = List.filter_map (function `String s -> Some s | _ -> None) items in
                 if names <> [] then Some (String.concat ", " names) else None
             | _ -> None)
          with _ -> None
        else None
      in
       (match sidecar_sup, repo_sup with
        | Some v, _ -> (`Green, Printf.sprintf "supervisor: %s (from sidecar)" v)
        | _, Some v -> (`Green, Printf.sprintf "supervisor: %s (from .c2c/repo.json)" v)
        | None, None -> (`Yellow, "supervisor: coordinator1 (default — run: c2c init --supervisor <alias> or c2c repo set supervisor <alias>)"))

(* #511: check the resolved primary authorizer (first live/DnD-clear/idle-clear
   reviewer in the authorizers[] chain). Displayed in `c2c doctor`. *)
let check_authorizers () =
  match C2c_authorizers.get_authorizers () with
  | None ->
      (`Yellow, "authorizers: not configured (set in ~/.c2c/repo.json: {\"authorizers\":[\"alias1\",\"alias2\"]}; fallback: coordinator1 implicit)")
  | Some [] ->
      (`Yellow, "authorizers: [] (empty — no approval forwarding will succeed)")
  | Some names ->
      (match C2c_authorizers.resolve_first_authorizer () with
       | None ->
           (`Red, Printf.sprintf "authorizers: [%s] (none live/DnD-clear/idle-clear)"
              (String.concat ", " names))
       | Some first ->
           (`Green, Printf.sprintf "authorizers: [%s] → primary: %s"
              (String.concat ", " names) first))

(* #84: report world-writable shared configs; never silently change a mode.
   Logic and rationale live in C2c_config_modes — this is presentation only. *)
let check_shared_config_modes () : [ `Green | `Yellow | `Gray ] * string * string list =
  let v = C2c_config_modes.check () in
  (C2c_config_modes.color v, C2c_config_modes.message v, C2c_config_modes.offenders v)

(* Returns (color, human_line, optional reported relay version string).
   The version option feeds B268's cache-only "relay behind latest known"
   comparison — no second network probe. *)
let check_relay_http () =
  let url = match Sys.getenv_opt "C2C_RELAY_URL" with Some v when v <> "" -> v | _ -> "https://relay.c2c.im" in
  try
    let client = Relay.Relay_client.make ~timeout:5.0 url in
    let result = Lwt_main.run (Relay.Relay_client.health client) in
    let version = Yojson.Safe.Util.(result |> member "version" |> to_string_option |> Option.value ~default:"?") in
    let git_hash = Yojson.Safe.Util.(result |> member "git_hash" |> to_string_option |> Option.value ~default:"?") in
    let auth_mode = Yojson.Safe.Util.(result |> member "auth_mode" |> to_string_option |> Option.value ~default:"unknown") in
    let ok = Yojson.Safe.Util.(result |> member "ok") = `Bool true in
    let reported_version =
      let open Yojson.Safe.Util in
      match result |> member "version" |> to_string_option with
      | Some v when String.trim v <> "" && v <> "?" -> Some v
      | _ ->
          (match result |> member "server_version" |> to_string_option with
           | Some v when String.trim v <> "" && v <> "?" -> Some v
           | _ -> None)
    in
    (* B121: protocol skew is not "unreachable" — surface the upgrade text. *)
    if Relay.Relay_client.is_transport_error result then
      let err =
        Yojson.Safe.Util.(result |> member "error" |> to_string_option
                          |> Option.value ~default:"connection_error")
      in
      (`Red, Printf.sprintf "relay: unreachable (%s) (%s)" err url, None)
    else if Relay.Relay_client.is_protocol_incompatible result then
      let err =
        Yojson.Safe.Util.(result |> member "error" |> to_string_option
                          |> Option.value ~default:"incompatible protocol")
      in
      (`Red, Printf.sprintf "relay: incompatible — %s" err, reported_version)
    else if ok then
      let auth_str = match auth_mode with
        | "dev" -> " ⚠ dev mode (no auth)"
        | "prod" -> " prod mode"
        | _ -> ""  (* field absent in older relay versions — suppress *)
      in
      let local_hash = Option.value (git_shorthash ()) ~default:"?" in
      let stale_warn =
        if git_hash <> "?" && local_hash <> "?" && git_hash <> local_hash then begin
          let commits_ahead =
            let cmd = Printf.sprintf "git rev-list --count %s..HEAD 2>/dev/null" git_hash in
            match Unix.open_process_in cmd with
            | ic ->
                let n = try String.trim (input_line ic) with End_of_file -> "" in
                ignore (Unix.close_process_in ic);
                (match int_of_string_opt n with Some k when k > 0 ->
                   Printf.sprintf " (%d commit%s — run 'c2c doctor' for classification)" k (if k=1 then "" else "s")
                 | _ -> "")
            | exception _ -> ""
          in
          Printf.sprintf " ⚠ relay behind local (deployed: %s, local: %s)%s" git_hash local_hash commits_ahead
        end else ""
      in
      let color = if stale_warn <> "" then `Yellow else `Green in
      (color,
       Printf.sprintf "relay: reachable — %s @ %s%s%s (%s)" version git_hash auth_str stale_warn url,
       reported_version)
    else (`Red, Printf.sprintf "relay: error response from %s" url, reported_version)
  with exn ->
    (`Red, Printf.sprintf "relay: unreachable (%s)" (Printexc.to_string exn), None)

let check_plugin_installs () =
  let home = try Sys.getenv "HOME" with Not_found -> "" in
  let results = ref [] in
  let add r = results := r :: !results in

  (* Claude Code: PostToolUse hook in ~/.claude/settings.json *)
  let settings_path = home // ".claude" // "settings.json" in
  (if Sys.file_exists settings_path then
     try
       let ic = open_in settings_path in
       let data = Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
         let n = in_channel_length ic in really_input_string ic n) in
       let j = Yojson.Safe.from_string data in
       let hooks_str = Yojson.Safe.to_string Yojson.Safe.Util.(j |> member "hooks") in
       if String.length hooks_str > 2 && (let needle = "c2c" in
         let nl = String.length needle and ll = String.length hooks_str in
         let found = ref false in
         for i = 0 to ll - nl do
           if String.sub hooks_str i nl = needle then found := true
         done; !found)
       then add (`Green, "claude-code: PostToolUse hook configured")
       else add (`Yellow, "claude-code: no c2c hook (run: c2c install claude)")
     with _ -> add (`Gray, "claude-code: could not read settings.json")
   else add (`Gray, "claude-code: settings.json not found"));

  (* OpenCode: project-level plugin. Legacy global copies are ignored so a
     missing project-local install is not hidden by stale user-global state. *)
  let project_plugin = (Sys.getcwd ()) // ".opencode" // "plugins" // "c2c.ts" in
  let global_plugin = home // ".config" // "opencode" // "plugins" // "c2c.ts" in
  (if Sys.file_exists project_plugin then
     add (`Green, "opencode: plugin installed (project-level)")
   else if Sys.file_exists global_plugin then
     add (`Yellow, "opencode: project plugin not installed; ignoring legacy global plugin (run: c2c install opencode)")
   else
     add (`Yellow, "opencode: plugin not installed (run: c2c install opencode)"));

  (* GUI: check if webkit2gtk-4.1 is available (required to build/run Tauri GUI) *)
  let webkit_available =
    (* Try pkg-config first; fall back to checking for the library file directly *)
    Sys.command "pkg-config --exists webkit2gtk-4.1 2>/dev/null" = 0
    || (match Sys.command "ldconfig -p 2>/dev/null | grep -q webkit2gtk-4.1" with
       | 0 -> true | _ -> false)
  in
  (if webkit_available then
     add (`Green, "gui: webkit2gtk-4.1 available (can build/run Tauri GUI)")
   else
     add (`Yellow, "gui: webkit2gtk-4.1 missing — install: sudo pacman -S webkit2gtk-4.1"));

  (* Codex: check ~/.codex/config.toml for c2c MCP server entry *)
  let codex_config = home // ".codex" // "config.toml" in
  (if Sys.file_exists codex_config then
     try
       let ic = open_in codex_config in
       let data = Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
         let n = in_channel_length ic in really_input_string ic n) in
       let needle = "mcp_servers.c2c" in
       let nl = String.length needle and ll = String.length data in
       let found = ref false in
       for i = 0 to ll - nl do
         if String.sub data i nl = needle then found := true
       done;
       if !found then
         let codex_blocks = C2c_doctor_hooks.check_codex_managed_blocks () in
         if codex_blocks.installed && codex_blocks.total_issues > 0 then
           add (`Yellow, "codex: managed hooks/AGENTS.md blocks stale or missing (run: c2c install codex)")
         else
           add (`Green, "codex: MCP server configured")
       else
         add (`Yellow, "codex: config exists but no c2c MCP entry (run: c2c install codex)")
     with _ -> add (`Gray, "codex: could not read config.toml")
   else add (`Gray, "codex: config.toml not found (not installed or not configured)"));

  (* Kimi: check ~/.kimi-code/mcp.json for c2c entry *)
  let kimi_config = home // ".kimi-code" // "mcp.json" in
  (if Sys.file_exists kimi_config then
     try
       let ic = open_in kimi_config in
       let data = Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
         let n = in_channel_length ic in really_input_string ic n) in
       let j = Yojson.Safe.from_string data in
       let has_c2c = match Yojson.Safe.Util.(j |> member "mcpServers" |> member "c2c") with
         | `Null -> false | _ -> true
       in
       if has_c2c then
         add (`Green, "kimi: MCP server configured")
       else
         add (`Yellow, "kimi: mcp.json exists but no c2c entry (run: c2c install kimi)")
     with _ -> add (`Gray, "kimi: could not read mcp.json")
   else add (`Gray, "kimi: mcp.json not found (not installed or not configured)"));

  (* Grok: CLI-first — skill and/or SessionStart hooks under ~/.grok/ (no MCP). *)
  let grok_skill = home // ".grok" // "skills" // "c2c" // "SKILL.md" in
  let grok_hooks = home // ".grok" // "hooks" // "c2c-session.json" in
  (if Sys.file_exists grok_skill || Sys.file_exists grok_hooks then
     add (`Green, "grok: skill/hooks configured (CLI-first; run: c2c install grok)")
   else
     add (`Gray, "grok: not configured (run: c2c install grok)"));

  (* Antigravity (agy): CLI-first — skill and hooks under ~/.gemini/ (no MCP). *)
  let agy_skill = home // ".gemini" // "skills" // "c2c" // "SKILL.md" in
  let agy_hooks = home // ".gemini" // "config" // "hooks.json" in
  let has_agy_hooks =
    if Sys.file_exists agy_hooks then
      try
        let json = Yojson.Safe.from_file agy_hooks in
        match json with
        | `Assoc fields -> List.mem_assoc "c2c-hooks" fields
        | _ -> false
      with _ -> false
    else false
  in
  (if Sys.file_exists agy_skill || has_agy_hooks then
     add (`Green, "agy: skill/hooks configured (CLI-first; run: c2c install agy)")
   else
     add (`Gray, "agy: not configured (run: c2c install agy)"));

  (* Hermes: plugin-first — the Python plugin under ~/.hermes/plugins/c2c/
     plus the `plugins.enabled` entry in ~/.hermes/config.yaml (no MCP). Both
     halves are probed separately: the plugin files present but not enabled is
     the state in which install "succeeded" and nothing ever loads. *)
  let hermes_plugin = home // ".hermes" // "plugins" // "c2c" // "plugin.yaml" in
  let hermes_config = home // ".hermes" // "config.yaml" in
  let hermes_enabled =
    Sys.file_exists hermes_config
    && C2c_hermes_config.is_enabled (C2c_utils.read_file_opt hermes_config)
  in
  (if Sys.file_exists hermes_plugin && hermes_enabled then
     add (`Green, "hermes: plugin installed and enabled (CLI-first, no MCP)")
   else if Sys.file_exists hermes_plugin then
     add (`Yellow, "hermes: plugin installed but not in plugins.enabled (run: c2c install hermes)")
   else
     add (`Gray, "hermes: not configured (run: c2c install hermes)"));

  List.rev !results

(* Scan for running deprecated PTY-based wake daemons.
   Returns a list of (script_name, pids, fix_hint) for any that are running. *)
let check_deprecated_daemons () :
    (string * int list * string) list =
  let patterns =
    [ ( "c2c_claude_wake_daemon.py"
      , "deprecated: use /loop 4m in Claude Code instead" )
    ; ( "c2c_opencode_wake_daemon.py"
      , "deprecated: TypeScript plugin handles delivery; kill this daemon" )
    ; ( "c2c_kimi_wake_daemon.py"
      , "deprecated: kimi delivery now uses C2c_kimi_notifier" )
    ; ( "c2c_crush_wake_daemon.py"
      , "deprecated: Crush PTY wake is unreliable; no replacement" )
    ]
  in
  List.filter_map
    (fun (script, hint) ->
       (* Require python in the command to avoid matching pgrep/shell wrappers
          that contain the script name as part of an eval or snapshot string. *)
       let pattern = "python.*" ^ script in
       let cmd =
         Printf.sprintf "pgrep -a -f %s 2>/dev/null" (Filename.quote pattern)
       in
       let ic = Unix.open_process_in cmd in
       let lines = ref [] in
       (try
          while true do
            lines := input_line ic :: !lines
          done
        with End_of_file -> ());
       ignore (Unix.close_process_in ic);
       (* Filter: only keep lines where the process executable is python,
          not shell wrappers (zsh/bash eval) that contain the script name
          as part of a snapshot or pgrep invocation string. *)
       let is_python_proc line =
         let parts = String.split_on_char ' ' (String.trim line) in
         match parts with
         | _ :: cmd :: _ ->
             let base = Filename.basename cmd in
             let lc = String.lowercase_ascii base in
             String.length lc >= 6
             && String.sub lc 0 6 = "python"
         | _ -> false
       in
       let pids =
         List.filter_map
           (fun line ->
              if not (is_python_proc line) then None
              else
                let line = String.trim line in
                match String.split_on_char ' ' line with
                | pid_str :: _ -> (
                    match int_of_string_opt pid_str with
                    | Some pid -> Some pid
                    | None -> None)
                | [] -> None)
           !lines
       in
       if pids = [] then None else Some (script, pids, hint))
    patterns

(* PTY-inject capability check: managed kimi/codex/opencode deliver daemons
   use pidfd_getfd, which needs CAP_SYS_PTRACE when yama ptrace_scope >= 1.
   This surfaces the "forgot to setcap python3" footgun in `c2c health`. *)
let check_pty_inject_capability () : [ `Ok | `Missing_cap of string | `Unknown ] =
  let py =
    let ic = Unix.open_process_in "command -v python3 2>/dev/null" in
    let line = try input_line ic with End_of_file -> "" in
    ignore (Unix.close_process_in ic);
    if String.trim line = "" then "python3" else String.trim line
  in
  let yama_ok =
    try
      let ic = open_in "/proc/sys/kernel/yama/ptrace_scope" in
      let v = Fun.protect ~finally:(fun () -> close_in ic) (fun () -> String.trim (input_line ic)) in
      v = "0"
    with _ -> false
  in
  if yama_ok then `Ok
  else
    let cmd = Printf.sprintf "getcap %s 2>/dev/null" (Filename.quote py) in
    let ic = Unix.open_process_in cmd in
    let line = try input_line ic with End_of_file -> "" in
    ignore (Unix.close_process_in ic);
    let has_cap =
      let needle = "cap_sys_ptrace" in
      let nl = String.length needle and ll = String.length line in
      let rec loop i =
        if i + nl > ll then false
        else if String.sub line i nl = needle then true
        else loop (i + 1)
      in
      loop 0
    in
    if line = "" then `Missing_cap py
    else if has_cap then `Ok
    else `Missing_cap py

let health_cmd =
  let+ json = json_flag in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let root_exists = Sys.is_directory root in
  let registry_exists = Sys.file_exists (root // "registry.json") in
  let dead_letter_exists =
    Sys.file_exists (C2c_mcp.Broker.dead_letter_path broker)
  in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let liveness_counts = List.map C2c_mcp.Broker.registration_liveness_state regs in
  let alive_count   = List.filter (( = ) C2c_mcp.Broker.Alive)   liveness_counts |> List.length in
  let unknown_count = List.filter (( = ) C2c_mcp.Broker.Unknown) liveness_counts |> List.length in
  let dead_count    = List.filter (( = ) C2c_mcp.Broker.Dead)    liveness_counts |> List.length in
  let rooms = C2c_mcp.Broker.list_rooms broker in
  let pty_cap = check_pty_inject_capability () in
  let pty_cap_str = match pty_cap with
    | `Ok -> "ok"
    | `Missing_cap py -> Printf.sprintf "missing — `sudo setcap cap_sys_ptrace=ep %s` (only needed for Codex PTY notify daemon; OpenCode + Kimi use non-PTY delivery)" py
    | `Unknown -> "unknown"
  in
  let stale_daemons = check_deprecated_daemons () in
  let supervisor_check = check_supervisor_config () in
  let authorizers_check = check_authorizers () in
  let (mode_col, mode_msg, mode_offenders) = check_shared_config_modes () in
  let (rel_col, rel_msg, relay_version_opt) = check_relay_http () in
  let plugin_checks = check_plugin_installs () in
  let legacy_broker = C2c_broker_root_check.is_legacy_broker_root root in
  (* B268: client update + relay-behind from local changelog cache only.
     Relay version string comes from the probe already done by check_relay_http
     (no second network call). Cache miss / offline → silent. *)
  let client_latest =
    try C2c_changelog.latest_known_newer ~broker_root:root () with _ -> None
  in
  let relay_behind =
    try
      C2c_changelog.component_behind_latest ~reported:relay_version_opt
        ~broker_root:root ()
    with _ -> None
  in
  (* #9 split-brain: an XDG-profile broker (pre-2026-07 resolution order, or
     written by a session with a per-profile XDG_STATE_HOME) that the resolver
     no longer selects. Registrations there are invisible to peers on the
     canonical root. *)
  let xdg_split_brain = C2c_repo_fp.xdg_split_brain_broker () in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      let stale_json =
        `List
          (List.map
             (fun (script, pids, hint) ->
                `Assoc
                  [ ("script", `String script)
                  ; ("pids", `List (List.map (fun p -> `Int p) pids))
                  ; ("fix", `String hint)
                  ])
             stale_daemons)
      in
      let color_str = function `Green -> "green" | `Yellow -> "yellow" | `Red -> "red" | `Gray -> "gray" in
      let plugin_json = `List (List.map (fun (c, msg) -> `Assoc [("status", `String (color_str c)); ("message", `String msg)]) plugin_checks) in
      let (sup_col, sup_msg) = supervisor_check in
      let update_fields = C2c_changelog.update_status_json ~broker_root:root () in
      let relay_version_fields =
        match relay_behind with
        | None ->
            [ ("relay_behind_latest", `Bool false)
            ; ("relay_version",
               match relay_version_opt with Some v -> `String v | None -> `Null)
            ; ("relay_latest_known_version", `Null) ]
        | Some (reported, latest) ->
            [ ("relay_behind_latest", `Bool true)
            ; ("relay_version", `String reported)
            ; ("relay_latest_known_version", `String latest) ]
      in
      print_json
        (`Assoc
          ([ ("broker_root", `String root)
          ; ("legacy_broker_warning", `Bool legacy_broker)
          ; ("migrate_hint",
             if legacy_broker || xdg_split_brain <> None
             then `String "c2c migrate-broker --dry-run"
             else `Null)
          ; ("xdg_split_brain_broker",
             match xdg_split_brain with
             | Some p -> `String p
             | None -> `Null)
          ; ("root_exists", `Bool root_exists)
          ; ("registry_exists", `Bool registry_exists)
          ; ("dead_letter_exists", `Bool dead_letter_exists)
          ; ("registrations", `Int (List.length regs))
          ; ("alive", `Int alive_count)
          ; ("unknown", `Int unknown_count)
          ; ("dead", `Int dead_count)
          ; ("rooms", `Int (List.length rooms))
          ; ("pty_inject_cap", `String (match pty_cap with `Ok -> "ok" | `Missing_cap _ -> "missing" | `Unknown -> "unknown"))
          ; ("stale_deprecated_daemons", stale_json)
          ; ("supervisor", `Assoc [("status", `String (color_str sup_col)); ("message", `String sup_msg)])
          ; ("authorizers", `Assoc [("status", `String (color_str (fst authorizers_check))); ("message", `String (snd authorizers_check))])
          ; ("shared_config_modes",
             `Assoc
               [ ("status", `String (color_str mode_col))
               ; ("message", `String mode_msg)
               ; ("world_writable", `List (List.map (fun p -> `String p) mode_offenders)) ])
          ; ("relay", `Assoc [("status", `String (color_str rel_col)); ("message", `String rel_msg)])
          ; ("plugins", plugin_json)
          ]
          @ update_fields
          @ relay_version_fields))
  | Human ->
      let icon = function `Green -> "✓" | `Yellow -> "⚠" | `Red -> "✗" | `Gray -> "–" in
      if legacy_broker then
        print_string (C2c_broker_root_check.legacy_broker_warning_text root)
      else
        Printf.printf "broker root:    %s\n" root;
      (match xdg_split_brain with
       | Some p ->
           Printf.printf
             "\xe2\x9a\xa0 split-brain: broker data also exists at XDG-profile path %s\n\
             \  Registrations there are invisible to peers on the canonical root.\n\
             \  Run: c2c migrate-broker --dry-run   # audit what will move\n\
             \  Then: c2c migrate-broker             # merge into %s\n"
             p root
       | None -> ());
      Printf.printf "root exists:    %s\n" (string_of_bool root_exists);
      Printf.printf "registry:       %s\n" (string_of_bool registry_exists);
      Printf.printf "dead-letter:    %s\n" (string_of_bool dead_letter_exists);
      Printf.printf "registrations:  %d (%d alive, %d unknown, %d dead)\n"
        (List.length regs) alive_count unknown_count dead_count;
      Printf.printf "rooms:          %d\n" (List.length rooms);
      Printf.printf "pty-inject cap: %s\n" pty_cap_str;
      (match client_latest with
       | Some latest ->
           Printf.printf "%s %s\n" (icon `Yellow)
             (Printf.sprintf
                "update: newer release %s available (you're on %s) — run `c2c self-update`"
                latest Version.version)
       | None -> ());
      (match relay_behind with
       | Some (reported, latest) ->
           Printf.printf "%s %s\n" (icon `Yellow)
             (Printf.sprintf
                "relay: version %s is behind latest known %s (informational — deploy the relay host)"
                reported latest)
       | None -> ());
      let (sup_col, sup_msg) = supervisor_check in
      Printf.printf "%s %s\n" (icon sup_col) sup_msg;
      let (auth_col, auth_msg) = authorizers_check in
      Printf.printf "%s %s\n" (icon auth_col) auth_msg;
      Printf.printf "%s %s\n" (icon mode_col) mode_msg;
      List.iter (fun p -> Printf.printf "    %s\n" p) mode_offenders;
      Printf.printf "%s %s\n" (icon rel_col) rel_msg;
      List.iter (fun (c, msg) -> Printf.printf "%s %s\n" (icon c) msg) plugin_checks;
      if stale_daemons = [] then
        Printf.printf "stale daemons:  none\n"
      else begin
        Printf.printf "stale daemons:  %d deprecated process(es) running!\n"
          (List.length stale_daemons);
        List.iter
          (fun (script, pids, hint) ->
             let pid_str =
               String.concat ", " (List.map string_of_int pids)
             in
             Printf.printf "  ⚠  %s (pid %s)\n" script pid_str;
             Printf.printf "     fix: %s\n" hint;
             Printf.printf "     kill: kill %s\n" pid_str)
          stale_daemons
      end

(* --- subcommand: connect -------------------------------------------------- *)

let supported_clients = [ "claude"; "codex"; "opencode"; "kimi"; "grok"; "agy"; "hermes" ]

let connect_dashboard ~root ~broker ~output_mode =
  let broker_root = root in
  let root_exists = Sys.is_directory root in
  let registry_exists = Sys.file_exists (root // "registry.json") in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let liveness_counts = List.map C2c_mcp.Broker.registration_liveness_state regs in
  let alive_count = List.filter (( = ) C2c_mcp.Broker.Alive) liveness_counts |> List.length in
  let rooms = C2c_mcp.Broker.list_rooms broker in
  let plugin_checks = check_plugin_installs () in
  let (rel_col, rel_msg, _) = check_relay_http () in
  let whoami_result =
    match C2c_mcp.session_id_from_env () with
    | None -> None
    | Some sid ->
        let r = C2c_mcp.Broker.create ~root in
        let found = List.filter (fun (reg : C2c_mcp.registration) -> reg.session_id = sid) (C2c_mcp.Broker.list_registrations r) in
        match found with [ reg ] -> Some (sid, reg.alias) | _ -> None
  in
  let has_substring haystack needle =
    let hay_len = String.length haystack in
    let needle_len = String.length needle in
    let rec loop i =
      i + needle_len <= hay_len
      && (String.sub haystack i needle_len = needle || loop (i + 1))
    in
    needle_len = 0 || loop 0
  in
  let client_status client =
    let has_green = List.exists (fun (c, msg) ->
      c = `Green && has_substring msg client
    ) plugin_checks in
    let has_yellow = List.exists (fun (c, msg) ->
      c = `Yellow && has_substring msg client
    ) plugin_checks in
    if has_green then `Installed
    else if has_yellow then `Needs_install
    else `Not_found
  in
  let all_installed = List.for_all (fun c -> client_status c = `Installed) supported_clients in
  let any_configured = List.exists (fun c -> client_status c <> `Not_found) supported_clients in
  let next_action =
    if not root_exists then
      "broker root not found — run 'c2c init' to get started"
    else if not any_configured then
      "no clients configured — run 'c2c install <client>' (explicit MCP opt-in)"
    else if not all_installed then
      let missing = List.filter (fun c -> client_status c <> `Installed) supported_clients in
      Printf.sprintf "partially configured — run 'c2c install %s' for missing clients"
        (String.concat " / " missing)
    else if alive_count = 0 then
      "clients installed but no live session — restart your client or run 'c2c ping --verify'"
    else
      "you're connected! run 'c2c ping --verify' to confirm end-to-end delivery."
  in
  match output_mode with
  | Json ->
      let color_str = function `Green -> "green" | `Yellow -> "yellow" | `Red -> "red" | `Gray -> "gray" in
      let client_status_json c = match client_status c with
        | `Installed -> `String "installed"
        | `Needs_install -> `String "needs_install"
        | `Not_found -> `String "not_found"
      in
      print_json (`Assoc
        [ ("broker_root", `String broker_root)
        ; ("root_exists", `Bool root_exists)
        ; ("registry_exists", `Bool registry_exists)
        ; ("alive_registrations", `Int alive_count)
        ; ("rooms", `Int (List.length rooms))
        ; ("whoami", match whoami_result with
          | Some (sid, alias) -> `Assoc [("session_id", `String sid); ("alias", `String alias)]
          | None -> `Null)
        ; ("relay", `Assoc [("status", `String (color_str rel_col)); ("message", `String rel_msg)])
        ; ("clients", `Assoc (List.map (fun c -> (c, client_status_json c)) supported_clients))
        ; ("next_action", `String next_action)
        ; ("plugins", `List (List.map (fun (c, msg) -> `Assoc [("status", `String (color_str c)); ("message", `String msg)]) plugin_checks))
        ])
  | Human ->
      let icon = function `Green -> "✓" | `Yellow -> "⚠" | `Red -> "✗" | `Gray -> "–" in
      Printf.printf "c2c ping — connection status\n";
      Printf.printf "────────────────────────────────\n";
      Printf.printf "broker root:  %s\n" broker_root;
      Printf.printf "broker:       %s\n" (if root_exists then "present" else "MISSING");
      Printf.printf "registry:     %s\n" (if registry_exists then "present" else "MISSING");
      Printf.printf "sessions:     %d alive\n" alive_count;
      Printf.printf "rooms:        %d\n" (List.length rooms);
      (match whoami_result with
       | Some (_, alias) -> Printf.printf "your alias:   %s\n" alias
       | None -> Printf.printf "your alias:   (not registered in this session)\n");
      Printf.printf "%s %s\n" (icon rel_col) rel_msg;
      Printf.printf "\nclient status:\n";
      List.iter (fun (c, msg) -> Printf.printf "  %s %s\n" (icon c) msg) plugin_checks;
      Printf.printf "\n  → %s\n" next_action

let connect_verify ~root ~broker ~timeout_secs ~output_mode =
  let root_exists = Sys.is_directory root in
  if not root_exists then begin
    (match output_mode with
     | Json -> print_json (`Assoc [("status", `String "FAIL"); ("reason", `String "broker root not found")])
     | Human -> Printf.eprintf "FAIL: broker root not found — run 'c2c init' first.\n%!");
    exit 1
  end;
  let probe_sid = Printf.sprintf "connect-verify-%d" (Unix.getpid ()) in
  let session_id, alias =
    match C2c_mcp.session_id_from_env () with
    | Some sid ->
        let regs = C2c_mcp.Broker.list_registrations broker in
        (match List.find_opt (fun (reg : C2c_mcp.registration) -> reg.session_id = sid) regs with
         | Some reg -> (sid, reg.alias)
         | None -> (probe_sid, "__connect_verify__"))
    | None -> (probe_sid, "__connect_verify__")
  in
  let marker = Printf.sprintf "c2c-connect-verify-%d-%d"
    (Unix.gettimeofday () |> int_of_float)
    (Random.int 1000000)
  in
  C2c_mcp.Broker.register broker ~session_id ~alias ~pid:None ~pid_start_time:None ();
  C2c_mcp.Broker.enqueue_message broker
    ~from_alias:alias ~to_alias:alias ~content:marker
    ~deferrable:false ~ephemeral:false ();
  let inbox_before = C2c_mcp.Broker.read_inbox broker ~session_id in
  let real_messages = List.filter (fun (m : C2c_mcp.message) ->
    m.content <> marker
  ) inbox_before in
  let real_count = List.length real_messages in
  let deadline = Unix.gettimeofday () +. float_of_int timeout_secs in
  let found_drained_by = ref None in
  let rec poll () =
    if Unix.gettimeofday () >= deadline then ()
    else begin
      Unix.select [] [] [] 0.5 |> ignore;
      let archive_entries = C2c_mcp.Broker.read_archive broker ~session_id ~limit:10 in
      let match_entry = List.filter_map (fun (e : C2c_mcp.Broker.archive_entry) ->
        if e.ae_content = marker then Some e.ae_drained_by else None
      ) archive_entries in
      (match match_entry with
       | drained_by :: _ -> found_drained_by := Some drained_by
       | [] -> poll ())
    end
  in
  poll ();
  let inbox_after = C2c_mcp.Broker.read_inbox broker ~session_id in
  let real_after = List.filter (fun (m : C2c_mcp.message) ->
    m.content <> marker
  ) inbox_after in
  let real_survived = List.length real_after = real_count in
  let status, detail = match !found_drained_by with
    | Some drained_by ->
        let pass = "PASS: consumed by auto-delivery path " ^ drained_by in
        (0, pass)
    | None ->
        let inbox_has_marker = List.exists (fun (m : C2c_mcp.message) ->
          m.content = marker
        ) inbox_after in
        if inbox_has_marker then
          (0, "INCONCLUSIVE: marker still queued — restart your client / it may use poll delivery")
        else
          (1, "FAIL: marker gone from inbox but not in archive — broker/registration/config path broken")
  in
  let footnote = "\n  NOT PROVEN: your client's transcript visibility is client-specific and not CLI-observable.\n  This probe confirms broker delivery plumbing, not that the agent sees the message." in
  match output_mode with
  | Json ->
      let extra = if real_survived then [] else
        [("real_inbox_preserved", `Bool false); ("warning", `String "pre-existing inbox messages may have been disturbed")] in
      print_json (`Assoc ([
        ("status", `String (if status = 0 then (match !found_drained_by with Some _ -> "PASS" | None -> "INCONCLUSIVE") else "FAIL"));
        ("marker", `String marker);
        ("drained_by", match !found_drained_by with Some d -> `String d | None -> `Null);
        ("real_inbox_preserved", `Bool real_survived);
        ("timeout_secs", `Int timeout_secs);
      ] @ extra));
      if status <> 0 then exit status
  | Human ->
      Printf.printf "\n%s\n%s\n" detail footnote;
      if not real_survived then
        Printf.printf "  WARNING: pre-existing inbox messages were disturbed during probe.\n";
      if status <> 0 then exit status

(* Core logic shared by `c2c ping` (canonical) and the deprecated `c2c connect`
   alias. B095: `connect` name-collided with `relay connect` (the cross-host
   bridge), so the local connection-status / loopback-probe command was renamed
   to `ping`; `connect` is retained as a backward-compatible alias. *)
let ping_run ~json ~verify ~timeout =
  let output_mode = if json then Json else Human in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  if verify then
    connect_verify ~root ~broker ~timeout_secs:timeout ~output_mode
  else
    connect_dashboard ~root ~broker ~output_mode

let ping_cmd =
  let verify = Cmdliner.Arg.(value & flag & info ["verify"; "V"] ~doc:"Run a loopback delivery probe: enqueue a self-marker and check it reaches the archive.") in
  let timeout = Cmdliner.Arg.(value & opt int 5 & info ["timeout"; "t"] ~docv:"SECS" ~doc:"Seconds to wait for --verify delivery (default: 5).") in
  let+ json = json_flag
  and+ verify = verify
  and+ timeout = timeout in
  ping_run ~json ~verify ~timeout

(* Deprecated alias (B095): `c2c connect` now delegates to `c2c ping`. Prints a
   one-time stderr hint so users learn the new name and learn that the
   cross-host relay bridge is `c2c relay connect`. The hint goes to stderr so
   `--json` stdout stays machine-parseable. Existing scripts keep working. *)
let connect_deprecated_cmd =
  let verify = Cmdliner.Arg.(value & flag & info ["verify"; "V"] ~doc:"(deprecated alias for --verify)") in
  let timeout = Cmdliner.Arg.(value & opt int 5 & info ["timeout"; "t"] ~docv:"SECS" ~doc:"Seconds to wait for --verify delivery (default: 5).") in
  let+ json = json_flag
  and+ verify = verify
  and+ timeout = timeout in
  prerr_endline "note: 'c2c connect' is a deprecated alias for 'c2c ping' (local connection status / delivery probe).";
  prerr_endline "      For the cross-host relay bridge, use 'c2c relay connect'.";
  ping_run ~json ~verify ~timeout

let read_managed_instances () =
  let base = C2c_start.instances_dir in
  let dirs =
    if not (Sys.file_exists base) then []
    else
      Array.fold_left
        (fun acc name ->
           let full = base // name in
           if Sys.is_directory full && Sys.file_exists (full // "config.json")
           then full :: acc
           else acc)
        [] (Sys.readdir base)
  in
  List.sort String.compare dirs
  |> List.map (fun dir ->
         let name = Filename.basename dir in
         let config_path = dir // "config.json" in
         let config =
           try Some (Yojson.Safe.from_file config_path) with _ -> None
         in
         let config_string name fields =
           match List.assoc_opt name fields with Some (`String s) -> Some s | _ -> None
         in
         let config_float name fields =
           match List.assoc_opt name fields with
           | Some (`Float f) -> Some f
           | Some (`Int n) -> Some (float_of_int n)
           | _ -> None
         in
         let client =
           match config with
           | Some (`Assoc fields) ->
               (match List.assoc_opt "client" fields with Some (`String c) -> c | _ -> "?")
           | _ -> "?"
         in
         let created_at =
           match config with
           | Some (`Assoc fields) -> config_float "created_at" fields
           | _ -> None
         in
         let binary_path =
           match config with
           | Some (`Assoc fields) ->
               (match config_string "binary_override" fields with
                | Some path -> path
                | None ->
                    (match Hashtbl.find_opt C2c_start.clients client with
                     | Some cfg -> cfg.C2c_start.binary
                     | None -> client))
           | _ ->
               (match Hashtbl.find_opt C2c_start.clients client with
                | Some cfg -> cfg.C2c_start.binary
                | None -> client)
         in
         let status, pid =
           let outer_pid_path = dir // "outer.pid" in
           if Sys.file_exists outer_pid_path then begin
             let pid_s =
               let ic = open_in outer_pid_path in
               Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
                   let s = input_line ic in
                   String.trim s)
             in
             match int_of_string_opt pid_s with
             | Some pid ->
                 (try
                    ignore (Unix.kill pid 0);
                    ("running", Some pid)
                  with Unix.Unix_error _ -> ("stopped", Some pid))
             | None -> ("unknown", None)
           end
           else ("stopped", None)
          in
          let delivery_mode =
            C2c_start.delivery_mode ~client ~name ~binary_path ~start_time:created_at ()
          in
          (* T005: one delivery-mode vocabulary across status/instances/doctor.
             ONLY a codex instance whose app-server unit is online-attached
             (healthy remote TUI) reports "app-server". Starting units have no
             attached TUI yet, and failed/offline records are not a live path
             — all of those keep the truthful hook-boundary label; the
             app_server_status field carries the lifecycle detail. Never
             overclaim delivery. status_of_instance is ghost-proof (dead pids
             read as offline). *)
          let delivery_mode =
            if client <> "codex" then delivery_mode
            else
              let instance_dir = C2c_start.instance_dir name in
              match
                C2c_codex_session.status_of_instance ~instance_dir
              with
              | Some C2c_codex_session.Online_attached ->
                  (* B138: online-attached is only LIVE app-server delivery when
                     the deliver loop actually loaded a frontend thread. The
                     fail-closed helper (shared with `c2c doctor`) trusts the
                     unit-stamped persisted signal and reports degraded when no
                     thread loaded — or when the record is absent/stale — instead
                     of overclaiming "app-server". *)
                  if (try C2c_codex_session.online_attached_delivery_degraded
                            ~instance_dir ()
                      with _ -> true)
                  then
                    (* #31: name the REASON. A binding-refused unit has a loaded
                       thread and is delivering; labelling it "no thread loaded"
                       sends the operator after the wrong fix. *)
                    C2c_doctor_hooks.codex_delivery_mode_label
                      (if (try C2c_codex_session
                                 .online_attached_delivery_binding_refused
                                 ~instance_dir ()
                           with _ -> false)
                       then C2c_doctor_hooks.Cd_app_server_unbound
                       else C2c_doctor_hooks.Cd_app_server_degraded)
                  else "app-server"
              | Some (C2c_codex_session.Starting | C2c_codex_session.Offline
                     | C2c_codex_session.Failed_startup)
              | None -> delivery_mode
          in
          let tmux_location =
            let tmux_json_path = dir // "tmux.json" in
            if Sys.file_exists tmux_json_path then
              (try
                let json = Yojson.Safe.from_file tmux_json_path in
                match json with
                | `Assoc fields ->
                    (match List.assoc_opt "session" fields with
                     | Some (`String s) -> Some s
                     | _ -> None)
                | _ -> None
              with _ -> None)
            else None
           in
            let expected_cwd =
              let ec_path = C2c_start.expected_cwd_path name in
              if Sys.file_exists ec_path then
                (try
                   let ic = open_in ec_path in
                   Fun.protect ~finally:(fun () -> close_in ic)
                     (fun () -> try Some (String.trim (input_line ic)) with End_of_file -> None)
                 with _ -> None)
              else None
            in
            let mi_role =
              try
                let role_path = C2c_role.resolve_agent_path ~name ~client in
                if Sys.file_exists role_path then
                  let r = C2c_role.parse_file role_path in
                  Some r.C2c_role.role
                else None
              with _ -> None
            in
            { mi_name = name
           ; mi_client = client
           ; mi_status = status
           ; mi_delivery_mode = delivery_mode
           ; mi_pid = pid
           ; mi_created_at = created_at
           ; mi_tmux_location = tmux_location
           ; mi_expected_cwd = expected_cwd
           ; mi_role
           })

let safe_is_directory path =
  try Sys.file_exists path && Sys.is_directory path with Sys_error _ -> false

let rec rm_rf path =
  if safe_is_directory path then (
    Array.iter (fun entry -> rm_rf (path // entry)) (Sys.readdir path);
    Unix.rmdir path)
  else
    (try Sys.remove path with Sys_error _ -> ())

let prune_stopped_instances_older_than ~days ~instances_dir managed_instances =
  let cutoff = Unix.gettimeofday () -. (float_of_int days *. 86400.0) in
  let stale_instances =
    List.filter
      (fun (inst : managed_instance_view) ->
         inst.mi_status = "stopped"
         && (match inst.mi_created_at with
             | Some created_at -> created_at < cutoff
             | None -> false))
      managed_instances
  in
  List.iter
    (fun (inst : managed_instance_view) ->
       let path = instances_dir // inst.mi_name in
       if Sys.file_exists path then rm_rf path)
    stale_instances;
  stale_instances

let status_cmd =
  let min_messages =
    Cmdliner.Arg.(
      value
      & opt int 1
      & info [ "min-messages" ] ~docv:"N"
          ~doc:"Minimum total messages (sent+received) to include a peer.")
  in
  let check_relay =
    Cmdliner.Arg.(
      value
      & flag
      & info [ "relay" ]
          ~doc:"Also query the relay (best-effort, ~4s) for the current \
                alias's lease TTL/expiry. Default is offline-safe — no network \
                round-trip unless this flag is passed.")
  in
  let+ json = json_flag
  and+ min_messages = min_messages
  and+ check_relay = check_relay in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let now = Unix.gettimeofday () in
  let archive_dir = root // "archive" in

  let sent_by_alias = Hashtbl.create 16 in
  let received_by_sid = Hashtbl.create 16 in
  let last_sent_by_alias = Hashtbl.create 16 in
  let last_recv_by_sid = Hashtbl.create 16 in

  if safe_is_directory archive_dir then (
    let entries =
      try Array.to_list (Sys.readdir archive_dir)
      with Sys_error _ -> []
    in
    List.iter
      (fun fname ->
         if Filename.check_suffix fname ".jsonl" then (
           let session_id = Filename.chop_extension fname in
           let path = archive_dir // fname in
           try
             let ic = open_in path in
             Fun.protect
               ~finally:(fun () -> close_in_noerr ic)
               (fun () ->
                  let rec loop () =
                    match input_line ic with
                    | exception End_of_file -> ()
                    | line ->
                        let line = String.trim line in
                        if line <> "" then (
                          try
                            let json = Yojson.Safe.from_string line in
                            let open Yojson.Safe.Util in
                            let from_alias =
                              try json |> member "from_alias" |> to_string
                              with _ -> ""
                            in
                            let drained_at =
                              match json |> member "drained_at" with
                              | `Float f -> f
                              | `Int i -> float_of_int i
                              | _ -> 0.0
                            in
                            if from_alias <> "" && from_alias <> "c2c-system"
                            then (
                              let prev =
                                try Hashtbl.find sent_by_alias from_alias
                                with Not_found -> 0
                              in
                              Hashtbl.replace sent_by_alias from_alias
                                (prev + 1);
                              let prev_ts =
                                try Hashtbl.find last_sent_by_alias from_alias
                                with Not_found -> 0.0
                              in
                              if drained_at > prev_ts then
                                Hashtbl.replace last_sent_by_alias from_alias
                                  drained_at
                            );
                            let prev_recv =
                              try Hashtbl.find last_recv_by_sid session_id
                              with Not_found -> 0.0
                            in
                            if drained_at > prev_recv then
                              Hashtbl.replace last_recv_by_sid session_id
                                drained_at;
                            let prev_recv_count =
                              try Hashtbl.find received_by_sid session_id
                              with Not_found -> 0
                            in
                            Hashtbl.replace received_by_sid session_id
                              (prev_recv_count + 1)
                          with _ -> ());
                        loop ()
                  in
                  loop ())
           with Sys_error _ -> ()))
      entries
  );

  let goal_count = 20 in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let rooms = C2c_mcp.Broker.list_rooms broker in

  let alive_peers =
    List.filter_map
      (fun (r : C2c_mcp.registration) ->
         if C2c_mcp.Broker.registration_liveness_state r = C2c_mcp.Broker.Alive then (
           let sent =
             try Hashtbl.find sent_by_alias r.alias with Not_found -> 0
           in
           let received =
             try Hashtbl.find received_by_sid r.session_id with Not_found ->
               try Hashtbl.find received_by_sid r.alias with Not_found -> 0
           in
           if sent + received >= min_messages then
             let last_sent =
               try Hashtbl.find last_sent_by_alias r.alias
               with Not_found -> 0.0
             in
             let last_recv =
               try Hashtbl.find last_recv_by_sid r.session_id with Not_found ->
                 try Hashtbl.find last_recv_by_sid r.alias
                 with Not_found -> 0.0
             in
             let last_active = max last_sent last_recv in
             let goal_met = sent >= goal_count && received >= goal_count in
             Some (r.alias, sent, received, goal_met, last_active)
           else None)
         else None)
      regs
  in

  let dead_peer_count = List.length regs - List.length alive_peers in
  let overall_goal_met =
    alive_peers <> []
    && List.for_all (fun (_, _, _, gm, _) -> gm) alive_peers
  in
  let managed_instances = read_managed_instances () in
  (* B031: filter old stopped instances (>24h) from default status view *)
  let stopped_ttl_s = 24.0 *. 3600.0 in
  let (visible_instances, hidden_stopped_count) =
    let is_old_stopped (i : managed_instance_view) =
      i.mi_status <> "running"
      && (match i.mi_created_at with
          | Some created_at -> (now -. created_at) > stopped_ttl_s
          | None ->
              (* Fall back to dir mtime *)
              let inst_path = C2c_start.instances_dir // i.mi_name in
              try (now -. (Unix.stat inst_path).Unix.st_mtime) > stopped_ttl_s
              with _ -> false)
    in
    let visible = List.filter (fun i -> not (is_old_stopped i)) managed_instances in
    let hidden = List.length managed_instances - List.length visible in
    (visible, hidden)
  in

  (* B094: relay state (URL configured, current alias, identity fingerprint,
     host_id). Pure-local — no network. [check_relay] opts into a best-effort
     signed /list round-trip for the current alias's lease TTL/expiry. *)
  let relay_snap = C2c_relay_state.snapshot ~broker () in
  let relay_lease =
    if check_relay then
      Some (C2c_relay_state.fetch_alias_lease
              ~alias:relay_snap.C2c_relay_state.alias
              ~relay_url:relay_snap.C2c_relay_state.relay_url
              ~our_host_id:relay_snap.C2c_relay_state.host_id ())
    else None
  in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      let peer_json (alias, sent, received, goal_met, last_active) =
        `Assoc
          [ ("alias", `String alias)
          ; ("sent", `Int sent)
          ; ("received", `Int received)
          ; ("goal_met", `Bool goal_met)
          ; ("last_active_ts", `Float last_active)
          ]
      in
      let room_json (r : C2c_mcp.Broker.room_info) =
        let alive_members =
          List.filter_map
            (fun (m : C2c_mcp.Broker.room_member_info) ->
               if m.rmi_alive <> Some false then Some (`String m.rmi_alias)
               else None)
            r.ri_member_details
        in
        `Assoc
          [ ("room_id", `String r.ri_room_id)
          ; ("member_count", `Int r.ri_member_count)
          ; ("alive_count", `Int r.ri_alive_member_count)
          ; ("alive_members", `List alive_members)
          ]
      in
      print_json
        (`Assoc
           [ ("alive_peers", `List (List.map peer_json alive_peers))
           ; ("dead_peer_count", `Int dead_peer_count)
           ; ("total_peer_count", `Int (List.length regs))
           ; ( "managed_instances",
               `List
                 (List.map
                    (fun inst ->
                       `Assoc
                         [ ("name", `String inst.mi_name)
                         ; ("client", `String inst.mi_client)
                         ; ("status", `String inst.mi_status)
                         ; ("delivery_mode", `String inst.mi_delivery_mode)
                         ; ("pid", match inst.mi_pid with Some p -> `Int p | None -> `Null)
                         ])
                    visible_instances) )
           ; ("stopped_hidden", `Int hidden_stopped_count)
           ; ("rooms", `List (List.map room_json rooms))
           ; ("relay", C2c_relay_state.relay_json relay_snap relay_lease)
           ; ("overall_goal_met", `Bool overall_goal_met)
           ])
  | Human ->
      Printf.printf "c2c Status\n";
      Printf.printf "==================================================\n\n";
      Printf.printf "Alive peers (%d/%d):\n" (List.length alive_peers)
        (List.length regs);
      List.iter
        (fun (alias, sent, received, goal_met, last_active) ->
           let age =
             let delta = now -. last_active in
             if delta < 0.0 then "just now"
             else if delta < 60.0 then Printf.sprintf "%.0fs ago" delta
             else if delta < 3600.0 then
               Printf.sprintf "%.0fm ago" (delta /. 60.0)
             else if delta < 86400.0 then
               Printf.sprintf "%.0fh ago" (delta /. 3600.0)
             else Printf.sprintf "%.0fd ago" (delta /. 86400.0)
           in
           let status = if goal_met then "goal_met" else "pending" in
           Printf.printf "  %-20s sent=%3d recv=%3d  %-8s  last=%s\n" alias
             sent received status age)
        alive_peers;
      if alive_peers = [] then Printf.printf "  (none)\n";
      Printf.printf "\nRooms:\n";
      List.iter
        (fun (r : C2c_mcp.Broker.room_info) ->
           Printf.printf "  %-20s %d member(s), %d alive\n" r.ri_room_id
             r.ri_member_count r.ri_alive_member_count)
        rooms;
      if rooms = [] then Printf.printf "  (none)\n";
      Printf.printf "\nManaged instances:\n";
      List.iter
        (fun inst ->
           let pid_str =
             match inst.mi_pid with
             | Some pid -> Printf.sprintf " (pid %d)" pid
             | None -> ""
           in
           Printf.printf "  %-20s %-10s %-12s %s%s\n" inst.mi_name
             inst.mi_client inst.mi_status inst.mi_delivery_mode pid_str)
        visible_instances;
      if visible_instances = [] then Printf.printf "  (none)\n";
      if hidden_stopped_count > 0 then
        Printf.printf "  (%d stopped instance(s) hidden; use 'c2c dev instances --all' or 'c2c dev instances gc')\n" hidden_stopped_count;
      Printf.printf "  Run 'c2c dev instances' for full detail (includes created_at, tmux, cwd, role).\n";
      Printf.printf "\n";
      C2c_relay_state.print_relay_section relay_snap relay_lease ~now ();
      Printf.printf "\nOverall goal_met: %s\n"
        (if overall_goal_met then "YES" else "NO")

let status =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "status"
      ~doc:"Show compact swarm overview (peers, rooms, instances, relay state). \
            Addressing: bare <alias> = local; <alias>@<host_id> = cross-host \
            via relay (use 'c2c relay list' for peer host_ids; 'c2c host-id' \
            for your own). Pass --relay to query the live lease for your alias.")
    status_cmd

(* --- subcommand: verify --------------------------------------------------- *)

let verify_cmd =
  let alive_only =
    Cmdliner.Arg.(
      value & flag
      & info [ "alive-only" ] ~doc:"Exclude dead registrations from results.")
  in
  let min_messages =
    Cmdliner.Arg.(
      value
      & opt int 0
      & info [ "min-messages" ] ~docv:"N"
          ~doc:"Minimum total messages (sent+received) to include a peer.")
  in
  let+ json = json_flag
  and+ alive_only = alive_only
  and+ min_messages = min_messages in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let archive_dir = root // "archive" in
  let sent_by_alias = Hashtbl.create 16 in
  let received_by_sid = Hashtbl.create 16 in
  if safe_is_directory archive_dir then (
    let entries =
      try Array.to_list (Sys.readdir archive_dir)
      with Sys_error _ -> []
    in
    List.iter
      (fun fname ->
         if Filename.check_suffix fname ".jsonl" then (
           let session_id = Filename.chop_extension fname in
           let path = archive_dir // fname in
           try
             let ic = open_in path in
             Fun.protect
               ~finally:(fun () -> close_in_noerr ic)
               (fun () ->
                  let rec loop recv_count =
                    match input_line ic with
                    | exception End_of_file -> recv_count
                    | line ->
                        let line = String.trim line in
                        if line <> "" then (
                          try
                            let json = Yojson.Safe.from_string line in
                            let open Yojson.Safe.Util in
                            let from_alias =
                              try json |> member "from_alias" |> to_string
                              with _ -> ""
                            in
                            if from_alias <> "" && from_alias <> "c2c-system"
                            then (
                              let prev =
                                try Hashtbl.find sent_by_alias from_alias
                                with Not_found -> 0
                              in
                              Hashtbl.replace sent_by_alias from_alias
                                (prev + 1)
                            );
                            loop (recv_count + 1)
                          with _ -> loop recv_count
                        ) else loop recv_count
                  in
                  let recv_count = loop 0 in
                  Hashtbl.replace received_by_sid session_id recv_count)
           with Sys_error _ -> ()))
      entries
  );
  let goal_count = 20 in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let participants =
    List.filter_map
      (fun (r : C2c_mcp.registration) ->
         if alive_only && not (C2c_mcp.Broker.registration_liveness_state r = C2c_mcp.Broker.Alive) then
           None
         else (
           let sent =
             try Hashtbl.find sent_by_alias r.alias with Not_found -> 0
           in
           let received =
             try Hashtbl.find received_by_sid r.session_id with Not_found ->
               try Hashtbl.find received_by_sid r.alias with Not_found -> 0
           in
           if sent + received >= min_messages then
             Some (r.alias, sent, received)
           else None))
      regs
  in
  let goal_met =
    participants <> []
    && List.for_all
         (fun (_, s, r) -> s >= goal_count && r >= goal_count)
         participants
  in
  if json then
    print_json
      (`Assoc
         [ ( "participants"
           , `List
               (List.map
                  (fun (alias, sent, received) ->
                     `Assoc
                       [ ("alias", `String alias)
                       ; ("sent", `Int sent)
                       ; ("received", `Int received)
                       ])
                  participants) )
         ; ("goal_met", `Bool goal_met)
         ; ("source", `String "broker")
         ])
  else (
    List.iter
      (fun (alias, sent, received) ->
         let status =
           if sent >= goal_count && received >= goal_count then "goal_met"
           else "in_progress"
         in
         Printf.printf "%s: sent=%d received=%d status=%s\n" alias sent
           received status)
      participants;
    Printf.printf "goal_met: %s\n" (if goal_met then "yes" else "no"))

let verify =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "verify" ~doc:"Verify c2c message exchange progress.")
    verify_cmd

(* --- subcommand: host-id ------------------------------------------------- *)
(* Slice 1 of .collab/design/2026-06-17-c2c-opaque-host-id.md. Computes the
   opaque per-host identifier used by the relay to de-duplicate / route
   across machines without exposing project name or hostname. The recipe
   matches the extension's `computeHostHash` byte-for-byte (see
   ocaml/host_id.ml for the canonical implementation) so c2c and the
   pi-c2c extension produce the same value on the same host. *)
let host_id_cmd =
  let json =
    Cmdliner.Arg.(value & flag & info [ "json" ]
      ~doc:"Emit JSON output with the source kind/value + computed id.")
  in
  let+ json = json in
  let info = Host_id.compute_host_hash_with_source () in
  if json then
    print_endline (Yojson.Safe.to_string (`Assoc [
      "host_id", `String info.Host_id.host_id;
      "kind", `String info.kind;
      "value", `String info.value;
    ]))
  else
    print_endline info.Host_id.host_id

let host_id =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "host-id"
      ~doc:"Print the opaque per-host identifier (12 hex chars). \
            Same recipe as the extension's computeHostHash; pass it as \
            <alias>@<host_id> to `c2c relay register` for cross-machine \
            privacy (.collab/design/2026-06-18-relay-address-at-host-id.md).")
    host_id_cmd

let health = Cmdliner.Cmd.v (Cmdliner.Cmd.info "health" ~doc:"Show broker health diagnostics.") health_cmd
let ping = Cmdliner.Cmd.v (Cmdliner.Cmd.info "ping" ~doc:"Local connection status dashboard and loopback delivery probe (--verify).") ping_cmd
let connect = Cmdliner.Cmd.v (Cmdliner.Cmd.info "connect" ~doc:"DEPRECATED alias for 'ping' (local connection status / delivery probe). The cross-host relay bridge is 'relay connect'.") connect_deprecated_cmd
