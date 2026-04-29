(* coord_fallthrough.ml — broker-side per-DM redundancy chain.

   Design: .collab/design/2026-04-29-coord-backup-fallthrough-stanza.md
   Slice: slice/coord-backup-scheduler-impl

   Receipt: galaxy-coder's permission DM auto-rejected at TTL=600s on
   2026-04-29 because the primary coord didn't surface the inbound in
   time. Per Max's brief, the fix is redundancy — if the primary
   doesn't ack within `coord_fallthrough_idle_seconds`, fan out to
   backups in `coord_chain` order; if the chain is exhausted,
   broadcast to `coord_fallthrough_broadcast_room` (default
   swarm-lounge).

   This module owns the scheduler loop (60s tick, separate from the
   relay_nudge 30min loop). On each tick it scans
   pending_permissions.json and decides whether to fire the next tier
   for any unresolved entry. Per Cairn's greenlit answers:
     - verbatim aliases in coord_chain (no role indirection)
     - skip-and-advance on offline backups
     - broadcast tier after the entire chain is exhausted
     - log-only on requester notification (no DM-the-requester spam)
     - check_pending_reply writes resolved_at; scheduler skips
       resolved entries
     - dedicated thread, 60s tick *)

open C2c_mcp

let src_log = Logs.Src.create "coord_fallthrough"
                ~doc:"coord-backup fallthrough scheduler"
module Log = (val Logs.src_log src_log : Logs.LOG)

(* 60s tick — short enough to catch the 120s default idle window with
   minimal lag, long enough to be cheap (one pending_permissions.json
   read per tick). *)
let default_tick_seconds = 60.0

(* Broadcast tier sender alias; used in fan-out and audit. *)
let broadcast_sender_alias = "c2c-coord-fallthrough"

(* Body shape for backup DMs and broadcast messages. The backup needs
   the perm_id (so they can call check_pending_reply); the requester
   alias is informational. Broadcast appends a coord-backup mention so
   the lounge knows it's an escalation, not chatter. *)
let backup_dm_body ~perm_id ~requester_alias ~primary_alias ~elapsed_s =
  Printf.sprintf
    "[coord-fallthrough] permission perm_id=%s from %s — primary %s \
     didn't ack within %.0fs. Reply via mcp__c2c__check_pending_reply."
    perm_id requester_alias primary_alias elapsed_s

let broadcast_body ~perm_id ~requester_alias ~primary_alias ~elapsed_s
    ~chain_aliases =
  let chain_str = match chain_aliases with
    | [] -> "(none)"
    | xs -> String.concat ", " xs
  in
  Printf.sprintf
    "@coordinator-backup [coord-fallthrough] permission perm_id=%s \
     from %s — primary %s and chain [%s] all unanswered after %.0fs. \
     Reply via mcp__c2c__check_pending_reply."
    perm_id requester_alias primary_alias chain_str elapsed_s

(* Skip-and-advance: a backup is "reachable" if any of its registered
   rows passes [registration_is_alive] (the permissive predicate that
   [enqueue_message] uses). Pidless rows (Unknown in
   registration_liveness_state) collapse to Alive here, same as the
   broker's enqueue path, because we still want to drop the DM into
   their inbox; the recipient drains on next poll/restart.

   Hard-Dead rows (pid set, /proc gone, or pid-start-time mismatch)
   are skipped — that's what skip-and-advance is for. *)
let alias_is_alive ~broker alias =
  let regs = Broker.list_registrations broker in
  let target = String.lowercase_ascii alias in
  List.exists
    (fun (r : registration) ->
      String.lowercase_ascii r.alias = target
      && Broker.registration_is_alive r)
    regs

(* Compute which tier to fire next for one pending entry, given the
   chain config and current time. Returns:
     `No_action          — entry resolved or no chain configured
     `Wait               — chain still has eligible tiers, but idle
                           threshold not yet reached
     `Fire_backup of (idx, alias)
                         — fire backup at chain[idx] (already
                           skip-and-advanced past offline rows)
     `Broadcast          — entire chain exhausted; broadcast tier *)
let decide_next_action
    ~broker
    ~(p : pending_permission)
    ~chain
    ~idle_seconds
    ~now =
  if p.resolved_at <> None then `No_action
  else if chain = [] then `No_action
  else
    let elapsed = now -. p.created_at in
    let chain_len = List.length chain in
    (* Identify already-fired tiers from p.fallthrough_fired_at. The
       list is parallel to the chain by 0-based index; entries beyond
       the list are treated as None (eligible). *)
    let fired_at idx =
      try List.nth p.fallthrough_fired_at idx with _ -> None
    in
    (* Skip-and-advance semantics (Cairn answer 2): when an earlier
       tier is offline, the next live tier fires NOW (same elapsed
       window the skipped tier would have fired at). Skipped tiers
       are stamped (so we don't re-check them every tick) but do not
       advance the threshold counter — only ACTUAL fires do. So the
       Nth real fire happens at elapsed >= idle * N regardless of how
       many offline tiers were skipped past.

       To distinguish "stamped because actually fired" from "stamped
       because skipped" without adding a sentinel, we re-derive at
       each scan: walk the chain from index 0; for each fired-stamped
       row, look up the registration — alive → counted as a real fire;
       not-alive (still offline) → counted as skipped. (If a backup
       was previously skipped and later comes online, that's a new
       eligible tier. The mark_pending_fallthrough_fired stamp
       prevents re-firing the SAME index, so the formerly-skipped
       row stays bookkept.)

       Implementation simplification: we just don't increment
       fired_count on already-stamped rows whose alias is not alive.
       This lets a transitioning peer rejoin the chain semantically.
       The threshold counter is "real-fire count." *)
    let rec scan idx fired_count =
      if idx >= chain_len then
        let broadcast_idx = chain_len in
        if fired_at broadcast_idx <> None then `No_action
        else
          let threshold = idle_seconds *. float_of_int (fired_count + 1) in
          if elapsed >= threshold then `Broadcast else `Wait
      else
        let alias = List.nth chain idx in
        if fired_at idx <> None then
          (* Stamped — count as a real fire only if the alias was
             alive when fire happened. We can't know retroactively, so
             approximate: count as real fire iff currently alive
             (best-effort; handles rejoin-after-skip). *)
          let counted_as_fire = if alias_is_alive ~broker alias then 1 else 0 in
          scan (idx + 1) (fired_count + counted_as_fire)
        else
          let tier_threshold = idle_seconds *. float_of_int (fired_count + 1) in
          if elapsed < tier_threshold then `Wait
          else if alias_is_alive ~broker alias then `Fire_backup (idx, alias)
          else `Skip_and_advance (idx, alias)
    in
    scan 0 0

(* `Skip_and_advance is one of the cases scan can return; encode as a
   polymorphic variant alongside the others. We dispatch in the tick
   handler. *)

let fire_backup ~broker ~broker_root ~p ~idx ~alias ~chain ~elapsed ~now =
  let body =
    backup_dm_body
      ~perm_id:p.perm_id
      ~requester_alias:p.requester_alias
      ~primary_alias:(match chain with [] -> "(none)" | a :: _ -> a)
      ~elapsed_s:elapsed
  in
  (try
     Broker.enqueue_message broker
       ~from_alias:broadcast_sender_alias
       ~to_alias:alias
       ~content:body
       ~deferrable:false
       ();
     Log.info (fun f ->
       f "fallthrough fired tier=%d perm_id=%s backup=%s elapsed=%.0fs"
         (idx + 1) p.perm_id alias elapsed)
   with e ->
     Log.warn (fun f ->
       f "fallthrough enqueue failed perm_id=%s backup=%s err=%s"
         p.perm_id alias (Printexc.to_string e)));
  log_coord_fallthrough_fired
    ~broker_root
    ~perm_id:p.perm_id
    ~tier:(idx + 1)
    ~primary_alias:(match chain with [] -> "(none)" | a :: _ -> a)
    ~backup_alias:alias
    ~requester_alias:p.requester_alias
    ~elapsed_s:elapsed
    ~ts:now;
  let _ : bool =
    Broker.mark_pending_fallthrough_fired broker
      ~perm_id:p.perm_id ~tier_index:idx ~ts:now
  in
  ()

let fire_broadcast ~broker ~broker_root ~p ~chain ~broadcast_room ~elapsed ~now =
  let chain_len = List.length chain in
  if broadcast_room = "" then
    (* Operator disabled the broadcast tier — log+stamp+skip. *)
    let _ : bool =
      Broker.mark_pending_fallthrough_fired broker
        ~perm_id:p.perm_id ~tier_index:chain_len ~ts:now
    in
    Log.info (fun f ->
      f "fallthrough broadcast tier suppressed (room=\"\") perm_id=%s"
        p.perm_id)
  else
    let body =
      broadcast_body
        ~perm_id:p.perm_id
        ~requester_alias:p.requester_alias
        ~primary_alias:(match chain with [] -> "(none)" | a :: _ -> a)
        ~elapsed_s:elapsed
        ~chain_aliases:chain
    in
    (try
       let _ : string list * string list =
         Broker.fan_out_room_message broker
           ~room_id:broadcast_room
           ~from_alias:broadcast_sender_alias
           ~content:body
       in
       Log.info (fun f ->
         f "fallthrough broadcast fired perm_id=%s room=%s elapsed=%.0fs"
           p.perm_id broadcast_room elapsed)
     with e ->
       Log.warn (fun f ->
         f "fallthrough broadcast failed perm_id=%s room=%s err=%s"
           p.perm_id broadcast_room (Printexc.to_string e)));
    log_coord_fallthrough_fired
      ~broker_root
      ~perm_id:p.perm_id
      ~tier:(chain_len + 1)
      ~primary_alias:(match chain with [] -> "(none)" | a :: _ -> a)
      ~backup_alias:"<broadcast>"
      ~requester_alias:p.requester_alias
      ~elapsed_s:elapsed
      ~ts:now;
    let _ : bool =
      Broker.mark_pending_fallthrough_fired broker
        ~perm_id:p.perm_id ~tier_index:chain_len ~ts:now
    in
    ()

(* One scan of the pending-permissions store. Public so tests can
   drive it without spawning the loop. Returns nothing; effects land
   via Broker enqueue/save and broker.log audit lines.

   On each tick we drain skip-and-advance decisions in a single pass:
   if backup-N is offline, stamp tier idx=N as fired, then check N+1
   in the same call (don't wait the next tick). Per Cairn's answer 2. *)
let tick ?now ~broker ~broker_root ~chain ~idle_seconds ~broadcast_room () =
  let now_ts = match now with Some t -> t | None -> Unix.gettimeofday () in
  let entries = Broker.load_pending_permissions broker in
  List.iter
    (fun (p : pending_permission) ->
      (* Skip expired entries; the existing TTL path will reap them. *)
      if p.expires_at <= now_ts then ()
      else
        (* Drain decisions until `Wait or `No_action — handles
           skip-and-advance + multi-tier catch-up if the scheduler was
           paused for a long stretch. *)
        let rec drain () =
          (* Re-load the entry by perm_id each loop, so any stamps we
             wrote in the previous iteration are visible. *)
          match Broker.find_pending_permission broker p.perm_id with
          | None -> ()
          | Some current ->
              (match decide_next_action
                       ~broker ~p:current ~chain ~idle_seconds ~now:now_ts with
               | `No_action | `Wait -> ()
               | `Fire_backup (idx, alias) ->
                   let elapsed = now_ts -. current.created_at in
                   fire_backup ~broker ~broker_root ~p:current
                     ~idx ~alias ~chain ~elapsed ~now:now_ts;
                   drain ()
               | `Skip_and_advance (idx, alias) ->
                   (* Stamp fired_at[idx] without DMing — the backup
                      is offline, the tier "fired" in the bookkeeping
                      sense (don't re-check on next tick), and
                      drain() will look at idx+1. *)
                   let _ : bool =
                     Broker.mark_pending_fallthrough_fired broker
                       ~perm_id:current.perm_id ~tier_index:idx
                       ~ts:now_ts
                   in
                   Log.info (fun f ->
                     f "fallthrough skip-and-advance perm_id=%s tier=%d alias=%s (offline)"
                       current.perm_id (idx + 1) alias);
                   drain ()
               | `Broadcast ->
                   let elapsed = now_ts -. current.created_at in
                   fire_broadcast ~broker ~broker_root ~p:current
                     ~chain ~broadcast_room ~elapsed ~now:now_ts;
                   drain ())
        in
        drain ())
    entries

let start_scheduler
    ~broker_root
    ~broker
    ?(tick_seconds = default_tick_seconds)
    () =
  let chain () = C2c_start.swarm_config_coord_chain () in
  let idle_seconds () =
    C2c_start.swarm_config_coord_fallthrough_idle_seconds ()
  in
  let broadcast_room () =
    C2c_start.swarm_config_coord_fallthrough_broadcast_room ()
  in
  Log.info (fun f ->
    f "coord_fallthrough: starting (tick=%.0fs, chain=%s, idle=%.0fs, broadcast=%s)"
      tick_seconds
      (String.concat "," (chain ()))
      (idle_seconds ())
      (broadcast_room ()));
  let rec loop () =
    let open Lwt in
    Lwt_unix.sleep tick_seconds
    >>= fun () ->
    (try
       tick
         ~broker
         ~broker_root
         ~chain:(chain ())
         ~idle_seconds:(idle_seconds ())
         ~broadcast_room:(broadcast_room ())
         ()
     with e ->
       Log.warn (fun f ->
         f "coord_fallthrough: tick failed: %s" (Printexc.to_string e)));
    loop ()
  in
  Lwt.async (fun () -> loop ())
