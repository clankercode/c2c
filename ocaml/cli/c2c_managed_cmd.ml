(* c2c_managed_cmd - managed-session lifecycle commands.
   Extracted from c2c.ml as part of the CLI architecture refactoring. *)

open C2c_cli_helpers
open Cmdliner.Term.Syntax
open C2c_types
open C2c_commands
open C2c_utils
open C2c_agent

(* --- subcommand: start ---------------------------------------------------- *)

let roles_dir () = C2c_role.canonical_roles_dir ()

let role_file_path ~alias =
  roles_dir () // (alias ^ ".md")

let read_role ~alias =
  let path = role_file_path ~alias in
  try
    let role = C2c_role.parse_file path in
    Some role
  with Sys_error _ -> None

let yaml_scalar s =
  if s = "" || String.length s > 0 && (String.contains s ':' || String.contains s '#' ||
     String.contains s '"' || String.contains s '\'') then
    "\"" ^ String.escaped s ^ "\""
  else s

let write_role ~alias ~(role : C2c_role.t) =
  let dir = roles_dir () in
  C2c_utils.mkdir_p dir;
  let path = role_file_path ~alias in
  let fm =
    Printf.sprintf
      "---\n\
       description: %s\n\
       role: %s\n\
       ---\n\
       %s\n"
      (yaml_scalar role.C2c_role.description)
      role.C2c_role.role
      role.C2c_role.body
  in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc fm)

let prompt_for_role ~alias =
  if Unix.isatty Unix.stdin then begin
    Printf.eprintf "\n[c2c start] No role file found for alias '%s'.\n" alias;
    Printf.eprintf "  What is this agent's role? (e.g. coder, planner, coordinator — press Enter to skip)\n";
    Printf.eprintf "  > %!";
    let line = try input_line stdin with End_of_file -> "" in
    let trimmed = String.trim line in
    if trimmed <> "" then begin
      (* If the input matches a known role class, expand the full template
         body so the agent gets first-5-turns + heartbeat block + peer-PASS
         sentence without the operator needing to write it manually.
         Fall back to using the raw input as a simple body. *)
      let body =
        match Role_templates.render ~role_class:trimmed ~alias ~display_name_hint:"" with
        | Some rendered -> rendered
        | None -> trimmed
      in
      let role = { C2c_role.
        description = "";
        role = "subagent";
        model = None;
        pmodel = None;
        role_class = None;
        pronouns = None;
        coordinator = None;
        c2c_alias = None;
        c2c_auto_join_rooms = [];
        c2c_heartbeat = [];
        c2c_heartbeats = [];
        include_ = [];
        compatible_clients = [];
        required_capabilities = [];
        opencode = [];
        claude = [];
        codex = [];
        kimi = [];
        body;
      } in
      write_role ~alias ~role;
      Printf.eprintf "[c2c start] Role saved to .c2c/roles/%s.md\n%!" alias;
      Some role
    end else None
  end else None

(* Render the kickoff prompt (#341): take the [swarm] restart_intro
   template (or the built-in fallback) and substitute {name}, {alias},
   {role} placeholders. The default template is in
   [C2c_start.builtin_swarm_restart_intro]; user override goes in
   .c2c/config.toml under [swarm] restart_intro. *)
let default_kickoff_prompt ~name ~alias ?role () =
  let role_section = match role with
    | None -> ""
    | Some r -> Printf.sprintf "\nYour assigned role: %s\n" r
  in
  let template = C2c_start.swarm_config_restart_intro () in
  let subst =
    [ "{name}", name; "{alias}", alias; "{role}", role_section ]
  in
  List.fold_left
    (fun acc (k, v) ->
      (* Naive substitute-all: walk acc, replace each occurrence of k with v.
         Placeholders are short, count is tiny — perf is irrelevant here. *)
      let rec replace s =
        match String.index_opt s '{' with
        | None -> s
        | Some _ ->
            let klen = String.length k in
            let slen = String.length s in
            let rec find i =
              if i + klen > slen then None
              else if String.sub s i klen = k then Some i
              else find (i + 1)
            in
            (match find 0 with
             | None -> s
             | Some i ->
                 let before = String.sub s 0 i in
                 let after = String.sub s (i + klen) (slen - i - klen) in
                 before ^ v ^ replace after)
      in
      replace acc)
    template subst

let agent_file_path ~client ~name =
  match client with
  | "kimi" -> C2c_role.kimi_agent_yaml_path ~name
  | _ -> C2c_role.client_agent_dir ~client // (name ^ ".md")

let render_role_for_client ?(model_override : string option) (r : C2c_role.t) ~client ~name =
  let pmodel_lookup (key : string) : string option =
    match C2c_start.repo_config_pmodel_lookup key with
    | None -> None
    | Some p -> Some (p.C2c_start.provider ^ ":" ^ p.C2c_start.model)
  in
  let resolved_pmodel =
    match model_override with
    | Some m -> Some m
    | None -> C2c_role.resolve_pmodel r ~class_lookup:pmodel_lookup
  in
  match resolved_pmodel with
  | Some p -> C2c_role.render_for_client r ~client ~resolved_pmodel:p ~name
  | None -> C2c_role.render_for_client r ~client ~name

(** Resolve the effective pmodel from a role and normalize it for launch args.
    Returns None if the role has no pmodel set.
    Used by cmd_start to derive --model from the role when no explicit --model
    flag is given. *)
let resolve_role_pmodel_for_launch (r : C2c_role.t) ~(client : string) : string option =
  let pmodel_lookup (key : string) : string option =
    match C2c_start.repo_config_pmodel_lookup key with
    | None -> None
    | Some p -> Some (p.C2c_start.provider ^ ":" ^ p.C2c_start.model)
  in
  match C2c_role.resolve_pmodel r ~class_lookup:pmodel_lookup with
  | None -> None
  | Some raw ->
      (match C2c_start.normalize_model_override_for_client ~client raw with
       | Ok normalized -> Some normalized
       | Error _ -> None)

let write_agent_file ~client ~name ~content =
  let path = agent_file_path ~client ~name in
  let dir = Filename.dirname path in
  mkdir_p dir;
  let lock_path = path ^ ".lock" in
  let fd = Unix.openfile lock_path [Unix.O_RDWR; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
  Fun.protect ~finally:(fun () -> Unix.close fd)
    (fun () ->
      Unix.lockf fd Unix.F_LOCK 0;
      Fun.protect ~finally:(fun () -> Unix.lockf fd Unix.F_ULOCK 0)
        (fun () ->
          let oc = open_out path in
          Fun.protect ~finally:(fun () -> close_out oc)
            (fun () -> output_string oc content; output_char oc '\n');
          Printf.eprintf "[c2c start] wrote compiled agent file: %s\n%!" path))

let get_opencode_theme (r : C2c_role.t) : string option =
  List.assoc_opt "theme" r.C2c_role.opencode

let start_cmd =
  let client =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"CLIENT"
      ~doc:(Printf.sprintf "Client to start (%s)." C2c_setup.start_client_list))
  in
  (* Trailing args after `--`: appended to the client's argv, except for the
     reserved [--c2c:name] wrapper control (B221).
     e.g. `c2c start claude -- --foo bar` runs claude with `--foo bar`;
     `c2c start pty -- bash -i` runs bash with `-i`.

     #470: use `string` (not `list string`) — the `list` Cmdliner converter
     splits each token on commas, which mangles arguments that contain
     commas (e.g. `--prompt "Hello, world"` would become three tokens:
     ["--prompt"; "Hello"; " world"]). With plain `string`, each positional
     token is preserved verbatim. *)
  let extra_argv =
    (* #470: `pos_all string []` captures every positional (including CLIENT)
       as individual tokens while preserving commas. Cmdliner consumes `--`;
       the shared helper removes the leading CLIENT. This replaces the
       broken `pos_right 1 (list string) []` which mangled comma-containing args
       and included `--` literally in the string. *)
    let extra_argv_term =
      Cmdliner.Arg.(value & pos_all string [] & info [] ~docv:"ARG"
        ~doc:"Extra arguments forwarded to the spawned client's argv (e.g. \
              `c2c start claude -- --print hello` runs claude with `--print hello`). \
              Tokens are preserved verbatim — commas inside an argument are NOT \
              split. The reserved `--c2c:name NAME` / `--c2c:name=NAME` control \
              sets the managed instance name and is removed from the client argv. \
              For CLIENT=tmux, the tail is typed into the target pane instead \
              of appended to argv. For CLIENT=pty, the first tail arg is the command \
              to spawn under the PTY (e.g. `c2c start pty -- bash -i`).")
    in
    let open Cmdliner.Term.Syntax in
    let+ extra_argv = extra_argv_term in
    C2c_start.strip_start_extra_argv_prefix extra_argv
  in
  let name =
    Cmdliner.Arg.(value & opt (some string) None & info [ "name"; "n" ] ~docv:"NAME" ~doc:"Instance name, and the broker alias peers send to unless --alias overrides it (default: auto-generated).")
  in
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias" ] ~docv:"ALIAS" ~doc:"Custom alias (defaults to instance name).")
  in
  let no_nonce =
    Cmdliner.Arg.(value & flag & info [ "no-nonce" ]
      ~doc:"Deprecated no-op: default auto-generated instance names always keep the 4-character nonce suffix.")
  in
  let bin =
    Cmdliner.Arg.(value & opt (some string) None & info [ "bin" ] ~docv:"PATH" ~doc:"Custom binary path or name to launch.")
  in
  let session_id =
    Cmdliner.Arg.(value & opt (some string) None & info [ "session-id"; "s" ] ~docv:"ID" ~doc:"Explicit session target — UUID or named session for claude, exact thread/session target for codex and codex-headless, ses_* for opencode (overrides auto-generated).")
  in
  let one_hr_cache =
    Cmdliner.Arg.(value & flag & info [ "1hr-cache" ] ~doc:"Set ENABLE_PROMPT_CACHING_1H=1 (claude only; default off — 1h cache writes cost 2x, only worth it if you hit the cache).")
  in
  let no_prompt_flag =
    Cmdliner.Arg.(value & flag & info [ "no-prompt"; "non-interactive" ]
      ~doc:"Skip all interactive prompts. Prompts that have a sane default take the \
            default silently; prompts with no default (e.g. missing opencode.json with no \
            --agent) exit non-zero with a clear error naming the missing input. \
            Also respected when C2C_NO_PROMPT=1 is set in the environment.")
  in
  let auto_flag =
    Cmdliner.Arg.(value & flag & info [ "auto" ] ~doc:"Write a getting-started kickoff prompt that the plugin delivers on first session.idle. OpenCode only.")
  in
  let kickoff_prompt_opt =
    Cmdliner.Arg.(value & opt (some string) None & info [ "kickoff-prompt" ] ~docv:"TEXT" ~doc:"Custom kickoff prompt text (implies --auto). OpenCode only.")
  in
  let kickoff_prompt_file_opt =
    Cmdliner.Arg.(value & opt (some string) None & info [ "kickoff-prompt-file" ] ~docv:"PATH" ~doc:"Read kickoff prompt from file (mutually exclusive with --kickoff-prompt). Useful for passing multi-line kickoff via tmux-backed launchers.")
  in
  let agent =
    Cmdliner.Arg.(value & opt (some string) None & info [ "agent"; "a" ] ~docv:"NAME" ~doc:"Start from canonical role at .c2c/roles/<NAME>.md (compiled to client format on launch).")
  in
  let model =
    Cmdliner.Arg.(value & opt (some string) None & info [ "model"; "m" ] ~docv:"MODEL" ~doc:"Override the launch model. Accepts pmodel-style input; single-provider clients also accept bare model names.")
  in
  let reply_to =
    Cmdliner.Arg.(value & opt (some string) None & info [ "reply-to" ] ~docv:"ALIAS" ~doc:"Set C2C_MCP_REPLY_TO env var — used by ephemeral agents to know where to send completion results.")
  in
  let auto_join =
    Cmdliner.Arg.(value & opt (some string) None & info [ "auto-join" ] ~docv:"ROOMS" ~doc:"Comma-separated room IDs to auto-join on startup. Overrides the default swarm-lounge.")
  in
  let worktree =
    Cmdliner.Arg.(value & flag & info [ "worktree" ] ~doc:"Create an isolated git worktree for this agent before launching. Useful for parallel feature work. Implied when C2C_AUTO_WORKTREE=1.")
  in
  let branch_opt =
    Cmdliner.Arg.(value & opt (some string) None & info [ "branch" ] ~docv:"BRANCH" ~doc:"Branch to check out in the new worktree (requires --worktree). Defaults to caller's current branch. Must not be 'master'.")
  in
  let tmux_loc =
    Cmdliner.Arg.(value & opt (some string) None & info [ "loc" ] ~docv:"TMUX_TARGET"
      ~doc:"Tmux target for generic tmux mode (e.g. 0:1.2 or %42). Required when CLIENT=tmux.")
  in
  let new_session_flag =
    Cmdliner.Arg.(value & flag & info [ "new-session" ]
      ~doc:"Start a fresh session even when an existing instance config is found. \
            Discards the saved session ID; the agent starts with a clean transcript. \
            Use when resumed sessions have grown too large.")
  in
  let foreground_flag =
    Cmdliner.Arg.(value & flag & info [ "foreground"; "fg" ]
      ~doc:"For CLIENT=relay-connect: run connector in the foreground instead of \
            daemonizing. Useful for tmux-managed dogfooding. Ignored for other clients.")
  in
  let relay_url_opt =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL"
      ~doc:"For CLIENT=relay-connect: relay URL to connect to. Same resolution \
            as $(b,c2c relay connect): $(b,--relay-url), then \
            \\$C2C_RELAY_URL, then the URL persisted by $(b,c2c relay setup) \
            (relay.json). Ignored for other clients.")
  in
  let interval_opt =
    Cmdliner.Arg.(value & opt int 30 & info [ "interval" ] ~docv:"SECS"
      ~doc:"For CLIENT=relay-connect: poll interval in seconds (default 30). \
            Ignored for other clients.")
  in
  (* T006: app-server-backed Codex grammar flags (codex only). *)
  let yolo_flag =
    Cmdliner.Arg.(value & flag & info [ "yolo" ]
      ~doc:"CLIENT=codex only. DANGER: forward codex \
            --dangerously-bypass-approvals-and-sandbox (disables ALL approvals \
            and the sandbox). Prints a warning; never persisted into resumes.")
  in
  let thread_id_flag =
    Cmdliner.Arg.(value & opt (some string) None & info [ "thread-id" ] ~docv:"ID"
      ~doc:"CLIENT=codex only. Exact Codex thread id to select; a conflict with \
            the saved thread is rejected rather than guessed.")
  in
  let+ client = client
  and+ name_opt = name
  and+ alias_opt = alias
  and+ no_nonce = no_nonce
  and+ bin_opt = bin
  and+ session_id_opt = session_id
  and+ one_hr_cache = one_hr_cache
  and+ no_prompt = no_prompt_flag
  and+ auto_flag = auto_flag
  and+ kickoff_prompt_text_raw = kickoff_prompt_opt
  and+ kickoff_prompt_file = kickoff_prompt_file_opt
  and+ agent_opt = agent
  and+ model_opt = model
  and+ reply_to = reply_to
  and+ auto_join = auto_join
  and+ worktree_flag = worktree
  and+ branch_flag = branch_opt
  and+ tmux_loc = tmux_loc
  and+ extra_argv = extra_argv
  and+ new_session = new_session_flag
  and+ foreground_flag = foreground_flag
  and+ relay_url_opt = relay_url_opt
  and+ interval_opt = interval_opt
  and+ yolo_flag = yolo_flag
  and+ thread_id_flag = thread_id_flag in
  let namespaced =
    match C2c_start.parse_namespaced_passthrough extra_argv with
    | Ok parsed -> parsed
    | Error msg ->
        Printf.eprintf "error: %s\n%!" msg;
        exit 1
  in
  let namespaced_name = namespaced.C2c_start.c2c_name in
  let name_opt =
    match C2c_start.merge_namespaced_name ~existing:name_opt
            ~namespaced:namespaced_name with
    | Ok value -> value
    | Error msg ->
        Printf.eprintf "error: %s\n%!" msg;
        exit 1
  in
  let extra_argv = namespaced.C2c_start.client_args in
  (* #470: extra_argv is now string list. The positional converter was changed
     from `pos_right 1 (list string) []` (which split each token on commas, so
     `c2c start claude -- --prompt "Hello, world"` would arrive as
     ["--prompt"; "Hello"; " world"]) to `pos_all string []` which preserves
     each token verbatim; no flatten needed. *)
  let kickoff_prompt_text =
    match kickoff_prompt_text_raw, kickoff_prompt_file with
    | Some _, Some _ ->
        Printf.eprintf "error: --kickoff-prompt and --kickoff-prompt-file are mutually exclusive.\n%!";
        exit 1
    | Some t, None -> Some t
    | None, Some path ->
        (try
           let ic = open_in path in
           Fun.protect ~finally:(fun () -> close_in_noerr ic) @@ fun () ->
             let n = in_channel_length ic in
             let buf = Bytes.create n in
             really_input ic buf 0 n;
             Some (Bytes.to_string buf)
         with Sys_error e ->
           Printf.eprintf "error: failed to read --kickoff-prompt-file %s: %s\n%!" path e;
           exit 1)
    | None, None -> None
  in
  (* The nested-session guard below applies to harness clients
     (claude/codex/etc.) where running `c2c start` from inside another
     agent session can hijack session IDs. relay-connect is a pure
     background daemon — no inheritance hazard — so it dispatches before
     the guard. *)
  if client <> "relay-connect" && Sys.getenv_opt "C2C_INSTANCE_NAME" <> None then begin
    Printf.eprintf "error: cannot run 'c2c start' from inside a c2c session.\n";
    Printf.eprintf "  Hint: use the outer shell or a separate terminal instead.\n%!";
    exit 1
  end;
  (* relay-connect: managed connector daemon. Branches off the harness-client
     pipeline early — connectors don't need session ids, role files, kickoff
     prompts, or tmux integration. The instance dir + outer.pid plumbing is
     shared with `c2c instances` / `c2c stop` so they Just Work. *)
  if client = "relay-connect" then begin
    let name = match name_opt with
      | Some n -> n
      | None -> "relay-connect"
    in
    (* B242: use the same URL resolution as plain `c2c relay connect` —
       flag → C2C_RELAY_URL → c2c relay setup / relay.json — so a prior
       `c2c relay setup --url …` is enough to start the managed connector. *)
    let resolved_url = C2c_relay_cmd.resolve_relay_url relay_url_opt in
    if resolved_url = None then begin
      Printf.eprintf
        "error: relay-connect requires a relay URL.\n\
        \  Pass --relay-url URL, export C2C_RELAY_URL, or run \
           c2c relay setup --url <URL>.\n\
        \  (Default public relay is %s.)\n%!"
        C2c_relay_cmd.default_public_relay_url;
      exit 1
    end;
    C2c_relay_managed.start
      ~name
      ~daemon:(not foreground_flag)
      ~relay_url:resolved_url
      ~broker_root:(resolve_broker_root ())
      ~interval:interval_opt
      ~extra_args:extra_argv
      () [@ocaml.warning "-21"];
    (* We never reach here — start either execs in-place (foreground) or
       the daemon child never returns (it execs the connector). *)
  end;
  if client <> "tmux" && tmux_loc <> None then begin
    Printf.eprintf "error: --loc is only valid with `c2c start tmux`.\n%!";
    exit 1
  end;
  (* Args after `--` (apart from reserved --c2c:* controls) are forwarded to
     the spawned client's argv (per
     `c2c start --help`). For CLIENT=tmux, the tail is the command typed
     into the target pane (handled separately via tmux_command). For all
     other clients, the tail flows through extra_argv → prepare_launch_args,
     which appends it verbatim to the client's argv. No reject here. *)
  let name, name_from_auto_gen = match name_opt with
    | Some n -> (n, false)
    | None ->
        let n = C2c_start.default_name ~no_nonce client in
        Printf.eprintf "[c2c start] no -n given; auto-picked name=%s. Pass -n NAME to override.\n%!" n;
        (n, true)
  in
  let binary_path =
    match bin_opt with
    | Some path -> path
    | None ->
        (try
           let cfg = Stdlib.Hashtbl.find C2c_start.clients client in
           cfg.C2c_start.binary
         with Not_found -> client)
  in
  let model_override =
    match model_opt with
    | None -> None
    | Some raw ->
        (match C2c_start.normalize_model_override_for_client ~client raw with
         | Ok normalized -> Some normalized
         | Error msg ->
             Printf.eprintf "error: invalid --model for client '%s': %s\n%!" client msg;
             exit 1)
  in
  let effective_alias = Option.value alias_opt ~default:name in
  let alias_from_auto_gen = name_from_auto_gen && (alias_opt = None) in
  (* #58 / #76: the {alias} a kickoff prompt shows must be the address that will
     actually be published. For a codex auto-derive (auto-picked name, no
     --alias / -n) the app-server mints a codex-<…> alias from its session id
     AFTER launch, so the launcher cannot know it and must tell the agent to
     self-verify (the #34 lesson). [C2c_start.managed_kickoff_alias] returns the
     showable address, or [None] to defer; it is keyed on the branch's REAL
     alias override — [alias_opt] on this no-role path, and [role_alias] on the
     two role/agent branches (#76: those used to interpolate their own
     [effective_alias], which defaulted to the ROLE name at the --agent site
     while the session publishes the instance name). Whenever it returns
     [Some a], [managed_published_alias] returns the same [a]. *)
  let kickoff_alias_or_defer ~(alias_override : string option) : string =
    match
      C2c_start.managed_kickoff_alias ~client ~name ~alias_override
        ~requested_name:
          (C2c_start.codex_requested_name_for_managed_start ~name
             ~name_from_auto_gen)
    with
    | Some a -> a
    | None -> "(auto-assigned at launch — run `c2c whoami` to see it)"
  in
  let kickoff_alias = kickoff_alias_or_defer ~alias_override:alias_opt in
  (* Resolve agent file path: canonical .c2c/roles/<agent>.md first,
     falling back to client-native agent path if canonical doesn't exist. *)
  let agent_role_path agent_name =
    C2c_role.resolve_agent_path ~name:agent_name ~client
  in
  (* --agent mode: load canonical role, render for client, write compiled file *)
  let (kickoff_prompt, alias_override, auto_join_rooms, agent_name, role_pmodel_override) =
    match agent_opt with
    | Some agent_name ->
        let role_path = agent_role_path agent_name in
        (try
           let role = C2c_role.parse_file role_path in
           if role.C2c_role.compatible_clients <> [] &&
              not (List.mem client role.C2c_role.compatible_clients) then
             (Printf.eprintf "error: role '%s' is not compatible with client '%s'.\n" agent_name client;
              Printf.eprintf "  compatible clients: %s\n%!" (String.concat ", " role.C2c_role.compatible_clients);
              exit 1);
           let missing =
             C2c_start.missing_role_capabilities ~client ~binary_path role
           in
           if missing <> [] then begin
             let available =
               C2c_start.probed_capabilities ~client ~binary_path
             in
             Printf.eprintf
               "error: role '%s' requires unsupported capabilities for client '%s'.\n"
               agent_name client;
             Printf.eprintf "  missing: %s\n%!" (String.concat ", " missing);
             Printf.eprintf "  available: %s\n%!"
               (if available = [] then "(none)" else String.concat ", " available);
             exit 1
           end;
            let role_pmodel = resolve_role_pmodel_for_launch role ~client in
            match render_role_for_client ?model_override role ~client ~name:agent_name with
            | Some rendered ->
                (* #34 review (fix 2): an explicit [--alias] outranks the role's
                   [c2c_alias] — that is the precedence docs/commands.md states.
                   This branch used to bind [alias_override] straight from the
                   role and drop [alias_opt] on the floor, so
                   `c2c start codex --agent R --alias BROKER -n NAME` silently
                   published NAME (or the role alias) instead of BROKER. *)
                let role_alias =
                  C2c_start.managed_alias_override_for_role ~alias_opt
                    ~role_alias:role.C2c_role.c2c_alias
                in
                (* #76: show [role_alias] (else the instance [name], the value
                   the publish path registers) — NOT [agent_name], the ROLE's
                   display name. The old [~default:agent_name] made the kickoff
                   assert an address the session never holds. Defer to whoami
                   only when codex will derive one post-launch. *)
                let kickoff_alias =
                  kickoff_alias_or_defer ~alias_override:role_alias
                in
                (* write_agent_file: opencode/claude write .md with YAML frontmatter.
                   Kimi writes AgentSpec YAML (agent.yaml) + system.md.
                   Codex has no user agent file surface.
                   Ref: .collab/design/2026-04-29-kuura-viima-143b-write-agent-file-parity.md *)
                if client = "opencode" || client = "claude" then
                  write_agent_file ~client ~name ~content:rendered;
                if client = "kimi" then begin
                  write_agent_file ~client ~name:agent_name ~content:rendered;
                  write_kimi_system_prompt ~name:agent_name ~content:role.C2c_role.body;
                end;
                let kickoff =
                  if client = "claude" then Some (C2c_start.claude_onboarding_preamble ~name:agent_name)
                  else Some (default_kickoff_prompt ~name:agent_name ~alias:kickoff_alias ~role:role.C2c_role.body ())
                in
                let alias_override = role_alias in
               let auto_join_rooms =
                 if role.C2c_role.c2c_auto_join_rooms <> []
                 then Some (String.concat ", " role.C2c_role.c2c_auto_join_rooms)
                 else None
               in
               let theme = get_opencode_theme role in
               let subtitle = Printf.sprintf "%s  |  %s" client name in
               Banner.print_banner ?theme_name:theme ~subtitle (Printf.sprintf "c2c start --agent %s" agent_name);
                let effective_agent_name = Some agent_name in
                (kickoff, alias_override, auto_join_rooms, effective_agent_name, role_pmodel)
          | None ->
              Printf.eprintf "error: --agent is not supported for client '%s' yet.\n%!" client;
              exit 1
        with Sys_error _ ->
          Printf.eprintf "error: role file not found: %s\n%!" role_path;
          exit 1)
    | None ->
        (* Auto-inference: if .c2c/roles/<name>.md or <client-native>/<name>.md exists
           as a structured role, auto-apply --agent=<name> (silent, no banner).
           Explicit --agent always wins. *)
        let canonical_path = role_file_path ~alias:name in
        let client_native_path = C2c_role.client_agent_dir ~client // (name ^ ".md") in
        let role_path =
          if Sys.file_exists canonical_path then canonical_path
          else if Sys.file_exists client_native_path then client_native_path
          else canonical_path (* non-existent, will trigger Sys_error below *)
        in
        if Sys.file_exists role_path then
          (try
             let role = C2c_role.parse_file role_path in
             if role.C2c_role.compatible_clients <> [] &&
                not (List.mem client role.C2c_role.compatible_clients) then
                (Printf.eprintf "error: role '%s' is not compatible with client '%s'.\n" name client;
                 Printf.eprintf "  compatible clients: %s\n%!" (String.concat ", " role.C2c_role.compatible_clients);
                 exit 1);
             let missing =
               C2c_start.missing_role_capabilities ~client ~binary_path role
             in
             if missing <> [] then begin
               let available =
                 C2c_start.probed_capabilities ~client ~binary_path
               in
               Printf.eprintf
                 "error: role '%s' requires unsupported capabilities for client '%s'.\n"
                 name client;
               Printf.eprintf "  missing: %s\n%!" (String.concat ", " missing);
               Printf.eprintf "  available: %s\n%!"
                 (if available = [] then "(none)" else String.concat ", " available);
               exit 1
             end;
               let role_pmodel = resolve_role_pmodel_for_launch role ~client in
               (match render_role_for_client ?model_override role ~client ~name with
                | Some rendered ->
                    (* #34 review (fix 2): same explicit-[--alias]-wins
                       precedence as the explicit [--agent] branch above; the
                       auto-inferred-role path dropped [alias_opt] identically. *)
                    let role_alias =
                      C2c_start.managed_alias_override_for_role ~alias_opt
                        ~role_alias:role.C2c_role.c2c_alias
                    in
                    (* #76: same treatment as the explicit --agent branch — show
                       [role_alias] else the instance [name] (the published
                       address), deferring to whoami only on a codex auto-derive.
                       This branch already defaulted to [name] (not the role
                       name), so it was never wrong for non-codex; routing it
                       through [managed_kickoff_alias] adds the codex-derive
                       deferral and keeps both role branches identical. *)
                    let kickoff_alias =
                      kickoff_alias_or_defer ~alias_override:role_alias
                    in
                    (* write_agent_file: opencode/claude only — same rationale
                       as gate at line ~7488. See design doc for per-client
                       divergence details. *)
                    if client = "opencode" || client = "claude" then
                      write_agent_file ~client ~name ~content:rendered;
                    let kickoff =
                      if client = "claude" then Some (C2c_start.claude_onboarding_preamble ~name)
                      else Some (default_kickoff_prompt ~name ~alias:kickoff_alias ~role:role.C2c_role.body ())
                    in
                    let alias_override = role_alias in
                    let auto_join_rooms =
                      if role.C2c_role.c2c_auto_join_rooms <> []
                      then Some (String.concat ", " role.C2c_role.c2c_auto_join_rooms)
                      else None
                    in
                     let agent_name = Some name in
                     (kickoff, alias_override, auto_join_rooms, agent_name, role_pmodel)
               | None ->
                        (* Role file exists but not supported for this client — fall through
                           to structured role path so user can still start with the role. *)
                        let role_opt =
                          match read_role ~alias:effective_alias with
                          | Some r -> Some r
                          | None -> prompt_for_role ~alias:effective_alias
                         in
                         let kickoff_prompt =
                           match kickoff_prompt_text with
                           | Some t -> Some t
                           | None when auto_flag -> Some (default_kickoff_prompt ~name ~alias:kickoff_alias ?role:(Option.map (fun r -> r.C2c_role.body) role_opt) ())
                           | None ->
                               (match role_opt with
                                | Some _ -> Some (default_kickoff_prompt ~name ~alias:kickoff_alias ?role:(Option.map (fun r -> r.C2c_role.body) role_opt) ())
                                 | None ->
                                     (* B011: a no-role start is never intro-less for agent clients. *)
                                     if C2c_start.intro_on_no_role client
                                     then Some (default_kickoff_prompt ~name ~alias:kickoff_alias ())
                                     else None)
                          in
                          (kickoff_prompt, alias_opt, None, None, None))
             with Sys_error _ ->
              (* Role file exists but can't be read as structured role — fall through. *)
              let role_opt =
                match read_role ~alias:effective_alias with
                | Some r -> Some r
                | None -> prompt_for_role ~alias:effective_alias
              in
              let kickoff_prompt =
                match kickoff_prompt_text with
                | Some t -> Some t
                | None when auto_flag -> Some (default_kickoff_prompt ~name ~alias:kickoff_alias ?role:(Option.map (fun r -> r.C2c_role.body) role_opt) ())
                | None ->
                    (match role_opt with
                     | Some _ -> Some (default_kickoff_prompt ~name ~alias:kickoff_alias ?role:(Option.map (fun r -> r.C2c_role.body) role_opt) ())
                      | None ->
                          (* B011: a no-role start is never intro-less for agent clients. *)
                          if C2c_start.intro_on_no_role client
                          then Some (default_kickoff_prompt ~name ~alias:kickoff_alias ())
                          else None)
                 in
                 (kickoff_prompt, alias_opt, None, None, None))
        else
          (* No structured role file — structured role path. *)
          let role_opt =
            match read_role ~alias:effective_alias with
            | Some r -> Some r
            | None ->
                (* If an explicit kickoff is already set, skip the interactive
                   role prompt — the caller knows what they want. This is the
                   path hit by `c2c agent run --pane` which pre-composes the
                   full kickoff and passes it via --kickoff-prompt-file. *)
                if client = "tmux" || kickoff_prompt_text <> None then None
                else prompt_for_role ~alias:effective_alias
          in
          let kickoff_prompt =
            match kickoff_prompt_text with
            | Some t -> Some t
            | None when auto_flag -> Some (default_kickoff_prompt ~name ~alias:kickoff_alias ?role:(Option.map (fun r -> r.C2c_role.body) role_opt) ())
            | None ->
                (match role_opt with
                 | Some _ -> Some (default_kickoff_prompt ~name ~alias:kickoff_alias ?role:(Option.map (fun r -> r.C2c_role.body) role_opt) ())
                 | None ->
                     (* B011: a no-role start is never intro-less for agent clients. *)
                     if C2c_start.intro_on_no_role client
                     then Some (default_kickoff_prompt ~name ~alias:kickoff_alias ())
                     else None)
           in
           (kickoff_prompt, alias_opt, None, None, None)
   in
   let auto_join_rooms = match auto_join with
    | Some rooms -> Some rooms
    | None -> auto_join_rooms
  in
  let auto_worktree = worktree_flag || (match Sys.getenv_opt "C2C_AUTO_WORKTREE" with Some "1" -> true | _ -> false) in
  (match session_id_opt with
  | Some _ ->
      Printf.printf "[c2c] resume mode — staying at parent cwd\n%!"
  | None when auto_worktree ->
      (* Resolve which branch the worktree should track:
         1. --branch flag (explicit override)
         2. caller's current git branch (auto-detected)
         3. error if neither is available or if branch is 'master' *)
      let branch = match branch_flag with
        | Some b -> b
        | None ->
            (match C2c_worktree.current_branch () with
             | Some b -> b
             | None ->
                 Printf.eprintf "error: --worktree requires a branch but git reports detached HEAD. Pass --branch <name> explicitly.\n%!";
                 exit 1)
      in
      if branch = "master" || branch = "main" then begin
        Printf.eprintf "error: --worktree refused on '%s'. Create a slice branch first (e.g. git checkout -b slice/my-work) or pass --branch <name>.\n%!" branch;
        exit 1
      end;
      let wt_dir = C2c_worktree.ensure_worktree ~alias:effective_alias ~branch in
      (try Unix.chdir wt_dir with Sys_error e ->
        Printf.eprintf "warning: failed to chdir to worktree %s: %s\n%!" wt_dir e);
      Printf.printf "[c2c] worktree: %s (branch: %s)\n%!" wt_dir branch
  | _ -> ());
  (* The hook-backed launch, as a thunk parameterized by the effective codex
     passthrough argv. This is the exact existing path; T006 wraps it so
     `c2c start codex` shares one implementation with `c2c codex`/`new`/`resume`. *)
  let cmd_start_with ~extra_args () =
    C2c_start.cmd_start ~client ~name ~extra_args
      ?binary_override:bin_opt
      ?alias_override
      ?session_id_override:session_id_opt
      ?model_override
      ?role_pmodel_override
      ~one_hr_cache ~new_session
      ?kickoff_prompt
      ?agent_name
      ?auto_join_rooms
      ?reply_to
      ?tmux_location:tmux_loc
      (* B221: use the same filtered tail for tmux that every other client
         receives.  Keeping a second raw positional capture here leaked
         reserved --c2c:* controls into the command typed into the pane. *)
      ~tmux_command:extra_args
      ~alias_from_auto_gen
      ~no_prompt
      ~opencode_plugin_embedded:C2c_opencode_plugin_embedded.content
      ()
  in
  if client = "codex" then
    (* #34: [name] is the merged instance name (`-n` / `--c2c:name`); pass it
       so the app-server path publishes the name the operator asked for
       instead of silently minting one. [name_from_auto_gen] keeps a
       c2c-picked name out of the override. *)
    let codex_alias_override =
      C2c_start.codex_alias_override_for_managed_start
        ~alias_opt:alias_override
        ~requested_name:
          (C2c_start.codex_requested_name_for_managed_start ~name
             ~name_from_auto_gen)
    in
    (* Fix 3: [alias_override] is either the explicit [--alias] or a role's
       [c2c_alias] (fix 2 makes the flag win). Name the real source in the
       notice — "--alias wins" is a lie when the operator never typed one. *)
    let alias_source =
      if alias_opt <> None then C2c_start.Alias_flag else C2c_start.Role_alias
    in
    (* When --alias legitimately outranks an explicit -n, say so — and record
       it durably: the codex TUI takes the terminal moments later, so a
       stderr-only note is not "loud" (#40 F5 learned this the hard way). *)
    (match codex_alias_override with
     | Some alias when not name_from_auto_gen ->
         (match
            C2c_start.codex_managed_start_name_notice ~source:alias_source ~name
              ~alias ()
          with
          | None -> ()
          | Some msg ->
              prerr_string msg;
              flush stderr;
              (try
                 Broker_log.append_json ~broker_root:(resolve_broker_root ())
                   ~json:
                     (C2c_start.managed_name_not_alias_record ~name ~alias
                        ~detail:msg ~ts:(Unix.gettimeofday ()))
               with _ -> ()))
     | _ -> ());
    exit (C2c_codex_cmd.start_delegate
            ~alias_override:codex_alias_override
            ~thread_id:thread_id_flag ~yolo:yolo_flag
            ?model_override ~extra_args:extra_argv
            ~fallback:cmd_start_with ())
  else begin
    ignore yolo_flag; ignore thread_id_flag;
    exit (cmd_start_with ~extra_args:extra_argv ())
  end

let start : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v (Cmdliner.Cmd.info "start" ~doc:"Start a managed c2c instance.") start_cmd

(* --- subcommand: stop ----------------------------------------------------- *)

let stop_cmd =
  let name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Instance name to stop.")
  in
  let+ json = json_flag
  and+ name = name in
  let output_mode = if json then Json else Human in
  let self_check =
    match Sys.getenv_opt "C2C_INSTANCE_NAME" with
    | Some self_name when self_name = name ->
        Some "cannot stop your own session"
    | _ -> None
  in
  if self_check <> None then begin
    (match output_mode with
     | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String (Option.value self_check ~default:"")) ])
     | Human -> Printf.eprintf "error: %s\n%!" (Option.value self_check ~default:""));
    exit 1
  end;
  let inst_path = C2c_instances_cmd.instances_dir () // name in
  if not (Sys.file_exists inst_path) then begin
    (match output_mode with
     | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String (Printf.sprintf "instance '%s' not found" name)) ])
     | Human -> Printf.eprintf "error: instance '%s' not found.\n%!" name);
    exit 1
  end;
  let outer_pid_path = inst_path // "outer.pid" in
  let result =
    if Sys.file_exists outer_pid_path then begin
      let pid_s =
        let ic = open_in outer_pid_path in
        Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
          let s = input_line ic in String.trim s)
      in
      match int_of_string_opt pid_s with
      | Some pid ->
          (try
             Unix.kill pid Sys.sigterm;
             let stopped = ref false in
             for _ = 1 to 10 do
               if not !stopped then begin
                 (try ignore (Unix.kill pid 0) with Unix.Unix_error _ -> stopped := true);
                 if not !stopped then Unix.sleepf 0.5
               end
             done;
             if not !stopped then
               (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
             "stopped"
           with Unix.Unix_error _ -> "stopped")
      | None -> "no pid found"
    end else "not running"
  in
  match output_mode with
  | Json ->
      print_json (`Assoc [ ("ok", `Bool true); ("name", `String name); ("status", `String result) ])
  | Human ->
      Printf.printf "Instance '%s': %s\n" name result

let stop : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v (Cmdliner.Cmd.info "stop" ~doc:"Stop a managed c2c instance.") stop_cmd

let restart_cmd =
  let name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Instance name to restart.")
  in
  let timeout =
    Cmdliner.Arg.(value & opt (some float) None & info [ "timeout" ]
      ~docv:"SECONDS"
      ~doc:"Seconds to wait for outer process to exit before spawning restart (default: 5).")
  in
  let force =
    Cmdliner.Arg.(value & flag & info [ "force" ]
      ~doc:"For an app-server Codex instance, restart even when thread status is active or unknown.")
  in
  let+ name = name
  and+ timeout = timeout
  and+ force = force in
  (* #49: when the operator did not pass --timeout, default the outer-exit
     ceiling per client. Managed kimi's outer loop winds down a notifier + REST
     client and exits just past the old flat 5s, which made restart abort and
     leave the session killed-but-not-relaunched. *)
  let timeout_s =
    match timeout with
    | Some t -> t
    | None ->
        (match C2c_start.load_config_opt name with
         | Some cfg -> C2c_start.default_restart_timeout_s ~client:cfg.C2c_start.client
         | None -> 5.0)
  in
  (* B212: the machine-wide relay connector persists a config shape that the
     harness-client restart path cannot parse (no session_id/alias/resume),
     which used to escape as an uncaught Not_found. Recognise it up front and
     drive the machine lifecycle (stop supervisor + relaunch daemon) instead.
     B235: also bootstrap when name is the conventional `relay-connect` and no
     managed config exists (ad-hoc connector died unsupervised) — restart then
     starts a supervised instance instead of falling through to
     "no config found for instance".
     [restart] does not return on success and exits cleanly on error. *)
  (match C2c_relay_managed.read_managed_config ~name with
   | Some _ ->
       C2c_relay_managed.restart
         ?relay_url_override:(C2c_relay_cmd.resolve_relay_url None) ~name
         ~broker_root:(resolve_broker_root ()) ~timeout_s ()
         [@ocaml.warning "-21"]
   | None when C2c_relay_managed.is_default_relay_connect_name name ->
       C2c_relay_managed.restart
         ?relay_url_override:(C2c_relay_cmd.resolve_relay_url None) ~name
         ~broker_root:(resolve_broker_root ()) ~timeout_s ()
         [@ocaml.warning "-21"]
   | None -> ());
  let instance_dir = C2c_start.instance_dir name in
  match C2c_codex_session.load_mapping ~instance_dir with
  | Some _ ->
      (* Any app-server mapping stays on the owner-control seam, including
         starting/unknown/offline records. Falling through to cmd_restart would
         spawn the replacement on this caller's TTY and violate ownership. *)
      (try
         let request_id =
           C2c_codex_session.request_restart ~instance_dir ~force
         in
         match C2c_codex_session.await_restart_result ~instance_dir ~request_id
                 ~timeout_s with
         | Some "restarting" ->
             Printf.printf
               "[c2c restart] owner accepted in-place restart for '%s'%s\n%!"
               name (if force then " (forced)" else " (idle-gated)");
             exit 0
         | Some result ->
             Printf.eprintf
               "[c2c restart] owner skipped restart for '%s': %s\n%!"
               name result;
             exit 2
         | None ->
             Printf.eprintf
               "[c2c restart] timed out after %.1fs waiting for app-server owner '%s'; no external restart was attempted\n%!"
               timeout_s name;
             exit 3
       with exn ->
         Printf.eprintf "error: could not request app-server restart: %s\n%!"
           (Printexc.to_string exn);
         exit 1)
  | None -> exit (C2c_start.cmd_restart name ~timeout_s)

let restart : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v (Cmdliner.Cmd.info "restart" ~doc:"Restart a managed c2c instance.") restart_cmd

(* --- subcommand: restart-stale (idea I010) -------------------------------- *)

let idle_allows_auto ~(force : bool) ~(app_server : bool)
    (idle : C2c_idle_contract.idle_state) : bool =
  if force then true
  else
    match idle with
    | C2c_idle_contract.Idle -> true
    | C2c_idle_contract.Busy -> false
    | C2c_idle_contract.Unknown _ -> app_server

let restart_stale_idle_fixture () : C2c_idle_contract.idle_state option =
  match Sys.getenv_opt "C2C_RESTART_STALE_IDLE_FIXTURE" with
  | Some s ->
      (match String.lowercase_ascii (String.trim s) with
       | "idle" -> Some C2c_idle_contract.Idle
       | "busy" -> Some C2c_idle_contract.Busy
       | "unknown" -> Some (C2c_idle_contract.Unknown "fixture")
       | _ -> None)
  | None -> None

let resolve_idle_for_instance ~(client : string) ~(name : string)
    ~(has_app_server_mapping : bool) : C2c_idle_contract.idle_state =
  match restart_stale_idle_fixture () with
  | Some idle -> idle
  | None ->
      C2c_idle_contract.query_client ~client
        ~instance_dir:(C2c_start.instance_dir name)
        ~has_app_server_mapping ()


(* What restart-stale decided to do for one managed instance. *)
type stale_action =
  | Restarted              (* app-server codex: owner accepted in-place restart *)
  | Would_restart          (* --dry-run: an app-server codex that would restart *)
  | Guided of string       (* stale, but not safe to auto-restart: manual cmd *)
  | Skipped of string      (* current / unknown / coordinator-excluded / self *)
  | Failed of string       (* auto-restart was attempted and failed *)

(* Hermetic command-test seam.  The request is still written through the real
   owner-control path (so tests can inspect its force bit), but a configured
   result stands in for the live app-server owner and avoids launching Codex.
   Unset or blank in production. *)
let restart_stale_owner_result_fixture () =
  match Sys.getenv_opt "C2C_RESTART_STALE_OWNER_RESULT_FIXTURE" with
  | Some result when String.trim result <> "" -> Some (String.trim result)
  | _ -> None

(* Request an in-place restart of one app-server Codex instance via the B153
   owner-control seam, called DIRECTLY (not by shelling out to `c2c restart`).
   The live owner self-reexecs in its own pane; we only write the request and
   await its result. Calling the seam inline — rather than spawning a child —
   means restart-stale can never execve into a supervisor / capture its own
   terminal (closing the child-fallback TOCTOU), and a failure degrades to a
   [Failed] row instead of aborting the rolling batch. *)
let request_app_server_restart ~name ~force ~timeout_s : stale_action =
  let instance_dir = C2c_start.instance_dir name in
  try
    let request_id = C2c_codex_session.request_restart ~instance_dir ~force in
    match
      match restart_stale_owner_result_fixture () with
      | Some result -> Some result
      | None ->
          C2c_codex_session.await_restart_result ~instance_dir ~request_id
            ~timeout_s
    with
    | Some "restarting" -> Restarted
    | Some result -> Skipped (Printf.sprintf "app-server owner declined: %s" result)
    | None -> Failed "timed out waiting for app-server owner"
  with exn ->
    Failed (Printf.sprintf "app-server restart error: %s" (Printexc.to_string exn))

(* G2: request in-pane outer-loop restart via C2c_owner_control. Never execve
   into a supervisor from this process (no TTY theft). *)
let request_outer_owner_restart ~name ~force ~timeout_s ~outer_pid : stale_action =
  let instance_dir = C2c_start.instance_dir name in
  try
    let start_time =
      match C2c_owner_control.read_pid_start_time outer_pid with
      | Some t -> t
      | None ->
          raise (Failure "outer pid start_time unavailable")
    in
    let request_id =
      C2c_owner_control.request_restart ~instance_dir ~instance_name:name
        ~force ~expected_pid:outer_pid ~expected_start_time:start_time ()
    in
    match
      match restart_stale_owner_result_fixture () with
      | Some result ->
          Some (C2c_owner_control.result_kind_of_string result)
      | None ->
          C2c_owner_control.await_result ~instance_dir ~request_id ~timeout_s
    with
    | Some C2c_owner_control.Restarting -> Restarted
    | Some (C2c_owner_control.Declined r) ->
        Skipped (Printf.sprintf "outer owner declined: %s" r)
    | Some (C2c_owner_control.Failed r) ->
        Failed (Printf.sprintf "outer owner failed: %s" r)
    | Some C2c_owner_control.Timed_out | None ->
        Failed "timed out waiting for outer owner"
  with exn ->
    Failed (Printf.sprintf "outer owner restart error: %s" (Printexc.to_string exn))


let restart_stale_cmd =
  let dry_run =
    Cmdliner.Arg.(value & flag & info [ "dry-run" ]
      ~doc:"Report what would be restarted without changing any process state.")
  in
  let exclude_coordinator =
    Cmdliner.Arg.(value & flag & info [ "exclude-coordinator" ]
      ~doc:"Skip the coordinator instance (otherwise it is restarted last).")
  in
  let force =
    Cmdliner.Arg.(value & flag & info [ "force" ]
      ~doc:"Treat every running instance as stale, and pass --force to \
            app-server restarts (overriding their idle gate).")
  in
  let timeout =
    Cmdliner.Arg.(value & opt (some float) None & info [ "timeout" ]
      ~docv:"SECONDS"
      ~doc:"Per-instance restart timeout in seconds (default: 20).")
  in
  let+ json = json_flag
  and+ dry_run = dry_run
  and+ exclude_coordinator = exclude_coordinator
  and+ force = force
  and+ timeout = timeout in
  let output_mode = if json then Json else Human in
  let timeout_s = Option.value timeout ~default:20.0 in
  let installed = "/proc/self/exe" in
  let coord_alias =
    String.lowercase_ascii (C2c_swarm_config.swarm_config_coordinator_alias ())
  in
  let self_name = Sys.getenv_opt "C2C_INSTANCE_NAME" in
  (* NB: the coordinator is matched by managed-instance NAME against the
     configured coordinator alias. The convention is name == alias (e.g.
     `c2c start claude -n coordinator1`); if an operator gives the coordinator
     a name that differs from its alias, coordinator-last ordering won't apply
     to it. *)
  let is_coord mi = String.lowercase_ascii mi.mi_name = coord_alias in
  (* Hash the installed binary at most once for the whole run (lazily, only if
     an inode mismatch forces a content compare). *)
  let installed_img = C2c_stale.installed_image installed in
  (* Dedup classification across processes sharing one executable inode. *)
  let verdict_memo : (int * int, C2c_stale.verdict) Hashtbl.t = Hashtbl.create 8 in
  let classify_pid pid =
    match C2c_stale.dev_ino_of_pid pid with
    | None -> C2c_stale.classify_installed installed_img pid (* -> Unknown *)
    | Some key -> (
        match Hashtbl.find_opt verdict_memo key with
        | Some v -> v
        | None ->
            let v = C2c_stale.classify_installed installed_img pid in
            Hashtbl.replace verdict_memo key v;
            v)
  in
  let is_app_server mi =
    C2c_codex_session.load_mapping
      ~instance_dir:(C2c_start.instance_dir mi.mi_name) <> None
  in
  (* Running managed instances with a live outer pid. *)
  let running =
    C2c_health_cmd.read_managed_instances ()
    |> List.filter_map (fun mi ->
         match mi.mi_pid with
         | Some pid when mi.mi_status = "running" -> Some (mi, pid)
         | _ -> None)
  in
  (* Rolling order: non-coordinators first, coordinator last so the swarm never
     goes fully dark mid-upgrade. *)
  let ordered =
    let non_coord, coord =
      List.partition (fun (mi, _) -> not (is_coord mi)) running
    in
    non_coord @ coord
  in
  (* Sequentially classify and (unless dry-run) act on each instance. *)
  let results =
    List.map
      (fun (mi, pid) ->
        let verdict = classify_pid pid in
        let eligible = force || verdict = C2c_stale.Stale in
        let action =
          if self_name = Some mi.mi_name then
            Skipped "self (cannot restart the running command's own session)"
          else if exclude_coordinator && is_coord mi then
            Skipped "coordinator excluded (--exclude-coordinator)"
          else
            match verdict with
            | C2c_stale.Unknown reason when not force ->
                Skipped (Printf.sprintf "unknown identity: %s" reason)
            | _ when not eligible -> Skipped "already current"
            | _ ->
                let has_map = is_app_server mi in
                let idle =
                  resolve_idle_for_instance ~client:mi.mi_client ~name:mi.mi_name
                    ~has_app_server_mapping:has_map
                in
                let allow = idle_allows_auto ~force ~app_server:has_map idle in
                if not has_map then
                  (* TUI/hook: outer owner-control in original pane (G2). *)
                  if not allow then
                    Guided (Printf.sprintf "c2c restart %s" mi.mi_name)
                  else if dry_run then Would_restart
                  else begin
                    if output_mode = Human then
                      Printf.eprintf
                        "[restart-stale] requesting outer owner restart for '%s'...
%!"
                        mi.mi_name;
                    request_outer_owner_restart ~name:mi.mi_name ~force
                      ~timeout_s ~outer_pid:pid
                  end
                else if not allow then
                  Skipped
                    (Printf.sprintf "idle contract %s (fail closed; use --force)"
                       (C2c_idle_contract.idle_state_to_string idle))
                else if dry_run then Would_restart
                else begin
                  if output_mode = Human then
                    Printf.eprintf
                      "[restart-stale] requesting app-server restart for '%s'...
%!"
                      mi.mi_name;
                  request_app_server_restart ~name:mi.mi_name ~force ~timeout_s
                end
              in
        (mi, verdict, action))
      ordered
  in
  let count p = List.length (List.filter p results) in
  let n_restarted = count (fun (_, _, a) -> a = Restarted) in
  let n_would = count (fun (_, _, a) -> a = Would_restart) in
  let n_guided = count (fun (_, _, a) -> match a with Guided _ -> true | _ -> false) in
  let n_failed = count (fun (_, _, a) -> match a with Failed _ -> true | _ -> false) in
  let n_skipped = count (fun (_, _, a) -> match a with Skipped _ -> true | _ -> false) in
  (match output_mode with
   | Json ->
       let action_json = function
         | Restarted -> `Assoc [ ("kind", `String "restarted") ]
         | Would_restart -> `Assoc [ ("kind", `String "would_restart") ]
         | Guided cmd -> `Assoc [ ("kind", `String "guided"); ("command", `String cmd) ]
         | Skipped r -> `Assoc [ ("kind", `String "skipped"); ("reason", `String r) ]
         | Failed r -> `Assoc [ ("kind", `String "failed"); ("reason", `String r) ]
       in
       print_json
         (`Assoc
           [ ("ok", `Bool (n_failed = 0));
             ("dry_run", `Bool dry_run);
             ("instances",
              `List
                (List.map
                   (fun (mi, verdict, action) ->
                     `Assoc
                       [ ("name", `String mi.mi_name);
                         ("client", `String mi.mi_client);
                         ("coordinator", `Bool (is_coord mi));
                         ("verdict", `String (C2c_stale.verdict_label verdict));
                         ("action", action_json action) ])
                   results));
             ("summary",
              `Assoc
                [ ("restarted", `Int n_restarted);
                  ("would_restart", `Int n_would);
                  ("needs_manual_restart", `Int n_guided);
                  ("skipped", `Int n_skipped);
                  ("failed", `Int n_failed) ]) ])
   | Human ->
       if results = [] then
         Printf.printf "No running managed instances found.\n%!"
       else begin
         Printf.printf "c2c restart-stale%s — %d running managed instance(s)\n\n"
           (if dry_run then " (dry-run)" else "") (List.length results);
         List.iter
           (fun (mi, verdict, action) ->
             let action_str =
               match action with
               | Restarted -> "restarted (app-server owner accepted)"
               | Would_restart -> "would restart (app-server)"
               | Guided cmd -> Printf.sprintf "manual: %s" cmd
               | Skipped r -> Printf.sprintf "skipped (%s)" r
               | Failed r -> Printf.sprintf "FAILED (%s)" r
             in
             Printf.printf "  %-18s %-10s %-8s %s%s\n"
               mi.mi_name mi.mi_client
               (C2c_stale.verdict_label verdict)
               action_str
               (if is_coord mi then "  [coordinator]" else ""))
           results;
         Printf.printf
           "\nSummary: %d restarted, %d would-restart, %d need manual restart, \
            %d skipped, %d failed.\n%!"
           n_restarted n_would n_guided n_skipped n_failed;
         if n_guided > 0 then
           Printf.printf
             "\n%d stale session(s) need a manual in-pane restart — run the \
              `c2c restart <name>` command shown above inside each session's \
              own tmux pane. Automated in-place restart of TUI clients is \
              tracked as follow-up idea I011.\n%!"
             n_guided
       end);
  exit (if n_failed = 0 then 0 else 1)

let restart_stale : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "restart-stale"
       ~doc:"Restart managed instances running an outdated c2c binary.")
    restart_stale_cmd

let reset_thread_cmd =
  let name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Instance name to reset.")
  in
  let thread_id =
    Cmdliner.Arg.(required & pos 1 (some string) None & info [] ~docv:"THREAD" ~doc:"Exact Codex thread/session target to resume.")
  in
  let+ name = name
  and+ thread_id = thread_id in
  exit (C2c_start.cmd_reset_thread name thread_id)

let reset_thread : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "reset-thread"
       ~doc:"Restart a managed codex/codex-headless instance onto a specific thread.")
    reset_thread_cmd

let restart_self_cmd =
  let name =
    Cmdliner.Arg.(value & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Instance name (default: \\$C2C_MCP_SESSION_ID).")
  in
  let+ name = name in
  exit (C2c_start.cmd_restart_self ?name ())

let restart_self : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v (Cmdliner.Cmd.info "restart-self" ~doc:"Signal our own managed inner client so the outer loop relaunches it. Intended for agents to reload themselves after a binary update; name falls back to \\$C2C_MCP_SESSION_ID.") restart_self_cmd
