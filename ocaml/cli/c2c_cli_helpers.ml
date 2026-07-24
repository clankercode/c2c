(* c2c_cli_helpers — shared CLI helper functions.
   Extracted from c2c.ml so extracted subcommand modules can share them
   without circular dependencies on the main executable module. *)

open Cmdliner.Term.Syntax
open C2c_mcp
module Relay = Relay
open C2c_types
open C2c_commands
open C2c_utils
open C2c_agent
module Repo_fp = C2c_repo_fp

let debug_enabled =
  match Sys.getenv_opt "C2C_MCP_DEBUG" with
  | Some v ->
      let n = String.lowercase_ascii (String.trim v) in
      not (List.mem n [ "0"; "false"; "no"; "" ])
  | None -> false

let ( // ) = Filename.concat

let rec rm_rf path =
  if Sys.is_directory path then (
    Array.iter (fun entry -> rm_rf (path // entry)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

(* Resolve the Claude config dir.
   Prefers CLAUDE_CONFIG_DIR if set, otherwise resolves ~/.claude as a symlink
   (so profile dirs like ~/.claude-mm/ work via the symlink). *)
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

(* --- broker root resolution (delegated to C2c_utils) ---------------------- *)

let resolve_broker_root = C2c_utils.resolve_broker_root

let resolve_effective_broker_root ?(explicit_root : string option = None) ~cross_repo () =
  match explicit_root with
  | Some r when String.trim r <> "" -> String.trim r
  | _ ->
      if cross_repo then Repo_fp.resolve_sessions_broker_root ()
      else resolve_broker_root ()

let broker_root_from_env () =
  match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
  | Some path when String.trim path <> "" -> Some path
  | _ -> None

let git_repo_toplevel () =
  match Git_helpers.git_repo_toplevel () with
  | Some line when Sys.is_directory line -> Some line
  | _ -> None

let git_shorthash () =
  match Git_helpers.git_shorthash () with
  | Some line when int_of_string_opt line = None -> Some line
  | _ -> None

(* B287: the parseable, primary version identity — BUILD time, not the wall
   clock at invocation. Used by Cmdliner's [~version], the bare-`c2c` landing,
   and (via [version_line_with_clock]) the human `--version` output. The
   compile-time git SHA is embedded (#420: no per-invocation `git rev-parse`
   shell-out). B289 should reuse these helpers so `c2c version` matches. *)
let version_string () = Version.build_identity ()

(* B287: `c2c --version` line — build-time identity plus a demarcated,
   secondary "now" clock (kept for clock-skew diagnostics, off to the side). *)
let version_line_with_clock () = Version.display_with_clock ()

let find_python_script script =
  match git_repo_toplevel () with
  | Some dir ->
      let path = dir // script in
      if Sys.file_exists path then Some path else None
  | None -> None

(* --- session / alias resolution ------------------------------------------- *)

(* --- init-fallback session statefile (#10) ---------------------------------
   When `c2c init` cannot derive a session id from the environment it
   synthesizes one and persists it to <broker_root>/default-session.json so
   that later `c2c` invocations in the same context (e.g. a Claude/Codex shell
   tool with zero exported env vars) resolve the same identity.

   This fallback is LAST RESORT and CLI-ONLY:
   - an env-derived session id (C2C_MCP_SESSION_ID or a client-native key such
     as CLAUDE_CODE_SESSION_ID) always wins — the fallback can never shadow it;
   - it is deliberately NOT wired into C2c_mcp.session_id_from_env, so the MCP
     server never picks it up (two MCP servers in one repo would otherwise
     silently share/steal the CLI session);
   - the file holds a single identity per repo/broker root. Two CLI-only
     agents sharing a repo will collide — last `c2c init` wins;
   - a stale statefile (session no longer in the broker registry) is ignored. *)

(* #23: shared with `c2c doctor hooks` via C2c_identity_candidates so both
   surfaces read the SAME statefile identity and present the SAME candidate
   list. Delegated (not duplicated) to keep them in lockstep. *)
let session_statefile_path = C2c_identity_candidates.session_statefile_path

let read_session_statefile = C2c_identity_candidates.read_session_statefile

let read_session_statefile_info =
  C2c_identity_candidates.read_session_statefile_info

(* Best-effort, non-fatal: identity persistence must never break init. *)
let write_session_statefile ~broker_root ~session_id ~alias ~client =
  let path = session_statefile_path ~broker_root in
  let json =
    `Assoc
      [ ("session_id", `String session_id)
      ; ("alias", `String alias)
      ; ("client", (match client with Some c -> `String c | None -> `Null))
      ; ("created_at", `String (C2c_time.now_iso8601_utc ()))
      ]
  in
  (try
     C2c_mcp.mkdir_p broker_root;
     ignore (C2c_io.write_file_atomic path (Yojson.Safe.pretty_to_string json ^ "\n"))
   with _ -> ())

let statefile_session_registered ~broker_root sid =
  try
    let broker = C2c_mcp.Broker.create ~root:broker_root in
    List.exists
      (fun (r : C2c_mcp.registration) -> r.session_id = sid)
      (C2c_mcp.Broker.list_registrations broker)
  with _ -> false

(** Normalize client labels so codex-app-server / codex-headless compare equal
    to the codex- reserved alias prefix. *)
let normalize_client_kind s =
  match String.lowercase_ascii (String.trim s) with
  | "codex-app-server" | "codex-headless" -> "codex"
  | other -> other

(** If [alias] starts with a reserved client prefix (e.g. "codex-"), return the
    client kind without the trailing hyphen ("codex"). *)
let alias_reserved_client_kind alias =
  let a = String.lowercase_ascii (String.trim alias) in
  let rec loop = function
    | [] -> None
    | p :: rest ->
        if String.starts_with ~prefix:p a then
          let kind = String.sub p 0 (String.length p - 1) in
          Some kind
        else loop rest
  in
  loop C2c_blocklist.reserved_client_prefixes

(* B284: refuse sticky default-session.json when its recorded / registered
   client clearly belongs to a different host client than the one we just
   detected (Cursor shell must not inherit a grok-* / codex-* sticky row). *)
let statefile_compatible_with_intended ~broker_root ~intended sid =
  match intended with
  | None -> true
  | Some want_raw ->
      let want = normalize_client_kind want_raw in
      let info_client =
        match read_session_statefile_info ~broker_root with
        | Some info when info.session_id = sid ->
            Option.map normalize_client_kind info.client
        | _ -> None
      in
      let reg_client, reg_alias_kind =
        try
          let broker = C2c_mcp.Broker.create ~root:broker_root in
          match
            List.find_opt
              (fun (r : C2c_mcp.registration) -> r.session_id = sid)
              (C2c_mcp.Broker.list_registrations broker)
          with
          | Some r ->
              ( Option.map normalize_client_kind r.client_type
              , alias_reserved_client_kind r.alias )
          | None -> (None, None)
        with _ -> (None, None)
      in
      let conflict_info =
        match info_client with
        | Some have when have <> want -> true
        | _ -> false
      in
      let conflict_reg =
        match reg_client with
        | Some have when have <> want -> true
        | _ -> false
      in
      let conflict_alias =
        match reg_alias_kind with
        | Some have when have <> want -> true
        | _ -> false
      in
      not (conflict_info || conflict_reg || conflict_alias)

let session_fallback_note_emitted = ref false

(* Resolve the persisted fallback session, validated against the broker
   registry. Emits a one-line stderr note (once per process) when used so
   commands like `whoami` say where the identity came from. *)
let session_id_from_statefile () =
  let broker_root = C2c_utils.resolve_broker_root () in
  match read_session_statefile ~broker_root with
  | None -> None
  | Some sid ->
      if
        statefile_session_registered ~broker_root sid
        && statefile_compatible_with_intended ~broker_root
             ~intended:(C2c_mcp.inferred_client_type_from_env ()) sid
      then begin
        if not !session_fallback_note_emitted then begin
          session_fallback_note_emitted := true;
          Printf.eprintf "note: session resolved from %s (c2c init fallback)\n%!"
            (session_statefile_path ~broker_root)
        end;
        Some sid
      end else begin
        if debug_enabled then
          Printf.eprintf
            "[DEBUG session_id_from_statefile] stale or foreign-client statefile \
             (session %s) — ignored\n%!"
            sid;
        None
      end

(* #26 (subsumes #21): the persisted default-session.json fallback is the CLI's
   last-resort identity. The old gate returned it *silently* whenever it was
   still registered — but a registered-but-background/dead session (e.g. a Grok
   registration with pid=None) then won silently and WRONG, misattributing DMs
   to a stale alias. Resolve it under a "fail-closed-on-ambiguity,
   sole-corroborated-success" gate instead:
     - [`Stale]           statefile absent or its session is not in the registry
                          (unchanged: resolves to None).
     - [`Sole sid]        the statefile session is the ONLY registration (or all
                          rows share its sid) — the legitimate single-session
                          human-CLI case; caller returns it but escalates the
                          note to a loud WARN.
     - [`Ambiguous others] at least one OTHER registration exists besides the
                          statefile's — the dangerous multi-session case; caller
                          returns None and fails closed with a candidate list.
   Behaviour is NOT changed for the [`Sole]/[`Stale] cases; only the previously
   silent multi-session case now fails closed. The escape hatch
   [C2C_ALLOW_DEFAULT_SESSION] restores the old silent-if-registered behaviour. *)
let resolve_statefile_session_gated ~broker_root :
    [ `Sole of string
    | `Client_matched of string
    | `Ambiguous of C2c_mcp.registration list
    | `Stale ] =
  match read_session_statefile ~broker_root with
  | None -> `Stale
  | Some sid ->
      let regs =
        try
          let broker = C2c_mcp.Broker.create ~root:broker_root in
          C2c_mcp.Broker.list_registrations broker
        with _ -> []
      in
      let sid_registered =
        List.exists (fun (r : C2c_mcp.registration) -> r.session_id = sid) regs
      in
      if not sid_registered then `Stale
      else if
        not
          (statefile_compatible_with_intended ~broker_root
             ~intended:(C2c_mcp.inferred_client_type_from_env ()) sid)
      then begin
        (* B284: foreign-client sticky — treat as absent so Cursor/Grok shells
           do not silently adopt another client's sole registration. *)
        if debug_enabled then
          Printf.eprintf
            "[DEBUG resolve_statefile_session_gated] foreign-client statefile \
             sid=%s — failing closed\n%!"
            sid;
        `Stale
      end
      else begin
        (* Deliberately LIVENESS-BLIND: any other registration → ambiguous.
           Do NOT "fix" this to exclude dead/stale others — liveness is an
           unreliable gate signal (pidless/CLI regs report alive; most stale
           rows are Unknown, not dead), so excluding them would resurrect the
           #26 silent-misattribution. Liveness is surfaced in the candidate
           printout only; C2C_ALLOW_DEFAULT_SESSION is the escape hatch.

           B284 exception: when the ambient client is known AND the statefile
           is compatible with that client, the sticky row is an intentional
           pin for *this* shell (e.g. Cursor init beside a leftover grok
           registration). Prefer it over fail-closed ambiguity so whoami
           works without a manual C2C_MCP_SESSION_ID. *)
        let others =
          List.filter
            (fun (r : C2c_mcp.registration) -> r.session_id <> sid)
            regs
        in
        match others with
        | [] -> `Sole sid
        | _ ->
            (match C2c_mcp.inferred_client_type_from_env () with
             | Some _ -> `Client_matched sid
             | None -> `Ambiguous others)
      end

let allow_default_session_env () =
  match Sys.getenv_opt "C2C_ALLOW_DEFAULT_SESSION" with
  | Some v ->
      (match String.lowercase_ascii (String.trim v) with
       | "1" | "true" | "yes" -> true
       | _ -> false)
  | None -> false

(* Enumerate broker registrations as identity candidates: (alias, session_id,
   client, registered_by, liveness). Used to fail closed with an actionable
   list when identity resolution is ambiguous or absent; a later doctor
   detector reuses this same shape. Best-effort — [] on any broker error. *)
let candidate_registrations = C2c_identity_candidates.candidate_registrations

let render_candidate_registration =
  C2c_identity_candidates.render_candidate_registration

(* Fix-step lines that list the broker's registrations as identity candidates,
   with the concrete env-var fix. Empty when the broker has no registrations
   (nothing to disambiguate against). *)
let candidate_identity_fix_steps ~broker_root =
  match candidate_registrations ~broker_root with
  | [] -> []
  | cands ->
      ("candidate identities registered in this broker:"
       :: List.map
            (fun c -> "  " ^ render_candidate_registration c)
            cands)
      @ [ "export C2C_MCP_SESSION_ID=<one of the above>   # pick YOUR session" ]

(* B172: Codex app-server shell tools often export only CODEX_THREAD_ID (the
   live thread UUID). Managed identity markers stay frontend-scoped on purpose
   (B137 nested-theft guard), so bare `c2c whoami`/`send` would otherwise look
   up the unregistered thread id. Prefer, in order:
   1. durable thread→managed map (codex-session.json / config.json)
   2. sole alive codex-app-server registration (first-turn race before the
      deliver loop persists the discovered thread — only when unambiguous) *)
(* First-turn race helper: only adopt a sole alive app-server identity when
   unambiguous AND that instance is not already bound to a *different* thread.
   Never steals a thread that is itself already registered (vanilla codex). *)
let sole_alive_codex_app_server_session ~broker_root ~thread_id =
  try
    let broker = C2c_mcp.Broker.create ~root:broker_root in
    let regs = C2c_mcp.Broker.list_registrations broker in
    if List.exists (fun (r : C2c_mcp.registration) -> r.session_id = thread_id) regs
    then None
    else
      let candidates =
        List.filter
          (fun (r : C2c_mcp.registration) ->
            r.client_type = Some "codex-app-server"
            && C2c_mcp.Broker.registration_is_alive r)
          regs
      in
      match candidates with
      | [ r ] ->
          (* If this managed instance already has a durable thread that is NOT
             ours, do not adopt it (another conversation owns that unit). *)
          let instances_dir =
            C2c_mcp_helpers_post_broker.managed_instances_dir ()
          in
          let mapping_path =
            Filename.concat (Filename.concat instances_dir r.alias)
              "codex-session.json"
          in
          let bound_other_thread =
            try
              if not (Sys.file_exists mapping_path) then false
              else
                match Yojson.Safe.from_file mapping_path with
                | `Assoc fields ->
                    (match List.assoc_opt "thread_id" fields with
                     | Some (`String t) ->
                         let t = String.trim t in
                         t <> "" && t <> thread_id
                     | _ -> false)
                | _ -> false
            with _ -> false
          in
          if bound_other_thread then None else Some r.session_id
      | _ -> None
  with _ -> None

let managed_session_id_for_codex_thread_env ~sid =
  let explicit_mcp =
    match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
    | Some v when String.trim v <> "" -> true
    | _ -> false
  in
  if explicit_mcp then None
  else
    let from_codex_thread =
      match Sys.getenv_opt "CODEX_THREAD_ID" with
      | Some tid when String.trim tid <> "" && String.trim tid = sid -> true
      | _ -> false
    in
    if not from_codex_thread then None
    else
      let broker_root = resolve_broker_root () in
      match
        C2c_mcp_helpers_post_broker.managed_session_id_from_codex_thread
          ~broker_root ~thread_id:sid
      with
      | Some _ as managed -> managed
      | None -> sole_alive_codex_app_server_session ~broker_root ~thread_id:sid

let env_session_id () =
  match C2c_mcp.session_id_from_env () with
  | Some s ->
      let resolved =
        match managed_session_id_for_codex_thread_env ~sid:s with
        | Some managed -> managed
        | None -> s
      in
      if debug_enabled then
        Printf.eprintf "[DEBUG env_session_id] returning Some=%s\n%!" resolved;
      Some resolved
  | None ->
      (* #26: last-resort default-session.json fallback. Escape hatch restores
         the OLD silent-if-registered behaviour; otherwise fail closed on
         ambiguity and only corroborated-sole / client-matched succeeds. *)
      if allow_default_session_env () then
        (match session_id_from_statefile () with
         | Some s ->
             if debug_enabled then
               Printf.eprintf
                 "[DEBUG env_session_id] C2C_ALLOW_DEFAULT_SESSION=1 statefile fallback=%s\n%!"
                 s;
             Some s
         | None ->
             if debug_enabled then
               Printf.eprintf "[DEBUG env_session_id] returning None (opt-in, stale)\n%!";
             None)
      else begin
        let broker_root = C2c_utils.resolve_broker_root () in
        match resolve_statefile_session_gated ~broker_root with
        | `Sole sid ->
            if not !session_fallback_note_emitted then begin
              session_fallback_note_emitted := true;
              Printf.eprintf
                "WARN: session resolved from %s (c2c init fallback; sole registration). \
                 Set C2C_MCP_SESSION_ID or a client-native session key to make this explicit.\n%!"
                (session_statefile_path ~broker_root)
            end;
            if debug_enabled then
              Printf.eprintf "[DEBUG env_session_id] returning sole statefile fallback=%s\n%!" sid;
            Some sid
        | `Client_matched sid ->
            if not !session_fallback_note_emitted then begin
              session_fallback_note_emitted := true;
              Printf.eprintf
                "WARN: session resolved from %s (c2c init fallback; matched detected client). \
                 Set C2C_MCP_SESSION_ID or a client-native session key to make this explicit.\n%!"
                (session_statefile_path ~broker_root)
            end;
            if debug_enabled then
              Printf.eprintf
                "[DEBUG env_session_id] returning client-matched statefile fallback=%s\n%!"
                sid;
            Some sid
        | `Ambiguous _ ->
            (* Do NOT silently adopt the statefile: another registration exists
               and picking one would misattribute authorship. Return None; the
               downstream identity-error path lists the candidates. *)
            if debug_enabled then
              Printf.eprintf
                "[DEBUG env_session_id] ambiguous statefile fallback — failing closed to None\n%!";
            None
        | `Stale ->
            if debug_enabled then
              Printf.eprintf "[DEBUG env_session_id] returning None (stale statefile)\n%!";
            None
      end

let env_auto_alias () =
  match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
  | Some v when String.trim v <> "" -> Some (String.trim v)
  | _ -> None

let env_client_type () =
  match Sys.getenv_opt "C2C_MCP_CLIENT_TYPE" with
  | Some v when String.trim v <> "" -> Some (String.trim v)
  | _ -> None

(* --- B187: honest identity (no borrowed / cross-client success) ----------- *)

let intended_client_kind () =
  match C2c_mcp.inferred_client_type_from_env () with
  | Some c -> Some (normalize_client_kind c)
  | None -> None

let argv_requests_json () =
  let n = Array.length Sys.argv in
  let rec loop i =
    i < n
    && (Sys.argv.(i) = "--json" || Sys.argv.(i) = "-j" || loop (i + 1))
  in
  loop 1

(** Shared fail-closed identity error (B187). Human text on stderr; with
    [--json]/-j] also emit a machine-readable error object on stdout. *)
let identity_error ?(json = false) ~reason ~candidate ~steps () =
  let use_json = json || argv_requests_json () in
  if use_json then begin
    let payload =
      `Assoc
        [ ("error", `String reason)
        ; ( "candidate",
            match candidate with
            | Some c -> `String c
            | None -> `Null )
        ; ("fix_steps", `List (List.map (fun s -> `String s) steps))
        ]
    in
    Yojson.Safe.pretty_to_channel stdout payload;
    print_newline ()
  end else begin
    Printf.eprintf "error: %s\n" reason;
    (match candidate with
     | Some c -> Printf.eprintf "candidate: %s\n" c
     | None -> ());
    Printf.eprintf "how to fix:\n";
    List.iteri (fun i s -> Printf.eprintf "  %d. %s\n" (i + 1) s) steps;
    Printf.eprintf "%!"
  end;
  exit 1

let default_identity_fix_steps ~intended =
  let prefix_hint =
    match intended with
    | Some c ->
        Printf.sprintf
          "c2c init --client %s   # or: c2c register --alias %s-<words> --session-id <your-session>"
          c c
    | None ->
        "c2c init --client <claude|codex|opencode|grok|agy|…>   # mint a client-prefixed alias"
  in
  [ prefix_hint
  ; "c2c register --alias <your-alias> --session-id <your-session>"
  ; "export C2C_MCP_SESSION_ID=<session that owns YOUR alias>   # or the native client session key"
  ; "unset C2C_MCP_AUTO_REGISTER_ALIAS   # if it points at another agent"
  ; "c2c whoami   # must print YOUR alias before sending"
  ; "c2c send <peer> <message>   # only after whoami is honest"
  ; "Advanced: set C2C_MCP_SESSION_ID or a client-native session key; do not reuse another peer's C2C_MCP_AUTO_REGISTER_ALIAS"
  ]

(** Fail closed when the resolved alias / registration clearly belongs to a
    different host client than this shell (e.g. agy shell → codex-* alias). *)
let assert_identity_client_ok ?(json = false) ~alias ~reg_client_type () =
  match intended_client_kind () with
  | None -> ()
  | Some intended ->
      let alias_kind = alias_reserved_client_kind alias in
      let reg_kind = Option.map normalize_client_kind reg_client_type in
      let conflict_prefix =
        match alias_kind with
        | Some k when k <> intended -> true
        | _ -> false
      in
      let conflict_reg =
        match reg_kind with
        | Some k when k <> intended -> true
        | _ -> false
      in
      if conflict_prefix || conflict_reg then
        let detail =
          match alias_kind, reg_kind with
          | Some k, _ -> Printf.sprintf "alias prefix is '%s-'" k
          | None, Some k -> Printf.sprintf "registration client_type is '%s'" k
          | None, None -> "cross-client identity"
        in
        identity_error ~json
          ~reason:
            (Printf.sprintf
               "refusing borrowed/cross-client identity: this shell looks like \
                client '%s' but resolved alias '%s' (%s). Presenting that \
                alias as success would forge authorship (B187)."
               intended alias detail)
          ~candidate:(Some alias)
          ~steps:(default_identity_fix_steps ~intended:(Some intended))
          ()

let refuse_borrowed_auto_alias ?(json = false) ~session_id ~alias () =
  let intended = intended_client_kind () in
  identity_error ~json
    ~reason:
      (Printf.sprintf
         "session_id %S is not registered on this broker; refusing to adopt \
          C2C_MCP_AUTO_REGISTER_ALIAS=%S as identity (borrowed fallback, B187)."
         session_id alias)
    ~candidate:(Some alias)
    ~steps:(default_identity_fix_steps ~intended)
    ()

let refuse_unregistered_identity ?(json = false) ~session_id () =
  let intended = intended_client_kind () in
  identity_error ~json
    ~reason:
      (Printf.sprintf
         "session_id %S is not registered on this broker — no honest alias to \
          report (B187)."
         session_id)
    ~candidate:None
    ~steps:(default_identity_fix_steps ~intended)
    ()

(** B071: pid to pin on a CLI-side registration (`c2c register`, `c2c init`).
    Resolution: C2C_MCP_CLIENT_PID env (unchanged — managed launchers set it
    to the durable outer-loop pid; the literal value is trusted as-is, incl.
    the "0" test sentinel) → [Broker.stable_client_pid] (walk /proc ancestry
    for a known long-lived agent process, strong-matched against
    [session_id] when its environ carries it) → None.

    None means unknown liveness, which send-side alias resolution treats as
    routable — strictly better than the old [Unix.getppid ()] fallback,
    which from an agent-harness shell pinned a transient per-command shell
    pid and made the registration born-dead + unroutable. *)
let resolve_registration_pid ~session_id () =
  match Sys.getenv_opt "C2C_MCP_CLIENT_PID" with
  | Some s ->
      (match int_of_string_opt (String.trim s) with
       | Some p -> Some p
       | None -> C2c_mcp.Broker.stable_client_pid ~session_id ())
  | None -> C2c_mcp.Broker.stable_client_pid ~session_id ()

let is_coordinator () =
  Sys.getenv_opt "C2C_COORDINATOR" = Some "1"

let validate_from_override broker ~caller_session_id ~from_alias =
  if is_coordinator () then ()
  else begin
    let from_cf = C2c_mcp.Broker.alias_casefold from_alias in
    let regs = C2c_mcp.Broker.list_registrations broker in
    let caller_owns_from =
      match caller_session_id with
      | Some sid ->
          List.exists
            (fun (r : C2c_mcp.registration) ->
               C2c_mcp.Broker.alias_casefold r.alias = from_cf && r.session_id = sid)
            regs
      | None -> false
    in
    if not caller_owns_from then begin
      let from_registered_to_other =
        List.exists
          (fun (r : C2c_mcp.registration) ->
             C2c_mcp.Broker.alias_casefold r.alias = from_cf
             && (match caller_session_id with
                 | Some sid -> r.session_id <> sid
                 | None -> true))
          regs
      in
      if from_registered_to_other then begin
        Printf.eprintf
          "refusing to send as '%s': that alias is registered to a different session than yours.\n- If you ARE %s: set C2C_MCP_SESSION_ID to that session's id so the broker recognizes you (this is the usual fix).\n- To relay on behalf of another agent: set C2C_COORDINATOR=1.\n- Otherwise: send as your own alias.\n%!"
          from_alias from_alias;
        exit 1
      end else begin
        Printf.eprintf
          "refusing to send as '%s': alias is not registered in this broker.\n\
           - Anti-impersonation: the broker only allows sending as a registered alias\n\
           to prevent one agent from spoofing another's identity.\n\
           - To send as this alias: register it first with `c2c register --alias %s`,\n\
           or set C2C_MCP_SESSION_ID to the session that owns it.\n\
           - To relay on behalf of another agent: set C2C_COORDINATOR=1.\n%!"
          from_alias from_alias;
        exit 1
      end
    end
  end

let resolve_alias ?(override : string option = None) ?(json = false) broker =
  match override with
  | Some a when String.trim a <> "" ->
      let r = String.trim a in
      validate_from_override broker
        ~caller_session_id:(env_session_id ())
        ~from_alias:r;
      if debug_enabled then Printf.eprintf "[DEBUG resolve_alias] override=%s\n%!" r;
      (* Still refuse --from when the override itself is a reserved prefix for
         a different client than this shell (B187). Coordinator may spoof. *)
      if not (is_coordinator ()) then
        assert_identity_client_ok ~json ~alias:r ~reg_client_type:None ();
      r
  | _ ->
      (* Prefer C2C_MCP_SESSION_ID lookup over C2C_MCP_AUTO_REGISTER_ALIAS.
         C2C_MCP_SESSION_ID identifies the actual registered session; using it
         to look up the registered alias handles the case where the caller
         (e.g. a container with C2C_MCP_AUTO_REGISTER_ALIAS=peer-b-{ts})
         is not the actual sender alias. *)
      match env_session_id () with
      | Some sid ->
          let regs = C2c_mcp.Broker.list_registrations broker in
          (match
             List.find_opt
               (fun (r : C2c_mcp.registration) -> r.session_id = sid)
               regs
           with
          | Some r ->
              if debug_enabled then Printf.eprintf "[DEBUG resolve_alias] from_sid=%s -> alias=%s\n%!" sid r.alias;
              assert_identity_client_ok ~json ~alias:r.alias
                ~reg_client_type:r.client_type ();
              r.alias
          | None -> (
              (* B187: do NOT adopt C2C_MCP_AUTO_REGISTER_ALIAS when our
                 session_id is unregistered — that env often belongs to
                 another managed peer and forges authorship on send/whoami. *)
              match env_auto_alias () with
              | Some a when not (is_coordinator ()) ->
                  if debug_enabled then
                    Printf.eprintf
                      "[DEBUG resolve_alias] sid=%s not registered; refusing borrowed auto_alias=%s\n%!"
                      sid a;
                  refuse_borrowed_auto_alias ~json ~session_id:sid ~alias:a ()
              | Some a ->
                  (* Coordinator may still self-label via AUTO_REGISTER_ALIAS. *)
                  if debug_enabled then
                    Printf.eprintf
                      "[DEBUG resolve_alias] coordinator auto_alias fallback=%s\n%!" a;
                  a
              | None ->
                  if is_coordinator () then (
                    (* B040: C2C_COORDINATOR=1 without --from: self-resolve from
                       env_auto_alias or default to "coordinator" instead of failing. *)
                    let fallback = Option.value (env_auto_alias ()) ~default:"coordinator" in
                    if debug_enabled then Printf.eprintf "[DEBUG resolve_alias] coordinator self-resolve to %s\n%!" fallback;
                    fallback
                  ) else (
                    (* B040: Session not registered here — common when --root
                       targets a different broker. Use the session_id itself as
                       the sender label rather than failing hard (honest label,
                       not another peer's alias). *)
                    if debug_enabled then Printf.eprintf "[DEBUG resolve_alias] sid=%s not registered in target broker, using sid as sender label\n%!" sid;
                    sid
                  )))
      | None -> (
          match env_auto_alias () with
          | Some a ->
              (* No session id at all: AUTO_REGISTER_ALIAS is only acceptable
                 when it does not conflict with the intended client prefix. *)
              if debug_enabled then Printf.eprintf "[DEBUG resolve_alias] from_env_auto_alias=%s\n%!" a;
              assert_identity_client_ok ~json ~alias:a ~reg_client_type:None ();
              a
          | None ->
              if is_coordinator () then (
                (* B040: C2C_COORDINATOR=1 without session or alias: use "coordinator" *)
                if debug_enabled then Printf.eprintf "[DEBUG resolve_alias] coordinator fallback to 'coordinator'\n%!";
                "coordinator"
              ) else begin
                let intended = intended_client_kind () in
                let broker_root = resolve_broker_root () in
                identity_error ~json
                  ~reason:"cannot determine your alias (no session id / registration)."
                  ~candidate:None
                  ~steps:
                    (default_identity_fix_steps ~intended
                     @ candidate_identity_fix_steps ~broker_root)
                  ()
              end)

let resolve_session_id () =
  match env_session_id () with
  | Some sid -> sid
  | None ->
      Printf.eprintf
        "error: cannot determine session ID. Set C2C_MCP_SESSION_ID or run from a supported client session.\n%!";
      exit 1

(* Like resolve_session_id but falls back to alias-based lookup when the
   session_id in the env doesn't match any registration. This handles the case
   where C2C_MCP_SESSION_ID was set by the harness to one value (e.g. "planner1")
   but the actual broker registration used a different session_id (e.g. "opencode-c2c")
   because the MCP server registered under a different identifier. *)
let resolve_session_id_by_alias broker alias =
  let alias_norm = String.lowercase_ascii alias in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let matches =
    List.filter
      (fun (r : C2c_mcp.registration) -> String.lowercase_ascii r.alias = alias_norm)
      regs
  in
  match matches with
  | [] ->
      Printf.eprintf "error: alias %s is not registered in this broker.\n%!" alias;
      exit 1
  | regs ->
      let live =
        List.filter
          (fun r -> C2c_mcp.Broker.registration_liveness_state r = C2c_mcp.Broker.Alive)
          regs
      in
      let chosen = match live with r :: _ -> r | [] -> List.hd regs in
      if debug_enabled then
        Printf.eprintf "[DEBUG resolve_sid_by_alias] alias=%s session_id=%s matches=%d live=%d\n%!"
          alias chosen.session_id (List.length regs) (List.length live);
      chosen.session_id

let resolve_session_id_for_inbox ?alias broker =
  match alias with
  | Some a -> resolve_session_id_by_alias broker a
  | None ->
      let sid = resolve_session_id () in
      let regs = C2c_mcp.Broker.list_registrations broker in
      let has_direct = List.exists (fun (r : C2c_mcp.registration) -> r.session_id = sid) regs in
      if debug_enabled then Printf.eprintf "[DEBUG resolve_sid_for_inbox] sid=%s has_direct=%b regs_count=%d\n%!"
        sid has_direct (List.length regs);
      if has_direct then sid
      else begin
        (* Fall back: look for a registration whose alias matches C2C_MCP_AUTO_REGISTER_ALIAS *)
        match env_auto_alias () with
        | None -> sid (* no fallback available, use original sid *)
        | Some alias ->
            (match List.find_opt (fun (r : C2c_mcp.registration) -> r.alias = alias) regs with
             | None -> sid
             | Some r ->
                 Printf.eprintf
                   "info: C2C_MCP_SESSION_ID=%s not in registry; using session_id=%s (alias=%s)\n%!"
                   sid r.session_id alias;
                 r.session_id)
      end

(* --- output helpers -------------------------------------------------------- *)

let json_flag =
  Cmdliner.Arg.(value & flag & info [ "json"; "j" ] ~doc:"Output machine-readable JSON.")

let cross_repo_flag =
  Cmdliner.Arg.(value & flag & info [ "cross-repo"; "global-broker" ]
    ~doc:"Target the cross-repo sessions broker ($(b,~/.c2c/sessions/broker)) instead of this repo's per-repo broker. Auto-resolves the rendezvous root (override with $(b,C2C_SESSIONS_BROKER_ROOT)); no manual $(b,C2C_MCP_BROKER_ROOT) needed. An explicit $(b,--root), where available, still wins.")

let print_json json =
  Yojson.Safe.pretty_to_channel stdout json;
  print_newline ()

(* ASCII case-insensitive substring test. Shared by `c2c find` and
   `c2c list --match`. An empty needle matches everything. *)
let string_contains_ci haystack needle =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  let hl = String.length h and nl = String.length n in
  if nl = 0 then true
  else
    let rec loop i = i + nl <= hl && (String.sub h i nl = n || loop (i + 1)) in
    loop 0

(* Commands that are runnable in any session (Tier1/Tier2) but are
   de-emphasised in the curated `c2c commands` / `c2c --help` listings
   unless `--dev` (or `--all`) is passed. Orthogonal to the tier map:
   hiding here only affects help text, never runnability. See
   .collab/design/2026-06-26-c2c-list-glyphs-registry.md. *)
let hidden_unless_dev = [ "list-glyphs" ]

(* One-line descriptions for the hidden-unless-dev commands, used to render
   the curated DEV section. *)
let hidden_unless_dev_descriptions =
  [ ("list-glyphs", "(dev) emit the canonical c2c TUI glyph registry as JSON") ]

(* The (name, description) rows to render in the curated DEV section —
   driven by `hidden_unless_dev` so the gate and the listing never drift. *)
let dev_listing_entries () =
  List.filter_map
    (fun name ->
      Option.map (fun d -> (name, d)) (List.assoc_opt name hidden_unless_dev_descriptions))
    hidden_unless_dev

(* Scan argv for `--dev` (mirrors the existing `--all` pre-scan). When
   present, curated listings reveal `hidden_unless_dev` entries (and dev
   sections behave as `--all` does). *)
let argv_has_dev () =
  let n = Array.length Sys.argv in
  let rec loop i = i < n && (Sys.argv.(i) = "--dev" || loop (i + 1)) in
  loop 1

let current_c2c_command () =
  let fallback =
    if Array.length Sys.argv > 0 then Sys.argv.(0) else "c2c"
  in
  let resolved =
    try Unix.readlink "/proc/self/exe"
    with Unix.Unix_error _ -> fallback
  in
  if Filename.is_relative resolved then Sys.getcwd () // resolved else resolved

(* --- MCP nudge: steer agents toward MCP tools when available ---------------- *)

(** Print a one-line nudge to stderr when the agent could use an MCP tool
    instead of the CLI. Fires only when:
    - MCP session env vars are present (C2C_MCP_SESSION_ID, C2C_MCP_AUTO_REGISTER_ALIAS)
    - C2C_CLI_FORCE is not set
    Does not affect command exit code — always returns unit. *)
let mcp_nudge_if_needed ~cmd =
  if Sys.getenv_opt "C2C_CLI_FORCE" = Some "1" then ()
  else
    let env_has_value var =
      match Sys.getenv_opt var with
      | Some s when String.trim s <> "" -> true
      | _ -> false
    in
    if env_has_value "C2C_MCP_SESSION_ID" && env_has_value "C2C_MCP_AUTO_REGISTER_ALIAS" then
      let tool_name =
        match cmd with
        | "send"      -> "mcp__c2c__send"
        | "poll-inbox"| "peek-inbox" -> "mcp__c2c__poll_inbox"
        | "list"      -> "mcp__c2c__list"
        | "whoami"    -> "mcp__c2c__whoami"
        | _ -> ""
      in
      if tool_name <> "" then
        Printf.eprintf
          "hint: MCP is available — consider using %s instead of `c2c %s`\n\
           (suppress with C2C_CLI_FORCE=1)\n%!"
          tool_name cmd
let mkdir_p = C2c_utils.mkdir_p
