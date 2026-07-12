open C2c_cli_helpers
open Cmdliner.Term.Syntax
open C2c_mcp
open C2c_utils

(* `c2c help [COMMAND...]` is a plain-English alias for `c2c [COMMAND...] --help`.
   Re-exec ourselves with `--help` appended so we get Cmdliner's full rendering
   (man-page layout, pager, and the sanitize_help_env fix) without having to
   reach into Cmdliner internals. *)
let help_cmd =
  let args =
    Cmdliner.Arg.(
      value & pos_all string []
      & info [] ~docv:"COMMAND"
          ~doc:"Subcommand path to show help for. With no args, shows top-level help.")
  in
  let+ args = args in
  let self = if Array.length Sys.argv > 0 then Sys.argv.(0) else "c2c" in
  let new_argv = Array.of_list (self :: args @ [ "--help" ]) in
  (try Unix.execvp self new_argv
   with Unix.Unix_error (err, _, _) ->
     prerr_endline ("c2c help: " ^ Unix.error_message err);
     exit 125)

let help : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "help"
       ~doc:"Show help for c2c or a subcommand (alias for --help)."
       ~man:
         [ `S "DESCRIPTION"
         ; `P "Prints the same help as $(b,--help). With no arguments, shows the \
               top-level c2c help. Arguments are treated as a subcommand path, \
               so $(b,c2c help install) is equivalent to $(b,c2c install --help), \
               and $(b,c2c help rooms list) mirrors $(b,c2c rooms list --help)."
         ])
    help_cmd

(* Cmdliner renders help through groff/grotty, which emits ANSI SGR escapes,
   then pipes through $MANPAGER (or $PAGER, or `less`). A MANPAGER that runs
   the output through `col -b*` (e.g. "sh -c 'col -bx | bat -l man -p'") strips
   the ESC byte from every SGR sequence but leaves the payload, producing
   visible garbage like "[4mNAME[0m" in the rendered help. Detect that case
   and swap in a safe pager so `c2c <cmd> --help` stays readable regardless
   of the user's shell setup. *)
let sanitize_help_env () =
  let contains_substr haystack needle =
    let nl = String.length needle and hl = String.length haystack in
    nl <= hl
    && (let rec loop i =
          i <= hl - nl
          && (String.sub haystack i nl = needle || loop (i + 1))
        in
        loop 0)
  in
  let esc_stripping v =
    (* `col -b` / `col -bx` drop control chars (including ESC) from input. *)
    contains_substr v "col -b" || contains_substr v "col\t-b"
  in
  let fix var =
    match Sys.getenv_opt var with
    | Some v when esc_stripping v -> Unix.putenv var "less -R"
    | _ -> ()
  in
  fix "MANPAGER";
  fix "PAGER"

(* Enriched landing for bare `c2c` (no subcommand). Shows detection status
   and suggested next commands — doubles as a "where am I?" report. *)
let print_enriched_landing () =
  let version = version_string () in
  let (self, clients) = C2c_setup.detect_installation () in
  (* B048: pi is not in known_clients (not a `c2c install` target — pi agents
     use the npm:pi-c2c extension). Append a synthetic display entry so pi
     still appears in the landing Clients section. *)
  let pi_on_path = C2c_setup.which_binary "pi" <> None in
  let clients = clients @ [ ("pi", pi_on_path, false) ] in
  let self_path = C2c_setup.self_installed_path () in
  let broker_root = try resolve_broker_root () with _ -> "(unresolved)" in
  Printf.printf "c2c %s — peer-to-peer messaging for AI agents\n" version;
  let format_binary_status path build_rel_path =
    match path with
    | None -> "not installed"
    | Some p ->
        let p_mtime = try Some (Unix.stat p).Unix.st_mtime with _ -> None in
        let build_path =
          match git_repo_toplevel () with
          | Some root -> Some (root // build_rel_path)
          | None -> None
        in
        let build_mtime =
          match build_path with
          | Some bp when Sys.file_exists bp ->
              (try Some (Unix.stat bp).Unix.st_mtime with _ -> None)
          | _ -> None
        in
        (match p_mtime, build_mtime with
         | Some pt, Some bt when bt > pt +. 1.0 ->
             let age_min = int_of_float ((bt -. pt) /. 60.0) in
             Printf.sprintf "%s  (STALE — newer build %dm ahead; `cp %s %s`)"
               p age_min (Option.value ~default:"?" build_path) p
         | _ -> p)
  in
  Printf.printf "\n";
  Printf.printf "Status\n";
  Printf.printf "  c2c on PATH:      %s\n"
    (format_binary_status self_path "_build/default/ocaml/cli/c2c.exe");
  let mcp_server_path = C2c_setup.which_binary "c2c-mcp-server" in
  Printf.printf "  c2c-mcp-server:   %s\n"
    (format_binary_status mcp_server_path
       "_build/default/ocaml/server/c2c_mcp_server.exe");
  Printf.printf "  broker root:      %s\n" broker_root;
  let broker_live =
    try
      let broker = C2c_mcp.Broker.create ~root:broker_root in
      let regs = C2c_mcp.Broker.list_registrations broker in
      let alive =
        List.filter C2c_mcp.Broker.registration_is_alive regs |> List.length
      in
      Some (List.length regs, alive)
    with _ -> None
  in
  (match broker_live with
   | Some (total, alive) ->
       Printf.printf "  peers:            %d registered (%d alive)\n" total alive
   | None ->
       Printf.printf "  peers:            (broker not initialised — try `c2c init`)\n");
  (match C2c_health_cmd.check_pty_inject_capability () with
   | `Ok -> ()
   | `Unknown -> ()
   | `Missing_cap py ->
        Printf.printf
          "  pty-inject:       MISSING cap_sys_ptrace — Codex PTY notify daemon will fail\n";
        Printf.printf
          "                    fix: sudo setcap cap_sys_ptrace=ep %s\n" py;
        Printf.printf
          "                    (OpenCode + Kimi use non-PTY delivery — cap not required for them)\n");
  Printf.printf "\nClients\n";
  List.iter (fun (c, on_path, configured) ->
    let status =
      if c = "pi" then
        if on_path then "on PATH — uses npm:pi-c2c (see pi.dev)"
        else "not on PATH — see pi.dev"
      else
        match on_path, configured with
        | false, _ -> "not on PATH"
        | true, true -> "configured (c2c MCP ready)"
        | true, false -> "on PATH, not configured — run 'c2c install' to set up"
    in
    Printf.printf "  %-10s %s\n" c status
  ) clients;
  let missing_clients =
    List.filter_map (fun (c, on_path, configured) ->
      if c <> "pi" && on_path && not configured then Some c else None) clients
  in
  let suggestions =
    let buf = Buffer.create 256 in
    if not self then
      Buffer.add_string buf (Printf.sprintf "  c2c install %-16s install the c2c binary to ~/.local/bin\n" "self");
    List.iter (fun c ->
      Buffer.add_string buf (Printf.sprintf "  c2c install %-16s configure %s for c2c\n" c c)
    ) missing_clients;
    Buffer.contents buf
  in
  if suggestions <> "" then begin
    Printf.printf "\nSuggested next steps\n";
    print_string suggestions;
    Printf.printf "  c2c install %-16s interactive installer (TUI)\n" ""
  end else begin
    Printf.printf "\nEverything looks configured. Some useful commands:\n";
    Printf.printf "  %-28s list registered peers\n" "c2c list";
    Printf.printf "  %-28s send a message\n" "c2c send ALIAS MSG";
    Printf.printf "  %-28s read pending messages\n" "c2c poll-inbox";
    Printf.printf "  %-28s list rooms you're in\n" "c2c rooms list";
    Printf.printf "\n  If you just installed, restart your CLI client (or run /reload-plugins\n  in Claude Code) and resume — this activates push-based delivery.\n"
  end;
  Printf.printf "\nRun `c2c help` or `c2c --help` for the full command list.\n"

let default_term =
  let+ () = Cmdliner.Term.const () in
  print_enriched_landing ()

(* A few top-level commands are used as lightweight orientation/status probes:
   they are a natural place to surface a non-blocking update hint.  The hint is
   deliberately emitted to stderr, preserving stdout for --json consumers and
   shell pipelines.  Version availability comes from the changelog's local
   cache; a stale cache is refreshed in the background by that module. *)
let general_command_requested () =
  let argv = Sys.argv in
  let command = if Array.length argv > 1 then Some argv.(1) else None in
  match command with
  | None -> true
  | Some
      ( "whoami" | "list" | "find" | "sessions" | "status" | "health"
      | "ping" | "connect" | "doctor" | "changelog" | "help" | "commands"
      | "server-info" | "--help" | "-h" | "--version" ) ->
      true
  | Some _ -> false

let maybe_emit_update_notice () =
  if general_command_requested () then
    try
      match
        C2c_changelog.update_notice ~broker_root:(resolve_broker_root ())
          ~now:(Unix.gettimeofday ()) ()
      with
      | Some notice -> Printf.eprintf "%s\n%!" notice
      | None -> ()
    with _ -> ()

(* Fast-path dispatch (#418): handle a small set of subcommands BEFORE
   the heavy Cmdliner setup (~1.5s) that builds the manpage for ~50 cmds.
   These commands have no broker/registry dependency, so we short-circuit
   them with a direct argv scan + lean handler.

   Race fix (#418): get-tmux-location used to call `tmux display-message -p`
   without `-t "$TMUX_PANE"`, which returns the tmux *server's* active pane
   — racy under concurrent invocation across panes. Reading $TMUX_PANE
   directly (set per-pane by tmux at fork) is the canonical zero-cost
   pane-bound answer; we normalize via `tmux display-message -t "$TMUX_PANE"`
   only when callers want the human-readable session:window.pane form. *)
let fast_path_get_tmux_location ?(json = false) () =
  let pane_id = Sys.getenv_opt "TMUX_PANE" in
  let tmux_set = Sys.getenv_opt "TMUX" in
  match pane_id, tmux_set with
  | None, None ->
      (* Neither TMUX nor TMUX_PANE is set — definitely not in tmux. *)
      Printf.eprintf "error: not running inside a tmux session (TMUX is not set).\n%!";
      exit 1
  | Some _, None ->
      (* TMUX_PANE survived env -u TMUX (orphaned pane var from a dead session).
         TMUX is not set so tmux commands will fail. Treat as non-tmux. *)
      Printf.eprintf "error: not running inside a tmux session (TMUX is not set).\n%!";
      exit 1
  | _, Some _ ->
      (* TMUX is set — we are in a tmux session. Pin to our own pane. *)
      let cmd = match pane_id with
        | Some p when String.trim p <> "" ->
            (* shell-quote the pane id (tmux pane ids look like %42 — safe but be defensive) *)
            Printf.sprintf "tmux display-message -t %s -p '#S:#I.#P'"
              (Filename.quote p)
        | _ ->
            (* No $TMUX_PANE but $TMUX is set — last-resort active-pane fallback. *)
            "tmux display-message -p '#S:#I.#P'"
      in
      let capture cmd =
        try
          let ic = Unix.open_process_in cmd in
          Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
            (fun () -> Some (input_line ic))
        with _ -> None
      in
      (match capture cmd with
       | None ->
           Printf.eprintf "error: tmux display-message failed. Is tmux running?\n%!";
           exit 1
       | Some addr ->
           if json then Printf.printf "%s\n" (Printf.sprintf "%S" addr)
           else Printf.printf "%s\n" addr;
           exit 0)

let fast_path_help () =
  (* c2c help [subcommand-path...] → execvp self [self, args..., --help] *)
  let self = if Array.length Sys.argv > 0 then Sys.argv.(0) else "c2c" in
  (* Collect positional args only (skip subcommand name itself at argv.(1)) *)
  let args =
    let n = Array.length Sys.argv in
    let rec go i acc =
      if i >= n then List.rev acc
      else go (i + 1) (Sys.argv.(i) :: acc)
    in
    go 2 []  (* skip argv[0]="c2c" and argv[1]="help" *)
  in
  let new_argv = Array.of_list (self :: args @ [ "--help" ]) in
  try Unix.execvp self new_argv
  with Unix.Unix_error (err, _, _) ->
    prerr_endline ("c2c help: " ^ Unix.error_message err);
    exit 125

let fast_path_server_info ~json () =
  let info = C2c_mcp.server_info () in
  if json then
    print_json info
  else
    match info with
    | `Assoc fields ->
        List.iter (fun (k, v) ->
          match v with
          | `String s -> Printf.printf "%s: %s\n" k s
          | `List l -> Printf.printf "%s:\n" k; List.iter (fun item -> Printf.printf "  - %s\n" (Yojson.Safe.to_string item)) l
          | _ -> Printf.printf "%s: %s\n" k (Yojson.Safe.to_string v))
          fields
    | _ -> print_json info

let fast_path_completion () =
  let n = Array.length Sys.argv in
  let help_requested =
    let rec loop i =
      i < n
      && (Sys.argv.(i) = "--help"
          || Sys.argv.(i) = "-h"
          || (String.length Sys.argv.(i) > 7
              && String.sub Sys.argv.(i) 0 7 = "--help=")
          || Sys.argv.(i) = "--version"
          || loop (i + 1))
    in
    loop 2
  in
  if help_requested then ()
  else begin
    let shell = ref None in
    for i = 2 to n - 1 do
      if Sys.argv.(i) = "--shell" && i + 1 < n then
        shell := Some (String.lowercase_ascii (String.trim Sys.argv.(i + 1)))
      else if String.length Sys.argv.(i) >= 7 && String.sub Sys.argv.(i) 0 7 = "--shell=" then
        shell := Some (String.lowercase_ascii (String.sub Sys.argv.(i) 7 (String.length Sys.argv.(i) - 7)))
    done;
    let shell = !shell in
    let shell = match shell with
      | Some s -> Some s
      | None ->
          (try
            let sh = Sys.getenv "SHELL" in
            if Filename.check_suffix sh "bash" then Some "bash"
            else if Filename.check_suffix sh "zsh" then Some "zsh"
            else if Filename.check_suffix sh "pwsh" || Filename.check_suffix sh "powershell" then Some "pwsh"
            else None
          with Not_found -> None)
    in
    match shell with
    | Some s when List.mem s ["bash"; "zsh"; "pwsh"] ->
        let cmdliner_bin () =
          try
            let opam_prefix = Sys.getenv "OPAM_SWITCH_PREFIX" in
            Filename.concat opam_prefix "bin" // "cmdliner"
          with Not_found ->
            let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
            Filename.concat home ".opam/c2c/bin/cmdliner"
        in
        let cmd = Printf.sprintf "%s tool-completion --standalone-completion %s c2c"
          (cmdliner_bin ()) s
        in
        let ic = Unix.open_process_in cmd in
        let rec copy_all () =
          try print_endline (input_line ic); copy_all ()
          with End_of_file -> ()
        in
        copy_all ();
        (match Unix.close_process_in ic with
         | Unix.WEXITED 0 -> exit 0
         | Unix.WEXITED n ->
             Printf.eprintf "error: cmdliner exited with code %d\n%!" n;
             exit 1
         | _ ->
             Printf.eprintf "error: cmdliner terminated unexpectedly\n%!";
             exit 1)
    | Some s ->
        Printf.eprintf "error: unknown shell '%s'. Supported: bash, zsh, pwsh\n%!" s;
        exit 1
    | None ->
        Printf.eprintf "error: could not detect shell. Please specify --shell explicitly\n%!";
        exit 1
  end

let try_fast_path () =
  (* Skip fast-path if any flag we don't recognize appears, so cmdliner
     can produce its standard error. We only handle the trivial shape:
       c2c help [args...]
       c2c commands [--all]
       c2c server-info [--json]
       c2c completion [--shell SHELL]
       c2c skills list [--json]
       c2c skills serve <name>
       c2c get-tmux-location [--json]
      and bare `c2c --version`. *)

  let argv = Sys.argv in
  let n = Array.length argv in
  if n >= 2 then begin
    match argv.(1) with
    | "help" ->
        (* Accept only positional args (no flags we don't handle).
           `c2c help` alone → top-level help. `c2c help rooms` → `c2c rooms --help`. *)
        maybe_emit_update_notice ();
        fast_path_help ()
    | "commands" ->
        maybe_emit_update_notice ();
        C2c_commands_cmd.fast_path_commands ()
    | "server-info" ->
        let json = ref false in
        let unknown = ref false in
        for i = 2 to n - 1 do
          match argv.(i) with
          | "--json" | "-j" -> json := true
          | _ -> unknown := true
        done;
        if not !unknown then begin
          maybe_emit_update_notice ();
          fast_path_server_info ~json:!json ();
          exit 0
        end
    | "completion" ->
        fast_path_completion ()
    | "skills" when n >= 3 ->
        (match argv.(2) with
         | "list" ->
             let json = ref false in
             let unknown = ref false in
             for i = 3 to n - 1 do
               match argv.(i) with
               | "--json" | "-j" -> json := true
               | _ -> unknown := true
             done;
             if not !unknown then begin
               C2c_skills_cmd.fast_path_skills_list ~json:!json ();
               exit 0
             end
         | "serve" when n = 4 && not (String.starts_with ~prefix:"-" argv.(3)) ->
             C2c_skills_cmd.fast_path_skills_serve argv.(3);
             exit 0
         | _ -> ())
    | "get-tmux-location" ->
        let json = ref false in
        let unknown = ref false in
        for i = 2 to n - 1 do
          match argv.(i) with
          | "--json" -> json := true
          | _ -> unknown := true
        done;
        if not !unknown then fast_path_get_tmux_location ~json:!json ()
    | "--version" when n = 2 ->
        maybe_emit_update_notice ();
        Printf.printf "%s\n" (version_string ());
        exit 0
    | _ -> ()
  end
