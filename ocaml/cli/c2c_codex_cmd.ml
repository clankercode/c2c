(* c2c_codex_cmd — public command grammar for app-server-backed Codex sessions
   (P1.M1.E1.T006).

   Four forms share ONE implementation path ({!C2c_codex_session.run}):
     c2c start codex ...     (canonical; wired from c2c_managed_cmd via
                              [codex_start_delegate])
     c2c codex ...           (exact shortcut for `start codex`)
     c2c new codex ...       (always a new thread + identity)
     c2c resume codex <alias> ...  (resume the thread saved for that alias)

   Everything after a literal `--` is forwarded to the stock `codex --remote`
   frontend argv except reserved `--c2c:*` wrapper controls. B221 initially
   defines `--c2c:name NAME` / `--c2c:name=NAME`. *)

open Cmdliner

(* ------------------------- shared flag terms ------------------------------ *)

let alias_t =
  Arg.(value & opt (some string) None & info [ "alias" ] ~docv:"ALIAS"
    ~doc:"Optional human-readable override for the display/routing alias. When \
          omitted a stable alias is derived from the Codex session id. Does NOT \
          replace the authoritative Codex thread id; a conflict with a \
          differently-owned saved alias is rejected.")

let yolo_t =
  Arg.(value & flag & info [ "yolo" ]
    ~doc:"DANGER: forward codex --dangerously-bypass-approvals-and-sandbox \
          (disables ALL approvals and the sandbox for this session). Prints a \
          conspicuous warning and is never persisted into later resumes.")

let thread_id_t =
  Arg.(value & opt (some string) None & info [ "thread-id" ] ~docv:"ID"
    ~doc:"Exact Codex thread id to select (escape hatch). A conflict with the \
          saved thread for the alias is rejected rather than guessed.")

(* pos_all captures every positional token, including whatever follows a literal
   `--` (cmdliner ends option parsing there). [strip_leading_client] /
   [strip_leading_client_alias] peel the fixed leading positionals and an
   optional `--` separator, leaving the codex passthrough plus any reserved
   namespaced c2c controls. *)
let positionals_t =
  Arg.(value & pos_all string [] & info [] ~docv:"ARG"
    ~doc:"Positional args. Everything after a literal `--` is forwarded to the \
          codex frontend except reserved namespaced controls. Use `--c2c:name NAME` \
          to set the managed name from an alias ending in `--` (e.g. \
          `c2c new codex -- --model MODEL --c2c:name my-codex`).")

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
                      $(b,c2c start codex) for the full managed flags." ])
    codex_term

(* --------------------------------- new ------------------------------------ *)

let new_term =
  let open Term.Syntax in
  let+ alias_override = alias_t
  and+ yolo = yolo_t
  and+ thread_id = thread_id_t
  and+ positionals = positionals_t in
  let (client, extra_args) = strip_leading_client positionals in
  require_codex_client client;
  let alias_override, extra_args =
    resolve_namespaced_name ~command:"c2c new codex" ~allow_name:true
      ~existing:alias_override extra_args
  in
  exit (dispatch ~mode:C2c_codex_session.New ~alias_override ~thread_id ~yolo
          ~extra_args ())

let new_cmd : unit Cmd.t =
  Cmd.v (Cmd.info "new"
           ~doc:"Start a NEW managed session (codex): always a fresh thread + identity."
           ~man:[ `S "DESCRIPTION"
                ; `P "Always creates a new Codex thread and a new c2c identity; \
                      never silently resumes. Forward codex options after $(b,--). \
                      Aliases ending in $(b,--) can set the managed name with \
                      $(b,--c2c:name NAME), e.g. $(b,c2c new codex -- --model MODEL \
                      --c2c:name my-codex)." ])
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
                      rejected rather than guessed." ])
    resume_term

(* Re-exported for c2c_managed_cmd so `c2c start codex` routes to the same path. *)
let start_delegate ~alias_override ~thread_id ~yolo ?model_override
    ~extra_args ~fallback () : int =
  C2c_codex_session.run ~mode:C2c_codex_session.Start ?alias_override ?thread_id
    ~yolo ?model_override ~extra_args ~fallback ()
