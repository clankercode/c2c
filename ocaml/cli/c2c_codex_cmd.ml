(* c2c_codex_cmd — public command grammar for managed session shortcuts.

   Codex (app-server-backed; P1.M1.E1.T006) — four forms share ONE
   implementation path ({!C2c_codex_session.run}):
     c2c start codex ...     (canonical; wired from c2c_managed_cmd via
                              [codex_start_delegate])
     c2c codex ...           (exact shortcut for `start codex`)
     c2c new codex ...       (always a new thread + identity)
     c2c resume codex <alias> ...  (resume the thread saved for that alias)

   Kimi (B245) — `c2c new kimi` is a reduced-surface shortcut for
     `c2c start kimi --new-session` (fresh identity + session; never silently
     resumes). There is no app-server path for kimi; dispatch is plain
     {!C2c_start.cmd_start}. `c2c resume` remains codex-only for now.

   Everything after a literal `--` is forwarded to the client frontend argv
   except reserved `--c2c:*` wrapper controls. B221 initially defines
   `--c2c:name NAME` / `--c2c:name=NAME`. *)

open Cmdliner

(* ------------------------- shared flag terms ------------------------------ *)

let alias_t =
  Arg.(value & opt (some string) None & info [ "alias" ] ~docv:"ALIAS"
    ~doc:"Optional human-readable override for the display/routing alias. For \
          codex, when omitted a stable alias is derived from the Codex session \
          id (does NOT replace the authoritative thread id; a conflict with a \
          differently-owned saved alias is rejected). For kimi, when omitted a \
          fresh generated identity is used.")

let yolo_t =
  Arg.(value & flag & info [ "yolo" ]
    ~doc:"DANGER (codex only): forward codex \
          --dangerously-bypass-approvals-and-sandbox (disables ALL approvals \
          and the sandbox for this session). Prints a conspicuous warning and \
          is never persisted into later resumes. Managed kimi already launches \
          with --yolo; the flag is rejected for `c2c new kimi`.")

let thread_id_t =
  Arg.(value & opt (some string) None & info [ "thread-id" ] ~docv:"ID"
    ~doc:"Exact Codex thread id to select (escape hatch; codex only). A \
          conflict with the saved thread for the alias is rejected rather than \
          guessed. Rejected for `c2c new kimi`.")

(* pos_all captures every positional token, including whatever follows a literal
   `--` (cmdliner ends option parsing there). [strip_leading_client] /
   [strip_leading_client_alias] peel the fixed leading positionals and an
   optional `--` separator, leaving the client passthrough plus any reserved
   namespaced c2c controls. *)
let positionals_t =
  Arg.(value & pos_all string [] & info [] ~docv:"ARG"
    ~doc:"Positional args. First arg is the client (`codex` or `kimi` for \
          `c2c new`). Everything after a literal `--` is forwarded to the \
          client frontend except reserved namespaced controls. Use \
          `--c2c:name NAME` to set the managed name from an alias ending in \
          `--` (e.g. `c2c new codex -- --model MODEL --c2c:name my-codex`, \
          `c2c new kimi -- --model MODEL --c2c:name my-kimi`).")

let drop_sep = C2c_codex_session.drop_sep
let strip_leading_client = C2c_codex_session.split_client
let strip_leading_client_alias = C2c_codex_session.split_client_alias

let require_codex_client = function
  | Some "codex" -> ()
  | Some other ->
      Printf.eprintf
        "error: only 'codex' is supported here (got '%s'). Try `c2c start %s`.\n%!"
        other other;
      exit 1
  | None ->
      Printf.eprintf "error: missing client. Usage includes `codex`, e.g. `c2c new codex`.\n%!";
      exit 1

(* B245: `c2c new` accepts codex | kimi. codex stays on the app-server path;
   kimi is a thin --new-session wrapper around cmd_start. *)
let require_new_client = function
  | Some ("codex" | "kimi" as c) -> c
  | Some other ->
      Printf.eprintf
        "error: `c2c new` supports 'codex' and 'kimi' (got '%s'). \
         Try `c2c start %s` (or `c2c start %s --new-session`).\n%!"
        other other other;
      exit 1
  | None ->
      Printf.eprintf
        "error: missing client. Usage: `c2c new codex` or `c2c new kimi`.\n%!";
      exit 1

let refuse_codex_only_flags ~client ~yolo ~thread_id =
  (match thread_id with
   | Some id when String.trim id <> "" && client <> "codex" ->
       Printf.eprintf
         "error: --thread-id is codex-only (got client '%s').\n%!" client;
       exit 1
   | _ -> ());
  if yolo && client <> "codex" then begin
    Printf.eprintf
      "error: --yolo is codex-only on `c2c new` (got client '%s'). \
       Managed kimi already launches with --yolo.\n%!"
      client;
    exit 1
  end

let resolve_namespaced_name ~command ~allow_name ~existing extra_args =
  match C2c_codex_session.resolve_namespaced_passthrough
          ~allow_name ~existing_name:existing extra_args with
  | Error msg ->
      Printf.eprintf "error: %s (%s)\n%!" msg command;
      exit 1
  | Ok resolved -> resolved

(* --------------------------- fallback thunks ------------------------------ *)

(* The hook-backed (legacy) launch, invoked when the app-server path is not
   engaged or gracefully falls back after a version/capability diagnostic. *)
let hook_fallback ~(mode : C2c_codex_session.launch_mode) ~(alias_override : string option)
    ?(model_override : string option) () : extra_args:string list -> unit -> int =
  (* Default swarm onboarding parity: a `c2c codex`/`new codex` launched agent
     still joins the social room like `c2c start codex` does. *)
  let auto_join_rooms = C2c_swarm_config.swarm_config_social_room () in
  fun ~extra_args () ->
    match mode with
    | C2c_codex_session.Resume alias ->
        C2c_start.cmd_start ~client:"codex" ~name:alias ~extra_args
          ?model_override ~auto_join_rooms
          ~opencode_plugin_embedded:"" ()
    | New ->
        let name = match alias_override with
          | Some a -> a
          | None -> C2c_start.default_name "codex" in
        C2c_start.cmd_start ~client:"codex" ~name ~extra_args
          ?alias_override ?model_override ~new_session:true ~auto_join_rooms
          ~alias_from_auto_gen:(alias_override = None)
          ~opencode_plugin_embedded:"" ()
    | Start ->
        let name = match alias_override with
          | Some a -> a
          | None -> C2c_start.default_name "codex" in
        C2c_start.cmd_start ~client:"codex" ~name ~extra_args
          ?alias_override ?model_override ~auto_join_rooms
          ~alias_from_auto_gen:(alias_override = None)
          ~opencode_plugin_embedded:"" ()

let dispatch ~(mode : C2c_codex_session.launch_mode) ~alias_override ~thread_id
    ~yolo ?model_override ~extra_args () : int =
  C2c_codex_session.run ~mode ?alias_override ?thread_id ~yolo
    ~extra_args ?model_override
    ~fallback:(hook_fallback ~mode ~alias_override ?model_override ())
    ()

(* -------------------------------- codex ----------------------------------- *)

let codex_term =
  let open Term.Syntax in
  let+ alias_override = alias_t
  and+ yolo = yolo_t
  and+ thread_id = thread_id_t
  and+ positionals = positionals_t in
  let extra_args = drop_sep positionals in
  let alias_override, extra_args =
    resolve_namespaced_name ~command:"c2c codex" ~allow_name:true
      ~existing:alias_override extra_args
  in
  exit (dispatch ~mode:C2c_codex_session.Start ~alias_override ~thread_id ~yolo
          ~extra_args ())

let codex : unit Cmd.t =
  Cmd.v (Cmd.info "codex"
           ~doc:"Start a managed Codex session (shortcut for `c2c start codex`)."
           ~man:[ `S "DESCRIPTION"
                ; `P "Shortcut for $(b,c2c start codex) with the same Codex session \
                      semantics and defaults (generated identity, $(b,--yolo)). The \
                      app-server transport (identity + auto-delivery of inbound c2c \
                      mail + auto-turn) is the default and only managed path for a \
                      supported Codex; it falls back to the hook-backed launch \
                      automatically if Codex is too old or the app-server fails to \
                      start. Exposes a reduced flag surface — pass codex options after \
                      $(b,--), e.g. $(b,c2c codex -- --model MODEL); use \
                      $(b,c2c start codex) for the full managed flags."
                ; `P "The $(b,[mcp_servers.c2c]) block in $(b,~/.codex/config.toml) \
                      is optional (B256): managed Codex delivers via the \
                      app-server + hooks + CLI, so a missing block does not block \
                      the launch. Run $(b,c2c install codex --with-mcp) if you \
                      also want the c2c MCP tools inside Codex. Only a $(i,stale) \
                      block (present but unrunnable) is refused up front with a \
                      repair message — run $(b,c2c install codex --with-mcp) to \
                      fix, or $(b,C2C_CODEX_SKIP_MCP_PREFLIGHT=1) to bypass." ])
    codex_term

(* --------------------------------- new ------------------------------------ *)

(* B245: kimi path — equivalent to `c2c start kimi --new-session` with the
   reduced `c2c new` flag surface + `--c2c:name` passthrough. Always mints a
   fresh managed identity when --alias/--c2c:name are omitted. *)
let dispatch_new_kimi ~alias_override ~extra_args () : int =
  let auto_join_rooms = C2c_swarm_config.swarm_config_social_room () in
  let name =
    match alias_override with
    | Some a -> a
    | None -> C2c_start.default_name "kimi"
  in
  C2c_start.cmd_start ~client:"kimi" ~name ~extra_args
    ?alias_override ~new_session:true ~auto_join_rooms
    ~alias_from_auto_gen:(alias_override = None)
    ~opencode_plugin_embedded:"" ()

let new_term =
  let open Term.Syntax in
  let+ alias_override = alias_t
  and+ yolo = yolo_t
  and+ thread_id = thread_id_t
  and+ positionals = positionals_t in
  let (client_opt, extra_args) = strip_leading_client positionals in
  let client = require_new_client client_opt in
  refuse_codex_only_flags ~client ~yolo ~thread_id;
  let alias_override, extra_args =
    resolve_namespaced_name ~command:("c2c new " ^ client) ~allow_name:true
      ~existing:alias_override extra_args
  in
  match client with
  | "kimi" ->
      exit (dispatch_new_kimi ~alias_override ~extra_args ())
  | "codex" ->
      exit (dispatch ~mode:C2c_codex_session.New ~alias_override ~thread_id ~yolo
              ~extra_args ())
  | other ->
      (* require_new_client already filters; keep exhaustiveness defensive. *)
      Printf.eprintf "error: internal: unexpected client '%s' for `c2c new`.\n%!" other;
      exit 1

let new_cmd : unit Cmd.t =
  Cmd.v (Cmd.info "new"
           ~doc:"Start a NEW managed session (codex|kimi): always a fresh session + identity."
           ~man:[ `S "DESCRIPTION"
                ; `P "Always starts a fresh managed session (never silently \
                      resumes a prior transcript). Supported clients: \
                      $(b,codex) and $(b,kimi). With no $(b,--alias)/$(b,--c2c:name), \
                      a new generated identity is used. Reusing an existing \
                      managed name (via $(b,--alias) or $(b,--c2c:name)) keeps that \
                      name but discards the saved session. Forward client options \
                      after $(b,--). Aliases ending in $(b,--) can set the managed \
                      name with $(b,--c2c:name NAME), e.g. \
                      $(b,c2c new codex -- --model MODEL --c2c:name my-codex) or \
                      $(b,c2c new kimi -- --model MODEL --c2c:name my-kimi)."
                ; `P "$(b,c2c new codex) uses the Codex app-server transport when \
                      available (same path as $(b,c2c start codex) with a forced \
                      fresh thread). $(b,c2c new kimi) is a reduced-surface \
                      shortcut for $(b,c2c start kimi --new-session)."
                ; `S "PREREQUISITE"
                ; `P "For codex: the machine-wide $(b,[mcp_servers.c2c]) block in \
                      $(b,~/.codex/config.toml) is optional (B256) — managed \
                      Codex delivers via the app-server + hooks + CLI. Run \
                      $(b,c2c install codex --with-mcp) if you also want the c2c \
                      MCP tools inside Codex. Only a $(i,stale) block is refused \
                      up front; repair with $(b,c2c install codex --with-mcp) or \
                      set $(b,C2C_CODEX_SKIP_MCP_PREFLIGHT=1) to bypass."
                ; `P "For kimi: $(b,c2c install kimi) must have run so the hooks + \
                      /c2c skill are configured under $(b,~/.kimi-code/) (add \
                      $(b,--with-mcp) for the MCP tools)." ])
    new_term

(* ------------------------------- resume ----------------------------------- *)

let resume_term =
  let open Term.Syntax in
  let+ yolo = yolo_t
  and+ thread_id = thread_id_t
  and+ positionals = positionals_t in
  let (client, alias, extra_args) = strip_leading_client_alias positionals in
  require_codex_client client;
  let _, extra_args =
    resolve_namespaced_name ~command:"c2c resume codex" ~allow_name:false
      ~existing:None extra_args
  in
  (match alias with
   | Some a when String.length a > 0 && a.[0] = '-' ->
       (* Guard against a mis-parsed flag being taken as the alias (e.g.
          `c2c resume codex -- --model x` with no alias). *)
       Printf.eprintf "error: `c2c resume codex` requires an ALIAS before any `--`/options \
                       (got '%s'). Usage: c2c resume codex <alias> [-- codex-options...]\n%!" a;
       exit 1
   | Some a ->
       exit (dispatch ~mode:(C2c_codex_session.Resume a) ~alias_override:None
               ~thread_id ~yolo ~extra_args ())
   | None ->
       Printf.eprintf "error: `c2c resume codex` requires an ALIAS. \
                       Usage: c2c resume codex <alias> [-- codex-options...]\n%!";
       exit 1)

let resume_cmd : unit Cmd.t =
  Cmd.v (Cmd.info "resume"
           ~doc:"Resume the saved managed session for an alias (codex)."
           ~man:[ `S "DESCRIPTION"
                ; `P "Resumes the Codex thread saved for the given c2c alias. Use \
                      $(b,--thread-id ID) to select an exact thread; conflicts are \
                      rejected rather than guessed."
                ; `P "Like $(b,c2c new codex), the machine-wide \
                      $(b,[mcp_servers.c2c]) block in $(b,~/.codex/config.toml) is \
                      optional (B256); only a $(i,stale) block is refused up front \
                      with a repair message — run $(b,c2c install codex --with-mcp) \
                      to fix, or $(b,C2C_CODEX_SKIP_MCP_PREFLIGHT=1) to bypass." ])
    resume_term

(* Re-exported for c2c_managed_cmd so `c2c start codex` routes to the same path. *)
let start_delegate ~alias_override ~thread_id ~yolo ?model_override
    ~extra_args ~fallback () : int =
  C2c_codex_session.run ~mode:C2c_codex_session.Start ?alias_override ?thread_id
    ~yolo ?model_override ~extra_args ~fallback ()
