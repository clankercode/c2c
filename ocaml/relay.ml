[@@@warning "-33-16-32-26"]
(* relay.ml — native OCaml HTTP relay server using Cohttp_lwt_unix *)

open Lwt.Infix
module Res = Result
open Sqlite3

include Relay_common
include Relay_registration_lease
include Relay_host_routing
include Relay_backend_contract
include Relay_observer_bindings
include Relay_observer_sessions
include Relay_observer_protocol
include Relay_observer_push
include Relay_observer_runtime
include Relay_mobile_pair_nonce_cache
include Relay_pow_challenge
include Relay_client
include Relay_alias_helpers

include Relay_sqlite_support
include Relay_pairing_token_sql

(* --- InMemoryRelay --- *)

module InMemoryRelay : RELAY = struct
  type t = {
    mutex : Mutex.t;
    leases : (string, RegistrationLease.t) Hashtbl.t;
    bindings : (string, string) Hashtbl.t;
    register_nonces : (string, float) Hashtbl.t;
    request_nonces : (string, float) Hashtbl.t;
    inboxes : ((string * string), Yojson.Safe.t list) Hashtbl.t;
    dead_letter : Yojson.Safe.t Queue.t;
    rooms : (string, string list) Hashtbl.t;
    (* Layer 4 slice 5: per-room visibility and invited identity_pk list. *)
    room_visibility : (string, string) Hashtbl.t;  (* "public" | "unlisted" | "gated" | "private" *)
    room_invites : (string, string list) Hashtbl.t; (* b64url-nopad pks *)
    room_knocks : (string, room_knock list) Hashtbl.t;
    (* L3/5: operator allowlist (alias → identity_pk b64url-nopad). If an
       alias is present here, registrations must match the pinned pk. *)
    allowed_identities : (string, string) Hashtbl.t;
    room_history : (string, Yojson.Safe.t list) Hashtbl.t;
    seen_ids : (string, bool) Hashtbl.t;
    dedup_window : int;
    seen_ids_fifo : string Queue.t;
    persist_dir : string option;  (* if set, room history is also written to disk *)
    (* S5a: In-memory pairing token store *)
    pairing_tokens : (string, (string * string * float)) Hashtbl.t;
    (* S5a: In-memory observer bindings *)
    observer_bindings_mem : (string, (string * string)) Hashtbl.t;
    (* S5b: Device-pair pending table (RFC 8628 OAuth, ephemeral) *)
    device_pair_pending_mem : (string, device_pair_pending) Hashtbl.t;
    (* #379: this relay's own host identity for alias@host validation *)
    self_host : string option;
    (* #330 S2: this relay's own Ed25519 identity for signing forward requests *)
    identity : Relay_identity.t;
    (* #330 S1: peer relays for cross-relay forwarding *)
    peer_relays : (string, peer_relay_t) Hashtbl.t;
  }

  let room_history_jsonl_path persist_dir room_id =
    Filename.concat (Filename.concat persist_dir ("rooms/" ^ room_id)) "history.jsonl"

  let load_room_history_from_disk persist_dir room_history =
    let rooms_dir = Filename.concat persist_dir "rooms" in
    if not (Sys.file_exists rooms_dir) then ()
    else begin
      let entries = try Array.to_list (Sys.readdir rooms_dir) with Sys_error _ -> [] in
      List.iter (fun room_id ->
        let path = room_history_jsonl_path persist_dir room_id in
        if Sys.file_exists path then begin
          let ic = open_in path in
          let lines = ref [] in
          (try while true do
            let line = String.trim (input_line ic) in
            if line <> "" then
              (try lines := Yojson.Safe.from_string line :: !lines
               with _ -> ())
          done with End_of_file -> ());
          close_in_noerr ic;
          (* Lines were read oldest-first; history is stored newest-first *)
          Hashtbl.replace room_history room_id !lines
        end
      ) entries
    end

  let append_room_history_to_disk persist_dir room_id hist_msg =
    let path = room_history_jsonl_path persist_dir room_id in
    let dir = Filename.dirname path in
    (try
       C2c_io.mkdir_p dir;
       let oc = open_out_gen [Open_creat; Open_append; Open_wronly] 0o644 path in
       output_string oc (Yojson.Safe.to_string hist_msg ^ "\n");
       close_out oc
     with _ -> ())

  let create ?(dedup_window = 10000) ?persist_dir ?(self_host=None) ?(peer_relays=Hashtbl.create 2) () =
    let room_history = Hashtbl.create 16 in
    (* Load persisted room history on startup *)
    Option.iter (fun d -> load_room_history_from_disk d room_history) persist_dir;
    (* #330 S2: load or generate this relay's Ed25519 identity for cross-relay signing *)
    let identity_path = Option.map (fun d -> Filename.concat d "relay-server-identity.json") persist_dir in
    let identity =
      match identity_path with
      | Some p -> Relay_identity.load_or_create_at ~path:p ~alias_hint:(Option.value self_host ~default:"relay")
      | None -> Relay_identity.generate ~alias_hint:(Option.value self_host ~default:"relay") ()
    in
    { mutex = Mutex.create ();
      leases = Hashtbl.create 16;
      bindings = Hashtbl.create 16;
      register_nonces = Hashtbl.create 64;
      request_nonces = Hashtbl.create 256;
      inboxes = Hashtbl.create 16;
      dead_letter = Queue.create ();
      rooms = Hashtbl.create 16;
      room_visibility = Hashtbl.create 16;
      room_invites = Hashtbl.create 16;
      room_knocks = Hashtbl.create 16;
      allowed_identities = Hashtbl.create 16;
      room_history;
      seen_ids = Hashtbl.create 64;
      seen_ids_fifo = Queue.create ();
      dedup_window;
      persist_dir;
      pairing_tokens = Hashtbl.create 64;
      observer_bindings_mem = Hashtbl.create 64;
      device_pair_pending_mem = Hashtbl.create 64;
      self_host;
      identity;
      peer_relays;
    }

  let with_lock t f =
    Mutex.lock t.mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

  let self_host t = t.self_host
  (* #330 S2: relay identity for cross-relay signing *)
  let relay_identity t = t.identity

  (* #330 S1: peer_relay accessors *)
  let add_peer_relay t pr = Hashtbl.replace t.peer_relays pr.name pr
  let peer_relay_of t ~name = Hashtbl.find_opt t.peer_relays name
  let peer_relays_list t = Hashtbl.fold (fun _ v acc -> v :: acc) t.peer_relays []

  let generate_uuid () =
    let random_hex n =
      let chars = "0123456789abcdef" in
      String.init n (fun _ -> chars.[Random.int 16])
    in
    Printf.sprintf "%s-%s-4%s-%s-%s"
      (random_hex 8) (random_hex 3) (random_hex 3) (random_hex 4) (random_hex 12)

  let record_message_id t msg_id =
    if Hashtbl.mem t.seen_ids msg_id then false
    else (
      Hashtbl.replace t.seen_ids msg_id true;
      Queue.add msg_id t.seen_ids_fifo;
      if Queue.length t.seen_ids_fifo > t.dedup_window then (
        match Queue.take_opt t.seen_ids_fifo with
        | None -> ()
        | Some old -> Hashtbl.remove t.seen_ids old
      );
      true
    )

  let inbox_key node_id session_id = (node_id, session_id)

  let get_inbox t key =
    match Hashtbl.find_opt t.inboxes key with
    | Some msgs -> msgs
    | None -> []

  let set_inbox t key msgs =
    Hashtbl.replace t.inboxes key msgs

  let release_alias t alias =
    (match Hashtbl.find_opt t.leases alias with
     | Some lease ->
       Hashtbl.remove t.inboxes
         (inbox_key (RegistrationLease.node_id lease) (RegistrationLease.session_id lease))
     | None -> ());
    Hashtbl.remove t.leases alias;
    Hashtbl.remove t.bindings alias;
    Hashtbl.iter (fun room_id members ->
      Hashtbl.replace t.rooms room_id (List.filter ((<>) alias) members)
    ) t.rooms

  let register t ~node_id ~session_id ~alias ?(client_type = "unknown") ?(ttl = default_lease_ttl) ?(identity_pk = "") ?(enc_pubkey = "") ?(signed_at = 0.0) ?(sig_b64 = "") ?(opaque_host_id : string option = None) () =
    with_lock t (fun () ->
      if not (C2c_name.is_valid_with_opaque_host_id alias) then
        let dummy = RegistrationLease.make ~node_id ~session_id ~alias ~client_type ~ttl ~identity_pk ~enc_pubkey ~signed_at ~sig_b64 ~opaque_host_id:opaque_host_id () in
        ("invalid_alias", dummy)
      else
      let alias, opaque_host_id = normalize_relay_alias ~alias ~opaque_host_id in
      let allow_state =
        match Hashtbl.find_opt t.allowed_identities alias with
        | None -> `Unlisted
        | Some pinned_b64 ->
          if identity_pk = "" then `ListedNoPk
          else
            let submitted_b64 =
              Base64.encode_string ~pad:false
                ~alphabet:Base64.uri_safe_alphabet identity_pk
            in
            if submitted_b64 = pinned_b64 then `Allowed
            else `AllowMismatch
      in
      match allow_state with
      | `AllowMismatch | `ListedNoPk ->
        let dummy = RegistrationLease.make ~node_id ~session_id ~alias ~client_type ~ttl ~identity_pk ~enc_pubkey ~signed_at ~sig_b64 ~opaque_host_id:opaque_host_id () in
        ("alias_not_allowed", dummy)
      | `Unlisted | `Allowed ->
      let now = Unix.gettimeofday () in
      (match Hashtbl.find_opt t.leases alias with
       | Some ex when alias_released ~now ~last_seen:(RegistrationLease.last_seen ex) ->
         release_alias t alias
       | _ -> ());
      let binding_state =
        if identity_pk = "" then `NoNewPk
        else
          match Hashtbl.find_opt t.bindings alias with
          | None -> `BindNew
          | Some pk when pk = identity_pk -> `Matches
          | Some _ -> `Mismatch
      in
      match binding_state with
      | `Mismatch ->
        let dummy = RegistrationLease.make ~node_id ~session_id ~alias ~client_type ~ttl ~identity_pk ~enc_pubkey ~signed_at ~sig_b64 ~opaque_host_id:opaque_host_id () in
        (relay_err_alias_identity_mismatch, dummy)
      | _ ->
        let existing = Hashtbl.find_opt t.leases alias in
        (match existing with
         | Some ex when not (alias_released ~now ~last_seen:(RegistrationLease.last_seen ex))
                     && RegistrationLease.node_id ex <> node_id
                     && not (identity_pk <> "" && RegistrationLease.identity_pk ex = identity_pk) ->
           (relay_err_alias_conflict, ex)
         | _ ->
           let old_inbox_msgs, conflict =
             match existing with
             | Some ex when RegistrationLease.is_alive ex
                         && RegistrationLease.session_id ex <> session_id ->
               let old_key = inbox_key (RegistrationLease.node_id ex) (RegistrationLease.session_id ex) in
               let msgs = get_inbox t old_key in
               if msgs <> [] then set_inbox t old_key [];
               (msgs, None)
             | _ -> ([], None)
           in
           match conflict with
           | Some ex -> (relay_err_alias_conflict, ex)
           | None ->
             let effective_pk =
               if identity_pk <> "" then identity_pk
               else Option.value ~default:"" (Hashtbl.find_opt t.bindings alias)
             in
             let lease = RegistrationLease.make ~node_id ~session_id ~alias ~client_type ~ttl ~identity_pk:effective_pk ~enc_pubkey ~signed_at ~sig_b64 ~opaque_host_id:opaque_host_id () in
             Hashtbl.replace t.leases alias lease;
             (match binding_state with
              | `BindNew -> Hashtbl.replace t.bindings alias identity_pk
              | _ -> ());
             let key = inbox_key node_id session_id in
             if not (Hashtbl.mem t.inboxes key) then set_inbox t key [];
             if old_inbox_msgs <> [] then set_inbox t key (List.append old_inbox_msgs (get_inbox t key));
             ("ok", lease))
    )


  let identity_pk_of t ~alias =
    let alias, _ = normalize_relay_alias ~alias ~opaque_host_id:None in
    with_lock t (fun () ->
      let now = Unix.gettimeofday () in
      match Hashtbl.find_opt t.leases alias, Hashtbl.find_opt t.bindings alias with
      | Some lease, Some pk
        when not (alias_released ~now ~last_seen:(RegistrationLease.last_seen lease)) ->
        Some pk
      | _ -> None)

  let alias_of_identity_pk t ~identity_pk =
    with_lock t (fun () ->
      let now = Unix.gettimeofday () in
      let result = ref None in
      Hashtbl.iter (fun alias pk ->
        match Hashtbl.find_opt t.leases alias with
        | Some lease
          when pk = identity_pk
               && not (alias_released ~now ~last_seen:(RegistrationLease.last_seen lease)) ->
          result := Some alias
        | _ -> ()
      ) t.bindings;
      !result
    )

  let alias_of_session t ~node_id ~session_id =
    with_lock t (fun () ->
      let now = Unix.gettimeofday () in
      let result = ref None in
      Hashtbl.iter (fun alias lease ->
        if RegistrationLease.node_id lease = node_id &&
           RegistrationLease.session_id lease = session_id &&
           not (alias_released ~now ~last_seen:(RegistrationLease.last_seen lease)) then
          result := Some alias
      ) t.leases;
      !result
    )

  (* S5a: In-memory pairing token store *)
  let store_pairing_token t ~binding_id ~token_b64 ~machine_ed25519_pubkey ~expires_at =
    Hashtbl.replace t.pairing_tokens binding_id (token_b64, machine_ed25519_pubkey, expires_at);
    Res.Ok ()

  let get_and_burn_pairing_token t ~binding_id =
    let now = Unix.gettimeofday () in
    match Hashtbl.find_opt t.pairing_tokens binding_id with
    | None -> None
    | Some (token_b64, machine_ed25519_pubkey, expires_at) ->
      if now > expires_at then
        (Hashtbl.remove t.pairing_tokens binding_id; None)
      else
        (Hashtbl.remove t.pairing_tokens binding_id;
         Some (token_b64, machine_ed25519_pubkey))

  let find_pairing_token t ~binding_id =
    match Hashtbl.find_opt t.pairing_tokens binding_id with
    | None -> false
    | Some (_, _, expires_at) ->
      let now = Unix.gettimeofday () in
      if now > expires_at then (Hashtbl.remove t.pairing_tokens binding_id; false)
      else true

  (* S5a: In-memory observer bindings *)
  let add_observer_binding t ~binding_id ~phone_ed25519_pubkey ~phone_x25519_pubkey ~machine_ed25519_pubkey:_ ~provenance_sig:_ =
    Hashtbl.replace t.observer_bindings_mem binding_id (phone_ed25519_pubkey, phone_x25519_pubkey)

  let get_observer_binding t ~binding_id =
    Option.map (fun (ed, x) -> (ed, x, "", "")) (Hashtbl.find_opt t.observer_bindings_mem binding_id)

  let remove_observer_binding t ~binding_id =
    Hashtbl.remove t.observer_bindings_mem binding_id

  (* S5b: Device-pair pending state accessors *)
  let get_device_pair_pending t ~user_code =
    Hashtbl.find_opt t.device_pair_pending_mem user_code

  let set_device_pair_pending t ~user_code pending =
    Hashtbl.replace t.device_pair_pending_mem user_code pending

  let remove_device_pair_pending t ~user_code =
    Hashtbl.remove t.device_pair_pending_mem user_code

  let query_messages_since t ~alias ~since_ts =
    let query_alias, _ = normalize_relay_alias ~alias ~opaque_host_id:None in
    with_lock t (fun () ->
      let results = ref [] in
      let min_ts = max since_ts (Unix.gettimeofday () -. 86400.0) in
      Hashtbl.iter (fun alias' lease ->
        if alias_matches_display ~query:query_alias alias' then (
          let key = (RegistrationLease.node_id lease, RegistrationLease.session_id lease) in
          match Hashtbl.find_opt t.inboxes key with
          | Some msgs ->
            List.iter (fun msg ->
              match msg with
              | `Assoc fields ->
                let ts = try List.assoc "ts" fields |> function `Float f -> f | `Int i -> float_of_int i | _ -> 0.0 with _ -> 0.0 in
                let from = try match List.assoc "from_alias" fields with `String s -> s | _ -> "" with _ -> "" in
                let to_ = try match List.assoc "to_alias" fields with `String s -> s | _ -> "" with _ -> "" in
                if ts > min_ts
                   && (alias_matches_display ~query:query_alias from
                       || alias_matches_display ~query:query_alias to_)
                then results := msg :: !results
              | _ -> ()
            ) msgs
          | None -> ()
        )
      ) t.leases;
      List.rev !results
    )

  let enc_pubkey_of t ~alias =
    with_lock t (fun () ->
      let now = Unix.gettimeofday () in
      match Hashtbl.find_opt t.leases alias with
      | Some lease when not (alias_released ~now ~last_seen:(RegistrationLease.last_seen lease)) ->
        let ek = RegistrationLease.enc_pubkey lease in
        if ek = "" then None else Some ek
      | None -> None
      | Some _ -> None
    )

  let registered_at_of t ~alias =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.leases alias with
      | Some lease -> Some (RegistrationLease.registered_at lease)
      | None -> None
    )

  let signed_at_of t ~alias =
    with_lock t (fun () ->
      let now = Unix.gettimeofday () in
      match Hashtbl.find_opt t.leases alias with
      | Some lease when not (alias_released ~now ~last_seen:(RegistrationLease.last_seen lease)) ->
        let sa = RegistrationLease.signed_at lease in
        if sa = 0.0 then None else Some sa
      | None -> None
      | Some _ -> None
    )

  let sig_b64_of t ~alias =
    with_lock t (fun () ->
      let now = Unix.gettimeofday () in
      match Hashtbl.find_opt t.leases alias with
      | Some lease when not (alias_released ~now ~last_seen:(RegistrationLease.last_seen lease)) ->
        let sb = RegistrationLease.sig_b64 lease in
        if sb = "" then None else Some sb
      | None -> None
      | Some _ -> None
    )

  let set_allowed_identity t ~alias ~identity_pk_b64 =
    with_lock t (fun () -> Hashtbl.replace t.allowed_identities alias identity_pk_b64)

  let allowed_identity_of t ~alias =
    with_lock t (fun () -> Hashtbl.find_opt t.allowed_identities alias)

  let check_allowlist t ~alias ~identity_pk_b64 =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.allowed_identities alias with
      | None -> `Unlisted
      | Some pinned ->
        if identity_pk_b64 = pinned then `Allowed else `Mismatch)

  let unbind_alias t ~alias =
    with_lock t (fun () ->
      let had = Hashtbl.mem t.bindings alias in
      Hashtbl.remove t.bindings alias;
      Hashtbl.remove t.leases alias;
      had)

  let check_nonce_in tbl ~ttl ~nonce ~ts =
    let cutoff = ts -. ttl in
    let expired = ref [] in
    Hashtbl.iter (fun n t0 -> if t0 < cutoff then expired := n :: !expired) tbl;
    List.iter (Hashtbl.remove tbl) !expired;
    if Hashtbl.mem tbl nonce then Res.Error relay_err_nonce_replay
    else (Hashtbl.replace tbl nonce ts; Res.Ok ())

  let check_register_nonce t ~nonce ~ts =
    with_lock t (fun () ->
      check_nonce_in t.register_nonces ~ttl:register_nonce_ttl ~nonce ~ts)

  let check_request_nonce t ~nonce ~ts =
    with_lock t (fun () ->
      check_nonce_in t.request_nonces ~ttl:request_nonce_ttl ~nonce ~ts)

  let heartbeat t ~node_id ~session_id =
    with_lock t (fun () ->
      let now = Unix.gettimeofday () in
      let found = ref None in
      Hashtbl.iter (fun alias lease ->
        if RegistrationLease.node_id lease = node_id
           && RegistrationLease.session_id lease = session_id then
          found := Some (alias, lease)
      ) t.leases;
      match !found with
      | None ->
         let dummy_lease = RegistrationLease.make ~node_id ~session_id ~alias:"_error" () in
         (relay_err_unknown_alias, dummy_lease)
      | Some (alias, lease) when alias_released ~now ~last_seen:(RegistrationLease.last_seen lease) ->
         release_alias t alias;
         let dummy_lease = RegistrationLease.make ~node_id ~session_id ~alias:"_error" () in
         (relay_err_unknown_alias, dummy_lease)
      | Some (_alias, lease) ->
         RegistrationLease.touch lease;
         ("ok", lease)
    )

  let list_peers t ?(include_dead = false) =
    with_lock t (fun () ->
      let now = Unix.gettimeofday () in
      Hashtbl.fold (fun _ lease acc ->
        let last_seen = RegistrationLease.last_seen lease in
        if not (alias_released ~now ~last_seen)
           && (include_dead || RegistrationLease.is_alive lease)
        then
          lease :: acc
        else acc
      ) t.leases []
    )

  let alias_of_session t ~node_id ~session_id =
    with_lock t (fun () ->
      let now = Unix.gettimeofday () in
      let found = ref None in
      Hashtbl.iter (fun alias lease ->
        if RegistrationLease.node_id lease = node_id
           && RegistrationLease.session_id lease = session_id
           && not (alias_released ~now ~last_seen:(RegistrationLease.last_seen lease)) then
          found := Some alias
      ) t.leases;
      !found
    )

  let send t ~from_alias ~to_alias ~content ?(message_id = None) =
    with_lock t (fun () ->
      let msg_id = match message_id with Some id -> id | None -> generate_uuid () in
      let ts = Unix.gettimeofday () in
      (* #686: strip any "@host:port" suffix so bare alias is used for
         the leases hashtbl lookup. The to_alias from the wire may be
         "alias@host:port" (from remote connectors); only the bare alias
         is registered. *)
      let bare_to_alias = bare_alias to_alias in
      let recipient = Hashtbl.find_opt t.leases bare_to_alias in
      match recipient with
      | None ->
        let dl = `Assoc [
          ("ts", `Float ts); ("message_id", `String msg_id);
          ("from_alias", `String from_alias); ("to_alias", `String to_alias);
          ("content", `String content); ("reason", `String "unknown_alias");
        ] in
        Queue.add dl t.dead_letter;
        `Error (relay_err_unknown_alias, Printf.sprintf "no registration for alias %S" to_alias)
      | Some lease when alias_released ~now:ts ~last_seen:(RegistrationLease.last_seen lease) ->
        let dl = `Assoc [
          ("ts", `Float ts); ("message_id", `String msg_id);
          ("from_alias", `String from_alias); ("to_alias", `String to_alias);
          ("content", `String content); ("reason", `String "unknown_alias");
        ] in
        Queue.add dl t.dead_letter;
        `Error (relay_err_unknown_alias, Printf.sprintf "no registration for alias %S" to_alias)
      | Some lease when not (RegistrationLease.is_alive lease) ->
        let dl = `Assoc [
          ("ts", `Float ts); ("message_id", `String msg_id);
          ("from_alias", `String from_alias); ("to_alias", `String to_alias);
          ("content", `String content); ("reason", `String "recipient_dead");
        ] in
        Queue.add dl t.dead_letter;
        `Error (relay_err_recipient_dead, Printf.sprintf "alias %S is registered but lease has expired" to_alias)
      | Some lease ->
        if not (record_message_id t msg_id) then
          `Duplicate ts
        else begin
          let key = inbox_key (RegistrationLease.node_id lease) (RegistrationLease.session_id lease) in
          let msg = `Assoc [
            ("message_id", `String msg_id); ("from_alias", `String from_alias);
            ("to_alias", `String to_alias); ("content", `String content); ("ts", `Float ts);
          ] in
          let inbox = get_inbox t key in
          set_inbox t key (msg :: inbox);
          `Ok ts
        end
    )

  let poll_inbox t ~node_id ~session_id =
    with_lock t (fun () ->
      let key = inbox_key node_id session_id in
      let msgs = get_inbox t key in
      set_inbox t key [];
      msgs
    )

  let peek_inbox t ~node_id ~session_id =
    with_lock t (fun () ->
      let key = inbox_key node_id session_id in
      get_inbox t key
    )

  let dead_letter t =
    with_lock t (fun () ->
      List.rev (Queue.fold (fun acc x -> x :: acc) [] t.dead_letter)
    )

  let add_dead_letter t msg =
    with_lock t (fun () -> Queue.add msg t.dead_letter)

  let join_room t ?(visibility = "public") ~alias ~room_id () =
    let visibility = canonical_visibility_exn visibility in
    with_lock t (fun () ->
      let now = Unix.gettimeofday () in
      match Hashtbl.find_opt t.leases alias with
      | None ->
        `Error (relay_err_unknown_alias, Printf.sprintf "alias %S is not registered" alias)
      | Some lease when alias_released ~now ~last_seen:(RegistrationLease.last_seen lease) ->
        release_alias t alias;
        `Error (relay_err_unknown_alias, Printf.sprintf "alias %S is not registered" alias)
      | Some _lease ->
        let members = match Hashtbl.find_opt t.rooms room_id with
          | Some m -> m | None -> []
        in
        (* Visibility is set only when the room is first created (this join is
           creating it). Later joiners passing a visibility have no effect —
           changes after creation go through the signed set_room_visibility op. *)
        if not (Hashtbl.mem t.room_visibility room_id) then
          Hashtbl.replace t.room_visibility room_id visibility;
        let already_member = List.mem alias members in
        let members' = if already_member then members else alias :: members in
        Hashtbl.replace t.rooms room_id members';
        if not (Hashtbl.mem t.room_history room_id) then
          Hashtbl.replace t.room_history room_id [];
        if not already_member then begin
          let ts = Unix.gettimeofday () in
        let msg_id = Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ()) in
          let content = room_join_content alias room_id in
          let hist_msg = `Assoc [
            ("message_id", `String msg_id); ("from_alias", `String room_system_alias);
            ("room_id", `String room_id); ("content", `String content); ("ts", `Float ts);
          ] in
          let hist = Hashtbl.find t.room_history room_id in
          Hashtbl.replace t.room_history room_id (hist_msg :: hist);
          Option.iter (fun d -> append_room_history_to_disk d room_id hist_msg) t.persist_dir;
          List.iter (fun member_alias ->
            match Hashtbl.find_opt t.leases member_alias with
            | None ->
              let dl = `Assoc [
                ("message_id", `String msg_id); ("from_alias", `String room_system_alias);
                ("to_alias", `String (member_alias ^ "#" ^ room_id)); ("content", `String content);
                ("ts", `Float ts); ("room_id", `String room_id); ("reason", `String "recipient_dead");
              ] in Queue.add dl t.dead_letter
            | Some lease ->
              if RegistrationLease.is_alive lease then
                let key = inbox_key (RegistrationLease.node_id lease) (RegistrationLease.session_id lease) in
                let msg = `Assoc [
                  ("message_id", `String msg_id); ("from_alias", `String room_system_alias);
                  ("to_alias", `String (member_alias ^ "#" ^ room_id)); ("content", `String content);
                  ("ts", `Float ts); ("room_id", `String room_id);
                ] in
                let inbox = get_inbox t key in set_inbox t key (msg :: inbox)
              else
                let dl = `Assoc [
                  ("message_id", `String msg_id); ("from_alias", `String room_system_alias);
                  ("to_alias", `String (member_alias ^ "#" ^ room_id)); ("content", `String content);
                  ("ts", `Float ts); ("room_id", `String room_id); ("reason", `String "recipient_dead");
                ] in Queue.add dl t.dead_letter
          ) members'
        end;
        `Ok
    )

  let leave_room t ~alias ~room_id =
    with_lock t (fun () ->
      let members = match Hashtbl.find_opt t.rooms room_id with
        | Some m -> m | None -> []
      in
      let removed = List.mem alias members in
      let members' = if removed then List.filter ((<>) alias) members else members in
      Hashtbl.replace t.rooms room_id members';
      if removed && members' <> [] then begin
        let ts = Unix.gettimeofday () in
        let msg_id = generate_uuid () in
        let content = room_leave_content alias room_id in
        let hist_msg = `Assoc [
          ("message_id", `String msg_id); ("from_alias", `String room_system_alias);
          ("room_id", `String room_id); ("content", `String content); ("ts", `Float ts);
        ] in
        (match Hashtbl.find_opt t.room_history room_id with
         | Some hist -> Hashtbl.replace t.room_history room_id (hist_msg :: hist)
         | None -> ());
        Option.iter (fun d -> append_room_history_to_disk d room_id hist_msg) t.persist_dir;
        List.iter (fun member_alias ->
          match Hashtbl.find_opt t.leases member_alias with
          | None ->
            let dl = `Assoc [
              ("message_id", `String msg_id); ("from_alias", `String room_system_alias);
              ("to_alias", `String (member_alias ^ "#" ^ room_id)); ("content", `String content);
              ("ts", `Float ts); ("room_id", `String room_id); ("reason", `String "recipient_dead");
            ] in Queue.add dl t.dead_letter
          | Some lease ->
            if RegistrationLease.is_alive lease then
              let key = inbox_key (RegistrationLease.node_id lease) (RegistrationLease.session_id lease) in
              let msg = `Assoc [
                ("message_id", `String msg_id); ("from_alias", `String room_system_alias);
                ("to_alias", `String (member_alias ^ "#" ^ room_id)); ("content", `String content);
                ("ts", `Float ts); ("room_id", `String room_id);
              ] in
              let inbox = get_inbox t key in set_inbox t key (msg :: inbox)
            else
              let dl = `Assoc [
                ("message_id", `String msg_id); ("from_alias", `String room_system_alias);
                ("to_alias", `String (member_alias ^ "#" ^ room_id)); ("content", `String content);
                ("ts", `Float ts); ("room_id", `String room_id); ("reason", `String "recipient_dead");
              ] in Queue.add dl t.dead_letter
        ) members'
      end;
      `Ok
    )

  (* Layer 4 slice 5 helpers — visibility + invited_pk list. *)
  let room_exists t ~room_id =
    with_lock t (fun () -> Hashtbl.mem t.rooms room_id)

  let room_visibility_of t ~room_id =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.room_visibility room_id with
      | Some v -> canonical_visibility_or_raw v | None -> "public")

  let room_invites_of t ~room_id =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.room_invites room_id with
      | Some l -> l | None -> [])

  let is_invited t ~room_id ~identity_pk_b64 =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.room_invites room_id with
      | None -> false
      | Some l -> List.mem identity_pk_b64 l)

  let set_room_visibility t ~room_id ~visibility =
    let visibility = canonical_visibility_exn visibility in
    with_lock t (fun () ->
      Hashtbl.replace t.room_visibility room_id visibility)

  let invite_to_room t ~room_id ~identity_pk_b64 =
    with_lock t (fun () ->
      let cur = match Hashtbl.find_opt t.room_invites room_id with
        | Some l -> l | None -> [] in
      if not (List.mem identity_pk_b64 cur) then
        Hashtbl.replace t.room_invites room_id (identity_pk_b64 :: cur))

  let uninvite_from_room t ~room_id ~identity_pk_b64 =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.room_invites room_id with
      | None -> ()
      | Some l ->
        Hashtbl.replace t.room_invites room_id
          (List.filter ((<>) identity_pk_b64) l))

  let room_knocks_of t ~room_id =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.room_knocks room_id with
      | Some l -> List.rev l
      | None -> [])

  let remove_room_knock t ~room_id ~requester_pk =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.room_knocks room_id with
      | None -> None
      | Some l ->
        let removed, kept =
          List.fold_left (fun (removed, kept) k ->
            if k.requester_pk = requester_pk then
              (Some k, kept)
            else
              (removed, k :: kept))
            (None, []) l
        in
        Hashtbl.replace t.room_knocks room_id kept;
        removed)

  let is_room_member_alias t ~room_id ~alias =
    with_lock t (fun () ->
      let now = Unix.gettimeofday () in
      match Hashtbl.find_opt t.leases alias, Hashtbl.find_opt t.rooms room_id with
      | Some lease, Some members
        when not (alias_released ~now ~last_seen:(RegistrationLease.last_seen lease)) ->
        List.mem alias members
      | _ -> false)

  let knock_room t ~room_id ~requester_alias ~requester_pk =
    with_lock t (fun () ->
      if not (Hashtbl.mem t.rooms room_id) then
        `Error (relay_err_not_found,
          "room is not discoverable or does not accept knocks")
      else
        let visibility =
          match Hashtbl.find_opt t.room_visibility room_id with
          | Some v -> canonical_visibility_or_raw v
          | None -> "public"
        in
        if visibility = "public" || visibility = "unlisted" then
          `Error (relay_err_join_directly,
            Printf.sprintf "room %S is %s; join directly" room_id visibility)
        else if visibility <> "gated" then
          `Error (relay_err_not_found,
            "room is not discoverable or does not accept knocks")
        else
          let now = Unix.gettimeofday () in
          let already_member =
            match Hashtbl.find_opt t.leases requester_alias,
                  Hashtbl.find_opt t.rooms room_id with
            | Some lease, Some members
              when not (alias_released ~now ~last_seen:(RegistrationLease.last_seen lease)) ->
              List.mem requester_alias members
            | _ -> false
          in
          if already_member then
            `Error (relay_err_already_member,
              Printf.sprintf "alias %S is already a member of room %S"
                requester_alias room_id)
          else
            let invites =
              match Hashtbl.find_opt t.room_invites room_id with
              | Some l -> l
              | None -> []
            in
            if List.mem requester_pk invites then
              `Error (relay_err_already_invited,
                Printf.sprintf "requester is already invited to room %S" room_id)
            else
              let cur =
                match Hashtbl.find_opt t.room_knocks room_id with
                | Some l -> l
                | None -> []
              in
              if List.exists (fun k -> k.requester_pk = requester_pk) cur then
                `Ok true
              else begin
                let knock = {
                  requester_alias;
                  requester_pk;
                  requested_at = now;
                } in
                Hashtbl.replace t.room_knocks room_id (knock :: cur);
                `Ok false
              end)

  let send_room t ~from_alias ~room_id ~content ?(message_id = None) ?envelope () =
    with_lock t (fun () ->
      let msg_id = match message_id with Some id -> id | None -> generate_uuid () in
      let ts = Unix.gettimeofday () in
      let sender_active =
        match Hashtbl.find_opt t.leases from_alias with
        | Some lease when not (alias_released ~now:ts ~last_seen:(RegistrationLease.last_seen lease)) -> true
        | Some lease ->
          if alias_released ~now:ts ~last_seen:(RegistrationLease.last_seen lease) then
            release_alias t from_alias;
          false
        | None -> false
      in
      if not sender_active then
        `Error (relay_err_unknown_alias, Printf.sprintf "alias %S is not registered" from_alias)
      else
      let members = match Hashtbl.find_opt t.rooms room_id with
        | Some m -> m | None -> []
      in
      if not (List.mem from_alias members) then
        `Error (relay_err_not_a_member, Printf.sprintf "alias %S is not a member of room %S" from_alias room_id)
      else
      if members = [] then `Ok (ts, [], [])
      else begin
        let delivered_to = ref [] in
        let skipped = ref [] in
        (* L4/3: append envelope verbatim when the signed path was taken
           (spec §6/§7). Fan-out and history carry the full envelope so
           clients can re-verify sig on receipt. *)
        let with_envelope base = match envelope with
          | None -> base
          | Some e -> ("envelope", e) :: base
        in
        List.iter (fun alias ->
          if alias = from_alias then ()
          else begin
            match Hashtbl.find_opt t.leases alias with
            | None ->
              skipped := alias :: !skipped;
              let dl = `Assoc (with_envelope [
                ("message_id", `String msg_id); ("from_alias", `String from_alias);
                ("to_alias", `String (alias ^ "#" ^ room_id)); ("content", `String content);
                ("ts", `Float ts); ("room_id", `String room_id); ("reason", `String "recipient_dead");
              ]) in Queue.add dl t.dead_letter
            | Some lease ->
              if not (RegistrationLease.is_alive lease) then begin
                skipped := alias :: !skipped;
                let dl = `Assoc (with_envelope [
                  ("message_id", `String msg_id); ("from_alias", `String from_alias);
                  ("to_alias", `String (alias ^ "#" ^ room_id)); ("content", `String content);
                  ("ts", `Float ts); ("room_id", `String room_id); ("reason", `String "recipient_dead");
                ]) in Queue.add dl t.dead_letter
              end else begin
                delivered_to := alias :: !delivered_to;
                let key = inbox_key (RegistrationLease.node_id lease) (RegistrationLease.session_id lease) in
                let msg = `Assoc (with_envelope [
                  ("message_id", `String msg_id); ("from_alias", `String from_alias);
                  ("room_id", `String room_id); ("content", `String content); ("ts", `Float ts);
                ]) in
                let inbox = get_inbox t key in set_inbox t key (msg :: inbox)
              end
          end
        ) members;
        let hist_msg = `Assoc (with_envelope [
          ("message_id", `String msg_id); ("from_alias", `String from_alias);
          ("room_id", `String room_id); ("content", `String content); ("ts", `Float ts);
        ]) in
        let hist = match Hashtbl.find_opt t.room_history room_id with
          | Some h -> h | None -> []
        in
        Hashtbl.replace t.room_history room_id (hist_msg :: hist);
        (* Persist to disk when configured *)
        Option.iter (fun d -> append_room_history_to_disk d room_id hist_msg) t.persist_dir;
        `Ok (ts, List.rev !delivered_to, List.rev !skipped)
      end
    )

  let room_history t ~room_id ?(limit = 50) =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.room_history room_id with
      | None -> []
      | Some hist ->
        let len = List.length hist in
        if limit >= len then List.rev hist
        else
          let rec drop n lst = if n = 0 then lst else drop (n - 1) (List.tl lst) in
          List.rev (drop (len - limit) hist)
    )

  let list_rooms t =
    with_lock t (fun () ->
      Hashtbl.fold (fun room_id members acc ->
        (* Only public and gated rooms appear in the directory; unlisted and
           private rooms are reachable by id but never listed. Absent
           visibility (legacy in-memory rooms) defaults to public. *)
        let visibility = match Hashtbl.find_opt t.room_visibility room_id with
          | Some v -> v | None -> "public" in
        if not (visibility = "public" || visibility = "gated") then acc
        else
          `Assoc [
            ("room_id", `String room_id);
            ("member_count", `Int (List.length members));
            ("members", `List (List.map (fun a -> `String a) members));
          ] :: acc
      ) t.rooms []
    )

  let send_all t ~from_alias ~content ?(message_id = None) =
    with_lock t (fun () ->
      let msg_id = match message_id with Some id -> id | None -> generate_uuid () in
      let ts = Unix.gettimeofday () in
      let delivered_to = ref [] in
      let skipped = ref [] in
      Hashtbl.iter (fun alias lease ->
        if alias = from_alias then ()
        else if not (RegistrationLease.is_alive lease) then skipped := alias :: !skipped
        else begin
          delivered_to := alias :: !delivered_to;
          let key = inbox_key (RegistrationLease.node_id lease) (RegistrationLease.session_id lease) in
          let msg = `Assoc [
            ("message_id", `String msg_id); ("from_alias", `String from_alias);
            ("to_alias", `String alias); ("content", `String content); ("ts", `Float ts);
          ] in
          let inbox = get_inbox t key in set_inbox t key (msg :: inbox)
        end
      ) t.leases;
      `Ok (ts, List.rev !delivered_to, List.rev !skipped)
    )

  let gc t =
    with_lock t (fun () ->
      let expired = ref [] in
      let now = Unix.gettimeofday () in
      Hashtbl.iter (fun alias lease ->
        let last_seen = RegistrationLease.last_seen lease in
        if alias_released ~now ~last_seen then
          expired := alias :: !expired
      ) t.leases;
      List.iter (fun alias ->
        release_alias t alias
      ) !expired;
      let live_keys = ref [] in
      Hashtbl.iter (fun _ lease ->
        live_keys := (RegistrationLease.node_id lease, RegistrationLease.session_id lease) :: !live_keys
      ) t.leases;
      let stale_keys = ref [] in
      Hashtbl.iter (fun key _ ->
        if not (List.mem key !live_keys) then
          stale_keys := key :: !stale_keys
      ) t.inboxes;
      let pruned = List.length !stale_keys in
      List.iter (fun k -> Hashtbl.remove t.inboxes k) !stale_keys;
      `Ok (List.rev !expired, pruned)
    )
end

(* --- SqliteRelay --- *)

module SqliteRelay : RELAY = struct
  type t = {
    db_path : string;
    dedup_window : int;
    mutex : Mutex.t;
    observer_bindings : ObserverBindings.t;
    self_host : string option;
    (* #330 S1: peer relays for cross-relay forwarding (in-memory, populated at boot from CLI) *)
    peer_relays : (string, peer_relay_t) Hashtbl.t;
    (* #330 S2: this relay's own Ed25519 identity for signing forward requests *)
    identity : Relay_identity.t;
  }

  let sqlite_table_has_column conn ~table ~column =
    let info_stmt = Sqlite3.prepare conn (Printf.sprintf "PRAGMA table_info(%s)" table) in
    let found = ref false in
    let rec loop () =
      let rc = Sqlite3.step info_stmt in
      if rc = Sqlite3.Rc.ROW then begin
        let col_name = Sqlite3.Data.to_string_exn (Sqlite3.column info_stmt 1) in
        if col_name = column then found := true;
        loop ()
      end
    in
    (try loop () with _ -> ());
    (try Sqlite3.finalize info_stmt |> ignore with _ -> ());
    !found

  let create ?(dedup_window=10000) ?(persist_dir="") ?(self_host=None) ?(peer_relays=Hashtbl.create 2) () =
    let db_path = Filename.concat persist_dir "c2c_relay.db" in
    let mutex = Mutex.create () in
    let conn = Sqlite3.db_open db_path in
    Sqlite3.exec conn "PRAGMA busy_timeout = 5000; PRAGMA journal_mode = WAL;" |> ignore;
    Sqlite3.exec conn sqlite_ddl |> ignore;
    (* #586 (slice 1): migrate older databases to the opaque_host_id
       column. `CREATE TABLE IF NOT EXISTS` does not add new columns
       to an existing leases table, so we probe pragma_table_info and
       ALTER if the column is missing. Idempotent on fresh installs
       (the column is already declared in sqlite_ddl). *)
    if not (sqlite_table_has_column conn ~table:"leases" ~column:"opaque_host_id") then
      Sqlite3.exec conn "ALTER TABLE leases ADD COLUMN opaque_host_id TEXT NOT NULL DEFAULT ''" |> ignore;
    if not (sqlite_table_has_column conn ~table:"rooms" ~column:"visibility") then
      Sqlite3.exec conn "ALTER TABLE rooms ADD COLUMN visibility TEXT NOT NULL DEFAULT 'public'" |> ignore;
    (* #330 S2: load or generate this relay's Ed25519 identity for cross-relay signing *)
    let identity_path = if persist_dir = "" then None else Some (Filename.concat persist_dir "relay-server-identity.json") in
    let identity =
      match identity_path with
      | Some p -> Relay_identity.load_or_create_at ~path:p ~alias_hint:(Option.value self_host ~default:"relay")
      | None -> Relay_identity.generate ~alias_hint:(Option.value self_host ~default:"relay") ()
    in
    { db_path; dedup_window; mutex; observer_bindings = ObserverBindings.create (); self_host; peer_relays; identity }

  let with_lock t f =
    Mutex.lock t.mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

  let self_host t = t.self_host
  (* #330 S2: relay identity for cross-relay signing *)
  let relay_identity t = t.identity

  (* #330 S1: peer_relay accessors *)
  let add_peer_relay t pr = Hashtbl.replace t.peer_relays pr.name pr
  let peer_relay_of t ~name = Hashtbl.find_opt t.peer_relays name
  let peer_relays_list t = Hashtbl.fold (fun _ v acc -> v :: acc) t.peer_relays []

  let get_lease_row_fields row =
    match row with
    | [alias; node_id; session_id; client_type; registered_at; last_seen; ttl; identity_pk; enc_pubkey; signed_at; sig_b64; opaque_host_id] ->
      let alias = match alias with Some s -> s | None -> "" in
      let node_id = match node_id with Some s -> s | None -> "" in
      let session_id = match session_id with Some s -> s | None -> "" in
      let client_type = match client_type with Some s -> s | None -> "unknown" in
      let registered_at = match registered_at with Some s -> float_of_string s | None -> 0.0 in
      let last_seen = match last_seen with Some s -> float_of_string s | None -> 0.0 in
      let ttl = match ttl with Some s -> float_of_string s | None -> default_lease_ttl in
      let identity_pk = match identity_pk with Some s -> s | None -> "" in
      let enc_pubkey = match enc_pubkey with Some s -> s | None -> "" in
      let signed_at = match signed_at with Some s -> float_of_string s | None -> 0.0 in
      let sig_b64 = match sig_b64 with Some s -> s | None -> "" in
      let opaque_host_id = match opaque_host_id with Some s when s <> "" -> Some s | _ -> None in
      (alias,
       RegistrationLease.make
         ~node_id
         ~session_id
         ~alias
         ~client_type
         ~registered_at
         ~last_seen
         ~ttl
         ~identity_pk
         ~enc_pubkey
         ~signed_at
         ~sig_b64
         ~opaque_host_id:opaque_host_id
         ())
    | _ -> failwith "Invalid lease row"

  let lease_of_row row =
    let (_alias, lease) = get_lease_row_fields row in lease

  let is_alive_lease_row row =
    try
      let lease = lease_of_row row in
      RegistrationLease.is_alive lease
    with _ -> false

  let row_to_string_opt = function Some s -> s | None -> ""
  let data_to_float_default col =
    match Sqlite3.Data.to_float col with
    | Some f -> f
    | None -> float_of_string (Sqlite3.Data.to_string_exn col)

  let release_alias conn alias =
    let old_key_stmt = Sqlite3.prepare conn "SELECT node_id, session_id FROM leases WHERE alias = ?" in
    Sqlite3.bind_text old_key_stmt 1 alias |> ignore;
    (match Sqlite3.step old_key_stmt with
     | Rc.ROW ->
       let node_id = Sqlite3.Data.to_string_exn (Sqlite3.column old_key_stmt 0) in
       let session_id = Sqlite3.Data.to_string_exn (Sqlite3.column old_key_stmt 1) in
       let del_inbox = Sqlite3.prepare conn "DELETE FROM inboxes WHERE node_id = ? AND session_id = ?" in
       Sqlite3.bind_text del_inbox 1 node_id |> ignore;
       Sqlite3.bind_text del_inbox 2 session_id |> ignore;
       Sqlite3.step del_inbox |> ignore
     | _ -> ());
    let del = Sqlite3.prepare conn "DELETE FROM leases WHERE alias = ?" in
    Sqlite3.bind_text del 1 alias |> ignore;
    Sqlite3.step del |> ignore;
    let del_member = Sqlite3.prepare conn "DELETE FROM room_members WHERE alias = ?" in
    Sqlite3.bind_text del_member 1 alias |> ignore;
    Sqlite3.step del_member |> ignore

  let register t ~node_id ~session_id ~alias ?(client_type="unknown") ?(ttl=default_lease_ttl) ?(identity_pk="") ?(enc_pubkey="") ?(signed_at=0.0) ?(sig_b64="") ?(opaque_host_id : string option = None) () =
    with_lock t (fun () ->
      let open Sqlite3 in
      let conn = db_open t.db_path in
      let now = Unix.gettimeofday () in
      if not (C2c_name.is_valid_with_opaque_host_id alias) then
        let dummy = RegistrationLease.make ~node_id ~session_id ~alias ~client_type ~ttl ~identity_pk ~enc_pubkey ~signed_at ~sig_b64 ~opaque_host_id:opaque_host_id () in
        ("invalid_alias", dummy)
      else
      let alias, opaque_host_id = normalize_relay_alias ~alias ~opaque_host_id in
      let allow_state =
        if identity_pk <> "" then
          let submitted_b64 = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet identity_pk in
          let has_row = exec_prepared conn "SELECT identity_pk_b64 FROM allowed_identities WHERE alias = ?" [`Text alias] in
          if not has_row then `Unlisted
          else
            let stmt = prepare conn "SELECT identity_pk_b64 FROM allowed_identities WHERE alias = ?" in
            bind_text stmt 1 alias |> ignore;
            let rc = step stmt in
            if rc = ROW then
              let pinned = Data.to_string_exn (column stmt 0) in
              if submitted_b64 = pinned then `Allowed else `Mismatch
            else `Unlisted
        else
          let has_row = exec_prepared conn "SELECT identity_pk_b64 FROM allowed_identities WHERE alias = ?" [`Text alias] in
          if not has_row then `Unlisted else `ListedNoPk
      in
      match allow_state with
      | `Mismatch | `ListedNoPk ->
        let dummy = RegistrationLease.make ~node_id ~session_id ~alias ~client_type ~ttl ~identity_pk ~enc_pubkey ~signed_at ~sig_b64 () in
        ("alias_not_allowed", dummy)
      | `Unlisted | `Allowed ->
        let has_row = exec_prepared conn "SELECT node_id, session_id, registered_at, last_seen, ttl, identity_pk FROM leases WHERE alias = ?" [`Text alias] in
        let conflict_lease = ref None in
        let existing_pk = ref "" in
        if has_row then (
          let stmt = prepare conn "SELECT node_id, session_id, registered_at, last_seen, ttl, identity_pk FROM leases WHERE alias = ?" in
          bind_text stmt 1 alias |> ignore;
          let rec check_existing () =
            let rc = step stmt in
            if rc = ROW then (
              let row_node_id = Data.to_string_exn (column stmt 0) in
              let row_session_id = Data.to_string_exn (column stmt 1) in
              let row_registered_at =
                let col = column stmt 2 in
                match Data.to_float col with
                | Some f -> f
                | None -> float_of_string (Data.to_string_exn col)
              in
              let row_last_seen =
                let col = column stmt 3 in
                match Data.to_float col with
                | Some f -> f
                | None -> float_of_string (Data.to_string_exn col)
              in
              let row_ttl =
                let col = column stmt 4 in
                match Data.to_float col with
                | Some f -> f
                | None -> float_of_string (Data.to_string_exn col)
              in
              let row_pk = Data.to_string_exn (column stmt 5) in
              let released = alias_released ~now ~last_seen:row_last_seen in
              if released then release_alias conn alias
              else existing_pk := row_pk;
              let same_identity = identity_pk <> "" && row_pk = identity_pk in
              if (not released) && row_node_id <> node_id && not same_identity then (
                conflict_lease := Some (
                  RegistrationLease.make
                    ~node_id:row_node_id
                    ~session_id:row_session_id
                    ~alias
                    ~client_type
                    ~registered_at:row_registered_at
                    ~last_seen:row_last_seen
                    ~ttl:row_ttl
                    ~identity_pk:row_pk
                    ~enc_pubkey
                    ~signed_at
                    ~sig_b64
                    ())
              ) else
                check_existing ()
            ) else if rc <> DONE then
              failwith ("step error: " ^ Rc.to_string rc)
          in
          check_existing ()
        );
        match !conflict_lease with
        | Some lease -> (relay_err_alias_conflict, lease)
        | None ->
          let binding_state =
            if identity_pk <> "" then
              if !existing_pk <> "" && !existing_pk <> identity_pk then `Mismatch
              else `Matches
            else
              if !existing_pk <> "" then `Preserve
              else `NoPkNoBinding
          in
          match binding_state with
          | `Mismatch ->
            let dummy = RegistrationLease.make ~node_id ~session_id ~alias ~client_type ~ttl ~identity_pk ~enc_pubkey ~signed_at ~sig_b64 () in
            (relay_err_alias_identity_mismatch, dummy)
          | _ ->
            let effective_pk = match binding_state with
              | `Preserve -> !existing_pk
              | `Matches -> identity_pk
              | `NoPkNoBinding -> ""
              | `Mismatch -> assert false
            in
            let stmt = prepare conn "INSERT INTO leases (alias, node_id, session_id, client_type, registered_at, last_seen, ttl, identity_pk, enc_pubkey, signed_at, sig_b64, opaque_host_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(alias) DO UPDATE SET node_id=excluded.node_id, session_id=excluded.session_id, client_type=excluded.client_type, last_seen=excluded.last_seen, ttl=excluded.ttl, identity_pk=excluded.identity_pk, enc_pubkey=excluded.enc_pubkey, signed_at=excluded.signed_at, sig_b64=excluded.sig_b64, opaque_host_id=excluded.opaque_host_id" in
            bind_text stmt 1 alias |> ignore;
            bind_text stmt 2 node_id |> ignore;
            bind_text stmt 3 session_id |> ignore;
            bind_text stmt 4 client_type |> ignore;
            bind_double stmt 5 now |> ignore;
            bind_double stmt 6 now |> ignore;
            bind_double stmt 7 ttl |> ignore;
            bind_text stmt 8 effective_pk |> ignore;
            bind_text stmt 9 enc_pubkey |> ignore;
            bind_double stmt 10 signed_at |> ignore;
            bind_text stmt 11 sig_b64 |> ignore;
            let opaque_host_id_str = match opaque_host_id with Some s -> s | None -> "" in
            bind_text stmt 12 opaque_host_id_str |> ignore;
            let rc = step stmt in
            if not (Rc.is_success rc) && rc <> DONE then
              failwith ("register insert failed: " ^ Rc.to_string rc);
            let lease = RegistrationLease.make ~node_id ~session_id ~alias ~client_type ~ttl ~identity_pk:effective_pk ~enc_pubkey ~signed_at ~sig_b64 ~opaque_host_id:opaque_host_id () in
            ("ok", lease)
    )

  let identity_pk_of t ~alias =
    let alias, _ = normalize_relay_alias ~alias ~opaque_host_id:None in
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = prepare conn "SELECT identity_pk, last_seen FROM leases WHERE alias = ?" in
      bind_text stmt 1 alias |> ignore;
      let result =
        if step stmt = Rc.ROW then
          let pk = Data.to_string_exn (column stmt 0) in
          let last_seen = data_to_float_default (column stmt 1) in
          if pk = "" || alias_released ~now:(Unix.gettimeofday ()) ~last_seen then None else Some pk
        else None
      in
      (try Sqlite3.finalize stmt |> ignore with _ -> ());
      result
    )

  let alias_of_identity_pk t ~identity_pk =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = prepare conn "SELECT alias, last_seen FROM leases WHERE identity_pk = ?" in
      bind_text stmt 1 identity_pk |> ignore;
      let now = Unix.gettimeofday () in
      let rec loop () =
        match step stmt with
        | Rc.ROW ->
          let alias = Data.to_string_exn (column stmt 0) in
          let last_seen = data_to_float_default (column stmt 1) in
          if alias <> "" && not (alias_released ~now ~last_seen) then Some alias
          else loop ()
        | _ -> None
      in
      let result = loop () in
      (try Sqlite3.finalize stmt |> ignore with _ -> ());
      result
    )

  let query_messages_since t ~alias ~since_ts =
    let query_alias, _ = normalize_relay_alias ~alias ~opaque_host_id:None in
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let msgs = ref [] in
      let min_ts = max since_ts (Unix.gettimeofday () -. 86400.0) in
      let stmt = prepare conn
        "SELECT message_id, from_alias, to_alias, content, ts FROM inboxes \
         WHERE ts > ? \
         ORDER BY ts ASC LIMIT 500"
      in
      bind_double stmt 1 min_ts |> ignore;
      let rec loop () =
        let rc = step stmt in
        if rc = Rc.ROW then (
          let message_id = Data.to_string_exn (column stmt 0) in
          let from_alias = Data.to_string_exn (column stmt 1) in
          let to_alias = Data.to_string_exn (column stmt 2) in
          let content = Data.to_string_exn (column stmt 3) in
          let ts =
            let col = column stmt 4 in
            match Data.to_float col with
            | Some f -> f
            | None -> float_of_string (Data.to_string_exn col)
          in
          if alias_matches_display ~query:query_alias from_alias
             || alias_matches_display ~query:query_alias to_alias
          then
            msgs := `Assoc [
              ("message_id", `String message_id);
              ("from_alias", `String from_alias);
              ("to_alias", `String to_alias);
              ("content", `String content);
              ("ts", `Float ts)
            ] :: !msgs;
          loop ()
        ) else if rc <> Rc.DONE then
          failwith ("query_messages_since step failed: " ^ Rc.to_string rc)
      in
      loop ();
      (try Sqlite3.finalize stmt |> ignore with _ -> ());
      List.rev !msgs
    )

  let enc_pubkey_of t ~alias =
    let alias, _ = normalize_relay_alias ~alias ~opaque_host_id:None in
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = prepare conn "SELECT enc_pubkey, last_seen FROM leases WHERE alias = ?" in
      bind_text stmt 1 alias |> ignore;
      let result =
        if step stmt = Rc.ROW then
          let ek = Data.to_string_exn (column stmt 0) in
          let last_seen = data_to_float_default (column stmt 1) in
          if ek = "" || alias_released ~now:(Unix.gettimeofday ()) ~last_seen then None else Some ek
        else None
      in
      (try Sqlite3.finalize stmt |> ignore with _ -> ());
      result
    )

  let alias_of_session t ~node_id ~session_id =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = prepare conn "SELECT alias, last_seen FROM leases WHERE node_id = ? AND session_id = ? LIMIT 1" in
      bind_text stmt 1 node_id |> ignore;
      bind_text stmt 2 session_id |> ignore;
      let result =
        if step stmt = Rc.ROW then
          let alias = Data.to_string_exn (column stmt 0) in
          let last_seen = data_to_float_default (column stmt 1) in
          if alias_released ~now:(Unix.gettimeofday ()) ~last_seen then None else Some alias
        else None
      in
      (try Sqlite3.finalize stmt |> ignore with _ -> ());
      result
    )

  let signed_at_of t ~alias =
    let alias, _ = normalize_relay_alias ~alias ~opaque_host_id:None in
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = prepare conn "SELECT signed_at, last_seen FROM leases WHERE alias = ?" in
      bind_text stmt 1 alias |> ignore;
      let result =
        if step stmt = Rc.ROW then
          let sa_float = data_to_float_default (column stmt 0) in
          let last_seen = data_to_float_default (column stmt 1) in
          if sa_float = 0.0 || alias_released ~now:(Unix.gettimeofday ()) ~last_seen then None else Some sa_float
        else None
      in
      (try Sqlite3.finalize stmt |> ignore with _ -> ());
      result
    )

  let sig_b64_of t ~alias =
    let alias, _ = normalize_relay_alias ~alias ~opaque_host_id:None in
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = prepare conn "SELECT sig_b64, last_seen FROM leases WHERE alias = ?" in
      bind_text stmt 1 alias |> ignore;
      let result =
        if step stmt = Rc.ROW then
          let sb = Data.to_string_exn (column stmt 0) in
          let last_seen = data_to_float_default (column stmt 1) in
          if sb = "" || alias_released ~now:(Unix.gettimeofday ()) ~last_seen then None else Some sb
        else None
      in
      (try Sqlite3.finalize stmt |> ignore with _ -> ());
      result
    )

  let set_allowed_identity t ~alias ~identity_pk_b64 =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = Sqlite3.prepare conn "INSERT INTO allowed_identities (alias, identity_pk_b64) VALUES (?, ?) ON CONFLICT(alias) DO UPDATE SET identity_pk_b64=excluded.identity_pk_b64" in
      Sqlite3.bind_text stmt 1 alias |> ignore;
      Sqlite3.bind_text stmt 2 identity_pk_b64 |> ignore;
      let rc = Sqlite3.step stmt in
      if not (Rc.is_success rc) && rc <> Rc.DONE then
        failwith ("set_allowed_identity failed: " ^ Rc.to_string rc)
    )

  let allowed_identity_of t ~alias =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let has_row = exec_prepared conn "SELECT identity_pk_b64 FROM allowed_identities WHERE alias = ?" [`Text alias] in
      if not has_row then None
      else
        let stmt = Sqlite3.prepare conn "SELECT identity_pk_b64 FROM allowed_identities WHERE alias = ?" in
        Sqlite3.bind_text stmt 1 alias |> ignore;
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let pk = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          Some pk
        else None
    )

  let check_allowlist t ~alias ~identity_pk_b64 =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let has_row = exec_prepared conn "SELECT identity_pk_b64 FROM allowed_identities WHERE alias = ?" [`Text alias] in
      if not has_row then `Unlisted
      else
        let stmt = Sqlite3.prepare conn "SELECT identity_pk_b64 FROM allowed_identities WHERE alias = ?" in
        Sqlite3.bind_text stmt 1 alias |> ignore;
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let pinned = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          if identity_pk_b64 = pinned then `Allowed else `Mismatch
        else `Unlisted
    )

  let unbind_alias t ~alias =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let before = ref false in
      let stmt = Sqlite3.prepare conn "SELECT alias FROM leases WHERE alias = ?" in
      Sqlite3.bind_text stmt 1 alias |> ignore;
      let rc = Sqlite3.step stmt in
      before := (rc = Rc.ROW);
      if !before then (
        let del = Sqlite3.prepare conn "DELETE FROM leases WHERE alias = ?" in
        Sqlite3.bind_text del 1 alias |> ignore;
        Sqlite3.step del |> ignore
      );
      !before
    )

  let check_nonce db ~ttl ~nonce ~ts =
    let cutoff = ts -. ttl in
    let conn = Sqlite3.db_open db in
    let del_stmt = Sqlite3.prepare conn "DELETE FROM register_nonces WHERE ts < ?" in
    Sqlite3.bind_double del_stmt 1 cutoff |> ignore;
    Sqlite3.step del_stmt |> ignore;
    let has_row = exec_prepared conn "SELECT nonce FROM register_nonces WHERE nonce = ?" [`Text nonce] in
    if has_row then Res.Error relay_err_nonce_replay
    else (
      let ins_stmt = Sqlite3.prepare conn "INSERT INTO register_nonces (nonce, ts) VALUES (?, ?)" in
      Sqlite3.bind_text ins_stmt 1 nonce |> ignore;
      Sqlite3.bind_double ins_stmt 2 ts |> ignore;
      Sqlite3.step ins_stmt |> ignore;
      Res.Ok ()
    )

  let check_register_nonce t ~nonce ~ts =
    with_lock t (fun () ->
      check_nonce t.db_path ~ttl:600.0 ~nonce ~ts
    )

  let check_request_nonce t ~nonce ~ts =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let cutoff = ts -. 120.0 in
      let del_stmt = Sqlite3.prepare conn "DELETE FROM request_nonces WHERE ts < ?" in
      Sqlite3.bind_double del_stmt 1 cutoff |> ignore;
      Sqlite3.step del_stmt |> ignore;
      let has_row = exec_prepared conn "SELECT nonce FROM request_nonces WHERE nonce = ?" [`Text nonce] in
      if has_row then Res.Error relay_err_nonce_replay
      else (
        let ins_stmt = Sqlite3.prepare conn "INSERT INTO request_nonces (nonce, ts) VALUES (?, ?)" in
        Sqlite3.bind_text ins_stmt 1 nonce |> ignore;
        Sqlite3.bind_double ins_stmt 2 ts |> ignore;
        Sqlite3.step ins_stmt |> ignore;
        Res.Ok ()
      )
    )

  let heartbeat t ~node_id ~session_id =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let now = Unix.gettimeofday () in
      let found_lease = ref None in
      let stmt = Sqlite3.prepare conn "SELECT alias, node_id, session_id, client_type, registered_at, last_seen, ttl, identity_pk, opaque_host_id FROM leases WHERE node_id = ? AND session_id = ?" in
      Sqlite3.bind_text stmt 1 node_id |> ignore;
      Sqlite3.bind_text stmt 2 session_id |> ignore;
      let rec find_lease () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then (
          let alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let node_id' = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1) in
          let session_id' = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2) in
          let client_type = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 3) in
          let registered_at =
            let col = Sqlite3.column stmt 4 in
            match Sqlite3.Data.to_float col with
            | Some f -> f
            | None -> float_of_string (Sqlite3.Data.to_string_exn col)
          in
          let last_seen =
            let col = Sqlite3.column stmt 5 in
            match Sqlite3.Data.to_float col with
            | Some f -> f
            | None -> float_of_string (Sqlite3.Data.to_string_exn col)
          in
          let ttl =
            let col = Sqlite3.column stmt 6 in
            match Sqlite3.Data.to_float col with
            | Some f -> f
            | None -> float_of_string (Sqlite3.Data.to_string_exn col)
          in
          let identity_pk = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 7) in
          let opaque_host_id_raw = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 8) in
          let opaque_host_id = if opaque_host_id_raw = "" then None else Some opaque_host_id_raw in
          let lease =
            RegistrationLease.make
              ~node_id:node_id'
              ~session_id:session_id'
              ~alias
              ~client_type
              ~registered_at
              ~last_seen
              ~ttl
              ~identity_pk
              ~opaque_host_id:opaque_host_id
              ()
          in
          found_lease := Some lease;
          find_lease ()
        ) else if rc <> Rc.DONE then
          failwith ("heartbeat step failed: " ^ Rc.to_string rc)
      in
      find_lease ();
      match !found_lease with
      | None ->
        let dummy = RegistrationLease.make ~node_id ~session_id ~alias:"_error" () in
        (relay_err_unknown_alias, dummy)
      | Some lease when alias_released ~now ~last_seen:(RegistrationLease.last_seen lease) ->
        release_alias conn (RegistrationLease.alias lease);
        let dummy = RegistrationLease.make ~node_id ~session_id ~alias:"_error" () in
        (relay_err_unknown_alias, dummy)
      | Some lease ->
        let up_stmt = Sqlite3.prepare conn "UPDATE leases SET last_seen = ? WHERE alias = ?" in
        Sqlite3.bind_double up_stmt 1 now |> ignore;
        Sqlite3.bind_text up_stmt 2 (RegistrationLease.alias lease) |> ignore;
        Sqlite3.step up_stmt |> ignore;
        RegistrationLease.touch lease;
        ("ok", lease)
    )

  let list_peers t ?(include_dead=false) =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let now = Unix.gettimeofday () in
      let leases = ref [] in
      let stmt = Sqlite3.prepare conn "SELECT alias, node_id, session_id, client_type, registered_at, last_seen, ttl, identity_pk, opaque_host_id FROM leases" in
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then (
          let alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let node_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1) in
          let session_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2) in
          let client_type = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 3) in
          let registered_at =
            let col = Sqlite3.column stmt 4 in
            match Sqlite3.Data.to_float col with
            | Some f -> f
            | None -> float_of_string (Sqlite3.Data.to_string_exn col)
          in
          let last_seen =
            let col = Sqlite3.column stmt 5 in
            match Sqlite3.Data.to_float col with
            | Some f -> f
            | None -> float_of_string (Sqlite3.Data.to_string_exn col)
          in
          let ttl =
            let col = Sqlite3.column stmt 6 in
            match Sqlite3.Data.to_float col with
            | Some f -> f
            | None -> float_of_string (Sqlite3.Data.to_string_exn col)
          in
          let identity_pk = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 7) in
          let opaque_host_id_raw = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 8) in
          let opaque_host_id = if opaque_host_id_raw = "" then None else Some opaque_host_id_raw in
          let lease =
            RegistrationLease.make
              ~node_id
              ~session_id
              ~alias
              ~client_type
              ~registered_at
              ~last_seen
              ~ttl
              ~identity_pk
              ~opaque_host_id:opaque_host_id
              ()
          in
          let alive = (last_seen +. ttl) >= now in
          if not (alias_released ~now ~last_seen)
             && (include_dead || alive)
          then leases := lease :: !leases;
          loop ()
        ) else if rc <> Rc.DONE then
          failwith ("list_peers step failed: " ^ Rc.to_string rc)
      in
      loop ();
      !leases
    )

  let gc t =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let now = Unix.gettimeofday () in
      let expired_aliases = ref [] in
      let stmt = Sqlite3.prepare conn "SELECT alias, last_seen, ttl FROM leases" in
      let rec collect_expired () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then (
          let alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let last_seen =
            match Sqlite3.Data.to_float (Sqlite3.column stmt 1) with
            | Some f -> f
            | None -> float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1))
          in
          let ttl =
            match Sqlite3.Data.to_float (Sqlite3.column stmt 2) with
            | Some f -> f
            | None -> float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2))
          in
          if alias_released ~now ~last_seen then expired_aliases := alias :: !expired_aliases;
          collect_expired ()
        ) else if rc <> Rc.DONE then
          failwith ("gc collect step failed: " ^ Rc.to_string rc)
      in
      collect_expired ();
      List.iter (fun alias ->
        release_alias conn alias
      ) !expired_aliases;
      let live_stmt = Sqlite3.prepare conn "SELECT node_id, session_id FROM leases" in
      let live_keys = ref [] in
      let rec collect_live () =
        let rc = Sqlite3.step live_stmt in
        if rc = Rc.ROW then (
          let node_id = Sqlite3.Data.to_string_exn (Sqlite3.column live_stmt 0) in
          let session_id = Sqlite3.Data.to_string_exn (Sqlite3.column live_stmt 1) in
          live_keys := (node_id, session_id) :: !live_keys;
          collect_live ()
        ) else if rc <> Rc.DONE then
          failwith ("gc live step failed: " ^ Rc.to_string rc)
      in
      collect_live ();
      let inbox_stmt = Sqlite3.prepare conn "SELECT DISTINCT node_id, session_id FROM inboxes" in
      let stale_keys = ref [] in
      let rec collect_stale () =
        let rc = Sqlite3.step inbox_stmt in
        if rc = Rc.ROW then (
          let node_id = Sqlite3.Data.to_string_exn (Sqlite3.column inbox_stmt 0) in
          let session_id = Sqlite3.Data.to_string_exn (Sqlite3.column inbox_stmt 1) in
          if not (List.mem (node_id, session_id) !live_keys) then
            stale_keys := (node_id, session_id) :: !stale_keys;
          collect_stale ()
        ) else if rc <> Rc.DONE then
          failwith ("gc stale step failed: " ^ Rc.to_string rc)
      in
      collect_stale ();
      let pruned = List.length !stale_keys in
      List.iter (fun (node_id, session_id) ->
        let del = Sqlite3.prepare conn "DELETE FROM inboxes WHERE node_id = ? AND session_id = ?" in
        Sqlite3.bind_text del 1 node_id |> ignore;
        Sqlite3.bind_text del 2 session_id |> ignore;
        Sqlite3.step del |> ignore
      ) !stale_keys;
      `Ok (List.rev !expired_aliases, pruned)
    )

  let send t ~from_alias ~to_alias ~content ?(message_id=None) =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let msg_id = match message_id with Some id -> id | None -> Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ()) in
      let ts = Unix.gettimeofday () in
      let lookup_alias, _ = normalize_relay_alias ~alias:to_alias ~opaque_host_id:None in
      let has_row = exec_prepared conn "SELECT alias, last_seen, ttl FROM leases WHERE alias = ?" [`Text lookup_alias] in
      if not has_row then
        `Error (relay_err_unknown_alias, Printf.sprintf "no registration for alias %S" to_alias)
      else
        let stmt = Sqlite3.prepare conn "SELECT alias, last_seen, ttl FROM leases WHERE alias = ?" in
        Sqlite3.bind_text stmt 1 lookup_alias |> ignore;
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let _alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let last_seen =
            match Sqlite3.Data.to_float (Sqlite3.column stmt 1) with
            | Some f -> f
            | None -> float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1))
          in
          let ttl =
            match Sqlite3.Data.to_float (Sqlite3.column stmt 2) with
            | Some f -> f
            | None -> float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2))
          in
          if alias_released ~now:ts ~last_seen then
            `Error (relay_err_unknown_alias, Printf.sprintf "no registration for alias %S" to_alias)
          else if (last_seen +. ttl) < ts then
            `Error (relay_err_recipient_dead, Printf.sprintf "alias %S is registered but lease has expired" to_alias)
          else
            let recv_stmt = Sqlite3.prepare conn "SELECT node_id, session_id FROM leases WHERE alias = ?" in
            Sqlite3.bind_text recv_stmt 1 lookup_alias |> ignore;
            let rc2 = Sqlite3.step recv_stmt in
            if rc2 = Rc.ROW then
              let recv_node_id = Sqlite3.Data.to_string_exn (Sqlite3.column recv_stmt 0) in
              let recv_session_id = Sqlite3.Data.to_string_exn (Sqlite3.column recv_stmt 1) in
              let ins_stmt = Sqlite3.prepare conn "INSERT INTO inboxes (node_id, session_id, message_id, from_alias, to_alias, content, ts) VALUES (?, ?, ?, ?, ?, ?, ?)" in
              Sqlite3.bind_text ins_stmt 1 recv_node_id |> ignore;
              Sqlite3.bind_text ins_stmt 2 recv_session_id |> ignore;
              Sqlite3.bind_text ins_stmt 3 msg_id |> ignore;
              Sqlite3.bind_text ins_stmt 4 from_alias |> ignore;
              Sqlite3.bind_text ins_stmt 5 to_alias |> ignore;
              Sqlite3.bind_text ins_stmt 6 content |> ignore;
              Sqlite3.bind_double ins_stmt 7 ts |> ignore;
              Sqlite3.step ins_stmt |> ignore;
              `Ok ts
            else
              `Error (relay_err_unknown_alias, "recipient lease not found")
        else
          `Error (relay_err_unknown_alias, "recipient lease not found")
    )

  let poll_inbox t ~node_id ~session_id =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let msgs = ref [] in
      let sel_stmt = Sqlite3.prepare conn "SELECT message_id, from_alias, to_alias, content, ts FROM inboxes WHERE node_id = ? AND session_id = ? ORDER BY id" in
      Sqlite3.bind_text sel_stmt 1 node_id |> ignore;
      Sqlite3.bind_text sel_stmt 2 session_id |> ignore;
      let rec loop () =
        let rc = Sqlite3.step sel_stmt in
        if rc = Rc.ROW then (
          let message_id = Sqlite3.Data.to_string_exn (Sqlite3.column sel_stmt 0) in
          let from_alias = Sqlite3.Data.to_string_exn (Sqlite3.column sel_stmt 1) in
          let to_alias = Sqlite3.Data.to_string_exn (Sqlite3.column sel_stmt 2) in
          let content = Sqlite3.Data.to_string_exn (Sqlite3.column sel_stmt 3) in
          let ts =
            match Sqlite3.Data.to_float (Sqlite3.column sel_stmt 4) with
            | Some f -> f
            | None -> float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column sel_stmt 4))
          in
          msgs := `Assoc [("message_id", `String message_id); ("from_alias", `String from_alias); ("to_alias", `String to_alias); ("content", `String content); ("ts", `Float ts)] :: !msgs;
          loop ()
        ) else if rc <> Rc.DONE then
          failwith ("poll_inbox step failed: " ^ Rc.to_string rc)
      in
      loop ();
      let del_stmt = Sqlite3.prepare conn "DELETE FROM inboxes WHERE node_id = ? AND session_id = ?" in
      Sqlite3.bind_text del_stmt 1 node_id |> ignore;
      Sqlite3.bind_text del_stmt 2 session_id |> ignore;
      Sqlite3.step del_stmt |> ignore;
      List.rev !msgs
    )

  let peek_inbox t ~node_id ~session_id =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let msgs = ref [] in
      let stmt = Sqlite3.prepare conn "SELECT message_id, from_alias, to_alias, content, ts FROM inboxes WHERE node_id = ? AND session_id = ? ORDER BY id" in
      Sqlite3.bind_text stmt 1 node_id |> ignore;
      Sqlite3.bind_text stmt 2 session_id |> ignore;
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then (
          let message_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let from_alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1) in
          let to_alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2) in
          let content = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 3) in
          let ts =
            match Sqlite3.Data.to_float (Sqlite3.column stmt 4) with
            | Some f -> f
            | None -> float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 4))
          in
          msgs := `Assoc [("message_id", `String message_id); ("from_alias", `String from_alias); ("to_alias", `String to_alias); ("content", `String content); ("ts", `Float ts)] :: !msgs;
          loop ()
        ) else if rc <> Rc.DONE then
          failwith ("peek_inbox step failed: " ^ Rc.to_string rc)
      in
      loop ();
      List.rev !msgs
    )

  let send_all t ~from_alias ~content ?(message_id=None) =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let now = Unix.gettimeofday () in
      let sent_to = ref [] in
      let skipped = ref [] in
      let msg_id = match message_id with Some id -> id | None -> Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ()) in
      let stmt = Sqlite3.prepare conn "SELECT alias, last_seen, ttl, node_id, session_id FROM leases WHERE alias != ?" in
      Sqlite3.bind_text stmt 1 from_alias |> ignore;
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let last_seen =
            match Sqlite3.Data.to_float (Sqlite3.column stmt 1) with
            | Some f -> f
            | None -> float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1))
          in
          let ttl =
            match Sqlite3.Data.to_float (Sqlite3.column stmt 2) with
            | Some f -> f
            | None -> float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2))
          in
          let alive = (last_seen +. ttl) >= now in
          if alive then (
            let node_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 3) in
            let session_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 4) in
            let ins_stmt = Sqlite3.prepare conn "INSERT INTO inboxes (node_id, session_id, message_id, from_alias, to_alias, content, ts) VALUES (?, ?, ?, ?, ?, ?, ?)" in
            Sqlite3.bind_text ins_stmt 1 node_id |> ignore;
            Sqlite3.bind_text ins_stmt 2 session_id |> ignore;
            Sqlite3.bind_text ins_stmt 3 msg_id |> ignore;
            Sqlite3.bind_text ins_stmt 4 from_alias |> ignore;
            Sqlite3.bind_text ins_stmt 5 alias |> ignore;
            Sqlite3.bind_text ins_stmt 6 content |> ignore;
            Sqlite3.bind_double ins_stmt 7 now |> ignore;
            Sqlite3.step ins_stmt |> ignore;
            sent_to := alias :: !sent_to
          ) else
            skipped := (alias, "not_alive") :: !skipped;
          loop ()
        else if rc <> Rc.DONE then
          failwith ("send_all step failed: " ^ Rc.to_string rc)
      in
      loop ();
      `Ok (now, List.rev !sent_to, List.map fst (List.rev !skipped))
    )

  let join_room t ?(visibility = "public") ~alias ~room_id () =
    let visibility = canonical_visibility_exn visibility in
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let lease_stmt = Sqlite3.prepare conn "SELECT last_seen FROM leases WHERE alias = ? LIMIT 1" in
      Sqlite3.bind_text lease_stmt 1 alias |> ignore;
      let active_alias =
        match Sqlite3.step lease_stmt with
        | Rc.ROW ->
          let last_seen = data_to_float_default (Sqlite3.column lease_stmt 0) in
          not (alias_released ~now:(Unix.gettimeofday ()) ~last_seen)
        | _ -> false
      in
      (try Sqlite3.finalize lease_stmt |> ignore with _ -> ());
      if not active_alias then (
        release_alias conn alias;
        `Error (relay_err_unknown_alias, Printf.sprintf "alias %S is not registered" alias)
      ) else (
      (* INSERT OR IGNORE: visibility is applied only on room creation; if the
         room already exists, its stored visibility is preserved. Post-creation
         changes go through the signed set_room_visibility op. *)
      let room_stmt = Sqlite3.prepare conn "INSERT OR IGNORE INTO rooms (room_id, visibility) VALUES (?, ?)" in
      Sqlite3.bind_text room_stmt 1 room_id |> ignore;
      Sqlite3.bind_text room_stmt 2 visibility |> ignore;
      Sqlite3.step room_stmt |> ignore;
      let mem_stmt = Sqlite3.prepare conn "INSERT OR IGNORE INTO room_members (room_id, alias) VALUES (?, ?)" in
      Sqlite3.bind_text mem_stmt 1 room_id |> ignore;
      Sqlite3.bind_text mem_stmt 2 alias |> ignore;
      Sqlite3.step mem_stmt |> ignore;
      `Ok
      )
    )

  let leave_room t ~alias ~room_id =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = Sqlite3.prepare conn "DELETE FROM room_members WHERE room_id = ? AND alias = ?" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      Sqlite3.bind_text stmt 2 alias |> ignore;
      Sqlite3.step stmt |> ignore;
      `Ok
    )

  let send_room t ~from_alias ~room_id ~content ?(message_id=None) ?envelope () =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let msg_id = match message_id with Some id -> id | None -> Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ()) in
      let ts = Unix.gettimeofday () in
      let sender_stmt = Sqlite3.prepare conn "SELECT last_seen FROM leases WHERE alias = ? LIMIT 1" in
      Sqlite3.bind_text sender_stmt 1 from_alias |> ignore;
      let sender_active =
        match Sqlite3.step sender_stmt with
        | Rc.ROW ->
          let last_seen = data_to_float_default (Sqlite3.column sender_stmt 0) in
          not (alias_released ~now:ts ~last_seen)
        | _ -> false
      in
      (try Sqlite3.finalize sender_stmt |> ignore with _ -> ());
      if not sender_active then (
        release_alias conn from_alias;
        `Error (relay_err_unknown_alias, Printf.sprintf "alias %S is not registered" from_alias)
      ) else
      let member_stmt = Sqlite3.prepare conn "SELECT 1 FROM room_members WHERE room_id = ? AND alias = ? LIMIT 1" in
      Sqlite3.bind_text member_stmt 1 room_id |> ignore;
      Sqlite3.bind_text member_stmt 2 from_alias |> ignore;
      let sender_member = Sqlite3.step member_stmt = Rc.ROW in
      (try Sqlite3.finalize member_stmt |> ignore with _ -> ());
      if not sender_member then
        `Error (relay_err_not_a_member, Printf.sprintf "alias %S is not a member of room %S" from_alias room_id)
      else
      let delivered_to = ref [] in
      let skipped = ref [] in
      let stmt = Sqlite3.prepare conn "SELECT alias FROM room_members WHERE room_id = ? AND alias != ?" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      Sqlite3.bind_text stmt 2 from_alias |> ignore;
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let member_alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          delivered_to := member_alias :: !delivered_to;
          loop ()
        else if rc <> Rc.DONE then
          failwith ("send_room members step failed: " ^ Rc.to_string rc)
      in
      loop ();
      let hist_stmt = Sqlite3.prepare conn "INSERT INTO room_history (room_id, message_id, from_alias, content, ts) VALUES (?, ?, ?, ?, ?)" in
      Sqlite3.bind_text hist_stmt 1 room_id |> ignore;
      Sqlite3.bind_text hist_stmt 2 msg_id |> ignore;
      Sqlite3.bind_text hist_stmt 3 from_alias |> ignore;
      Sqlite3.bind_text hist_stmt 4 content |> ignore;
      Sqlite3.bind_double hist_stmt 5 ts |> ignore;
      Sqlite3.step hist_stmt |> ignore;
      List.iter (fun to_alias ->
        let node_stmt = Sqlite3.prepare conn "SELECT node_id, session_id, last_seen, ttl FROM leases WHERE alias = ?" in
        Sqlite3.bind_text node_stmt 1 to_alias |> ignore;
        let rc = Sqlite3.step node_stmt in
        if rc = Rc.ROW then
          let node_id = Sqlite3.Data.to_string_exn (Sqlite3.column node_stmt 0) in
          let session_id = Sqlite3.Data.to_string_exn (Sqlite3.column node_stmt 1) in
          let last_seen =
            let col = Sqlite3.column node_stmt 2 in
            match Sqlite3.Data.to_float col with
            | Some f -> f
            | None -> float_of_string (Sqlite3.Data.to_string_exn col)
          in
          let ttl =
            let col = Sqlite3.column node_stmt 3 in
            match Sqlite3.Data.to_float col with
            | Some f -> f
            | None -> float_of_string (Sqlite3.Data.to_string_exn col)
          in
          if last_seen +. ttl >= ts then (
            let inbox_stmt = Sqlite3.prepare conn "INSERT INTO inboxes (node_id, session_id, message_id, from_alias, to_alias, content, ts) VALUES (?, ?, ?, ?, ?, ?, ?)" in
            Sqlite3.bind_text inbox_stmt 1 node_id |> ignore;
            Sqlite3.bind_text inbox_stmt 2 session_id |> ignore;
            Sqlite3.bind_text inbox_stmt 3 msg_id |> ignore;
            Sqlite3.bind_text inbox_stmt 4 from_alias |> ignore;
            Sqlite3.bind_text inbox_stmt 5 (to_alias ^ "#" ^ room_id) |> ignore;
            Sqlite3.bind_text inbox_stmt 6 content |> ignore;
            Sqlite3.bind_double inbox_stmt 7 ts |> ignore;
            Sqlite3.step inbox_stmt |> ignore
          ) else
            skipped := to_alias :: !skipped
        else
          skipped := to_alias :: !skipped
      ) !delivered_to;
      let delivered =
        List.filter (fun alias -> not (List.mem alias !skipped)) !delivered_to
      in
      `Ok (ts, List.rev delivered, List.rev !skipped)
    )

  let room_history t ~room_id ?(limit=50) =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let msgs = ref [] in
      let stmt = Sqlite3.prepare conn "SELECT message_id, from_alias, content, ts FROM room_history WHERE room_id = ? ORDER BY id DESC LIMIT ?" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      Sqlite3.bind_int stmt 2 limit |> ignore;
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let message_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let from_alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1) in
          let content = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2) in
          let ts =
            let col = Sqlite3.column stmt 3 in
            match Sqlite3.Data.to_float col with
            | Some f -> f
            | None -> float_of_string (Sqlite3.Data.to_string_exn col)
          in
          msgs := `Assoc [("message_id", `String message_id); ("from_alias", `String from_alias); ("content", `String content); ("ts", `Float ts)] :: !msgs;
          loop ()
        else if rc <> Rc.DONE then
          failwith ("room_history step failed: " ^ Rc.to_string rc)
      in
      loop ();
      List.rev !msgs
    )

  let dead_letter t =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let msgs = ref [] in
      let stmt = Sqlite3.prepare conn "SELECT message_id, from_alias, to_alias, content, ts, reason FROM dead_letter" in
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let message_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let from_alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1) in
          let to_alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2) in
          let content = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 3) in
          let ts =
            let col = Sqlite3.column stmt 4 in
            match Sqlite3.Data.to_float col with
            | Some f -> f
            | None -> float_of_string (Sqlite3.Data.to_string_exn col)
          in
          let reason = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 5) in
          msgs := `Assoc [("message_id", `String message_id); ("from_alias", `String from_alias); ("to_alias", `String to_alias); ("content", `String content); ("ts", `Float ts); ("reason", `String reason)] :: !msgs;
          loop ()
        else if rc <> Rc.DONE then
          failwith ("dead_letter step failed: " ^ Rc.to_string rc)
      in
      loop ();
      List.rev !msgs
    )

  let add_dead_letter t msg =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let message_id = Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "message_id" msg) in
      let from_alias = Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "from_alias" msg) in
      let to_alias = Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "to_alias" msg) in
      let content = Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "content" msg) in
      let ts = Yojson.Safe.Util.to_number (Yojson.Safe.Util.member "ts" msg) in
      let reason = Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "reason" msg) in
      let stmt = Sqlite3.prepare conn "INSERT INTO dead_letter (message_id, from_alias, to_alias, content, ts, reason) VALUES (?, ?, ?, ?, ?, ?)" in
      Sqlite3.bind_text stmt 1 message_id |> ignore;
      Sqlite3.bind_text stmt 2 from_alias |> ignore;
      Sqlite3.bind_text stmt 3 to_alias |> ignore;
      Sqlite3.bind_text stmt 4 content |> ignore;
      Sqlite3.bind_double stmt 5 ts |> ignore;
      Sqlite3.bind_text stmt 6 reason |> ignore;
      ignore (Sqlite3.step stmt)
    )

  let list_rooms t =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let rooms = ref [] in
      (* Only public and gated rooms are listed; unlisted/private rooms stay
         reachable by id but are omitted from the directory. *)
      let stmt = Sqlite3.prepare conn "SELECT room_id FROM rooms WHERE visibility IN ('public','gated')" in
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let room_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let mem_stmt = Sqlite3.prepare conn "SELECT COUNT(*) FROM room_members WHERE room_id = ?" in
          Sqlite3.bind_text mem_stmt 1 room_id |> ignore;
          let rc2 = Sqlite3.step mem_stmt in
          (* The COUNT aggregate comes back as a sqlite INTEGER; [Data.to_string_exn]
             raises DataTypeError on INT, so read the int directly (with a string
             fallback for safety). *)
          let member_count =
            if rc2 = Rc.ROW then
              (match Sqlite3.column mem_stmt 0 with
               | Sqlite3.Data.INT n -> Int64.to_int n
               | d -> (try int_of_string (Sqlite3.Data.to_string_exn d) with _ -> 0))
            else 0
          in
          let alias_stmt = Sqlite3.prepare conn "SELECT alias FROM room_members WHERE room_id = ?" in
          Sqlite3.bind_text alias_stmt 1 room_id |> ignore;
          let aliases = ref [] in
          let rec collect_aliases () =
            let rc3 = Sqlite3.step alias_stmt in
            if rc3 = Rc.ROW then
              let alias = Sqlite3.Data.to_string_exn (Sqlite3.column alias_stmt 0) in
              aliases := alias :: !aliases;
              collect_aliases ()
            else if rc3 <> Rc.DONE then
              failwith ("list_rooms aliases step failed: " ^ Rc.to_string rc3)
          in
          collect_aliases ();
          rooms := `Assoc [("room_id", `String room_id); ("member_count", `Int member_count); ("members", `List (List.map (fun a -> `String a) !aliases))] :: !rooms;
          loop ()
        else if rc <> Rc.DONE then
          failwith ("list_rooms step failed: " ^ Rc.to_string rc)
      in
      loop ();
      List.rev !rooms
    )

  let my_rooms t =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let rooms = ref [] in
      let stmt = Sqlite3.prepare conn "SELECT DISTINCT room_id FROM room_members" in
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let room_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let mem_stmt = Sqlite3.prepare conn "SELECT COUNT(*) FROM room_members WHERE room_id = ?" in
          Sqlite3.bind_text mem_stmt 1 room_id |> ignore;
          let rc2 = Sqlite3.step mem_stmt in
          (* The COUNT aggregate comes back as a sqlite INTEGER; [Data.to_string_exn]
             raises DataTypeError on INT, so read the int directly (with a string
             fallback for safety). *)
          let member_count =
            if rc2 = Rc.ROW then
              (match Sqlite3.column mem_stmt 0 with
               | Sqlite3.Data.INT n -> Int64.to_int n
               | d -> (try int_of_string (Sqlite3.Data.to_string_exn d) with _ -> 0))
            else 0
          in
          let alias_stmt = Sqlite3.prepare conn "SELECT alias FROM room_members WHERE room_id = ?" in
          Sqlite3.bind_text alias_stmt 1 room_id |> ignore;
          let aliases = ref [] in
          let rec collect_aliases () =
            let rc3 = Sqlite3.step alias_stmt in
            if rc3 = Rc.ROW then
              let alias = Sqlite3.Data.to_string_exn (Sqlite3.column alias_stmt 0) in
              aliases := alias :: !aliases;
              collect_aliases ()
            else if rc3 <> Rc.DONE then
              failwith ("my_rooms aliases step failed: " ^ Rc.to_string rc3)
          in
          collect_aliases ();
          rooms := `Assoc [("room_id", `String room_id); ("member_count", `Int member_count); ("members", `List (List.map (fun a -> `String a) !aliases))] :: !rooms;
          loop ()
        else if rc <> Rc.DONE then
          failwith ("my_rooms step failed: " ^ Rc.to_string rc)
      in
      loop ();
      List.rev !rooms
    )

  let room_visibility_of t ~room_id =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = Sqlite3.prepare conn "SELECT visibility FROM rooms WHERE room_id = ?" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      let rc = Sqlite3.step stmt in
      if rc = Rc.ROW then
        canonical_visibility_or_raw (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0))
      else "public"
    )

  let room_exists t ~room_id =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = Sqlite3.prepare conn "SELECT 1 FROM rooms WHERE room_id = ? LIMIT 1" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      let found = Sqlite3.step stmt = Rc.ROW in
      (try Sqlite3.finalize stmt |> ignore with _ -> ());
      found
    )

  let room_invites_of t ~room_id =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let invites = ref [] in
      let stmt = Sqlite3.prepare conn "SELECT identity_pk_b64 FROM room_invites WHERE room_id = ?" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let pk = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          invites := pk :: !invites;
          loop ()
        else if rc <> Rc.DONE then
          failwith ("room_invites_of step failed: " ^ Rc.to_string rc)
      in
      loop ();
      List.rev !invites
    )

  let is_invited t ~room_id ~identity_pk_b64 =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = Sqlite3.prepare conn "SELECT 1 FROM room_invites WHERE room_id = ? AND identity_pk_b64 = ?" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      Sqlite3.bind_text stmt 2 identity_pk_b64 |> ignore;
      let rc = Sqlite3.step stmt in
      rc = Rc.ROW
    )

  let set_room_visibility t ~room_id ~visibility =
    let visibility = canonical_visibility_exn visibility in
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = Sqlite3.prepare conn "INSERT INTO rooms (room_id, visibility) VALUES (?, ?) ON CONFLICT(room_id) DO UPDATE SET visibility=excluded.visibility" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      Sqlite3.bind_text stmt 2 visibility |> ignore;
      Sqlite3.step stmt |> ignore
    )

  let invite_to_room t ~room_id ~identity_pk_b64 =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = Sqlite3.prepare conn "INSERT OR IGNORE INTO room_invites (room_id, identity_pk_b64) VALUES (?, ?)" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      Sqlite3.bind_text stmt 2 identity_pk_b64 |> ignore;
      Sqlite3.step stmt |> ignore
    )

  let uninvite_from_room t ~room_id ~identity_pk_b64 =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = Sqlite3.prepare conn "DELETE FROM room_invites WHERE room_id = ? AND identity_pk_b64 = ?" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      Sqlite3.bind_text stmt 2 identity_pk_b64 |> ignore;
      Sqlite3.step stmt |> ignore
    )

  let room_knocks_of t ~room_id =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let knocks = ref [] in
      let stmt = Sqlite3.prepare conn
        "SELECT requester_alias, requester_identity_pk_b64, requested_at \
         FROM room_knocks WHERE room_id = ? ORDER BY requested_at ASC"
      in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then begin
          let requester_alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let requester_pk = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1) in
          let requested_at = data_to_float_default (Sqlite3.column stmt 2) in
          knocks := { requester_alias; requester_pk; requested_at } :: !knocks;
          loop ()
        end else if rc <> Rc.DONE then
          failwith ("room_knocks_of step failed: " ^ Rc.to_string rc)
      in
      loop ();
      (try Sqlite3.finalize stmt |> ignore with _ -> ());
      List.rev !knocks
    )

  let remove_room_knock t ~room_id ~requester_pk =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let select_stmt = Sqlite3.prepare conn
        "SELECT requester_alias, requester_identity_pk_b64, requested_at \
         FROM room_knocks WHERE room_id = ? AND requester_identity_pk_b64 = ? LIMIT 1"
      in
      Sqlite3.bind_text select_stmt 1 room_id |> ignore;
      Sqlite3.bind_text select_stmt 2 requester_pk |> ignore;
      let found =
        match Sqlite3.step select_stmt with
        | Rc.ROW ->
          Some {
            requester_alias = Sqlite3.Data.to_string_exn (Sqlite3.column select_stmt 0);
            requester_pk = Sqlite3.Data.to_string_exn (Sqlite3.column select_stmt 1);
            requested_at = data_to_float_default (Sqlite3.column select_stmt 2);
          }
        | _ -> None
      in
      (try Sqlite3.finalize select_stmt |> ignore with _ -> ());
      (match found with
       | None -> None
       | Some knock ->
         let del_stmt = Sqlite3.prepare conn
           "DELETE FROM room_knocks WHERE room_id = ? AND requester_identity_pk_b64 = ?"
         in
         Sqlite3.bind_text del_stmt 1 room_id |> ignore;
         Sqlite3.bind_text del_stmt 2 requester_pk |> ignore;
         Sqlite3.step del_stmt |> ignore;
         (try Sqlite3.finalize del_stmt |> ignore with _ -> ());
         Some knock)
    )

  let knock_room t ~room_id ~requester_alias ~requester_pk =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let room_stmt =
        Sqlite3.prepare conn "SELECT visibility FROM rooms WHERE room_id = ? LIMIT 1"
      in
      Sqlite3.bind_text room_stmt 1 room_id |> ignore;
      let visibility_opt =
        match Sqlite3.step room_stmt with
        | Rc.ROW ->
          Some (canonical_visibility_or_raw
            (Sqlite3.Data.to_string_exn (Sqlite3.column room_stmt 0)))
        | _ -> None
      in
      (try Sqlite3.finalize room_stmt |> ignore with _ -> ());
      match visibility_opt with
      | None ->
        `Error (relay_err_not_found,
          "room is not discoverable or does not accept knocks")
      | Some visibility when visibility = "public" || visibility = "unlisted" ->
        `Error (relay_err_join_directly,
          Printf.sprintf "room %S is %s; join directly" room_id visibility)
      | Some visibility when visibility <> "gated" ->
        `Error (relay_err_not_found,
          "room is not discoverable or does not accept knocks")
      | Some _ ->
        let member_stmt = Sqlite3.prepare conn
          "SELECT leases.last_seen \
           FROM room_members JOIN leases ON leases.alias = room_members.alias \
           WHERE room_members.room_id = ? AND room_members.alias = ? LIMIT 1"
        in
        Sqlite3.bind_text member_stmt 1 room_id |> ignore;
        Sqlite3.bind_text member_stmt 2 requester_alias |> ignore;
        let already_member =
          match Sqlite3.step member_stmt with
          | Rc.ROW ->
            let last_seen = data_to_float_default (Sqlite3.column member_stmt 0) in
            not (alias_released ~now:(Unix.gettimeofday ()) ~last_seen)
          | _ -> false
        in
        (try Sqlite3.finalize member_stmt |> ignore with _ -> ());
        if already_member then
          `Error (relay_err_already_member,
            Printf.sprintf "alias %S is already a member of room %S"
              requester_alias room_id)
        else
          let invite_stmt = Sqlite3.prepare conn
            "SELECT 1 FROM room_invites WHERE room_id = ? AND identity_pk_b64 = ? LIMIT 1"
          in
          Sqlite3.bind_text invite_stmt 1 room_id |> ignore;
          Sqlite3.bind_text invite_stmt 2 requester_pk |> ignore;
          let already_invited = Sqlite3.step invite_stmt = Rc.ROW in
          (try Sqlite3.finalize invite_stmt |> ignore with _ -> ());
          if already_invited then
            `Error (relay_err_already_invited,
              Printf.sprintf "requester is already invited to room %S" room_id)
          else
            let dup_stmt = Sqlite3.prepare conn
              "SELECT 1 FROM room_knocks \
               WHERE room_id = ? AND requester_identity_pk_b64 = ? LIMIT 1"
            in
            Sqlite3.bind_text dup_stmt 1 room_id |> ignore;
            Sqlite3.bind_text dup_stmt 2 requester_pk |> ignore;
            let already_pending = Sqlite3.step dup_stmt = Rc.ROW in
            (try Sqlite3.finalize dup_stmt |> ignore with _ -> ());
            if already_pending then
              `Ok true
            else begin
              let insert_stmt = Sqlite3.prepare conn
                "INSERT INTO room_knocks \
                 (room_id, requester_identity_pk_b64, requester_alias, requested_at) \
                 VALUES (?, ?, ?, ?)"
              in
              Sqlite3.bind_text insert_stmt 1 room_id |> ignore;
              Sqlite3.bind_text insert_stmt 2 requester_pk |> ignore;
              Sqlite3.bind_text insert_stmt 3 requester_alias |> ignore;
              Sqlite3.bind_double insert_stmt 4 (Unix.gettimeofday ()) |> ignore;
              Sqlite3.step insert_stmt |> ignore;
              (try Sqlite3.finalize insert_stmt |> ignore with _ -> ());
              `Ok false
            end
    )

  let is_room_member_alias t ~room_id ~alias =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = Sqlite3.prepare conn
        "SELECT leases.last_seen \
         FROM room_members JOIN leases ON leases.alias = room_members.alias \
         WHERE room_members.room_id = ? AND room_members.alias = ? LIMIT 1"
      in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      Sqlite3.bind_text stmt 2 alias |> ignore;
      let result =
        match Sqlite3.step stmt with
        | Rc.ROW ->
          let last_seen = data_to_float_default (Sqlite3.column stmt 0) in
          not (alias_released ~now:(Unix.gettimeofday ()) ~last_seen)
        | _ -> false
      in
      (try Sqlite3.finalize stmt |> ignore with _ -> ());
      result
    )

  (* S5a: Pairing token management — delegates to module-level SQL helpers *)
  let store_pairing_token t ~binding_id ~token_b64 ~machine_ed25519_pubkey ~expires_at =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      store_pairing_token_db conn ~binding_id ~token_b64 ~machine_ed25519_pubkey ~expires_at
    )

  let get_and_burn_pairing_token t ~binding_id =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      match get_and_burn_pairing_token_db conn ~binding_id with
      | Res.Ok opt -> opt
      | Res.Error _ -> None
    )

  let find_pairing_token t ~binding_id =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      find_pairing_token_db conn ~binding_id
    )

  (* S5a: Observer bindings — uses per-relay ObserverBindings instance *)
  let add_observer_binding t ~binding_id ~phone_ed25519_pubkey ~phone_x25519_pubkey ~machine_ed25519_pubkey ~provenance_sig =
    ObserverBindings.add t.observer_bindings ~binding_id ~phone_ed25519_pubkey ~phone_x25519_pubkey
      ~machine_ed25519_pubkey ~provenance_sig

  let get_observer_binding t ~binding_id =
    ObserverBindings.get t.observer_bindings ~binding_id

  let remove_observer_binding t ~binding_id =
    ObserverBindings.remove t.observer_bindings ~binding_id

  (* S5b: Device-pair pending — SqliteRelay doesn't use ephemeral OAuth state, stubs for signature *)
  let get_device_pair_pending _t ~user_code:_ = None
  let set_device_pair_pending _t ~user_code:_ (_:device_pair_pending) = ()
  let remove_device_pair_pending _t ~user_code:_ = ()
end

(* --- Relay_server HTTP layer (functor over RELAY backend) --- *)

(* Instantiate rate limiter once at module level — avoids fresh-type-in-functor issue. *)
module Rate_limiter_inst = Relay_ratelimit.Make()

module Relay_server(R : RELAY) : sig
  val make_callback :
    R.t ->
    string option ->
    Conduit_lwt_unix.flow ->
    Cohttp.Request.t ->
    Cohttp_lwt.Body.t ->
    ?broker_root:string option ->
    rate_limiter:Rate_limiter_inst.t ->
    Cohttp_lwt_unix.Server.response Lwt.t

  (* L2/4 auth decision — exposed for unit testing the route matrix.
     Returns (allow, error_msg_if_denied). Admin routes require Bearer;
     peer routes require Ed25519; unauth routes always allow. *)
  val auth_decision :
    path:string ->
    include_dead:bool ->
    token:string option ->
    auth_header:string option ->
    ed25519_verified:bool ->
    bool * string option

  (* B115: inbox read handlers — exposed for unit testing the owner gate
     independently of the outer route classifier (defense in depth).
     [require_owner] mirrors [token <> None] at the dispatch site: on a
     token-configured (prod) relay an unverified request must be refused
     here even if the route classifier ever regresses. *)
  val handle_poll_inbox :
    R.t ->
    verified_alias:string option ->
    require_owner:bool ->
    Yojson.Safe.t ->
    Cohttp_lwt_unix.Server.response Lwt.t

  val handle_peek_inbox :
    R.t ->
    verified_alias:string option ->
    require_owner:bool ->
    Yojson.Safe.t ->
    Cohttp_lwt_unix.Server.response Lwt.t

  val start_server :
    host:string ->
    port:int ->
    relay:R.t ->
    token:string option ->
    ?verbose:bool ->
    ?gc_interval:float ->
    ?tls:[ `Cert_key of string * string ] ->
    ?allowlist:(string * string) list ->
    ?broker_root:string option ->
    unit ->
    unit Lwt.t
end = struct

  include Relay_server_auth
  include Relay_server_json
  include Relay_server_response
  include Relay_server_html

  (* Error codes *)
  let err_bad_request = "bad_request"
  let err_not_found = "not_found"
  let err_internal_error = "internal_error"

  let pow_required_json challenge =
    `Assoc [
      "ok", `Bool false;
      "error_code", `String "pow_required";
      "required", `Assoc [
        "difficulty", `Int challenge.difficulty;
        "epoch", `Int challenge.epoch;
        "server_nonce", `String challenge.server_nonce;
        "ctx", `String Pow.ctx;
        "ttl_s", `Int challenge.ttl_s;
      ];
    ]

  let issue_pow_header ~route ~actor_id ~difficulty =
    issue_pow_challenge ~route ~actor_id ~difficulty |> pow_header

  let pow_difficulty_for_actor ~enabled ~actor_id =
    if enabled then
      Pow_policy.required_difficulty_for_actor relay_pow_policy
        ~actor_id ~now:(Unix.gettimeofday ())
    else
      0

  let encode_token_json j =
    Yojson.Safe.to_string j |>
    fun s -> Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

  let decode_token_json b64 =
    match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet b64 with
    | Error _ -> None
    | Ok s ->
      try Some (Yojson.Safe.from_string s)
      with Yojson.Json_error _ -> None

  let canonical_token_msg ~binding_id ~machine_ed25519_pubkey_b64 ~issued_at ~expires_at ~nonce =
    Relay_identity.canonical_msg ~ctx:mobile_pair_token_sign_ctx
      [ binding_id; machine_ed25519_pubkey_b64; string_of_float issued_at;
        string_of_float expires_at; nonce ]

  let is_valid_binding_id s =
    let len = String.length s in
    len >= 8 && len <= 64 &&
    String.for_all (fun c ->
      (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') || c = '_' || c = '-') s


  let handle_health ~auth_mode () =
    let git_hash =
      (* Railway injects RAILWAY_GIT_COMMIT_SHA at runtime; prefer it over a
         git subprocess (which fails in Docker where .git is absent). *)
      match Sys.getenv_opt "RAILWAY_GIT_COMMIT_SHA" with
      | Some sha when String.length sha >= 7 ->
        String.sub sha 0 7
      | _ ->
        (try
          let ic = Unix.open_process_in "git rev-parse --short HEAD 2>/dev/null" in
          let line = input_line ic in
          ignore (Unix.close_process_in ic);
          String.trim line
        with _ -> "unknown")
    in
    let pow_enabled = relay_pow_enabled () in
    let pow_header =
      issue_pow_header ~route:"health" ~actor_id:"" ~difficulty:0
    in
    respond_ok ~headers:[pow_header] (json_ok [
      ("version", `String Version.version);
      ("git_hash", `String git_hash);
      ("auth_mode", `String auth_mode);
      ("pow", `Assoc [
        ("enabled", `Bool pow_enabled);
        ("scheme", `String Pow.scheme_id);
      ]);
    ])

  let handle_list relay ~include_dead =
    let peers = R.list_peers relay ~include_dead |> List.map RegistrationLease.to_json in
    respond_ok (json_ok [ ("peers", `List peers) ])

  let handle_pubkey relay ~broker_root ~alias =
    if not (C2c_name.is_valid alias) then
      respond_bad_request (json_error_str err_bad_request ("invalid alias format: " ^ alias))
    else
      let identity_pk = R.identity_pk_of relay ~alias in
      let enc_pubkey = R.enc_pubkey_of relay ~alias in
      let signed_at = R.signed_at_of relay ~alias in
      let sig_b64 = R.sig_b64_of relay ~alias in
      match identity_pk with
      | None ->
        respond_not_found (json_error_str err_not_found ("unknown alias: " ^ alias))
      | Some ipk ->
        let fields = [
          ("alias", `String alias);
          ("ed25519_pubkey", `String (b64url_nopad_encode ipk));
        ] in
        let fields = match enc_pubkey with
          | Some ek -> fields @ [("x25519_pubkey", `String (b64url_nopad_encode ek))]
          | None -> fields
        in
        let fields = match signed_at with
          | Some sa -> fields @ [("signed_at", `Float sa)]
          | None -> fields
        in
        let fields = match sig_b64 with
          | Some sb -> fields @ [("signature", `String sb)]
          | None -> fields
        in
        respond_ok (json_ok fields)

  let handle_dead_letter relay =
    let dl = R.dead_letter relay in
    respond_ok (json_ok [ ("dead_letter", `List dl) ])

  let handle_list_rooms relay =
    let rooms = R.list_rooms relay in
    respond_ok (json_ok [ ("rooms", `List rooms) ])

  let handle_admin_unbind relay body =
    let alias = get_string body "alias" in
    if alias = "" then
      respond_bad_request (json_error_str err_bad_request "alias is required")
    else
      let removed = R.unbind_alias relay ~alias in
      Printf.printf "audit: admin_unbind alias=%s removed=%b\n%!" alias removed;
      respond_ok (`Assoc [("ok", `Bool true); ("removed", `Bool removed); ("alias", `String alias)])

  let handle_gc relay =
    match R.gc relay with
    | `Ok (expired, pruned) -> respond_ok (json_of_gc_result (expired, pruned))

  (* Parse an RFC 3339 / ISO 8601 UTC timestamp like "2026-04-21T00:05:30Z"
     into Unix epoch seconds. Returns None on malformed input.
     Uses Ptime.of_rfc3339 to avoid timezone arithmetic bugs from mktime. *)
  let parse_rfc3339_utc s =
    match Ptime.of_rfc3339 s with
    | Ok (t, _, _) -> Some (Ptime.to_float_s t)
    | Error _ -> None

  let decode_b64url s =
    Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s

  let handle_register relay ~relay_url body =
    let node_id = get_string body "node_id" in
    let session_id = get_string body "session_id" in
    let alias = get_string body "alias" in
    (* Extract opaque_host_id from the relay address suffix
       `<name>@<12-16 hex>` (set by `c2c host-id`). The body may also
       carry an explicit `opaque_host_id` field (clients that don't
       want the `@hostid` suffix in their relay address). Explicit
       field wins over suffix extraction when both are present. The
       relay stores the display alias as the lease key; opaque_host_id is a
       separate field for routing/dedup/reply-route reconstruction. *)
    let alias_embedded_host_id =
      let _name, host_id_opt = C2c_name.split_opaque_host_id alias in
      host_id_opt
    in
    let body_host_id = get_opt_string body "opaque_host_id" in
    let opaque_host_id =
      match body_host_id with
      | Some s when s <> "" ->
          if C2c_name.is_opaque_host_id s then Some s
          else
            Some s  (* keep as-is; R.register will store it verbatim — we
                      don't enforce a shape at this layer; the client's
                      recipe owns the format *)
      | _ -> alias_embedded_host_id
    in
    let identity_pk_b64 = get_opt_string body "identity_pk" |> Option.value ~default:"" in
    let actor_id =
      if identity_pk_b64 = "" then ""
      else
        match decode_b64url identity_pk_b64 with
        | Ok identity_pk when String.length identity_pk = 32 ->
          b64url_nopad_encode identity_pk
        | _ -> ""
    in
    let pow_enabled = relay_pow_enabled () in
    let pow_actor_enabled = pow_enabled && actor_id <> "" in
    (* A re-register of a session that already holds a lease bound to the same
       alias is a routine lease *refresh*, not a new registration. The relay
       connector keeps no persistent registered-set in `--once` mode, so it
       re-registers every local session on every sync; without this, each
       refresh re-charges register cost (10) and escalates the per-actor PoW
       difficulty to d_max — burning CPU minting a needless proof every sync.
       A refresh is PoW-free and cost-free: the actor already proved ownership
       of this alias when the lease was first bound (the signed path verifies
       the Ed25519 signature for `alias`), so a free refresh is NOT a
       new-registration flood vector. Alias compare is case-insensitive to
       match registry semantics. *)
    let is_lease_refresh =
      alias <> ""
      && (match R.alias_of_session relay ~node_id ~session_id with
          | Some bound ->
            String.lowercase_ascii bound = String.lowercase_ascii alias
          | None -> false)
    in
    let respond_register_json ?difficulty ~status body =
      let difficulty =
        match difficulty with
        | Some d -> d
        | None -> pow_difficulty_for_actor ~enabled:pow_actor_enabled ~actor_id
      in
      respond_json ~status ~headers:[
        issue_pow_header ~route:"register" ~actor_id ~difficulty
      ] body
    in
    let respond_register_ok ?difficulty body =
      respond_register_json ?difficulty ~status:`OK body
    in
    let respond_register_bad_request body =
      respond_register_json ~status:`Bad_request body
    in
    let respond_register_unauthorized body =
      respond_register_json ~status:`Unauthorized body
    in
    let finish_register_result result =
      if pow_actor_enabled && not is_lease_refresh && fst result = "ok" then begin
        Pow_policy.record_route relay_pow_policy ~actor_id ~route:"register"
          ~now:(Unix.gettimeofday ())
      end else
        0
    in
    let reject_pow_required difficulty =
      let challenge = issue_pow_challenge ~route:"register" ~actor_id ~difficulty in
      respond_json ~status:`Too_many_requests
        ~headers:[pow_header challenge]
        (pow_required_json challenge)
    in
    let verify_register_pow difficulty =
      if not pow_enabled || difficulty <= 0 then Ok ()
      else
        let pow_nonce = get_opt_string body "pow_nonce" in
        let pow_server_nonce = get_opt_string body "pow_server_nonce" in
        let pow_epoch =
          match Yojson.Safe.Util.member "pow_epoch" body with
          | `Int n -> Some n
          | `Float f -> Some (int_of_float f)
          | _ -> None
        in
        match pow_nonce, pow_epoch, pow_server_nonce with
        | Some pow_nonce, Some epoch, Some server_nonce ->
          let challenge =
            Pow.challenge_string ~ctx:Pow.ctx ~route:"register" ~actor_id
              ~epoch ~server_nonce
          in
          if Pow.verify ~challenge ~difficulty ~pow_nonce
             && PowChallenges.consume_if_valid ~route:"register" ~actor_id
                  ~epoch ~server_nonce ~now:(Unix.gettimeofday ())
          then
            Ok ()
          else
            Error ()
        | _ -> Error ()
    in
    if node_id = "" || session_id = "" || alias = "" then
      respond_register_bad_request
        (json_error_str err_bad_request "node_id, session_id, and alias are required")
    else
      let client_type = get_opt_string body "client_type" |> Option.value ~default:"unknown" in
      let ttl = effective_lease_ttl ~client_ttl:(float_of_int (get_int body "ttl" 0)) in
      let enc_pubkey_b64 = get_opt_string body "enc_pubkey" |> Option.value ~default:"" in
      let signed_at = get_float body "signed_at" 0.0 in
      let sig_b64 = get_opt_string body "sig_b64" |> Option.value ~default:"" in
      let signature_b64 = get_opt_string body "signature" |> Option.value ~default:"" in
      let nonce_b64 = get_opt_string body "nonce" |> Option.value ~default:"" in
      let timestamp_str = get_opt_string body "timestamp" |> Option.value ~default:"" in
      let has_proof_fields =
        identity_pk_b64 <> "" && signature_b64 <> ""
        && nonce_b64 <> "" && timestamp_str <> ""
      in
      let partial_proof =
        (identity_pk_b64 <> "" || signature_b64 <> ""
         || nonce_b64 <> "" || timestamp_str <> "")
        && not has_proof_fields
      in
      let required_pow =
        if is_lease_refresh then 0
        else pow_difficulty_for_actor ~enabled:pow_actor_enabled ~actor_id
      in
      match verify_register_pow required_pow with
      | Error () ->
        reject_pow_required required_pow
      | Ok () ->
      if partial_proof then
        respond_register_bad_request (json_error_str relay_err_missing_proof_field
          "identity_pk, signature, nonce, and timestamp must all be present together")
      else if pow_enabled && not has_proof_fields then
        respond_register_bad_request (json_error_str relay_err_missing_proof_field
          "identity_pk, signature, nonce, and timestamp are required when C2C_RELAY_POW=1")
      else if has_proof_fields then
        (* Signed registration path — verify before binding. *)
        match decode_b64url identity_pk_b64 with
        | Error _ ->
          respond_register_bad_request (json_error_str err_bad_request "identity_pk not base64url-nopad")
        | Ok identity_pk when String.length identity_pk <> 32 ->
          respond_register_bad_request (json_error_str err_bad_request "identity_pk must be 32 bytes")
        | Ok identity_pk ->
          match decode_b64url signature_b64 with
          | Error _ ->
            respond_register_bad_request (json_error_str err_bad_request "signature not base64url-nopad")
          | Ok sig_ when String.length sig_ <> 64 ->
            respond_register_bad_request (json_error_str relay_err_signature_invalid "signature must be 64 bytes")
          | Ok sig_ ->
            match parse_rfc3339_utc timestamp_str with
            | None ->
              respond_register_bad_request (json_error_str err_bad_request "timestamp must be RFC3339 UTC")
            | Some ts_client ->
              let now = Unix.gettimeofday () in
              let skew = ts_client -. now in
              if skew > register_ts_future_window || -. skew > register_ts_past_window then
                respond_register_bad_request (json_error_str relay_err_timestamp_out_of_window
                  (Printf.sprintf "timestamp skew %.1fs outside [-%.0f, +%.0f]"
                     skew register_ts_past_window register_ts_future_window))
              else
                match R.check_register_nonce relay ~nonce:nonce_b64 ~ts:ts_client with
                | Error code ->
                  respond_register_bad_request (json_error_str code "nonce already seen within TTL")
                | Ok () ->
                  let signed =
                    Relay_identity.canonical_msg ~ctx:Relay_signed_ops.register_sign_ctx
                      [ alias; String.lowercase_ascii relay_url;
                        identity_pk_b64; timestamp_str; nonce_b64 ]
                  in
                  if not (Relay_identity.verify ~pk:identity_pk ~msg:signed ~sig_) then
                    respond_register_unauthorized (json_error_str relay_err_signature_invalid
                      "Ed25519 signature does not verify against identity_pk")
                  else
                    let result =
                      R.register relay ~node_id ~session_id ~alias
                        ~client_type ~ttl ~identity_pk ~enc_pubkey:enc_pubkey_b64 ~signed_at ~sig_b64:sig_b64
                        ~opaque_host_id:opaque_host_id ()
                    in
                    let receipt =
                      let relay_identity = R.relay_identity relay in
                      let ts = Relay_signed_ops.now_rfc3339_utc () in
                      let nonce = Relay_signed_ops.random_nonce_b64 () in
                      Relay_signed_ops.build_registration_receipt_json
                        ~identity:relay_identity
                        ~alias
                        ~client_identity_pk_b64:identity_pk_b64
                        ~nonce
                        ~ts
                    in
                    let difficulty = finish_register_result result in
                    respond_register_ok ~difficulty (json_of_register_result ~receipt result)
      else
        (* Legacy path — no identity_pk supplied, behaves exactly as before. *)
        let result =
          R.register relay ~node_id ~session_id ~alias ~client_type ~ttl ~enc_pubkey:enc_pubkey_b64 ~signed_at ~sig_b64:sig_b64
            ~opaque_host_id:opaque_host_id ()
        in
        let difficulty = finish_register_result result in
        respond_register_ok ~difficulty (json_of_register_result result)

  (* S-A1: bind verified Ed25519 signer to body claims. When ~verified_alias
     is [Some v], body [from_alias] on send-family routes must match [v];
     body (node_id, session_id) on session-scoped routes must be owned by [v].
     [None] = Bearer-admin or no identity — no body-binding check applied. *)
  let reject_alias_mismatch ~verified ~claimed =
    respond_json ~status:`Forbidden
      (json_error_str relay_err_signature_invalid
         (Printf.sprintf "verified signer %S does not match body from_alias %S"
            verified claimed))

  let reject_session_mismatch ~verified ~node_id ~session_id =
    respond_json ~status:`Forbidden
      (json_error_str relay_err_signature_invalid
         (Printf.sprintf "verified signer %S does not own session (%s, %s)"
            verified node_id session_id))

  (* The body [from_alias] on send routes may carry an opaque host suffix
     (`<name>@<host_id>`) for relay routing/display — clients like pi-c2c sign
     and send under their full relay address. The verified Ed25519 signer is
     bound to the bare [name], so compare against the name part when
     [from_alias] is a well-formed `<name>@<host>` (or a bare valid name);
     otherwise compare the whole string so a malformed claim still rejects.
     The host suffix is opaque routing metadata and grants no privilege — the
     name↔identity binding is what's enforced. *)
  let from_alias_signer_name from_alias =
    if C2c_name.is_valid_with_opaque_host_id from_alias
    then fst (C2c_name.split_opaque_host_id from_alias)
    else from_alias

  let handle_heartbeat relay ~verified_alias body =
    let node_id = get_string body "node_id" in
    let session_id = get_string body "session_id" in
    if node_id = "" || session_id = "" then
      respond_bad_request (json_error_str err_bad_request "node_id and session_id are required")
    else
      match verified_alias with
      | Some v ->
        (match R.alias_of_session relay ~node_id ~session_id with
         | Some owner when owner = v ->
           let result = R.heartbeat relay ~node_id ~session_id in
           respond_ok (json_of_heartbeat_result result)
         | _ -> reject_session_mismatch ~verified:v ~node_id ~session_id)
      | None ->
        let result = R.heartbeat relay ~node_id ~session_id in
        respond_ok (json_of_heartbeat_result result)

  let handle_send relay ~verified_alias body =
    let from_alias = get_string body "from_alias" in
    let to_alias = get_string body "to_alias" in
    let content = get_string body "content" in
    if from_alias = "" || to_alias = "" || content = "" then
      respond_bad_request (json_error_str err_bad_request "from_alias, to_alias, and content are required")
    else
      (* #379: split alias@host for cross-relay routing. A 12-16 lowercase
         hex host is the relay opaque-host reply route, not a cross-relay
         host name, so it stays local while preserving the concrete route
         in delivered message JSON. *)
      let stripped_to_alias, host_opt = split_alias_host to_alias in
      let opaque_host_route =
        match host_opt with
        | Some h -> C2c_name.is_opaque_host_id h
        | None -> false
      in
      let self_host = R.self_host relay in
      if (not opaque_host_route) && not (host_acceptable ~self_host host_opt) then
        (* #330 S2: three-way branch. Pre-bind msg_id and peer_name so the
           forward-outcome callback can reference them via closure. *)
        let msg_id = match get_opt_string body "message_id" with
          | Some m -> m
          | None -> Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ())
        in
        let peer_name, forward_result =
          match host_opt with
          | None ->
              ("", None)
          | Some h -> (match R.peer_relay_of relay ~name:h with
                       | None -> ("", None)
                       | Some p -> (p.name, Some p))
        in
        (match forward_result with
         | None ->
             (* No known peer — write dead-letter and return synchronously. *)
             let ts = Unix.gettimeofday () in
             let dl = `Assoc [
               ("ts", `Float ts);
               ("message_id", `String msg_id);
               ("from_alias", `String from_alias);
               ("to_alias", `String to_alias);
               ("content", `String content);
               ("reason", `String "cross_host_not_implemented");
               ("phase", `String "forward_out");
             ] in
             R.add_dead_letter relay dl;
             respond_not_found
               (json_error_str "cross_host_not_implemented"
                  (Printf.sprintf "cross-host send to %S not supported (relay does not forward to other hosts)" to_alias))
         | Some peer ->
             (* Known peer relay — forward the request. *)
             let identity = R.relay_identity relay in
             Lwt.bind
               (Relay_forwarder.forward_send ~identity
                  ~self_host:(Option.value self_host ~default:"")
                  ~peer_url:peer.url
                  ~from_alias ~to_alias:stripped_to_alias
                  ~content ~message_id:msg_id)
               (fun outcome ->
                 let open Relay_forwarder in
                 match outcome with
                 | Delivered ts ->
                     respond_ok (`Assoc ["ok", `Bool true; "ts", `Float ts])
                 | Duplicate ts ->
                     respond_ok (`Assoc ["ok", `Bool true; "ts", `Float ts; "duplicate", `Bool true])
                 | Peer_unreachable reason ->
                     let dl = `Assoc [
                       ("ts", `Float (Unix.gettimeofday ()));
                       ("message_id", `String msg_id);
                       ("from_alias", `String from_alias);
                       ("to_alias", `String to_alias);
                       ("content", `String content);
                       ("reason", `String "peer_unreachable");
                       ("phase", `String "forward_out");
                       ("peer", `String peer_name);
                     ] in
                     R.add_dead_letter relay dl;
                     respond_bad_gateway
                       (json_error_str "peer_unreachable"
                          (Printf.sprintf "peer relay %s unreachable: %s" peer_name reason))
                 | Peer_timeout ->
                     let dl = `Assoc [
                       ("ts", `Float (Unix.gettimeofday ()));
                       ("message_id", `String msg_id);
                       ("from_alias", `String from_alias);
                       ("to_alias", `String to_alias);
                       ("content", `String content);
                       ("reason", `String "peer_timeout");
                       ("phase", `String "forward_out");
                       ("peer", `String peer_name);
                     ] in
                     R.add_dead_letter relay dl;
                     respond_gateway_timeout
                       (json_error_str "peer_timeout"
                          (Printf.sprintf "peer relay %s did not respond within 5s" peer_name))
                 | Peer_5xx (st, body_excerpt) ->
                     let dl = `Assoc [
                       ("ts", `Float (Unix.gettimeofday ()));
                       ("message_id", `String msg_id);
                       ("from_alias", `String from_alias);
                       ("to_alias", `String to_alias);
                       ("content", `String content);
                       ("reason", `String "peer_5xx");
                       ("phase", `String "forward_out");
                       ("peer", `String peer_name);
                     ] in
                     R.add_dead_letter relay dl;
                     respond_bad_gateway
                       (json_error_str "peer_5xx"
                          (Printf.sprintf "peer relay %s returned %d: %s" peer_name st body_excerpt))
                 | Peer_4xx (st, body_excerpt) ->
                     let dl = `Assoc [
                       ("ts", `Float (Unix.gettimeofday ()));
                       ("message_id", `String msg_id);
                       ("from_alias", `String from_alias);
                       ("to_alias", `String to_alias);
                       ("content", `String content);
                       ("reason", `String "peer_rejected");
                       ("phase", `String "forward_out");
                       ("peer", `String peer_name);
                     ] in
                     R.add_dead_letter relay dl;
                     respond_not_found
                       (json_error_str "peer_rejected"
                          (Printf.sprintf "peer relay %s rejected request %d: %s" peer_name st body_excerpt))
                 | Peer_unauthorized ->
                     let dl = `Assoc [
                       ("ts", `Float (Unix.gettimeofday ()));
                       ("message_id", `String msg_id);
                       ("from_alias", `String from_alias);
                       ("to_alias", `String to_alias);
                       ("content", `String content);
                       ("reason", `String "peer_unauthorized");
                       ("phase", `String "forward_out");
                       ("peer", `String peer_name);
                     ] in
                     R.add_dead_letter relay dl;
                     respond_bad_gateway
                       (json_error_str "peer_unauthorized"
                          (Printf.sprintf "peer relay %s did not accept our identity" peer_name))
                 | Local_error err ->
                     let dl = `Assoc [
                       ("ts", `Float (Unix.gettimeofday ()));
                       ("message_id", `String msg_id);
                       ("from_alias", `String from_alias);
                       ("to_alias", `String to_alias);
                       ("content", `String content);
                       ("reason", `String "forward_local_error");
                       ("phase", `String "forward_out");
                       ("peer", `String peer_name);
                     ] in
                     R.add_dead_letter relay dl;
                     respond_internal_error
                       (json_error_str "forward_local_error"
                          (Printf.sprintf "local forwarder error: %s" err))))
      else
      match verified_alias with
      | Some v when v <> from_alias_signer_name from_alias -> reject_alias_mismatch ~verified:v ~claimed:from_alias
      | _ ->
        let message_id = get_opt_string body "message_id" in
        let deliver_to_alias = if opaque_host_route then to_alias else stripped_to_alias in
        let result = R.send relay ~from_alias ~to_alias:deliver_to_alias ~content ~message_id in
        (match result with
         | `Ok ts | `Duplicate ts ->
           (* Push to WS subscribers (slice 2) *)
           Relay_ws_server.push_dm ~to_alias:stripped_to_alias ~from_alias ~body:content ~ts;
           (match R.identity_pk_of relay ~alias:stripped_to_alias with
            | Some identity_pk ->
              (match binding_id_of_phone_pk ~phone_ed25519_pubkey:identity_pk with
               | Some binding_id ->
                  let sq_msg = {
                    Relay_short_queue.ts;
                    from_alias;
                    to_alias;
                    room_id = None;
                    content;
                  } in
                  Relay_short_queue.ShortQueue.push short_queue ~binding_id sq_msg;
                  push_to_observers ~binding_id sq_msg
                | None -> ())
             | None -> ())
          | `Error _ -> ());
        respond_ok (json_of_send_result result)

  let handle_send_all relay ~verified_alias body =
    let from_alias = get_string body "from_alias" in
    let content = get_string body "content" in
    if from_alias = "" || content = "" then
      respond_bad_request (json_error_str err_bad_request "from_alias and content are required")
    else
      match verified_alias with
      | Some v when v <> from_alias_signer_name from_alias -> reject_alias_mismatch ~verified:v ~claimed:from_alias
      | _ ->
        let message_id = get_opt_string body "message_id" in
        match R.send_all relay ~from_alias ~content ~message_id with
        | `Ok (ts, delivered, skipped) ->
          List.iter (fun to_alias ->
            match R.identity_pk_of relay ~alias:to_alias with
            | Some identity_pk ->
              (match binding_id_of_phone_pk ~phone_ed25519_pubkey:identity_pk with
               | Some binding_id ->
                  let sq_msg = {
                    Relay_short_queue.ts;
                    from_alias;
                    to_alias;
                    room_id = None;
                    content;
                  } in
                  Relay_short_queue.ShortQueue.push short_queue ~binding_id sq_msg;
                  push_to_observers ~binding_id sq_msg
                | None -> ())
             | None -> ()
           ) delivered;
            respond_ok (json_of_send_all_result (ts, delivered, skipped))

  (* #330 S4: handle an inbound forward from a peer relay.
     Verifies the Ed25519 signature using the peer relay's known public key,
     then delivers the message locally. The Authorization header must contain
     a valid Ed25519 proof signed by the peer relay's identity. *)
  let handle_forward relay ~auth_header body_str =
    match auth_header with
    | None ->
      respond_unauthorized (json_error_str err_unauthorized "missing Authorization header")
    | Some h ->
      let prefix = "Ed25519 " in
      let plen = String.length prefix in
      if String.length h < plen || (String.sub h 0 plen <> prefix) then
        respond_unauthorized (json_error_str err_unauthorized "expected Ed25519 authorization")
      else begin
        let params_str = String.sub h plen (String.length h - plen) |> String.trim in
        match parse_ed25519_auth_params params_str with
        | Error e ->
          respond_unauthorized (json_error_str err_unauthorized ("malformed Ed25519 auth: " ^ e))
        | Ok (claimed_alias, ts_str, nonce, sig_b64) ->
          let relay_host_opt =
            match String.rindex_opt claimed_alias '@' with
            | None -> None
            | Some i -> Some (String.sub claimed_alias (i + 1) (String.length claimed_alias - i - 1))
          in
          match float_of_string_opt ts_str with
          | None ->
            respond_unauthorized (json_error_str err_unauthorized "ts must be unix seconds")
          | Some ts_client ->
            let now = Unix.gettimeofday () in
            let skew = ts_client -. now in
            if skew > request_ts_future_window || -. skew > request_ts_past_window then
              respond_unauthorized (json_error_str relay_err_timestamp_out_of_window
                (Printf.sprintf "request ts skew %.1fs outside window" skew))
            else begin
              match R.check_request_nonce relay ~nonce ~ts:ts_client with
              | Error _ -> respond_unauthorized (json_error_str err_unauthorized "request nonce replay")
              | Ok () ->
                begin match relay_host_opt with
                | None ->
                  respond_unauthorized (json_error_str err_unauthorized
                    (Printf.sprintf "alias %S has no identity binding" claimed_alias))
                | Some relay_host ->
                  begin match R.peer_relay_of relay ~name:relay_host with
                  | None ->
                    respond_unauthorized (json_error_str err_unauthorized
                      (Printf.sprintf "alias %S has no identity binding" claimed_alias))
                  | Some peer_relay ->
                    begin match decode_b64url sig_b64 with
                    | Error _ ->
                      respond_unauthorized (json_error_str err_unauthorized "sig not base64url-nopad")
                    | Ok sig_ when String.length sig_ <> 64 ->
                      respond_unauthorized (json_error_str relay_err_signature_invalid "sig must be 64 bytes")
                    | Ok sig_ ->
                      let body_sha256 = body_sha256_b64 body_str in
                      let blob =
                        Relay_signed_ops.canonical_request_blob
                          ~meth:"POST" ~path:"/forward" ~query:""
                          ~body_sha256_b64:body_sha256 ~ts:ts_str ~nonce
                      in
                      if not (Relay_identity.verify ~pk:peer_relay.identity_pk ~msg:blob ~sig_:sig_) then
                        respond_unauthorized (json_error_str relay_err_signature_invalid
                          "Ed25519 request signature does not verify")
                      else
                        match Yojson.Safe.from_string body_str with
                        | exception Yojson.Json_error msg ->
                          respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
                        | body ->
                          let from_alias = get_string body "from_alias" in
                          let to_alias = get_string body "to_alias" in
                          let content = get_string body "content" in
                          if from_alias = "" || to_alias = "" || content = "" then
                            respond_bad_request (json_error_str err_bad_request
                              "from_alias, to_alias, and content are required")
                          else
                            let message_id = get_opt_string body "message_id" in
                            match R.send relay ~from_alias ~to_alias ~content ~message_id with
                            | `Ok ts ->
                              respond_ok (`Assoc ["ok", `Bool true; "ts", `Float ts])
                            | `Duplicate ts ->
                              respond_ok (`Assoc ["ok", `Bool true; "ts", `Float ts; "duplicate", `Bool true])
                            | `Error (code, msg) ->
                              respond_bad_request (json_error_str code msg)
                    end
                  end
                end
            end
      end

  (* B115: /poll_inbox and /peek_inbox expose inbox contents, so they are
     bound to a verified owner. [require_owner] is true whenever the relay
     runs with a Bearer token configured (auth_mode "prod" in /health); in
     that mode an unverified request is rejected here even if the outer
     route classifier ever regresses (defense in depth — auth_decision
     already refuses these routes without a verified Ed25519 header).
     The unverified legacy path survives ONLY in dev mode (no token
     configured), the explicit development-only setting. *)
  let handle_inbox_read relay ~verified_alias ~require_owner ~route ~read body =
    let node_id = get_string body "node_id" in
    let session_id = get_string body "session_id" in
    if node_id = "" || session_id = "" then
      respond_bad_request (json_error_str err_bad_request "node_id and session_id are required")
    else
      match verified_alias with
      | Some v ->
        (match R.alias_of_session relay ~node_id ~session_id with
         | Some owner when owner = v ->
           let msgs = read relay ~node_id ~session_id in
           respond_ok (json_ok [ ("messages", `List msgs) ])
         | _ -> reject_session_mismatch ~verified:v ~node_id ~session_id)
      | None ->
        if require_owner then
          respond_unauthorized (json_error_str err_unauthorized
            (route ^ " requires an Ed25519-signed request from the session owner"))
        else
          let msgs = read relay ~node_id ~session_id in
          respond_ok (json_ok [ ("messages", `List msgs) ])

  let handle_poll_inbox relay ~verified_alias ~require_owner body =
    handle_inbox_read relay ~verified_alias ~require_owner
      ~route:"poll_inbox" ~read:R.poll_inbox body

  let handle_peek_inbox relay ~verified_alias ~require_owner body =
    handle_inbox_read relay ~verified_alias ~require_owner
      ~route:"peek_inbox" ~read:R.peek_inbox body

  let handle_remote_inbox session_id =
    let msgs = Relay_remote_broker.get_messages ~session_id in
    respond_ok (json_ok [ ("messages", `List msgs) ])

  (* Layer 4 slice 1: verify optional signed proof on room join/leave.
     Returns [Ok ()] when either (a) no proof fields are present (legacy
     path) or (b) all fields present and verify correctly. Returns
     [Error (code, msg)] for any partial/invalid/forged proof. *)
  let verify_room_op_proof relay ?(extra_signed_fields = []) ~sign_ctx ~room_id ~alias body =
    let identity_pk_b64 = get_opt_string body "identity_pk" |> Option.value ~default:"" in
    let signature_b64 = get_opt_string body "sig" |> Option.value ~default:"" in
    let nonce_b64 = get_opt_string body "nonce" |> Option.value ~default:"" in
    let timestamp_str = get_opt_string body "ts" |> Option.value ~default:"" in
    let has_proof =
      identity_pk_b64 <> "" && signature_b64 <> ""
      && nonce_b64 <> "" && timestamp_str <> ""
    in
    let partial =
      (identity_pk_b64 <> "" || signature_b64 <> ""
       || nonce_b64 <> "" || timestamp_str <> "")
      && not has_proof
    in
    if partial then
      Res.Error (relay_err_missing_proof_field,
        "identity_pk, sig, nonce, and ts must all be present together")
    else if not has_proof then
      if require_signed_room_ops () then
        Res.Error (relay_err_unsigned_room_op,
          "unsigned room op rejected; client must upgrade to sign room ops "
          ^ "and/or set C2C_REQUIRE_SIGNED_ROOM_OPS=0 on the server")
      else
        (Logs.warn (fun m -> m "unsigned room op %s for %S (no identity loaded — this is safe in dev but indicates a client gap in prod)" sign_ctx alias);
         Res.Ok ())  (* legacy unsigned path — accept *)
    else
      match decode_b64url identity_pk_b64 with
      | Res.Error _ -> Res.Error (err_bad_request, "identity_pk not base64url-nopad")
      | Res.Ok identity_pk when String.length identity_pk <> 32 ->
        Res.Error (err_bad_request, "identity_pk must be 32 bytes")
      | Res.Ok identity_pk ->
        match decode_b64url signature_b64 with
        | Error _ -> Error (err_bad_request, "sig not base64url-nopad")
        | Ok sig_ when String.length sig_ <> 64 ->
          Error (relay_err_signature_invalid, "sig must be 64 bytes")
        | Ok sig_ ->
          match parse_rfc3339_utc timestamp_str with
          | None -> Error (err_bad_request, "ts must be RFC3339 UTC")
          | Some ts_client ->
            let now = Unix.gettimeofday () in
            let skew = ts_client -. now in
            if skew > register_ts_future_window || -. skew > register_ts_past_window then
              Error (relay_err_timestamp_out_of_window,
                Printf.sprintf "ts skew %.1fs outside window" skew)
            else
              match R.check_register_nonce relay ~nonce:nonce_b64 ~ts:ts_client with
              | Error code -> Error (code, "nonce already seen within TTL")
              | Ok () ->
                (* Bind identity_pk to alias: must match any existing binding. *)
                (match R.identity_pk_of relay ~alias with
                 | Some bound when bound <> identity_pk ->
                   Error (relay_err_alias_identity_mismatch,
                     "identity_pk does not match registered binding")
                 | _ ->
                           let blob =
                             Relay_identity.canonical_msg ~ctx:sign_ctx
                               ([ room_id; alias ] @ extra_signed_fields
                                @ [ identity_pk_b64; timestamp_str; nonce_b64 ])
                           in
                   if Relay_identity.verify ~pk:identity_pk ~msg:blob ~sig_ then
                     Ok ()
                   else
                     Error (relay_err_signature_invalid,
                       "Ed25519 signature does not verify"))

  let handle_join_room relay body =
    let alias = get_string body "alias" in
    let room_id = get_string body "room_id" in
    (* Optional visibility — only applied if this join creates the room. *)
    let visibility_raw = get_opt_string body "visibility" in
    let requested_visibility =
      match visibility_raw with
      | None | Some "" -> Some "public"
      | Some v -> canonical_visibility v
    in
    if alias = "" || room_id = "" then
      respond_bad_request (json_error_str err_bad_request "alias and room_id are required")
    else match requested_visibility with
    | None ->
      respond_bad_request (json_error_str err_bad_request
        "visibility must be \"public\", \"unlisted\", \"gated\", or \"private\"")
    | Some requested_visibility ->
      let extra_signed_fields =
        match visibility_raw with
        | Some v when String.trim v <> "" -> [ requested_visibility ]
        | _ -> []
      in
      match verify_room_op_proof relay ~sign_ctx:room_join_sign_ctx
              ~extra_signed_fields ~room_id ~alias body with
      | Error (code, msg) ->
        if code = err_bad_request || code = relay_err_missing_proof_field then
          respond_bad_request (json_error_str code msg)
        else
          respond_unauthorized (json_error_str code msg)
      | Ok () ->
        (* L4/5 ACL: gated and private rooms are invite-gated — require
           identity_pk ∈ invited. public and unlisted rooms are open-join. A
           brand-new room has no stored visibility yet (defaults to "public"
           here), so the creator is always admitted and the room is then
           created with [requested_visibility]. *)
        let visibility = R.room_visibility_of relay ~room_id in
        let pk_b64 = get_opt_string body "identity_pk" |> Option.value ~default:"" in
        let open_join = visibility = "public" || visibility = "unlisted" in
        let admitted =
          open_join
          || (pk_b64 <> "" && R.is_invited relay ~room_id ~identity_pk_b64:pk_b64)
        in
        if not admitted then
          respond_unauthorized (json_error_str relay_err_not_invited
            (Printf.sprintf "room %S requires an invite and caller is not on the list" room_id))
        else
        let result = R.join_room relay ~visibility:requested_visibility ~alias ~room_id () in
        respond_ok (match result with
          | `Ok -> json_of_room_join_result `Ok
          | `Error (code, msg) -> json_error code msg [])

  (* L4/5 — set_room_visibility. Signed by any existing room member. *)
  let handle_set_room_visibility relay body =
    let alias = get_string body "alias" in
    let room_id = get_string body "room_id" in
    let visibility_raw = get_string body "visibility" in
    if alias = "" || room_id = "" || visibility_raw = "" then
      respond_bad_request (json_error_str err_bad_request
        "alias, room_id, and visibility are required")
    else match canonical_visibility visibility_raw with
    | None ->
      respond_bad_request (json_error_str err_bad_request
        "visibility must be \"public\", \"unlisted\", \"gated\", or \"private\"")
    | Some visibility ->
      match verify_room_op_proof relay
              ~sign_ctx:room_set_visibility_sign_ctx
              ~extra_signed_fields:[ visibility ]
              ~room_id ~alias body with
      | Error (code, msg) ->
        if code = err_bad_request || code = relay_err_missing_proof_field then
          respond_bad_request (json_error_str code msg)
        else
          respond_unauthorized (json_error_str code msg)
      | Ok () ->
        if not (R.is_room_member_alias relay ~room_id ~alias) then
          respond_unauthorized (json_error_str relay_err_not_a_member
            (Printf.sprintf "alias %S is not a member of room %S" alias room_id))
        else begin
          R.set_room_visibility relay ~room_id ~visibility;
          respond_ok (`Assoc [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ("visibility", `String visibility);
          ])
        end

  (* L4/5 — invite / uninvite. Signed by any existing room member. *)
  let handle_room_invite_op relay ~sign_ctx ~op body =
    let alias = get_string body "alias" in
    let room_id = get_string body "room_id" in
    let target_pk = get_string body "invitee_pk" in
    if alias = "" || room_id = "" || target_pk = "" then
      respond_bad_request (json_error_str err_bad_request
        "alias, room_id, and invitee_pk are required")
    else
      match verify_room_op_proof relay ~sign_ctx ~room_id ~alias body with
      | Error (code, msg) ->
        if code = err_bad_request || code = relay_err_missing_proof_field then
          respond_bad_request (json_error_str code msg)
        else
          respond_unauthorized (json_error_str code msg)
      | Ok () ->
        if not (R.is_room_member_alias relay ~room_id ~alias) then
          respond_unauthorized (json_error_str relay_err_not_a_member
            (Printf.sprintf "alias %S is not a member of room %S" alias room_id))
        else begin
          (match op with
           | `Invite ->
             R.invite_to_room relay ~room_id ~identity_pk_b64:target_pk
           | `Uninvite ->
             R.uninvite_from_room relay ~room_id ~identity_pk_b64:target_pk);
          let invites = R.room_invites_of relay ~room_id in
          respond_ok (`Assoc [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ("invited_members", `List (List.map (fun s -> `String s) invites));
          ])
        end

  let handle_invite_room relay body =
    handle_room_invite_op relay ~sign_ctx:room_invite_sign_ctx ~op:`Invite body

  let handle_uninvite_room relay body =
    handle_room_invite_op relay ~sign_ctx:room_uninvite_sign_ctx ~op:`Uninvite body

  let handle_knock_room relay body =
    let alias = get_string body "alias" in
    let room_id = get_string body "room_id" in
    if alias = "" || room_id = "" then
      respond_bad_request (json_error_str err_bad_request "alias and room_id are required")
    else
      match verify_room_op_proof relay ~sign_ctx:room_knock_sign_ctx
              ~room_id ~alias body with
      | Error (code, msg) ->
        if code = err_bad_request || code = relay_err_missing_proof_field then
          respond_bad_request (json_error_str code msg)
        else
          respond_unauthorized (json_error_str code msg)
      | Ok () ->
        let requester_pk =
          match get_opt_string body "identity_pk" with
          | Some pk when pk <> "" -> pk
          | _ -> get_opt_string body "requester_pk" |> Option.value ~default:""
        in
        if requester_pk = "" then
          respond_bad_request (json_error_str err_bad_request
            "identity_pk is required for knock_room")
        else
          match R.knock_room relay ~room_id ~requester_alias:alias
                  ~requester_pk with
          | `Ok already_pending ->
            respond_ok (`Assoc [
              ("ok", `Bool true);
              ("room_id", `String room_id);
              ("requester_alias", `String alias);
              ("requester_pk", `String requester_pk);
              ("already_pending", `Bool already_pending);
              ("notified", `List []);
            ])
          | `Error (code, msg) when code = relay_err_not_found ->
            respond_not_found (json_error_str code msg)
          | `Error (code, msg) ->
            respond_bad_request (json_error_str code msg)

  let handle_list_room_knocks relay body =
    let alias = get_string body "alias" in
    let room_id = get_string body "room_id" in
    if alias = "" || room_id = "" then
      respond_bad_request (json_error_str err_bad_request "alias and room_id are required")
    else
      match verify_room_op_proof relay ~sign_ctx:room_list_knocks_sign_ctx
              ~room_id ~alias body with
      | Error (code, msg) ->
        if code = err_bad_request || code = relay_err_missing_proof_field then
          respond_bad_request (json_error_str code msg)
        else
          respond_unauthorized (json_error_str code msg)
      | Ok () ->
        if not (R.is_room_member_alias relay ~room_id ~alias) then
          respond_unauthorized (json_error_str relay_err_not_a_member
            (Printf.sprintf "alias %S is not a member of room %S" alias room_id))
        else
          let knocks = R.room_knocks_of relay ~room_id in
          respond_ok (`Assoc [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ("knocks", `List (List.map json_of_room_knock knocks));
          ])

  let handle_room_knock_decision relay ~sign_ctx ~decision body =
    let alias = get_string body "alias" in
    let room_id = get_string body "room_id" in
    let requester_pk = get_string body "requester_pk" in
    if alias = "" || room_id = "" || requester_pk = "" then
      respond_bad_request (json_error_str err_bad_request
        "alias, room_id, and requester_pk are required")
    else
      match verify_room_op_proof relay ~sign_ctx ~room_id ~alias
              ~extra_signed_fields:[ requester_pk ] body with
      | Error (code, msg) ->
        if code = err_bad_request || code = relay_err_missing_proof_field then
          respond_bad_request (json_error_str code msg)
        else
          respond_unauthorized (json_error_str code msg)
      | Ok () ->
        if not (R.is_room_member_alias relay ~room_id ~alias) then
          respond_unauthorized (json_error_str relay_err_not_a_member
            (Printf.sprintf "alias %S is not a member of room %S" alias room_id))
        else
          match R.remove_room_knock relay ~room_id ~requester_pk with
          | None ->
            respond_bad_request (json_error_str relay_err_no_pending_knock
              (Printf.sprintf "no pending knock from requester_pk %S in room %S"
                 requester_pk room_id))
          | Some removed ->
            (match decision with
             | `Approve ->
               R.invite_to_room relay ~room_id ~identity_pk_b64:requester_pk
             | `Deny -> ());
            let fields = [
              ("ok", `Bool true);
              ("room_id", `String room_id);
              ("requester_alias", `String removed.requester_alias);
              ("requester_pk", `String requester_pk);
              ("decision", `String (match decision with `Approve -> "approved" | `Deny -> "denied"));
            ] in
            let fields =
              match decision with
              | `Approve ->
                let invites = R.room_invites_of relay ~room_id in
                fields @ [
                  ("invited_members", `List (List.map (fun s -> `String s) invites));
                ]
              | `Deny -> fields
            in
            respond_ok (`Assoc fields)

  let handle_approve_room_knock relay body =
    handle_room_knock_decision relay
      ~sign_ctx:room_approve_knock_sign_ctx ~decision:`Approve body

  let handle_deny_room_knock relay body =
    handle_room_knock_decision relay
      ~sign_ctx:room_deny_knock_sign_ctx ~decision:`Deny body

  let handle_leave_room relay body =
    let alias = get_string body "alias" in
    let room_id = get_string body "room_id" in
    if alias = "" || room_id = "" then
      respond_bad_request (json_error_str err_bad_request "alias and room_id are required")
    else
      match verify_room_op_proof relay ~sign_ctx:room_leave_sign_ctx
              ~room_id ~alias body with
      | Error (code, msg) ->
        if code = err_bad_request || code = relay_err_missing_proof_field then
          respond_bad_request (json_error_str code msg)
        else
          respond_unauthorized (json_error_str code msg)
      | Ok () ->
        let result = R.leave_room relay ~alias ~room_id in
        respond_ok (json_of_room_join_result result)

  (* Layer 4 slice 2: verify optional signed envelope on /send_room.
     Envelope shape per spec §2: {ct, enc, sender_pk, sig, ts, nonce}.
     In v1, `ct` is base64url-nopad of the UTF-8 message text; relay
     still fans out `content` verbatim. Soft rollout: no envelope → legacy
     path. Envelope present → verify end-to-end before send_room. *)
  let verify_room_send_envelope relay ~from_alias ~room_id ~content body =
    match List.assoc_opt "envelope" (match body with `Assoc l -> l | _ -> []) with
    | None -> Ok ()  (* legacy unsigned path *)
    | Some env ->
      let es k = match env with
        | `Assoc l ->
          (match List.assoc_opt k l with Some (`String s) -> s | _ -> "")
        | _ -> ""
      in
      let ct_b64 = es "ct" in
      let enc = es "enc" in
      let sender_pk_b64 = es "sender_pk" in
      let sig_b64 = es "sig" in
      let ts = es "ts" in
      let nonce = es "nonce" in
      if ct_b64 = "" || enc = "" || sender_pk_b64 = ""
         || sig_b64 = "" || ts = "" || nonce = "" then
        Error (relay_err_missing_proof_field,
          "envelope must include ct, enc, sender_pk, sig, ts, nonce")
      else if enc <> "none" then
        Error (relay_err_unsupported_enc,
          Printf.sprintf "enc=%S not supported in v1 (only \"none\")" enc)
      else
        match decode_b64url sender_pk_b64 with
        | Error _ -> Error (err_bad_request, "sender_pk not base64url-nopad")
        | Ok sender_pk when String.length sender_pk <> 32 ->
          Error (err_bad_request, "sender_pk must be 32 bytes")
        | Ok sender_pk ->
          match decode_b64url sig_b64 with
          | Error _ -> Error (err_bad_request, "sig not base64url-nopad")
          | Ok sig_ when String.length sig_ <> 64 ->
            Error (relay_err_signature_invalid, "sig must be 64 bytes")
          | Ok sig_ ->
            match decode_b64url ct_b64 with
            | Error _ -> Error (err_bad_request, "ct not base64url-nopad")
            | Ok ct_bytes ->
              (* v1 enc=none: ct must be UTF-8 of the content field. *)
              if ct_bytes <> content then
                Error (relay_err_signature_invalid,
                  "ct does not match content (enc=none)")
              else
                match parse_rfc3339_utc ts with
                | None -> Error (err_bad_request, "ts must be RFC3339 UTC")
                | Some ts_client ->
                  let now = Unix.gettimeofday () in
                  let skew = ts_client -. now in
                  if skew > register_ts_future_window
                     || -. skew > register_ts_past_window then
                    Error (relay_err_timestamp_out_of_window,
                      Printf.sprintf "ts skew %.1fs outside window" skew)
                  else
                    match R.check_register_nonce relay ~nonce ~ts:ts_client with
                    | Error code -> Error (code, "nonce already seen within TTL")
                    | Ok () ->
                      (match R.identity_pk_of relay ~alias:from_alias with
                       | Some bound when bound <> sender_pk ->
                         Error (relay_err_alias_identity_mismatch,
                           "sender_pk does not match registered binding")
                       | _ ->
                         let ct_hash = body_sha256_b64 ct_bytes in
                         let blob =
                           Relay_identity.canonical_msg ~ctx:Relay_signed_ops.room_send_sign_ctx
                             [ room_id; from_alias; sender_pk_b64; enc;
                               ct_hash; ts; nonce ]
                         in
                         if Relay_identity.verify ~pk:sender_pk ~msg:blob ~sig_ then
                           Ok ()
                         else
                           Error (relay_err_signature_invalid,
                             "Ed25519 envelope signature does not verify"))

  let handle_send_room relay body =
    let from_alias = get_string body "from_alias" in
    let room_id = get_string body "room_id" in
    let content = get_string body "content" in
    if from_alias = "" || room_id = "" || content = "" then
      respond_bad_request (json_error_str err_bad_request "from_alias, room_id, and content are required")
    else
      match verify_room_send_envelope relay ~from_alias ~room_id ~content body with
      | Error (code, msg) ->
        if code = err_bad_request
           || code = relay_err_missing_proof_field
           || code = relay_err_unsupported_enc then
          respond_bad_request (json_error_str code msg)
        else
          respond_unauthorized (json_error_str code msg)
      | Ok () ->
        let message_id = get_opt_string body "message_id" in
        let envelope =
          match body with
          | `Assoc l ->
            (match List.assoc_opt "envelope" l with
             | Some e -> Some e | None -> None)
          | _ -> None
        in
        match R.send_room relay ~from_alias ~room_id ~content
                ~message_id ?envelope () with
        | `Error (code, msg) ->
          if code = relay_err_unknown_alias then
            respond_not_found (json_error_str code msg)
          else
            respond_unauthorized (json_error_str code msg)
        | `Ok (ts, delivered, skipped) ->
          List.iter (fun to_alias ->
            match R.identity_pk_of relay ~alias:to_alias with
            | Some identity_pk ->
              (match binding_id_of_phone_pk ~phone_ed25519_pubkey:identity_pk with
               | Some binding_id ->
                  let sq_msg = {
                    Relay_short_queue.ts;
                    from_alias;
                    to_alias;
                    room_id = Some room_id;
                    content;
                  } in
                  Relay_short_queue.ShortQueue.push short_queue ~binding_id sq_msg;
                  push_to_observers ~binding_id sq_msg
                | None -> ())
             | None -> ()
           ) delivered;
           respond_ok (json_of_send_room_result (ts, delivered, skipped))

  let handle_room_history relay ~verified_alias body =
    let room_id = get_string body "room_id" in
    if room_id = "" then
      respond_bad_request (json_error_str err_bad_request "room_id is required")
    else
      let limit = get_int body "limit" 50 in
      let visibility = R.room_visibility_of relay ~room_id in
      let open_read = visibility = "public" || visibility = "unlisted" in
      let member_read =
        match verified_alias with
        | Some alias -> R.is_room_member_alias relay ~room_id ~alias
        | None -> false
      in
      if (not open_read) && not member_read then
        respond_unauthorized
          (json_error_str relay_err_not_a_member
             (Printf.sprintf "room %S history requires membership" room_id))
      else
        let history = R.room_history relay ~room_id ~limit in
        respond_ok (json_ok [ ("room_id", `String room_id); ("history", `List history) ])

  (* S5a: POST /mobile-pair/prepare — store signed pairing token, return binding_id *)
  let handle_mobile_pair_prepare relay ~client_ip body =
    let open Yojson.Safe.Util in
    let machine_pk = get_opt_string body "machine_ed25519_pubkey" |> Option.value ~default:"" in
    let token_b64 = get_opt_string body "token" |> Option.value ~default:"" in
    if machine_pk = "" then respond_bad_request (json_error_str err_bad_request "machine_ed25519_pubkey is required")
    else if token_b64 = "" then respond_bad_request (json_error_str err_bad_request "token is required")
    else
      match decode_b64url machine_pk with
      | Error _ -> respond_bad_request (json_error_str err_bad_request "machine_ed25519_pubkey not base64url-nopad")
      | Ok pk when String.length pk <> 32 -> respond_bad_request (json_error_str err_bad_request "machine_ed25519_pubkey must be 32 bytes")
      | Ok _ ->
        match decode_token_json token_b64 with
        | None -> respond_bad_request (json_error_str err_bad_request "token: invalid JSON or encoding")
        | Some token_json ->
          let open Yojson.Safe.Util in
          let token_fields = match token_json with `Assoc f -> f | _ -> [] in
          let binding_id = `Assoc token_fields |> member "binding_id" |> to_string_option |> Option.value ~default:"" in
          let issued_at = `Assoc token_fields |> member "issued_at" |> function `Float f -> f | `Int i -> float_of_int i | _ -> 0.0 in
          let expires_at = `Assoc token_fields |> member "expires_at" |> function `Float f -> f | `Int i -> float_of_int i | _ -> 0.0 in
          let sig_b64 = `Assoc token_fields |> member "sig" |> to_string_option |> Option.value ~default:"" in
          let nonce = `Assoc token_fields |> member "nonce" |> to_string_option |> Option.value ~default:"" in
          let now = Unix.gettimeofday () in
          if binding_id = "" then respond_bad_request (json_error_str err_bad_request "token missing binding_id")
          else if sig_b64 = "" then respond_bad_request (json_error_str err_bad_request "token missing sig")
          else if nonce = "" then respond_bad_request (json_error_str err_bad_request "token missing nonce")
          else if now > expires_at then respond_bad_request (json_error_str err_bad_request "token expired")
          else if now < issued_at -. 5.0 then respond_bad_request (json_error_str err_bad_request "token issued_at in future")
          else if expires_at -. issued_at > 300.0 then respond_bad_request (json_error_str err_bad_request "token TTL exceeds 300s server cap")
          else if not (is_valid_binding_id binding_id) then respond_bad_request (json_error_str err_bad_request "binding_id must be 8-64 chars of [A-Za-z0-9_-]")
          else
            match decode_b64url sig_b64 with
            | Error _ -> respond_bad_request (json_error_str err_bad_request "token sig not base64url-nopad")
            | Ok sig_raw ->
              let blob = canonical_token_msg ~binding_id ~machine_ed25519_pubkey_b64:machine_pk
                ~issued_at ~expires_at ~nonce in
              match decode_b64url machine_pk with
              | Error _ -> respond_bad_request (json_error_str err_bad_request "machine_ed25519_pubkey decode")
              | Ok pk_raw ->
                  if not (Relay_identity.verify ~pk:pk_raw ~msg:blob ~sig_:sig_raw) then
                    respond_unauthorized (json_error_str relay_err_signature_invalid "token signature verification failed")
                  else
                    let is_rebind = R.find_pairing_token relay ~binding_id in
                    match R.store_pairing_token relay ~binding_id ~token_b64 ~machine_ed25519_pubkey:machine_pk ~expires_at with
                    | Error e -> respond_internal_error (json_error_str err_internal_error e)
                    | Ok () ->
                      let () = if is_rebind then
                        Relay_ratelimit.structured_log ~event:"pair_rebound"
                          ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip) ~result:"overwrite" ()
                      in
                      Relay_ratelimit.structured_log ~event:"pair_requested"
                        ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip) ~result:"ok" ();
                      respond_ok (`Assoc ["binding_id", `String binding_id])

  (* S5a: POST /mobile-pair — verify token sig, burn atomically, create binding *)
  let handle_mobile_pair relay body =
    let open Yojson.Safe.Util in
    let token_b64 = get_opt_string body "token" |> Option.value ~default:"" in
    let phone_ed_pk = get_opt_string body "phone_ed25519_pubkey" |> Option.value ~default:"" in
    let phone_x_pk = get_opt_string body "phone_x25519_pubkey" |> Option.value ~default:"" in
    if token_b64 = "" then respond_bad_request (json_error_str err_bad_request "token is required")
    else if phone_ed_pk = "" || phone_x_pk = "" then
      respond_bad_request (json_error_str err_bad_request "phone_ed25519_pubkey and phone_x25519_pubkey are required")
    else
      match decode_token_json token_b64 with
      | None -> respond_bad_request (json_error_str err_bad_request "token: invalid JSON or encoding")
      | Some token_json ->
        let open Yojson.Safe.Util in
        let token_fields = match token_json with `Assoc f -> f | _ -> [] in
        let binding_id = `Assoc token_fields |> member "binding_id" |> to_string_option |> Option.value ~default:"" in
        let machine_pk = `Assoc token_fields |> member "machine_ed25519_pubkey" |> to_string_option |> Option.value ~default:"" in
        let issued_at = `Assoc token_fields |> member "issued_at" |> function `Float f -> f | `Int i -> float_of_int i | _ -> 0.0 in
        let expires_at = `Assoc token_fields |> member "expires_at" |> function `Float f -> f | `Int i -> float_of_int i | _ -> 0.0 in
        let nonce = `Assoc token_fields |> member "nonce" |> to_string_option |> Option.value ~default:"" in
        let sig_b64 = `Assoc token_fields |> member "sig" |> to_string_option |> Option.value ~default:"" in
        let now = Unix.gettimeofday () in
        if binding_id = "" then respond_bad_request (json_error_str err_bad_request "token missing binding_id")
        else if machine_pk = "" then respond_bad_request (json_error_str err_bad_request "token missing machine_ed25519_pubkey")
        else if sig_b64 = "" then respond_bad_request (json_error_str err_bad_request "token missing sig")
        else if nonce = "" then respond_bad_request (json_error_str err_bad_request "token missing nonce")
        else if now > expires_at then respond_bad_request (json_error_str err_bad_request "token expired")
        else if now < issued_at -. 5.0 then respond_bad_request (json_error_str err_bad_request "token issued_at in future")
        else if not (is_valid_binding_id binding_id) then respond_bad_request (json_error_str err_bad_request "binding_id must be 8-64 chars of [A-Za-z0-9_-]")
        else
          match decode_b64url sig_b64 with
          | Error _ -> respond_bad_request (json_error_str err_bad_request "token sig not base64url-nopad")
          | Ok sig_raw ->
            let blob = canonical_token_msg ~binding_id ~machine_ed25519_pubkey_b64:machine_pk
              ~issued_at ~expires_at ~nonce in
            match decode_b64url machine_pk with
            | Error _ -> respond_bad_request (json_error_str err_bad_request "token machine_ed25519_pubkey decode")
            | Ok pk_raw ->
              if not (Relay_identity.verify ~pk:pk_raw ~msg:blob ~sig_:sig_raw) then
                respond_unauthorized (json_error_str relay_err_signature_invalid "token signature verification failed")
              else
                match R.get_and_burn_pairing_token relay ~binding_id with
                | None -> respond_bad_request (json_error_str err_bad_request "token already used, expired, or not found")
                | Some (stored_token, stored_pk) ->
                  if stored_token <> token_b64 then
                    respond_bad_request (json_error_str err_bad_request "token mismatch after burn")
                  else if stored_pk <> machine_pk then
                    respond_bad_request (json_error_str err_bad_request "machine_ed25519_pubkey mismatch")
                  else
                    match decode_b64url phone_ed_pk with
                    | Error _ -> respond_bad_request (json_error_str err_bad_request "phone_ed25519_pubkey invalid encoding")
                    | Ok p when String.length p <> 32 -> respond_bad_request (json_error_str err_bad_request "phone_ed25519_pubkey must be 32 bytes")
                    | Ok _ ->
                      match decode_b64url phone_x_pk with
                      | Error _ -> respond_bad_request (json_error_str err_bad_request "phone_x25519_pubkey invalid encoding")
                      | Ok p when String.length p <> 32 -> respond_bad_request (json_error_str err_bad_request "phone_x25519_pubkey must be 32 bytes")
                      | Ok _ ->
                        let () = R.add_observer_binding relay ~binding_id
                          ~phone_ed25519_pubkey:phone_ed_pk ~phone_x25519_pubkey:phone_x_pk
                          ~machine_ed25519_pubkey:machine_pk ~provenance_sig:sig_b64 in
                        let bound_at = Unix.gettimeofday () in
                        let () = push_pseudo_registration_to_observers ~binding_id
                          ~phone_ed_pk:phone_ed_pk ~phone_x_pk:phone_x_pk
                          ~machine_ed_pk:machine_pk ~provenance_sig:sig_b64 ~bound_at in
                        let confirm_json = `Assoc [
                          "binding_id", `String binding_id;
                          "phone_ed25519_pubkey", `String phone_ed_pk;
                          "phone_x25519_pubkey", `String phone_x_pk;
                          "bound_at", `Float bound_at
                        ] in
                        let confirm_b64 = Yojson.Safe.to_string confirm_json |>
                          Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet in
                        Relay_ratelimit.structured_log ~event:"pair_confirmed"
                          ~binding_id_prefix:(Relay_ratelimit.prefix8 binding_id)
                          ~source_ip_prefix:"" ~result:"ok" ();
                        respond_ok (`Assoc [
                          "ok", `Bool true;
                          "binding_id", `String binding_id;
                          "confirmation", `String confirm_b64
                        ])

  (* S5a: DELETE /binding/<binding_id> — revoke a mobile binding *)
  let handle_mobile_pair_revoke relay ~client_ip binding_id =
    if not (is_valid_binding_id binding_id) then
      respond_bad_request (json_error_str err_bad_request "binding_id must be 8-64 chars of [A-Za-z0-9_-]")
    else
      let existed = match R.get_observer_binding relay ~binding_id with
        | None -> false
        | Some _ -> true
      in
      R.remove_observer_binding relay ~binding_id;
      (if existed then push_pseudo_unregistration_to_observers ~binding_id else ());
      Relay_ratelimit.structured_log ~event:"pair_revoke"
        ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
        ~result:(if existed then "ok" else "not_found") ();
      if existed then respond_ok (`Assoc ["ok", `Bool true; "binding_id", `String binding_id])
      else respond_not_found (json_error_str err_not_found "binding_id not found")

  (* S5b: Device-login OAuth-style fallback (§S5b).
     User flow: machine init → phone registers via web → machine polls to claim. *)

  let generate_user_code () =
    let chars = "abcdefghijklmnopqrstuvwxyz234567" in
    let raw = Bytes.create 5 in
    for i = 0 to 4 do Bytes.set raw i (chars.[Random.int 32]) done;
    Bytes.to_string raw

  (* S5b: POST /device-pair/init — create pending device-pair, return user_code *)
  let handle_device_pair_init relay ~client_ip body =
    let open Yojson.Safe.Util in
    let machine_pk = get_opt_string body "machine_ed25519_pubkey" |> Option.value ~default:"" in
    if machine_pk = "" then respond_bad_request (json_error_str err_bad_request "machine_ed25519_pubkey required")
    else
      match decode_b64url machine_pk with
      | Error _ -> respond_bad_request (json_error_str err_bad_request "machine_ed25519_pubkey not base64url-nopad")
      | Ok pk when String.length pk <> 32 -> respond_bad_request (json_error_str err_bad_request "machine_ed25519_pubkey must be 32 bytes")
      | Ok _ ->
        let user_code = generate_user_code () in
        let binding_id = "dev-" ^ user_code in
        let now = Unix.gettimeofday () in
        let expires_at = now +. 600.0 in
        let pending = {
          binding_id;
          machine_ed25519_pubkey = machine_pk;
          phone_ed25519_pubkey = None;
          phone_x25519_pubkey = None;
          created_at = now;
          expires_at;
          fail_count = 0;
        } in
        R.set_device_pair_pending relay ~user_code pending;
        Relay_ratelimit.structured_log ~event:"device_pair_init"
          ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
          ~user_code_prefix:(Relay_ratelimit.prefix8 user_code)
          ~result:"ok" ();
        respond_ok (`Assoc [
          "user_code", `String user_code;
          "device_code", `String binding_id;
          "poll_interval", `Float 2.0;
          "expires_at", `Float expires_at
        ])

  (* S5b: POST /device-pair/<user_code> — phone registers its pubkeys *)
  let handle_device_pair_register relay ~client_ip ~user_code body =
    let open Yojson.Safe.Util in
    let phone_ed_pk = get_opt_string body "phone_ed25519_pubkey" |> Option.value ~default:"" in
    let phone_x_pk = get_opt_string body "phone_x25519_pubkey" |> Option.value ~default:"" in
    if phone_ed_pk = "" || phone_x_pk = "" then
      respond_bad_request (json_error_str err_bad_request "phone_ed25519_pubkey and phone_x25519_pubkey required")
    else
      match R.get_device_pair_pending relay ~user_code with
      | None ->
        Relay_ratelimit.structured_log ~event:"device_pair_register"
          ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
          ~user_code_prefix:(Relay_ratelimit.prefix8 user_code)
          ~result:"user_code_not_found" ();
        respond_not_found (json_error_str err_not_found "user_code not found or expired")
      | Some pending ->
        if Unix.gettimeofday () > pending.expires_at then
          (R.remove_device_pair_pending relay ~user_code;
           respond_not_found (json_error_str err_not_found "user_code expired"))
        else
          match decode_b64url phone_ed_pk with
          | Error _ ->
            let new_fail = pending.fail_count + 1 in
            if new_fail >= 10 then
              (R.remove_device_pair_pending relay ~user_code;
               Relay_ratelimit.structured_log ~event:"device_pair_invalidated"
                 ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
                 ~user_code_prefix:(Relay_ratelimit.prefix8 user_code)
                 ~result:"max_failures" ();
               respond_not_found (json_error_str err_not_found "user_code invalidated"))
            else
              (R.set_device_pair_pending relay ~user_code { pending with fail_count = new_fail };
               respond_bad_request (json_error_str err_bad_request "phone_ed25519_pubkey not base64url-nopad"))
          | Ok ed when String.length ed <> 32 ->
            let new_fail = pending.fail_count + 1 in
            if new_fail >= 10 then
              (R.remove_device_pair_pending relay ~user_code;
               Relay_ratelimit.structured_log ~event:"device_pair_invalidated"
                 ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
                 ~user_code_prefix:(Relay_ratelimit.prefix8 user_code)
                 ~result:"max_failures" ();
               respond_not_found (json_error_str err_not_found "user_code invalidated"))
            else
              (R.set_device_pair_pending relay ~user_code { pending with fail_count = new_fail };
               respond_bad_request (json_error_str err_bad_request "phone_ed25519_pubkey must be 32 bytes"))
          | Ok _ ->
            match decode_b64url phone_x_pk with
            | Error _ ->
              let new_fail = pending.fail_count + 1 in
              if new_fail >= 10 then
                (R.remove_device_pair_pending relay ~user_code;
                 Relay_ratelimit.structured_log ~event:"device_pair_invalidated"
                   ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
                   ~user_code_prefix:(Relay_ratelimit.prefix8 user_code)
                   ~result:"max_failures" ();
                 respond_not_found (json_error_str err_not_found "user_code invalidated"))
              else
                (R.set_device_pair_pending relay ~user_code { pending with fail_count = new_fail };
                 respond_bad_request (json_error_str err_bad_request "phone_x25519_pubkey not base64url-nopad"))
            | Ok x when String.length x <> 32 ->
              let new_fail = pending.fail_count + 1 in
              if new_fail >= 10 then
                (R.remove_device_pair_pending relay ~user_code;
                 Relay_ratelimit.structured_log ~event:"device_pair_invalidated"
                   ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
                   ~user_code_prefix:(Relay_ratelimit.prefix8 user_code)
                   ~result:"max_failures" ();
                 respond_not_found (json_error_str err_not_found "user_code invalidated"))
              else
                (R.set_device_pair_pending relay ~user_code { pending with fail_count = new_fail };
                 respond_bad_request (json_error_str err_bad_request "phone_x25519_pubkey must be 32 bytes"))
            | Ok _ ->
              let updated = { pending with
                phone_ed25519_pubkey = Some phone_ed_pk;
                phone_x25519_pubkey = Some phone_x_pk
              } in
              R.set_device_pair_pending relay ~user_code updated;
              Relay_ratelimit.structured_log ~event:"device_pair_register"
                ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
                ~user_code_prefix:(Relay_ratelimit.prefix8 user_code)
                ~result:"ok" ();
              respond_ok (`Assoc ["ok", `Bool true])

  (* S5b: GET /device-pair/<user_code> — machine polls for phone registration *)
  let handle_device_pair_poll relay ~client_ip ~user_code =
    match R.get_device_pair_pending relay ~user_code with
    | None ->
      respond_not_found (json_error_str err_not_found "user_code not found")
    | Some pending ->
      if Unix.gettimeofday () > pending.expires_at then
        (R.remove_device_pair_pending relay ~user_code;
         respond_not_found (json_error_str err_not_found "user_code expired"))
      else
        match pending.phone_ed25519_pubkey, pending.phone_x25519_pubkey with
        | None, None ->
          respond_ok (`Assoc ["status", `String "pending"; "user_code", `String user_code])
        | Some ed_pk, Some x_pk ->
          let () = R.add_observer_binding relay ~binding_id:pending.binding_id
            ~phone_ed25519_pubkey:ed_pk ~phone_x25519_pubkey:x_pk
            ~machine_ed25519_pubkey:pending.machine_ed25519_pubkey ~provenance_sig:"" in
          let bound_at = Unix.gettimeofday () in
          let () = push_pseudo_registration_to_observers ~binding_id:pending.binding_id
            ~phone_ed_pk:ed_pk ~phone_x_pk:x_pk
            ~machine_ed_pk:pending.machine_ed25519_pubkey
            ~provenance_sig:"" ~bound_at in
          R.remove_device_pair_pending relay ~user_code;
          Relay_ratelimit.structured_log ~event:"device_pair_claimed"
            ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
            ~user_code_prefix:(Relay_ratelimit.prefix8 user_code)
            ~binding_id_prefix:(Relay_ratelimit.prefix8 pending.binding_id)
            ~result:"ok" ();
          respond_ok (`Assoc [
            "status", `String "claimed";
            "binding_id", `String pending.binding_id
          ])
        | _ ->
          respond_bad_request (json_error_str err_bad_request "incomplete registration")

  (* --- Main callback factory --- *)

  let meth_to_string = function
    | `GET -> "GET" | `POST -> "POST" | `PUT -> "PUT"
    | `DELETE -> "DELETE" | `HEAD -> "HEAD" | `PATCH -> "PATCH"
    | `OPTIONS -> "OPTIONS" | `CONNECT -> "CONNECT" | `TRACE -> "TRACE"
    | `Other s -> String.uppercase_ascii s

  (* If Authorization header starts with "Ed25519 ", verify the full proof
     per spec §5.1 and return [Ok (Some alias)]. Returns [Ok None] when no
     Ed25519 header is present so the caller can fall back to Bearer. *)
  let try_verify_ed25519_request relay ~auth_header ~meth ~path ~query
      ~body_sha256_b64 =
    match auth_header with
    | None -> Ok None
    | Some h ->
      let prefix = "Ed25519 " in
      let plen = String.length prefix in
      if String.length h < plen || String.sub h 0 plen <> prefix then
        Ok None
      else
        let params_str =
          String.sub h plen (String.length h - plen) |> String.trim
        in
        match parse_ed25519_auth_params params_str with
        | Error e -> Error (err_unauthorized, "malformed Ed25519 auth: " ^ e)
        | Ok (alias, ts_str, nonce, sig_b64) ->
          (match (try Some (float_of_string ts_str) with _ -> None) with
           | None -> Error (err_unauthorized, "ts must be unix seconds")
           | Some ts_client ->
             let now = Unix.gettimeofday () in
             let skew = ts_client -. now in
             if skew > request_ts_future_window
                || -. skew > request_ts_past_window then
               Error (relay_err_timestamp_out_of_window,
                 Printf.sprintf "request ts skew %.1fs outside window" skew)
             else
               match R.check_request_nonce relay ~nonce ~ts:ts_client with
               | Error code -> Error (code, "request nonce replay")
               | Ok () ->
                 match R.identity_pk_of relay ~alias with
                 | None ->
                   Error (err_unauthorized,
                     Printf.sprintf "alias %S has no identity binding" alias)
                 | Some pk ->
                   match decode_b64url sig_b64 with
                   | Error _ ->
                     Error (err_unauthorized, "sig not base64url-nopad")
                   | Ok sig_ when String.length sig_ <> 64 ->
                     Error (relay_err_signature_invalid, "sig must be 64 bytes")
                   | Ok sig_ ->
                      let blob =
                        Relay_signed_ops.canonical_request_blob ~meth ~path ~query
                          ~body_sha256_b64 ~ts:ts_str ~nonce
                     in
                     if Relay_identity.verify ~pk ~msg:blob ~sig_ then
                       let display_alias, _ =
                         normalize_relay_alias ~alias ~opaque_host_id:None
                       in
                       Ok (Some display_alias)
                     else
                         Error (relay_err_signature_invalid,
                           "Ed25519 request signature does not verify"))

  let get_client_ip (flow:Conduit_lwt_unix.flow) =
    match flow with
    | TCP { fd } ->
      (try
         let addr = Unix.getpeername (Lwt_unix.unix_file_descr fd) in
         match addr with
         | Unix.ADDR_INET (inet_addr, _) -> Unix.string_of_inet_addr inet_addr
         | _ -> "unix"
       with _ -> "unknown")
    | Domain_socket { fd } ->
      (try
         let addr = Unix.getpeername (Lwt_unix.unix_file_descr fd) in
         match addr with
         | Unix.ADDR_INET (inet_addr, _) -> Unix.string_of_inet_addr inet_addr
         | _ -> "unix"
       with _ -> "unknown")
    | _ -> "unknown"

  let get_fd_from_flow (flow:Conduit_lwt_unix.flow) =
    match flow with
    | TCP { fd } -> Some fd
    | Domain_socket { fd } -> Some fd
    | _ -> None

  let make_callback relay token conn req body ?(broker_root=None) ~rate_limiter =
    let open Cohttp in
    let open Cohttp_lwt_unix in
    let uri = Request.uri req in
    let path = Uri.path uri in
    let meth = Request.meth req in
    let client_ip = get_client_ip conn in
    let rate_key = client_ip in
    let rate_limit_event, rate_limit_binding_prefix =
      if String.length path > 10 && String.sub path 0 10 = "/observer/" then
        ("observer_handshake", Some (Relay_ratelimit.prefix8 (String.sub path 10 (String.length path - 10))))
      else
        ("rate_limit_denied", None)
    in
    match Rate_limiter_inst.check rate_limiter ~key:rate_key ~cost:1 ~path with
    | `Deny retry_after ->
        Relay_ratelimit.structured_log
          ~event:rate_limit_event
          ~binding_id_prefix:(match rate_limit_binding_prefix with Some p -> p | None -> "")
          ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
          ~result:"rate_limit_denied"
          ~reason:(path ^ " retry_after=" ^ string_of_float retry_after)
          ();
        respond_too_many_requests (`Assoc [
          "error", `String "rate_limit_exceeded";
          "retry_after", `Float retry_after
        ])
    | `Allow ->
      begin
        let auth_header = Header.get (Request.headers req) "Authorization" in
    let host_header = Header.get (Request.headers req) "Host" in
    (* Reconstruct the relay URL a client would have signed against.
       Scheme: forwarded-proto → X-Forwarded-Proto → uri.scheme → http. *)
    let scheme =
      match Header.get (Request.headers req) "X-Forwarded-Proto" with
      | Some s when s <> "" -> s
      | _ ->
        (match Uri.scheme uri with
         | Some s when s <> "" -> s
         | _ -> "http")
    in
    let relay_url =
      match host_header with
      | Some h when h <> "" -> Printf.sprintf "%s://%s" scheme h
      | _ -> ""
    in
    let query_bool name =
      match Uri.get_query_param uri name with
      | Some v -> let v = String.lowercase_ascii v in v = "1" || v = "true" || v = "yes"
      | None -> false
    in

    (* Auth check — L2/4 hard cut (spec §5.1, approved 2026-04-21).
       Peer routes require Ed25519 per-request signature; admin routes
       require Bearer. Mixing is rejected both ways. When no Bearer
       token is configured on the server (dev mode), admin routes
       still skip the Bearer check — mirrors prior behavior. *)
    Cohttp_lwt.Body.to_string body >>= fun body_str ->
    let body_sha256 = body_sha256_b64 body_str in
    let query = sorted_query_string uri in
    let ed25519_result =
      try_verify_ed25519_request relay ~auth_header
        ~meth:(meth_to_string meth) ~path ~query ~body_sha256_b64:body_sha256
    in
    let include_dead = query_bool "include_dead" in
    let verified_alias, ed25519_verified, ed25519_err =
      match ed25519_result with
      | Ok (Some a) -> (Some a, true, None)
      | Ok None -> (None, false, None)
      | Error (code, msg) -> (None, false, Some (code, msg))
    in
    let auth_ok, auth_err_msg =
      auth_decision ~path ~include_dead ~token ~auth_header ~ed25519_verified
    in
    if not auth_ok then
      let code, msg = match ed25519_err with
        | Some (c, m) -> c, m
        | None ->
          let m = match auth_err_msg with
            | Some m -> m
            | None -> "missing or invalid auth"
          in
          err_unauthorized, m
      in
      respond_unauthorized (json_error_str code msg)
    else
      let parse_body () =
        try Res.Ok (Yojson.Safe.from_string body_str)
        with Yojson.Json_error msg -> Res.Error msg
      in
      match meth, path with
      (* === S4: Observer WebSocket endpoint === *)
      | `GET, path when String.length path > 10 && String.sub path 0 10 = "/observer/" ->
        let binding_id = String.sub path 11 (String.length path - 11) in
        let upgrade = Header.get (Request.headers req) "Upgrade" in
        let sec_websocket_key = Header.get (Request.headers req) "Sec-WebSocket-Key" in
        let client_ip = get_client_ip conn in
        (match upgrade with
         | Some u when String.lowercase_ascii u = "websocket" ->
           (match sec_websocket_key with
            | None ->
              Relay_ratelimit.structured_log
                ~event:"observer_handshake"
                ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
                ~binding_id_prefix:(Relay_ratelimit.prefix8 binding_id)
                ~result:"missing_websocket_key" ();
              respond_bad_request (json_error_str "missing_sec_websocket_key" "Sec-WebSocket-Key header required")
            | Some ws_key ->
              let bearer_token = auth_header in
              let valid_binding =
                match bearer_token with
                | Some t when String.length t > 7 && String.sub t 0 7 = "Bearer " ->
                  let token = String.sub t 7 (String.length t - 7) in
                  token = binding_id && get_observer_binding ~binding_id <> None
                | _ -> false
              in
              if not valid_binding then
                (Relay_ratelimit.structured_log
                  ~event:"observer_handshake"
                  ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
                  ~binding_id_prefix:(Relay_ratelimit.prefix8 binding_id)
                  ~result:"invalid_bearer_token" ();
                 respond_unauthorized (json_error_str "invalid_bearer_token" "Bearer token invalid or binding not found"))
              else
                match get_fd_from_flow conn with
                | None ->
                  Relay_ratelimit.structured_log
                    ~event:"observer_handshake"
                    ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
                    ~binding_id_prefix:(Relay_ratelimit.prefix8 binding_id)
                    ~result:"no_fd" ();
                  respond_json ~status:`Internal_server_error (json_error_str "internal_error" "Could not extract connection fd")
                | Some orig_fd ->
                  let ws_accept = Relay_ws_frame.make_handshake_response ws_key in
                  let fd_dup = Lwt_unix.unix_file_descr orig_fd |> Unix.dup in
                  let fd_dup_lwt = Lwt_unix.of_unix_file_descr fd_dup in
                  let (_:int) = Unix.write (Lwt_unix.unix_file_descr orig_fd) (Bytes.of_string ws_accept) 0 (String.length ws_accept) in
                  Unix.close (Lwt_unix.unix_file_descr orig_fd);
                  Relay_ratelimit.structured_log
                    ~event:"observer_handshake"
                    ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
                    ~binding_id_prefix:(Relay_ratelimit.prefix8 binding_id)
                    ~result:"upgraded" ();
                  Lwt.async (fun () ->
                    Lwt.catch (fun () ->
                      let session = Relay_ws_frame.Session.of_fd fd_dup_lwt in
                      ObserverSessions.register observer_sessions ~binding_id session;
                      let finally () =
                        ObserverSessions.remove observer_sessions ~binding_id session
                      in
                      let rec loop () =
                        Relay_ws_frame.Session.recv session >>= fun msg ->
                        match msg with
                        | None ->
                          finally ();
                          Lwt.return_unit
                        | Some (`Ping) ->
                          Relay_ws_frame.Session.send_text session "observer_pong" >>= fun () ->
                          loop ()
                        | Some (`Close (_, _)) ->
                          finally ();
                          Relay_ws_frame.Session.close_with ~code:1000 ~reason:"normal" () session
                        | Some (`Text raw) | Some (`Binary raw) ->
                          (match parse_observer_ws_msg raw with
                           | `Reconnect (since_ts, sig_b64) ->
                             let valid_sig =
                               match sig_b64 with
                               | Some sig_val ->
                                  (match get_observer_binding ~binding_id with
                                   | Some (phone_pk, _, _, _) ->
                                    (match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet sig_val with
                                     | Ok sig_raw ->
                                       (match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet phone_pk with
                                        | Ok pk_raw ->
                                          Relay_identity.verify ~pk:pk_raw ~msg:binding_id ~sig_:sig_raw
                                        | Error _ -> false)
                                     | Error _ -> false)
                                  | None -> false)
                               | None -> false
                             in
                             if not valid_sig then
                               (finally ();
                                Relay_ws_frame.Session.close_with ~code:4001 ~reason:"invalid_signature" () session >>= fun () ->
                                Lwt.return_unit)
                             else
                               (let sq_msgs = Relay_short_queue.ShortQueue.get_after short_queue ~binding_id ~since_ts in
                                let sq_json_msgs = List.map (fun (m : Relay_short_queue.message) ->
                                  `Assoc (
                                    ["ts", `Float m.ts;
                                     "from_alias", `String m.from_alias;
                                     "to_alias", `String m.to_alias]
                                      @ (match m.room_id with Some r -> ["room_id", `String r] | None -> [])
                                      @ ["content", `String m.content])
                                ) sq_msgs in
                                let gap = match Relay_short_queue.ShortQueue.oldest_ts short_queue ~binding_id with
                                  | Some oldest -> since_ts < oldest
                                  | None -> false
                                in
                                let backfill_msgs, gap_flag =
                                  if gap then
                                    match get_observer_binding ~binding_id with
                                    | Some (phone_pk, _, _, _) ->
                                      (match R.alias_of_identity_pk relay ~identity_pk:phone_pk with
                                       | Some alias ->
                                         let direct_msgs = R.query_messages_since relay ~alias ~since_ts in
                                         let room_msgs =
                                           let all_rooms = R.list_rooms relay in
                                           List.fold_left (fun (acc : Yojson.Safe.t list) room ->
                                             match room with
                                             | `Assoc fields ->
                                               (match List.assoc_opt "room_id" fields with
                                                | Some (`String room_id) ->
                                                  if R.is_room_member_alias relay ~room_id ~alias then
                                                    let hist = R.room_history relay ~room_id ~limit:100 in
                                                    let since_float = since_ts in
                                                    let filtered = List.filter (fun (msg : Yojson.Safe.t) ->
                                                      match msg with
                                                      | `Assoc f ->
                                                        (match List.assoc_opt "ts" f with
                                                         | Some (`Float t) -> t > since_float
                                                         | Some (`Int i) -> float_of_int i > since_float
                                                         | _ -> false)
                                                      | _ -> false
                                                    ) hist in
                                                    filtered @ acc
                                                  else acc
                                                | _ -> acc)
                                             | _ -> acc
                                           ) [] all_rooms
                                         in
                                         let all_msgs = direct_msgs @ room_msgs in
                                         (List.sort (fun (a : Yojson.Safe.t) (b : Yojson.Safe.t) ->
                                           let ts_a = match a with `Assoc f -> (match List.assoc_opt "ts" f with Some (`Float t) -> t | Some (`Int i) -> float_of_int i | _ -> 0.0) | _ -> 0.0 in
                                           let ts_b = match b with `Assoc f -> (match List.assoc_opt "ts" f with Some (`Float t) -> t | Some (`Int i) -> float_of_int i | _ -> 0.0) in
                                           compare ts_a ts_b
                                         ) all_msgs, [("gap", `Bool true)])
                                       | None -> ([], [("gap", `Bool true)]))
                                    | None -> ([], [("gap", `Bool true)])
                                  else ([], [])
                                in
                                let all_msgs = sq_json_msgs @ backfill_msgs in
                                let response = `Assoc (["type", `String "replay"; "messages", `List all_msgs] @ gap_flag) in
                                Relay_ws_frame.Session.send_text session (Yojson.Safe.to_string response) >>= fun () ->
                                loop ())
                           | `Ping ->
                             Relay_ws_frame.Session.send_text session "observer_pong" >>= fun () ->
                             loop ()
                           | `Unknown ->
                             Relay_ws_frame.Session.send_text session "observer_ack" >>= fun () ->
                             loop ())
                      in
                      Lwt.catch loop (fun e -> finally (); Lwt.return_unit)
                    ) (function
                      | End_of_file -> Lwt.return_unit
                      | e -> Lwt.return_unit
                    )
                  );
                  respond_ok (`Assoc ["ok", `Bool true; "msg", `String "websocket_session_started"]))
         | _ ->
           respond_bad_request (json_error_str "observer_upgrade_required" "Upgrade: websocket header required"))

      (* === Slice 2: WebSocket push subscription endpoint === *)
      | `GET, "/ws/subscribe" ->
        let upgrade = Header.get (Request.headers req) "Upgrade" in
        let sec_websocket_key = Header.get (Request.headers req) "Sec-WebSocket-Key" in
        let c2c_alias = Header.get (Request.headers req) "X-C2C-Alias" in
        let c2c_ts = Header.get (Request.headers req) "X-C2C-Timestamp" in
        let c2c_sig = Header.get (Request.headers req) "X-C2C-Signature" in
        let client_ip = get_client_ip conn in
        (match upgrade with
         | Some u when String.lowercase_ascii u = "websocket" ->
           (match sec_websocket_key, c2c_alias, c2c_ts, c2c_sig with
            | None, _, _, _ ->
              respond_bad_request (json_error_str "missing_sec_websocket_key" "Sec-WebSocket-Key header required")
            | _, None, _, _ | _, _, None, _ | _, _, _, None ->
              respond_unauthorized (json_error_str "missing_auth_headers" "X-C2C-Alias, X-C2C-Timestamp, X-C2C-Signature required")
            | Some ws_key, Some alias, Some ts_str, Some sig_b64 ->
              (* Validate auth *)
              let lookup_pk ~alias = R.identity_pk_of relay ~alias in
              (match Relay_ws_server.validate_subscribe_auth ~lookup_pk ~alias ~ts_str ~sig_b64 with
               | Relay_ws_server.Auth_error msg ->
                 Relay_ratelimit.structured_log
                   ~event:"ws_subscribe"
                   ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
                   ~result:"auth_failed" ();
                 respond_unauthorized (json_error_str "auth_failed" msg)
               | Relay_ws_server.Auth_ok validated_alias ->
                 match get_fd_from_flow conn with
                 | None ->
                   respond_json ~status:`Internal_server_error (json_error_str "internal_error" "Could not extract connection fd")
                 | Some orig_fd ->
                   let ws_accept = Relay_ws_server.make_upgrade_response ws_key in
                   let fd_dup = Lwt_unix.unix_file_descr orig_fd |> Unix.dup in
                   let fd_dup_lwt = Lwt_unix.of_unix_file_descr fd_dup in
                   let (_:int) = Unix.write (Lwt_unix.unix_file_descr orig_fd) (Bytes.of_string ws_accept) 0 (String.length ws_accept) in
                   Unix.close (Lwt_unix.unix_file_descr orig_fd);
                   Relay_ratelimit.structured_log
                     ~event:"ws_subscribe"
                     ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
                     ~result:"upgraded" ();
                   Lwt.async (fun () ->
                     Lwt.catch
                       (fun () ->
                          let lookup_pk_for_sub ~alias = R.identity_pk_of relay ~alias in
                          Relay_ws_server.handle_subscriber ~aliases:[validated_alias] ~fd:fd_dup_lwt ~lookup_pk:lookup_pk_for_sub)
                       (fun _ -> Lwt.return_unit));
                   respond_ok (`Assoc ["ok", `Bool true; "msg", `String "ws_subscribe_session_started"])))
         | _ ->
           respond_bad_request (json_error_str "websocket_upgrade_required" "Upgrade: websocket header required"))

      | `GET, "/" ->
        respond_html landing_html

      | `GET, "/health" ->
        let auth_mode = if token = None then "dev" else "prod" in
        handle_health ~auth_mode ()

      | `GET, "/list" ->
        handle_list relay ~include_dead:(query_bool "include_dead")

      | `GET, "/dead_letter" ->
        handle_dead_letter relay

      | `GET, "/device-login" ->
        respond_html device_login_html

      | `GET, "/list_rooms" ->
        handle_list_rooms relay

      | `POST, "/gc" ->
        handle_gc relay

      | `GET, path when String.length path > 8 && String.sub path 0 8 = "/pubkey/" ->
        let alias = String.sub path 8 (String.length path - 8) in
        handle_pubkey relay ~broker_root ~alias

      | `POST, "/admin/unbind" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_admin_unbind relay j)

      | `POST, "/register" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_register relay ~relay_url j)

      | `POST, "/heartbeat" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_heartbeat relay ~verified_alias j)

      | `POST, "/send" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_send relay ~verified_alias j)

      | `POST, "/send_all" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_send_all relay ~verified_alias j)

      | `POST, "/poll_inbox" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j ->
           handle_poll_inbox relay ~verified_alias
             ~require_owner:(token <> None) j)

      | `POST, "/peek_inbox" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j ->
           handle_peek_inbox relay ~verified_alias
             ~require_owner:(token <> None) j)

      | `POST, "/join_room" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_join_room relay j)

      | `POST, "/leave_room" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_leave_room relay j)

      | `POST, "/set_room_visibility" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_set_room_visibility relay j)

      | `POST, "/invite_room" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_invite_room relay j)

      | `POST, "/uninvite_room" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_uninvite_room relay j)

      | `POST, "/knock_room" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_knock_room relay j)

      | `POST, "/list_room_knocks" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_list_room_knocks relay j)

      | `POST, "/approve_room_knock" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_approve_room_knock relay j)

      | `POST, "/deny_room_knock" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_deny_room_knock relay j)

      | `POST, "/send_room" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_send_room relay j)

      | `POST, "/room_history" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_room_history relay ~verified_alias j)

      (* === #330 S4: inbound forward from peer relay === *)
      | `POST, "/forward" ->
        let auth_header = Header.get (Request.headers req) "Authorization" in
        handle_forward relay ~auth_header body_str

      | `GET, path when String.starts_with ~prefix:"/remote_inbox/" path ->
        let session_id = String.sub path 14 (String.length path - 14) in
        let valid =
          let n = String.length session_id in
          if n = 0 || n > 64 then false
          else begin
            let ok = ref true in
            String.iter (fun c ->
              if not ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                      || (c >= '0' && c <= '9') || c = '-' || c = '_')
              then ok := false
            ) session_id;
            !ok
          end
        in
        if not valid then
          respond_bad_request (json_error_str err_bad_request "invalid session_id")
        else
          handle_remote_inbox session_id

      (* === S4: Observer WebSocket endpoint (done) === *)

      (* === S5a: Mobile-pair endpoints === *)
      | `POST, "/mobile-pair/prepare" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_mobile_pair_prepare relay ~client_ip j)

      | `POST, "/mobile-pair" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_mobile_pair relay j)

      | `DELETE, path when String.starts_with ~prefix:"/binding/" path ->
        let binding_id = String.sub path 9 (String.length path - 9) in
        handle_mobile_pair_revoke relay ~client_ip binding_id

      (* === S5b: Device-pair endpoints === *)
      | `POST, "/device-pair/init" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_device_pair_init relay ~client_ip j)

      | `POST, path when String.starts_with ~prefix:"/device-pair/" path && String.length path > 13 ->
        let user_code = String.sub path 13 (String.length path - 13) in
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_device_pair_register relay ~client_ip ~user_code j)

      | `GET, path when String.starts_with ~prefix:"/device-pair/" path && String.length path > 13 ->
        let user_code = String.sub path 13 (String.length path - 13) in
        handle_device_pair_poll relay ~client_ip ~user_code

      | _ ->
        respond_not_found (json_error_str err_not_found ("unknown endpoint: " ^ path))
      end

  (* --- GC thread loop --- *)

  let rec gc_loop relay gc_interval =
    Lwt_unix.sleep gc_interval >>= fun () ->
    (try ignore (R.gc relay :> _) with
     | _ -> ());
    gc_loop relay gc_interval

  (* --- Server startup --- *)

  let start_server ~host ~port ~relay ~token ?(verbose=false) ?(gc_interval=0.0) ?tls ?(allowlist=[]) ?broker_root () =
    List.iter (fun (alias, identity_pk_b64) ->
      R.set_allowed_identity relay ~alias ~identity_pk_b64)
      allowlist;
    (match allowlist with
     | [] -> ()
     | _ ->
       Printf.printf "allowlist: %d pinned identities\n%!" (List.length allowlist));
      let rate_limiter = Rate_limiter_inst.create ~gc_interval:300.0 () in
    let callback (conn, _) req body =
      make_callback relay token conn req body ~rate_limiter ?broker_root
    in
    let gc_thread =
      if gc_interval > 0.0 then
        Lwt.async (fun () -> gc_loop relay gc_interval)
      else
        ()
    in
    let _ = gc_thread in
    let scheme = match tls with Some _ -> "https" | None -> "http" in
    let verbose_str = if verbose then " (verbose)" else "" in
    Printf.printf "c2c relay serving on %s://%s:%d%s\n%!" scheme host port verbose_str;
    (match tls with
     | Some _ -> Printf.printf "tls: enabled\n%!"
     | None -> ());
    (match token with
     | Some _ -> Printf.printf "auth: Bearer token required\n%!"
     | None -> Printf.printf "auth: DISABLED (no token set — do not expose publicly)\n%!");
    if gc_interval > 0.0 then
      Printf.printf "gc: running every %.0fs\n%!" gc_interval
    else
      Printf.printf "gc: disabled\n%!";
    let spec = Cohttp_lwt_unix.Server.make ~callback () in
    match tls with
    | None ->
        Cohttp_lwt_unix.Server.create ~mode:(`TCP (`Port port)) spec
    | Some (`Cert_key (cert_path, key_path)) ->
        Mirage_crypto_rng_unix.use_default ();
        Cohttp_lwt_unix.Server.create
          ~mode:(`TLS (`Crt_file_path cert_path,
                       `Key_file_path key_path,
                       `No_password,
                       `Port port))
          spec

end
