(* #450 Slice 7 (final): Identity/Discovery cluster hoisted out of
   [c2c_mcp.ml]'s [handle_tool_call]. Each identity-related tool branch
   is now a top-level function here; [handle_tool_call] dispatches
   one-line into the corresponding [C2c_identity_handlers.X] entrypoint.

   Mechanical move — no behavior change. The bodies are byte-for-byte
   identical to the original arms with free locals lifted into named
   parameters ([broker], [session_id_override], [arguments]). *)

open C2c_mcp_helpers
open C2c_mcp_helpers_post_broker
module Broker = C2c_broker

let register ~broker ~session_id_override ~arguments =
      let session_id = resolve_session_id ?session_id_override:session_id_override arguments in
      let explicit_alias = optional_string_member "alias" arguments in
      let alias =
        match explicit_alias with
        | Some a -> a
        | None ->
            (match auto_register_alias () with
             | Some a -> a
             | None -> invalid_arg "alias is required (pass {\"alias\":\"your-name\"} or set C2C_MCP_AUTO_REGISTER_ALIAS)")
      in
      (* Origin marker: written by c2c install/start ONLY when the alias was
         auto-picked (not --alias/--name/role/env). It crosses the env boundary
         so the server-side register handler knows this name originated from
         auto-generation and should skip the user-supplied-only blocklist. *)
      let env_from_auto_gen () =
        match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN" with
        | Some v -> String.trim v = "1"
        | None -> false
      in
      (* #dual-alias-fix / B046: if this session already has a registration
         with a different alias and the caller did NOT explicitly request an
         alias (i.e. relying on C2C_MCP_AUTO_REGISTER_ALIAS or default), reuse
         the existing alias to prevent the same session accumulating multiple
         registrations under different aliases. B135: an explicit alias=
         that differs from the existing registration is refused (sticky
         alias) — start a fresh session for a new name.
         When reusing an existing alias we skip the blocklist, because the
         alias was already validated at first registration.
         B240: explicit same-alias re-register (PID refresh) may restate a
         reserved client-prefix name this session already holds — also skip
         the blocklist so sticky same-alias refresh is not a dead-end. *)
      let alias, alias_from_auto_gen =
        match explicit_alias with
        | Some a ->
            let already_holds =
              List.exists
                (fun reg ->
                  reg.session_id = session_id
                  && Broker.alias_casefold reg.alias = Broker.alias_casefold a)
                (Broker.list_registrations broker)
            in
            (* already_holds → skip blocklist; otherwise enforce it. *)
            (a, already_holds)
        | None ->
            let existing =
              List.find_opt
                (fun reg -> reg.session_id = session_id)
                (Broker.list_registrations broker)
            in
            (match existing with
             | Some reg when reg.alias <> alias -> (reg.alias, true)  (* reuse existing, skip blocklist *)
             | _ -> (alias, env_from_auto_gen ()))
      in
      (* B135: refuse explicit rename of an existing session_id's alias. *)
      match
        (match explicit_alias with
         | None -> None
         | Some _ ->
             Broker.sticky_alias_conflict broker ~session_id ~requested_alias:alias)
      with
      | Some existing_alias ->
          Lwt.return (tool_err
            (Broker.sticky_alias_error ~session_id ~existing_alias
               ~requested_alias:alias))
      | None ->
      (* Reserved aliases — always blocked. *)
      if Broker.is_reserved_system_alias alias then
        Lwt.return (tool_err (Printf.sprintf
          "register rejected: '%s' is a reserved system alias and cannot be registered" alias))
      else if (not alias_from_auto_gen) && C2c_blocklist.is_banned_alias alias then
        Lwt.return (tool_err (C2c_blocklist.blocked_alias_error alias))
      else if not (C2c_name.is_valid alias) then
        Lwt.return (tool_err (Printf.sprintf "register rejected: %s"
          (C2c_name.error_message "alias" alias)))
      else
      let pid =
        match current_client_pid () with
        | Some pid -> Some pid
        | None -> Some (Unix.getppid ())
      in
      let client_type = optional_string_member "client_type" arguments in
      (* Detect whether this is a brand-new registration (no existing row for
         this session_id). Used below to emit peer_register broadcast. *)
      let is_new_registration =
        not (List.exists (fun r -> r.session_id = session_id)
               (Broker.list_registrations broker))
      in
      (* Detect alias rename before registering so we can notify rooms.
         A rename is genuine when the same process (matched by PID) re-registers
         under a new alias.  When both the old and new registration have a real
         PID set, they must agree — a differing PID means a new process reused
         the same session_id (common with `c2c start`), not an intentional rename.
         When the old registration has pid=None (legacy / no-PID registration),
         we allow the rename so that pre-PID entries are not permanently frozen. *)
      let old_alias_opt =
        let existing =
          List.find_opt
            (fun reg ->
              reg.session_id = session_id
              && reg.alias <> alias
              && (match reg.pid, pid with
                  | Some old_pid, Some new_pid -> old_pid = new_pid
                  | None, _ -> true   (* legacy no-PID row — allow rename *)
                  | Some _, None -> false))   (* new has no pid — can't confirm same process *)
            (Broker.list_registrations broker)
        in
        match existing with
        | Some reg -> Some reg.alias
        | None -> None
      in
      (* Capture rooms BEFORE re-registering (membership still uses old alias). *)
      let rooms_to_notify =
        match old_alias_opt with
        | None -> []
        | Some _ ->
            List.map (fun ri -> ri.Broker.ri_room_id)
              (Broker.my_rooms broker ~session_id)
      in
      let pid_start_time = Broker.capture_pid_start_time pid in
      (* Guard: refuse to evict a CONFIRMED-alive registration that owns this alias
         under a different session_id. An agent re-registering its own alias (same
         session_id, e.g. after a PID change) is always allowed. This prevents
         confused or malicious agents from hijacking another agent's alias.
         Use registration_liveness_state (tristate) so that pidless/Unknown entries
         do NOT block — registration_is_alive returns true for pid=None, which would
         permanently strand an alias held by a stale pidless row. We also block when
         pid is set and process exists but pid_start_time is missing (conservative:
         can't verify PID reuse, so protect the alias). *)
      let alias_hijack_conflict =
        (* #432 follow-up (slate-coder 2026-04-29): compare case-folded
           aliases. The eviction predicate at L1898 is case-fold, so a
           raw `=` here was an asymmetric guard — an attacker could
           register `slate-coder` against a victim holding `Slate-Coder`
           and the eviction would still fire, hijacking the victim's
           inbox. See
           .collab/findings/2026-04-29T14-25-00Z-slate-coder-alias-casefold-guard-asymmetry-takeover.md. *)
        let target = Broker.alias_casefold alias in
        List.find_opt
          (fun reg ->
            Broker.alias_casefold reg.alias = target
            && reg.session_id <> session_id
            && Option.is_some reg.pid
            && Broker.registration_is_alive reg)
          (Broker.list_registrations broker)
      in
      (match alias_hijack_conflict with
       | Some conflict ->
           let suggested_opt = Broker.suggest_alias_for_alias broker ~alias in
           let content =
             match suggested_opt with
             | Some suggested ->
                 Yojson.Safe.to_string
                   (`Assoc
                     [ ("error", `String
                          (Printf.sprintf
                             "register rejected: alias '%s' is currently held by \
                              an alive session '%s'. Suggested free alias: '%s'. \
                              Options: (1) register with {\"alias\":\"%s\"}, \
                              (2) wait for the current holder's process to exit, \
                              (3) call list to see all current registrations."
                             alias conflict.session_id suggested suggested))
                     ; ("collision", `Bool true)
                     ; ("contested_alias", `String alias)
                     ; ("holder_session_id", `String conflict.session_id)
                     ; ("suggested_alias", `String suggested)
                     ])
             | None ->
                 Yojson.Safe.to_string
                   (`Assoc
                     [ ("error", `String
                          (Printf.sprintf
                             "register rejected: alias '%s' is currently held by \
                              an alive session '%s', and all prime-suffixed \
                              candidates are also taken. Choose a different base alias."
                             alias conflict.session_id))
                     ; ("collision", `Bool true)
                     ; ("collision_exhausted", `Bool true)
                     ; ("contested_alias", `String alias)
                     ; ("holder_session_id", `String conflict.session_id)
                     ])
           in
            Lwt.return (tool_err content)
         | None ->
             let prior_owner_has_pending =
               Broker.pending_permission_exists_for_alias broker alias
             in
              if prior_owner_has_pending then
                Lwt.return (tool_err (Printf.sprintf
                  "register rejected: alias '%s' has pending permission state \
                   from a prior owner. \
                   Wait for the pending reply to arrive or for it to timeout before claiming this alias."
                  alias))
            else begin
              (* Key creation/pinning happens before [Broker.register] can
                 claim the alias in the registry.  Keep that preparation and
                 the commit in the same alias-identity critical section so a
                 concurrent B140 rename cannot move or roll back this
                 claimant's target material. *)
              Broker.with_alias_identity_locks broker ~aliases:[ alias ]
                (fun () ->
              let plugin_version = optional_string_member "plugin_version" arguments in
              let role = optional_string_member "role" arguments in
              let tmux_location_arg = optional_string_member "tmux_location" arguments in
              let include_metadata =
                match Json_util.bool_member "include_metadata" arguments with
                | Some b -> b
                | None -> true
              in
              let metadata_opt_out = not include_metadata in
              let tmux_location =
                match tmux_location_arg with
                | Some _ -> tmux_location_arg
                | None -> Sys.getenv_opt "C2C_TMUX_LOCATION"
              in
              (* Wake-inject targets (codex idle wake): explicit args win,
                 else fall back to the herdr pane env the MCP server child
                 inherits when the session runs inside a herdr pane. *)
              let nonempty_env name =
                match Sys.getenv_opt name with
                | Some v when String.trim v <> "" -> Some (String.trim v)
                | _ -> None
              in
              let herdr_pane =
                match optional_string_member "herdr_pane" arguments with
                | Some _ as v -> v
                | None -> nonempty_env "HERDR_PANE_ID"
              in
              let herdr_socket =
                match optional_string_member "herdr_socket" arguments with
                | Some _ as v -> v
                | None -> nonempty_env "HERDR_SOCKET_PATH"
              in
              let broker_root = Broker.root broker in
              let keys_dir = Filename.concat broker_root "keys" in
              let enc_pubkey =
                match Relay_enc.load_or_generate ~alias () with
                | Ok enc -> Some (Relay_enc.public_key_b64 enc)
                | Error e ->
                    Printf.eprintf "[register] warning: could not load X25519 key: %s\n%!" e;
                    None
              in
              let ed25519_pubkey, pubkey_signed_at, pubkey_sig =
                match enc_pubkey with
                | None -> (None, None, None)
                | Some x25519_b64 ->
                    let priv_path = Filename.concat keys_dir (alias ^ ".ed25519") in
                    let ed_identity_opt =
                      if Sys.file_exists priv_path then
                        (* File exists but load failed — permissions error or corruption.
                           Do not clobber: operator must resolve manually. *)
                        (match Relay_identity.load ~path:priv_path () with
                         | Ok id -> Some id
                         | Error e ->
                             Printf.eprintf "[register] warning: cannot load Ed25519 key at %s: %s\n%!" priv_path e;
                             None)
                      else
                        (* No such file — lazy-create is safe. *)
                        (try
                           let () = mkdir_p ~mode:0o700 keys_dir in
                           Some (Relay_identity.load_or_create_at ~path:priv_path ~alias_hint:alias)
                         with e ->
                           Printf.eprintf "[register] warning: could not create Ed25519 identity at %s: %s\n%!" priv_path (Printexc.to_string e);
                           None)
                    in
                    match ed_identity_opt with
                    | None -> (None, None, None)
                    | Some ed_identity ->
                        let ed_pubkey_b64 = Relay_identity.b64url_encode ed_identity.Relay_identity.public_key in
                        let signed_at = Unix.gettimeofday () in
                        let signed_at_str = C2c_time.iso8601_utc signed_at in
                        let canonical_msg =
                          Relay_identity.canonical_msg ~ctx:Relay.pubkey_binding_sign_ctx
                            [ alias; ed_pubkey_b64; x25519_b64; signed_at_str ]
                        in
                        let sig_raw = Relay_identity.sign ed_identity canonical_msg in
                        let sig_b64 = Relay_identity.b64url_encode sig_raw in
                        (Some ed_pubkey_b64, Some signed_at, Some sig_b64)
              in
              (* E2E S2: check both TOFU pins before registering.
                 If either mismatches, reject the registration.
                 CRIT-2 register-path observability: on each mismatch
                 emit a structured broker.log line via
                 [log_relay_e2e_register_pin_mismatch] so operators can
                 grep for register-path attacks across the swarm. *)
              let ed25519_mismatch =
                match ed25519_pubkey with
                | None -> None
                | Some ed_pk ->
                    (match Broker.pin_ed25519_sync ~alias ~pk:ed_pk with
                     | `Mismatch ->
                         let pinned = Broker.get_pinned_ed25519 alias in
                         Some ("ed25519", pinned, ed_pk)
                     | `Already_pinned | `New_pin -> None)
              in
              let x25519_mismatch =
                match enc_pubkey with
                | None -> None
                | Some xb64 ->
                    (match Broker.pin_x25519_sync ~alias ~pk:xb64 with
                     | `Mismatch ->
                         let pinned = Broker.get_pinned_x25519 alias in
                         Some ("x25519", pinned, xb64)
                     | `Already_pinned | `New_pin -> None)
              in
              let emit_register_pin_mismatch_audit (key_class, pinned_opt, claimed) =
                match Broker.get_relay_pins_root () with
                | None -> ()
                | Some broker_root ->
                    let pinned_b64 = Option.value pinned_opt ~default:"" in
                    log_relay_e2e_register_pin_mismatch
                      ~broker_root
                      ~alias
                      ~key_class
                      ~pinned_b64
                      ~claimed_b64:claimed
                      ~ts:(Unix.gettimeofday ())
              in
              match ed25519_mismatch, x25519_mismatch with
              | Some ((ed_k, _, _) as ed_info), Some ((x_k, _, _) as x_info) ->
                  emit_register_pin_mismatch_audit ed_info;
                  emit_register_pin_mismatch_audit x_info;
                  Lwt.return (tool_result
                    ~content:(Printf.sprintf
                      "register rejected: %s and %s pubkey mismatch — explicit rotation required \
                       (both pubkeys differ from previously pinned values for this alias)"
                      ed_k x_k)
                    ~is_error:true)
              | Some ((key_kind, _, _) as info), None
              | None, Some ((key_kind, _, _) as info) ->
                  emit_register_pin_mismatch_audit info;
                  Lwt.return (tool_result
                    ~content:(Printf.sprintf
                      "register rejected: %s pubkey mismatch — explicit rotation required \
                       (pubkey differs from previously pinned value for this alias)"
                      key_kind)
                    ~is_error:true)
              | None, None ->
                  Broker.register broker ~session_id ~alias ~pid ~pid_start_time
                    ~client_type ~plugin_version ~enc_pubkey ~ed25519_pubkey
                    ~pubkey_signed_at ~pubkey_sig ~role ~tmux_location
                    ~herdr_pane ~herdr_socket
                    ~cwd:(try Some (Sys.getcwd ()) with Sys_error _ -> None)
                    ~metadata_opt_out ~from_auto_gen:alias_from_auto_gen ();
                  Broker.touch_session broker ~session_id;
              List.iter
                (fun room_id ->
                  try
                    ignore
                      (Broker.rename_room_member_alias broker ~room_id ~session_id
                         ~new_alias:alias)
                  with _ -> ())
                rooms_to_notify;
              (match old_alias_opt with
               | None -> ()
               | Some old_alias ->
                   let content =
                     Printf.sprintf
                       "%s renamed to %s {\"type\":\"peer_renamed\",\"old_alias\":\"%s\",\"new_alias\":\"%s\"}"
                       old_alias alias old_alias alias
                   in
                   List.iter
                     (fun room_id ->
                       (try
                          ignore
                            (Broker.send_room broker ~from_alias:"c2c-system"
                               ~room_id ~content)
                        with _ -> ()))
                     rooms_to_notify);
              let new_reg_unconfirmed =
                match List.find_opt (fun r -> r.session_id = session_id)
                        (Broker.list_registrations broker) with
                | Some reg -> Broker.is_unconfirmed reg
                | None -> false
              in
              (if is_new_registration && not new_reg_unconfirmed then begin
                let social_rooms =
                  let auto_rooms =
                    match Sys.getenv_opt "C2C_MCP_AUTO_JOIN_ROOMS" with
                    | Some v ->
                        String.split_on_char ',' v
                        |> List.map String.trim
                        |> List.filter (fun s -> s <> "" && Broker.valid_room_id s)
                    | None -> []
                  in
                  let social_room = C2c_swarm_config.swarm_config_social_room () in
                  if social_room = "" then auto_rooms
                  else List.sort_uniq String.compare (social_room :: auto_rooms)
                in
                let content =
                  Printf.sprintf
                    "%s registered {\"type\":\"peer_register\",\"alias\":\"%s\"}"
                    alias alias
                in
                List.iter
                  (fun room_id ->
                    try ignore (Broker.send_room broker ~from_alias:"c2c-system" ~room_id ~content)
                    with _ -> ())
                  social_rooms
              end);
              let redelivered =
                Broker.redeliver_dead_letter_for_session broker ~session_id ~alias
              in
              (match Broker.write_allowed_signers_entry broker ~alias with
               | Ok () -> ()
               | Error e -> Printf.eprintf "[allowed_signers] warning: %s\n%!" e);
              let response_content =
                if redelivered > 0 then
                  Printf.sprintf "registered %s (redelivered %d dead-letter message%s)"
                    alias redelivered (if redelivered = 1 then "" else "s")
                else
                  "registered " ^ alias
              in
              Lwt.return (tool_ok response_content))
            end)

(* B140: deliberate atomic alias rename-everywhere. The sanctioned
   counterpart to the B135 sticky-alias forbid — see
   [Broker.rename_alias] for the store-by-store mechanics and the
   rollback model. This handler is a thin shim so CLI and MCP share one
   implementation. B179: after a successful local rename, best-effort
   relay rebind (async, same Lwt loop — never Lwt_main.run here). *)
let rename ~broker ~session_id_override ~arguments =
      let ambient_session_id =
        match session_id_override with
        | Some session_id -> Some session_id
        | None -> current_session_id ()
      in
      match ambient_session_id, optional_string_member "session_id" arguments with
      | Some ambient, Some requested when not (String.equal ambient requested) ->
          (* A rename changes identity-bearing state.  Unlike the CLI's
             explicit [--session-id] maintenance path, an MCP caller may only
             rename the session bound to its transport/environment. *)
          Lwt.return
            (tool_err
               (Printf.sprintf
                  "rename rejected: session_id '%s' does not match the ambient MCP session '%s'"
                  requested ambient))
      | None, _ ->
          Lwt.return
            (tool_err
               "rename rejected: no ambient MCP session is bound to this request")
      | Some session_id, _ ->
          match optional_string_member "new_alias" arguments with
          | None -> Lwt.return (tool_err "rename rejected: new_alias is required")
          | Some new_alias -> (
              match Broker.rename_alias broker ~session_id ~new_alias with
              | Error e -> Lwt.return (tool_err e)
              | Ok rename_json ->
                  let open Lwt.Infix in
                  let old_alias =
                    match rename_json with
                    | `Assoc fields ->
                        (match List.assoc_opt "old_alias" fields with
                         | Some (`String s) -> s
                         | _ -> "")
                    | _ -> ""
                  in
                  let is_noop =
                    match rename_json with
                    | `Assoc fields ->
                        List.assoc_opt "noop" fields = Some (`Bool true)
                    | _ -> false
                  in
                  (if is_noop then
                     Lwt.return
                       (`Assoc
                          [ ("status", `String "skipped")
                          ; ("reason", `String "noop rename")
                          ; ("new_alias", `String new_alias)
                          ])
                   else
                     Relay_rename_rebind.rebind_lwt ~old_alias ~new_alias ())
                  >>= fun rebind_json ->
                  let result_json =
                    Relay_rename_rebind.merge_into_rename_result ~rename_json
                      ~rebind_json
                  in
                  Lwt.return (tool_ok (Yojson.Safe.to_string result_json)))

let list ~broker ~session_id_override:_ ~arguments =
      let alive_only =
        try match Yojson.Safe.Util.member "alive_only" arguments with
          | `Bool b -> b | _ -> false
        with _ -> false
      in
      (* #74: MCP parity with CLI — on the shared `default` broker, hide rows
         whose registration cwd is outside the current scope dir. Opt out with
         include_all:true (CLI --all equivalent). Real repo brokers are not
         filtered (worktree peers must remain visible). *)
      let include_all =
        try match Yojson.Safe.Util.member "include_all" arguments with
          | `Bool b -> b | _ -> false
        with _ -> false
      in
      let registrations =
        let all = Broker.list_registrations broker in
        let all =
          if alive_only then
            List.filter (fun reg ->
              match Broker.registration_liveness_state reg with
              | C2c_broker.Alive -> true
              | C2c_broker.Dead | C2c_broker.Unknown -> false) all
          else all
        in
        let broker_root = Broker.root broker in
        let (kept, _hidden) =
          C2c_list_scope.maybe_filter_default_broker ~broker_root
            ~apply:(not include_all)
            ~cwd_of:(fun (r : registration) -> r.cwd) all
        in
        kept
      in
      let content =
        `List
          (List.map
             (fun reg ->
               let { session_id; alias; pid; pid_start_time = _; registered_at; _ } = reg in
               let base =
                 [ ("session_id", `String session_id); ("alias", `String alias) ]
               in
               let with_pid =
                 match pid with
                 | Some n -> base @ [ ("pid", `Int n) ]
                 | None -> base
               in
               (* Tristate `alive`: Bool true / Bool false / Null for
                  legacy pidless rows. Operators can filter on this
                  to identify zombie peers before broadcasting. *)
               let alive_field =
                  match Broker.registration_liveness_state reg with
                 | Broker.Alive -> `Bool true
                 | Broker.Dead -> `Bool false
                 | Broker.Unknown -> `Null
               in
               let with_alive = with_pid @ [ ("alive", alive_field) ] in
               let with_ra =
                 match registered_at with
                 | Some ts -> with_alive @ [ ("registered_at", `Float ts) ]
                 | None -> with_alive
               in
               let fields =
                 match reg.canonical_alias with
                 | Some ca -> with_ra @ [ ("canonical_alias", `String ca) ]
                 | None -> with_ra
               in
               `Assoc fields)
             registrations)
        |> Yojson.Safe.to_string
      in
      Lwt.return (tool_ok content)

let whoami ~broker ~session_id_override ~arguments =
      let session_id = resolve_session_id ?session_id_override:session_id_override arguments in
      let reg_opt =
        match
          Broker.list_registrations broker
          |> List.find_opt (fun reg -> reg.session_id = session_id)
        with
        | Some _ as r -> r
        | None ->
            (* #48: an unregistered managed-kimi MCP session reports its
               launcher identity (resolved by cwd) rather than "unregistered". *)
            self_managed_kimi_row ?session_id_override:session_id_override broker
      in
      let content =
        match reg_opt with
        | None -> ""
        | Some reg ->
            (match reg.canonical_alias with
             | Some ca ->
                 `Assoc [ ("alias", `String reg.alias); ("canonical_alias", `String ca) ]
                 |> Yojson.Safe.to_string
             | None -> reg.alias)
      in
      Lwt.return (tool_ok content)

let debug ~broker ~session_id_override ~arguments =
      let action = string_member "action" arguments in
      if not Build_flags.mcp_debug_tool_enabled then
        Lwt.return (tool_err "unknown tool")
      else
        (match action with
         | "send_msg_to_self" ->
             let session_id = resolve_session_id ?session_id_override:session_id_override arguments in
             let sender_alias =
               match current_registered_alias ?session_id_override:session_id_override broker with
               | Some alias -> alias
               | None ->
                   (match auto_register_alias () with
                    | Some alias -> alias
                    | None ->
                        raise
                          (Invalid_argument
                             "debug.send_msg_to_self: current session is not registered"))
             in
             let payload_json =
               optional_member "payload" arguments |> Option.value ~default:`Null
             in
             let content =
               `Assoc
                 [ ("kind", `String "c2c_debug")
                 ; ("action", `String action)
                 ; ("payload", payload_json)
                 ; ("ts", `Float (Unix.gettimeofday ()))
                 ; ("session_id", `String session_id)
                 ; ("alias", `String sender_alias)
                 ]
               |> Yojson.Safe.to_string
             in
             Broker.enqueue_message broker ~from_alias:sender_alias
               ~to_alias:sender_alias ~content ();
             let result_json =
               `Assoc
                 [ ("ok", `Bool true)
                 ; ("action", `String action)
                 ; ("session_id", `String session_id)
                 ; ("alias", `String sender_alias)
                 ; ("delivered_to", `String sender_alias)
                 ; ("content_preview", `String content)
                 ]
               |> Yojson.Safe.to_string
             in
             Lwt.return (tool_ok result_json)
         | "send_raw_to_self" ->
             (* Like send_msg_to_self, but content is the payload string verbatim
                — no JSON wrapping, no c2c_debug envelope. The body that arrives in
                the channel notification is exactly the payload. Use case: probe
                whether a Claude harness treats raw channel body as user input
                (e.g. payload="/compact" to test slash-command firing). *)
             let session_id = resolve_session_id ?session_id_override:session_id_override arguments in
             let sender_alias =
               match current_registered_alias ?session_id_override:session_id_override broker with
               | Some alias -> alias
               | None ->
                   (match auto_register_alias () with
                    | Some alias -> alias
                    | None ->
                        raise
                          (Invalid_argument
                             "debug.send_raw_to_self: current session is not registered"))
             in
             let payload =
               match optional_member "payload" arguments with
               | Some (`String s) -> s
               | Some _ ->
                   raise
                     (Invalid_argument
                        "debug.send_raw_to_self: payload must be a string")
               | None ->
                   raise
                     (Invalid_argument
                        "debug.send_raw_to_self: payload is required")
             in
             Broker.enqueue_message broker ~from_alias:sender_alias
               ~to_alias:sender_alias ~content:payload ();
             let preview =
               if String.length payload <= 200 then payload
               else String.sub payload 0 200 ^ "…"
             in
             let result_json =
               `Assoc
                 [ ("ok", `Bool true)
                 ; ("action", `String action)
                 ; ("session_id", `String session_id)
                 ; ("alias", `String sender_alias)
                 ; ("delivered_to", `String sender_alias)
                 ; ("payload_length", `Int (String.length payload))
                 ; ("content_preview", `String preview)
                 ]
               |> Yojson.Safe.to_string
             in
             Lwt.return (tool_ok result_json)
          | "get_env" ->
              let prefix =
                match optional_string_member "prefix" arguments with
                | Some p -> p
                | None -> "C2C_"
              in
              let env_vars =
                Array.to_list (Unix.environment ())
                |> List.filter (fun entry ->
                  String.length entry > String.length prefix
                  && String.sub entry 0 (String.length prefix) = prefix)
                |> List.map (fun entry ->
                  match String.index_opt entry '=' with
                  | Some i ->
                      let key = String.sub entry 0 i in
                      let value = String.sub entry (i + 1) (String.length entry - i - 1) in
                      (key, value)
                  | None -> (entry, ""))
                |> List.sort (fun (k1,_) (k2,_) -> String.compare k1 k2)
              in
              let result_json =
                `Assoc (
                  ("ok", `Bool true)
                  :: ("action", `String "get_env")
                  :: ("prefix", `String prefix)
                  :: ("count", `Int (List.length env_vars))
                  :: (List.map (fun (k,v) -> (k, `String v)) env_vars)
                )
                |> Yojson.Safe.to_string
              in
              Lwt.return (tool_ok result_json)
          | _ ->
              Lwt.return
                (tool_result
                   ~content:(Printf.sprintf "debug: unknown action '%s'" action)
                   ~is_error:true))
