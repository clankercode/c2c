(* c2c_agent.ml — agent/role management CLI commands.
    Extracted from c2c.ml (#152 Phase 4). *)

open Cmdliner.Term.Syntax

let ( // ) = Filename.concat

(* --- shared helpers ------------------------------------------------------- *)

let is_interactive_stdin () =
  Unix.isatty Unix.stdin

let rec prompt_nonempty ~prompt () =
  print_string prompt;
  flush stdout;
  let line = input_line stdin in
  let trimmed = String.trim line in
  if trimmed = "" then prompt_nonempty ~prompt ()
  else trimmed

let rec prompt_choice ?(default=0) ~prompt ~options () =
  print_string prompt;
  flush stdout;
  let line = String.trim (input_line stdin) in
  if line = "" then List.nth options default
  else
    match int_of_string_opt line with
    | None -> print_endline "Invalid number. Try again."; prompt_choice ~default ~prompt ~options ()
    | Some n ->
        if n < 0 || n >= List.length options then (
          print_endline "Out of range. Try again."; prompt_choice ~default ~prompt ~options ()
        ) else List.nth options n

let rec prompt_multi_select ~prompt ~items () =
  print_string prompt;
  flush stdout;
  let line = String.trim (input_line stdin) in
  if line = "" then [] else
    let nums =
      if String.index_opt line ',' = None && String.for_all (fun c -> c >= '0' && c <= '9') line then
        let rec expl i = if i >= String.length line then [] else line.[i] :: expl (i+1) in expl 0 |> List.filter_map (fun c -> int_of_string_opt (String.make 1 c))
      else
        List.filter_map int_of_string_opt (String.split_on_char ',' line)
    in
    match nums with
    | [] ->
        print_endline "Invalid selection (no valid numbers entered). Try again.";
        prompt_multi_select ~prompt ~items ()
    | _ ->
        List.filter_map (fun n -> if n >= 0 && n < List.length items then Some (List.nth items n) else None) nums

(* --- agent list ---------------------------------------------------------- *)

let agent_list_term =
  let+ () = Cmdliner.Term.const () in
  let roles_dir = C2c_role.canonical_roles_dir () in
  C2c_utils.mkdir_p roles_dir;
  match Array.to_list (Sys.readdir roles_dir) |> List.filter (fun f -> String.ends_with ~suffix:".md" f) with
  | [] -> Printf.printf "  (no roles found)\n"
  | files ->
      List.sort String.compare files
      |> List.iter (fun f ->
        let name = String.sub f 0 (String.length f - 3) in
        let path = Filename.concat roles_dir f in
        let size = (Unix.stat path).Unix.st_size in
        Printf.printf "  %s  (%d bytes)\n" name size)

(* --- agent delete --------------------------------------------------------- *)

let agent_delete_term =
  let name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME"
      ~doc:"Role name to delete.")
  in
  let force =
    Cmdliner.Arg.(value & flag & info [ "force"; "f" ]
      ~doc:"Skip confirmation prompt.")
  in
  let+ name = name
  and+ force = force in
  let roles_dir = C2c_role.canonical_roles_dir () in
  let path = Filename.concat roles_dir (name ^ ".md") in
  if not (Sys.file_exists path) then begin
    Printf.eprintf "error: role not found: %s\n%!" path;
    exit 1
  end;
  if not force then begin
    Printf.printf "Delete role '%s'? [y/N] " name;
    flush stdout;
    match input_line stdin with
    | "y" | "Y" -> ()
    | _ -> Printf.printf "aborted.\n"; exit 0
  end;
  Unix.unlink path;
  Printf.printf "deleted: %s\n" path

(* --- agent rename --------------------------------------------------------- *)

let agent_rename_term =
  let old_name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"OLD"
      ~doc:"Current role name.")
  in
  let new_name =
    Cmdliner.Arg.(required & pos 1 (some string) None & info [] ~docv:"NEW"
      ~doc:"New role name.")
  in
  let+ old_name = old_name
  and+ new_name = new_name in
  let roles_dir = C2c_role.canonical_roles_dir () in
  let old_path = Filename.concat roles_dir (old_name ^ ".md") in
  let new_path = Filename.concat roles_dir (new_name ^ ".md") in
  if not (Sys.file_exists old_path) then begin
    Printf.eprintf "error: role not found: %s\n%!" old_path;
    exit 1
  end;
  if Sys.file_exists new_path then begin
    Printf.eprintf "error: role already exists: %s\n%!" new_path;
    exit 1
  end;
  Unix.rename old_path new_path;
  Printf.printf "renamed: %s -> %s\n" old_name new_name

(* --- agent new (interactive helpers) -------------------------------------- *)

let agent_new_interactive ?(client="opencode") name =
  print_newline ();
  print_endline "=== c2c agent new — interactive mode ===";
  print_endline "Press Enter to accept defaults in brackets.\n";
  let description = prompt_nonempty ~prompt:"Description: " () in
  print_newline ();
  print_endline "Role type:";
  print_endline "  [0] subagent  (helper agent, not a primary peer)";
  print_endline "  [1] primary   (full peer — coordinator, CEO, etc.)  ← default for opencode";
  print_endline "  [2] all";
  let role_default = if client = "opencode" then 1 else 0 in
  let role = prompt_choice ~default:role_default ~prompt:(Printf.sprintf "Role type [%d]: " role_default) ~options:["subagent";"primary";"all"] () in
  print_newline ();
  print_endline "Compatible clients (comma-separated numbers, e.g. 0,2,3):";
  print_endline "  [0] all  (default — works on any client)";
  print_endline "  [1] claude";
  print_endline "  [2] opencode";
  print_endline "  [3] codex";
  print_endline "  [4] kimi";
  let client_items = ["all";"claude";"opencode";"codex";"kimi"] in
  let selected = prompt_multi_select ~prompt:"Clients [0]: " ~items:client_items () in
  let compatible_clients = if selected = [] || selected = ["all"] then ["all"] else selected in
  print_newline ();
  print_endline "Available themes:";
  let theme_options = [
    "exp33-gilded"; "exp33-black"; "exp33-chroma";
    "ffx-yuna"; "ffx-rikku"; "ffx-bevelle"; "ffx-zanarkand";
    "lotr-forge";
    "er-ranni"; "er-nightreign"; "er-melina";
    "default";
  ] in
  List.iteri (fun i t -> Printf.printf "  [%d] %s\n" i t) theme_options;
  print_endline "  [12] skip (no theme)";
  let selected = prompt_choice ~default:12 ~prompt:"Theme [12]: " ~options:(theme_options @ ["skip"]) () in
  let theme = if selected = "skip" then None else Some selected in
  print_newline ();
  print_endline "Available snippets (comma-separated numbers, or Enter to skip):";
  let snippet_dir = Filename.concat (Sys.getcwd ()) ".c2c" // "snippets" in
  let snippets =
    if Sys.file_exists snippet_dir then
      Array.to_list (Sys.readdir snippet_dir)
      |> List.filter (fun f -> Filename.check_suffix f ".md")
    else []
  in
  let selected_snippets =
    if snippets = [] then begin
      print_endline "  (no snippets found)";
      []
    end else begin
      List.iteri (fun i s -> Printf.printf "  [%d] %s\n" i s) snippets;
      print_string "Snippets [Enter to skip]: ";
      flush stdout;
      let line = String.trim (input_line stdin) in
      if line = "" then []
      else begin
        let nums = List.filter_map int_of_string_opt (String.split_on_char ',' line) in
        let names =
          List.filter_map
            (fun n ->
              if n >= 0 && n < List.length snippets then
                Some (Filename.remove_extension (List.nth snippets n))
              else None)
            nums
        in
        if names <> [] then begin
          print_endline "Included snippets:";
          List.iter (fun s -> print_endline ("  - " ^ s)) names
        end;
        names
      end
    end
  in
  print_newline ();
  let auto_join_rooms = if role = "primary" then "swarm-lounge" else "" in
  let rooms_input = prompt_choice ~prompt:("Auto-join rooms [" ^ (if auto_join_rooms <> "" then auto_join_rooms else "none") ^ "]: ") ~options:[auto_join_rooms;""] () in
  let auto_join_rooms = if rooms_input = "" then auto_join_rooms else rooms_input in
  print_newline ();
  (description, role, compatible_clients, theme, auto_join_rooms, selected_snippets)

(* --- agent new ---------------------------------------------------------- *)

let agent_new_term =
  let name_pos =
    Cmdliner.Arg.(value & pos 0 (some string) None & info [] ~docv:"NAME"
      ~doc:"Role name (creates .c2c/roles/<NAME>.md). Use instead of --name.")
  in
  let name =
    Cmdliner.Arg.(value & opt (some string) None & info [ "name" ] ~docv:"NAME"
      ~doc:"Role name (creates .c2c/roles/<NAME>.md). Use instead of the positional argument.")
  in
  let description =
    Cmdliner.Arg.(value & opt (some string) None & info [ "description"; "d" ]
      ~docv:"TEXT" ~doc:"Role description (required in interactive mode).")
  in
  let role_type =
    Cmdliner.Arg.(value & opt (some string) None & info [ "role"; "r" ]
      ~docv:"TYPE" ~doc:"Role type: subagent, primary, or all.")
  in
  let theme =
    Cmdliner.Arg.(value & opt (some string) None & info [ "theme"; "t" ]
      ~docv:"THEME" ~doc:"Banner theme (exp33-gilded, ffx-yuna, lotr-forge, etc.).")
  in
  let+ name_pos = name_pos
  and+ name = name
  and+ description = description
  and+ role_type = role_type
  and+ theme = theme in
  let name =
    match name, name_pos with
    | Some n, Some p ->
        Printf.eprintf "error: give either a positional NAME or --name, not both\n%!";
        exit 1
    | Some n, None -> n
    | None, Some p -> p
    | None, None ->
        if is_interactive_stdin () then
          prompt_nonempty ~prompt:"Role name: " ()
        else begin
          Printf.eprintf "error: NAME is required (pass as positional arg, use --name, or run with no arguments for interactive mode)\n%!";
          exit 1
        end
  in
  let any_flag_passed = description <> None || role_type <> None || theme <> None in
  let interactive = not any_flag_passed && is_interactive_stdin () in
  let (description, role, compatible_clients, theme, auto_join_rooms, selected_snippets) =
    if not interactive then
      ( Option.value description ~default:"TODO: describe this agent's purpose",
        Option.value role_type ~default:"subagent",
        ["all"],
        theme,
        "",
        [] )
    else
      agent_new_interactive name
  in
  let roles_dir = C2c_role.canonical_roles_dir () in
  C2c_utils.mkdir_p roles_dir;
  let path = Filename.concat roles_dir (name ^ ".md") in
  if Sys.file_exists path then begin
    Printf.eprintf "error: role already exists: %s\n%!" path;
    exit 1
  end;
  let auto_join_yaml =
    if auto_join_rooms <> "" then "  auto_join_rooms: [" ^ auto_join_rooms ^ "]\n" else ""
  in
  let theme_yaml =
    match theme with Some t -> "  theme: " ^ t ^ "\n" | None -> ""
  in
  let include_yaml =
    if selected_snippets = [] then "include: []\n"
    else "include: [" ^ String.concat ", " selected_snippets ^ "]\n"
  in
  let tmpl = Printf.sprintf
    "---\n\
     description: %s\n\
     role: %s\n\
     compatible_clients: [%s]\n\
     %s\
     required_capabilities: []\n\
     c2c:\n\
     %s\
     opencode:\n\
     %s\
     ---\n\
     You are a %s agent.\n\
     Your responsibilities:\n\
     - TODO: list primary responsibilities\n\
     - TODO: add more as needed\n"
    description
    role
    (String.concat ", " compatible_clients)
    include_yaml
    auto_join_yaml
    theme_yaml
    name
  in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc tmpl);
  Banner.print_banner ?theme_name:theme ~subtitle:("agent new  |  " ^ name) "c2c agent";
  Printf.printf "  created: %s\n" path;
  if interactive then begin
    Printf.printf "  path: %s\n" path;
    let editor =
      match Sys.getenv_opt "VISUAL" with
      | Some v when String.trim v <> "" -> Some v
      | _ ->
        match Sys.getenv_opt "EDITOR" with
        | Some v when String.trim v <> "" -> Some v
        | _ ->
          if Sys.command "command -v nano >/dev/null 2>&1" = 0 then Some "nano"
          else if Sys.command "command -v vi >/dev/null 2>&1" = 0 then Some "vi"
          else None
    in
    let editor_label = match editor with
      | Some e -> e
      | None -> "(none found — open the path above in a GUI editor)"
    in
    print_newline ();
    let open_it = prompt_choice
        ~default:0
        ~prompt:(Printf.sprintf "Open in %s now? [0=yes, 1=skip]: " editor_label)
        ~options:["yes"; "skip"] () in
    if open_it = "yes" then begin
      match editor with
      | Some ed ->
        let rc = Sys.command (Printf.sprintf "%s %s" ed (Filename.quote path)) in
        if rc <> 0 then
          Printf.eprintf "note: editor exited with code %d\n%!" rc
      | None ->
        Printf.printf "  no editor found. Open %s in a GUI editor.\n" path
    end;
    Printf.printf "\n  next: c2c agent refine %s  (hand off to role-designer)\n" name
  end

(* --- ephemeral mode type ------------------------------------------------- *)

type ephemeral_mode =
  | Pane
  | Background
  | Headless

(* --- shared ephemeral-agent runner --------------------------------------- *)

let run_ephemeral_agent
    ~(role : string)
    ~(prompt_opt : string option)
    ~(name_opt : string option)
    ~(client_opt : string option)
    ~(bin_opt : string option)
    ~(timeout : float)
    ~(dry_run : bool)
    ~(mode : ephemeral_mode)
    ~(reply_to_opt : string option)
    ~(auto_join_rooms_opt : string option)
    () =
  let role_path = C2c_role.canonical_roles_dir () // (role ^ ".md") in
  if not (Sys.file_exists role_path) then begin
    Printf.eprintf "error: role file not found: %s\n  create it first with: c2c agent new %s\n%!" role_path role;
    exit 1
  end;
  let r =
    try C2c_role.parse_file role_path
    with Sys_error e ->
      Printf.eprintf "error: failed to read role file %s: %s\n%!" role_path e;
      exit 1
  in
  let config_read () : (string * string) list =
    let path = Filename.concat (Sys.getcwd ()) ".c2c/config.toml" in
    if not (Sys.file_exists path) then []
    else
      let ic = open_in path in
      Fun.protect ~finally:(fun () -> close_in_noerr ic) @@ fun () ->
        let rec loop acc =
          match try Some (input_line ic) with End_of_file -> None with
          | None -> List.rev acc
          | Some line ->
              let trimmed = String.trim line in
              if trimmed = "" || String.length trimmed > 0 && trimmed.[0] = '#' then loop acc
              else match String.index_opt trimmed '=' with
                | None -> loop acc
                | Some i ->
                    let k = String.trim (String.sub trimmed 0 i) in
                    let v_raw = String.trim (String.sub trimmed (i+1) (String.length trimmed - i - 1)) in
                    let v =
                      let n = String.length v_raw in
                      if n >= 2 && v_raw.[0] = '"' && v_raw.[n-1] = '"' then String.sub v_raw 1 (n-2)
                      else v_raw
                    in
                    loop ((k, v) :: acc)
        in
        loop []
  in
  let client = match client_opt with
    | Some c -> c
    | None ->
      (match r.C2c_role.compatible_clients with
       | c :: _ -> c
       | [] ->
         (match List.assoc_opt "generation_client" (config_read ()) with
          | Some c -> c
          | None ->
            Printf.eprintf "error: role '%s' has no compatible_clients and generation_client is not set.\n  pass --client, or set: c2c config generation-client <client>\n%!" role;
            exit 1))
  in
  if r.C2c_role.compatible_clients <> [] && not (List.mem client r.C2c_role.compatible_clients) then begin
    Printf.eprintf "error: role '%s' is not compatible with client '%s' (compatible: %s)\n%!"
      role client (String.concat ", " r.C2c_role.compatible_clients);
    exit 1
  end;
  let name = match name_opt with
    | Some n -> n
    | None -> Printf.sprintf "eph-%s-%s" role (C2c_start.generate_alias ())
  in
  let caller =
    match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
    | Some a when a <> "" -> a
    | _ -> "(human operator)"
  in
  let caller_is_alias = caller <> "(human operator)" in
  let rendered =
    match C2c_commands.render_role_for_client r ~client ~name with
    | Some s -> s
    | None ->
      Printf.eprintf "error: role rendering not supported for client '%s'\n%!" client;
      exit 1
  in
  let user_prompt_section = match prompt_opt with
    | Some p when p <> "" -> Printf.sprintf "\n## Caller prompt\n\n%s\n" p
    | _ -> ""
  in
  let reply_to_line = match reply_to_opt with
    | Some r -> Printf.sprintf "Send completion results to: %s (via `c2c send %s \"<result>\"`).\n" r r
    | None -> ""
  in
  let confirm_line =
    if caller_is_alias then
      Printf.sprintf "1. Confirm completion with the caller (`c2c send %s \"done: <short summary>\"`).\n" caller
    else
      "1. Leave a summary for the human operator in this pane (stdout). The operator will decide when you are done.\n"
  in
  let idle_line =
    if timeout > 0.0 then
      Printf.sprintf
        "## Idle timeout\n\n\
         A supervisor watchdog will SIGTERM this session after %.0f seconds of no broker activity (inbox or archive mtime). If you expect to pause for longer than that, send a keepalive (e.g. poll_inbox, or a short swarm-lounge note) to reset the clock.\n\n"
        timeout
    else
      ""
  in
  let kickoff =
    Printf.sprintf
      "# Ephemeral c2c agent (role: %s)\n\n\
       You are a short-lived, purpose-built c2c peer. Your alias is `%s`. Your caller is `%s`.\n\
       ## Lifecycle\n\n\
       %s\
       When your task is complete:\n\
       %s\
       2. After the caller acknowledges (or you have left a summary for a human), call the `stop_self` MCP tool (c2c server) to terminate cleanly.\n\
       If you are unsure whether you are done, ASK the caller rather than stop_self-ing prematurely.\n\
       %s\
       %s\
       ## Role briefing\n\n\
       %s\n"
      role name caller reply_to_line confirm_line user_prompt_section idle_line rendered
  in
  let auto_join =
    match auto_join_rooms_opt with
    | Some rooms -> Some rooms
    | None -> None
  in
  if dry_run then begin
    let mode_str = match mode with Pane -> "pane" | Background -> "background" | Headless -> "headless" in
    let reply_to_str = match reply_to_opt with Some r -> r | None -> "(none)" in
    Printf.printf "c2c agent run [dry-run]:\n  role=%s\n  client=%s\n  name=%s\n  caller=%s\n  timeout=%.0fs\n  bin=%s\n  mode=%s\n  reply_to=%s\n  auto_join=%s\n\n--- kickoff prompt ---\n%s--- end prompt ---\n%!"
      role client name caller timeout
      (match bin_opt with Some b -> b | None -> "(default)")
      mode_str
      reply_to_str
      (match auto_join with Some r -> r | None -> "(none)")
      kickoff;
    exit 0
  end;
  C2c_commands.write_agent_file ~client ~name ~content:rendered;
  let mode_str = match mode with Pane -> "pane" | Background -> "background" | Headless -> "headless" in
  Printf.printf "c2c agent run: role=%s client=%s name=%s caller=%s timeout=%.0fs mode=%s\n%!"
    role client name caller timeout mode_str;
  let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
  let kickoff_dir = Filename.concat home ".local/share/c2c/kickoff" in
  (try Unix.mkdir kickoff_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> () | _ -> ());
  let kickoff_path = Filename.concat kickoff_dir (name ^ ".md") in
  let oc = open_out kickoff_path in
  output_string oc kickoff;
  close_out oc;

  let start_watchdog () =
    if timeout > 0.0 then begin
      match Unix.fork () with
      | 0 ->
        (try ignore (Unix.setsid ()) with _ -> ());
        let broker_root = C2c_start.broker_root () in
        let outer_pid_path = C2c_start.outer_pid_path name in
        let inbox_path = Filename.concat broker_root (name ^ ".inbox.json") in
        let archive_path = Filename.concat (Filename.concat broker_root "archive") (name ^ ".jsonl") in
        let mtime_opt p = try Some (Unix.stat p).st_mtime with _ -> None in
        let max_mtime () =
          let candidates = [mtime_opt inbox_path; mtime_opt archive_path] in
          List.fold_left (fun acc -> function Some m -> max acc m | None -> acc) 0.0 candidates
        in
        let start_time = Unix.gettimeofday () in
        let tick = min 30.0 (max 5.0 (timeout /. 4.0)) in
        let boot_grace_deadline = start_time +. 60.0 in
        let rec loop () =
          Unix.sleepf tick;
          match C2c_start.read_pid outer_pid_path with
          | None ->
              if Unix.gettimeofday () < boot_grace_deadline then loop ()
              else exit 0
          | Some pid when not (C2c_start.pid_alive pid) -> exit 0
          | Some pid ->
              let last = max_mtime () in
              let effective = if last > 0.0 then last else start_time in
              if Unix.gettimeofday () -. effective > timeout then begin
                Printf.eprintf "[c2c agent run] idle timeout %.0fs reached; SIGTERM pid %d (name=%s)\n%!"
                  timeout pid name;
                (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
                exit 0
              end else loop ()
        in
        loop ()
      | pid -> pid
    end else 0
  in

  let c2c_bin = match bin_opt with Some b -> b | None -> "c2c" in
  let q = Filename.quote in

  let env_for_start = match auto_join_rooms_opt with
    | Some rooms -> Printf.sprintf "env -u C2C_MCP_SESSION_ID -u C2C_MCP_AUTO_REGISTER_ALIAS -u C2C_INSTANCE_NAME -u C2C_WRAPPER_SELF C2C_MCP_AUTO_JOIN_ROOMS=%s" rooms
    | None -> "env -u C2C_MCP_SESSION_ID -u C2C_MCP_AUTO_REGISTER_ALIAS -u C2C_INSTANCE_NAME -u C2C_WRAPPER_SELF -u C2C_MCP_AUTO_JOIN_ROOMS"
  in

  let start_cmd_args = Printf.sprintf "%s start %s -n %s --kickoff-prompt-file %s"
    (q c2c_bin) (q client) (q name) (q kickoff_path)
  in

  match mode with
  | Pane ->
      (match Sys.getenv_opt "TMUX" with
       | Some s when s <> "" -> ()
       | _ ->
         Printf.eprintf "error: --mode pane requires running inside tmux (TMUX env var is not set)\n%!";
         exit 1);
      let window_title = Printf.sprintf "c2c-%s" name in
      let shell_cmd = Printf.sprintf "%s %s" env_for_start start_cmd_args in
      (match Unix.fork () with
       | 0 ->
         (try Unix.execvp "tmux" [| "tmux"; "new-window"; "-n"; window_title; shell_cmd |] with
          | Unix.Unix_error (e, _, _) ->
            Printf.eprintf "error: tmux new-window failed: %s\n%!" (Unix.error_message e);
            exit 1)
       | child ->
         (match snd (Unix.waitpid [] child) with
          | Unix.WEXITED 0 ->
            let wp = start_watchdog () in
            Printf.printf "launched tmux window '%s' (kickoff=%s)\n%!" window_title kickoff_path;
            (try Unix.kill wp Sys.sigterm with _ -> ());
            exit 0
          | _ ->
            Printf.eprintf "error: tmux new-window returned non-zero\n%!";
            exit 1))

  | Background ->
      let full_cmd = Printf.sprintf "%s %s &" env_for_start start_cmd_args in
      Printf.printf "spawning background ephemeral '%s' (kickoff=%s)\n%!" name kickoff_path;
      (match Unix.fork () with
       | 0 ->
         (try ignore (Unix.setsid ()) with _ -> ());
         (try
            let devnull = Unix.openfile "/dev/null" [Unix.O_RDWR] 0 in
            Unix.dup2 devnull Unix.stdin;
            Unix.dup2 devnull Unix.stdout;
            Unix.dup2 devnull Unix.stderr;
            Unix.close devnull
          with _ -> ());
         let wp = start_watchdog () in
         ignore (Sys.command full_cmd);
         (try Unix.kill wp Sys.sigterm with _ -> ());
         exit 0
       | _ -> exit 0)

  | Headless ->
      let headless_client = if client = "claude" || client = "opencode" then "codex-headless" else client in
      let start_cmd_args = Printf.sprintf "%s start %s -n %s --kickoff-prompt-file %s"
        (q c2c_bin) (q headless_client) (q name) (q kickoff_path)
      in
      let full_cmd = Printf.sprintf "%s %s &" env_for_start start_cmd_args in
      Printf.printf "spawning headless ephemeral '%s' (kickoff=%s)\n%!" name kickoff_path;
      (match Unix.fork () with
       | 0 ->
         (try ignore (Unix.setsid ()) with _ -> ());
         (try
            let devnull = Unix.openfile "/dev/null" [Unix.O_RDWR] 0 in
            Unix.dup2 devnull Unix.stdin;
            Unix.dup2 devnull Unix.stdout;
            Unix.dup2 devnull Unix.stderr;
            Unix.close devnull
          with _ -> ());
         let wp = start_watchdog () in
         ignore (Sys.command full_cmd);
         (try Unix.kill wp Sys.sigterm with _ -> ());
         exit 0
       | _ -> exit 0)

(* --- agent refine -------------------------------------------------------- *)

let agent_refine_term =
  let name_arg =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME"
      ~doc:"Role name — reads .c2c/roles/<NAME>.md and refines it via a role-designer ephemeral.")
  in
  let client_arg =
    Cmdliner.Arg.(value & opt (some string) None & info [ "client"; "c" ] ~docv:"CLIENT"
      ~doc:"Client to launch (claude|opencode|codex|kimi). Default: first entry of role-designer.compatible_clients, else generation_client from config.")
  in
  let bin_arg =
    Cmdliner.Arg.(value & opt (some string) None & info [ "bin" ] ~docv:"PATH"
      ~doc:"Custom binary path or name (e.g. cc-mm).")
  in
  let timeout_arg =
    Cmdliner.Arg.(value & opt float 1800.0 & info [ "timeout"; "t" ] ~docv:"SECONDS"
      ~doc:"Idle timeout — SIGTERM if no broker activity for this many seconds. 0 disables. Default 1800 (30min).")
  in
  let dry_run_arg =
    Cmdliner.Arg.(value & flag & info [ "dry-run" ]
      ~doc:"Print resolved config + kickoff prompt without invoking c2c start.")
  in
  let reply_to_arg =
    Cmdliner.Arg.(value & opt (some string) None & info [ "reply-to" ]
      ~docv:"ALIAS" ~doc:"Alias to DM completion results to (default: caller alias from C2C_MCP_AUTO_REGISTER_ALIAS).")
  in
  let agent_mode_arg =
    Cmdliner.Arg.(value & flag & info [ "agent-mode" ]
      ~doc:"Peer-invocation mode: DM the caller (from C2C_MCP_REPLY_TO, or coordinator1 fallback) for clarification instead of interviewing in this pane. Implies structured output + stop_self on completion.")
  in
  let+ name = name_arg
  and+ client_opt = client_arg
  and+ bin_opt = bin_arg
  and+ timeout = timeout_arg
  and+ dry_run = dry_run_arg
  and+ reply_to_opt = reply_to_arg
  and+ agent_mode = agent_mode_arg in
  let roles_dir = C2c_role.canonical_roles_dir () in
  let role_file_path = Filename.concat roles_dir (name ^ ".md") in
  if not (Sys.file_exists role_file_path) then begin
    Printf.eprintf "error: role file not found: %s\n  create it first with: c2c agent new %s\n%!" role_file_path name;
    exit 1
  end;
  let read_all path =
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) @@ fun () ->
      let n = in_channel_length ic in
      let buf = Bytes.create n in
      really_input ic buf 0 n;
      Bytes.to_string buf
  in
  let draft_body = read_all role_file_path in
  let refine_prompt =
    if agent_mode then
      let reply_to =
        match Sys.getenv_opt "C2C_MCP_REPLY_TO" with
        | Some alias when String.trim alias <> "" -> alias
        | _ ->
          (Printf.eprintf "[c2c agent refine --agent-mode] warning: C2C_MCP_REPLY_TO is not set. DMing coordinator1 as fallback.\n%!";
           "coordinator1")
      in
      Printf.sprintf
        "We are refining a role named `%s`. The role file is at:\n\n    %s\n\nHere is the current draft:\n\n---\n%s\n---\n\nYou are being called by peer `%s`. Refine the role file IN PLACE at the path above using your Edit tool. Use `send` to DM `%s` for any clarification needed. When the role is finalized, call `stop_self` to terminate cleanly.\n"
        name role_file_path draft_body reply_to reply_to
    else
      Printf.sprintf
        "We are refining a role named `%s`. The role file is at:\n\n    %s\n\nHere is the current draft:\n\n---\n%s\n---\n\nInterview the caller (or the human operator in this pane) about this agent, and refine the role file IN PLACE at the path above using your Edit tool. When the caller says \"done\" (or a human operator says they're done), save the final content and call `stop_self`.\n"
        name role_file_path draft_body
  in
  let instance_name =
    Printf.sprintf "eph-refine-%s-%s" name (C2c_start.generate_alias ())
  in
  let caller =
    match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
    | Some a when a <> "" -> Some a
    | _ -> None
  in
  let reply_to = match reply_to_opt with
    | Some r -> Some r
    | None -> caller
  in
  run_ephemeral_agent
    ~role:"role-designer"
    ~prompt_opt:(Some refine_prompt)
    ~name_opt:(Some instance_name)
    ~client_opt ~bin_opt ~timeout ~dry_run
    ~mode:Pane ~reply_to_opt:reply_to ~auto_join_rooms_opt:None
    ()

(* --- agent run ----------------------------------------------------------- *)

let agent_run_term =
  let role_arg =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROLE"
      ~doc:"Role name — reads .c2c/roles/<ROLE>.md and launches an ephemeral managed peer with that role.")
  in
  let prompt_arg =
    Cmdliner.Arg.(value & opt (some string) None & info [ "prompt"; "p" ] ~docv:"TEXT"
      ~doc:"Optional caller prompt folded into the kickoff template.")
  in
  let name_arg =
    Cmdliner.Arg.(value & opt (some string) None & info [ "name"; "n" ] ~docv:"NAME"
      ~doc:"Explicit instance/alias name. Default: eph-<role>-<word>-<word>.")
  in
  let client_arg =
    Cmdliner.Arg.(value & opt (some string) None & info [ "client"; "c" ] ~docv:"CLIENT"
      ~doc:"Client to launch (claude|opencode|codex|kimi). Default: first entry of role.compatible_clients, else generation_client from config.")
  in
  let bin_arg =
    Cmdliner.Arg.(value & opt (some string) None & info [ "bin" ] ~docv:"PATH"
      ~doc:"Custom binary path or name (e.g. cc-mm).")
  in
  let timeout_arg =
    Cmdliner.Arg.(value & opt float 1800.0 & info [ "timeout"; "t" ] ~docv:"SECONDS"
      ~doc:"Idle timeout — SIGTERM the instance if no broker activity for this many seconds. 0 disables. Default 1800 (30min).")
  in
  let dry_run_arg =
    Cmdliner.Arg.(value & flag & info [ "dry-run" ]
      ~doc:"Print resolved client, name, caller, kickoff prompt, and timeout without invoking c2c start.")
  in
  let mode_arg =
    let mode_conv =
      Cmdliner.Arg.enum [
        "pane", Pane;
        "background", Background;
        "headless", Headless;
      ]
    in
    Cmdliner.Arg.(value & opt (some mode_conv) (Some Pane) & info [ "mode" ]
      ~docv:"MODE" ~doc:"Terminal harness mode: pane (tmux window), background (detached daemon), or headless (codex-headless). Default: pane.")
  in
  let reply_to_arg =
    Cmdliner.Arg.(value & opt (some string) None & info [ "reply-to" ]
      ~docv:"ALIAS" ~doc:"Alias to DM completion results to (default: caller alias from C2C_MCP_AUTO_REGISTER_ALIAS).")
  in
  let auto_join_arg =
    Cmdliner.Arg.(value & opt (some string) None & info [ "auto-join" ]
      ~docv:"ROOMS" ~doc:"Comma-separated room IDs to auto-join on startup (default: none for ephemerals).")
  in
  let+ role = role_arg
  and+ prompt_opt = prompt_arg
  and+ name_opt = name_arg
  and+ client_opt = client_arg
  and+ bin_opt = bin_arg
  and+ timeout = timeout_arg
  and+ dry_run = dry_run_arg
  and+ mode_opt = mode_arg
  and+ reply_to_opt = reply_to_arg
  and+ auto_join_rooms_opt = auto_join_arg in
  let mode = Option.value mode_opt ~default:Pane in
  let caller =
    match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
    | Some a when a <> "" -> Some a
    | _ -> None
  in
  let reply_to = match reply_to_opt with
    | Some r -> Some r
    | None -> caller
  in
  run_ephemeral_agent
    ~role ~prompt_opt ~name_opt ~client_opt ~bin_opt ~timeout ~dry_run
    ~mode ~reply_to_opt:reply_to ~auto_join_rooms_opt:auto_join_rooms_opt
    ()

(* --- CLI command definitions --------------------------------------------- *)

let agent_new_cmd = Cmdliner.Cmd.v (Cmdliner.Cmd.info "new" ~doc:"Create a new canonical role file.") agent_new_term
let agent_list_cmd = Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List all canonical role files.") agent_list_term
let agent_delete_cmd = Cmdliner.Cmd.v (Cmdliner.Cmd.info "delete" ~doc:"Delete a canonical role file.") agent_delete_term
let agent_rename_cmd = Cmdliner.Cmd.v (Cmdliner.Cmd.info "rename" ~doc:"Rename a canonical role file.") agent_rename_term
let agent_refine_cmd = Cmdliner.Cmd.v (Cmdliner.Cmd.info "refine" ~doc:"Launch the configured generation_client to interactively refine an existing role file (Phase 2 of the agent wizard).") agent_refine_term
let agent_run_cmd = Cmdliner.Cmd.v (Cmdliner.Cmd.info "run" ~doc:"Launch a short-lived ephemeral managed peer from a role file.") agent_run_term

let agent_group =
  Cmdliner.Cmd.group ~default:agent_list_term
    (Cmdliner.Cmd.info "agent" ~doc:"Manage canonical role files.")
    [agent_new_cmd; agent_list_cmd; agent_delete_cmd; agent_rename_cmd; agent_refine_cmd; agent_run_cmd]

(* --- roles compile -------------------------------------------------------- *)

let roles_compile_term =
  let name_arg =
    Cmdliner.Arg.(value & pos 0 (some string) None & info [] ~docv:"NAME"
      ~doc:"Role name to compile (reads .c2c/roles/<NAME>.md). Omit to compile all roles.")
  in
  let client =
    Cmdliner.Arg.(value & opt (some string) (Some "all") & info [ "client"; "c" ]
      ~docv:"CLIENT" ~doc:"Target client for rendering (opencode, claude, codex, kimi, or 'all' for every supported client).")
  in
  let dry_run =
    Cmdliner.Arg.(value & flag & info [ "dry-run" ] ~doc:"Print output to stdout instead of writing files.")
  in
  let+ name_opt = name_arg
  and+ client = client
  and+ dry_run = dry_run in
  let roles_dir = C2c_role.canonical_roles_dir () in
  let roles =
    match name_opt with
    | Some n -> [(n, Filename.concat roles_dir (n ^ ".md"))]
    | None ->
        (try
          Array.to_list (Sys.readdir roles_dir)
          |> List.filter (fun f -> String.ends_with ~suffix:".md" f)
          |> List.map (fun f -> (String.sub f 0 (String.length f - 3), Filename.concat roles_dir f))
        with Sys_error _ ->
          Printf.eprintf "error: roles directory not found: %s\n%!" roles_dir;
          exit 1)
  in
  let n_roles = List.length roles in
  let subtitle = if n_roles = 1 then "1 role" else Printf.sprintf "%d roles" n_roles in
  Banner.print_banner ~subtitle:("roles compile  |  " ^ subtitle) "c2c roles";
  let client_str = Option.value client ~default:"opencode" in
  let targets =
    if client_str = "all" then ["opencode"; "claude"; "codex"; "kimi"]
    else [client_str]
  in
  List.iter (fun (name, path) ->
    try
      let role = C2c_role.parse_file path in
      List.iter (fun target ->
        match C2c_commands.render_role_for_client role ~client:target ~name with
        | Some rendered ->
            if dry_run then
              (Printf.printf "=== %s (%s) ===\n%s\n\n" name target rendered; flush stdout)
            else
               (let out_path = C2c_commands.agent_file_path ~client:target ~name in
                let dir = Filename.dirname out_path in
                C2c_utils.mkdir_p dir;
                let lock_path = out_path ^ ".lock" in
                let fd = Unix.openfile lock_path [Unix.O_RDWR; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
                Fun.protect ~finally:(fun () -> Unix.close fd)
                  (fun () ->
                    Unix.lockf fd Unix.F_LOCK 0;
                    Fun.protect ~finally:(fun () -> Unix.lockf fd Unix.F_ULOCK 0)
                      (fun () ->
                        let oc = open_out out_path in
                        Fun.protect ~finally:(fun () -> close_out oc)
                          (fun () -> output_string oc rendered; output_char oc '\n');
                        Printf.printf "  [roles compile] %s -> %s\n" path out_path)))
        | None ->
            Printf.eprintf "  [roles compile] skip %s: client '%s' not supported\n" name target
      ) targets
    with Sys_error msg ->
      Printf.eprintf "  [roles compile] skip %s: %s\n" name msg
  ) roles;
  if not dry_run then Printf.printf "[roles compile] done.\n%!"

let roles_compile_cmd = Cmdliner.Cmd.v
  (Cmdliner.Cmd.info "compile"
     ~doc:"Compile canonical role(s) to client agent files."
     ~man:[ `S "DESCRIPTION"
          ; `P "Canonical role files live in $(b,.c2c/roles/). Use $(b,c2c roles compile) to compile them to client-specific agent files (e.g. $(b,.opencode/agents/<name>.md))."
          ; `S "EXAMPLES"
           ; `P "$(b,c2c roles compile)  — compile all roles for all clients (opencode, claude, codex, kimi)"
           ; `P "$(b,c2c roles compile --client opencode)  — compile all roles for OpenCode only"
           ; `P "$(b,c2c roles compile my-role --client claude)  — compile one role for Claude"
           ; `P "$(b,c2c roles validate)  — check role files for completeness"
          ])
  roles_compile_term

(* --- roles validate ------------------------------------------------------ *)

let roles_validate_term =
  let+ () = Cmdliner.Term.const () in
  let roles_dir = C2c_role.canonical_roles_dir () in
  let roles =
    try
      Array.to_list (Sys.readdir roles_dir)
      |> List.filter (fun f -> String.ends_with ~suffix:".md" f)
      |> List.map (fun f -> (String.sub f 0 (String.length f - 3), Filename.concat roles_dir f))
    with Sys_error _ ->
      Printf.eprintf "error: roles directory not found: %s\n%!" roles_dir;
      exit 1
  in
  let n_ok = ref 0 in
  let n_warn = ref 0 in
  let n_err = ref 0 in
  List.iter (fun (name, path) ->
    try
      let role = C2c_role.parse_file path in
      let has_issues = ref false in
      if role.C2c_role.description = "" then
        (Printf.eprintf "  %s: missing description\n%!" name; has_issues := true);
      if role.C2c_role.role = "" || role.C2c_role.role = "subagent" then
        (Printf.eprintf "  %s: role is empty or default 'subagent'\n%!" name; has_issues := true);
      if role.C2c_role.body = "" then
        (Printf.eprintf "  %s: body is empty\n%!" name; has_issues := true);
      if !has_issues then incr n_warn
      else incr n_ok
    with Sys_error msg ->
      Printf.eprintf "  %s: error reading: %s\n%!" name msg;
      incr n_err
  ) roles;
  Printf.printf "[roles validate] %d ok, %d warnings, %d errors\n%!" !n_ok !n_warn !n_err;
  if !n_err > 0 then exit 1

let roles_validate_cmd = Cmdliner.Cmd.v (Cmdliner.Cmd.info "validate" ~doc:"Validate canonical role files for completeness.") roles_validate_term

(* --- roles default ------------------------------------------------------- *)

let roles_default_term =
  let+ () = Cmdliner.Term.const () in
  let roles_dir = C2c_role.canonical_roles_dir () in
  let roles =
    try
      Array.to_list (Sys.readdir roles_dir)
      |> List.filter (fun f -> String.ends_with ~suffix:".md" f)
      |> List.map (fun f -> (String.sub f 0 (String.length f - 3), Filename.concat roles_dir f))
    with Sys_error _ ->
      Printf.eprintf "error: roles directory not found: %s\n%!" roles_dir;
      exit 1
  in
  let n_roles = List.length roles in
  let subtitle = if n_roles = 1 then "1 role" else Printf.sprintf "%d roles" n_roles in
  Banner.print_banner ~subtitle:("roles compile  |  " ^ subtitle) "c2c roles";
  let all_targets = ["opencode"; "claude"; "codex"; "kimi"] in
  List.iter (fun (name, path) ->
    try
      let role = C2c_role.parse_file path in
      List.iter (fun target ->
        match C2c_commands.render_role_for_client role ~client:target ~name with
        | Some rendered ->
            let out_path = C2c_commands.agent_file_path ~client:target ~name in
            let dir = Filename.dirname out_path in
            C2c_utils.mkdir_p dir;
            let lock_path = out_path ^ ".lock" in
            let fd = Unix.openfile lock_path [Unix.O_RDWR; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
            Fun.protect ~finally:(fun () -> Unix.close fd)
              (fun () ->
                Unix.lockf fd Unix.F_LOCK 0;
                Fun.protect ~finally:(fun () -> Unix.lockf fd Unix.F_ULOCK 0)
                  (fun () ->
                    let oc = open_out out_path in
                    Fun.protect ~finally:(fun () -> close_out oc)
                      (fun () -> output_string oc rendered; output_char oc '\n');
                    Printf.printf "  [roles compile] %s -> %s\n" path out_path))
        | None ->
            Printf.eprintf "  [roles compile] skip %s: client '%s' not supported\n" name target
      ) all_targets
    with Sys_error msg ->
      Printf.eprintf "  [roles compile] skip %s: %s\n" name msg
  ) roles;
  Printf.printf "[roles compile] done.\n%!"

let roles_group =
  Cmdliner.Cmd.group ~default:roles_default_term
    (Cmdliner.Cmd.info "roles" ~doc:"Manage and compile canonical role files.")
    [roles_compile_cmd; roles_validate_cmd]