(* c2c_setup.ml — extracted from c2c.ml (Phase 1 split) *)

(* This module is part of the c2c executable. All files in the executable
   are compiled together; no open/include needed to reference values across files. *)

let ( // ) = Filename.concat
open Cmdliner.Term.Syntax
open C2c_mcp
open C2c_types

let json_flag =
  Cmdliner.Arg.(value & flag & info [ "json"; "j" ] ~doc:"Output machine-readable JSON.")

let resolve_claude_dir () =
  match Sys.getenv_opt "CLAUDE_CONFIG_DIR" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ ->
      let dot_claude = Filename.concat (Sys.getenv "HOME") ".claude" in
      (try
         let rec resolve_link p max_depth =
           if max_depth <= 0 then p
           else
             let stat = Unix.lstat p in
             if stat.Unix.st_kind = Unix.S_LNK then
               let target = Unix.readlink p in
               let resolved = if Filename.is_relative target then
                               Filename.concat (Filename.dirname p) target
                             else target in
               resolve_link resolved (max_depth - 1)
             else p
         in
         resolve_link dot_claude 10
       with _ -> dot_claude)

let current_c2c_command () =
  let fallback =
    if Array.length Sys.argv > 0 then Sys.argv.(0) else "c2c"
  in
  let resolved =
    try Unix.readlink "/proc/self/exe"
    with Unix.Unix_error _ -> fallback
  in
  if Filename.is_relative resolved then Sys.getcwd () // resolved else resolved

(* resolve_broker_root — delegates to C2c_utils.resolve_broker_root which has
   the authoritative resolution order (coord1 2026-04-26). *)
let resolve_broker_root () = C2c_utils.resolve_broker_root ()

let print_json json =
  Yojson.Safe.pretty_to_channel stdout json;
  print_newline ()

(* Note: resolve_claude_dir and current_c2c_command are defined above. The
   duplicates that previously appeared here were dead code (shadowed by the
   identical earlier definitions); removed by #334. *)

(* References to c2c.ml definitions needed here are accessed directly.
   C2c_start module is from the c2c_mcp library. *)

let find_ocaml_server_path () =
  (* Look for c2c_mcp_server.exe in _build, then try opam *)
  let candidates = [
    "_build/default/ocaml/server/c2c_mcp_server.exe";
    "_build/ocaml/server/c2c_mcp_server.exe";
  ] in
  let extra_candidates =
    try
      let switch = Sys.getenv "OPAM_SWITCH_PREFIX" in
      [ switch // "bin/c2c_mcp_server" ]
    with Not_found -> []
  in
  let all = candidates @ extra_candidates in
  List.find_opt Sys.file_exists all

let json_read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    let s = really_input_string ic (in_channel_length ic) in
    Yojson.Safe.from_string s)


(* --- install: self (copy binary to ~/.local/bin) ------------------------- *)

let do_install_self ~output_mode ~dest_opt ~with_mcp_server =
  let dest_dir =
    match dest_opt with
    | Some d -> d
    | None ->
        let home = Sys.getenv "HOME" in
        home // ".local" // "bin"
  in
  let exe_path = Sys.executable_name in
  if not (Sys.file_exists exe_path) then (
    match output_mode with
    | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String "cannot determine executable path") ])
    | Human ->
        Printf.eprintf "error: cannot find executable at %s\n%!" exe_path;
        exit 1)
  else
    let result =
      try
        if not (Sys.file_exists dest_dir && Sys.is_directory dest_dir) then
          C2c_mcp.mkdir_p dest_dir;
        let dest_path = dest_dir // "c2c" in
        let ic = open_in_bin exe_path in
        let oc = open_out_bin (dest_path ^ ".tmp") in
        Fun.protect ~finally:(fun () -> close_in ic; close_out oc) (fun () ->
          let buf = Bytes.create 65536 in
          let rec copy () =
            let n = input ic buf 0 (Bytes.length buf) in
            if n > 0 then (output oc buf 0 n; copy ())
          in
          copy ());
        Unix.chmod (dest_path ^ ".tmp") 0o755;
        Unix.rename (dest_path ^ ".tmp") dest_path;
        let extras =
          if with_mcp_server then
            match find_ocaml_server_path () with
            | None -> [ Error "could not find c2c_mcp_server.exe to install" ]
            | Some server_src ->
                let mcp_dest = dest_dir // "c2c-mcp-server" in
                try
                  let ic = open_in_bin server_src in
                  let oc = open_out_bin (mcp_dest ^ ".tmp") in
                  Fun.protect ~finally:(fun () -> close_in ic; close_out oc) (fun () ->
                    let buf = Bytes.create 65536 in
                    let rec copy () =
                      let n = input ic buf 0 (Bytes.length buf) in
                      if n > 0 then (output oc buf 0 n; copy ())
                    in
                    copy ());
                  Unix.chmod (mcp_dest ^ ".tmp") 0o755;
                  Unix.rename (mcp_dest ^ ".tmp") mcp_dest;
                  [ Ok mcp_dest ]
                with Sys_error msg -> [ Error msg ]
           else []
         in
         (* Install the swarm-wide git shim (pre-reset guard + attribution shim).
            This also installs git-pre-reset (the guard) alongside the git shim.
            Failures here are non-fatal (the shim is best-effort). *)
         let shim_dir =
           try Some (C2c_start.ensure_swarm_git_shim_installed ()) with
           | e -> Printf.eprintf "warning: could not install git shim: %s\n%!" (Printexc.to_string e); None
         in
         Ok (dest_path, extras, shim_dir)
      with
      | Unix.Unix_error (code, func, _arg) ->
          Error (Printf.sprintf "%s: %s" func (Unix.error_message code))
      | Sys_error msg -> Error msg
    in
    (match result with
     | Ok (dest_path, extras, shim_dir) ->
         (match output_mode with
          | Json ->
              let items = [ ("ok", `Bool true); ("c2c", `String dest_path) ] in
              let items =
                let extra_json = List.map (fun x -> match x with Ok p -> `String p | Error m -> `String ("error: " ^ m)) extras in
                let items = if extra_json = [] then items else items @ [ ("mcp_server", `List extra_json) ] in
                let items = match shim_dir with Some d -> items @ [ ("git_shim_dir", `String d) ] | None -> items in
                items
              in
              print_json (`Assoc items)
          | Human ->
              Printf.printf "installed c2c to %s\n" dest_path;
              List.iter (function Ok p -> Printf.printf "installed c2c-mcp-server to %s\n" p | Error m -> Printf.eprintf "error: %s\n%!" m) extras;
              (match shim_dir with
               | Some d -> Printf.printf "installed git-pre-reset guard to %s\n" d
               | None -> ()))
     | Error msg ->
         (match output_mode with
          | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])
          | Human ->
              Printf.eprintf "error: %s\n%!" msg;
              exit 1))

(* --- subcommand: init — defined after do_install_client below ----------- *)

(* --- subcommand: setup --------------------------------------------------- *)

(* alias word pool lives in [C2c_alias_words] (#388 — converged from
   the duplicated 128-entry literal previously inlined here and in
   c2c_start.ml). Note: this local [generate_alias] does NOT call
   [Random.self_init ()] — the caller is expected to seed Random
   (see [setup_register]). *)

let generate_alias () =
  let words = C2c_alias_words.words in
  let n = Array.length words in
  let rec loop () =
    let w1 = words.(Random.int n) in
    let w2 = words.(Random.int n) in
    if w1 = w2 then loop () else Printf.sprintf "%s-%s" w1 w2
  in
  loop ()

(* easy-pool alias generation — uses C2c_alias_words.easy_pool (~42 nature-themed
   words). Generates an alias from the restricted pool. Raises if the pool is
   too small to form a non-identical pair (structurally impossible with 50+ words). *)
let generate_alias_easy () =
  let words = C2c_alias_words.easy_pool in
  let n = Array.length words in
  let rec loop () =
    let w1 = words.(Random.int n) in
    let w2 = words.(Random.int n) in
    if w1 = w2 then loop () else Printf.sprintf "%s-%s" w1 w2
  in
  loop ()

let generate_session_id () =
  let buf = Buffer.create 36 in
  for _ = 1 to 8 do
    Buffer.add_string buf (string_of_int (Random.int 16))
  done;
  Buffer.add_char buf '-';
  for _ = 1 to 4 do
    Buffer.add_string buf (string_of_int (Random.int 16))
  done;
  Buffer.add_char buf '-';
  for _ = 1 to 4 do
    Buffer.add_string buf (string_of_int (Random.int 16))
  done;
  Buffer.contents buf


let json_write_file path json =
  let tmp = path ^ ".tmp" in
  let oc = open_out tmp in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    Yojson.Safe.pretty_to_channel oc json);
  Unix.rename tmp path

let json_write_file_or_dryrun dry_run path json =
  if dry_run then
    let s = Yojson.Safe.to_string json in
    Printf.printf "[DRY-RUN] would write %d bytes to %s\n%!" (String.length s) path
  else
    json_write_file path json

let mkdir_or_dryrun dry_run dir =
  if dry_run then
    Printf.printf "[DRY-RUN] would create directory %s\n%!" dir
  else
    (try Unix.mkdir dir 0o755 with Unix.Unix_error _ -> ())

let mkdir_p dry_run dir =
  (* Recursive mkdir: creates dir and all intermediate parents, like mkdir -p. *)
  if dry_run then
    Printf.printf "[DRY-RUN] would create directory tree %s\n%!" dir
  else
    C2c_mcp.mkdir_p dir

let default_alias_for_client client =
  let client = match String.lowercase_ascii client with
    | "codex-headless" -> "codex"
    | other -> other
  in
  let suffix = C2c_start.generate_alias () in
  Printf.sprintf "%s-%s" client suffix

(* --- setup: Codex (TOML) --- *)

(* Codex MCP tool allow-list. Codex's TOML config requires every MCP tool to
   be enumerated explicitly (no wildcard), so this list must enumerate every
   tool registered by the c2c MCP server.

   IMPORTANT: this list must stay in sync with `C2c_mcp.base_tool_definitions`.
   When you add a new tool to the broker, append its name here too — otherwise
   Codex sessions will silently lose access to it.

   A future #412-followup will generate this list from a single source of
   truth (the broker's own tool registry) so the two cannot drift; for now
   it is hand-maintained. *)
let c2c_tools_list = [
  (* identity / discovery *)
  "register"; "whoami"; "list";
  (* 1:1 + broadcast send *)
  "send"; "send_all";
  (* inbox / archive *)
  "poll_inbox"; "peek_inbox"; "history";
  (* rooms (N:N) *)
  "join_room"; "leave_room"; "delete_room";
  "send_room"; "list_rooms"; "my_rooms"; "room_history";
  "send_room_invite"; "set_room_visibility"; "prune_rooms";
  (* presence / DND *)
  "set_dnd"; "dnd_status";
  (* permission / pending-reply tracking *)
  "open_pending_reply"; "check_pending_reply";
  (* compaction lifecycle *)
  "set_compact"; "clear_compact";
  (* managed-session lifecycle *)
  "stop_self";
  (* per-agent memory *)
  "memory_list"; "memory_read"; "memory_write";
  (* admin / diagnostics *)
  "sweep"; "tail_log"; "server_info";
]

let setup_codex ~output_mode ~dry_run ~root ~alias_val ~server_path ~mcp_command ~client =
  let config_path = Filename.concat (Sys.getenv "HOME") (".codex" // "config.toml") in
  let existing =
    if Sys.file_exists config_path then
      let ic = open_in config_path in
      Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        let n = in_channel_length ic in
        let s = really_input_string ic n in
        s)
    else ""
  in
  let lines = String.split_on_char '\n' existing in
  let stripped =
    let buf = Buffer.create (String.length existing) in
    let in_c2c = ref false in
    List.iter (fun line ->
      let trimmed = String.trim line in
      if String.length trimmed > 0 && trimmed.[0] = '[' then begin
        in_c2c :=
          (try
             let sec = String.sub trimmed 1 (String.length trimmed - 2) in
             String.length sec >= String.length "mcp_servers.c2c"
             && String.sub sec 0 (String.length "mcp_servers.c2c") = "mcp_servers.c2c"
           with _ -> false)
      end;
      if not !in_c2c then Buffer.add_string buf line;
      Buffer.add_char buf '\n'
    ) lines;
    Buffer.contents buf
  in
  let buf = Buffer.create 1024 in
  Buffer.add_string buf "\n[mcp_servers.c2c]\n";
  if mcp_command = "c2c-mcp-server" then begin
    Buffer.add_string buf "command = \"c2c-mcp-server\"\n";
    Buffer.add_string buf "args = []\n"
  end else begin
    Buffer.add_string buf "command = \"opam\"\n";
    Buffer.add_string buf (Printf.sprintf "args = [\"exec\", \"--\", \"%s\"]\n" server_path)
  end;
  Buffer.add_string buf "\n[mcp_servers.c2c.env]\n";
  Buffer.add_string buf (Printf.sprintf "C2C_MCP_BROKER_ROOT = \"%s\"\n" root);
  Buffer.add_string buf "C2C_MCP_CLIENT_TYPE = \"codex\"\n";
  Buffer.add_string buf "C2C_MCP_AUTO_JOIN_ROOMS = \"swarm-lounge\"\n";
  Buffer.add_string buf "C2C_AUTO_JOIN_ROLE_ROOM = \"1\"\n";
  List.iter (fun tool ->
    Buffer.add_string buf (Printf.sprintf "\n[mcp_servers.c2c.tools.%s]\n" tool);
    Buffer.add_string buf "approval_mode = \"auto\"\n"
  ) c2c_tools_list;
  let new_content = stripped ^ Buffer.contents buf in
  mkdir_or_dryrun dry_run (Filename.dirname config_path);
  if dry_run then
    Printf.printf "[DRY-RUN] would write %d bytes to %s\n%!" (String.length new_content) config_path
  else begin
    let tmp = config_path ^ ".tmp" in
    let oc = open_out tmp in
    Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      output_string oc new_content);
    Unix.rename tmp config_path
  end;
  match output_mode with
  | Json ->
      print_json (`Assoc
        [ ("ok", `Bool true)
        ; ("client", `String client)
        ; ("alias", `String alias_val)
        ; ("broker_root", `String root)
        ; ("config", `String config_path)
        ])
  | Human ->
      Printf.printf "Configured Codex for c2c.\n";
      Printf.printf "  alias:       %s\n" alias_val;
      Printf.printf "  broker root: %s\n" root;
      Printf.printf "  config:      %s\n" config_path;
      Printf.printf "  server:      %s\n" server_path;
      Printf.printf "  note:        shared MCP config only; managed sessions set identity at launch\n";
      Printf.printf "\nRestart Codex to pick up the new MCP server.\n"

(* --- setup: Kimi (JSON) --- *)

(* [build_kimi_mcp_config ~root ~alias_val ~server_path existing]
   is the pure JSON merge at the heart of setup_kimi.  It takes the
   pre-existing ~/.kimi/mcp.json value (already parsed) and returns the
   updated config with the c2c entry (including #478 allowedTools) merged in.
   Running this twice on the same input yields identical output (idempotent
   replacement — the old c2c entry is removed before the new one is added,
   never appended). *)
let build_kimi_mcp_config ~root ~alias_val ~server_path existing : Yojson.Safe.t =
  let c2c_allowed_tools_json = `List (List.map (fun t -> `String t) c2c_tools_list) in
  let c2c_entry =
    `Assoc
      [ ("type", `String "stdio")
      ; ("command", `String "opam")
      ; ("args", `List [ `String "exec"; `String "--"; `String server_path ])
      ; ("env", `Assoc
          [ ("C2C_MCP_BROKER_ROOT", `String root)
          ; ("C2C_MCP_SESSION_ID", `String alias_val)
          ; ("C2C_MCP_AUTO_REGISTER_ALIAS", `String alias_val)
          ; ("C2C_MCP_AUTO_JOIN_ROOMS", `String "swarm-lounge")
          ; ("C2C_AUTO_JOIN_ROLE_ROOM", `String "1")
          ])
      ; ("allowedTools", c2c_allowed_tools_json)
      ]
  in
  match existing with
  | `Assoc fields ->
      let existing_mcp = match List.assoc_opt "mcpServers" fields with
        | Some (`Assoc m) -> List.filter (fun (k, _) -> k <> "c2c") m
        | _ -> []
      in
      `Assoc (List.filter (fun (k, _) -> k <> "mcpServers") fields
              @ [ ("mcpServers", `Assoc (existing_mcp @ [ ("c2c", c2c_entry) ])) ])
  | _ -> `Assoc [ ("mcpServers", `Assoc [ ("c2c", c2c_entry) ]) ]

let setup_kimi ~output_mode ~dry_run ~root ~alias_val ~server_path =
  let home = Sys.getenv "HOME" in
  let config_path = Filename.concat home (".kimi" // "mcp.json") in
  let toml_config_path = Filename.concat home (".kimi" // "config.toml") in
  let hook_install_dir = Filename.concat home (".local" // "bin") in
  let existing =
    if Sys.file_exists config_path then json_read_file config_path
    else `Assoc []
  in
  let config = build_kimi_mcp_config ~root ~alias_val ~server_path existing in
  mkdir_or_dryrun dry_run (Filename.dirname config_path);
  json_write_file_or_dryrun dry_run config_path config;
  (* Slice 2 of #142: install the PreToolUse approval hook script and
     append a fully-commented [[hooks]] block to ~/.kimi/config.toml.
     Idempotent — running `c2c install kimi` twice yields one block. *)
  let hook_path =
    C2c_kimi_hook.install_approval_hook_script ~dest_dir:hook_install_dir ~dry_run
  in
  let hook_block_status =
    C2c_kimi_hook.append_toml_block
      ~config_path:toml_config_path ~hook_path ~dry_run ()
  in
  let hook_block_status_str = match hook_block_status with
    | `Already_present -> "already_present"
    | `Appended -> "appended"
    | `Created -> "created"
  in
  match output_mode with
  | Json ->
      print_json (`Assoc
        [ ("ok", `Bool true)
        ; ("client", `String "kimi")
        ; ("alias", `String alias_val)
        ; ("broker_root", `String root)
        ; ("config", `String config_path)
        ; ("hook_script", `String hook_path)
        ; ("hooks_toml_path", `String toml_config_path)
        ; ("hooks_toml_block", `String hook_block_status_str)
        ])
  | Human ->
      Printf.printf "Configured Kimi for c2c.\n";
      Printf.printf "  alias:       %s\n" alias_val;
      Printf.printf "  broker root: %s\n" root;
      Printf.printf "  config:      %s\n" config_path;
      Printf.printf "  server:      %s\n" server_path;
      Printf.printf "  hook script: %s\n" hook_path;
      Printf.printf "  hooks toml:  %s (%s)\n" toml_config_path hook_block_status_str;
      Printf.printf "\nRestart Kimi to pick up the new MCP server.\n";
      Printf.printf "PreToolUse permission forwarding ships fully-commented in %s —\n"
        toml_config_path;
      Printf.printf "uncomment ONE [[hooks]] example in that file to opt in.\n"

(* --- setup: Gemini CLI (JSON, user-scope) --- *)

(* Gemini CLI keeps its config at ~/.gemini/settings.json (user scope) and
   exposes MCP servers via the same `mcpServers` shape as Claude Code, plus
   a `trust: true` flag that bypasses tool-call confirmation prompts.

   We write user-scope (not project-scope) so the c2c MCP server is
   available across every gemini session — matches kimi's precedent, and
   the swarm-wide alias model. Use `gemini mcp remove c2c` to undo. *)
let setup_gemini ~output_mode ~dry_run ~root ~alias_val ~server_path ~mcp_command =
  let config_path =
    Filename.concat (Sys.getenv "HOME") (".gemini" // "settings.json")
  in
  let existing =
    if Sys.file_exists config_path then json_read_file config_path
    else `Assoc []
  in
  (* When `c2c-mcp-server` is on PATH, use it directly. Otherwise fall
     back to `opam exec -- <absolute-server-path>` — same shape as
     setup_claude/setup_codex. resolve_mcp_server_paths picks the right
     pair upstream. *)
  let args_list =
    if mcp_command = "c2c-mcp-server" then []
    else [ `String "exec"; `String "--"; `String server_path ]
  in
  let c2c_entry =
    `Assoc
      [ ("command", `String mcp_command)
      ; ("args", `List args_list)
      ; ("env", `Assoc
          [ ("C2C_MCP_BROKER_ROOT", `String root)
          ; ("C2C_MCP_SESSION_ID", `String alias_val)
          ; ("C2C_MCP_AUTO_REGISTER_ALIAS", `String alias_val)
          ; ("C2C_MCP_AUTO_JOIN_ROOMS", `String "swarm-lounge")
          ; ("C2C_AUTO_JOIN_ROLE_ROOM", `String "1")
          ])
      ; ("trust", `Bool true)
      ]
  in
  let config = match existing with
    | `Assoc fields ->
        let existing_mcp = match List.assoc_opt "mcpServers" fields with
          | Some (`Assoc m) -> List.filter (fun (k, _) -> k <> "c2c") m
          | _ -> []
        in
        `Assoc (List.filter (fun (k, _) -> k <> "mcpServers") fields
                @ [ ("mcpServers", `Assoc (existing_mcp @ [ ("c2c", c2c_entry) ])) ])
    | _ -> `Assoc [ ("mcpServers", `Assoc [ ("c2c", c2c_entry) ]) ]
  in
  mkdir_or_dryrun dry_run (Filename.dirname config_path);
  json_write_file_or_dryrun dry_run config_path config;
  match output_mode with
  | Json ->
      print_json (`Assoc
        [ ("ok", `Bool true)
        ; ("client", `String "gemini")
        ; ("alias", `String alias_val)
        ; ("broker_root", `String root)
        ; ("config", `String config_path)
        ; ("trust", `Bool true)
        ])
  | Human ->
      Printf.printf "Configured Gemini CLI for c2c.\n";
      Printf.printf "  alias:       %s\n" alias_val;
      Printf.printf "  broker root: %s\n" root;
      Printf.printf "  config:      %s\n" config_path;
      Printf.printf "  trust:       true (skips per-tool confirmation prompts)\n";
      Printf.printf "\nRun 'gemini mcp list' to verify.\n";
      Printf.printf "If you haven't authenticated yet, run 'gemini' once interactively to seed ~/.gemini/oauth_creds.json before launching managed sessions.\n"

(* --- setup: OpenCode (JSON + plugin) --- *)

let setup_opencode ~output_mode ~dry_run ~root ~alias_val ~server_path ~target_dir_opt ?(force=false) () =
  let target_dir = match target_dir_opt with
    | Some d -> d
    | None -> Sys.getcwd ()
  in
  if not (Sys.is_directory target_dir) then begin
    Printf.eprintf "error: target directory does not exist: %s\n%!" target_dir;
    exit 1
  end;
  let config_dir = target_dir // ".opencode" in
  let config_path = config_dir // "opencode.json" in
  (* Guard: if config already exists and has a c2c mcp entry, warn and skip unless --force. *)
  if (not force) && Sys.file_exists config_path then begin
    (try
       match json_read_file config_path with
       | `Assoc fields ->
           (match List.assoc_opt "mcp" fields with
            | Some (`Assoc m) when List.mem_assoc "c2c" m ->
                Printf.eprintf
                  "warning: %s already has a c2c MCP entry.\n\
                   Use --force to overwrite, or edit manually to change alias/session.\n\
                   Skipping opencode.json write; updating plugin and sidecar only.\n%!"
                  config_path
            | _ -> ())
       | _ -> ()
     with _ -> ())
  end;
  let dir_name = Filename.basename (
    let n = String.length target_dir in
    if n > 1 && target_dir.[n-1] = '/' then String.sub target_dir 0 (n-1)
    else target_dir) in
  let session_id = Printf.sprintf "opencode-%s" dir_name in
  mkdir_or_dryrun dry_run config_dir;
  let should_write_config =
    force || not (Sys.file_exists config_path) ||
    (try
       match json_read_file config_path with
       | `Assoc fields -> not (match List.assoc_opt "mcp" fields with
           | Some (`Assoc m) -> List.mem_assoc "c2c" m | _ -> false)
       | _ -> true
     with _ -> true)
  in
  if not should_write_config then () else
  let config =
    `Assoc
      [ ("$schema", `String "https://opencode.ai/config.json")
      ; ("mcp", `Assoc
          [ ("c2c", `Assoc
              [ ("type", `String "local")
              ; ("command", `List [ `String "opam"; `String "exec"; `String "--"; `String server_path ])
              ; ("environment", `Assoc
                  [ ("C2C_MCP_BROKER_ROOT", `String root)
                  ; ("C2C_MCP_AUTO_DRAIN_CHANNEL", `String "0")
                  ; ("C2C_MCP_AUTO_JOIN_ROOMS", `String "swarm-lounge")
                  ; ("C2C_CLI_COMMAND", `String (current_c2c_command ()))
                  ; ("C2C_AUTO_JOIN_ROLE_ROOM", `String "1")
                  ])
              ; ("enabled", `Bool true)
              ])
          ])
      ]
  in
  json_write_file_or_dryrun dry_run config_path config;
  let sidecar = config_dir // "c2c-plugin.json" in
  (* Drift-prevention follow-up to #504 / kimi-mcp-canonical-server:
     omit broker_root from the sidecar when value == resolver default.
      The opencode TS plugin (data/opencode-plugin/c2c.ts) has its own
      canonical resolveBrokerRoot() that mirrors C2c_repo_fp; an absent
      field falls back correctly. *)
  let resolver_default =
    try C2c_repo_fp.resolve_broker_root () with _ -> ""
  in
  (* #507: always write broker_root (not just when non-default) and also
     write broker_root_fingerprint so the plugin can detect staleness after
     a git remote or migrate-broker change. *)
  let fp =
    try C2c_repo_fp.repo_fingerprint () with _ -> ""
  in
  let sidecar_json =
    `Assoc (
      ("session_id", `String session_id) ::
      ("alias", `String alias_val) ::
      ("broker_root", `String root) ::
      ("broker_root_fingerprint", `String fp) ::
      (if root = "" || root = resolver_default then [] else [])
    )
  in
  json_write_file_or_dryrun dry_run sidecar sidecar_json;
  (* Find canonical plugin source. When running from the c2c repo, the canonical
     source is data/opencode-plugin/c2c.ts. Use a symlink so the installed
     plugin auto-picks up future c2c repo updates without re-install. *)
  let home = try Sys.getenv "HOME" with Not_found -> "" in
  let global_plugin_path = home // ".config" // "opencode" // "plugins" // "c2c.ts" in
  let canonical_plugin = "data" // "opencode-plugin" // "c2c.ts" in
  let file_size path =
    try (Unix.stat path).Unix.st_size with Unix.Unix_error _ -> 0
  in
  let copy_file ~src ~dst =
    let src_size = file_size src in
    if dry_run then
      Printf.printf "[DRY-RUN] would copy %d bytes from %s to %s\n%!" src_size src dst
    else begin
      let ic = open_in_bin src in
      let oc = open_out_bin (dst ^ ".tmp") in
      Fun.protect ~finally:(fun () -> close_in ic; close_out oc) (fun () ->
        let buf = Bytes.create 65536 in
        let rec loop () =
          let n = input ic buf 0 (Bytes.length buf) in
          if n > 0 then (output oc buf 0 n; loop ())
        in
        loop ());
      Unix.rename (dst ^ ".tmp") dst
    end
  in
  let make_symlink ~src ~dst =
    (* Unix.symlink stores src as-is; the kernel resolves it relative to the
       symlink's parent directory, not CWD. Always use an absolute src path. *)
    let src_abs = if Filename.is_relative src then Filename.concat (Sys.getcwd ()) src else src in
    if dry_run then
      Printf.printf "[DRY-RUN] would symlink %s -> %s\n%!" dst src_abs
    else begin
      (try Unix.unlink dst with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
      Unix.symlink src_abs dst
    end
  in
  let canonical_exists = Sys.file_exists canonical_plugin && file_size canonical_plugin >= 1024 in
  let plugin_src =
    if canonical_exists then Some canonical_plugin
    else if Sys.file_exists global_plugin_path && file_size global_plugin_path >= 1024 then
      Some global_plugin_path
    else None
  in
  let plugin_note =
    match plugin_src with
    | None ->
        Printf.sprintf "plugin not found — run: c2c install opencode (from c2c repo, or copy .opencode/plugins/c2c.ts to %s)" global_plugin_path
    | Some src ->
        let plugins_dir = config_dir // "plugins" in
        mkdir_or_dryrun dry_run plugins_dir;
        let dest = plugins_dir // "c2c.ts" in
        (try
           if canonical_exists then begin
             (* Canonical source available: use symlinks so installed plugin
                tracks repo changes automatically. *)
             make_symlink ~src:canonical_plugin ~dst:dest;
             let global_note =
               (try
                   let gdir = Filename.dirname global_plugin_path in
                   mkdir_p dry_run gdir;
                  make_symlink ~src:canonical_plugin ~dst:global_plugin_path;
                  " + global symlinked"
                with _ -> " (global symlink failed)")
             in
             Printf.sprintf "plugin symlinked to %s%s" dest global_note
           end else begin
             (* No canonical source: copy from existing global plugin. *)
             copy_file ~src ~dst:dest;
             Printf.sprintf "plugin installed to %s (copied)" dest
           end
         with _ -> "plugin install failed")
  in
  match output_mode with
  | Json ->
      print_json (`Assoc
        [ ("ok", `Bool true)
        ; ("client", `String "opencode")
        ; ("session_id", `String session_id)
        ; ("alias", `String alias_val)
        ; ("broker_root", `String root)
        ; ("config", `String config_path)
        ; ("plugin", `String plugin_note)
        ])
  | Human ->
      Printf.printf "Configured OpenCode for c2c.\n";
      Printf.printf "  session id:  %s\n" session_id;
      Printf.printf "  alias:       %s\n" alias_val;
      Printf.printf "  broker root: %s\n" root;
      Printf.printf "  config:      %s\n" config_path;
      Printf.printf "  plugin:      %s\n" plugin_note;
      Printf.printf "\nRun 'opencode mcp list' from %s to verify.\n" target_dir

(* --- setup: Claude PostToolUse hook -------------------------------------- *)

let claude_hook_script = {|
#!/bin/bash
# c2c-inbox-check.sh — PostToolUse hook for c2c auto-delivery in Claude Code
#
# Calls 'c2c hook' which drains the inbox and outputs messages.
# Also calls cold-boot hook to emit context block once per session.
# c2c hook self-regulates runtime to prevent Node.js ECHILD race.
#
# IMPORTANT: do NOT use `exec c2c hook`. Claude Code's Node.js hook runner
# tracks the initially-spawned bash PID, and when bash exec's to the c2c
# binary the runner's waitpid() bookkeeping gets confused and surfaces
# `ECHILD: unknown error, waitpid` on every tool call. Running c2c as a
# bash subprocess and exiting bash normally fixes it.
#
# Required env vars (set by c2c start or the MCP server entry):
#   C2C_MCP_SESSION_ID   — broker session id
#   C2C_MCP_BROKER_ROOT  — absolute path to broker root dir

SCRIPT_DIR="$(dirname "$0")"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null || echo "$SCRIPT_DIR")"

if command -v c2c >/dev/null 2>&1; then
    c2c hook
fi

# Try c2c-cold-boot-hook from PATH first (after `just install-all`),
# fall back to dev-tree _build path. Pass REPO_ROOT so the hook can
# find findings/personal-logs in the correct repo (not worktree root).
if command -v c2c-cold-boot-hook >/dev/null 2>&1; then
    C2C_REPO_ROOT="$REPO_ROOT" c2c-cold-boot-hook
elif [ -x "$REPO_ROOT/_build/default/ocaml/tools/c2c_cold_boot_hook.exe" ]; then
    C2C_REPO_ROOT="$REPO_ROOT" "$REPO_ROOT/_build/default/ocaml/tools/c2c_cold_boot_hook.exe"
else
    # Neither binary found: sleep to avoid fast-exit ECHILD race, then exit.
    sleep 0.05
fi
exit 0
|}

let configure_claude_hook () =
  let home = Sys.getenv "HOME" in
  let hooks_dir = home // ".claude" // "hooks" in
  let script_path = hooks_dir // "c2c-inbox-check.sh" in
  let settings_path = home // ".claude" // "settings.json" in
  C2c_mcp.mkdir_p hooks_dir;
  let oc = open_out script_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc claude_hook_script);
  Unix.chmod script_path 0o755;
  let settings =
    if Sys.file_exists settings_path then json_read_file settings_path
    else `Assoc []
  in
  let hook_entry =
    `Assoc [ ("type", `String "command"); ("command", `String script_path) ]
  in
  let settings = match settings with
    | `Assoc fields ->
        let hooks = match List.assoc_opt "hooks" fields with
          | Some (`Assoc h) -> h
          | _ -> []
        in
        let post_tool_use = match List.assoc_opt "PostToolUse" hooks with
          | Some (`List g) -> g
          | _ -> []
        in
        let target_group, other_groups =
          List.partition (fun g -> match g with
            | `Assoc m -> (match List.assoc_opt "matcher" m with
              | Some (`String ".*") -> true
              | Some (`String "^(?!mcp__).*") -> true
              | _ -> false)
            | _ -> false) post_tool_use
        in
        let target_group = match target_group with
          | (`Assoc m) :: _ ->
              let existing_hooks = match List.assoc_opt "hooks" m with
                | Some (`List h) -> h
                | _ -> []
              in
              let has_hook = List.exists (fun h -> match h with
                | `Assoc n -> (match List.assoc_opt "command" n with Some (`String p) -> p = script_path | _ -> false)
                | _ -> false) existing_hooks
              in
              let new_hooks = if has_hook then existing_hooks else existing_hooks @ [ hook_entry ] in
              let m_without_matcher_or_hooks =
                List.filter (fun (k, _) -> k <> "matcher" && k <> "hooks") m
              in
              `Assoc (("matcher", `String "^(?!mcp__).*")
                      :: m_without_matcher_or_hooks
                      @ [ ("hooks", `List new_hooks) ])
          | _ ->
              `Assoc [ ("matcher", `String "^(?!mcp__).*"); ("hooks", `List [ hook_entry ]) ]
        in
        let hooks = List.filter (fun (k, _) -> k <> "PostToolUse") hooks in
        let hooks = hooks @ [ ("PostToolUse", `List (other_groups @ [ target_group ])) ] in
        let fields = List.filter (fun (k, _) -> k <> "hooks") fields in
        `Assoc (fields @ [ ("hooks", `Assoc hooks) ])
    | _ ->
        `Assoc [ ("hooks", `Assoc [ ("PostToolUse", `List [ `Assoc [ ("matcher", `String "^(?!mcp__).*"); ("hooks", `List [ hook_entry ]) ] ]) ]) ]
  in
  json_write_file settings_path settings

(* --- PATH detection helper, shared by install dispatchers --------------- *)

let which_binary name =
  match Sys.getenv_opt "PATH" with
  | None -> None
  | Some path ->
      let sep = if Sys.win32 then ';' else ':' in
      let dirs = String.split_on_char sep path in
      List.find_map (fun d ->
        if d = "" then None
        else
          let candidate = d // name in
          if Sys.file_exists candidate then Some candidate else None) dirs

(* --- install: claude (MCP server + PostToolUse hook) ---------------------- *)

(* #334: by default the MCP server entry goes into the project-scoped
   `<project>/.mcp.json`, NOT the user-global `~/.claude.json`. Onboarding a
   fresh clone with `c2c install claude` wires this repo for c2c without
   touching global Claude config. The `--global` flag preserves the legacy
   behavior (write `mcpServers.c2c` into `~/.claude.json`) for users who
   want one MCP entry across every project.

   The PostToolUse hook script + settings.json registration always go to
   `~/.claude/` — those are user-global Claude features, not project-scoped. *)
let setup_claude ~output_mode ~dry_run ~root ~alias_val ~alias_opt ~server_path ~mcp_command ~force ~channel_delivery ~global ~project_dir =
  let claude_dir = resolve_claude_dir () in
  let project_dir =
    match project_dir with Some d -> d | None -> Sys.getcwd ()
  in
  let mcp_config_path =
    if global then Filename.concat claude_dir ".claude.json"
    else Filename.concat project_dir ".mcp.json"
  in
  let config =
    if Sys.file_exists mcp_config_path then json_read_file mcp_config_path
    else `Assoc []
  in
  let env_pairs =
    [ ("C2C_MCP_BROKER_ROOT", `String root)
    ; ("C2C_MCP_AUTO_REGISTER_ALIAS", `String alias_val)
    ; ("C2C_MCP_AUTO_JOIN_ROOMS", `String "swarm-lounge")
    ; ("C2C_AUTO_JOIN_ROLE_ROOM", `String "1")
    ] @ (if channel_delivery then [ ("C2C_MCP_CHANNEL_DELIVERY", `String "1") ] else [])
  in
  (* Project `.mcp.json` entries conventionally include `"type": "stdio"`;
     `~/.claude.json` mcpServers entries omit it (legacy shape). Match the
     convention of the file we're writing. *)
  let mcp_entry_fields =
    (if global then [] else [ ("type", `String "stdio") ])
    @ [ ("command", `String mcp_command)
      ; ("args", `List (if mcp_command = "c2c-mcp-server" then [] else [ `String "exec"; `String "--"; `String server_path ]))
      ; ("env", `Assoc env_pairs)
      ]
  in
  let mcp_entry = `Assoc mcp_entry_fields in
  let config = match config with
    | `Assoc fields ->
        let filtered = List.filter (fun (k, _) -> k <> "mcpServers") fields in
        let existing_mcp = match List.assoc_opt "mcpServers" fields with
          | Some (`Assoc m) -> List.filter (fun (k, _) -> k <> "c2c") m
          | _ -> []
        in
        `Assoc (filtered @ [ ("mcpServers", `Assoc (existing_mcp @ [ ("c2c", mcp_entry) ])) ])
    | _ -> `Assoc [ ("mcpServers", `Assoc [ ("c2c", mcp_entry) ]) ]
  in
  (* mkdir -p the parent (only matters in --global=false when project_dir
     might not exist; existing-repo case is a no-op). *)
  (try mkdir_p dry_run (Filename.dirname mcp_config_path)
   with Unix.Unix_error _ -> ());
  json_write_file_or_dryrun dry_run mcp_config_path config;
  let settings_path = Filename.concat claude_dir "settings.json" in
  let hook_script = Filename.concat claude_dir "hooks" // "c2c-inbox-check.sh" in
  let script_changed = ref false in
  (try
     let dir = Filename.dirname hook_script in
     if not (Sys.file_exists dir) then mkdir_p dry_run dir;
     let hook_content = claude_hook_script in
     let existing =
       if Sys.file_exists hook_script then
         try
           let ic = open_in hook_script in
           Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
             really_input_string ic (in_channel_length ic))
         with _ -> ""
       else ""
     in
     if existing <> hook_content then script_changed := true;
     if dry_run then
       Printf.printf "[DRY-RUN] would write hook script to %s\n%!" hook_script
     else begin
       let oc = open_out hook_script in
       output_string oc hook_content;
       close_out oc;
       Unix.chmod hook_script 0o755
     end
   with Unix.Unix_error _ -> ());
  let hook_registered = ref false in
  let settings_changed = ref false in
  let target_matcher = "^(?!mcp__).*" in
  let settings_ref = ref (
    if Sys.file_exists settings_path then json_read_file settings_path
    else `Assoc []
  ) in
  settings_ref := (match !settings_ref with
    | `Assoc fields ->
        let hooks = match List.assoc_opt "hooks" fields with
          | Some (`Assoc h) -> h
          | _ -> []
        in
        let post_tool_use = match List.assoc_opt "PostToolUse" hooks with
          | Some (`List entries) -> entries
          | _ -> []
        in
        let entry_has_hook entry =
          match entry with
          | `Assoc e ->
              (match List.assoc_opt "hooks" e with
               | Some (`List hs) ->
                   List.exists (fun h ->
                     match h with
                     | `Assoc h_fields ->
                         (match List.assoc_opt "command" h_fields with
                          | Some (`String cmd) -> cmd = hook_script
                          | _ -> false)
                     | _ -> false) hs
               | _ -> false)
          | _ -> false
        in
        let already = List.exists entry_has_hook post_tool_use in
        hook_registered := already;
        let upgraded_post = List.map (fun entry ->
          if entry_has_hook entry then
            match entry with
            | `Assoc e ->
                let current_matcher = match List.assoc_opt "matcher" e with
                  | Some (`String s) -> Some s
                  | _ -> None
                in
                if current_matcher = Some target_matcher then entry
                else begin
                  settings_changed := true;
                  let rest = List.filter (fun (k, _) -> k <> "matcher") e in
                  `Assoc (("matcher", `String target_matcher) :: rest)
                end
            | _ -> entry
          else entry
        ) post_tool_use in
        if not already then begin
          settings_changed := true;
          let new_entry = `Assoc [ ("matcher", `String target_matcher); ("hooks", `List [ `Assoc [ ("type", `String "command"); ("command", `String hook_script) ] ]) ] in
          let new_post = upgraded_post @ [ new_entry ] in
          let new_hooks = List.filter (fun (k, _) -> k <> "PostToolUse") hooks @ [ ("PostToolUse", `List new_post) ] in
          let new_fields = List.filter (fun (k, _) -> k <> "hooks") fields @ [ ("hooks", `Assoc new_hooks) ] in
          `Assoc new_fields
        end else if !settings_changed then begin
          let new_hooks = List.filter (fun (k, _) -> k <> "PostToolUse") hooks @ [ ("PostToolUse", `List upgraded_post) ] in
          let new_fields = List.filter (fun (k, _) -> k <> "hooks") fields @ [ ("hooks", `Assoc new_hooks) ] in
          `Assoc new_fields
        end else
          `Assoc fields
    | _ -> `Assoc []
  );
  (* #142 slice 4: PreToolUse permission-forwarding hook for Claude Code.
     Symmetric with the kimi PreToolUse hook from slice 2. The approval hook
     script is installed by `c2c install kimi` (slice 2) to
     ~/.local/bin/c2c-kimi-approval-hook.sh. We register it here so Claude Code
     also gets permission forwarding.
     Design (B per lumi pre-check): auto-write with sentinel matcher
     `__C2C_PREAUTH_DISABLED__`. Operator edits the matcher to opt in.
     Sentinel convention: `__C2C_<HOOK>_<STATE>__` namespaces by hook type
     so future c2c-managed hook blocks don't collide. *)
  let preauth_hook_script =
    (Sys.getenv "HOME") // ".local" // "bin" // "c2c-kimi-approval-hook.sh"
  in
  let preauth_hook_registered = ref false in
  let preauth_settings_changed = ref false in
  if Sys.file_exists preauth_hook_script then begin
    let fields = match !settings_ref with `Assoc f -> f | _ -> [] in
    let hooks = match List.assoc_opt "hooks" fields with
      | Some (`Assoc h) -> h | _ -> []
    in
    let pre_tool_use = match List.assoc_opt "PreToolUse" hooks with
      | Some (`List entries) -> entries | _ -> []
    in
    let sentinel_matcher = "__C2C_PREAUTH_DISABLED__" in
    let already =
      List.exists (function
        | `Assoc e ->
            (match List.assoc_opt "matcher" e with
             | Some (`String m) -> m = sentinel_matcher
             | _ -> false)
        | _ -> false) pre_tool_use
    in
    preauth_hook_registered := already;
    if not already then begin
      preauth_settings_changed := true;
      let new_entry = `Assoc [
        ("matcher", `String sentinel_matcher);
        ("hooks", `List [
          `Assoc [ ("type", `String "command"); ("command", `String preauth_hook_script) ]
        ])
      ] in
      let new_pre = pre_tool_use @ [ new_entry ] in
      let new_hooks = List.filter (fun (k, _) -> k <> "PreToolUse") hooks
                       @ [ ("PreToolUse", `List new_pre) ] in
      let new_fields = List.filter (fun (k, _) -> k <> "hooks") fields
                       @ [ ("hooks", `Assoc new_hooks) ] in
      settings_ref := `Assoc new_fields
    end
  end;
  let preauth_status =
    if not (Sys.file_exists preauth_hook_script) then "hook script not installed (run `c2c install kimi` first)"
    else if !preauth_hook_registered then "already registered"
    else "registered"
  in
  if !settings_changed || !preauth_settings_changed then json_write_file_or_dryrun dry_run settings_path !settings_ref;
  let hook_status =
    if !hook_registered && not !settings_changed && not !script_changed then "already registered"
    else if !hook_registered && !script_changed && not !settings_changed then "script updated"
    else if !hook_registered then "matcher upgraded"
    else "registered"
  in
  (match output_mode with
   | Json ->
       print_json (`Assoc
          [ ("ok", `Bool true)
          ; ("client", `String "claude")
          ; ("alias", `String alias_val)
          ; ("broker_root", `String root)
          ; ("config", `String mcp_config_path)
          ; ("scope", `String (if global then "global" else "project"))
          ; ("hook_status", `String hook_status)
          ; ("preauth_hook_status", `String preauth_status)
          ])
   | Human ->
       let hook_dir = Filename.concat claude_dir "hooks" in
       let hook_script = Filename.concat hook_dir "c2c-inbox-check.sh" in
       let mark = "x" in
       let scope_label = if global then "global" else "project" in
       Printf.printf "Configured Claude Code for c2c (%s scope):\n" scope_label;
       Printf.printf "  - [%s] MCP server:     %s\n" mark mcp_config_path;
       Printf.printf "  - [%s] PostToolUse hook: %s/settings.json\n" mark claude_dir;
       Printf.printf "  - [%s] Inbox hook script: %s\n" mark hook_script;
       Printf.printf "\n  alias:       %s\n" alias_val;
       Printf.printf "  broker root: %s\n" root;
       if !hook_registered && not !settings_changed && not !script_changed then
         Printf.printf "\n  (hook was already registered — no changes made)\n"
       else if !hook_registered && !script_changed && not !settings_changed then
         Printf.printf "\n  (hook already registered; script body updated at %s)\n" hook_script
       else if !hook_registered then
         Printf.printf "\n  (hook already registered; upgraded matcher to %s)\n" target_matcher
       else
         Printf.printf "\nRestart Claude Code to pick up the new MCP server.\n";
       if not global then
         Printf.printf "\n  (project scope: MCP entry written to %s/.mcp.json. Pass --global to write to ~/.claude.json instead.)\n" project_dir;
       let alias_str = match alias_opt with Some a -> " -a " ^ a | None -> "" in
        let force_str = if force then " --force" else "" in
        Printf.printf "\nTo use a custom profile directory:\n";
        Printf.printf "  CLAUDE_CONFIG_DIR=/path/to/profile c2c install claude%s%s\n" alias_str force_str;
        (* #142 slice 4: PreToolUse hook status + opt-in hint *)
        if Sys.file_exists preauth_hook_script then begin
          Printf.printf "\n  PreToolUse permission hook: %s\n" preauth_status;
          if not !preauth_hook_registered then begin
            Printf.printf "    (edit %s/settings.json to opt in: change\n" claude_dir;
            Printf.printf "     \"matcher\": \"__C2C_PREAUTH_DISABLED__\" to\n";
            Printf.printf "     \"matcher\": \"<tool-name>\" where tool-name is the exact\n";
            Printf.printf "     tool to gate — e.g. \"Bash\", \"Read\".\n";
            Printf.printf "     NOTE: Claude Code matcher is exact tool name, not regex.)\n"
          end
        end else
          Printf.printf "\n  PreToolUse permission hook: %s\n" preauth_status
  )

(* --- install: crush (JSON) --- *)

let setup_crush ~output_mode ~dry_run ~root ~alias_val ~server_path =
  let config_path = Filename.concat (Sys.getenv "HOME") (".config" // "crush" // "crush.json") in
  let existing =
    if Sys.file_exists config_path then json_read_file config_path
    else `Assoc []
  in
  let c2c_entry =
    `Assoc
      [ ("type", `String "stdio")
      ; ("command", `String "opam")
      ; ("args", `List [ `String "exec"; `String "--"; `String server_path ])
      ; ("env", `Assoc
          [ ("C2C_MCP_BROKER_ROOT", `String root)
          ; ("C2C_MCP_SESSION_ID", `String alias_val)
          ; ("C2C_MCP_AUTO_REGISTER_ALIAS", `String alias_val)
          ; ("C2C_MCP_AUTO_JOIN_ROOMS", `String "swarm-lounge")
          ; ("C2C_AUTO_JOIN_ROLE_ROOM", `String "1")
          ])
      ]
  in
  let config = match existing with
    | `Assoc fields ->
        let existing_mcp = match List.assoc_opt "mcpServers" fields with
          | Some (`Assoc m) -> List.filter (fun (k, _) -> k <> "c2c") m
          | _ -> []
        in
        `Assoc (List.filter (fun (k, _) -> k <> "mcpServers") fields
                @ [ ("mcpServers", `Assoc (existing_mcp @ [ ("c2c", c2c_entry) ])) ])
    | _ -> `Assoc [ ("mcpServers", `Assoc [ ("c2c", c2c_entry) ]) ]
  in
  (try mkdir_p dry_run (Filename.dirname config_path)
   with Unix.Unix_error _ -> ());
  json_write_file_or_dryrun dry_run config_path config;
  match output_mode with
  | Json ->
      print_json (`Assoc
        [ ("ok", `Bool true)
        ; ("client", `String "crush")
        ; ("alias", `String alias_val)
        ; ("broker_root", `String root)
        ; ("config", `String config_path)
        ])
  | Human ->
      Printf.printf "Configured Crush for c2c (experimental).\n";
      Printf.printf "  alias:       %s\n" alias_val;
      Printf.printf "  broker root: %s\n" root;
      Printf.printf "  config:      %s\n" config_path;
      Printf.printf "  server:      %s\n" server_path

(* --- install: shared dispatcher (used by `c2c install <client>` and TUI) --- *)

let resolve_mcp_server_paths ~output_mode =
  match which_binary "c2c-mcp-server" with
  | Some p -> (p, "c2c-mcp-server")
  | None ->
      let server_path =
        match find_ocaml_server_path () with
        | Some p -> p
        | None ->
            (match output_mode with
             | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String "cannot find c2c_mcp_server binary") ])
             | Human ->
                 Printf.eprintf "error: cannot find c2c_mcp_server binary. Build with: just build\n%!");
            exit 1
      in
      let server_path =
        if Filename.is_relative server_path then Sys.getcwd () // server_path
        else server_path
      in
      (server_path, "opam")

let canonical_install_client client =
  match String.lowercase_ascii client with
  | "codex-headless" -> "codex"
  | other -> other

let known_clients = [ "claude"; "codex"; "opencode"; "kimi"; "crush"; "gemini" ]
let install_subcommand_clients = [ "claude"; "codex"; "codex-headless"; "opencode"; "kimi"; "crush"; "gemini" ]
let install_client_error_list = String.concat ", " install_subcommand_clients
let install_client_pipe_list = String.concat "|" install_subcommand_clients
let init_configurable_clients = [ "claude"; "opencode"; "codex"; "codex-headless"; "kimi"; "gemini" ]
let init_configurable_client_list = String.concat ", " init_configurable_clients
let detect_client_prefixes = [ "opencode"; "claude"; "codex-headless"; "codex"; "kimi"; "gemini"; "crush" ]
let start_clients = [ "claude"; "codex"; "codex-headless"; "kimi"; "gemini"; "opencode"; "crush"; "tmux"; "pty"; "relay-connect" ]
let start_client_list = String.concat ", " start_clients

let do_install_client ?(channel_delivery=false) ?(global=false) ~output_mode ~dry_run ~client ~alias_opt ~broker_root_opt ~target_dir_opt ~force () =
  let client = canonical_install_client client in
  let root =
    match broker_root_opt with
    | Some r -> r
    | None -> resolve_broker_root ()
  in
  let alias_val =
    match alias_opt with
    | Some a -> a
    | None ->
        let a = default_alias_for_client client in
        Printf.eprintf "[c2c setup] no --alias given; auto-picked alias=%s. Pass --alias NAME to override.\n%!" a;
        a
  in
  let (server_path, mcp_command) = resolve_mcp_server_paths ~output_mode in
  match client with
  | "claude" -> setup_claude ~output_mode ~dry_run ~root ~alias_val ~alias_opt ~server_path ~mcp_command ~force ~channel_delivery ~global ~project_dir:target_dir_opt
  | "codex" -> setup_codex ~output_mode ~dry_run ~root ~alias_val ~server_path ~mcp_command ~client
  | "kimi" -> setup_kimi ~output_mode ~dry_run ~root ~alias_val ~server_path
  | "gemini" -> setup_gemini ~output_mode ~dry_run ~root ~alias_val ~server_path ~mcp_command
  | "opencode" -> setup_opencode ~output_mode ~dry_run ~root ~alias_val ~server_path ~target_dir_opt ~force ()
  | "crush" -> setup_crush ~output_mode ~dry_run ~root ~alias_val ~server_path
  | _ ->
      let msg = Printf.sprintf "unknown client '%s'. Use: %s" client install_client_error_list in
      (match output_mode with
       | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])
       | Human ->
           Printf.eprintf "error: %s\n%!" msg;
           exit 1)

(* --- install: detection + TUI --------------------------------------------- *)

let self_installed_path () =
  let home = try Sys.getenv "HOME" with Not_found -> "" in
  let p = home // ".local" // "bin" // "c2c" in
  if Sys.file_exists p then Some p else None

(* #411: shared check for `mcpServers.c2c` membership in a JSON config. *)
let json_file_has_c2c_mcp_entry path =
  if not (Sys.file_exists path) then false
  else
    try
      match json_read_file path with
      | `Assoc fields ->
          (match List.assoc_opt "mcpServers" fields with
           | Some (`Assoc m) -> List.mem_assoc "c2c" m
           | _ -> false)
      | _ -> false
    with _ -> false

let client_configured client =
  let home = try Sys.getenv "HOME" with Not_found -> "" in
  match String.lowercase_ascii client with
  | "claude" ->
      (* Claude has TWO valid install scopes (#334):
         - global / user-scope: ~/.claude.json
         - project-scope (the install default since #334): <cwd>/.mcp.json
         The verifier must accept either, else `c2c install all` re-prompts a
         working project-scope install and the TUI mis-reports state.
         Surfaced by the cross-client install audit (#411). *)
      let user_scope = home // ".claude.json" in
      let project_scope = Sys.getcwd () // ".mcp.json" in
      json_file_has_c2c_mcp_entry user_scope
      || json_file_has_c2c_mcp_entry project_scope
   | "codex" | "codex-headless" ->
       let p = home // ".codex" // "config.toml" in
       if not (Sys.file_exists p) then false
       else
         (try
            let ic = open_in p in
            let s =
              Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
                really_input_string ic (in_channel_length ic))
            in
            let needle = "[mcp_servers.c2c]" in
            let nl = String.length needle and hl = String.length s in
            let rec loop i =
              i <= hl - nl
              && (String.sub s i nl = needle || loop (i + 1))
            in
            loop 0
          with _ -> false)
   | "kimi" ->
      let p = home // ".kimi" // "mcp.json" in
      if not (Sys.file_exists p) then false
      else
        (try
           match json_read_file p with
           | `Assoc fields ->
               (match List.assoc_opt "mcpServers" fields with
                | Some (`Assoc m) -> List.mem_assoc "c2c" m
                | _ -> false)
           | _ -> false
         with _ -> false)
   | "gemini" ->
      let p = home // ".gemini" // "settings.json" in
      if not (Sys.file_exists p) then false
      else
        (try
           match json_read_file p with
           | `Assoc fields ->
               (match List.assoc_opt "mcpServers" fields with
                | Some (`Assoc m) -> List.mem_assoc "c2c" m
                | _ -> false)
           | _ -> false
         with _ -> false)
  | "opencode" ->
      let p = Sys.getcwd () // ".opencode" // "opencode.json" in
      if not (Sys.file_exists p) then false
      else
        (try
           match json_read_file p with
           | `Assoc fields ->
               (match List.assoc_opt "mcp" fields with
                | Some (`Assoc m) -> List.mem_assoc "c2c" m
                | _ -> false)
           | _ -> false
         with _ -> false)
  | "crush" ->
      let p = home // ".config" // "crush" // "crush.json" in
      if not (Sys.file_exists p) then false
      else
        (try
           match json_read_file p with
           | `Assoc fields ->
               (match List.assoc_opt "mcpServers" fields with
                | Some (`Assoc m) -> List.mem_assoc "c2c" m
                | _ -> false)
           | _ -> false
         with _ -> false)
  | _ -> false

(* [detect_installation ()] returns the detection snapshot:
   (self_installed, [(client, binary_on_path, configured)]) *)
let detect_installation () =
  let self = self_installed_path () <> None in
  let clients = List.map (fun c ->
    (c, which_binary c <> None, client_configured c)
  ) known_clients in
  (self, clients)

let prompt_yn ?(default_yes = true) q =
  Printf.printf "%s " q;
  let suffix = if default_yes then "[Y/n]: " else "[y/N]: " in
  print_string suffix;
  let () = try flush stdout with _ -> () in
  match (try Some (input_line stdin) with End_of_file -> None) with
  | None -> default_yes
  | Some s ->
      let t = String.lowercase_ascii (String.trim s) in
      if t = "" then default_yes
      else (t.[0] = 'y')

let prompt_channel_delivery () =
  Printf.printf
    "\n  Enable experimental channel-delivery (C2C_MCP_CHANNEL_DELIVERY=1)?\n\
    \    When Claude Code declares support for experimental.claude/channel,\n\
    \    the broker auto-injects inbound messages into the transcript without\n\
    \    polling. Standard Claude Code doesn't declare this capability, so\n\
    \    today it's a no-op — but if a future build enables it, auto-injection\n\
    \    would fire unprompted. Security-conscious users may prefer to leave\n\
    \    it off and rely on the PostToolUse hook + poll_inbox instead.\n";
  prompt_yn ~default_yes:false "  Enable channel delivery?"

let run_install_tui ~alias_opt ~broker_root_opt ~dry_run =
  let (self, clients) = detect_installation () in
  Printf.printf "c2c installer\n";
  Printf.printf "─────────────\n\n";
  Printf.printf "Here's the plan — press [Enter] to proceed with defaults.\n\n";
  let self_default = not self in
  let client_defaults = List.map (fun (c, on_path, configured) ->
    let do_it = on_path && not configured in
    (c, on_path, configured, do_it)
  ) clients in
  let mark b = if b then "[x]" else "[ ]" in
  let self_suffix =
    if self then "→ ~/.local/bin/c2c (already present)"
    else "→ install to ~/.local/bin/c2c"
  in
  Printf.printf "  %s %-22s %s\n" (mark self_default) "install c2c binary" self_suffix;
  List.iter (fun (c, on_path, configured, do_it) ->
    let label = Printf.sprintf "configure %s" c in
    let suffix =
      if not on_path then "→ not on PATH, skipping"
      else if configured then "→ already configured"
      else "→ detected"
    in
    Printf.printf "  %s %-22s %s\n" (mark do_it) label suffix
  ) client_defaults;
  Printf.printf "\nPress [Enter] to proceed, [c] to customize, [n] to abort: ";
  let () = try flush stdout with _ -> () in
  let choice =
    match (try Some (input_line stdin) with End_of_file -> None) with
    | None -> ""
    | Some s -> String.lowercase_ascii (String.trim s)
  in
  let (do_self, do_clients) =
    if choice = "n" || choice = "no" || choice = "abort" then begin
      Printf.printf "Aborted.\n";
      exit 0
    end
    else if choice = "c" || choice = "customize" then begin
      Printf.printf "\nCustomize:\n";
      let s =
        if self then
          prompt_yn ~default_yes:false "  Reinstall c2c binary?"
        else prompt_yn "  Install c2c binary?"
      in
      let cs = List.map (fun (c, on_path, configured, _default) ->
        if not on_path then (c, false)
        else
          let q =
            if configured
            then Printf.sprintf "  Reconfigure %s?" c
            else Printf.sprintf "  Configure %s?" c
          in
          let default = not configured in
          (c, prompt_yn ~default_yes:default q)
      ) client_defaults in
      (s, cs)
    end
    else
      let cs = List.map (fun (c, _, _, do_it) -> (c, do_it)) client_defaults in
      (self_default, cs)
  in
  let any_action = do_self || List.exists (fun (_, do_it) -> do_it) do_clients in
  if not any_action then
    Printf.printf "\nNothing to do.\n"
  else begin
    Printf.printf "\n";
    if do_self then begin
      Printf.printf "→ Installing c2c binary...\n";
      do_install_self ~output_mode:Human ~dest_opt:None ~with_mcp_server:false
    end;
    List.iter (fun (c, do_it) ->
      if do_it then begin
        Printf.printf "\n→ Configuring %s...\n" c;
        let channel_delivery =
          if c = "claude" then prompt_channel_delivery () else false
        in
        do_install_client ~channel_delivery ~output_mode:Human ~dry_run ~client:c ~alias_opt
          ~broker_root_opt ~target_dir_opt:None ~force:false ()
      end
    ) do_clients;
    Printf.printf "\nDone.\n"
  end

(* --- install: Cmdliner wiring --------------------------------------------- *)

let install_common_args () =
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS" ~doc:"Alias to use (default: auto-generated per client).")
  in
  let broker_root =
    Cmdliner.Arg.(value & opt (some string) None & info [ "broker-root"; "b" ] ~docv:"DIR" ~doc:"Broker root directory (default: auto-detected).")
  in
  let target_dir =
    Cmdliner.Arg.(value & opt (some string) None & info [ "target-dir"; "t" ] ~docv:"DIR" ~doc:"Target directory for opencode/claude project config (default: cwd).")
  in
  let force =
    Cmdliner.Arg.(value & flag & info [ "force"; "f" ] ~doc:"Overwrite existing configuration.")
  in
  let dry_run =
    Cmdliner.Arg.(value & flag & info [ "dry-run"; "n" ] ~doc:"Show what would be written without writing anything.")
  in
  let global =
    Cmdliner.Arg.(value & flag & info [ "global" ] ~doc:"(claude only) Write the MCP server entry to user-global ~/.claude.json instead of project-scoped <cwd>/.mcp.json. Defaults to project scope so a fresh clone wires c2c on first install.")
  in
  (alias, broker_root, target_dir, force, dry_run, global)

let install_self_subcmd =
  let dest =
    Cmdliner.Arg.(value & opt (some string) None & info [ "dest"; "d" ] ~docv:"DIR" ~doc:"Install destination (default: ~/.local/bin).")
  in
  let mcp_server =
    Cmdliner.Arg.(value & flag & info [ "mcp-server" ] ~doc:"Also install the c2c MCP server binary as ~/.local/bin/c2c-mcp-server. The MCP server is the JSON-RPC bridge that enables c2c messaging between coding CLIs.")
  in
  let term =
    let+ json = json_flag
    and+ dest_opt = dest
    and+ with_mcp_server = mcp_server in
    let output_mode = if json then Json else Human in
    do_install_self ~output_mode ~dest_opt ~with_mcp_server
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "self"
       ~doc:"Install the running c2c binary to ~/.local/bin.")
    term

let install_client_subcmd client =
  let (alias, broker_root, target_dir, force, dry_run, global) = install_common_args () in
  let term =
    let+ json = json_flag
    and+ alias_opt = alias
    and+ broker_root_opt = broker_root
    and+ target_dir_opt = target_dir
    and+ force = force
    and+ dry_run = dry_run
    and+ global = global in
    let output_mode = if json then Json else Human in
    let channel_delivery =
      if client = "claude" && output_mode = Human then prompt_channel_delivery () else false
    in
    do_install_client ~channel_delivery ~global ~output_mode ~dry_run ~client ~alias_opt ~broker_root_opt ~target_dir_opt ~force ()
  in
  let doc = Printf.sprintf "Configure %s for c2c messaging." client in
  Cmdliner.Cmd.v (Cmdliner.Cmd.info client ~doc) term

let install_all_subcmd =
  let (alias, broker_root, _, _, dry_run, global) = install_common_args () in
  let term =
    let+ json = json_flag
    and+ alias_opt = alias
    and+ broker_root_opt = broker_root
    and+ dry_run = dry_run
    and+ global = global in
    let output_mode = if json then Json else Human in
    let (self, clients) = detect_installation () in
    if not self then begin
      if output_mode = Human then Printf.printf "→ Installing c2c binary...\n";
      do_install_self ~output_mode ~dest_opt:None ~with_mcp_server:false
    end;
    List.iter (fun (c, on_path, configured) ->
      if on_path && not configured then begin
        if output_mode = Human then Printf.printf "\n→ Configuring %s...\n" c;
        do_install_client ~global ~output_mode ~dry_run ~client:c ~alias_opt ~broker_root_opt
          ~target_dir_opt:None ~force:false ()
      end
    ) clients;
    if output_mode = Human then Printf.printf "\nDone.\n"
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "all"
       ~doc:"Install c2c binary and auto-configure every detected client (scriptable, no prompts).")
    term

let do_install_git_hook ~output_mode ~dry_run =
  let repo_root =
    match Git_helpers.git_repo_toplevel () with
    | Some r -> r
    | None ->
      (match output_mode with
       | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String "not in a git repository") ])
       | Human -> Printf.eprintf "error: not in a git repository\n%!");
      exit 1
  in
  let git_common =
    match Git_helpers.git_common_dir () with
    | Some d -> d
    | None ->
      (match output_mode with
       | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String "cannot determine git common dir") ])
       | Human -> Printf.eprintf "error: cannot determine git common dir\n%!");
      exit 1
  in
  let hook_src =
    let parent = Option.value (Git_helpers.git_common_dir_parent ()) ~default:repo_root in
    parent // ".c2c" // "hooks" // "pre-commit.sh" in
  let hook_dst = git_common // "hooks" // "pre-commit" in
  if not (Sys.file_exists hook_src) then begin
    (match output_mode with
     | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String ("hook source not found: " ^ hook_src)) ])
     | Human -> Printf.eprintf "error: hook source not found: %s\n%!" hook_src);
    exit 1
  end;
  let file_size path = try (Unix.stat path).Unix.st_size with Unix.Unix_error _ -> 0 in
  let hook_src_size = file_size hook_src in
  if dry_run then
    (match output_mode with
     | Json -> print_json (`Assoc [ ("ok", `Bool true); ("dry_run", `Bool true); ("src", `String hook_src); ("dst", `String hook_dst) ])
     | Human -> Printf.printf "[DRY-RUN] would copy %d bytes from %s to %s and chmod 755\n%!" hook_src_size hook_src hook_dst)
  else
    (try
       let ic = open_in_bin hook_src in
       let oc = open_out_bin (hook_dst ^ ".tmp") in
       Fun.protect ~finally:(fun () -> close_in ic; close_out oc) (fun () ->
         let buf = Bytes.create 65536 in
         let rec loop () =
           let n = input ic buf 0 (Bytes.length buf) in
           if n > 0 then (output oc buf 0 n; loop ())
         in
         loop ());
        Unix.rename (hook_dst ^ ".tmp") hook_dst;
        Unix.chmod hook_dst 0o755;
        (match output_mode with
         | Json -> print_json (`Assoc [ ("ok", `Bool true); ("src", `String hook_src); ("dst", `String hook_dst) ])
         | Human -> Printf.printf "→ Installed pre-commit hook: %s\n%!" hook_dst)
      with Unix.Unix_error (e, _, _) ->
        (match output_mode with
         | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String (Unix.error_message e)) ])
         | Human -> Printf.eprintf "error: %s\n%!" (Unix.error_message e));
        exit 1)

let install_git_hook_subcmd =
  let term =
    let+ json = json_flag
    and+ dry_run =
      Cmdliner.Arg.(value & flag & info [ "dry-run"; "n" ] ~doc:"Show what would be done without doing it.")
    in
    let output_mode = if json then Json else Human in
    do_install_git_hook ~output_mode ~dry_run
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "git-hook"
       ~doc:"Install the c2c pre-commit hook into the repo's .git/hooks directory.")
    term

let install_default_term =
  let (alias, broker_root, _, _, dry_run, _) = install_common_args () in
  let+ alias_opt = alias
  and+ broker_root_opt = broker_root
  and+ dry_run = dry_run in
  run_install_tui ~alias_opt ~broker_root_opt ~dry_run
