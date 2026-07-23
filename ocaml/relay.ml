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

(* --- B262/B263 contact-grant helpers (shared by both backends) ---------- *)

let contact_sha256_raw s =
  Digestif.SHA256.(to_raw_string (digest_string s))

let contact_b64url s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let contact_fp_of_pk pk = contact_sha256_raw pk

let contact_grant_id_of_verifier verifier = contact_b64url verifier

let contact_sender_fp_prefix sender_fp =
  let full = contact_b64url sender_fp in
  if String.length full <= 12 then full else String.sub full 0 12

let contact_random_secret () =
  (try Mirage_crypto_rng_unix.use_default () with _ -> ());
  Mirage_crypto_rng.generate 32

let contact_decode_grant_id grant_id =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet grant_id with
  | Ok v when String.length v = 32 -> Some v
  | _ -> None

let contact_scope_v1 = "dm-first-contact"

(* B262 §7.4: retain grant + message_id rows until max(expires,revoked)+7d. *)
let contact_grant_gc_grace_s = 7. *. 86_400.

type contact_grant_rec = {
  verifier : string;
  recipient_identity_fp : string;
  delivery_alias : string;
  sender_fp : string;
  scope : string;
  generation : int;
  created_at : float;
  expires_at : float;
  mutable revoked_at : float option;
  label : string option;
}

let contact_meta_of_rec (g : contact_grant_rec) : contact_grant_meta =
  {
    grant_id = contact_grant_id_of_verifier g.verifier;
    sender_fp_prefix = contact_sender_fp_prefix g.sender_fp;
    delivery_alias = g.delivery_alias;
    expires_at = g.expires_at;
    revoked_at = g.revoked_at;
    generation = g.generation;
    label = g.label;
  }

(* --- InMemoryRelay --- *)

module InMemoryRelay : RELAY = struct
  type t = {
    mutex : Mutex.t;
    leases : (string, RegistrationLease.t) Hashtbl.t;
    bindings : (string, string) Hashtbl.t;
    register_nonces : (string, float) Hashtbl.t;
    request_nonces : (string, float) Hashtbl.t;
    (* B116: dedicated revoke-proof nonce store, isolated from
       request_nonces (which the outer verifier writes pre-auth). *)
    revoke_nonces : (string, float) Hashtbl.t;
    inboxes : ((string * string), Yojson.Safe.t list) Hashtbl.t;
    dead_letter : Yojson.Safe.t Queue.t;
    rooms : (string, string list) Hashtbl.t;
    (* Layer 4 slice 5: per-room visibility and invited identity_pk list. *)
    room_visibility : (string, string) Hashtbl.t;  (* "public" | "unlisted" | "gated" | "private" *)
    (* B117: per-room history readability policy, persisted separately from
       visibility. Absent → default per visibility (history_public_of). *)
    room_history_public : (string, bool) Hashtbl.t;
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
    (* S5a: In-memory observer bindings —
       (phone_ed25519, phone_x25519, machine_ed25519, provenance_sig).
       B116: the machine key MUST be stored (not dropped) — binding
       revocation authorizes against it. *)
    observer_bindings_mem : (string, (string * string * string * string)) Hashtbl.t;
    (* S5b: Device-pair pending table (RFC 8628 OAuth, ephemeral) *)
    device_pair_pending_mem : (string, device_pair_pending) Hashtbl.t;
    (* #379: this relay's own host identity for alias@host validation *)
    self_host : string option;
    (* #330 S2: this relay's own Ed25519 identity for signing forward requests *)
    identity : Relay_identity.t;
    (* #330 S1: peer relays for cross-relay forwarding *)
    peer_relays : (string, peer_relay_t) Hashtbl.t;
    (* B147: usage stats. Message-accept timestamps (gc-pruned past the
       largest window), an all-time counter that survives pruning, and
       alias/machine -> last_seen for windowed distinct counts. *)
    mutable stats_message_events : float list;
    mutable stats_messages_ever : int;
    stats_seen_aliases : (string, float) Hashtbl.t;
    stats_seen_machines : (string, float) Hashtbl.t;
    (* B263: contact grants — verifier-keyed; never store raw secret. *)
    contact_grants : (string, contact_grant_rec) Hashtbl.t;
    contact_grant_mids : ((string * string), float) Hashtbl.t;
    contact_generation : (string, int) Hashtbl.t;
    (* B264: peer discovery visibility per alias. Default Private. *)
    discovery_visibility : (string, peer_discovery_visibility) Hashtbl.t;
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

  (* B117: per-room metadata (visibility + history_public) persisted alongside
     the history jsonl so a persist_dir-backed InMemoryRelay retains the
     policy across a restart. Without this, a restart reloads room history but
     defaults visibility/history_public, re-opening a deliberately-closed
     room's history to anonymous readers. *)
  let room_meta_json_path persist_dir room_id =
    Filename.concat (Filename.concat persist_dir ("rooms/" ^ room_id)) "meta.json"

  let write_room_meta persist_dir room_id ~visibility ~history_public =
    let path = room_meta_json_path persist_dir room_id in
    let dir = Filename.dirname path in
    (try
       C2c_io.mkdir_p dir;
       let j = `Assoc [
         ("visibility", `String visibility);
         ("history_public", `Bool history_public);
       ] in
       let tmp = path ^ ".tmp" in
       let oc = open_out tmp in
       output_string oc (Yojson.Safe.to_string j);
       close_out oc;
       Sys.rename tmp path
     with _ -> ())

  let load_room_meta_from_disk persist_dir room_visibility room_history_public =
    let rooms_dir = Filename.concat persist_dir "rooms" in
    if not (Sys.file_exists rooms_dir) then ()
    else begin
      let entries = try Array.to_list (Sys.readdir rooms_dir) with Sys_error _ -> [] in
      List.iter (fun room_id ->
        let path = room_meta_json_path persist_dir room_id in
        if Sys.file_exists path then begin
          (* B117 (review P1): meta.json EXISTS but is unreadable / malformed /
             missing a field ⇒ a deliberate policy was written but we can't
             trust it, so fail CLOSED (member-only) rather than re-open a
             possibly-closed history. A truly ABSENT meta.json is a legacy
             pre-B117 room (no branch here) and keeps the AC-mandated
             compatible-rollout default (public/unlisted → open). *)
          let fail_closed () =
            Hashtbl.replace room_history_public room_id false in
          match (try Some (Yojson.Safe.from_file path) with _ -> None) with
          | None -> fail_closed ()
          | Some j ->
            (* Accept the persisted OPEN value only when BOTH fields are
               present and well-formed. Any incompleteness (missing visibility,
               missing/invalid history_public, unparseable file) fails closed —
               symmetric, defence-in-depth against a partial/tampered write. *)
            (* canonical_visibility returns None for any unrecognized string,
               so a garbage/tampered visibility fails the both-fields-valid
               check below and falls through to fail_closed. *)
            let vis = match Yojson.Safe.Util.member "visibility" j with
              | `String v -> canonical_visibility v | _ -> None in
            let hp = match Yojson.Safe.Util.member "history_public" j with
              | `Bool b -> Some b | _ -> None in
            (match vis, hp with
             | Some v, Some b ->
               Hashtbl.replace room_visibility room_id v;
               Hashtbl.replace room_history_public room_id b
             | _ -> fail_closed ())
        end
      ) entries
    end

  (* B148: persist usage stats to [persist_dir] so they survive a restart,
     mirroring the SqliteRelay stats tables. An append-only [stats-events.jsonl]
     holds one JSON line per event:
       message:  {"t":"m","ts":<float>,"alias":"<from_alias>"}
       activity: {"t":"a","ts":<float>,"node":"<node_id>","alias":"<alias>"}
     A companion [stats-totals.json] ({"messages_ever":N}) is rewritten
     atomically on each increment so the all-time count survives BOTH a restart
     AND event pruning (gc drops message rows past the retention window). gc
     compacts the jsonl to a state snapshot (retained message ts + one line per
     distinct alias/machine) so the file stays bounded without losing the
     distinct 'ever' counts. All writes best-effort — never raise. *)
  let stats_events_jsonl_path persist_dir =
    Filename.concat persist_dir "stats-events.jsonl"

  let stats_totals_json_path persist_dir =
    Filename.concat persist_dir "stats-totals.json"

  let append_stats_event_to_disk persist_dir json =
    let path = stats_events_jsonl_path persist_dir in
    (try
       C2c_io.mkdir_p (Filename.dirname path);
       let oc = open_out_gen [Open_creat; Open_append; Open_wronly] 0o644 path in
       output_string oc (Yojson.Safe.to_string json ^ "\n");
       close_out oc
     with _ -> ())

  let write_stats_totals persist_dir messages_ever =
    let path = stats_totals_json_path persist_dir in
    (try
       C2c_io.mkdir_p (Filename.dirname path);
       let j = `Assoc [ ("messages_ever", `Int messages_ever) ] in
       let tmp = path ^ ".tmp" in
       let oc = open_out tmp in
       output_string oc (Yojson.Safe.to_string j);
       close_out oc;
       Sys.rename tmp path
     with _ -> ())

  (* Replay [stats-events.jsonl] into the seen tables (last write wins on
     last_seen) and return the retained message-event timestamps (those within
     [stats_event_retention_s] of [now], matching the gc prune boundary).
     Malformed lines are skipped, never raised. *)
  let load_stats_events_from_disk persist_dir ~now stats_seen_aliases
      stats_seen_machines =
    let path = stats_events_jsonl_path persist_dir in
    let message_events = ref [] in
    (if Sys.file_exists path then begin
       let ic = open_in path in
       (try
          while true do
            let line = String.trim (input_line ic) in
            if line <> "" then
              (try
                 let j = Yojson.Safe.from_string line in
                 let open Yojson.Safe.Util in
                 let ts =
                   match member "ts" j with
                   | `Float f -> Some f
                   | `Int i -> Some (float_of_int i)
                   | _ -> None
                 in
                 let alias_opt =
                   match member "alias" j with
                   | `String a when a <> "" -> Some a
                   | _ -> None
                 in
                 let node_opt =
                   match member "node" j with
                   | `String n when n <> "" -> Some n
                   | _ -> None
                 in
                 let retire_opt =
                   match member "retire" j with
                   | `String n when n <> "" -> Some n
                   | _ -> None
                 in
                 (match ts with
                  | None -> ()
                  | Some ts ->
                    (match member "t" j with
                     | `String "m" ->
                       if ts >= now -. stats_event_retention_s then
                         message_events := ts :: !message_events;
                       Option.iter
                         (fun a -> Hashtbl.replace stats_seen_aliases a ts)
                         alias_opt
                     | `String "a" ->
                       Option.iter
                         (fun a -> Hashtbl.replace stats_seen_aliases a ts)
                         alias_opt;
                       Option.iter
                         (fun n -> Hashtbl.replace stats_seen_machines n ts)
                         node_opt;
                       (* B174: replay re-key so legacy node_id keys stay dropped. *)
                       Option.iter
                         (fun old ->
                           match node_opt with
                           | Some n when n <> old ->
                             Hashtbl.remove stats_seen_machines old
                           | _ -> ())
                         retire_opt
                     | _ -> ()))
               with _ -> ())
          done
        with End_of_file -> ());
       close_in_noerr ic
     end);
    !message_events

  let load_stats_totals persist_dir =
    match
      (try Some (Yojson.Safe.from_file (stats_totals_json_path persist_dir))
       with _ -> None)
    with
    | Some j ->
      (match Yojson.Safe.Util.member "messages_ever" j with
       | `Int i -> i
       | `Float f -> int_of_float f
       | _ -> 0)
    | None -> 0

  (* gc-time compaction: rewrite the jsonl as a minimal state snapshot (atomic
     tmp+rename). Emits one "m" line per retained message ts (no alias — the
     seen-alias state is captured by the "a" snapshot lines below), plus one
     "a" line per distinct alias and per distinct machine carrying its current
     last_seen. This preserves the exact reload state (message-event count +
     windowed/ever distinct counts) while dropping the unbounded append log. *)
  let rewrite_stats_events_to_disk persist_dir ~message_events ~seen_aliases
      ~seen_machines =
    let path = stats_events_jsonl_path persist_dir in
    (try
       C2c_io.mkdir_p (Filename.dirname path);
       let tmp = path ^ ".tmp" in
       let oc = open_out tmp in
       List.iter
         (fun ts ->
           output_string oc
             (Yojson.Safe.to_string
                (`Assoc [ ("t", `String "m"); ("ts", `Float ts) ])
             ^ "\n"))
         message_events;
       Hashtbl.iter
         (fun alias last ->
           output_string oc
             (Yojson.Safe.to_string
                (`Assoc
                   [ ("t", `String "a"); ("ts", `Float last);
                     ("alias", `String alias) ])
             ^ "\n"))
         seen_aliases;
       Hashtbl.iter
         (fun node last ->
           output_string oc
             (Yojson.Safe.to_string
                (`Assoc
                   [ ("t", `String "a"); ("ts", `Float last);
                     ("node", `String node) ])
             ^ "\n"))
         seen_machines;
       close_out oc;
       Sys.rename tmp path
     with _ -> ())

  let create ?(dedup_window = 10000) ?persist_dir ?(self_host=None) ?(peer_relays=Hashtbl.create 2) () =
    let room_history = Hashtbl.create 16 in
    (* Load persisted room history on startup *)
    Option.iter (fun d -> load_room_history_from_disk d room_history) persist_dir;
    (* B117: reload persisted per-room metadata (visibility + history_public)
       so the policy survives a restart on the persist_dir-backed path. *)
    let room_visibility = Hashtbl.create 16 in
    let room_history_public = Hashtbl.create 16 in
    Option.iter (fun d -> load_room_meta_from_disk d room_visibility room_history_public) persist_dir;

    let identity_path = Option.map (fun d -> Filename.concat d "relay-server-identity.json") persist_dir in
    let identity =
      match identity_path with
      | Some p -> Relay_identity.load_or_create_at ~path:p ~alias_hint:(Option.value self_host ~default:"relay")
      | None -> Relay_identity.generate ~alias_hint:(Option.value self_host ~default:"relay") ()
    in
    (* B148: reload persisted usage stats (message events within retention +
       distinct alias/machine last_seen) and the all-time counter. *)
    let stats_seen_aliases = Hashtbl.create 64 in
    let stats_seen_machines = Hashtbl.create 64 in
    let stats_message_events =
      match persist_dir with
      | Some d ->
        load_stats_events_from_disk d ~now:(Unix.gettimeofday ())
          stats_seen_aliases stats_seen_machines
      | None -> []
    in
    let stats_messages_ever =
      match persist_dir with Some d -> load_stats_totals d | None -> 0
    in
    { mutex = Mutex.create ();
      leases = Hashtbl.create 16;
      bindings = Hashtbl.create 16;
      register_nonces = Hashtbl.create 64;
      request_nonces = Hashtbl.create 256;
      revoke_nonces = Hashtbl.create 64;
      inboxes = Hashtbl.create 16;
      dead_letter = Queue.create ();
      rooms = Hashtbl.create 16;
      room_visibility;
      room_history_public;
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
      stats_message_events;
      stats_messages_ever;
      stats_seen_aliases;
      stats_seen_machines;
      contact_grants = Hashtbl.create 32;
      contact_grant_mids = Hashtbl.create 64;
      contact_generation = Hashtbl.create 16;
      discovery_visibility = Hashtbl.create 64;
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

  (* --- B147: usage stats --- *)

  let stats_note_message t ~from_alias ~ts =
    with_lock t (fun () ->
      t.stats_message_events <- ts :: t.stats_message_events;
      t.stats_messages_ever <- t.stats_messages_ever + 1;
      Hashtbl.replace t.stats_seen_aliases from_alias ts;
      (* B148: append the event + rewrite the all-time counter (both under the
         lock, mirroring append_room_history_to_disk's lock-held write). *)
      Option.iter (fun d ->
        append_stats_event_to_disk d
          (`Assoc [ ("t", `String "m"); ("ts", `Float ts);
                    ("alias", `String from_alias) ]);
        write_stats_totals d t.stats_messages_ever)
        t.persist_dir)

  let stats_note_activity t ~machine_id ?(retire_key = "") ~alias ~ts () =
    with_lock t (fun () ->
      Hashtbl.replace t.stats_seen_machines machine_id ts;
      (* B174: when activity is re-keyed from a legacy per-session node_id to
         the real opaque host id, drop the old key so unique_machines does
         not keep both forever. *)
      if retire_key <> "" && retire_key <> machine_id then
        Hashtbl.remove t.stats_seen_machines retire_key;
      Hashtbl.replace t.stats_seen_aliases alias ts;
      Option.iter (fun d ->
        let fields =
          [ ("t", `String "a"); ("ts", `Float ts);
            ("node", `String machine_id); ("alias", `String alias) ]
          @ (if retire_key <> "" && retire_key <> machine_id then
               [ ("retire", `String retire_key) ]
             else [])
        in
        append_stats_event_to_disk d (`Assoc fields))
        t.persist_dir)

  (* B148: aggregate connected-lease counts. A lease is "currently connected"
     iff NOT [alias_released ~now ~last_seen] (Relay_common predicate). Emits
     aggregate counts only — never aliases, node_ids, or session ids.
     B174: machines are keyed by opaque_host_id when present (else node_id). *)
  let stats_connected t ~now =
    let clients = ref 0 in
    let machines = Hashtbl.create 16 in
    let by_ct = Hashtbl.create 8 in
    let by_version = Hashtbl.create 8 in
    let by_os = Hashtbl.create 8 in
    let bump tbl key =
      let key = if key = "" then "unknown" else key in
      Hashtbl.replace tbl key
        (1 + (match Hashtbl.find_opt tbl key with Some n -> n | None -> 0))
    in
    Hashtbl.iter
      (fun _alias lease ->
        let last_seen = RegistrationLease.last_seen lease in
        if not (alias_released ~now ~last_seen) then begin
          incr clients;
          Hashtbl.replace machines (stats_machine_id_of_lease lease) ();
          bump by_ct (RegistrationLease.client_type lease);
          bump by_version (RegistrationLease.client_version lease);
          bump by_os (RegistrationLease.client_os lease)
        end)
      t.leases;
    let entries tbl = Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl [] in
    stats_connected_json ~clients:!clients
      ~machines:(Hashtbl.length machines) ~by_client_type:(entries by_ct)
      ~by_version:(entries by_version) ~by_os:(entries by_os)

  let stats t ~now =
    with_lock t (fun () ->
      let count_since tbl ~cutoff =
        Hashtbl.fold (fun _ last acc -> if last >= cutoff then acc + 1 else acc) tbl 0
      in
      stats_json ~now
        ~messages_in_window:(fun ~cutoff ->
          List.length (List.filter (fun ts -> ts >= cutoff) t.stats_message_events))
        ~aliases_in_window:(fun ~cutoff -> count_since t.stats_seen_aliases ~cutoff)
        ~machines_in_window:(fun ~cutoff -> count_since t.stats_seen_machines ~cutoff)
        ~messages_ever:t.stats_messages_ever
        ~aliases_ever:(Hashtbl.length t.stats_seen_aliases)
        ~machines_ever:(Hashtbl.length t.stats_seen_machines)
        ~connected:(stats_connected t ~now))

  (* B149: historical snapshot — one jsonl line per call under persist_dir
     ({"ts":..,"stats":..}); no-op without persist_dir. [stats] takes the
     lock itself, so the append happens outside it. Best-effort, never
     raises. *)
  let record_stats_snapshot t ~now =
    match t.persist_dir with
    | None -> ()
    | Some d ->
      let snapshot = stats t ~now in
      (try
         C2c_io.mkdir_p d;
         let path = Filename.concat d "stats-history.jsonl" in
         let oc = open_out_gen [Open_creat; Open_append; Open_wronly] 0o644 path in
         output_string oc
           (Yojson.Safe.to_string
              (`Assoc [ ("ts", `Float now); ("stats", snapshot) ]) ^ "\n");
         close_out oc
       with _ -> ())

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
    Hashtbl.remove t.discovery_visibility alias;
    Hashtbl.iter (fun room_id members ->
      Hashtbl.replace t.rooms room_id (List.filter ((<>) alias) members)
    ) t.rooms

  let register t ~node_id ~session_id ~alias ?(client_type = "unknown") ?(client_version = "") ?(client_os = "") ?(ttl = default_lease_ttl) ?(identity_pk = "") ?(enc_pubkey = "") ?(signed_at = 0.0) ?(sig_b64 = "") ?(opaque_host_id : string option = None) () =
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
             (* B174: never clobber a stored host id with empty on re-register. *)
             let opaque_host_id =
               match opaque_host_id with
               | Some id when id <> "" -> Some id
               | _ ->
                 (match existing with
                  | Some ex -> RegistrationLease.opaque_host_id ex
                  | None -> opaque_host_id)
             in
             let lease = RegistrationLease.make ~node_id ~session_id ~alias ~client_type ~client_version ~client_os ~ttl ~identity_pk:effective_pk ~enc_pubkey ~signed_at ~sig_b64 ~opaque_host_id:opaque_host_id () in
             Hashtbl.replace t.leases alias lease;
             (match binding_state with
              | `BindNew -> Hashtbl.replace t.bindings alias identity_pk
              | _ -> ());
             (* B264/B266: new registrations are always private by default;
                re-register preserves prior visibility. Public exposure is an
                explicit policy mutation, never an environment bypass. *)
             if not (Hashtbl.mem t.discovery_visibility alias) then
               Hashtbl.replace t.discovery_visibility alias Private;
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
               && not (alias_released ~now ~last_seen:(RegistrationLease.last_seen lease))
               && (match Hashtbl.find_opt t.discovery_visibility alias with
                   | Some Public -> true
                   | _ -> false) ->
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

  (* S5a: In-memory observer bindings. B116: keep the machine key and
     provenance sig — revocation authorization compares against the stored
     machine/phone Ed25519 keys, so dropping them would make owner revoke
     impossible on this backend. *)
  let add_observer_binding t ~binding_id ~phone_ed25519_pubkey ~phone_x25519_pubkey ~machine_ed25519_pubkey ~provenance_sig =
    Hashtbl.replace t.observer_bindings_mem binding_id
      (phone_ed25519_pubkey, phone_x25519_pubkey, machine_ed25519_pubkey,
       provenance_sig)

  let get_observer_binding t ~binding_id =
    Hashtbl.find_opt t.observer_bindings_mem binding_id

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

  let check_revoke_nonce t ~nonce ~ts =
    with_lock t (fun () ->
      check_nonce_in t.revoke_nonces ~ttl:request_nonce_ttl ~nonce ~ts)

  let heartbeat t ~node_id ~session_id ?(opaque_host_id = "") =
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
         (* B174: heal host id on heartbeat when client now reports one. *)
         RegistrationLease.set_opaque_host_id lease opaque_host_id;
         ("ok", lease)
    )

  let list_peers_admin t ?(include_dead = false) =
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

  let list_peers t ?(include_dead = false) =
    with_lock t (fun () ->
      let now = Unix.gettimeofday () in
      Hashtbl.fold (fun alias lease acc ->
        let last_seen = RegistrationLease.last_seen lease in
        let vis =
          match Hashtbl.find_opt t.discovery_visibility alias with
          | Some v -> v
          | None -> Private
        in
        if vis = Public
           && not (alias_released ~now ~last_seen)
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

  let send t ~from_alias ~to_alias ~content ?(message_id = None) ?(pow_difficulty = -1) =
    with_lock t (fun () ->
      let msg_id = match message_id with Some id -> id | None -> generate_uuid () in
      let ts = Unix.gettimeofday () in
      (* #686: strip any "@host:port" suffix so bare alias is used for
         the leases hashtbl lookup. The to_alias from the wire may be
         "alias@host:port" (from remote connectors); only the bare alias
         is registered. *)
      let bare_to_alias = bare_alias to_alias in
      let recipient = Hashtbl.find_opt t.leases bare_to_alias in
      let is_public_recip alias =
        match Hashtbl.find_opt t.discovery_visibility alias with
        | Some Public -> true
        | _ -> false
      in
      match recipient with
      | None ->
        let dl = `Assoc [
          ("ts", `Float ts); ("message_id", `String msg_id);
          ("from_alias", `String from_alias); ("to_alias", `String to_alias);
          ("content", `String content); ("reason", `String "unknown_alias");
        ] in
        Queue.add dl t.dead_letter;
        `Error (relay_err_unknown_alias, Printf.sprintf "no registration for alias %S" to_alias)
      | Some _ when not (is_public_recip bare_to_alias) ->
        (* B264: private recipient — uniform unauthorised vs unknown; no content DLQ. *)
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
          let msg = `Assoc (Relay_pow_challenge.with_pow_meta ~difficulty:pow_difficulty [
            ("message_id", `String msg_id); ("from_alias", `String from_alias);
            ("to_alias", `String to_alias); ("content", `String content); ("ts", `Float ts);
          ]) in
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

  (* B117: flush a room's visibility + history_public to disk (no-op without a
     persist_dir). Call after any mutation of either field, under the lock. *)
  let persist_room_meta t room_id =
    match t.persist_dir with
    | None -> ()
    | Some d ->
      let visibility = match Hashtbl.find_opt t.room_visibility room_id with
        | Some v -> canonical_visibility_or_raw v | None -> "public" in
      let history_public = match Hashtbl.find_opt t.room_history_public room_id with
        | Some b -> b | None -> history_public_default_for_visibility visibility in
      write_room_meta d room_id ~visibility ~history_public

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
        if not (Hashtbl.mem t.room_visibility room_id) then begin
          Hashtbl.replace t.room_visibility room_id visibility;
          (* B117: seed the history_public default from the creation
             visibility (public/unlisted → true, gated/private → false). *)
          Hashtbl.replace t.room_history_public room_id
            (history_public_default_for_visibility visibility);
          persist_room_meta t room_id
        end;
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
      Hashtbl.replace t.room_visibility room_id visibility;
      (* B117: gated/private must always be member-only — atomically clear
         history_public on a downgrade. public/unlisted preserve the current
         stored value (never silently re-open a deliberately-closed room). *)
      if visibility = "gated" || visibility = "private" then
        Hashtbl.replace t.room_history_public room_id false;
      persist_room_meta t room_id)

  (* B117: default per visibility when no explicit value has been stored. *)
  let history_public_of t ~room_id =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.room_history_public room_id with
      | Some b -> b
      | None ->
        let visibility = match Hashtbl.find_opt t.room_visibility room_id with
          | Some v -> canonical_visibility_or_raw v | None -> "public" in
        history_public_default_for_visibility visibility)

  let set_room_history_public t ~room_id ~history_public =
    with_lock t (fun () ->
      Hashtbl.replace t.room_history_public room_id history_public;
      persist_room_meta t room_id)

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

  let list_rooms ?for_alias t =
    with_lock t (fun () ->
      Hashtbl.fold (fun room_id members acc ->
        (* Directory policy (B230 + B229):
           - public / gated: always listed (anonymous directory).
           - unlisted: listed only when [for_alias] is a current member (B230).
           - private: never listed on this surface (reachable by id only).
           - gated roster redacted on this directory surface (B229).
           Absent visibility (legacy in-memory rooms) defaults to public. *)
        let visibility =
          match Hashtbl.find_opt t.room_visibility room_id with
          | Some v -> canonical_visibility_or_raw v
          | None -> "public"
        in
        let include_room =
          match visibility with
          | "public" | "gated" -> true
          | "unlisted" ->
              (match for_alias with
               | Some a ->
                   let a_cf = String.lowercase_ascii a in
                   List.exists
                     (fun m -> String.lowercase_ascii m = a_cf)
                     members
               | None -> false)
          | _ -> false
        in
        (* B118: defensive directory-boundary guard. handle_join_room rejects
           out-of-grammar room ids, but a backend-direct caller or a legacy
           persisted row could still carry a room id containing `#`/`@`, which
           would make its alias#room@relay directory address ambiguous. Omit
           such rooms from the directory entirely — better unlisted than
           emitting an address the recipient parser cannot round-trip. *)
        if not include_room then acc
        else if not (valid_relay_room_id room_id) then acc
        else
          (* B229/B230: optional verified identity expands the directory with
             unlisted rooms that identity is a member of. Public (and
             member-visible unlisted) rows expose presentation rosters; gated
             rows stay discoverable (room_id + member_count) but members is
             always [] on this surface (directory privacy — not local-broker
             member-full-roster parity). Stored membership stays raw. *)
          let members_json =
            if visibility = "gated" then `List []
            else
              `List
                (List.map
                   (fun a ->
                     `String (format_room_roster_address ~alias:a ~room_id))
                   members)
          in
          `Assoc [
            ("room_id", `String room_id);
            ("member_count", `Int (List.length members));
            ("members", members_json);
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
        else begin
          (* B264/G2: private recipients are invisible to broadcast — omit from
             both delivered and skipped so skipped cannot enumerate private aliases. *)
          let is_public =
            match Hashtbl.find_opt t.discovery_visibility alias with
            | Some Public -> true
            | _ -> false
          in
          if not is_public then ()
          else if not (RegistrationLease.is_alive lease) then
            skipped := alias :: !skipped
          else begin
            delivered_to := alias :: !delivered_to;
            let key = inbox_key (RegistrationLease.node_id lease) (RegistrationLease.session_id lease) in
            let msg = `Assoc [
              ("message_id", `String msg_id); ("from_alias", `String from_alias);
              ("to_alias", `String alias); ("content", `String content); ("ts", `Float ts);
            ] in
            let inbox = get_inbox t key in set_inbox t key (msg :: inbox)
          end
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
      (* B147: drop message-event timestamps past the largest stats window;
         stats_messages_ever keeps the all-time count. *)
      t.stats_message_events <-
        List.filter (fun ts -> ts >= now -. stats_event_retention_s)
          t.stats_message_events;
      (* B148: compact the persisted jsonl to a bounded state snapshot so it
         doesn't grow unboundedly (gc already holds the lock). *)
      Option.iter (fun d ->
        rewrite_stats_events_to_disk d
          ~message_events:t.stats_message_events
          ~seen_aliases:t.stats_seen_aliases
          ~seen_machines:t.stats_seen_machines)
        t.persist_dir;
      (* B262/B266: GC expired/revoked contact grants past the replay window. *)
      let drop_verifiers = ref [] in
      Hashtbl.iter
        (fun verifier g ->
          let end_ts =
            match g.revoked_at with
            | Some r -> max g.expires_at r
            | None -> g.expires_at
          in
          if now >= end_ts +. contact_grant_gc_grace_s then
            drop_verifiers := verifier :: !drop_verifiers)
        t.contact_grants;
      List.iter
        (fun verifier ->
          Hashtbl.remove t.contact_grants verifier;
          Hashtbl.filter_map_inplace
            (fun (v, _mid) ts -> if v = verifier then None else Some ts)
            t.contact_grant_mids)
        !drop_verifiers;
      `Ok (List.rev !expired, pruned)
    )

  (* B262/B263: contact grants — in-memory lifecycle. *)
  let issue_contact_grant t ~recipient_identity_pk ~delivery_alias
      ~sender_identity_pk ~expires_at ?label ?now () =
    with_lock t (fun () ->
      let now = match now with Some n -> n | None -> Unix.gettimeofday () in
      if String.length recipient_identity_pk = 0
         || String.length sender_identity_pk = 0
         || delivery_alias = "" then
        Result.Error "contact_grant_invalid_args"
      else if expires_at <= now then
        Result.Error "contact_grant_expires_in_past"
      else
        (* Owner binding: delivery_alias must be registered to recipient_identity_pk. *)
        match Hashtbl.find_opt t.leases delivery_alias with
        | None -> Result.Error "contact_grant_unknown_delivery_alias"
        | Some lease when RegistrationLease.identity_pk lease = ""
                          || RegistrationLease.identity_pk lease
                             <> recipient_identity_pk ->
          Result.Error "contact_grant_not_owner"
        | Some _ -> begin
        let recipient_fp = contact_fp_of_pk recipient_identity_pk in
        let sender_fp = contact_fp_of_pk sender_identity_pk in
        let prev_gen =
          match Hashtbl.find_opt t.contact_generation recipient_fp with
          | Some g -> g | None -> 0
        in
        let generation = prev_gen + 1 in
        Hashtbl.replace t.contact_generation recipient_fp generation;
        let grant_secret = contact_random_secret () in
        let verifier = contact_sha256_raw grant_secret in
        let rec_ =
          {
            verifier;
            recipient_identity_fp = recipient_fp;
            delivery_alias;
            sender_fp;
            scope = contact_scope_v1;
            generation;
            created_at = now;
            expires_at;
            revoked_at = None;
            label;
          }
        in
        Hashtbl.replace t.contact_grants verifier rec_;
        Result.Ok
          {
            grant_secret;
            grant_id = contact_grant_id_of_verifier verifier;
            expires_at;
            generation;
          }
        end)

  let list_contact_grants t ~recipient_identity_pk =
    with_lock t (fun () ->
      let recipient_fp = contact_fp_of_pk recipient_identity_pk in
      Hashtbl.fold
        (fun _ g acc ->
          if g.recipient_identity_fp = recipient_fp then
            contact_meta_of_rec g :: acc
          else acc)
        t.contact_grants [])

  let revoke_contact_grant t ~recipient_identity_pk ~grant_id ?now () =
    with_lock t (fun () ->
      let now = match now with Some n -> n | None -> Unix.gettimeofday () in
      match contact_decode_grant_id grant_id with
      | None -> Result.Error "contact_grant_not_found"
      | Some verifier ->
        (match Hashtbl.find_opt t.contact_grants verifier with
         | None -> Result.Error "contact_grant_not_found"
         | Some g ->
           let recipient_fp = contact_fp_of_pk recipient_identity_pk in
           if g.recipient_identity_fp <> recipient_fp then
             Result.Error "contact_grant_not_owner"
           else begin
             (match g.revoked_at with
              | None -> g.revoked_at <- Some now
              | Some _ -> ());
             Result.Ok ()
           end))

  let rotate_contact_grant t ~recipient_identity_pk ~grant_id
      ~sender_identity_pk ~expires_at ?label ?now () =
    with_lock t (fun () ->
      let now = match now with Some n -> n | None -> Unix.gettimeofday () in
      match contact_decode_grant_id grant_id with
      | None -> Result.Error "contact_grant_not_found"
      | Some old_verifier ->
        (match Hashtbl.find_opt t.contact_grants old_verifier with
         | None -> Result.Error "contact_grant_not_found"
         | Some old ->
           let recipient_fp = contact_fp_of_pk recipient_identity_pk in
           if old.recipient_identity_fp <> recipient_fp then
             Result.Error "contact_grant_not_owner"
           else if String.length sender_identity_pk = 0 then
             Result.Error "contact_grant_invalid_args"
           else if expires_at <= now then
             Result.Error "contact_grant_expires_in_past"
           else begin
             (match old.revoked_at with
              | None -> old.revoked_at <- Some now
              | Some _ -> ());
             let prev_gen =
               match Hashtbl.find_opt t.contact_generation recipient_fp with
               | Some g -> g | None -> old.generation
             in
             let generation = prev_gen + 1 in
             Hashtbl.replace t.contact_generation recipient_fp generation;
             let grant_secret = contact_random_secret () in
             let verifier = contact_sha256_raw grant_secret in
             let delivery_alias = old.delivery_alias in
             let label =
               match label with Some l -> Some l | None -> old.label
             in
             let rec_ =
               {
                 verifier;
                 recipient_identity_fp = recipient_fp;
                 delivery_alias;
                 sender_fp = contact_fp_of_pk sender_identity_pk;
                 scope = contact_scope_v1;
                 generation;
                 created_at = now;
                 expires_at;
                 revoked_at = None;
                 label;
               }
             in
             Hashtbl.replace t.contact_grants verifier rec_;
             Result.Ok
               {
                 grant_secret;
                 grant_id = contact_grant_id_of_verifier verifier;
                 expires_at;
                 generation;
               }
           end))

  let admit_contact_delivery t ~verified_sender_alias
      ~verified_sender_identity_pk ~grant_secret ~message_id ~content
      ?now () =
    with_lock t (fun () ->
      let now = match now with Some n -> n | None -> Unix.gettimeofday () in
      if String.length grant_secret <> 32 || message_id = "" then `Rejected
      else
        let verifier = contact_sha256_raw grant_secret in
        match Hashtbl.find_opt t.contact_grants verifier with
        | None -> `Rejected
        | Some g ->
          (match g.revoked_at with
           | Some _ -> `Rejected
           | None when now >= g.expires_at -> `Rejected
           | None when g.scope <> contact_scope_v1 -> `Rejected
           | None ->
             let sender_fp = contact_fp_of_pk verified_sender_identity_pk in
             if sender_fp <> g.sender_fp then `Rejected
             else
               match Hashtbl.find_opt t.contact_grant_mids (verifier, message_id) with
               | Some ts -> `Duplicate (ts, g.delivery_alias)
               | None ->
                 (match Hashtbl.find_opt t.leases g.delivery_alias with
                  | None -> `Rejected
                  | Some lease
                    when alias_released ~now
                           ~last_seen:(RegistrationLease.last_seen lease)
                         || not (RegistrationLease.is_alive lease) ->
                    `Rejected
                  | Some lease ->
                    let lease_pk = RegistrationLease.identity_pk lease in
                    if lease_pk = ""
                       || contact_fp_of_pk lease_pk <> g.recipient_identity_fp
                    then `Rejected
                    else begin
                      (* optional defence-in-depth: live sender alias matches key *)
                      (match Hashtbl.find_opt t.leases verified_sender_alias with
                       | Some slease
                         when RegistrationLease.is_alive slease
                              && not
                                   (alias_released ~now
                                      ~last_seen:
                                        (RegistrationLease.last_seen slease))
                              && RegistrationLease.identity_pk slease
                                 = verified_sender_identity_pk ->
                         ()
                       | _ -> ());
                      let key =
                        inbox_key (RegistrationLease.node_id lease)
                          (RegistrationLease.session_id lease)
                      in
                      let msg =
                        `Assoc
                          [
                            ("message_id", `String message_id);
                            ("from_alias", `String verified_sender_alias);
                            ("to_alias", `String g.delivery_alias);
                            ("content", `String content);
                            ("ts", `Float now);
                          ]
                      in
                      let inbox = get_inbox t key in
                      set_inbox t key (msg :: inbox);
                      Hashtbl.replace t.contact_grant_mids
                        (verifier, message_id) now;
                      `Accepted (now, g.delivery_alias)
                    end)))

  let peer_discovery_visibility_of t ~alias =
    let alias, _ = normalize_relay_alias ~alias ~opaque_host_id:None in
    with_lock t (fun () ->
      match Hashtbl.find_opt t.leases alias with
      | None -> None
      | Some _ ->
        Some
          (match Hashtbl.find_opt t.discovery_visibility alias with
           | Some v -> v
           | None -> Private))

  let set_peer_discovery_visibility t ~alias ~visibility =
    let alias, _ = normalize_relay_alias ~alias ~opaque_host_id:None in
    with_lock t (fun () ->
      if Hashtbl.mem t.leases alias then begin
        Hashtbl.replace t.discovery_visibility alias visibility;
        Result.Ok ()
      end else Result.Error "unknown_alias")

  let is_public_unlocked t ~alias =
    match Hashtbl.find_opt t.discovery_visibility alias with
    | Some Public -> true
    | _ -> false

  let peer_identity_pk_of t ~alias =
    let alias, _ = normalize_relay_alias ~alias ~opaque_host_id:None in
    with_lock t (fun () ->
      if not (is_public_unlocked t ~alias) then None
      else
        let now = Unix.gettimeofday () in
        match Hashtbl.find_opt t.leases alias, Hashtbl.find_opt t.bindings alias with
        | Some lease, Some pk
          when not (alias_released ~now ~last_seen:(RegistrationLease.last_seen lease)) ->
          Some pk
        | _ -> None)

  let peer_enc_pubkey_of t ~alias =
    with_lock t (fun () ->
      if not (is_public_unlocked t ~alias) then None
      else
        let now = Unix.gettimeofday () in
        match Hashtbl.find_opt t.leases alias with
        | Some lease when not (alias_released ~now ~last_seen:(RegistrationLease.last_seen lease)) ->
          let ek = RegistrationLease.enc_pubkey lease in
          if ek = "" then None else Some ek
        | _ -> None)

  let peer_signed_at_of t ~alias =
    with_lock t (fun () ->
      if not (is_public_unlocked t ~alias) then None
      else
        let now = Unix.gettimeofday () in
        match Hashtbl.find_opt t.leases alias with
        | Some lease when not (alias_released ~now ~last_seen:(RegistrationLease.last_seen lease)) ->
          let sa = RegistrationLease.signed_at lease in
          if sa = 0.0 then None else Some sa
        | _ -> None)

  let peer_sig_b64_of t ~alias =
    with_lock t (fun () ->
      if not (is_public_unlocked t ~alias) then None
      else
        let now = Unix.gettimeofday () in
        match Hashtbl.find_opt t.leases alias with
        | Some lease when not (alias_released ~now ~last_seen:(RegistrationLease.last_seen lease)) ->
          let sb = RegistrationLease.sig_b64 lease in
          if sb = "" then None else Some sb
        | _ -> None)

  let private_reachability_mode _t = "process_local"

end

(* --- SqliteRelay --- *)

module SqliteRelay : RELAY = struct
  type t = {
    db_path : string;
    (* B219 (GH #79): ONE long-lived connection, opened once in [create] and
       reused under [with_lock] for every DB op. Replaces the previous
       per-op [t.db] (~50 sites) that was never closed
       and whose statements were never finalized — under load the GC
       finalizer backlog produced a use-after-free SIGSEGV inside
       sqlite3_finalize. Every access to [db] MUST hold [mutex]; see the
       "public locks / inner worker is lock-free" split below. [db_path] is
       kept because tests/migrations still reference the file directly. *)
    db : Sqlite3.db;
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
    let found = ref false in
    let info_stmt = Sqlite3.prepare conn (Printf.sprintf "PRAGMA table_info(%s)" table) in
    Fun.protect
      ~finally:(fun () -> (try ignore (Sqlite3.finalize info_stmt) with _ -> ()))
      (fun () ->
        let rec loop () =
          let rc = Sqlite3.step info_stmt in
          if rc = Sqlite3.Rc.ROW then begin
            let col_name = Sqlite3.Data.to_string_exn (Sqlite3.column info_stmt 1) in
            if col_name = column then found := true;
            loop ()
          end
        in
        (try loop () with _ -> ());
        !found)

  let sqlite_object_type conn ~name =
    let stmt =
      Sqlite3.prepare conn
        "SELECT type FROM sqlite_master WHERE name = ? LIMIT 1"
    in
    Fun.protect
      ~finally:(fun () -> try ignore (Sqlite3.finalize stmt) with _ -> ())
      (fun () ->
        Sqlite3.bind_text stmt 1 name |> ignore;
        if Sqlite3.step stmt = Sqlite3.Rc.ROW then
          Some (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0))
        else None)

  let checked_exec conn ~context sql =
    let rc = Sqlite3.exec conn sql in
    if not (Sqlite3.Rc.is_success rc) then
      failwith (context ^ ": " ^ Sqlite3.Rc.to_string rc)

  let sqlite_object_sql conn ~name =
    let stmt =
      Sqlite3.prepare conn
        "SELECT sql FROM sqlite_master WHERE name = ? LIMIT 1"
    in
    Fun.protect
      ~finally:(fun () -> try ignore (Sqlite3.finalize stmt) with _ -> ())
      (fun () ->
        Sqlite3.bind_text stmt 1 name |> ignore;
        if Sqlite3.step stmt = Sqlite3.Rc.ROW then
          match Sqlite3.column stmt 0 with
          | Sqlite3.Data.NULL -> None
          | value -> Some (Sqlite3.Data.to_string_exn value)
        else None)

  let sqlite_trigger_count conn ~table_name =
    let stmt =
      Sqlite3.prepare conn
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?"
    in
    Fun.protect
      ~finally:(fun () -> try ignore (Sqlite3.finalize stmt) with _ -> ())
      (fun () ->
        Sqlite3.bind_text stmt 1 table_name |> ignore;
        if Sqlite3.step stmt <> Sqlite3.Rc.ROW then
          failwith "B266 trigger count failed";
        match Sqlite3.Data.to_int (Sqlite3.column stmt 0) with
        | Some count -> count
        | None -> failwith "B266 trigger count was not integer")

  let secure_leases_table = "secure_leases_v2"
  let legacy_refusal_view_sql =
    "CREATE VIEW leases AS
       SELECT alias, node_id, session_id, client_type, registered_at,
              last_seen, ttl, identity_pk, enc_pubkey, signed_at, sig_b64,
              opaque_host_id, client_version, client_os,
              discovery_visibility
         FROM secure_leases_v2 WHERE 0"

  let normalize_sql sql =
    sql |> String.lowercase_ascii
    |> String.to_seq
    |> Seq.filter (fun c -> c <> ' ' && c <> '\n' && c <> '\r' && c <> '\t')
    |> String.of_seq

  let require_legacy_refusal_view conn =
    match sqlite_object_type conn ~name:"leases" with
    | Some "view" ->
      let actual = sqlite_object_sql conn ~name:"leases" |> Option.value ~default:"" in
      if normalize_sql actual <> normalize_sql legacy_refusal_view_sql then
        failwith "B266 legacy leases view does not match refusal definition";
      if sqlite_trigger_count conn ~table_name:"leases" <> 0 then
        failwith "B266 legacy leases view has write-capable triggers"
    | Some kind ->
      failwith ("B266 secure table coexists with legacy " ^ kind)
    | None -> failwith "B266 secure table missing legacy refusal view"

  let create ?(dedup_window=10000) ?(persist_dir="") ?(self_host=None) ?(peer_relays=Hashtbl.create 2) () =
    let db_path = Filename.concat persist_dir "c2c_relay.db" in
    let mutex = Mutex.create () in
    let conn = Sqlite3.db_open db_path in
    (let rc = Sqlite3.exec conn "PRAGMA busy_timeout = 5000" in
     if not (Sqlite3.Rc.is_success rc) then
       failwith ("sqlite busy_timeout pragma failed: " ^ Sqlite3.Rc.to_string rc));
    let rec set_wal attempts =
      let rc = Sqlite3.exec conn "PRAGMA journal_mode = WAL" in
      if Sqlite3.Rc.is_success rc then ()
      else if attempts > 0 && (rc = Sqlite3.Rc.BUSY || rc = Sqlite3.Rc.LOCKED)
      then begin Unix.sleepf 0.01; set_wal (attempts - 1) end
      else failwith ("sqlite WAL pragma failed: " ^ Sqlite3.Rc.to_string rc)
    in
    set_wal 500;
    (let rc = Sqlite3.exec conn sqlite_ddl in
     if not (Sqlite3.Rc.is_success rc) then
       failwith ("sqlite_ddl failed (B266 security-critical): " ^ Sqlite3.Rc.to_string rc));
    (* B266 rollback floor. Serialize detection, column migration, rename and
       compatibility-view creation under one IMMEDIATE transaction. A second
       new binary waits, then rechecks the committed object shape. Current
       binaries use [secure_leases_v2]. Pre-B266 binaries see no recipients and
       cannot INSERT/UPDATE the [leases] view. *)
    checked_exec conn ~context:"B266 begin lease quarantine" "BEGIN IMMEDIATE";
    (try
       let lease_table =
         match sqlite_object_type conn ~name:secure_leases_table with
         | Some "table" -> secure_leases_table
         | Some kind ->
           failwith ("B266 secure lease object has unexpected type: " ^ kind)
         | None ->
           (match sqlite_object_type conn ~name:"leases" with
            | Some "table" -> "leases"
            | Some "view" ->
              failwith "B266 legacy view exists without secure lease table"
            | Some kind ->
              failwith ("B266 legacy lease object has unexpected type: " ^ kind)
            | None -> failwith "B266 lease table missing after schema setup")
       in
       let add_column_if_missing column ddl =
         if not (sqlite_table_has_column conn ~table:lease_table ~column) then
           checked_exec conn ~context:("B266 add lease column " ^ column)
             (Printf.sprintf "ALTER TABLE %s ADD COLUMN %s" lease_table ddl)
       in
       add_column_if_missing "opaque_host_id"
         "opaque_host_id TEXT NOT NULL DEFAULT ''";
       add_column_if_missing "client_version"
         "client_version TEXT NOT NULL DEFAULT ''";
       add_column_if_missing "client_os"
         "client_os TEXT NOT NULL DEFAULT ''";
       add_column_if_missing "discovery_visibility"
         "discovery_visibility TEXT NOT NULL DEFAULT 'private'";
       if lease_table = "leases" then begin
         checked_exec conn ~context:"B266 rename secure leases"
           "ALTER TABLE leases RENAME TO secure_leases_v2";
         (match Sys.getenv_opt "C2C_RELAY_MIGRATION_FAULT_FIXTURE" with
          | Some "after-lease-rename" ->
            failwith "B266 fixture: fail after lease rename"
          | Some _ | None -> ());
         checked_exec conn ~context:"B266 create legacy refusal view"
           legacy_refusal_view_sql
       end;
       require_legacy_refusal_view conn;
       checked_exec conn ~context:"B266 commit lease quarantine" "COMMIT"
     with exn ->
       ignore (Sqlite3.exec conn "ROLLBACK");
       raise exn);
    (* B266: feature marker table (idempotent). *)
    (let rc =
       Sqlite3.exec conn
         "CREATE TABLE IF NOT EXISTS relay_features (
            feature TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            set_at REAL NOT NULL)"
     in
     if not (Sqlite3.Rc.is_success rc) then
       failwith
         ("B266 migration failed: create relay_features: " ^ Sqlite3.Rc.to_string rc));
    (* Require contact grant tables for consent-gated mode. *)
    let table_exists name =
      let st =
        Sqlite3.prepare conn
          "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?"
      in
      Fun.protect
        ~finally:(fun () -> ignore (Sqlite3.finalize st))
        (fun () ->
          Sqlite3.bind_text st 1 name |> ignore;
          Sqlite3.step st = Sqlite3.Rc.ROW)
    in
    List.iter
      (fun name ->
        if not (table_exists name) then
          failwith
            (Printf.sprintf
               "B266: %s table missing after DDL — refuse insecure open" name))
      [ "contact_grants"; "contact_grant_message_ids"; "relay_features" ];
    (* Upsert durable feature markers (idempotent). *)
    let marker_now = Unix.gettimeofday () in
    List.iter
      (fun (feature, value) ->
        let st =
          Sqlite3.prepare conn
            "INSERT INTO relay_features (feature, value, set_at) VALUES (?, ?, ?)
             ON CONFLICT(feature) DO UPDATE SET value=excluded.value, set_at=excluded.set_at"
        in
        Fun.protect
          ~finally:(fun () -> ignore (Sqlite3.finalize st))
          (fun () ->
            Sqlite3.bind_text st 1 feature |> ignore;
            Sqlite3.bind_text st 2 value |> ignore;
            Sqlite3.bind_double st 3 marker_now |> ignore;
            let rc = Sqlite3.step st in
            if rc <> Sqlite3.Rc.DONE then
              failwith
                ("B266 feature marker upsert failed: " ^ Sqlite3.Rc.to_string rc)))
      [ ("private_reachability", "consent_gated");
        ("contact_protocol", "1");
        ("minimum_reader_generation", "2");
      ];
    if not (sqlite_table_has_column conn ~table:"rooms" ~column:"visibility") then
      Sqlite3.exec conn "ALTER TABLE rooms ADD COLUMN visibility TEXT NOT NULL DEFAULT 'public'" |> ignore;
    (* B117: migrate older databases to the history_public column. Add it with
       DEFAULT 1 so pre-existing public/unlisted rooms keep their prior
       open-read behaviour, then force 0 for pre-existing gated/private rooms
       (which were already member-only) so the invariant holds after upgrade.
       Idempotent on fresh installs (the column is already in sqlite_ddl). *)
    if not (sqlite_table_has_column conn ~table:"rooms" ~column:"history_public") then begin
      Sqlite3.exec conn "ALTER TABLE rooms ADD COLUMN history_public INTEGER NOT NULL DEFAULT 1" |> ignore;
      Sqlite3.exec conn "UPDATE rooms SET history_public = 0 WHERE visibility IN ('gated','private')" |> ignore
    end;
    (* B014: migrate older databases to the inboxes.pow_difficulty column. Add
       it with DEFAULT -1 (= not recorded) so pre-existing queued messages emit
       no [pow] object on delivery. Idempotent on fresh installs (declared in
       sqlite_ddl). *)
    if not (sqlite_table_has_column conn ~table:"inboxes" ~column:"pow_difficulty") then
      Sqlite3.exec conn "ALTER TABLE inboxes ADD COLUMN pow_difficulty INTEGER NOT NULL DEFAULT -1" |> ignore;
    (* B266: durable feature/migration stamp. schema_version.version = 2 marks
       private-reachability schema (discovery_visibility + contact grants).
       Checked insert; old binaries that ignore grants must refuse or be blocked
       operationally (floor is the presence of this stamp + private default). *)
    (let rc =
       Sqlite3.exec conn
         "INSERT INTO schema_version (version) VALUES (2)           ON CONFLICT(version) DO NOTHING"
     in
     if not (Sqlite3.Rc.is_success rc) then
       failwith ("schema_version stamp failed: " ^ Sqlite3.Rc.to_string rc));
    (let has = ref false in
     let stmt = Sqlite3.prepare conn "SELECT version FROM schema_version WHERE version = 2" in
     Fun.protect
       ~finally:(fun () -> try ignore (Sqlite3.finalize stmt) with _ -> ())
       (fun () ->
         if Sqlite3.step stmt = Sqlite3.Rc.ROW then has := true);
     if not !has then
       failwith "schema_version stamp missing after insert (B266 fail-closed)");
    (* #330 S2: load or generate this relay's Ed25519 identity for cross-relay signing *)
    let identity_path = if persist_dir = "" then None else Some (Filename.concat persist_dir "relay-server-identity.json") in
    let identity =
      match identity_path with
      | Some p -> Relay_identity.load_or_create_at ~path:p ~alias_hint:(Option.value self_host ~default:"relay")
      | None -> Relay_identity.generate ~alias_hint:(Option.value self_host ~default:"relay") ()
    in
    { db_path; db = conn; dedup_window; mutex; observer_bindings = ObserverBindings.create (); self_host; peer_relays; identity }

  let with_lock t f =
    Mutex.lock t.mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

  (* B219: prepare/finalize a statement around [f]. With the persistent
     connection an unfinalized statement leaks for the process lifetime and
     can hold locks / block WAL checkpoints, so EVERY ad-hoc prepare is routed
     through this helper. The finalize runs in [~finally] so it fires even if
     [f] raises. The caller MUST already hold [t.mutex] (the connection is
     shared) — [with_stmt] does not lock. *)
  let with_stmt conn sql f =
    let stmt = Sqlite3.prepare conn sql in
    Fun.protect
      ~finally:(fun () -> (try ignore (Sqlite3.finalize stmt) with _ -> ()))
      (fun () -> f stmt)

  (* B219: best-effort lifecycle close. No shutdown path calls this today;
     the persistent connection is process-lifetime owned. Keep this locked
     hook for a future explicit teardown path. Never raises. *)
  let close t =
    with_lock t (fun () ->
      try ignore (Sqlite3.db_close t.db) with _ -> ())
  let _ = close

  let self_host t = t.self_host
  (* #330 S2: relay identity for cross-relay signing *)
  let relay_identity t = t.identity

  (* #330 S1: peer_relay accessors *)
  let add_peer_relay t pr = Hashtbl.replace t.peer_relays pr.name pr
  let peer_relay_of t ~name = Hashtbl.find_opt t.peer_relays name
  let peer_relays_list t = Hashtbl.fold (fun _ v acc -> v :: acc) t.peer_relays []

  (* --- B147: usage stats --- *)

  (* Single-row COUNT/COALESCE queries; 0 on any miss. *)
  let count_query conn sql params =
    with_stmt conn sql (fun stmt ->
      List.iteri (fun idx param ->
        let idx' = idx + 1 in
        (match param with
         | `Text s -> Sqlite3.bind_text stmt idx' s |> ignore
         | `Float f -> Sqlite3.bind_double stmt idx' f |> ignore)
      ) params;
      if Sqlite3.step stmt = Rc.ROW then
        match Sqlite3.Data.to_int (Sqlite3.column stmt 0) with
        | Some i -> i
        | None -> 0
      else 0)

  let stats_note_message t ~from_alias ~ts =
    with_lock t (fun () ->
      let conn = t.db in
      exec_prepared conn "INSERT INTO stats_message_events (ts) VALUES (?)"
        [`Float ts] |> ignore;
      exec_prepared conn
        "INSERT INTO stats_totals (key, value) VALUES ('messages_ever', 1) \
         ON CONFLICT(key) DO UPDATE SET value = value + 1" [] |> ignore;
      exec_prepared conn
        "INSERT INTO stats_seen_aliases (alias, last_seen) VALUES (?, ?) \
         ON CONFLICT(alias) DO UPDATE SET last_seen = excluded.last_seen"
        [`Text from_alias; `Float ts] |> ignore)

  let stats_note_activity t ~machine_id ?(retire_key = "") ~alias ~ts () =
    with_lock t (fun () ->
      let conn = t.db in
      exec_prepared conn
        "INSERT INTO stats_seen_machines (machine_id, last_seen) VALUES (?, ?) \
         ON CONFLICT(machine_id) DO UPDATE SET last_seen = excluded.last_seen"
        [`Text machine_id; `Float ts] |> ignore;
      (* B174: drop a legacy per-session node_id key once re-keyed to host id. *)
      if retire_key <> "" && retire_key <> machine_id then
        exec_prepared conn
          "DELETE FROM stats_seen_machines WHERE machine_id = ?"
          [`Text retire_key]
        |> ignore;
      exec_prepared conn
        "INSERT INTO stats_seen_aliases (alias, last_seen) VALUES (?, ?) \
         ON CONFLICT(alias) DO UPDATE SET last_seen = excluded.last_seen"
        [`Text alias; `Float ts] |> ignore)

  (* B148: aggregate connected-lease counts from the secure_leases_v2 table. Filters
     with the SAME [alias_released] predicate as the memory backend (applied in
     OCaml, not SQL) so the two backends can't disagree on liveness. Emits
     aggregate counts only — never aliases, node_ids, or session ids.
     B174: machines are keyed by opaque_host_id when present (else node_id). *)
  let stats_connected conn ~now =
    let clients = ref 0 in
    let machines = Hashtbl.create 16 in
    let by_ct = Hashtbl.create 8 in
    let by_version = Hashtbl.create 8 in
    let by_os = Hashtbl.create 8 in
    let bump tbl key =
      let key = if key = "" then "unknown" else key in
      Hashtbl.replace tbl key
        (1 + (match Hashtbl.find_opt tbl key with Some n -> n | None -> 0))
    in
    with_stmt conn
      "SELECT node_id, client_type, last_seen, client_version, client_os, \
       opaque_host_id FROM secure_leases_v2" (fun stmt ->
      let col_string col = match Sqlite3.Data.to_string col with Some s -> s | None -> "" in
      let col_float col =
        match Sqlite3.Data.to_float col with
        | Some f -> f
        | None -> (try float_of_string (Sqlite3.Data.to_string_exn col) with _ -> 0.0)
      in
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then begin
          let node_id = col_string (Sqlite3.column stmt 0) in
          let client_type = col_string (Sqlite3.column stmt 1) in
          let last_seen = col_float (Sqlite3.column stmt 2) in
          let client_version = col_string (Sqlite3.column stmt 3) in
          let client_os = col_string (Sqlite3.column stmt 4) in
          let opaque_host_id = col_string (Sqlite3.column stmt 5) in
          if not (alias_released ~now ~last_seen) then begin
            incr clients;
            let machine_id =
              stats_machine_id ~node_id
                ~opaque_host_id:
                  (if opaque_host_id = "" then None else Some opaque_host_id)
            in
            Hashtbl.replace machines machine_id ();
            bump by_ct client_type;
            bump by_version client_version;
            bump by_os client_os
          end;
          loop ()
        end
      in
      try loop () with _ -> ());
    let entries tbl = Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl [] in
    stats_connected_json ~clients:!clients
      ~machines:(Hashtbl.length machines) ~by_client_type:(entries by_ct)
      ~by_version:(entries by_version) ~by_os:(entries by_os)

  let stats t ~now =
    with_lock t (fun () ->
      let conn = t.db in
      stats_json ~now
        ~messages_in_window:(fun ~cutoff ->
          count_query conn
            "SELECT COUNT(*) FROM stats_message_events WHERE ts >= ?"
            [`Float cutoff])
        ~aliases_in_window:(fun ~cutoff ->
          count_query conn
            "SELECT COUNT(*) FROM stats_seen_aliases WHERE last_seen >= ?"
            [`Float cutoff])
        ~machines_in_window:(fun ~cutoff ->
          count_query conn
            "SELECT COUNT(*) FROM stats_seen_machines WHERE last_seen >= ?"
            [`Float cutoff])
        ~messages_ever:
          (count_query conn
             "SELECT COALESCE((SELECT value FROM stats_totals \
              WHERE key = 'messages_ever'), 0)" [])
        ~aliases_ever:
          (count_query conn "SELECT COUNT(*) FROM stats_seen_aliases" [])
        ~machines_ever:
          (count_query conn "SELECT COUNT(*) FROM stats_seen_machines" [])
        ~connected:(stats_connected conn ~now))

  (* B149: historical snapshot — one stats_snapshots row per call. [stats]
     releases its lock before this separate locked INSERT on the shared
     connection. Best-effort, never raises. *)
  let record_stats_snapshot t ~now =
    let snapshot = stats t ~now in
    with_lock t (fun () ->
      try
        let conn = t.db in
        exec_prepared conn "INSERT INTO stats_snapshots (ts, json) VALUES (?, ?)"
          [`Float now; `Text (Yojson.Safe.to_string snapshot)]
        |> ignore
      with _ -> ())

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

  (* B219: inner worker — lock-free, called under the lock (register/gc). *)
  let release_alias conn alias =
    with_stmt conn "SELECT node_id, session_id FROM secure_leases_v2 WHERE alias = ?" (fun old_key_stmt ->
      Sqlite3.bind_text old_key_stmt 1 alias |> ignore;
      (match Sqlite3.step old_key_stmt with
       | Rc.ROW ->
         let node_id = Sqlite3.Data.to_string_exn (Sqlite3.column old_key_stmt 0) in
         let session_id = Sqlite3.Data.to_string_exn (Sqlite3.column old_key_stmt 1) in
         with_stmt conn "DELETE FROM inboxes WHERE node_id = ? AND session_id = ?" (fun del_inbox ->
           Sqlite3.bind_text del_inbox 1 node_id |> ignore;
           Sqlite3.bind_text del_inbox 2 session_id |> ignore;
           Sqlite3.step del_inbox |> ignore)
       | _ -> ()));
    with_stmt conn "DELETE FROM secure_leases_v2 WHERE alias = ?" (fun del ->
      Sqlite3.bind_text del 1 alias |> ignore;
      Sqlite3.step del |> ignore);
    with_stmt conn "DELETE FROM room_members WHERE alias = ?" (fun del_member ->
      Sqlite3.bind_text del_member 1 alias |> ignore;
      Sqlite3.step del_member |> ignore)

  let register t ~node_id ~session_id ~alias ?(client_type="unknown") ?(client_version="") ?(client_os="") ?(ttl=default_lease_ttl) ?(identity_pk="") ?(enc_pubkey="") ?(signed_at=0.0) ?(sig_b64="") ?(opaque_host_id : string option = None) () =
    with_lock t (fun () ->
      let open Sqlite3 in
      let conn = t.db in
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
            with_stmt conn "SELECT identity_pk_b64 FROM allowed_identities WHERE alias = ?" (fun stmt ->
              bind_text stmt 1 alias |> ignore;
              let rc = step stmt in
              if rc = ROW then
                let pinned = Data.to_string_exn (column stmt 0) in
                if submitted_b64 = pinned then `Allowed else `Mismatch
              else `Unlisted)
        else
          let has_row = exec_prepared conn "SELECT identity_pk_b64 FROM allowed_identities WHERE alias = ?" [`Text alias] in
          if not has_row then `Unlisted else `ListedNoPk
      in
      match allow_state with
      | `Mismatch | `ListedNoPk ->
        let dummy = RegistrationLease.make ~node_id ~session_id ~alias ~client_type ~ttl ~identity_pk ~enc_pubkey ~signed_at ~sig_b64 () in
        ("alias_not_allowed", dummy)
      | `Unlisted | `Allowed ->
        let has_row = exec_prepared conn "SELECT node_id, session_id, registered_at, last_seen, ttl, identity_pk FROM secure_leases_v2 WHERE alias = ?" [`Text alias] in
        let conflict_lease = ref None in
        let existing_pk = ref "" in
        if has_row then (
          with_stmt conn "SELECT node_id, session_id, registered_at, last_seen, ttl, identity_pk FROM secure_leases_v2 WHERE alias = ?" (fun stmt ->
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
          check_existing ())
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
            (* B174: coalesce opaque_host_id — empty excluded must not wipe a
               previously stored host id (older clients re-registering). *)
            (* Production behaviour is unconditionally private-by-default.
               Tests that need public discovery must call the explicit setter. *)
            with_stmt conn "INSERT INTO secure_leases_v2 (alias, node_id, session_id, client_type, registered_at, last_seen, ttl, identity_pk, enc_pubkey, signed_at, sig_b64, opaque_host_id, client_version, client_os, discovery_visibility) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'private') ON CONFLICT(alias) DO UPDATE SET node_id=excluded.node_id, session_id=excluded.session_id, client_type=excluded.client_type, last_seen=excluded.last_seen, ttl=excluded.ttl, identity_pk=excluded.identity_pk, enc_pubkey=excluded.enc_pubkey, signed_at=excluded.signed_at, sig_b64=excluded.sig_b64, opaque_host_id=CASE WHEN excluded.opaque_host_id = '' THEN secure_leases_v2.opaque_host_id ELSE excluded.opaque_host_id END, client_version=excluded.client_version, client_os=excluded.client_os" (fun stmt ->
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
            bind_text stmt 13 client_version |> ignore;
            bind_text stmt 14 client_os |> ignore;
            let rc = step stmt in
            if not (Rc.is_success rc) && rc <> DONE then
              failwith ("register insert failed: " ^ Rc.to_string rc));
            (* Read back coalesced host id so returned lease matches DB. *)
            let effective_ohid =
              match opaque_host_id with
              | Some s when s <> "" -> Some s
              | _ ->
                with_stmt conn "SELECT opaque_host_id FROM secure_leases_v2 WHERE alias = ?" (fun sel ->
                  bind_text sel 1 alias |> ignore;
                  if step sel = ROW then
                    let raw = Data.to_string_exn (column sel 0) in
                    if raw = "" then None else Some raw
                  else None)
            in
            let lease = RegistrationLease.make ~node_id ~session_id ~alias ~client_type ~client_version ~client_os ~ttl ~identity_pk:effective_pk ~enc_pubkey ~signed_at ~sig_b64 ~opaque_host_id:effective_ohid () in
            ("ok", lease)
    )

  let identity_pk_of t ~alias =
    let alias, _ = normalize_relay_alias ~alias ~opaque_host_id:None in
    with_lock t (fun () ->
      let conn = t.db in
      with_stmt conn "SELECT identity_pk, last_seen FROM secure_leases_v2 WHERE alias = ?" (fun stmt ->
      bind_text stmt 1 alias |> ignore;
      if step stmt = Rc.ROW then
        let pk = Data.to_string_exn (column stmt 0) in
        let last_seen = data_to_float_default (column stmt 1) in
        if pk = "" || alias_released ~now:(Unix.gettimeofday ()) ~last_seen then None else Some pk
      else None)
    )

  let alias_of_identity_pk t ~identity_pk =
    with_lock t (fun () ->
      let conn = t.db in
      (* B264: reverse identity oracle only for public discovery aliases. *)
      with_stmt conn
        "SELECT alias, last_seen FROM secure_leases_v2          WHERE identity_pk = ? AND discovery_visibility = 'public'" (fun stmt ->
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
      loop ())
    )

  let query_messages_since t ~alias ~since_ts =
    let query_alias, _ = normalize_relay_alias ~alias ~opaque_host_id:None in
    with_lock t (fun () ->
      let conn = t.db in
      let msgs = ref [] in
      let min_ts = max since_ts (Unix.gettimeofday () -. 86400.0) in
      with_stmt conn
        "SELECT message_id, from_alias, to_alias, content, ts, pow_difficulty FROM inboxes \
         WHERE ts > ? \
         ORDER BY ts ASC LIMIT 500" (fun stmt ->
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
          let pow_difficulty =
            match Data.to_int (column stmt 5) with
            | Some i -> i
            | None -> Relay_pow_challenge.pow_difficulty_unrecorded
          in
          if alias_matches_display ~query:query_alias from_alias
             || alias_matches_display ~query:query_alias to_alias
          then
            msgs := `Assoc (Relay_pow_challenge.with_pow_meta ~difficulty:pow_difficulty [
              ("message_id", `String message_id);
              ("from_alias", `String from_alias);
              ("to_alias", `String to_alias);
              ("content", `String content);
              ("ts", `Float ts)
            ]) :: !msgs;
          loop ()
        ) else if rc <> Rc.DONE then
          failwith ("query_messages_since step failed: " ^ Rc.to_string rc)
      in
      loop ();
      List.rev !msgs)
    )

  let enc_pubkey_of t ~alias =
    let alias, _ = normalize_relay_alias ~alias ~opaque_host_id:None in
    with_lock t (fun () ->
      let conn = t.db in
      with_stmt conn "SELECT enc_pubkey, last_seen FROM secure_leases_v2 WHERE alias = ?" (fun stmt ->
      bind_text stmt 1 alias |> ignore;
      if step stmt = Rc.ROW then
        let ek = Data.to_string_exn (column stmt 0) in
        let last_seen = data_to_float_default (column stmt 1) in
        if ek = "" || alias_released ~now:(Unix.gettimeofday ()) ~last_seen then None else Some ek
      else None)
    )

  let alias_of_session t ~node_id ~session_id =
    with_lock t (fun () ->
      let conn = t.db in
      with_stmt conn "SELECT alias, last_seen FROM secure_leases_v2 WHERE node_id = ? AND session_id = ? LIMIT 1" (fun stmt ->
      bind_text stmt 1 node_id |> ignore;
      bind_text stmt 2 session_id |> ignore;
      if step stmt = Rc.ROW then
        let alias = Data.to_string_exn (column stmt 0) in
        let last_seen = data_to_float_default (column stmt 1) in
        if alias_released ~now:(Unix.gettimeofday ()) ~last_seen then None else Some alias
      else None)
    )

  let signed_at_of t ~alias =
    let alias, _ = normalize_relay_alias ~alias ~opaque_host_id:None in
    with_lock t (fun () ->
      let conn = t.db in
      with_stmt conn "SELECT signed_at, last_seen FROM secure_leases_v2 WHERE alias = ?" (fun stmt ->
      bind_text stmt 1 alias |> ignore;
      if step stmt = Rc.ROW then
        let sa_float = data_to_float_default (column stmt 0) in
        let last_seen = data_to_float_default (column stmt 1) in
        if sa_float = 0.0 || alias_released ~now:(Unix.gettimeofday ()) ~last_seen then None else Some sa_float
      else None)
    )

  let sig_b64_of t ~alias =
    let alias, _ = normalize_relay_alias ~alias ~opaque_host_id:None in
    with_lock t (fun () ->
      let conn = t.db in
      with_stmt conn "SELECT sig_b64, last_seen FROM secure_leases_v2 WHERE alias = ?" (fun stmt ->
      bind_text stmt 1 alias |> ignore;
      if step stmt = Rc.ROW then
        let sb = Data.to_string_exn (column stmt 0) in
        let last_seen = data_to_float_default (column stmt 1) in
        if sb = "" || alias_released ~now:(Unix.gettimeofday ()) ~last_seen then None else Some sb
      else None)
    )

  let set_allowed_identity t ~alias ~identity_pk_b64 =
    with_lock t (fun () ->
      let conn = t.db in
      with_stmt conn "INSERT INTO allowed_identities (alias, identity_pk_b64) VALUES (?, ?) ON CONFLICT(alias) DO UPDATE SET identity_pk_b64=excluded.identity_pk_b64" (fun stmt ->
        Sqlite3.bind_text stmt 1 alias |> ignore;
        Sqlite3.bind_text stmt 2 identity_pk_b64 |> ignore;
        let rc = Sqlite3.step stmt in
        if not (Rc.is_success rc) && rc <> Rc.DONE then
          failwith ("set_allowed_identity failed: " ^ Rc.to_string rc))
    )

  let allowed_identity_of t ~alias =
    with_lock t (fun () ->
      let conn = t.db in
      let has_row = exec_prepared conn "SELECT identity_pk_b64 FROM allowed_identities WHERE alias = ?" [`Text alias] in
      if not has_row then None
      else
        with_stmt conn "SELECT identity_pk_b64 FROM allowed_identities WHERE alias = ?" (fun stmt ->
          Sqlite3.bind_text stmt 1 alias |> ignore;
          let rc = Sqlite3.step stmt in
          if rc = Rc.ROW then
            let pk = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
            Some pk
          else None)
    )

  let check_allowlist t ~alias ~identity_pk_b64 =
    with_lock t (fun () ->
      let conn = t.db in
      let has_row = exec_prepared conn "SELECT identity_pk_b64 FROM allowed_identities WHERE alias = ?" [`Text alias] in
      if not has_row then `Unlisted
      else
        with_stmt conn "SELECT identity_pk_b64 FROM allowed_identities WHERE alias = ?" (fun stmt ->
          Sqlite3.bind_text stmt 1 alias |> ignore;
          let rc = Sqlite3.step stmt in
          if rc = Rc.ROW then
            let pinned = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
            if identity_pk_b64 = pinned then `Allowed else `Mismatch
          else `Unlisted)
    )

  let unbind_alias t ~alias =
    with_lock t (fun () ->
      let conn = t.db in
      let before = ref false in
      with_stmt conn "SELECT alias FROM secure_leases_v2 WHERE alias = ?" (fun stmt ->
        Sqlite3.bind_text stmt 1 alias |> ignore;
        let rc = Sqlite3.step stmt in
        before := (rc = Rc.ROW));
      if !before then (
        with_stmt conn "DELETE FROM secure_leases_v2 WHERE alias = ?" (fun del ->
          Sqlite3.bind_text del 1 alias |> ignore;
          Sqlite3.step del |> ignore)
      );
      !before
    )

  (* B219: inner worker — takes the shared connection and does NOT lock; its
     only caller [check_register_nonce] already holds [t.mutex]. Adding a lock
     here would nest inside that one (plain non-reentrant Mutex) and deadlock. *)
  let check_nonce conn ~ttl ~nonce ~ts =
    let cutoff = ts -. ttl in
    with_stmt conn "DELETE FROM register_nonces WHERE ts < ?" (fun del_stmt ->
      Sqlite3.bind_double del_stmt 1 cutoff |> ignore;
      Sqlite3.step del_stmt |> ignore);
    let has_row = exec_prepared conn "SELECT nonce FROM register_nonces WHERE nonce = ?" [`Text nonce] in
    if has_row then Res.Error relay_err_nonce_replay
    else (
      with_stmt conn "INSERT INTO register_nonces (nonce, ts) VALUES (?, ?)" (fun ins_stmt ->
        Sqlite3.bind_text ins_stmt 1 nonce |> ignore;
        Sqlite3.bind_double ins_stmt 2 ts |> ignore;
        Sqlite3.step ins_stmt |> ignore);
      Res.Ok ()
    )

  let check_register_nonce t ~nonce ~ts =
    with_lock t (fun () ->
      check_nonce t.db ~ttl:600.0 ~nonce ~ts
    )

  let check_request_nonce t ~nonce ~ts =
    with_lock t (fun () ->
      let conn = t.db in
      let cutoff = ts -. 120.0 in
      with_stmt conn "DELETE FROM request_nonces WHERE ts < ?" (fun del_stmt ->
        Sqlite3.bind_double del_stmt 1 cutoff |> ignore;
        Sqlite3.step del_stmt |> ignore);
      let has_row = exec_prepared conn "SELECT nonce FROM request_nonces WHERE nonce = ?" [`Text nonce] in
      if has_row then Res.Error relay_err_nonce_replay
      else (
        with_stmt conn "INSERT INTO request_nonces (nonce, ts) VALUES (?, ?)" (fun ins_stmt ->
          Sqlite3.bind_text ins_stmt 1 nonce |> ignore;
          Sqlite3.bind_double ins_stmt 2 ts |> ignore;
          Sqlite3.step ins_stmt |> ignore);
        Res.Ok ()
      )
    )

  (* B116: dedicated revoke-proof nonce store (persisted). Same TTL as
     request nonces (120s > the 30s signed-request window, no eviction
     gap) but a distinct table so the pre-auth outer verifier never writes
     here. *)
  let check_revoke_nonce t ~nonce ~ts =
    with_lock t (fun () ->
      let conn = t.db in
      let cutoff = ts -. 120.0 in
      with_stmt conn "DELETE FROM revoke_nonces WHERE ts < ?" (fun del_stmt ->
        Sqlite3.bind_double del_stmt 1 cutoff |> ignore;
        Sqlite3.step del_stmt |> ignore);
      let has_row = exec_prepared conn "SELECT nonce FROM revoke_nonces WHERE nonce = ?" [`Text nonce] in
      if has_row then Res.Error relay_err_nonce_replay
      else (
        with_stmt conn "INSERT INTO revoke_nonces (nonce, ts) VALUES (?, ?)" (fun ins_stmt ->
          Sqlite3.bind_text ins_stmt 1 nonce |> ignore;
          Sqlite3.bind_double ins_stmt 2 ts |> ignore;
          Sqlite3.step ins_stmt |> ignore);
        Res.Ok ()
      )
    )

  let heartbeat t ~node_id ~session_id ?(opaque_host_id = "") =
    with_lock t (fun () ->
      let conn = t.db in
      let now = Unix.gettimeofday () in
      let found_lease = ref None in
      with_stmt conn "SELECT alias, node_id, session_id, client_type, registered_at, last_seen, ttl, identity_pk, opaque_host_id FROM secure_leases_v2 WHERE node_id = ? AND session_id = ?" (fun stmt ->
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
      find_lease ());
      match !found_lease with
      | None ->
        let dummy = RegistrationLease.make ~node_id ~session_id ~alias:"_error" () in
        (relay_err_unknown_alias, dummy)
      | Some lease when alias_released ~now ~last_seen:(RegistrationLease.last_seen lease) ->
        release_alias conn (RegistrationLease.alias lease);
        let dummy = RegistrationLease.make ~node_id ~session_id ~alias:"_error" () in
        (relay_err_unknown_alias, dummy)
      | Some lease ->
        (* B174: heal host id when the client reports one on heartbeat. *)
        let up_sql =
          if opaque_host_id <> "" then
            "UPDATE secure_leases_v2 SET last_seen = ?, \
             opaque_host_id = CASE WHEN ? = '' THEN opaque_host_id ELSE ? END \
             WHERE alias = ?"
          else
            "UPDATE secure_leases_v2 SET last_seen = ? WHERE alias = ?"
        in
        with_stmt conn up_sql (fun up_stmt ->
          Sqlite3.bind_double up_stmt 1 now |> ignore;
          if opaque_host_id <> "" then begin
            Sqlite3.bind_text up_stmt 2 opaque_host_id |> ignore;
            Sqlite3.bind_text up_stmt 3 opaque_host_id |> ignore;
            Sqlite3.bind_text up_stmt 4 (RegistrationLease.alias lease) |> ignore
          end else
            Sqlite3.bind_text up_stmt 2 (RegistrationLease.alias lease) |> ignore;
          Sqlite3.step up_stmt |> ignore);
        RegistrationLease.touch lease;
        RegistrationLease.set_opaque_host_id lease opaque_host_id;
        ("ok", lease)
    )

  let list_peers_unlocked conn ~include_dead ~only_public =
    let now = Unix.gettimeofday () in
    let leases = ref [] in
    with_stmt conn
      "SELECT alias, node_id, session_id, client_type, registered_at, last_seen, ttl,               identity_pk, opaque_host_id, client_version, client_os, discovery_visibility          FROM secure_leases_v2" (fun stmt ->
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
          let client_version =
            match Sqlite3.Data.to_string (Sqlite3.column stmt 9) with Some s -> s | None -> "" in
          let client_os =
            match Sqlite3.Data.to_string (Sqlite3.column stmt 10) with Some s -> s | None -> "" in
          let disc_vis =
            let raw =
              try Sqlite3.Data.to_string_exn (Sqlite3.column stmt 11)
              with _ -> "private"
            in
            if raw = "public" then Public else Private
          in
          let lease =
            RegistrationLease.make
              ~node_id
              ~session_id
              ~alias
              ~client_type
              ~client_version
              ~client_os
              ~registered_at
              ~last_seen
              ~ttl
              ~identity_pk
              ~opaque_host_id:opaque_host_id
              ()
          in
          let alive = (last_seen +. ttl) >= now in
          if (not only_public || disc_vis = Public)
             && not (alias_released ~now ~last_seen)
             && (include_dead || alive)
          then leases := lease :: !leases;
          loop ()
        ) else if rc <> Rc.DONE then
          failwith ("list_peers step failed: " ^ Rc.to_string rc)
      in
      loop ());
    !leases

  let list_peers t ?(include_dead=false) =
    with_lock t (fun () ->
      list_peers_unlocked t.db ~include_dead ~only_public:true)

  let list_peers_admin t ?(include_dead=false) =
    with_lock t (fun () ->
      list_peers_unlocked t.db ~include_dead ~only_public:false)

  let gc t =
    with_lock t (fun () ->
      let conn = t.db in
      let now = Unix.gettimeofday () in
      let expired_aliases = ref [] in
      with_stmt conn "SELECT alias, last_seen, ttl FROM secure_leases_v2" (fun stmt ->
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
      collect_expired ());
      List.iter (fun alias ->
        release_alias conn alias
      ) !expired_aliases;
      let live_keys = ref [] in
      with_stmt conn "SELECT node_id, session_id FROM secure_leases_v2" (fun live_stmt ->
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
      collect_live ());
      let stale_keys = ref [] in
      with_stmt conn "SELECT DISTINCT node_id, session_id FROM inboxes" (fun inbox_stmt ->
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
      collect_stale ());
      let pruned = List.length !stale_keys in
      List.iter (fun (node_id, session_id) ->
        with_stmt conn "DELETE FROM inboxes WHERE node_id = ? AND session_id = ?" (fun del ->
          Sqlite3.bind_text del 1 node_id |> ignore;
          Sqlite3.bind_text del 2 session_id |> ignore;
          Sqlite3.step del |> ignore)
      ) !stale_keys;
      (* B116: sweep expired revoke-proof nonces on a SERVER-time basis.
         check_revoke_nonce only self-cleans when another owner revoke
         runs it (rare), so without this the persisted revoke_nonces table
         would accumulate durable rows. request_nonces/register_nonces
         self-clean on their frequent per-request hits, so this gc sweep is
         specific to the low-traffic revoke store. *)
      with_stmt conn "DELETE FROM revoke_nonces WHERE ts < ?" (fun del_revoke ->
        Sqlite3.bind_double del_revoke 1 (now -. request_nonce_ttl) |> ignore;
        Sqlite3.step del_revoke |> ignore);
      (* B147: drop message-event rows past the largest stats window; the
         stats_totals 'messages_ever' counter keeps the all-time count. *)
      with_stmt conn "DELETE FROM stats_message_events WHERE ts < ?" (fun del_stats ->
        Sqlite3.bind_double del_stats 1 (now -. stats_event_retention_s) |> ignore;
        Sqlite3.step del_stats |> ignore);
      (* B262/B266: drop contact grants past max(expires,revoked)+grace. *)
      with_stmt conn
        "DELETE FROM contact_grant_message_ids WHERE verifier IN (
           SELECT verifier FROM contact_grants
            WHERE MAX(expires_at, COALESCE(revoked_at, expires_at)) + ? < ? )"
        (fun del_mids ->
          Sqlite3.bind_double del_mids 1 contact_grant_gc_grace_s |> ignore;
          Sqlite3.bind_double del_mids 2 now |> ignore;
          ignore (Sqlite3.step del_mids));
      with_stmt conn
        "DELETE FROM contact_grants
          WHERE MAX(expires_at, COALESCE(revoked_at, expires_at)) + ? < ?"
        (fun del_g ->
          Sqlite3.bind_double del_g 1 contact_grant_gc_grace_s |> ignore;
          Sqlite3.bind_double del_g 2 now |> ignore;
          ignore (Sqlite3.step del_g));
      `Ok (List.rev !expired_aliases, pruned)
    )

  let send t ~from_alias ~to_alias ~content ?(message_id=None) ?(pow_difficulty = -1) =
    with_lock t (fun () ->
      let conn = t.db in
      let msg_id = match message_id with Some id -> id | None -> Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ()) in
      let ts = Unix.gettimeofday () in
      let lookup_alias, _ = normalize_relay_alias ~alias:to_alias ~opaque_host_id:None in
      let disc_vis = ref None in
      with_stmt conn
        "SELECT discovery_visibility FROM secure_leases_v2 WHERE alias = ?" (fun vstmt ->
        Sqlite3.bind_text vstmt 1 lookup_alias |> ignore;
        if Sqlite3.step vstmt = Rc.ROW then
          let raw =
            try Sqlite3.Data.to_string_exn (Sqlite3.column vstmt 0)
            with _ -> "private"
          in
          disc_vis := Some (if raw = "public" then Public else Private));
      match !disc_vis with
      | None ->
        `Error (relay_err_unknown_alias, Printf.sprintf "no registration for alias %S" to_alias)
      | Some Private ->
        (* B264: private recipient — uniform with unknown; no content DLQ. *)
        `Error (relay_err_unknown_alias, Printf.sprintf "no registration for alias %S" to_alias)
      | Some Public ->
        with_stmt conn "SELECT alias, last_seen, ttl FROM secure_leases_v2 WHERE alias = ?" (fun stmt ->
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
            with_stmt conn "SELECT node_id, session_id FROM secure_leases_v2 WHERE alias = ?" (fun recv_stmt ->
            Sqlite3.bind_text recv_stmt 1 lookup_alias |> ignore;
            let rc2 = Sqlite3.step recv_stmt in
            if rc2 = Rc.ROW then
              let recv_node_id = Sqlite3.Data.to_string_exn (Sqlite3.column recv_stmt 0) in
              let recv_session_id = Sqlite3.Data.to_string_exn (Sqlite3.column recv_stmt 1) in
              with_stmt conn "INSERT INTO inboxes (node_id, session_id, message_id, from_alias, to_alias, content, ts, pow_difficulty) VALUES (?, ?, ?, ?, ?, ?, ?, ?)" (fun ins_stmt ->
              Sqlite3.bind_text ins_stmt 1 recv_node_id |> ignore;
              Sqlite3.bind_text ins_stmt 2 recv_session_id |> ignore;
              Sqlite3.bind_text ins_stmt 3 msg_id |> ignore;
              Sqlite3.bind_text ins_stmt 4 from_alias |> ignore;
              Sqlite3.bind_text ins_stmt 5 to_alias |> ignore;
              Sqlite3.bind_text ins_stmt 6 content |> ignore;
              Sqlite3.bind_double ins_stmt 7 ts |> ignore;
              Sqlite3.bind_int ins_stmt 8 pow_difficulty |> ignore;
              Sqlite3.step ins_stmt |> ignore;
              `Ok ts)
            else
              `Error (relay_err_unknown_alias, "recipient lease not found"))
        else
          `Error (relay_err_unknown_alias, "recipient lease not found"))
    )

  let poll_inbox t ~node_id ~session_id =
    with_lock t (fun () ->
      let conn = t.db in
      let msgs = ref [] in
      with_stmt conn "SELECT message_id, from_alias, to_alias, content, ts, pow_difficulty FROM inboxes WHERE node_id = ? AND session_id = ? ORDER BY id" (fun sel_stmt ->
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
          let pow_difficulty =
            match Sqlite3.Data.to_int (Sqlite3.column sel_stmt 5) with
            | Some i -> i
            | None -> Relay_pow_challenge.pow_difficulty_unrecorded
          in
          msgs := `Assoc (Relay_pow_challenge.with_pow_meta ~difficulty:pow_difficulty [("message_id", `String message_id); ("from_alias", `String from_alias); ("to_alias", `String to_alias); ("content", `String content); ("ts", `Float ts)]) :: !msgs;
          loop ()
        ) else if rc <> Rc.DONE then
          failwith ("poll_inbox step failed: " ^ Rc.to_string rc)
      in
      loop ());
      with_stmt conn "DELETE FROM inboxes WHERE node_id = ? AND session_id = ?" (fun del_stmt ->
        Sqlite3.bind_text del_stmt 1 node_id |> ignore;
        Sqlite3.bind_text del_stmt 2 session_id |> ignore;
        Sqlite3.step del_stmt |> ignore);
      List.rev !msgs
    )

  let peek_inbox t ~node_id ~session_id =
    with_lock t (fun () ->
      let conn = t.db in
      let msgs = ref [] in
      with_stmt conn "SELECT message_id, from_alias, to_alias, content, ts, pow_difficulty FROM inboxes WHERE node_id = ? AND session_id = ? ORDER BY id" (fun stmt ->
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
          let pow_difficulty =
            match Sqlite3.Data.to_int (Sqlite3.column stmt 5) with
            | Some i -> i
            | None -> Relay_pow_challenge.pow_difficulty_unrecorded
          in
          msgs := `Assoc (Relay_pow_challenge.with_pow_meta ~difficulty:pow_difficulty [("message_id", `String message_id); ("from_alias", `String from_alias); ("to_alias", `String to_alias); ("content", `String content); ("ts", `Float ts)]) :: !msgs;
          loop ()
        ) else if rc <> Rc.DONE then
          failwith ("peek_inbox step failed: " ^ Rc.to_string rc)
      in
      loop ());
      List.rev !msgs
    )

  let send_all t ~from_alias ~content ?(message_id=None) =
    with_lock t (fun () ->
      let conn = t.db in
      let now = Unix.gettimeofday () in
      let sent_to = ref [] in
      let skipped = ref [] in
      let msg_id = match message_id with Some id -> id | None -> Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ()) in
      (* B264: broadcast only to public discovery recipients. *)
      with_stmt conn
        "SELECT alias, last_seen, ttl, node_id, session_id FROM secure_leases_v2          WHERE alias != ? AND discovery_visibility = 'public'" (fun stmt ->
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
            with_stmt conn "INSERT INTO inboxes (node_id, session_id, message_id, from_alias, to_alias, content, ts) VALUES (?, ?, ?, ?, ?, ?, ?)" (fun ins_stmt ->
              Sqlite3.bind_text ins_stmt 1 node_id |> ignore;
              Sqlite3.bind_text ins_stmt 2 session_id |> ignore;
              Sqlite3.bind_text ins_stmt 3 msg_id |> ignore;
              Sqlite3.bind_text ins_stmt 4 from_alias |> ignore;
              Sqlite3.bind_text ins_stmt 5 alias |> ignore;
              Sqlite3.bind_text ins_stmt 6 content |> ignore;
              Sqlite3.bind_double ins_stmt 7 now |> ignore;
              Sqlite3.step ins_stmt |> ignore);
            sent_to := alias :: !sent_to
          ) else
            skipped := (alias, "not_alive") :: !skipped;
          loop ()
        else if rc <> Rc.DONE then
          failwith ("send_all step failed: " ^ Rc.to_string rc)
      in
      loop ());
      `Ok (now, List.rev !sent_to, List.map fst (List.rev !skipped))
    )

  let join_room t ?(visibility = "public") ~alias ~room_id () =
    let visibility = canonical_visibility_exn visibility in
    with_lock t (fun () ->
      let conn = t.db in
      let active_alias = with_stmt conn "SELECT last_seen FROM secure_leases_v2 WHERE alias = ? LIMIT 1" (fun lease_stmt ->
      Sqlite3.bind_text lease_stmt 1 alias |> ignore;
      match Sqlite3.step lease_stmt with
      | Rc.ROW ->
        let last_seen = data_to_float_default (Sqlite3.column lease_stmt 0) in
        not (alias_released ~now:(Unix.gettimeofday ()) ~last_seen)
      | _ -> false) in
      if not active_alias then (
        release_alias conn alias;
        `Error (relay_err_unknown_alias, Printf.sprintf "alias %S is not registered" alias)
      ) else (
      (* INSERT OR IGNORE: visibility is applied only on room creation; if the
         room already exists, its stored visibility is preserved. Post-creation
         changes go through the signed set_room_visibility op. *)
      (* B117: seed history_public from the creation visibility. Only applied
         on room creation (INSERT OR IGNORE); an existing room keeps its
         stored policy. *)
      with_stmt conn "INSERT OR IGNORE INTO rooms (room_id, visibility, history_public) VALUES (?, ?, ?)" (fun room_stmt ->
        Sqlite3.bind_text room_stmt 1 room_id |> ignore;
        Sqlite3.bind_text room_stmt 2 visibility |> ignore;
        Sqlite3.bind_int room_stmt 3
          (if history_public_default_for_visibility visibility then 1 else 0) |> ignore;
        Sqlite3.step room_stmt |> ignore);
      with_stmt conn "INSERT OR IGNORE INTO room_members (room_id, alias) VALUES (?, ?)" (fun mem_stmt ->
        Sqlite3.bind_text mem_stmt 1 room_id |> ignore;
        Sqlite3.bind_text mem_stmt 2 alias |> ignore;
        Sqlite3.step mem_stmt |> ignore);
      `Ok
      )
    )

  let leave_room t ~alias ~room_id =
    with_lock t (fun () ->
      let conn = t.db in
      with_stmt conn "DELETE FROM room_members WHERE room_id = ? AND alias = ?" (fun stmt ->
        Sqlite3.bind_text stmt 1 room_id |> ignore;
        Sqlite3.bind_text stmt 2 alias |> ignore;
        Sqlite3.step stmt |> ignore);
      `Ok
    )

  let send_room t ~from_alias ~room_id ~content ?(message_id=None) ?envelope () =
    with_lock t (fun () ->
      let conn = t.db in
      let msg_id = match message_id with Some id -> id | None -> Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ()) in
      let ts = Unix.gettimeofday () in
      let sender_active = with_stmt conn "SELECT last_seen FROM secure_leases_v2 WHERE alias = ? LIMIT 1" (fun sender_stmt ->
      Sqlite3.bind_text sender_stmt 1 from_alias |> ignore;
      match Sqlite3.step sender_stmt with
      | Rc.ROW ->
        let last_seen = data_to_float_default (Sqlite3.column sender_stmt 0) in
        not (alias_released ~now:ts ~last_seen)
      | _ -> false) in
      if not sender_active then (
        release_alias conn from_alias;
        `Error (relay_err_unknown_alias, Printf.sprintf "alias %S is not registered" from_alias)
      ) else
      let sender_member = with_stmt conn "SELECT 1 FROM room_members WHERE room_id = ? AND alias = ? LIMIT 1" (fun member_stmt ->
      Sqlite3.bind_text member_stmt 1 room_id |> ignore;
      Sqlite3.bind_text member_stmt 2 from_alias |> ignore;
      Sqlite3.step member_stmt = Rc.ROW) in
      if not sender_member then
        `Error (relay_err_not_a_member, Printf.sprintf "alias %S is not a member of room %S" from_alias room_id)
      else
      let delivered_to = ref [] in
      let skipped = ref [] in
      with_stmt conn "SELECT alias FROM room_members WHERE room_id = ? AND alias != ?" (fun stmt ->
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
      loop ());
      with_stmt conn "INSERT INTO room_history (room_id, message_id, from_alias, content, ts) VALUES (?, ?, ?, ?, ?)" (fun hist_stmt ->
        Sqlite3.bind_text hist_stmt 1 room_id |> ignore;
        Sqlite3.bind_text hist_stmt 2 msg_id |> ignore;
        Sqlite3.bind_text hist_stmt 3 from_alias |> ignore;
        Sqlite3.bind_text hist_stmt 4 content |> ignore;
        Sqlite3.bind_double hist_stmt 5 ts |> ignore;
        Sqlite3.step hist_stmt |> ignore);
      List.iter (fun to_alias ->
        with_stmt conn "SELECT node_id, session_id, last_seen, ttl FROM secure_leases_v2 WHERE alias = ?" (fun node_stmt ->
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
            with_stmt conn "INSERT INTO inboxes (node_id, session_id, message_id, from_alias, to_alias, content, ts) VALUES (?, ?, ?, ?, ?, ?, ?)" (fun inbox_stmt ->
              Sqlite3.bind_text inbox_stmt 1 node_id |> ignore;
              Sqlite3.bind_text inbox_stmt 2 session_id |> ignore;
              Sqlite3.bind_text inbox_stmt 3 msg_id |> ignore;
              Sqlite3.bind_text inbox_stmt 4 from_alias |> ignore;
              Sqlite3.bind_text inbox_stmt 5 (to_alias ^ "#" ^ room_id) |> ignore;
              Sqlite3.bind_text inbox_stmt 6 content |> ignore;
              Sqlite3.bind_double inbox_stmt 7 ts |> ignore;
              Sqlite3.step inbox_stmt |> ignore)
          ) else
            skipped := to_alias :: !skipped
        else
          skipped := to_alias :: !skipped)
      ) !delivered_to;
      let delivered =
        List.filter (fun alias -> not (List.mem alias !skipped)) !delivered_to
      in
      `Ok (ts, List.rev delivered, List.rev !skipped)
    )

  let room_history t ~room_id ?(limit=50) =
    with_lock t (fun () ->
      let conn = t.db in
      let msgs = ref [] in
      with_stmt conn "SELECT message_id, from_alias, content, ts FROM room_history WHERE room_id = ? ORDER BY id DESC LIMIT ?" (fun stmt ->
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
      loop ());
      List.rev !msgs
    )

  let dead_letter t =
    with_lock t (fun () ->
      let conn = t.db in
      let msgs = ref [] in
      with_stmt conn "SELECT message_id, from_alias, to_alias, content, ts, reason FROM dead_letter" (fun stmt ->
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
      loop ());
      List.rev !msgs
    )

  let add_dead_letter t msg =
    with_lock t (fun () ->
      let conn = t.db in
      let message_id = Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "message_id" msg) in
      let from_alias = Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "from_alias" msg) in
      let to_alias = Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "to_alias" msg) in
      let content = Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "content" msg) in
      let ts = Yojson.Safe.Util.to_number (Yojson.Safe.Util.member "ts" msg) in
      let reason = Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "reason" msg) in
      with_stmt conn "INSERT INTO dead_letter (message_id, from_alias, to_alias, content, ts, reason) VALUES (?, ?, ?, ?, ?, ?)" (fun stmt ->
        Sqlite3.bind_text stmt 1 message_id |> ignore;
        Sqlite3.bind_text stmt 2 from_alias |> ignore;
        Sqlite3.bind_text stmt 3 to_alias |> ignore;
        Sqlite3.bind_text stmt 4 content |> ignore;
        Sqlite3.bind_double stmt 5 ts |> ignore;
        Sqlite3.bind_text stmt 6 reason |> ignore;
        ignore (Sqlite3.step stmt))
    )

  let list_rooms ?for_alias t =
    with_lock t (fun () ->
      let conn = t.db in
      let rooms = ref [] in
      (* Directory policy (B230 + B229):
         - anonymous: public + gated only.
         - with for_alias: also unlisted rooms where that alias is a member.
         private rooms stay omitted. Gated roster redacted (B229). *)
      let stmt_sql =
        match for_alias with
        | None ->
            "SELECT room_id, visibility FROM rooms WHERE visibility IN ('public','gated')"
        | Some _ ->
            (* Alias compare is case-insensitive (c2c aliases are casefold);
               COLLATE NOCASE matches in-memory list_rooms membership. *)
            "SELECT room_id, visibility FROM rooms WHERE visibility IN ('public','gated') \
             OR (visibility = 'unlisted' AND EXISTS ( \
               SELECT 1 FROM room_members m \
               WHERE m.room_id = rooms.room_id AND m.alias = ? COLLATE NOCASE))"
      in
      with_stmt conn stmt_sql (fun stmt ->
      (match for_alias with
       | Some alias -> Sqlite3.bind_text stmt 1 alias |> ignore
       | None -> ());
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let room_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let visibility =
            canonical_visibility_or_raw
              (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1))
          in
          (* B118: defensive directory-boundary guard — omit any room whose id
             is out-of-grammar (contains `#`/`@` etc.) so its alias#room@relay
             directory address can never be ambiguous. Covers legacy persisted
             rows and backend-direct callers that bypass handle_join_room's
             grammar check. Better unlisted than an unparseable address. *)
          if not (valid_relay_room_id room_id) then loop ()
          else
          (* The COUNT aggregate comes back as a sqlite INTEGER; [Data.to_string_exn]
             raises DataTypeError on INT, so read the int directly (with a string
             fallback for safety). *)
          let member_count =
            with_stmt conn "SELECT COUNT(*) FROM room_members WHERE room_id = ?" (fun mem_stmt ->
              Sqlite3.bind_text mem_stmt 1 room_id |> ignore;
              let rc2 = Sqlite3.step mem_stmt in
              if rc2 = Rc.ROW then
                (match Sqlite3.column mem_stmt 0 with
                 | Sqlite3.Data.INT n -> Int64.to_int n
                 | d -> (try int_of_string (Sqlite3.Data.to_string_exn d) with _ -> 0))
              else 0)
          in
          (* B229: anonymous directory — public rooms expose presentation
             roster addresses; gated rooms keep room_id + member_count for
             discovery but redact members (local-broker 4-level parity).
             room_members rows stay raw for membership checks and delivery. *)
          let members_json =
            if visibility = "gated" then `List []
            else begin
              with_stmt conn "SELECT alias FROM room_members WHERE room_id = ?" (fun alias_stmt ->
              Sqlite3.bind_text alias_stmt 1 room_id |> ignore;
              let aliases = ref [] in
              let rec collect_aliases () =
                let rc3 = Sqlite3.step alias_stmt in
                if rc3 = Rc.ROW then
                  let alias =
                    Sqlite3.Data.to_string_exn (Sqlite3.column alias_stmt 0)
                  in
                  aliases := alias :: !aliases;
                  collect_aliases ()
                else if rc3 <> Rc.DONE then
                  failwith
                    ("list_rooms aliases step failed: " ^ Rc.to_string rc3)
              in
              collect_aliases ();
              `List
                (List.map
                   (fun a ->
                     `String (format_room_roster_address ~alias:a ~room_id))
                   !aliases))
            end
          in
          rooms :=
            `Assoc
              [ ("room_id", `String room_id)
              ; ("member_count", `Int member_count)
              ; ("members", members_json)
              ]
            :: !rooms;
          loop ()
        else if rc <> Rc.DONE then
          failwith ("list_rooms step failed: " ^ Rc.to_string rc)
      in
      loop ());
      List.rev !rooms
    )

  let my_rooms t =
    with_lock t (fun () ->
      let conn = t.db in
      let rooms = ref [] in
      with_stmt conn "SELECT DISTINCT room_id FROM room_members" (fun stmt ->
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let room_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          (* The COUNT aggregate comes back as a sqlite INTEGER; [Data.to_string_exn]
             raises DataTypeError on INT, so read the int directly (with a string
             fallback for safety). *)
          let member_count =
            with_stmt conn "SELECT COUNT(*) FROM room_members WHERE room_id = ?" (fun mem_stmt ->
              Sqlite3.bind_text mem_stmt 1 room_id |> ignore;
              let rc2 = Sqlite3.step mem_stmt in
              if rc2 = Rc.ROW then
                (match Sqlite3.column mem_stmt 0 with
                 | Sqlite3.Data.INT n -> Int64.to_int n
                 | d -> (try int_of_string (Sqlite3.Data.to_string_exn d) with _ -> 0))
              else 0)
          in
          let aliases = ref [] in
          with_stmt conn "SELECT alias FROM room_members WHERE room_id = ?" (fun alias_stmt ->
          Sqlite3.bind_text alias_stmt 1 room_id |> ignore;
          let rec collect_aliases () =
            let rc3 = Sqlite3.step alias_stmt in
            if rc3 = Rc.ROW then
              let alias = Sqlite3.Data.to_string_exn (Sqlite3.column alias_stmt 0) in
              aliases := alias :: !aliases;
              collect_aliases ()
            else if rc3 <> Rc.DONE then
              failwith ("my_rooms aliases step failed: " ^ Rc.to_string rc3)
          in
          collect_aliases ());
          rooms := `Assoc [("room_id", `String room_id); ("member_count", `Int member_count); ("members", `List (List.map (fun a -> `String a) !aliases))] :: !rooms;
          loop ()
        else if rc <> Rc.DONE then
          failwith ("my_rooms step failed: " ^ Rc.to_string rc)
      in
      loop ());
      List.rev !rooms
    )

  let room_visibility_of t ~room_id =
    with_lock t (fun () ->
      let conn = t.db in
      with_stmt conn "SELECT visibility FROM rooms WHERE room_id = ?" (fun stmt ->
        Sqlite3.bind_text stmt 1 room_id |> ignore;
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          canonical_visibility_or_raw (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0))
        else "public")
    )

  let room_exists t ~room_id =
    with_lock t (fun () ->
      let conn = t.db in
      with_stmt conn "SELECT 1 FROM rooms WHERE room_id = ? LIMIT 1" (fun stmt ->
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      Sqlite3.step stmt = Rc.ROW)
    )

  let room_invites_of t ~room_id =
    with_lock t (fun () ->
      let conn = t.db in
      let invites = ref [] in
      with_stmt conn "SELECT identity_pk_b64 FROM room_invites WHERE room_id = ?" (fun stmt ->
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
      loop ());
      List.rev !invites
    )

  let is_invited t ~room_id ~identity_pk_b64 =
    with_lock t (fun () ->
      let conn = t.db in
      with_stmt conn "SELECT 1 FROM room_invites WHERE room_id = ? AND identity_pk_b64 = ?" (fun stmt ->
        Sqlite3.bind_text stmt 1 room_id |> ignore;
        Sqlite3.bind_text stmt 2 identity_pk_b64 |> ignore;
        let rc = Sqlite3.step stmt in
        rc = Rc.ROW)
    )

  let set_room_visibility t ~room_id ~visibility =
    let visibility = canonical_visibility_exn visibility in
    with_lock t (fun () ->
      let conn = t.db in
      (* B117: on a downgrade to gated/private, atomically clear history_public
         (CASE forces 0). public/unlisted preserve the existing stored value
         (rooms.history_public), never silently re-opening a closed room. On
         insert (room absent) history_public seeds from the new visibility. *)
      with_stmt conn
        "INSERT INTO rooms (room_id, visibility, history_public) VALUES (?, ?, ?) \
         ON CONFLICT(room_id) DO UPDATE SET visibility=excluded.visibility, \
         history_public = CASE WHEN excluded.visibility IN ('gated','private') \
         THEN 0 ELSE rooms.history_public END" (fun stmt ->
        Sqlite3.bind_text stmt 1 room_id |> ignore;
        Sqlite3.bind_text stmt 2 visibility |> ignore;
        Sqlite3.bind_int stmt 3
          (if history_public_default_for_visibility visibility then 1 else 0) |> ignore;
        Sqlite3.step stmt |> ignore)
    )

  (* B117: read the persisted history_public policy; default per visibility
     when the row/column is absent. *)
  let history_public_of t ~room_id =
    with_lock t (fun () ->
      let conn = t.db in
      with_stmt conn "SELECT history_public, visibility FROM rooms WHERE room_id = ?" (fun stmt ->
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      let rc = Sqlite3.step stmt in
      if rc = Rc.ROW then
        match Sqlite3.Data.to_int (Sqlite3.column stmt 0) with
        | Some n -> n <> 0
        | None ->
          (* Column NULL (shouldn't happen: NOT NULL) — fall back to the
             per-visibility default. *)
          let vis = try canonical_visibility_or_raw (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1)) with _ -> "public" in
          history_public_default_for_visibility vis
      else true (* unknown room: default open (matches empty-history read) *))
    )

  let set_room_history_public t ~room_id ~history_public =
    with_lock t (fun () ->
      let conn = t.db in
      with_stmt conn "UPDATE rooms SET history_public = ? WHERE room_id = ?" (fun stmt ->
        Sqlite3.bind_int stmt 1 (if history_public then 1 else 0) |> ignore;
        Sqlite3.bind_text stmt 2 room_id |> ignore;
        Sqlite3.step stmt |> ignore)
    )

  let invite_to_room t ~room_id ~identity_pk_b64 =
    with_lock t (fun () ->
      let conn = t.db in
      with_stmt conn "INSERT OR IGNORE INTO room_invites (room_id, identity_pk_b64) VALUES (?, ?)" (fun stmt ->
        Sqlite3.bind_text stmt 1 room_id |> ignore;
        Sqlite3.bind_text stmt 2 identity_pk_b64 |> ignore;
        Sqlite3.step stmt |> ignore)
    )

  let uninvite_from_room t ~room_id ~identity_pk_b64 =
    with_lock t (fun () ->
      let conn = t.db in
      with_stmt conn "DELETE FROM room_invites WHERE room_id = ? AND identity_pk_b64 = ?" (fun stmt ->
        Sqlite3.bind_text stmt 1 room_id |> ignore;
        Sqlite3.bind_text stmt 2 identity_pk_b64 |> ignore;
        Sqlite3.step stmt |> ignore)
    )

  let room_knocks_of t ~room_id =
    with_lock t (fun () ->
      let conn = t.db in
      let knocks = ref [] in
      with_stmt conn
        "SELECT requester_alias, requester_identity_pk_b64, requested_at \
         FROM room_knocks WHERE room_id = ? ORDER BY requested_at ASC" (fun stmt ->
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
      loop ());
      List.rev !knocks
    )

  let remove_room_knock t ~room_id ~requester_pk =
    with_lock t (fun () ->
      let conn = t.db in
      let found = with_stmt conn
        "SELECT requester_alias, requester_identity_pk_b64, requested_at \
         FROM room_knocks WHERE room_id = ? AND requester_identity_pk_b64 = ? LIMIT 1" (fun select_stmt ->
      Sqlite3.bind_text select_stmt 1 room_id |> ignore;
      Sqlite3.bind_text select_stmt 2 requester_pk |> ignore;
      match Sqlite3.step select_stmt with
      | Rc.ROW ->
        Some {
          requester_alias = Sqlite3.Data.to_string_exn (Sqlite3.column select_stmt 0);
          requester_pk = Sqlite3.Data.to_string_exn (Sqlite3.column select_stmt 1);
          requested_at = data_to_float_default (Sqlite3.column select_stmt 2);
        }
      | _ -> None) in
      (match found with
       | None -> None
       | Some knock ->
         with_stmt conn
           "DELETE FROM room_knocks WHERE room_id = ? AND requester_identity_pk_b64 = ?"
           (fun del_stmt ->
         Sqlite3.bind_text del_stmt 1 room_id |> ignore;
         Sqlite3.bind_text del_stmt 2 requester_pk |> ignore;
         Sqlite3.step del_stmt |> ignore);
         Some knock)
    )

  let knock_room t ~room_id ~requester_alias ~requester_pk =
    with_lock t (fun () ->
      let conn = t.db in
      let visibility_opt = with_stmt conn "SELECT visibility FROM rooms WHERE room_id = ? LIMIT 1" (fun room_stmt ->
      Sqlite3.bind_text room_stmt 1 room_id |> ignore;
      match Sqlite3.step room_stmt with
      | Rc.ROW ->
        Some (canonical_visibility_or_raw
          (Sqlite3.Data.to_string_exn (Sqlite3.column room_stmt 0)))
      | _ -> None) in
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
        let already_member = with_stmt conn
          "SELECT secure_leases_v2.last_seen \
           FROM room_members JOIN secure_leases_v2 ON secure_leases_v2.alias = room_members.alias \
           WHERE room_members.room_id = ? AND room_members.alias = ? LIMIT 1" (fun member_stmt ->
        Sqlite3.bind_text member_stmt 1 room_id |> ignore;
        Sqlite3.bind_text member_stmt 2 requester_alias |> ignore;
        match Sqlite3.step member_stmt with
        | Rc.ROW ->
          let last_seen = data_to_float_default (Sqlite3.column member_stmt 0) in
          not (alias_released ~now:(Unix.gettimeofday ()) ~last_seen)
        | _ -> false) in
        if already_member then
          `Error (relay_err_already_member,
            Printf.sprintf "alias %S is already a member of room %S"
              requester_alias room_id)
        else
          let already_invited = with_stmt conn
            "SELECT 1 FROM room_invites WHERE room_id = ? AND identity_pk_b64 = ? LIMIT 1"
            (fun invite_stmt ->
          Sqlite3.bind_text invite_stmt 1 room_id |> ignore;
          Sqlite3.bind_text invite_stmt 2 requester_pk |> ignore;
          Sqlite3.step invite_stmt = Rc.ROW) in
          if already_invited then
            `Error (relay_err_already_invited,
              Printf.sprintf "requester is already invited to room %S" room_id)
          else
            let already_pending = with_stmt conn
              "SELECT 1 FROM room_knocks \
               WHERE room_id = ? AND requester_identity_pk_b64 = ? LIMIT 1" (fun dup_stmt ->
            Sqlite3.bind_text dup_stmt 1 room_id |> ignore;
            Sqlite3.bind_text dup_stmt 2 requester_pk |> ignore;
            Sqlite3.step dup_stmt = Rc.ROW) in
            if already_pending then
              `Ok true
            else begin
              with_stmt conn
                "INSERT INTO room_knocks \
                 (room_id, requester_identity_pk_b64, requester_alias, requested_at) \
                 VALUES (?, ?, ?, ?)" (fun insert_stmt ->
              Sqlite3.bind_text insert_stmt 1 room_id |> ignore;
              Sqlite3.bind_text insert_stmt 2 requester_pk |> ignore;
              Sqlite3.bind_text insert_stmt 3 requester_alias |> ignore;
              Sqlite3.bind_double insert_stmt 4 (Unix.gettimeofday ()) |> ignore;
              Sqlite3.step insert_stmt |> ignore);
              `Ok false
            end
    )

  let is_room_member_alias t ~room_id ~alias =
    with_lock t (fun () ->
      let conn = t.db in
      with_stmt conn
        "SELECT secure_leases_v2.last_seen \
         FROM room_members JOIN secure_leases_v2 ON secure_leases_v2.alias = room_members.alias \
         WHERE room_members.room_id = ? AND room_members.alias = ? LIMIT 1" (fun stmt ->
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      Sqlite3.bind_text stmt 2 alias |> ignore;
      match Sqlite3.step stmt with
      | Rc.ROW ->
        let last_seen = data_to_float_default (Sqlite3.column stmt 0) in
        not (alias_released ~now:(Unix.gettimeofday ()) ~last_seen)
      | _ -> false)
    )

  (* S5a: Pairing token management — delegates to module-level SQL helpers *)
  let store_pairing_token t ~binding_id ~token_b64 ~machine_ed25519_pubkey ~expires_at =
    with_lock t (fun () ->
      let conn = t.db in
      store_pairing_token_db conn ~binding_id ~token_b64 ~machine_ed25519_pubkey ~expires_at
    )

  let get_and_burn_pairing_token t ~binding_id =
    with_lock t (fun () ->
      let conn = t.db in
      match get_and_burn_pairing_token_db conn ~binding_id with
      | Res.Ok opt -> opt
      | Res.Error _ -> None
    )

  let find_pairing_token t ~binding_id =
    with_lock t (fun () ->
      let conn = t.db in
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

  (* B262/B263: contact grants — SQLite lifecycle on process-lifetime t.db. *)
  let sql_begin_immediate conn =
    let rc = Sqlite3.exec conn "BEGIN IMMEDIATE" in
    if not (Rc.is_success rc) then
      failwith ("BEGIN IMMEDIATE failed: " ^ Rc.to_string rc)

  let sql_commit conn =
    let rc = Sqlite3.exec conn "COMMIT" in
    if not (Rc.is_success rc) then
      failwith ("COMMIT failed: " ^ Rc.to_string rc)

  let sql_rollback conn =
    ignore (Sqlite3.exec conn "ROLLBACK")

  let with_tx_immediate conn f =
    sql_begin_immediate conn;
    match (try Ok (f ()) with exn -> Error exn) with
    | Ok v ->
      (try sql_commit conn; v
       with commit_exn ->
         sql_rollback conn;
         raise commit_exn)
    | Error exn -> sql_rollback conn; raise exn

  let next_generation_for_recipient conn ~recipient_fp =
    let gen = ref 0 in
    with_stmt conn
      "SELECT COALESCE(MAX(generation), 0) FROM contact_grants WHERE recipient_identity_fp = ?"
      (fun stmt ->
        Sqlite3.bind_blob stmt 1 recipient_fp |> ignore;
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          gen :=
            (match Sqlite3.Data.to_int (Sqlite3.column stmt 0) with
             | Some i -> i
             | None ->
               (try int_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0))
                with _ -> 0)));
    !gen + 1

  let insert_contact_grant_row conn ~verifier ~recipient_fp ~delivery_alias
      ~sender_fp ~generation ~created_at ~expires_at ~label =
    with_stmt conn
      "INSERT INTO contact_grants
         (verifier, recipient_identity_fp, delivery_alias, sender_fp, scope,
          generation, created_at, expires_at, revoked_at, label)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)"
      (fun stmt ->
        Sqlite3.bind_blob stmt 1 verifier |> ignore;
        Sqlite3.bind_blob stmt 2 recipient_fp |> ignore;
        Sqlite3.bind_text stmt 3 delivery_alias |> ignore;
        Sqlite3.bind_blob stmt 4 sender_fp |> ignore;
        Sqlite3.bind_text stmt 5 contact_scope_v1 |> ignore;
        Sqlite3.bind_int stmt 6 generation |> ignore;
        Sqlite3.bind_double stmt 7 created_at |> ignore;
        Sqlite3.bind_double stmt 8 expires_at |> ignore;
        (match label with
         | Some l -> Sqlite3.bind_text stmt 9 l |> ignore
         | None -> Sqlite3.bind stmt 9 Sqlite3.Data.NULL |> ignore);
        let rc = Sqlite3.step stmt in
        if rc <> Rc.DONE then
          failwith ("insert contact_grant failed: " ^ Rc.to_string rc))

  let load_grant_by_verifier conn ~verifier =
    let result = ref None in
    with_stmt conn
      "SELECT recipient_identity_fp, delivery_alias, sender_fp, scope,
              generation, created_at, expires_at, revoked_at, label
         FROM contact_grants WHERE verifier = ?"
      (fun stmt ->
        Sqlite3.bind_blob stmt 1 verifier |> ignore;
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then begin
          let recipient_fp =
            Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0)
          in
          let delivery_alias =
            Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1)
          in
          let sender_fp = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2) in
          let scope = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 3) in
          let generation =
            match Sqlite3.Data.to_int (Sqlite3.column stmt 4) with
            | Some i -> i
            | None ->
              int_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 4))
          in
          let created_at =
            match Sqlite3.Data.to_float (Sqlite3.column stmt 5) with
            | Some f -> f
            | None ->
              float_of_string
                (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 5))
          in
          let expires_at =
            match Sqlite3.Data.to_float (Sqlite3.column stmt 6) with
            | Some f -> f
            | None ->
              float_of_string
                (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 6))
          in
          let revoked_at =
            match Sqlite3.column stmt 7 with
            | Sqlite3.Data.NULL -> None
            | d ->
              (match Sqlite3.Data.to_float d with
               | Some f -> Some f
               | None ->
                 (try Some (float_of_string (Sqlite3.Data.to_string_exn d))
                  with _ -> None))
          in
          let label =
            match Sqlite3.column stmt 8 with
            | Sqlite3.Data.NULL -> None
            | d ->
              (try Some (Sqlite3.Data.to_string_exn d) with _ -> None)
          in
          result :=
            Some
              {
                verifier;
                recipient_identity_fp = recipient_fp;
                delivery_alias;
                sender_fp;
                scope;
                generation;
                created_at;
                expires_at;
                revoked_at;
                label;
              }
        end);
    !result

  let issue_contact_grant t ~recipient_identity_pk ~delivery_alias
      ~sender_identity_pk ~expires_at ?label ?now () =
    with_lock t (fun () ->
      let conn = t.db in
      let now = match now with Some n -> n | None -> Unix.gettimeofday () in
      if String.length recipient_identity_pk = 0
         || String.length sender_identity_pk = 0
         || delivery_alias = "" then
        Result.Error "contact_grant_invalid_args"
      else if expires_at <= now then
        Result.Error "contact_grant_expires_in_past"
      else
        try
          with_tx_immediate conn (fun () ->
            (* Owner binding: delivery_alias lease identity must match recipient. *)
            let lease_pk = ref None in
            with_stmt conn "SELECT identity_pk FROM secure_leases_v2 WHERE alias = ?" (fun stmt ->
              Sqlite3.bind_text stmt 1 delivery_alias |> ignore;
              if Sqlite3.step stmt = Rc.ROW then
                lease_pk := Some (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0)));
            (match !lease_pk with
             | None -> Result.Error "contact_grant_unknown_delivery_alias"
             | Some pk when pk = "" || pk <> recipient_identity_pk ->
               Result.Error "contact_grant_not_owner"
             | Some _ ->
            let recipient_fp = contact_fp_of_pk recipient_identity_pk in
            let sender_fp = contact_fp_of_pk sender_identity_pk in
            let generation =
              next_generation_for_recipient conn ~recipient_fp
            in
            let grant_secret = contact_random_secret () in
            let verifier = contact_sha256_raw grant_secret in
            insert_contact_grant_row conn ~verifier ~recipient_fp
              ~delivery_alias ~sender_fp ~generation ~created_at:now
              ~expires_at ~label;
            Result.Ok
              {
                grant_secret;
                grant_id = contact_grant_id_of_verifier verifier;
                expires_at;
                generation;
              }))
        with exn ->
          Result.Error ("contact_grant_issue_failed: " ^ Printexc.to_string exn))

  let list_contact_grants t ~recipient_identity_pk =
    with_lock t (fun () ->
      let conn = t.db in
      let recipient_fp = contact_fp_of_pk recipient_identity_pk in
      let acc = ref [] in
      with_stmt conn
        "SELECT verifier, delivery_alias, sender_fp, generation, expires_at,
                revoked_at, label
           FROM contact_grants WHERE recipient_identity_fp = ?"
        (fun stmt ->
          Sqlite3.bind_blob stmt 1 recipient_fp |> ignore;
          let rec loop () =
            let rc = Sqlite3.step stmt in
            if rc = Rc.ROW then begin
              let verifier =
                Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0)
              in
              let delivery_alias =
                Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1)
              in
              let sender_fp =
                Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2)
              in
              let generation =
                match Sqlite3.Data.to_int (Sqlite3.column stmt 3) with
                | Some i -> i
                | None ->
                  int_of_string
                    (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 3))
              in
              let expires_at =
                match Sqlite3.Data.to_float (Sqlite3.column stmt 4) with
                | Some f -> f
                | None ->
                  float_of_string
                    (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 4))
              in
              let revoked_at =
                match Sqlite3.column stmt 5 with
                | Sqlite3.Data.NULL -> None
                | d ->
                  (match Sqlite3.Data.to_float d with
                   | Some f -> Some f
                   | None ->
                     (try Some (float_of_string (Sqlite3.Data.to_string_exn d))
                      with _ -> None))
              in
              let label =
                match Sqlite3.column stmt 6 with
                | Sqlite3.Data.NULL -> None
                | d ->
                  (try Some (Sqlite3.Data.to_string_exn d) with _ -> None)
              in
              acc :=
                {
                  grant_id = contact_grant_id_of_verifier verifier;
                  sender_fp_prefix = contact_sender_fp_prefix sender_fp;
                  delivery_alias;
                  expires_at;
                  revoked_at;
                  generation;
                  label;
                }
                :: !acc;
              loop ()
            end
          in
          loop ());
      !acc)

  let revoke_contact_grant t ~recipient_identity_pk ~grant_id ?now () =
    with_lock t (fun () ->
      let conn = t.db in
      let now = match now with Some n -> n | None -> Unix.gettimeofday () in
      match contact_decode_grant_id grant_id with
      | None -> Result.Error "contact_grant_not_found"
      | Some verifier ->
        try
          with_tx_immediate conn (fun () ->
            match load_grant_by_verifier conn ~verifier with
            | None -> Result.Error "contact_grant_not_found"
            | Some g ->
              let recipient_fp = contact_fp_of_pk recipient_identity_pk in
              if g.recipient_identity_fp <> recipient_fp then
                Result.Error "contact_grant_not_owner"
              else begin
                with_stmt conn
                  "UPDATE contact_grants SET revoked_at = ?
                    WHERE verifier = ? AND revoked_at IS NULL"
                  (fun stmt ->
                    Sqlite3.bind_double stmt 1 now |> ignore;
                    Sqlite3.bind_blob stmt 2 verifier |> ignore;
                    let rc = Sqlite3.step stmt in
                    if rc <> Rc.DONE then
                      failwith
                        ("revoke contact_grant failed: " ^ Rc.to_string rc));
                Result.Ok ()
              end)
        with exn ->
          Result.Error
            ("contact_grant_revoke_failed: " ^ Printexc.to_string exn))

  let rotate_contact_grant t ~recipient_identity_pk ~grant_id
      ~sender_identity_pk ~expires_at ?label ?now () =
    with_lock t (fun () ->
      let conn = t.db in
      let now = match now with Some n -> n | None -> Unix.gettimeofday () in
      match contact_decode_grant_id grant_id with
      | None -> Result.Error "contact_grant_not_found"
      | Some old_verifier ->
        if String.length sender_identity_pk = 0 then
          Result.Error "contact_grant_invalid_args"
        else if expires_at <= now then
          Result.Error "contact_grant_expires_in_past"
        else
          try
            with_tx_immediate conn (fun () ->
              match load_grant_by_verifier conn ~verifier:old_verifier with
              | None -> Result.Error "contact_grant_not_found"
              | Some old ->
                let recipient_fp = contact_fp_of_pk recipient_identity_pk in
                if old.recipient_identity_fp <> recipient_fp then
                  Result.Error "contact_grant_not_owner"
                else begin
                  with_stmt conn
                    "UPDATE contact_grants SET revoked_at = ?
                      WHERE verifier = ? AND revoked_at IS NULL"
                    (fun stmt ->
                      Sqlite3.bind_double stmt 1 now |> ignore;
                      Sqlite3.bind_blob stmt 2 old_verifier |> ignore;
                      let rc = Sqlite3.step stmt in
                      if rc <> Rc.DONE then
                        failwith
                          ("rotate revoke failed: " ^ Rc.to_string rc));
                  let generation =
                    next_generation_for_recipient conn ~recipient_fp
                  in
                  let grant_secret = contact_random_secret () in
                  let verifier = contact_sha256_raw grant_secret in
                  let label =
                    match label with Some l -> Some l | None -> old.label
                  in
                  insert_contact_grant_row conn ~verifier ~recipient_fp
                    ~delivery_alias:old.delivery_alias
                    ~sender_fp:(contact_fp_of_pk sender_identity_pk)
                    ~generation ~created_at:now ~expires_at ~label;
                  Result.Ok
                    {
                      grant_secret;
                      grant_id = contact_grant_id_of_verifier verifier;
                      expires_at;
                      generation;
                    }
                end)
          with exn ->
            Result.Error
              ("contact_grant_rotate_failed: " ^ Printexc.to_string exn))

  let admit_contact_delivery t ~verified_sender_alias
      ~verified_sender_identity_pk ~grant_secret ~message_id ~content
      ?now () =
    with_lock t (fun () ->
      let conn = t.db in
      let now = match now with Some n -> n | None -> Unix.gettimeofday () in
      if String.length grant_secret <> 32 || message_id = "" then `Rejected
      else
        let verifier = contact_sha256_raw grant_secret in
        try
          with_tx_immediate conn (fun () ->
            match load_grant_by_verifier conn ~verifier with
            | None -> `Rejected
            | Some g ->
              (match g.revoked_at with
               | Some _ -> `Rejected
               | None when now >= g.expires_at -> `Rejected
               | None when g.scope <> contact_scope_v1 -> `Rejected
               | None ->
                 let sender_fp =
                   contact_fp_of_pk verified_sender_identity_pk
                 in
                 if sender_fp <> g.sender_fp then `Rejected
                 else begin
                   (* Idempotency first: existing (verifier, message_id). *)
                   let prior = ref None in
                   with_stmt conn
                     "SELECT accepted_at FROM contact_grant_message_ids
                       WHERE verifier = ? AND message_id = ?"
                     (fun stmt ->
                       Sqlite3.bind_blob stmt 1 verifier |> ignore;
                       Sqlite3.bind_text stmt 2 message_id |> ignore;
                       let rc = Sqlite3.step stmt in
                       if rc = Rc.ROW then
                         prior :=
                           (match Sqlite3.Data.to_float (Sqlite3.column stmt 0) with
                            | Some f -> Some f
                            | None ->
                              (try
                                 Some
                                   (float_of_string
                                      (Sqlite3.Data.to_string_exn
                                         (Sqlite3.column stmt 0)))
                               with _ -> None)));
                   match !prior with
                   | Some ts -> `Duplicate (ts, g.delivery_alias)
                   | None ->
                     let lease_info = ref None in
                     with_stmt conn
                       "SELECT node_id, session_id, last_seen, ttl, identity_pk
                          FROM secure_leases_v2 WHERE alias = ?"
                       (fun stmt ->
                         Sqlite3.bind_text stmt 1 g.delivery_alias |> ignore;
                         let rc = Sqlite3.step stmt in
                         if rc = Rc.ROW then begin
                           let node_id =
                             Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0)
                           in
                           let session_id =
                             Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1)
                           in
                           let last_seen =
                             match Sqlite3.Data.to_float (Sqlite3.column stmt 2) with
                             | Some f -> f
                             | None ->
                               float_of_string
                                 (Sqlite3.Data.to_string_exn
                                    (Sqlite3.column stmt 2))
                           in
                           let ttl =
                             match Sqlite3.Data.to_float (Sqlite3.column stmt 3) with
                             | Some f -> f
                             | None ->
                               float_of_string
                                 (Sqlite3.Data.to_string_exn
                                    (Sqlite3.column stmt 3))
                           in
                           let identity_pk =
                             match Sqlite3.column stmt 4 with
                             | Sqlite3.Data.NULL -> ""
                             | d ->
                               (try Sqlite3.Data.to_string_exn d with _ -> "")
                           in
                           lease_info :=
                             Some (node_id, session_id, last_seen, ttl, identity_pk)
                         end);
                     match !lease_info with
                     | None -> `Rejected
                     | Some (node_id, session_id, last_seen, ttl, identity_pk) ->
                       if alias_released ~now ~last_seen then `Rejected
                       else if last_seen +. ttl < now then `Rejected
                       else if identity_pk = ""
                               || contact_fp_of_pk identity_pk
                                  <> g.recipient_identity_fp
                       then `Rejected
                       else begin
                         with_stmt conn
                           "INSERT INTO inboxes
                              (node_id, session_id, message_id, from_alias,
                               to_alias, content, ts, pow_difficulty)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
                           (fun ins ->
                             Sqlite3.bind_text ins 1 node_id |> ignore;
                             Sqlite3.bind_text ins 2 session_id |> ignore;
                             Sqlite3.bind_text ins 3 message_id |> ignore;
                             Sqlite3.bind_text ins 4 verified_sender_alias
                             |> ignore;
                             Sqlite3.bind_text ins 5 g.delivery_alias |> ignore;
                             Sqlite3.bind_text ins 6 content |> ignore;
                             Sqlite3.bind_double ins 7 now |> ignore;
                             Sqlite3.bind_int ins 8 (-1) |> ignore;
                             let rc = Sqlite3.step ins in
                             if rc <> Rc.DONE then
                               failwith
                                 ("admit inbox insert failed: "
                                  ^ Rc.to_string rc));
                         with_stmt conn
                           "INSERT INTO contact_grant_message_ids
                              (verifier, message_id, accepted_at)
                            VALUES (?, ?, ?)"
                           (fun mid ->
                             Sqlite3.bind_blob mid 1 verifier |> ignore;
                             Sqlite3.bind_text mid 2 message_id |> ignore;
                             Sqlite3.bind_double mid 3 now |> ignore;
                             let rc = Sqlite3.step mid in
                             if rc <> Rc.DONE then
                               failwith
                                 ("admit mid insert failed: "
                                  ^ Rc.to_string rc));
                         `Accepted (now, g.delivery_alias)
                       end
                 end))
        with _ -> `Rejected)

  let peer_discovery_visibility_of t ~alias =
    let alias, _ = normalize_relay_alias ~alias ~opaque_host_id:None in
    with_lock t (fun () ->
      let conn = t.db in
      let result = ref None in
      with_stmt conn
        "SELECT discovery_visibility FROM secure_leases_v2 WHERE alias = ?" (fun stmt ->
        Sqlite3.bind_text stmt 1 alias |> ignore;
        if Sqlite3.step stmt = Rc.ROW then
          let raw =
            try Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0)
            with _ -> "private"
          in
          result := Some (if raw = "public" then Public else Private));
      !result)

  let set_peer_discovery_visibility t ~alias ~visibility =
    let alias, _ = normalize_relay_alias ~alias ~opaque_host_id:None in
    with_lock t (fun () ->
      let conn = t.db in
      let vis =
        match visibility with Private -> "private" | Public -> "public"
      in
      (* Do not use changes()>0: setting the same value yields 0 changes. *)
      let exists = ref false in
      with_stmt conn "SELECT 1 FROM secure_leases_v2 WHERE alias = ?" (fun stmt ->
        Sqlite3.bind_text stmt 1 alias |> ignore;
        if Sqlite3.step stmt = Rc.ROW then exists := true);
      if not !exists then Result.Error "unknown_alias"
      else begin
        with_stmt conn
          "UPDATE secure_leases_v2 SET discovery_visibility = ? WHERE alias = ?" (fun stmt ->
          Sqlite3.bind_text stmt 1 vis |> ignore;
          Sqlite3.bind_text stmt 2 alias |> ignore;
          let rc = Sqlite3.step stmt in
          if rc <> Rc.DONE then
            failwith ("set discovery_visibility failed: " ^ Rc.to_string rc));
        Result.Ok ()
      end)

  let is_public_discovery_unlocked conn ~alias =
    let is_public = ref false in
    with_stmt conn
      "SELECT discovery_visibility FROM secure_leases_v2 WHERE alias = ?" (fun stmt ->
      Sqlite3.bind_text stmt 1 alias |> ignore;
      if Sqlite3.step stmt = Rc.ROW then
        let raw =
          try Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0)
          with _ -> "private"
        in
        is_public := (raw = "public"));
    !is_public

  let peer_identity_pk_of t ~alias =
    with_lock t (fun () ->
      if not (is_public_discovery_unlocked t.db ~alias) then None
      else
        (* re-open via already-locked helpers: call identity path inline *)
        let now = Unix.gettimeofday () in
        let result = ref None in
        with_stmt t.db
          "SELECT identity_pk, last_seen, ttl FROM secure_leases_v2 WHERE alias = ?"
          (fun stmt ->
            Sqlite3.bind_text stmt 1 alias |> ignore;
            if Sqlite3.step stmt = Rc.ROW then begin
              let pk = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
              let last_seen =
                match Sqlite3.Data.to_float (Sqlite3.column stmt 1) with
                | Some f -> f
                | None ->
                  float_of_string
                    (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1))
              in
              let ttl =
                match Sqlite3.Data.to_float (Sqlite3.column stmt 2) with
                | Some f -> f
                | None ->
                  float_of_string
                    (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2))
              in
              if not (alias_released ~now ~last_seen) && pk <> "" then
                result := Some pk
            end);
        !result)

  let peer_enc_pubkey_of t ~alias =
    with_lock t (fun () ->
      if not (is_public_discovery_unlocked t.db ~alias) then None
      else
        let result = ref None in
        with_stmt t.db "SELECT enc_pubkey FROM secure_leases_v2 WHERE alias = ?" (fun stmt ->
          Sqlite3.bind_text stmt 1 alias |> ignore;
          if Sqlite3.step stmt = Rc.ROW then
            let ek = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
            if ek <> "" then result := Some ek);
        !result)

  let peer_signed_at_of t ~alias =
    with_lock t (fun () ->
      if not (is_public_discovery_unlocked t.db ~alias) then None
      else
        let result = ref None in
        with_stmt t.db "SELECT signed_at FROM secure_leases_v2 WHERE alias = ?" (fun stmt ->
          Sqlite3.bind_text stmt 1 alias |> ignore;
          if Sqlite3.step stmt = Rc.ROW then
            match Sqlite3.Data.to_float (Sqlite3.column stmt 0) with
            | Some f when f <> 0.0 -> result := Some f
            | _ -> ());
        !result)

  let peer_sig_b64_of t ~alias =
    with_lock t (fun () ->
      if not (is_public_discovery_unlocked t.db ~alias) then None
      else
        let result = ref None in
        with_stmt t.db "SELECT sig_b64 FROM secure_leases_v2 WHERE alias = ?" (fun stmt ->
          Sqlite3.bind_text stmt 1 alias |> ignore;
          if Sqlite3.step stmt = Rc.ROW then
            let s = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
            if s <> "" then result := Some s);
        !result)

  let private_reachability_mode _t = "consent_gated"

end

(* --- Relay_server HTTP layer (functor over RELAY backend) --- *)

(* Instantiate rate limiter once at module level — avoids fresh-type-in-functor issue. *)
module Rate_limiter_inst = Relay_ratelimit.Make()

(* B216: resolve the git hash reported by /health. Pure given its inputs so
   the precedence (RAILWAY_GIT_COMMIT_SHA truncated to 7 chars > git fallback >
   "unknown") is unit-testable. Preserves the exact behaviour that
   handle_health used to inline per-request. *)
let resolve_git_hash ~railway_sha ~git_fallback =
  match railway_sha with
  | Some sha when String.length sha >= 7 -> String.sub sha 0 7
  | _ ->
    (match git_fallback () with
     | Some s -> s
     | None -> "unknown")

(* B216: memoize the git hash ONCE at boot instead of forking
   `git rev-parse` on every /health request. The value cannot change over
   the life of the process (env is fixed; .git is absent in the Docker
   image), so a single lazy force is safe and preserves the prior value. *)
let git_hash_memo = lazy (
  resolve_git_hash
    ~railway_sha:(Sys.getenv_opt "RAILWAY_GIT_COMMIT_SHA")
    ~git_fallback:(fun () ->
      try
        let ic = Unix.open_process_in "git rev-parse --short HEAD 2>/dev/null" in
        let line = input_line ic in
        ignore (Unix.close_process_in ic);
        Some (String.trim line)
      with _ -> None))

(* --- B219: relay serve-path instrumentation (diagnostics only) --- *)

(* Heartbeat cadence: one concise line every 60s so a death is preceded by a
   resource trend (memory / connection count) in the logs. *)
let heartbeat_interval_s = 60.

(* Default ON; set C2C_RELAY_HEARTBEAT_LOG to 0/false/no/off to silence. *)
let heartbeat_enabled () =
  match Sys.getenv_opt "C2C_RELAY_HEARTBEAT_LOG" with
  | Some ("0" | "false" | "no" | "off" | "FALSE" | "No" | "Off" | "OFF") -> false
  | _ -> true

(* Coarse resident-set size in KiB from /proc/self/statm (field 2 = resident
   pages). Linux-only; returns None off Linux or on any read error. *)
let heartbeat_rss_kb () =
  try
    let ic = open_in "/proc/self/statm" in
    let line = input_line ic in
    close_in ic;
    match String.split_on_char ' ' line with
    | _size :: resident :: _ ->
      (match int_of_string_opt resident with
       | Some pages -> Some (pages * 4) (* coarse: assume 4 KiB pages *)
       | None -> None)
    | _ -> None
  with _ -> None

(* Pure heartbeat-line formatter (B219) so its shape is unit-testable. *)
let format_heartbeat_line ~uptime_s ~peer_count ~heap_words ~rss_kb =
  let rss_str = match rss_kb with Some kb -> string_of_int kb | None -> "?" in
  Printf.sprintf
    "[relay] heartbeat uptime=%.0fs peers=%d gc_heap_words=%d gc_heap_kb=%d rss_kb=%s"
    uptime_s peer_count heap_words (heap_words * (Sys.word_size / 8) / 1024) rss_str

module Relay_server(R : RELAY) : sig
  val make_callback :
    R.t ->
    string option ->
    Conduit_lwt_unix.flow ->
    Cohttp.Request.t ->
    Cohttp_lwt.Body.t ->
    ?broker_root:string option ->
    native_tls:bool ->
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

  exception Ws_subscribe_upgrade of string * string
  include Relay_server_json
  include Relay_server_response
  include Relay_server_html

  (* Error codes *)
  let err_bad_request = "bad_request"
  let err_not_found = "not_found"
  let err_internal_error = "internal_error"
  (* B265: uniform denial for private legacy send + contact deliver rejects. *)
  let err_contact_unauthorised = "contact_unauthorised"

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


  let handle_health ~auth_mode ~private_reachability () =
    (* B216: read the once-memoized git hash instead of forking
       `git rev-parse` per request. Precedence unchanged: RAILWAY_GIT_COMMIT_SHA
       (7-char prefix) > `git rev-parse --short HEAD` > "unknown". *)
    let git_hash = Lazy.force git_hash_memo in
    let pow_enabled = relay_pow_enabled () in
    let pow_header =
      issue_pow_header ~route:"health" ~actor_id:"" ~difficulty:0
    in
    let dev_mode = auth_mode = "dev" in
    respond_ok ~headers:[pow_header] (json_ok [
      ("version", `String Version.version);
      ("git_hash", `String git_hash);
      (* B121: wire protocol negotiation. Clients compare these against
         Version.relay_protocol_version and surface an upgrade message
         when the numbers diverge instead of opaque auth/HTTP errors. *)
      ("protocol_version", `Int Version.relay_protocol_version);
      ("min_client_protocol_version",
       `Int Version.relay_min_client_protocol_version);
      ("auth_mode", `String auth_mode);
      (* B265/B266: contact grant protocol card (c2c-contact/1). *)
      ("contact_protocol", `Int 1);
      (* B266: only durable SQLite backends claim consent_gated. *)
      ("private_reachability", `String private_reachability);
      ("dev_mode", `Bool dev_mode);
      ("production_claims",
       `Bool (auth_mode = "prod" && private_reachability = "consent_gated"));
      ("pow", `Assoc [
        ("enabled", `Bool pow_enabled);
        ("scheme", `String Pow.scheme_id);
      ]);
    ])

  let handle_list relay ~include_dead =
    (* include_dead is the Bearer-admin directory path; include private leases. *)
    let peers =
      (if include_dead then R.list_peers_admin relay ~include_dead
       else R.list_peers relay ~include_dead)
      |> List.map RegistrationLease.to_json
    in
    respond_ok (json_ok [ ("peers", `List peers) ])

  let handle_pubkey relay ~broker_root ~alias =
    if not (C2c_name.is_valid alias) then
      respond_bad_request (json_error_str err_bad_request ("invalid alias format: " ^ alias))
    else
      (* B264: peer-facing lookup; private aliases must look like unknown. *)
      let identity_pk = R.peer_identity_pk_of relay ~alias in
      let enc_pubkey = R.peer_enc_pubkey_of relay ~alias in
      let signed_at = R.peer_signed_at_of relay ~alias in
      let sig_b64 = R.peer_sig_b64_of relay ~alias in
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

  (* B230: when the request carries a verified Ed25519 identity, pass that
     alias so unlisted rooms the caller is a member of appear in the
     directory. Anonymous callers still only see public + gated. Invalid
     signatures on this anonymous-read route degrade to anonymous listing
     (same soft-auth posture as /room_history). *)
  let handle_list_rooms relay ~verified_alias =
    let rooms = match verified_alias with
      | Some alias -> R.list_rooms ~for_alias:alias relay
      | None -> R.list_rooms relay
    in
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

  (* B147: normalize an alias for stats uniqueness — strip a valid opaque
     host suffix (`name@<12-16 hex>`) down to the bare name; anything else
     (including cross-relay `name@host` forms) stays as-is, a distinct
     identity from this relay's viewpoint. *)
  let stats_alias_key alias =
    if C2c_name.is_valid_with_opaque_host_id alias
    then fst (C2c_name.split_opaque_host_id alias)
    else alias

  (* B147: public usage stats — aggregate counts only; no aliases, machine
     ids, or message content are exposed. *)
  let handle_stats relay =
    let now = Unix.gettimeofday () in
    let generated_at = now in
    (* B148: [generated_ago] is computed dynamically from [now -. generated_at]
       at serve time. It reads "just now" for live serving (generated_at = now),
       and future-proofs cached/snapshot serving + helps humans reading saved
       JSON dumps. *)
    respond_ok (json_ok [
      ("generated_at", `Float generated_at);
      ("generated_ago", `String (Relay_common.humanize_ago (now -. generated_at)));
      ("stats", R.stats relay ~now);
    ])

  let handle_register relay ~relay_url ~token body =
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
      (* B149: client-reported connection metadata. These land as keys in the
         public /stats connected.by_version / by_os count maps, so clamp them:
         trim, drop non-printable chars, cap length. Absent/empty → "" (older
         clients), which /stats buckets as "unknown". *)
      let clamp_meta s =
        let s = String.trim s in
        let b = Buffer.create (String.length s) in
        String.iter (fun c -> if c >= ' ' && c <> '\x7f' then Buffer.add_char b c) s;
        let s = Buffer.contents b in
        if String.length s > 48 then String.sub s 0 48 else s
      in
      let client_version =
        get_opt_string body "client_version" |> Option.value ~default:"" |> clamp_meta in
      let client_os =
        get_opt_string body "client_os" |> Option.value ~default:"" |> clamp_meta in
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
      else if (pow_enabled || token <> None) && not has_proof_fields then
        (* B267 review: token-configured (prod) relays must not accept unsigned
           registration — it is a private-alias existence oracle and blocks
           victims from claiming their alias. PoW still forces proofs too. *)
        respond_register_bad_request (json_error_str relay_err_missing_proof_field
          "identity_pk, signature, nonce, and timestamp are required on a token-configured relay (or when C2C_RELAY_POW=1)")
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
                        ~client_type ~client_version ~client_os ~ttl ~identity_pk ~enc_pubkey:enc_pubkey_b64 ~signed_at ~sig_b64:sig_b64
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
                    (if fst result = "ok" then
                       let lease = snd result in
                       let machine_id = stats_machine_id_of_lease lease in
                       R.stats_note_activity relay ~machine_id
                         ~retire_key:node_id
                         ~alias:(stats_alias_key alias) ~ts:(Unix.gettimeofday ()) ());
                    respond_register_ok ~difficulty (json_of_register_result ~receipt result)
      else
        (* Legacy path — no identity_pk supplied, behaves exactly as before. *)
        let result =
          R.register relay ~node_id ~session_id ~alias ~client_type ~client_version ~client_os ~ttl ~enc_pubkey:enc_pubkey_b64 ~signed_at ~sig_b64:sig_b64
            ~opaque_host_id:opaque_host_id ()
        in
        let difficulty = finish_register_result result in
        (if fst result = "ok" then
           let lease = snd result in
           let machine_id = stats_machine_id_of_lease lease in
           R.stats_note_activity relay ~machine_id
             ~retire_key:node_id
             ~alias:(stats_alias_key alias) ~ts:(Unix.gettimeofday ()) ());
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
    (* B174: optional host id heals leases that registered without one. *)
    let opaque_host_id =
      match get_opt_string body "opaque_host_id" with
      | Some s when C2c_name.is_opaque_host_id s -> s
      | Some s when s <> "" -> s
      | _ -> ""
    in
    if node_id = "" || session_id = "" then
      respond_bad_request (json_error_str err_bad_request "node_id and session_id are required")
    else
      let run_heartbeat () =
        let result =
          R.heartbeat relay ~node_id ~session_id ~opaque_host_id
        in
        (if fst result = "ok" then
           let lease = snd result in
           let machine_id = stats_machine_id_of_lease lease in
           R.stats_note_activity relay ~machine_id
             ~retire_key:node_id
             ~alias:(stats_alias_key (RegistrationLease.alias lease))
             ~ts:(Unix.gettimeofday ()) ());
        respond_ok (json_of_heartbeat_result result)
      in
      match verified_alias with
      | Some v ->
        (match R.alias_of_session relay ~node_id ~session_id with
         | Some owner when owner = v -> run_heartbeat ()
         | _ -> reject_session_mismatch ~verified:v ~node_id ~session_id)
      | None -> run_heartbeat ()

  let handle_contact_deliver relay ~verified_alias ~token ~confidential_transport body =
    (* B265: POST /contact/v1/deliver — recipient-issued grant admission.
       Tokenless (dev) relays refuse contact delivery (B262 §13.3).
       Production contact delivery requires confidential transport (B262 §10):
       native TLS or trusted X-Forwarded-Proto=https/wss.
       Side effects only on `Accepted (not Duplicate/Rejected).
       G6: all admission denials share one external shape (contact_unauthorised)
       — no distinct messages for unknown/malformed/expired/revoked/dev/protocol. *)
    let deny () =
      respond_unauthorized
        (json_error_str err_contact_unauthorised "contact unauthorised")
    in
    if token = None then deny ()
    else if not confidential_transport then deny ()
    else
      match verified_alias with
      | None -> deny ()
      | Some from_alias ->
        let protocol = get_string body "protocol" in
        let grant_secret_b64 = get_string body "grant_secret" in
        let message_id = get_string body "message_id" in
        let content = get_string body "content" in
        if protocol <> "c2c-contact/1" || grant_secret_b64 = ""
           || message_id = "" || content = "" then deny ()
        else
          match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet grant_secret_b64 with
          | Error _ -> deny ()
          | Ok grant_secret when String.length grant_secret <> 32 -> deny ()
          | Ok grant_secret ->
            match R.identity_pk_of relay ~alias:from_alias with
            | None -> deny ()
            | Some sender_pk ->
              match
                R.admit_contact_delivery relay
                  ~verified_sender_alias:from_alias
                  ~verified_sender_identity_pk:sender_pk
                  ~grant_secret ~message_id ~content ()
              with
              | `Rejected -> deny ()
              | `Duplicate (ts, _delivery_alias) ->
                (* No second side effects (stricter than legacy /send). *)
                respond_ok
                  (`Assoc
                     [ ("ok", `Bool true);
                       ("duplicate", `Bool true);
                       ("ts", `Float ts) ])
              | `Accepted (ts, delivery_alias) ->
                R.stats_note_message relay
                  ~from_alias:(stats_alias_key from_alias) ~ts;
                (* G1 authorised path: push WS / short-queue / observer once. *)
                Relay_ws_server.push_dm ~to_alias:delivery_alias ~from_alias
                  ~body:content ~ts;
                (match R.identity_pk_of relay ~alias:delivery_alias with
                 | Some identity_pk ->
                   (match
                      binding_id_of_phone_pk ~phone_ed25519_pubkey:identity_pk
                    with
                    | Some binding_id ->
                      let sq_msg =
                        {
                          Relay_short_queue.ts;
                          from_alias;
                          to_alias = delivery_alias;
                          room_id = None;
                          content;
                        }
                      in
                      Relay_short_queue.ShortQueue.push short_queue ~binding_id
                        sq_msg;
                      push_to_observers ~binding_id sq_msg
                    | None -> ())
                 | None -> ());
                respond_ok (`Assoc [ ("ok", `Bool true); ("ts", `Float ts) ])

  (* G1 / B267: forward-path failures must not store message content.
     Private-destination rejects and peer 4xx would otherwise content-DLQ
     a guessed private alias without a grant. *)
  let forward_out_dead_letter ~ts ~message_id ~from_alias ~to_alias ~reason
      ~phase ?peer () =
    let base =
      [ ("ts", `Float ts);
        ("message_id", `String message_id);
        ("from_alias", `String from_alias);
        ("to_alias", `String to_alias);
        ("content", `String "");
        ("content_redacted", `Bool true);
        ("reason", `String reason);
        ("phase", `String phase);
      ]
    in
    match peer with
    | Some p -> `Assoc (base @ [ ("peer", `String p) ])
    | None -> `Assoc base

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
             let dl =
               forward_out_dead_letter ~ts ~message_id:msg_id ~from_alias
                 ~to_alias ~reason:"cross_host_not_implemented"
                 ~phase:"forward_out" ()
             in
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
                     let dl =
                       forward_out_dead_letter
                         ~ts:(Unix.gettimeofday ()) ~message_id:msg_id
                         ~from_alias ~to_alias ~reason:"peer_unreachable"
                         ~phase:"forward_out" ~peer:peer_name ()
                     in
                     R.add_dead_letter relay dl;
                     respond_bad_gateway
                       (json_error_str "peer_unreachable"
                          (Printf.sprintf "peer relay %s unreachable: %s" peer_name reason))
                 | Peer_timeout ->
                     let dl =
                       forward_out_dead_letter
                         ~ts:(Unix.gettimeofday ()) ~message_id:msg_id
                         ~from_alias ~to_alias ~reason:"peer_timeout"
                         ~phase:"forward_out" ~peer:peer_name ()
                     in
                     R.add_dead_letter relay dl;
                     respond_gateway_timeout
                       (json_error_str "peer_timeout"
                          (Printf.sprintf "peer relay %s did not respond within 5s" peer_name))
                 | Peer_5xx (st, body_excerpt) ->
                     let dl =
                       forward_out_dead_letter
                         ~ts:(Unix.gettimeofday ()) ~message_id:msg_id
                         ~from_alias ~to_alias ~reason:"peer_5xx"
                         ~phase:"forward_out" ~peer:peer_name ()
                     in
                     R.add_dead_letter relay dl;
                     respond_bad_gateway
                       (json_error_str "peer_5xx"
                          (Printf.sprintf "peer relay %s returned %d: %s" peer_name st body_excerpt))
                 | Peer_4xx (st, body_excerpt) ->
                     let dl =
                       forward_out_dead_letter
                         ~ts:(Unix.gettimeofday ()) ~message_id:msg_id
                         ~from_alias ~to_alias ~reason:"peer_rejected"
                         ~phase:"forward_out" ~peer:peer_name ()
                     in
                     R.add_dead_letter relay dl;
                     respond_not_found
                       (json_error_str "peer_rejected"
                          (Printf.sprintf "peer relay %s rejected request %d: %s" peer_name st body_excerpt))
                 | Peer_unauthorized ->
                     let dl =
                       forward_out_dead_letter
                         ~ts:(Unix.gettimeofday ()) ~message_id:msg_id
                         ~from_alias ~to_alias ~reason:"peer_unauthorized"
                         ~phase:"forward_out" ~peer:peer_name ()
                     in
                     R.add_dead_letter relay dl;
                     respond_bad_gateway
                       (json_error_str "peer_unauthorized"
                          (Printf.sprintf "peer relay %s did not accept our identity" peer_name))
                 | Local_error err ->
                     let dl =
                       forward_out_dead_letter
                         ~ts:(Unix.gettimeofday ()) ~message_id:msg_id
                         ~from_alias ~to_alias ~reason:"forward_local_error"
                         ~phase:"forward_out" ~peer:peer_name ()
                     in
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
        (* B014: record the sender's current PoW difficulty (leading-zero bits)
           as sibling metadata on the delivered message. The policy keys cost by
           identity pubkey (b64url, same normalization as the register handler),
           so resolve the sender's pubkey via the lease table. Sentinel -1 when
           relay PoW is off or the sender's identity is unresolved — such
           messages carry no [pow] object on delivery. Read-only: we do NOT
           accrue send-route cost here (no [record_route]). *)
        let pow_difficulty =
          let sender_actor_id =
            match R.identity_pk_of relay ~alias:from_alias with
            | Some pk when String.length pk = 32 -> b64url_nopad_encode pk
            | _ -> ""
          in
          if relay_pow_enabled () && sender_actor_id <> "" then
            pow_difficulty_for_actor ~enabled:true ~actor_id:sender_actor_id
          else Relay_pow_challenge.pow_difficulty_unrecorded
        in
        let result = R.send relay ~from_alias ~to_alias:deliver_to_alias ~content ~pow_difficulty ~message_id in
        (* B147: count relay-accepted DMs (duplicate replays excluded). *)
        (match result with
         | `Ok ts ->
           R.stats_note_message relay ~from_alias:(stats_alias_key from_alias) ~ts
         | _ -> ());
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
        (match result with
         | `Error (code, _) when code = relay_err_unknown_alias ->
           respond_unauthorized
             (json_error_str err_contact_unauthorised "contact unauthorised")
         | _ -> respond_ok (json_of_send_result result))

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
          (* B147: a broadcast counts as one message, not one per recipient.
             B267: private-only targets yield delivered=[]; do not bump stats
             (G1 — no side effect without a successful public delivery). *)
          (if delivered <> [] then
             R.stats_note_message relay ~from_alias:(stats_alias_key from_alias) ~ts);
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
                        let pk_fp =
                          Relay_identity.fingerprint_of_pk peer_relay.identity_pk
                        in
                        respond_unauthorized (json_error_str relay_err_signature_invalid
                          (Printf.sprintf
                             "Ed25519 request signature does not verify \
(alias=%s, bound_pk=%s, meth=POST, path=/forward)"
                             claimed_alias pk_fp))
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
                            (* B014: forwarded-in from a peer relay — the origin
                               relay's PoW difficulty is not available here, so
                               record -1 (unrecorded). *)
                            match R.send relay ~from_alias ~to_alias ~content ~message_id ~pow_difficulty:(-1) with
                            | `Ok ts ->
                              (* B147: forwarded-in messages delivered locally
                                 count as messages on this relay. *)
                              R.stats_note_message relay
                                ~from_alias:(stats_alias_key from_alias) ~ts;
                              respond_ok (`Assoc ["ok", `Bool true; "ts", `Float ts])
                            | `Duplicate ts ->
                              respond_ok (`Assoc ["ok", `Bool true; "ts", `Float ts; "duplicate", `Bool true])
                            | `Error (code, _)
                              when code = relay_err_unknown_alias ->
                              respond_unauthorized
                                (json_error_str err_contact_unauthorised
                                   "contact unauthorised")
                            | `Error (code, msg) ->
                              respond_bad_request (json_error_str code msg)
                    end
                  end
                end
            end
      end

  (* B115: /poll_inbox and /peek_inbox expose inbox contents, so they are
     bound to a verified owner. [require_owner] is computed at the dispatch
     site via [inbox_owner_required]: always true on a token-configured
     (prod) relay, and true BY DEFAULT on a tokenless relay too — a
     production deploy whose token secret goes missing therefore fails
     closed for inbox reads instead of silently reopening the B111 drain.
     The legacy unauthenticated path exists only behind the explicit
     development-only setting [C2C_RELAY_ALLOW_UNSIGNED_INBOX=1], and even
     that is ignored when a token is configured (a prod relay can never be
     downgraded by env). When [require_owner] is true an unverified request
     is rejected here even if the outer route classifier ever regresses
     (defense in depth — auth_decision already refuses these routes without
     a verified Ed25519 header whenever a token is configured). *)
  let allow_unsigned_inbox_env = "C2C_RELAY_ALLOW_UNSIGNED_INBOX"

  let inbox_owner_required ~token_configured =
    token_configured
    || (match Sys.getenv_opt allow_unsigned_inbox_env with
        | Some ("1" | "true" | "TRUE" | "yes") -> false
        | Some _ | None -> true)

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

  (* Layer 4 slice 1 / B114: verify the signed proof on room mutations.
     [require_signed] comes from [require_signed_room_ops] (true whenever the
     relay is token-configured, and by default in dev mode too). Returns
     [Ok ()] when all proof fields are present and verify correctly, or when
     no proof fields are present AND [require_signed] is false (dev-gated
     legacy path). Returns [Error (code, msg)] for any partial/invalid/forged
     proof, and for absent proofs when [require_signed] is true. *)
  let verify_room_op_proof relay ?(extra_signed_fields = []) ~require_signed
      ~sign_ctx ~room_id ~alias body =
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
      if require_signed then
        Res.Error (relay_err_unsigned_room_op,
          "unsigned room op rejected; client must sign room ops "
          ^ "(legacy unsigned is dev-only: C2C_REQUIRE_SIGNED_ROOM_OPS=0 "
          ^ "on a relay with no Bearer token)")
      else
        (Logs.warn (fun m -> m "unsigned room op %s for %S accepted via dev gate (C2C_REQUIRE_SIGNED_ROOM_OPS=0, no token)" sign_ctx alias);
         Res.Ok ())  (* dev-gated legacy unsigned path — accept *)
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
                (* B114 (review finding 1): the proof only AUTHENTICATES the
                   alias if [identity_pk] is the key already bound to it. A
                   self-signed proof for an alias with no registered binding
                   is meaningless (any attacker key would "verify"), so an
                   absent binding is rejected — there is no first-proof TOFU
                   pinning. The alias must have registered a signed identity
                   first (register_signed binds the key). *)
                (match R.identity_pk_of relay ~alias with
                 | Some bound when bound <> identity_pk ->
                   Error (relay_err_alias_identity_mismatch,
                     "identity_pk does not match registered binding")
                 | None ->
                   Error (relay_err_alias_identity_mismatch,
                     "alias has no registered identity binding; register a \
                      signed identity before signing room ops")
                 | Some _ ->
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

  let handle_join_room relay ~require_signed body =
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
    else if not (valid_relay_room_id room_id) then
      (* B118: enforce the canonical room-id grammar ([A-Za-z0-9_-], no `#`/`@`)
         at the room-op boundary — matches the local broker's valid_room_id.
         This keeps the anonymous /list_rooms directory address
         (alias#room@relay) unambiguous: an out-of-grammar room id could
         otherwise inject an extra `#`/`@` delimiter that defeats the
         recipient parser. *)
      respond_bad_request (json_error_str err_bad_request
        "room_id must match [A-Za-z0-9_-] and be non-empty")
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
      match verify_room_op_proof relay ~require_signed ~sign_ctx:room_join_sign_ctx
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
  let handle_set_room_visibility relay ~require_signed body =
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
      match verify_room_op_proof relay ~require_signed
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
            (* B117: report the effective history_public after the change
               (a downgrade to gated/private atomically clears it). *)
            ("history_public", `Bool (R.history_public_of relay ~room_id));
          ])
        end

  (* B117 — set_room_history_public. Signed by any existing room member. The
     boolean is bound into the canonical signed bytes (extra_signed_fields), so
     an intermediary cannot flip it. gated/private rooms must always be
     member-only: a request to set true on such a room is rejected. *)
  let handle_set_room_history_public relay ~require_signed body =
    let alias = get_string body "alias" in
    let room_id = get_string body "room_id" in
    match get_opt_bool body "history_public" with
    | None ->
      respond_bad_request (json_error_str err_bad_request
        "history_public (boolean) is required")
    | Some history_public ->
    if alias = "" || room_id = "" then
      respond_bad_request (json_error_str err_bad_request
        "alias and room_id are required")
    else
      let hp_str = if history_public then "true" else "false" in
      match verify_room_op_proof relay ~require_signed
              ~sign_ctx:room_set_history_public_sign_ctx
              ~extra_signed_fields:[ hp_str ]
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
          let visibility = R.room_visibility_of relay ~room_id in
          let is_listed_open = visibility = "public" || visibility = "unlisted" in
          if history_public && not is_listed_open then
            respond_bad_request (json_error_str relay_err_history_public_gated
              (Printf.sprintf
                 "room %S is %s; history_public can only be true for public or unlisted rooms"
                 room_id visibility))
          else begin
            R.set_room_history_public relay ~room_id ~history_public;
            respond_ok (`Assoc [
              ("ok", `Bool true);
              ("room_id", `String room_id);
              ("history_public", `Bool history_public);
            ])
          end

  (* L4/5 — invite / uninvite. Signed by any existing room member. *)
  let handle_room_invite_op relay ~require_signed ~sign_ctx ~op body =
    let alias = get_string body "alias" in
    let room_id = get_string body "room_id" in
    let target_pk = get_string body "invitee_pk" in
    if alias = "" || room_id = "" || target_pk = "" then
      respond_bad_request (json_error_str err_bad_request
        "alias, room_id, and invitee_pk are required")
    else
      (* B114 (review finding 2): invitee_pk is authorization-relevant and
         MUST be covered by the signature, or an intermediary could substitute
         the target key under an otherwise-valid member proof. Bind it as an
         extra signed field (matches Relay_signed_ops.sign_room_op_with_target_pk). *)
      match verify_room_op_proof relay ~require_signed ~sign_ctx
              ~extra_signed_fields:[ target_pk ] ~room_id ~alias body with
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

  let handle_invite_room relay ~require_signed body =
    handle_room_invite_op relay ~require_signed ~sign_ctx:room_invite_sign_ctx ~op:`Invite body

  let handle_uninvite_room relay ~require_signed body =
    handle_room_invite_op relay ~require_signed ~sign_ctx:room_uninvite_sign_ctx ~op:`Uninvite body

  let handle_knock_room relay ~require_signed body =
    let alias = get_string body "alias" in
    let room_id = get_string body "room_id" in
    if alias = "" || room_id = "" then
      respond_bad_request (json_error_str err_bad_request "alias and room_id are required")
    else
      match verify_room_op_proof relay ~require_signed ~sign_ctx:room_knock_sign_ctx
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

  let handle_list_room_knocks relay ~require_signed body =
    let alias = get_string body "alias" in
    let room_id = get_string body "room_id" in
    if alias = "" || room_id = "" then
      respond_bad_request (json_error_str err_bad_request "alias and room_id are required")
    else
      match verify_room_op_proof relay ~require_signed ~sign_ctx:room_list_knocks_sign_ctx
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

  let handle_room_knock_decision relay ~require_signed ~sign_ctx ~decision body =
    let alias = get_string body "alias" in
    let room_id = get_string body "room_id" in
    let requester_pk = get_string body "requester_pk" in
    if alias = "" || room_id = "" || requester_pk = "" then
      respond_bad_request (json_error_str err_bad_request
        "alias, room_id, and requester_pk are required")
    else
      match verify_room_op_proof relay ~require_signed ~sign_ctx ~room_id ~alias
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

  let handle_approve_room_knock relay ~require_signed body =
    handle_room_knock_decision relay ~require_signed
      ~sign_ctx:room_approve_knock_sign_ctx ~decision:`Approve body

  let handle_deny_room_knock relay ~require_signed body =
    handle_room_knock_decision relay ~require_signed
      ~sign_ctx:room_deny_knock_sign_ctx ~decision:`Deny body

  let handle_leave_room relay ~require_signed body =
    let alias = get_string body "alias" in
    let room_id = get_string body "room_id" in
    if alias = "" || room_id = "" then
      respond_bad_request (json_error_str err_bad_request "alias and room_id are required")
    else
      match verify_room_op_proof relay ~require_signed ~sign_ctx:room_leave_sign_ctx
              ~room_id ~alias body with
      | Error (code, msg) ->
        if code = err_bad_request || code = relay_err_missing_proof_field then
          respond_bad_request (json_error_str code msg)
        else
          respond_unauthorized (json_error_str code msg)
      | Ok () ->
        let result = R.leave_room relay ~alias ~room_id in
        respond_ok (json_of_room_join_result result)

  (* Layer 4 slice 2 / B114: verify the signed envelope on /send_room.
     Envelope shape per spec §2: {ct, enc, sender_pk, sig, ts, nonce}.
     In v1, `ct` is base64url-nopad of the UTF-8 message text; relay
     still fans out `content` verbatim. B114: an absent envelope is
     rejected when [require_signed] is true (mandatory in production and
     the source default); the envelope-less legacy path survives only
     behind the dev gate. Envelope present → verify end-to-end before
     send_room. *)
  let verify_room_send_envelope relay ~require_signed ~from_alias ~room_id ~content body =
    match List.assoc_opt "envelope" (match body with `Assoc l -> l | _ -> []) with
    | None ->
      if require_signed then
        Res.Error (relay_err_unsigned_room_op,
          "room send requires a signed envelope; client must send a signed "
          ^ "envelope (legacy envelope-less send is dev-only: "
          ^ "C2C_REQUIRE_SIGNED_ROOM_OPS=0 on a relay with no Bearer token)")
      else
        (Logs.warn (fun m -> m "envelope-less send_room from %S to room %S accepted via dev gate (C2C_REQUIRE_SIGNED_ROOM_OPS=0, no token)" from_alias room_id);
         Res.Ok ())  (* dev-gated legacy envelope-less path — accept *)
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
                      (* B114 (review finding 1): as with room ops, the
                         envelope only authenticates [from_alias] when
                         [sender_pk] is the key bound to it. An absent binding
                         is rejected (no first-proof TOFU) — the sender must
                         have registered a signed identity. *)
                      (match R.identity_pk_of relay ~alias:from_alias with
                       | Some bound when bound <> sender_pk ->
                         Error (relay_err_alias_identity_mismatch,
                           "sender_pk does not match registered binding")
                       | None ->
                         Error (relay_err_alias_identity_mismatch,
                           "alias has no registered identity binding; register \
                            a signed identity before sending signed room \
                            messages")
                       | Some _ ->
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

  let handle_send_room relay ~require_signed body =
    let from_alias = get_string body "from_alias" in
    let room_id = get_string body "room_id" in
    let content = get_string body "content" in
    if from_alias = "" || room_id = "" || content = "" then
      respond_bad_request (json_error_str err_bad_request "from_alias, room_id, and content are required")
    else
      match verify_room_send_envelope relay ~require_signed ~from_alias ~room_id ~content body with
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
          (* B147: a room message counts as one message, not one per member. *)
          R.stats_note_message relay ~from_alias:(stats_alias_key from_alias) ~ts;
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
      (* B117: anonymous open-read is now gated by BOTH visibility (listed +
         open: public/unlisted) AND the persisted history_public policy. A
         history-closed listed room is member-only, same as gated/private. *)
      let open_read =
        (visibility = "public" || visibility = "unlisted")
        && R.history_public_of relay ~room_id
      in
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

  (* S5a/B116: DELETE /binding/<binding_id> — revoke a mobile binding.

     B111 found the original handler treated a bare binding ID as both
     authority and an existence oracle. Revocation now requires a signed
     owner proof in the JSON body:

       { "revoke_pk": <b64url Ed25519 pk>,   -- machine OR phone key
         "ts":        <unix epoch seconds, string>,
         "nonce":     <b64url random>,
         "sig":       <b64url Ed25519 sig> }

     sig covers canonical_msg(binding_revoke_sign_ctx,
     [binding_id; revoke_pk; ts; nonce]).

     Replay + freshness follow the SAME signed-request pattern as every
     other peer route (spec §5.1): the ts must be within
     [-request_ts_past_window, +request_ts_future_window] of now, and the
     nonce is consumed through a DEDICATED revoke-nonce store
     (R.check_revoke_nonce) — separate from request_nonces because the
     outer Ed25519 request verifier writes header nonces to request_nonces
     BEFORE signature verification, so sharing that store would let an
     attacker pre-seed/grief a revoke nonce with a bogus Authorization
     header. SqliteRelay persists the revoke-nonce table to disk, so
     replay protection survives a relay restart within the freshness
     window (InMemoryRelay is in-memory, matching all other signed ops in
     dev/test).

     Ordering is deliberate for two invariants:

     1. No existence oracle. Every denial that could reveal binding
        state — non-owner key, unknown binding, AND a replayed proof —
        funnels through the identical 401 `revoke_denied` body. Shape
        failures (missing fields, bad encoding, non-finite/stale ts, bad
        sig) reject BEFORE any store or nonce access, so their distinct
        codes are existence-independent.
     2. No anonymous nonce-store growth (DoS). The owner check runs
        BEFORE the nonce is recorded, so only a request whose signature
        verifies AND whose key owns the binding ever writes to the nonce
        store. A stranger's valid-but-non-owner signature is denied
        without touching the store; nonce length is bounded up front too.

     Unconditional: dev mode (no server token) does not bypass any of it. *)
  let handle_mobile_pair_revoke relay ~client_ip binding_id body =
    let deny_uniform () =
      Relay_ratelimit.structured_log ~event:"pair_revoke"
        ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
        ~result:"denied" ();
      respond_unauthorized
        (json_error_str relay_err_revoke_denied
           "binding revocation denied: unknown binding or proof key does not own it")
    in
    let reject code msg =
      Relay_ratelimit.structured_log ~event:"pair_revoke"
        ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
        ~result:"bad_proof" ();
      respond_unauthorized (json_error_str code msg)
    in
    if not (is_valid_binding_id binding_id) then
      respond_bad_request (json_error_str err_bad_request "binding_id must be 8-64 chars of [A-Za-z0-9_-]")
    else
      let get_field name =
        match body with
        | `Assoc l ->
          (match List.assoc_opt name l with
           | Some (`String s) when s <> "" -> Some s
           | _ -> None)
        | _ -> None
      in
      match get_field "revoke_pk", get_field "ts",
            get_field "nonce", get_field "sig" with
      | None, _, _, _ | _, None, _, _ | _, _, None, _ | _, _, _, None ->
        reject relay_err_missing_proof_field
          "binding revocation requires a signed owner proof: revoke_pk, ts, nonce, sig"
      (* Bound the nonce length before it can reach any store — a legit
         proof nonce is ~22 chars (16 random bytes, b64url); refuse
         anything oversized as malformed so it cannot bloat the store. *)
      | _, _, Some nonce, _ when String.length nonce > 128 ->
        reject relay_err_missing_proof_field "nonce too long"
      | Some revoke_pk_b64, Some ts, Some nonce, Some sig_b64 ->
        match decode_b64url revoke_pk_b64 with
        | Error _ ->
          reject relay_err_signature_invalid "revoke_pk not base64url-nopad"
        | Ok pk_raw when String.length pk_raw <> 32 ->
          reject relay_err_signature_invalid "revoke_pk must be 32 bytes"
        | Ok pk_raw ->
          match decode_b64url sig_b64 with
          | Error _ ->
            reject relay_err_signature_invalid "sig not base64url-nopad"
          | Ok sig_raw when String.length sig_raw <> 64 ->
            reject relay_err_signature_invalid "sig must be 64 bytes"
          | Ok sig_raw ->
            let now = Unix.gettimeofday () in
            (match float_of_string_opt ts with
             | None ->
               reject relay_err_timestamp_out_of_window
                 "ts must be unix epoch seconds"
             | Some ts_f
               (* is_finite also rejects nan/inf, whose window comparison
                  would otherwise be vacuously false — a non-expiring
                  proof. Same window as all signed peer requests. *)
               when (not (Float.is_finite ts_f))
                    || ts_f -. now > request_ts_future_window
                    || now -. ts_f > request_ts_past_window ->
               reject relay_err_timestamp_out_of_window
                 (Printf.sprintf "ts skew %.1fs outside signed-request window"
                    (ts_f -. now))
             | Some ts_f ->
               let blob = Relay_identity.canonical_msg
                   ~ctx:binding_revoke_sign_ctx
                   [ binding_id; revoke_pk_b64; ts; nonce ] in
               if not (Relay_identity.verify ~pk:pk_raw ~msg:blob
                         ~sig_:sig_raw) then
                 reject relay_err_signature_invalid
                   "revocation proof signature does not verify"
               else begin
                 (* Owner check BEFORE nonce consumption: only a verified
                    owner writes to the nonce store (no anonymous growth),
                    and unknown-binding / non-owner both deny uniformly. *)
                 let owner =
                   match R.get_observer_binding relay ~binding_id with
                   | None -> false
                   | Some (phone_ed, _phone_x, machine_ed, _sig) ->
                     revoke_pk_b64 = machine_ed || revoke_pk_b64 = phone_ed
                 in
                 if not owner then deny_uniform ()
                 else
                   (* Replay check consumes the nonce via the DEDICATED
                      persisted revoke-nonce store (never touched by the
                      pre-auth outer Ed25519 verifier, which writes header
                      nonces to request_nonces). A replay denies through
                      the SAME revoke_denied body as a non-owner — no
                      oracle. *)
                   match R.check_revoke_nonce relay ~nonce ~ts:ts_f with
                   | Error _ -> deny_uniform ()
                   | Ok () ->
                     R.remove_observer_binding relay ~binding_id;
                     push_pseudo_unregistration_to_observers ~binding_id;
                     Relay_ratelimit.structured_log ~event:"pair_revoke"
                       ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
                       ~result:"ok" ();
                     respond_ok (`Assoc [ "ok", `Bool true;
                                          "binding_id", `String binding_id ])
               end)

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
                       (* B184: include which bound key + which signed fields
                          failed so operators can distinguish key drift after
                          rename/register from body/path/query mismatches
                          (empty-vs-"{}" body was a common intermittent cause). *)
                       let pk_fp = Relay_identity.fingerprint_of_pk pk in
                       let body_tok =
                         if body_sha256_b64 = "" then "empty"
                         else
                           let n = min 12 (String.length body_sha256_b64) in
                           String.sub body_sha256_b64 0 n ^ "..."
                       in
                       Error (relay_err_signature_invalid,
                         Printf.sprintf
                           "Ed25519 request signature does not verify \
(alias=%s, bound_pk=%s, meth=%s, path=%s, query=%S, body_sha256=%s). \
If you just renamed/re-registered, re-run: c2c relay register --alias %s \
(same machine identity as c2c relay identity show)"
                           alias pk_fp meth path query body_tok alias))

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

  let make_callback relay token conn req body ?(broker_root=None)
      ~native_tls ~rate_limiter =
    let open Cohttp in
    let open Cohttp_lwt_unix in
    let uri = Request.uri req in
    let path = Uri.path uri in
    let meth = Request.meth req in
    let client_ip = get_client_ip conn in
    (* B243: client identity only — Relay_ratelimit.check composites
       (key, endpoint-class) so /send and /pubkey do not share a bucket. *)
    let rate_key = client_ip in
    let rate_limit_event, rate_limit_binding_prefix =
      if String.length path > 10 && String.sub path 0 10 = "/observer/" then
        ("observer_handshake", Some (Relay_ratelimit.prefix8 (String.sub path 10 (String.length path - 10))))
      else if String.length path >= 13 && String.sub path 0 13 = "/ws/subscribe" then
        (* B276: same event name as auth path; result=rate_limit_denied. *)
        ("ws_subscribe", None)
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
        (* B237: emit the standard ok:false / error_code envelope so clients
           do not hit the schema-dishonest path ("body did not report
           ok:false") on rate limits. retry_after stays a peer field. *)
        respond_too_many_requests
          (json_error "rate_limit_exceeded" "rate_limit_exceeded"
             [ ("retry_after", `Float retry_after) ])
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
         | _ -> if native_tls then "https" else "http")
    in
    (* B262 §10: grant secrets need authenticated confidential transport.
       A client-supplied X-Forwarded-Proto is evidence only when the operator
       explicitly trusts its TLS terminator; otherwise arbitrary cleartext
       clients could spoof https. *)
    let trust_forwarded_proto =
      match Sys.getenv_opt "C2C_RELAY_TRUST_FORWARDED_PROTO" with
      | Some ("1" | "true" | "TRUE" | "yes") -> true
      | Some _ | None -> false
    in
    let confidential_transport =
      native_tls
      || (trust_forwarded_proto
          && let s = String.lowercase_ascii (String.trim scheme) in
             s = "https" || s = "wss")
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
      (* /forward is Self_auth and has a route-specific peer-relay verifier.
         Do not consume its nonce here and again in [handle_forward]. *)
      if path = "/forward" then Ok None
      else
        try_verify_ed25519_request relay ~auth_header
          ~meth:(meth_to_string meth) ~path ~query
          ~body_sha256_b64:body_sha256
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
      if path = "/contact/v1/deliver" then
        respond_unauthorized
          (json_error_str err_contact_unauthorised "contact unauthorised")
      else
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
      (* B114: room mutations require signed body proofs / envelopes.
         Mandatory whenever a Bearer token is configured (production);
         in dev mode (no token) it is still the default, with an explicit
         C2C_REQUIRE_SIGNED_ROOM_OPS=0 legacy escape hatch. *)
      let require_signed =
        require_signed_room_ops ~token_configured:(token <> None)
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
                 raise (Ws_subscribe_upgrade (ws_key, validated_alias))))
         | _ ->
           respond_bad_request (json_error_str "websocket_upgrade_required" "Upgrade: websocket header required"))

      | `GET, "/" ->
        respond_html landing_html

      | `GET, "/health" ->
        let auth_mode = if token = None then "dev" else "prod" in
        let private_reachability = R.private_reachability_mode relay in
        handle_health ~auth_mode ~private_reachability ()

      | `GET, "/stats" ->
        handle_stats relay

      | `GET, "/list" ->
        handle_list relay ~include_dead:(query_bool "include_dead")

      | `GET, "/dead_letter" ->
        handle_dead_letter relay

      | `GET, "/device-login" ->
        respond_html device_login_html

      | `GET, "/list_rooms" ->
        handle_list_rooms relay ~verified_alias

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
         | Ok j -> handle_register relay ~relay_url ~token j)

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

      | `POST, "/contact/v1/deliver" ->
        let json = parse_body () in
        (match json with
         | Error _ ->
           respond_unauthorized
             (json_error_str err_contact_unauthorised "contact unauthorised")
         | Ok j ->
           handle_contact_deliver relay ~verified_alias ~token
             ~confidential_transport j)

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
             ~require_owner:(inbox_owner_required ~token_configured:(token <> None)) j)

      | `POST, "/peek_inbox" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j ->
           handle_peek_inbox relay ~verified_alias
             ~require_owner:(inbox_owner_required ~token_configured:(token <> None)) j)

      | `POST, "/join_room" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_join_room relay ~require_signed j)

      | `POST, "/leave_room" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_leave_room relay ~require_signed j)

      | `POST, "/set_room_visibility" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_set_room_visibility relay ~require_signed j)

      | `POST, "/set_room_history_public" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_set_room_history_public relay ~require_signed j)

      | `POST, "/invite_room" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_invite_room relay ~require_signed j)

      | `POST, "/uninvite_room" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_uninvite_room relay ~require_signed j)

      | `POST, "/knock_room" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_knock_room relay ~require_signed j)

      | `POST, "/list_room_knocks" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_list_room_knocks relay ~require_signed j)

      | `POST, "/approve_room_knock" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_approve_room_knock relay ~require_signed j)

      | `POST, "/deny_room_knock" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_deny_room_knock relay ~require_signed j)

      | `POST, "/send_room" ->
        let json = parse_body () in
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_send_room relay ~require_signed j)

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
        (* B116: an unparseable body gets the same missing-proof rejection
           as an absent one — never a distinct parse error that could be
           probed. *)
        let json = match parse_body () with
          | Ok j -> j
          | Error _ -> `Null
        in
        handle_mobile_pair_revoke relay ~client_ip binding_id json

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

  (* B149: hourly historical /stats snapshots (plus one at startup so every
     deploy leaves an anchor row). record_stats_snapshot is best-effort and
     never raises, but guard anyway so the loop cannot die. *)
  let stats_snapshot_interval_s = 3600.

  let rec stats_snapshot_loop relay =
    Lwt_unix.sleep stats_snapshot_interval_s >>= fun () ->
    (try R.record_stats_snapshot relay ~now:(Unix.gettimeofday ()) with _ -> ());
    stats_snapshot_loop relay

  (* B219: periodic heartbeat so the logs carry a resource trend (memory /
     lease count / uptime) before a silent death. Best-effort — a failure to
     read counts must never kill the loop. Mirrors the gc/stats loop style. *)
  let rec heartbeat_loop relay ~start_time =
    Lwt_unix.sleep heartbeat_interval_s >>= fun () ->
    (try
       let uptime_s = Unix.gettimeofday () -. start_time in
       let peer_count =
         try List.length (R.list_peers relay ~include_dead:true) with _ -> -1
       in
       let gc = Gc.quick_stat () in
       let rss_kb = heartbeat_rss_kb () in
       Printf.eprintf "%s\n%!"
         (format_heartbeat_line ~uptime_s ~peer_count
            ~heap_words:gc.Gc.heap_words ~rss_kb)
     with _ -> ());
    heartbeat_loop relay ~start_time

  (* --- Server startup --- *)

  let start_server ~host ~port ~relay ~token ?(verbose=false) ?(gc_interval=0.0) ?tls ?(allowlist=[]) ?broker_root () =
    (* B219: make exceptions carry backtraces so the top-level serve guard can
       log them (relay deaths were previously silent — no exn, no backtrace). *)
    Printexc.record_backtrace true;
    (* B219: leave a log trace when the platform kills us. OCaml runs
       Sys.set_signal handlers at safe points (not raw async context), so a
       log line + exit here is safe and non-blocking. SIGKILL is uncatchable
       and deliberately not trapped. *)
    let install_signal_log signum ~name ~code =
      try
        Sys.set_signal signum (Sys.Signal_handle (fun _n ->
          Printf.eprintf "[relay] received signal %s, shutting down\n%!" name;
          exit code))
      with _ -> ()
    in
    install_signal_log Sys.sigterm ~name:"SIGTERM" ~code:143;
    install_signal_log Sys.sigint ~name:"SIGINT" ~code:130;
    let start_time = Unix.gettimeofday () in
    List.iter (fun (alias, identity_pk_b64) ->
      R.set_allowed_identity relay ~alias ~identity_pk_b64)
      allowlist;
    (match allowlist with
     | [] -> ()
     | _ ->
       Printf.printf "allowlist: %d pinned identities\n%!" (List.length allowlist));
      let rate_limiter = Rate_limiter_inst.create ~gc_interval:300.0 () in
    let callback (conn, _) req body =
      Lwt.catch
        (fun () ->
           make_callback relay token conn req body ~rate_limiter ?broker_root
             ~native_tls:(tls <> None)
           >|= fun response -> `Response response)
        (function
          | Ws_subscribe_upgrade (ws_key, validated_alias) ->
              let accept = Relay_ws_frame.websocket_accept ws_key in
              let headers =
                Cohttp.Header.init_with "Upgrade" "websocket"
                |> fun h -> Cohttp.Header.add h "Connection" "Upgrade"
                |> fun h -> Cohttp.Header.add h "Sec-WebSocket-Accept" accept
              in
              let response =
                Cohttp.Response.make ~status:`Switching_protocols ~headers ()
              in
              let io_handler ic oc =
                Relay_ratelimit.structured_log
                  ~event:"ws_subscribe"
                  ~source_ip_prefix:(Relay_ratelimit.prefix8 (get_client_ip conn))
                  ~result:"upgraded" ();
                let lookup_pk ~alias = R.identity_pk_of relay ~alias in
                Relay_ws_server.handle_subscriber_channels
                  ~aliases:[validated_alias] ~ic ~oc ~lookup_pk
              in
              Lwt.return (`Expert (response, io_handler))
          | e -> Lwt.fail e)
    in
    let gc_thread =
      if gc_interval > 0.0 then
        Lwt.async (fun () -> gc_loop relay gc_interval)
      else
        ()
    in
    let _ = gc_thread in
    (try R.record_stats_snapshot relay ~now:(Unix.gettimeofday ()) with _ -> ());
    Lwt.async (fun () -> stats_snapshot_loop relay);
    (* B219: heartbeat loop (default ON; C2C_RELAY_HEARTBEAT_LOG=0 silences). *)
    if heartbeat_enabled () then
      Lwt.async (fun () -> heartbeat_loop relay ~start_time);
    let scheme = match tls with Some _ -> "https" | None -> "http" in
    let verbose_str = if verbose then " (verbose)" else "" in
    Printf.printf "c2c relay serving on %s://%s:%d%s\n%!" scheme host port verbose_str;
    (match tls with
     | Some _ -> Printf.printf "tls: enabled\n%!"
     | None -> ());
    (match token with
     | Some _ -> Printf.printf "auth: Bearer token required\n%!"
     | None -> Printf.printf "auth: DISABLED (no token set — do not expose publicly)\n%!");
    (* B114: report the effective signed-room-op mode at startup so the
       deployed configuration is operator-visible. *)
    (match Sys.getenv_opt "C2C_REQUIRE_SIGNED_ROOM_OPS", token with
     | Some "0", Some _ ->
       Printf.printf
         "room ops: signed proofs REQUIRED (C2C_REQUIRE_SIGNED_ROOM_OPS=0 \
          IGNORED — a token-configured relay never accepts unsigned room ops)\n%!"
     | Some "0", None ->
       Printf.printf
         "room ops: DEV GATE ACTIVE — unsigned room ops and envelope-less \
          sends accepted (C2C_REQUIRE_SIGNED_ROOM_OPS=0, no token; do not \
          expose publicly)\n%!"
     | _ ->
       Printf.printf "room ops: signed proofs + send envelopes required\n%!");
    if gc_interval > 0.0 then
      Printf.printf "gc: running every %.0fs\n%!" gc_interval
    else
      Printf.printf "gc: disabled\n%!";
    let spec = Cohttp_lwt_unix.Server.make_response_action ~callback () in
    let server_promise =
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
    in
    (* B219: top-level serve-loop guard. Previously an uncaught exception out
       of the serve loop terminated the process silently. Log the exception +
       backtrace to stderr, then re-raise so exit behaviour is unchanged (this
       does NOT swallow or continue past the failure). *)
    Lwt.catch
      (fun () -> server_promise)
      (fun exn ->
         let bt = Printexc.get_backtrace () in
         Printf.eprintf
           "[relay] FATAL: serve loop terminated by uncaught exception: %s\n%s%!"
           (Printexc.to_string exn) bt;
         Lwt.fail exn)

end
