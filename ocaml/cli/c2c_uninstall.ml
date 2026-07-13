(* c2c_uninstall.ml — inverse of c2c install.

   Removes artifacts recorded in the install manifest, falling back to
   deterministic known paths when the manifest is missing or incomplete.
   Shared files are surgically stripped; owned files are deleted. *)

let ( // ) = Filename.concat
open C2c_types
open Cmdliner.Term.Syntax

let known_components =
  [ "claude"; "codex"; "kimi"; "opencode"; "grok"; "agy"; "self"; "git-hook"; "git-shim"; "all" ]

let home_dir () = try Sys.getenv "HOME" with Not_found -> ""

let resolve_target_dir target_dir_opt =
  match target_dir_opt with
  | None -> Sys.getcwd ()
  | Some d ->
      let abs = if Filename.is_relative d then Sys.getcwd () // d else d in
      (try Unix.realpath abs with Unix.Unix_error _ -> abs)

(* -------------------------------------------------------------------------- *)
(* JSON / TOML surgical removers *)
(* -------------------------------------------------------------------------- *)

let read_json_opt path =
  if not (Sys.file_exists path) then None
  else
    try Some (Yojson.Safe.from_file path) with _ -> None

let write_json_atomic path json =
  C2c_utils.atomic_write_json path json

let rec remove_json_key json keys =
  match json, keys with
  | `Assoc fields, [k] ->
      `Assoc (List.filter (fun (kk, _) -> kk <> k) fields)
  | `Assoc fields, k :: rest ->
      `Assoc
        (List.map
           (fun (kk, v) ->
              if kk = k then (kk, remove_json_key v rest) else (kk, v))
           fields)
  | _ -> json

let remove_shared_key ~dry_run path key =
  match read_json_opt path with
  | None -> None
  | Some json ->
      let keys = String.split_on_char '.' key in
      let cleaned = remove_json_key json keys in
      if cleaned = json then None
      else if dry_run then Some path
      else begin
        write_json_atomic path cleaned;
        Some path
      end

let strip_toml_sections ~section_prefix content =
  let lines = String.split_on_char '\n' content in
  let in_c2c = ref false in
  let kept =
    List.filter_map
      (fun line ->
         let trimmed = String.trim line in
         if String.length trimmed > 0 && trimmed.[0] = '[' then
           in_c2c :=
             (try
                let sec = String.sub trimmed 1 (String.length trimmed - 2) in
                String.length sec >= String.length section_prefix
                && String.sub sec 0 (String.length section_prefix) = section_prefix
              with _ -> false);
         if !in_c2c then None else Some line)
      lines
  in
  String.concat "\n" kept

let remove_shared_toml_section ~dry_run ~section_prefix path =
  if not (Sys.file_exists path) then None
  else
    let content = C2c_utils.read_file_opt path in
    if content = "" then None
    else
      let stripped = strip_toml_sections ~section_prefix content in
      if stripped = content then None
      else if dry_run then Some path
      else begin
        (match C2c_utils.write_file_atomic path stripped with
         | Ok () -> ()
         | Error _ -> ());
        Some path
      end

let strip_block ~begin_marker ~end_marker ?legacy_marker content =
  let starts_with s prefix =
    String.length s >= String.length prefix
    && String.sub s 0 (String.length prefix) = prefix
  in
  let legacy_matches trimmed =
    match legacy_marker with
    | Some marker -> trimmed = marker || starts_with trimmed marker
    | None -> false
  in
  let lines = String.split_on_char '\n' content in
  let in_block = ref false in
  let in_legacy_block = ref false in
  let stripped_any = ref false in
  let kept =
    List.filter_map
      (fun line ->
         let trimmed = String.trim line in
         if !in_legacy_block then begin
           if trimmed = "" || starts_with trimmed "#" then begin
             stripped_any := true;
             None
           end else begin
             in_legacy_block := false;
             Some line
           end
         end else if trimmed = begin_marker then begin
           in_block := true;
           stripped_any := true;
           None
         end else if trimmed = end_marker then begin
           in_block := false;
           stripped_any := true;
           None
         end else if legacy_matches trimmed then begin
           in_legacy_block := true;
           stripped_any := true;
           None
         end else if !in_block then begin
           stripped_any := true;
           None
         end else
           Some line)
      lines
  in
  (String.concat "\n" kept, !stripped_any)

let remove_shared_block ~dry_run ~begin_marker ~end_marker ?legacy_marker path =
  if not (Sys.file_exists path) then None
  else
    let content = C2c_utils.read_file_opt path in
    if content = "" then None
    else
      let stripped, changed =
        strip_block ~begin_marker ~end_marker ?legacy_marker content
      in
      if not changed then None
      else if dry_run then Some path
      else begin
        (match C2c_utils.write_file_atomic path stripped with
         | Ok () -> ()
         | Error _ -> ());
        Some path
      end

(* -------------------------------------------------------------------------- *)
(* Claude settings.json hook cleanup *)
(* -------------------------------------------------------------------------- *)

let remove_claude_settings_hooks ~dry_run path c2c_scripts =
  if not (Sys.file_exists path) then None
  else
    match read_json_opt path with
    | None -> None
    | Some json ->
        let filter_hook_commands hooks =
          List.filter_map
            (fun entry ->
               match entry with
               | `Assoc e ->
                   (match List.assoc_opt "hooks" e with
                    | Some (`List hs) ->
                        let filtered =
                          List.filter
                            (fun h ->
                               match h with
                               | `Assoc hf ->
                                   (match List.assoc_opt "command" hf with
                                    | Some (`String cmd) ->
                                        not (List.mem cmd c2c_scripts)
                                    | _ -> true)
                               | _ -> true)
                            hs
                        in
                        if List.length filtered = List.length hs then Some entry
                        else if filtered = [] then None
                        else Some (`Assoc (("hooks", `List filtered) :: List.filter (fun (k,_) -> k <> "hooks") e))
                    | _ -> Some entry)
               | _ -> Some entry)
            hooks
        in
        let remove_sentinel_pre_tool_use entries =
          List.filter
            (fun entry ->
               match entry with
               | `Assoc e ->
                   (match List.assoc_opt "matcher" e with
                    | Some (`String "__C2C_PREAUTH_DISABLED__") -> false
                    | _ -> true)
               | _ -> true)
            entries
        in
        let changed = ref false in
        let cleaned =
          match json with
          | `Assoc fields ->
              (match List.assoc_opt "hooks" fields with
               | Some (`Assoc hooks) ->
                   let hooks =
                     List.map
                       (fun (k, v) ->
                          match k, v with
                          | ("PostToolUse" | "Stop" | "SessionStart" | "SessionEnd"), `List entries ->
                              let filtered = filter_hook_commands entries in
                              if List.length filtered <> List.length entries then changed := true;
                              (k, `List filtered)
                          | "PreToolUse", `List entries ->
                              let filtered = remove_sentinel_pre_tool_use entries in
                              if List.length filtered <> List.length entries then changed := true;
                              (k, `List filtered)
                          | _ -> (k, v))
                       hooks
                   in
                   let hooks = List.filter (fun (_, v) -> v <> `List []) hooks in
                   if hooks <> [] then
                     `Assoc (List.filter (fun (k, _) -> k <> "hooks") fields @ [ ("hooks", `Assoc hooks) ])
                   else begin
                     changed := true;
                     `Assoc (List.filter (fun (k, _) -> k <> "hooks") fields)
                   end
               | _ -> json)
          | _ -> json
        in
        if not !changed then None
        else if dry_run then Some path
        else begin
          write_json_atomic path cleaned;
          Some path
        end

(* -------------------------------------------------------------------------- *)
(* Owned file / directory removal *)
(* -------------------------------------------------------------------------- *)

let safe_remove_owned ~dry_run path =
  if not (Sys.file_exists path) then None
  else if dry_run then Some path
  else begin
    (try
       let stat = Unix.lstat path in
       match stat.Unix.st_kind with
       | Unix.S_DIR ->
           (* Only remove empty directories; client dirs may have runtime files. *)
           let entries = Sys.readdir path in
           if Array.length entries = 0 then Unix.rmdir path
       | _ -> Unix.unlink path
     with Unix.Unix_error _ -> ());
    Some path
  end

(* -------------------------------------------------------------------------- *)
(* Git hook verification/removal *)
(* -------------------------------------------------------------------------- *)

let c2c_hook_source () =
  match Git_helpers.git_repo_toplevel () with
  | None -> None
  | Some r ->
      let parent = Option.value (Git_helpers.git_common_dir_parent ()) ~default:r in
      let src = parent // ".c2c" // "hooks" // "pre-commit.sh" in
      if Sys.file_exists src then Some src else None

let string_contains s sub =
  let rec aux i =
    if i + String.length sub > String.length s then false
    else if String.sub s i (String.length sub) = sub then true
    else aux (i + 1)
  in
  aux 0

let is_c2c_hook hook_path hook_src =
  if not (Sys.file_exists hook_path) then false
  else
    try
      let stat = Unix.lstat hook_path in
      match stat.Unix.st_kind with
      | Unix.S_LNK ->
          let target = Unix.readlink hook_path in
          string_contains target "scripts/git-hooks" || target = hook_src
      | _ ->
          let src_content = C2c_utils.read_file_opt hook_src in
          let dst_content = C2c_utils.read_file_opt hook_path in
          src_content <> "" && src_content = dst_content
    with _ -> false

let remove_git_hook_file ~dry_run path hook_src =
  if not (is_c2c_hook path hook_src) then None
  else if dry_run then Some path
  else begin
    (try Unix.unlink path with Unix.Unix_error _ -> ());
    Some path
  end

(* -------------------------------------------------------------------------- *)
(* Manifest helpers *)
(* -------------------------------------------------------------------------- *)

let find_manifest_record component target_dir =
  let m = C2c_install_manifest.read_manifest () in
  let exact =
    List.find_opt
    (fun r -> r.C2c_install_manifest.component = component && r.target_dir = target_dir)
    m.installs
  in
  match exact with
  | Some _ -> exact
  | None ->
      if List.mem component [ "codex"; "kimi"; "git-shim" ] then
        List.find_opt
          (fun r -> r.C2c_install_manifest.component = component)
          m.installs
      else None

let remove_manifest_record component target_dir =
  try C2c_install_manifest.remove_record ~component ~target_dir
  with _ -> ()

let artifact_key a =
  ( a.C2c_install_manifest.kind
  , a.path
  , a.key
  , a.begin_marker
  , a.end_marker
  , a.section_prefix )

let dedupe_artifacts artifacts =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun a ->
       let key = artifact_key a in
       if Hashtbl.mem seen key then false
       else begin
         Hashtbl.add seen key ();
         true
       end)
    artifacts

(* -------------------------------------------------------------------------- *)
(* Recompute fallback artifacts *)
(* -------------------------------------------------------------------------- *)

let rec concat = function [] -> "" | [x] -> x | x :: xs -> x // concat xs

let deliver_watch_artifacts client =
  let client_dir = home_dir () // ".c2c" // "clients" // client in
  [ C2c_install_manifest.owned_file (client_dir // "deliver-watch.sh")
  ; C2c_install_manifest.owned_file (client_dir // "start-hooks" // "pre-deliver.sh")
  ]

let recompute_claude_artifacts ~target_dir =
  let claude_dir = C2c_setup.resolve_claude_dir () in
  let project_mcp = target_dir // ".mcp.json" in
  let global_mcp = claude_dir // ".claude.json" in
  let settings = claude_dir // "settings.json" in
  let hook_script = claude_dir // "hooks" // "c2c-inbox-check.sh" in
  let stop_hook_script = claude_dir // "hooks" // "c2c-stop-deliver.sh" in
  let session_hook_script = claude_dir // "hooks" // "c2c-session-hook.sh" in
  let skill_path = claude_dir // "skills" // "c2c" // "SKILL.md" in
  let shared =
    (if Sys.file_exists project_mcp then
       [ C2c_install_manifest.shared_key ~path:project_mcp ~key:"mcpServers.c2c" ~format:"json" ]
     else [])
    @ (if Sys.file_exists global_mcp then
         [ C2c_install_manifest.shared_key ~path:global_mcp ~key:"mcpServers.c2c" ~format:"json" ]
       else [])
  in
  let owned =
    [ C2c_install_manifest.owned_file hook_script
    ; C2c_install_manifest.owned_file stop_hook_script
    ; C2c_install_manifest.owned_file session_hook_script
    ; C2c_install_manifest.owned_file skill_path
    ]
  in
  (shared, owned, Some settings)

let recompute_codex_artifacts () =
  let config = home_dir () // ".codex" // "config.toml" in
  let agents_md = home_dir () // ".codex" // "AGENTS.md" in
  let skill_path = home_dir () // ".codex" // "skills" // "c2c" // "SKILL.md" in
  (* Shared blocks mirror what setup_codex declares: the config.toml hooks
     block and the AGENTS.md orientation block, so a manifest-less
     `c2c uninstall codex` strips them too. The deliver-watch owned files are
     no longer written by install (hooks are the delivery path) but stay here
     so uninstall can remove scripts from older installs; removal is a no-op
     when the files are absent. *)
  ([ C2c_install_manifest.shared_toml_section ~path:config ~section_prefix:"mcp_servers.c2c"
   ; C2c_install_manifest.shared_block ~path:config
       ~begin_marker:C2c_codex_hooks.config_begin_marker
       ~end_marker:C2c_codex_hooks.config_end_marker ()
   ; C2c_install_manifest.shared_block ~path:agents_md
       ~begin_marker:C2c_codex_hooks.agents_md_begin_marker
       ~end_marker:C2c_codex_hooks.agents_md_end_marker ()
   ],
   C2c_install_manifest.owned_file skill_path :: deliver_watch_artifacts "codex",
   None)

let recompute_kimi_artifacts () =
  let home = home_dir () in
  let config = home // ".kimi" // "mcp.json" in
  let toml = home // ".kimi" // "config.toml" in
  let hook = home // ".local" // "bin" // "c2c-kimi-approval-hook.sh" in
  let begin_marker =
    C2c_kimi_hook.toml_block_begin_marker ~block_id:C2c_kimi_hook.approval_hook_block_id
  in
  let end_marker =
    C2c_kimi_hook.toml_block_end_marker ~block_id:C2c_kimi_hook.approval_hook_block_id
  in
  ([ C2c_install_manifest.shared_key ~path:config ~key:"mcpServers.c2c" ~format:"json"
   ; C2c_install_manifest.shared_block ~path:toml ~begin_marker ~end_marker
       ~legacy_marker:C2c_kimi_hook.toml_block_legacy_marker ()
   ],
   C2c_install_manifest.owned_file hook :: deliver_watch_artifacts "kimi",
   None)

let recompute_opencode_artifacts ~target_dir =
  let config_dir = target_dir // ".opencode" in
  ([ C2c_install_manifest.shared_key ~path:(config_dir // "opencode.json") ~key:"mcp.c2c" ~format:"json" ],
   [ C2c_install_manifest.owned_file (config_dir // "c2c-plugin.json")
   ; C2c_install_manifest.owned_file (config_dir // "plugins" // "c2c.ts")
   ] @ deliver_watch_artifacts "opencode",
   None)

let recompute_crush_artifacts () =
  let config = home_dir () // ".config" // "crush" // "crush.json" in
  ([ C2c_install_manifest.shared_key ~path:config ~key:"mcpServers.c2c" ~format:"json" ],
   deliver_watch_artifacts "crush",
   None)

let recompute_grok_artifacts () =
  let home = home_dir () in
  let skill = home // ".grok" // "skills" // "c2c" // "SKILL.md" in
  let session_skill = home // ".grok" // "skills" // "c2c-session" // "SKILL.md" in
  let hooks = home // ".grok" // "hooks" // "c2c-session.json" in
  ( []
  , [ C2c_install_manifest.owned_file skill
    ; C2c_install_manifest.owned_file session_skill
    ; C2c_install_manifest.owned_file hooks
    ]
  , None )

let recompute_agy_artifacts () =
  let home = home_dir () in
  let skill = home // ".gemini" // "skills" // "c2c" // "SKILL.md" in
  let hooks_path = home // ".gemini" // "config" // "hooks.json" in
  ( [ C2c_install_manifest.shared_key ~path:hooks_path ~key:"c2c-hooks" ~format:"json" ]
  , [ C2c_install_manifest.owned_file skill ]
  , None )

let recompute_self_artifacts () =
  let home = home_dir () in
  let bin = home // ".local" // "bin" in
  let names =
    [ "c2c"; "c2c-mcp-server"; "c2c-mcp-inner"; "c2c-inbox-hook-ocaml"
    ; "c2c-cold-boot-hook"; "c2c-post-compact-hook"; "cc-quota"
    ; "c2c-deliver-inbox"; "c2c-gui"
    ]
  in
  List.map
    (fun name -> C2c_install_manifest.binary (bin // name))
    (names @ [ ".c2c-version" ])

let recompute_git_shim_artifacts () =
  let shim_dir = C2c_start.swarm_git_shim_dir () in
  let base =
    [ C2c_install_manifest.binary (shim_dir // "git")
    ; C2c_install_manifest.binary (shim_dir // "git-pre-reset")
    ]
  in
  let instances =
    if Sys.file_exists C2c_start.instances_dir && Sys.is_directory C2c_start.instances_dir then
      Sys.readdir C2c_start.instances_dir
      |> Array.to_list
      |> List.concat_map
           (fun name ->
              let d = C2c_start.instances_dir // name // "bin" in
              [ C2c_install_manifest.binary (d // "git")
              ; C2c_install_manifest.binary (d // "git-pre-reset")
              ])
    else []
  in
  base @ instances

let recompute_git_hook_artifacts ~target_dir =
  let git_common =
    match Git_helpers.git_common_dir () with
    | Some d -> d
    | None -> target_dir // ".git"
  in
  [ C2c_install_manifest.owned_file (git_common // "hooks" // "pre-commit")
  ; C2c_install_manifest.owned_file (git_common // "hooks" // "pre-push")
  ]

let recompute_artifacts_for_component ~component ~target_dir =
  match component with
  | "claude" -> recompute_claude_artifacts ~target_dir
  | "codex" -> recompute_codex_artifacts ()
  | "kimi" -> recompute_kimi_artifacts ()
  | "opencode" -> recompute_opencode_artifacts ~target_dir
  | "crush" -> recompute_crush_artifacts ()
  | "grok" -> recompute_grok_artifacts ()
  | "agy" -> recompute_agy_artifacts ()
  | "git-hook" -> ([], recompute_git_hook_artifacts ~target_dir, None)
  | "git-shim" -> ([], recompute_git_shim_artifacts (), None)
  | _ -> ([], [], None)

(* -------------------------------------------------------------------------- *)
(* Artifact removal dispatcher *)
(* -------------------------------------------------------------------------- *)

let remove_artifact ~dry_run a =
  match a.C2c_install_manifest.kind with
  | "owned-file" | "symlink" | "binary" | "schedule" ->
      safe_remove_owned ~dry_run a.path
  | "shared-key" ->
      (match a.key with
       | Some key -> remove_shared_key ~dry_run a.path key
       | None -> None)
  | "shared-block" ->
      (match a.begin_marker, a.end_marker with
       | Some b, Some e ->
           remove_shared_block ~dry_run ~begin_marker:b ~end_marker:e ?legacy_marker:a.legacy_marker a.path
       | _ -> None)
  | "shared-toml-section" ->
      (match a.section_prefix with
       | Some p -> remove_shared_toml_section ~dry_run ~section_prefix:p a.path
       | None -> None)
  | _ -> None

(* -------------------------------------------------------------------------- *)
(* Component uninstall *)
(* -------------------------------------------------------------------------- *)

let uninstall_component ~output_mode ~dry_run ~component ~target_dir ~alias =
  let record = find_manifest_record component target_dir in
  let manifest_target_dir =
    match record with
    | Some r -> r.C2c_install_manifest.target_dir
    | None -> target_dir
  in
  let recomputed_shared, recomputed_owned, recomputed_settings =
    recompute_artifacts_for_component ~component ~target_dir
  in
  let artifacts, settings_path =
    match record with
    | Some r ->
        let sched =
          match alias with
          | Some a -> [ C2c_install_manifest.schedule (C2c_mcp.schedule_entry_path a "wake") ]
          | None ->
              List.filter_map
                (fun a -> if a.C2c_install_manifest.kind = "schedule" then Some a else None)
                r.artifacts
        in
        ( dedupe_artifacts
            (r.C2c_install_manifest.artifacts @ recomputed_shared @ recomputed_owned @ sched)
        , recomputed_settings )
    | None ->
        let sched =
          match alias with
          | Some a -> [ C2c_install_manifest.schedule (C2c_mcp.schedule_entry_path a "wake") ]
          | None -> []
        in
        (dedupe_artifacts (recomputed_shared @ recomputed_owned @ sched), recomputed_settings)
  in
  (* For claude, always clean settings.json via recompute even if manifest missed it. *)
  let settings_removed =
    if component = "claude" then
      match settings_path with
      | Some settings ->
          let claude_dir = C2c_setup.resolve_claude_dir () in
          let hook_script = claude_dir // "hooks" // "c2c-inbox-check.sh" in
          let stop_hook_script = claude_dir // "hooks" // "c2c-stop-deliver.sh" in
          let session_hook_script = claude_dir // "hooks" // "c2c-session-hook.sh" in
          remove_claude_settings_hooks ~dry_run settings
            [ hook_script; stop_hook_script; session_hook_script ]
      | None -> None
    else None
  in
  (* For git-hook, verify before removing. *)
  let removed_paths =
    if component = "git-hook" then
      match c2c_hook_source () with
      | Some hook_src ->
          List.filter_map
            (fun a -> remove_git_hook_file ~dry_run a.C2c_install_manifest.path hook_src)
            artifacts
      | None -> []
    else
      List.filter_map (remove_artifact ~dry_run) artifacts
  in
  let all_removed =
    match settings_removed with
    | Some p -> p :: removed_paths
    | None -> removed_paths
  in
  let any_removed = all_removed <> [] in
  if not dry_run && (any_removed || Option.is_some record) then
    remove_manifest_record component manifest_target_dir;
  (any_removed, all_removed)

let uninstall_self ~output_mode ~dry_run =
  let home = home_dir () in
  let bin = home // ".local" // "bin" in
  (match output_mode with
   | Human when not dry_run ->
       Printf.printf "WARNING: removing the running c2c binary at %s/c2c\n" bin
   | Human ->
       Printf.printf "Would remove the running c2c binary at %s/c2c\n" bin
   | Json -> ());
  let artifacts = recompute_self_artifacts () in
  let removed = List.filter_map (remove_artifact ~dry_run) artifacts in
  let any_removed = removed <> [] in
  if not dry_run && any_removed then
    remove_manifest_record "self" bin;
  (any_removed, removed)

(* -------------------------------------------------------------------------- *)
(* Summary output *)
(* -------------------------------------------------------------------------- *)

let report_removed ~output_mode ~dry_run ~component paths =
  match output_mode with
  | Json ->
      let removed = List.map (fun p -> `String p) paths in
      C2c_setup.print_json
        (`Assoc
           [ ("ok", `Bool true)
           ; ("component", `String component)
           ; ("dry_run", `Bool dry_run)
           ; ("removed", `List removed)
           ])
  | Human ->
      let prefix = if dry_run then "Would remove" else "Removed" in
      if paths = [] then
        Printf.printf "nothing to remove for %s\n" component
      else begin
        Printf.printf "%s c2c for %s:\n" prefix component;
        List.iter (fun p -> Printf.printf "  - %s\n" p) paths
      end

(* -------------------------------------------------------------------------- *)
(* Entry point *)
(* -------------------------------------------------------------------------- *)

let run_uninstall ~output_mode ~dry_run ~component ~target_dir_opt ~alias_opt =
  let component = String.lowercase_ascii component in
  if not (List.mem component known_components) then begin
    let msg = Printf.sprintf "unknown component '%s'. Use: %s" component (String.concat ", " known_components) in
    (match output_mode with
     | Json -> C2c_setup.print_json (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])
     | Human -> Printf.eprintf "error: %s\n%!" msg);
    exit 124
  end;
  if component = "all" then begin
    let components = [ "claude"; "codex"; "kimi"; "opencode"; "grok"; "agy"; "crush"; "git-shim"; "git-hook" ] in
    let target_dir = resolve_target_dir target_dir_opt in
    let all_removed = ref [] in
    List.iter
      (fun c ->
         let _, removed = uninstall_component ~output_mode ~dry_run ~component:c ~target_dir ~alias:alias_opt in
         all_removed := !all_removed @ removed)
      components;
    let _, self_removed = uninstall_self ~output_mode ~dry_run in
    all_removed := !all_removed @ self_removed;
    report_removed ~output_mode ~dry_run ~component:"all" !all_removed
  end else if component = "self" then begin
    let _, removed = uninstall_self ~output_mode ~dry_run in
    report_removed ~output_mode ~dry_run ~component:"self" removed
  end else begin
    let target_dir =
      if component = "opencode" || component = "claude" then resolve_target_dir target_dir_opt
      else if component = "git-hook" then
        (match Git_helpers.git_common_dir () with
         | Some d -> d
         | None ->
             let t = resolve_target_dir target_dir_opt in
             t // ".git")
      else resolve_target_dir None
    in
    let _, removed = uninstall_component ~output_mode ~dry_run ~component ~target_dir ~alias:alias_opt in
    report_removed ~output_mode ~dry_run ~component removed
  end

(* -------------------------------------------------------------------------- *)
(* Cmdliner wiring *)
(* -------------------------------------------------------------------------- *)

let uninstall_subcmd =
  let dry_run =
    Cmdliner.Arg.(value & flag & info [ "dry-run"; "n" ] ~doc:"Show what would be removed without removing anything.")
  in
  let target_dir =
    Cmdliner.Arg.(value & opt (some string) None & info [ "target-dir"; "t" ] ~docv:"DIR" ~doc:"Target directory for opencode/claude project config (default: cwd).")
  in
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS" ~doc:"Alias used to locate the wake schedule when not in the manifest.")
  in
  let component =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"COMPONENT" ~doc:("Component to uninstall: " ^ String.concat " " known_components))
  in
  let term =
    let+ json = C2c_setup.json_flag
    and+ dry_run = dry_run
    and+ target_dir_opt = target_dir
    and+ alias_opt = alias
    and+ component = component in
    let output_mode = if json then Json else Human in
    run_uninstall ~output_mode ~dry_run ~component ~target_dir_opt ~alias_opt
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "uninstall"
       ~doc:"Remove c2c install artifacts for a component (manifest-driven with recompute fallback).")
    term
