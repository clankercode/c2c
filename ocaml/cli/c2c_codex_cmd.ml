(* c2c_codex_cmd — public command grammar for app-server-backed Codex sessions
   (P1.M1.E1.T006).

   Four forms share ONE implementation path ({!C2c_codex_session.run}):
     c2c start codex ...     (canonical; wired from c2c_managed_cmd via
                              [codex_start_delegate])
     c2c codex ...           (exact shortcut for `start codex`)
     c2c new codex ...       (always a new thread + identity)
     c2c resume codex <alias> ...  (resume the thread saved for that alias)

   Everything after a literal `--` is forwarded verbatim to the stock
   `codex --remote` frontend argv and is NEVER parsed as a c2c flag. *)

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

let app_server_t =
  Arg.(value & flag & info [ "app-server" ]
    ~doc:"Use the app-server-backed remote-TUI transport instead of the \
          hook-backed launch. Also enabled by C2C_CODEX_APP_SERVER=1. Falls \
          back to hooks with an actionable message if the local codex is too old.")

(* pos_all captures every positional token, including whatever follows a literal
   `--` (cmdliner ends option parsing there). [strip_leading_client] /
   [strip_leading_client_alias] peel the fixed leading positionals and an
   optional `--` separator, leaving the verbatim codex passthrough. *)
let positionals_t =
  Arg.(value & pos_all string [] & info [] ~docv:"ARG"
    ~doc:"Positional args. Everything after a literal `--` is forwarded verbatim \
          to the codex frontend (e.g. `c2c new codex -- --model gpt-5.3-codex-spark`).")

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

(* --------------------------- fallback thunks ------------------------------ *)

(* The hook-backed (legacy) launch, invoked when the app-server path is not
   engaged or gracefully falls back after a version/capability diagnostic. *)
let hook_fallback ~(mode : C2c_codex_session.launch_mode) ~(alias_override : string option)
    () : extra_args:string list -> unit -> int =
  fun ~extra_args () ->
    match mode with
    | C2c_codex_session.Resume alias ->
        C2c_start.cmd_start ~client:"codex" ~name:alias ~extra_args
          ~opencode_plugin_embedded:"" ()
    | New ->
        let name = match alias_override with
          | Some a -> a
          | None -> C2c_start.default_name "codex" in
        C2c_start.cmd_start ~client:"codex" ~name ~extra_args
          ?alias_override ~new_session:true
          ~alias_from_auto_gen:(alias_override = None)
          ~opencode_plugin_embedded:"" ()
    | Start ->
        let name = match alias_override with
          | Some a -> a
          | None -> C2c_start.default_name "codex" in
        C2c_start.cmd_start ~client:"codex" ~name ~extra_args
          ?alias_override
          ~alias_from_auto_gen:(alias_override = None)
          ~opencode_plugin_embedded:"" ()

let dispatch ~(mode : C2c_codex_session.launch_mode) ~alias_override ~thread_id
    ~yolo ~app_server ~extra_args () : int =
  C2c_codex_session.run ~mode ?alias_override ?thread_id ~yolo ~app_server
    ~extra_args
    ~fallback:(hook_fallback ~mode ~alias_override ())
    ()

(* -------------------------------- codex ----------------------------------- *)

let codex_term =
  let open Term.Syntax in
  let+ alias_override = alias_t
  and+ yolo = yolo_t
  and+ thread_id = thread_id_t
  and+ app_server = app_server_t
  and+ positionals = positionals_t in
  let extra_args = drop_sep positionals in
  exit (dispatch ~mode:C2c_codex_session.Start ~alias_override ~thread_id ~yolo
          ~app_server ~extra_args ())

let codex : unit Cmd.t =
  Cmd.v (Cmd.info "codex"
           ~doc:"Start a managed Codex session (exact shortcut for `c2c start codex`)."
           ~man:[ `S "DESCRIPTION"
                ; `P "Identical to $(b,c2c start codex): launches an interactive \
                      Codex frontend with a generated c2c identity. Pass codex \
                      options after $(b,--), e.g. $(b,c2c codex -- --model MODEL)." ])
    codex_term

(* --------------------------------- new ------------------------------------ *)

let new_term =
  let open Term.Syntax in
  let+ alias_override = alias_t
  and+ yolo = yolo_t
  and+ thread_id = thread_id_t
  and+ app_server = app_server_t
  and+ positionals = positionals_t in
  let (client, extra_args) = strip_leading_client positionals in
  require_codex_client client;
  exit (dispatch ~mode:C2c_codex_session.New ~alias_override ~thread_id ~yolo
          ~app_server ~extra_args ())

let new_cmd : unit Cmd.t =
  Cmd.v (Cmd.info "new"
           ~doc:"Start a NEW managed session (codex): always a fresh thread + identity."
           ~man:[ `S "DESCRIPTION"
                ; `P "Always creates a new Codex thread and a new c2c identity; \
                      never silently resumes. Forward codex options after $(b,--), \
                      e.g. $(b,c2c new codex -- --model gpt-5.3-codex-spark)." ])
    new_term

(* ------------------------------- resume ----------------------------------- *)

let resume_term =
  let open Term.Syntax in
  let+ yolo = yolo_t
  and+ thread_id = thread_id_t
  and+ app_server = app_server_t
  and+ positionals = positionals_t in
  let (client, alias, extra_args) = strip_leading_client_alias positionals in
  require_codex_client client;
  (match alias with
   | Some a ->
       exit (dispatch ~mode:(C2c_codex_session.Resume a) ~alias_override:None
               ~thread_id ~yolo ~app_server ~extra_args ())
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
let start_delegate ~alias_override ~thread_id ~yolo ~app_server ~extra_args
    ~fallback () : int =
  C2c_codex_session.run ~mode:C2c_codex_session.Start ?alias_override ?thread_id
    ~yolo ~app_server ~extra_args ~fallback ()
