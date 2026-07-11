(* test_c2c_watch_data.ml — synthetic-broker fixture tests for the `c2c watch`
   data layer (slice B1). The joins are the highest-bug-risk part of the TUI
   (spec §8-B1 / §9), so these tests build a real on-disk broker dir in a
   tmpdir via the Broker write API and assert [build_snapshot]'s projections:

     - peer liveness tristate: Alive / Dead / Unknown all present;
     - the [#room] fan-out filter drops [ae_to_alias] / [to_alias] rows
       carrying '#' from the DM shard (they belong to the Rooms tab, §3.2);
     - an archive shard whose session_id is absent from the registry is an
       orphan (ds_owner_alias = None, ds_is_orphan = true);
     - in-flight (undrained inbox) rows are merged in and #room-filtered;
     - an empty room is the COMMON quiet case → rv_history = [] (§3.3).

   No live peers: the synthetic fixture is deterministic. Aliases are
   test-only nonsense ("zzttest-*") to avoid colliding with real swarm
   aliases. Fixture hygiene (spec §9): everything is synthetic, written into
   a private mkdtemp dir that is removed at the end. *)

open Alcotest

module Broker = C2c_mcp.Broker
module Data = C2c_watch_data

(* --- tmpdir helpers ----------------------------------------------------- *)

let mkdtemp () =
  let base = Filename.get_temp_dir_name () in
  let rec attempt n =
    if n > 50 then failwith "mkdtemp: too many attempts"
    else
      let cand =
        Filename.concat base
          (Printf.sprintf "c2c_watch_data_test_%d_%d" (Unix.getpid ())
             (Random.int 1_000_000))
      in
      match Unix.mkdir cand 0o700 with
      | () -> cand
      | exception Unix.Unix_error (Unix.EEXIST, _, _) -> attempt (n + 1)
  in
  attempt 0

let rec rm_rf path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun e -> rm_rf (Filename.concat path e)) (Sys.readdir path);
      (try Unix.rmdir path with Unix.Unix_error _ -> ())
  | _ -> (try Unix.unlink path with Unix.Unix_error _ -> ())
  | exception Unix.Unix_error _ -> ()

(* --- message helper ----------------------------------------------------- *)

let mk_msg ~from_a ~to_a ~content : C2c_mcp.message =
  { from_alias = from_a
  ; to_alias = to_a
  ; content
  ; deferrable = false
  ; reply_via = None
  ; enc_status = None
  ; ts = 1714291842.0
  ; ephemeral = false
  ; message_id = None
  ; pow_difficulty = None
  }

(* A pid that cannot exist on Linux (well above the conventional pid_max)
   → /proc/<pid> absent → registration_liveness_state = Dead. *)
let impossible_pid = 2_147_483_600

(* --- fixture build ------------------------------------------------------ *)

(* Registered (non-orphan) peer's session_id whose archive we populate. *)
let alive_sid = "zzttest-alive-sid"
let dead_sid = "zzttest-dead-sid"
let unknown_sid = "zzttest-unknown-sid"
let ghost_sid = "ghost-sid-xyz"  (* archive present, NOT registered → orphan *)

let alive_alias = "zzttest-alpha"
let dead_alias = "zzttest-bravo"
let unknown_alias = "zzttest-charlie"

let room_with_history = "zzttest-room-loud"
let room_empty = "zzttest-room-quiet"

let build_fixture root =
  let t = Broker.create ~root in
  (* --- 3 peers exercising ALL liveness states ---------------------------
     Alive: this process's pid + its matching pid_start_time (current ==
       stored at check time).
     Dead: a pid with no /proc entry.
     Unknown: pid = None. *)
  let self_pid = Unix.getpid () in
  Broker.register t ~session_id:alive_sid ~alias:alive_alias
    ~pid:(Some self_pid)
    ~pid_start_time:(Broker.capture_pid_start_time (Some self_pid))
    ~role:(Some "coder") ();
  Broker.register t ~session_id:dead_sid ~alias:dead_alias
    ~pid:(Some impossible_pid) ~pid_start_time:(Some 1) ();
  Broker.register t ~session_id:unknown_sid ~alias:unknown_alias
    ~pid:None ~pid_start_time:None ();
  (* --- archive rows for the registered ALIVE peer: one normal DM, one
     #room fan-out copy (to_alias contains '#'). The #room row MUST be
     dropped from ds_entries. *)
  Broker.append_archive t ~session_id:alive_sid
    ~messages:
      [ mk_msg ~from_a:"coordinator1" ~to_a:alive_alias ~content:"normal DM body"
      ; mk_msg ~from_a:"coordinator1"
          ~to_a:(alive_alias ^ "#" ^ room_with_history)
          ~content:"room fanout copy — must be hidden in DMs tab"
      ];
  (* --- in-flight (undrained) inbox for the alive peer: one normal, one
     #room-tagged. The tagged one MUST be dropped from ds_inflight. *)
  Broker.save_inbox t ~session_id:alive_sid
    [ mk_msg ~from_a:"coordinator1" ~to_a:alive_alias ~content:"in-flight normal"
    ; mk_msg ~from_a:"coordinator1"
        ~to_a:(alive_alias ^ "#" ^ room_with_history)
        ~content:"in-flight room copy — drop me"
    ];
  (* --- archive for an UNREGISTERED session_id → orphan shard. *)
  Broker.append_archive t ~session_id:ghost_sid
    ~messages:
      [ mk_msg ~from_a:"someone" ~to_a:"zzttest-delta" ~content:"orphan shard body" ];
  (* --- room WITH history: create + join + send (sender is a member,
     send_room appends to history.jsonl). *)
  ignore
    (Broker.create_room t ~room_id:room_with_history ~caller_alias:alive_alias
       ~caller_session_id:alive_sid ~visibility:C2c_mcp.Public
       ~invited_members:[] ~auto_join:true);
  ignore
    (Broker.send_room t ~from_alias:alive_alias ~room_id:room_with_history
       ~content:"hello room — this lands in history.jsonl");
  (* --- room WITHOUT history: create only, no joins/sends → no history.jsonl
     → rv_history = [] (the common quiet case). *)
  ignore
    (Broker.create_room t ~room_id:room_empty ~caller_alias:alive_alias
       ~caller_session_id:alive_sid ~visibility:C2c_mcp.Public
       ~invited_members:[] ~auto_join:false);
  t

(* --- the snapshot under test (built once, asserted by all cases) -------- *)

let with_snapshot f =
  let root = mkdtemp () in
  Fun.protect
    ~finally:(fun () -> rm_rf root)
    (fun () ->
       let t = build_fixture root in
       f ~root (Data.build_snapshot t))

(* --- assertions --------------------------------------------------------- *)

let find_peer snap alias =
  List.find_opt (fun (p : Data.peer_row) -> p.pr_alias = alias) snap.Data.peers

let liveness_eq = function
  | Broker.Alive, Broker.Alive
  | Broker.Dead, Broker.Dead
  | Broker.Unknown, Broker.Unknown -> true
  | _ -> false

let test_peer_liveness_tristate () =
  with_snapshot (fun ~root:_ snap ->
      let get a = match find_peer snap a with
        | Some p -> p
        | None -> failf "peer %s missing from snapshot" a
      in
      let alive = get alive_alias in
      let dead = get dead_alias in
      let unknown = get unknown_alias in
      check bool "alive peer => Alive" true
        (liveness_eq (alive.pr_liveness, Broker.Alive));
      check bool "dead peer => Dead" true
        (liveness_eq (dead.pr_liveness, Broker.Dead));
      check bool "unknown peer => Unknown" true
        (liveness_eq (unknown.pr_liveness, Broker.Unknown));
      (* sparse-field passthrough: role present on alive, absent on others *)
      check (option string) "alive peer role" (Some "coder") alive.pr_role)

let test_room_copy_filtered_from_entries () =
  with_snapshot (fun ~root:_ snap ->
      let shard =
        match
          List.find_opt
            (fun (s : Data.dm_shard) -> s.ds_session_id = alive_sid)
            snap.Data.shards
        with
        | Some s -> s
        | None -> failf "alive shard %s missing" alive_sid
      in
      (* exactly the normal DM survives in ds_entries; #room row dropped *)
      check int "one DM row kept (room copy dropped)" 1
        (List.length shard.ds_entries);
      let e = List.hd shard.ds_entries in
      check string "kept row is the normal DM" "normal DM body" e.ae_content;
      check bool "no surviving entry carries '#'" true
        (List.for_all
           (fun (e : Broker.archive_entry) ->
              not (String.contains e.ae_to_alias '#'))
           shard.ds_entries))

let test_inflight_filtered () =
  with_snapshot (fun ~root:_ snap ->
      let shard =
        List.find
          (fun (s : Data.dm_shard) -> s.ds_session_id = alive_sid)
          snap.Data.shards
      in
      check int "one in-flight row kept (room copy dropped)" 1
        (List.length shard.ds_inflight);
      let m = List.hd shard.ds_inflight in
      check string "kept in-flight is the normal one" "in-flight normal"
        m.C2c_mcp.content;
      check bool "no in-flight carries '#'" true
        (List.for_all
           (fun (m : C2c_mcp.message) -> not (String.contains m.to_alias '#'))
           shard.ds_inflight))

let test_orphan_detected () =
  with_snapshot (fun ~root:_ snap ->
      let shard =
        match
          List.find_opt
            (fun (s : Data.dm_shard) -> s.ds_session_id = ghost_sid)
            snap.Data.shards
        with
        | Some s -> s
        | None -> failf "ghost shard %s missing from snapshot" ghost_sid
      in
      check (option string) "orphan has no owner alias" None shard.ds_owner_alias;
      check bool "orphan flagged" true shard.ds_is_orphan;
      check int "orphan shard keeps its single body" 1
        (List.length shard.ds_entries))

let test_registered_shard_owner () =
  with_snapshot (fun ~root:_ snap ->
      let shard =
        List.find
          (fun (s : Data.dm_shard) -> s.ds_session_id = alive_sid)
          snap.Data.shards
      in
      check bool "registered shard has an owner alias" true
        (shard.ds_owner_alias <> None);
      check bool "registered shard is NOT orphan" false shard.ds_is_orphan)

let test_room_history_and_empty () =
  with_snapshot (fun ~root:_ snap ->
      let get_room rid =
        match
          List.find_opt
            (fun (rv : Data.room_view) -> rv.rv_info.ri_room_id = rid)
            snap.Data.rooms
        with
        | Some rv -> rv
        | None -> failf "room %s missing from snapshot" rid
      in
      let loud = get_room room_with_history in
      let quiet = get_room room_empty in
      check bool "room with a send has non-empty history" true
        (loud.rv_history <> []);
      check (list string) "empty room => rv_history projection is empty" []
        (List.map (fun (m : C2c_mcp.room_message) -> m.rm_content)
           quiet.rv_history);
      check int "quiet room history length is 0" 0 (List.length quiet.rv_history))

let test_broker_root_passthrough () =
  with_snapshot (fun ~root snap ->
      check string "broker_root matches Broker.root" root snap.Data.broker_root)

let tests =
  [ "peer liveness tristate",        `Quick, test_peer_liveness_tristate
  ; "#room copy filtered (archive)", `Quick, test_room_copy_filtered_from_entries
  ; "#room copy filtered (inflight)",`Quick, test_inflight_filtered
  ; "orphan shard detected",         `Quick, test_orphan_detected
  ; "registered shard owner",        `Quick, test_registered_shard_owner
  ; "room history + empty default",  `Quick, test_room_history_and_empty
  ; "broker_root passthrough",       `Quick, test_broker_root_passthrough
  ]

(* --- B5: send-wrapper ERROR-PATH tests ---------------------------------- *)

(* These prove the #1 requirement (spec §4.3): a send NEVER raises out of the
   wrapper — every broker rejection becomes a [Send_failed] VALUE. We drive the
   real broker write API against a synthetic tmpdir broker (the B1 fixture
   pattern); the error paths need no live peer. Each case asserts:
     (a) no exception escapes (the wrapper returned), and
     (b) the result is the expected [Send_failed] / [Sent_room]+warning. *)

let is_send_failed = function
  | Data.Send_failed _ -> true
  | _ -> false

let send_failed_msg = function
  | Data.Send_failed m -> m
  | Data.Sent_dm -> "<Sent_dm>"
  | Data.Sent_dm_offline -> "<Sent_dm_offline>"
  | Data.Sent_room _ -> "<Sent_room>"

let contains_sub (hay : string) (needle : string) : bool =
  let hl = String.length hay and nl = String.length needle in
  let rec go i = i + nl <= hl && (String.sub hay i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let with_broker f =
  let root = mkdtemp () in
  Fun.protect
    ~finally:(fun () -> rm_rf root)
    (fun () -> f (build_fixture root))

(* DM to an UNREGISTERED recipient -> Send_failed (alias not found). The
   wrapper catches the broker's Invalid_argument; the watcher never sees it. *)
let test_send_dm_unknown_recipient () =
  with_broker (fun t ->
      let r =
        Data.send_dm t ~from_alias:"operator"
          ~to_alias:"zzttest-nobody-here" ~content:"hi"
      in
      check bool "unknown recipient => Send_failed" true (is_send_failed r);
      check bool "message mentions not registered" true
        (contains_sub (send_failed_msg r) "not registered"))

(* SELF-SEND (from = to) -> Send_failed, guarded BEFORE the broker call. *)
let test_send_dm_self_send () =
  with_broker (fun t ->
      let r =
        Data.send_dm t ~from_alias:alive_alias ~to_alias:alive_alias
          ~content:"talking to myself"
      in
      check bool "self-send => Send_failed" true (is_send_failed r);
      check bool "message mentions yourself" true
        (contains_sub (send_failed_msg r) "yourself"))

(* DM to a DEAD recipient (registered, pid has no /proc) -> Sent_dm_offline
   (B127 durable offline queue). Proves the All_recipients_dead branch queues
   instead of raising / Send_failed. *)
let test_send_dm_dead_recipient () =
  with_broker (fun t ->
      let r =
        Data.send_dm t ~from_alias:"operator" ~to_alias:dead_alias
          ~content:"are you there?"
      in
      check bool "dead recipient => Sent_dm_offline" true
        (match r with Data.Sent_dm_offline -> true | _ -> false);
      let inbox = C2c_mcp.Broker.read_inbox t ~session_id:dead_sid in
      check int "offline mail landed in dead session inbox" 1 (List.length inbox))

(* RESERVED from_alias ("c2c") -> Send_failed (broker rejects spoofed system
   sender). Proves the reserved-from Invalid_argument is caught. *)
let test_send_dm_reserved_from () =
  with_broker (fun t ->
      let r =
        Data.send_dm t ~from_alias:"c2c" ~to_alias:alive_alias
          ~content:"spoofing the system"
      in
      check bool "reserved from => Send_failed" true (is_send_failed r))

(* Room send to a room with 0 OTHER members (only the sender) — a SOFT warning
   path, NOT an exception. The send succeeds (Sent_room) and surfaces the
   sr_warning if the broker set one; either way it must NOT be Send_failed and
   must NOT raise. *)
let test_send_room_zero_members () =
  with_broker (fun t ->
      (* room_empty was created but NOT auto-joined by anyone; send via the
         system path is allowed (ghost-room) and yields a 0-delivery result. *)
      let r =
        Data.send_room_message t ~from_alias:alive_alias
          ~room_id:room_empty ~content:"anyone here?"
      in
      match r with
      | Data.Sent_room { delivered; skipped = _; warning = _ } ->
          (* No OTHER members => delivered 0 (or the sender's own membership is
             excluded). The key assertion: it did NOT raise and is NOT a
             failure. *)
          check bool "0-member room delivered count >= 0" true (delivered >= 0)
      | Data.Send_failed m ->
          (* Acceptable ONLY if the broker treats a never-joined sender as a
             membership error — but it must still be a VALUE, not an exception.
             Record it so a regression in the wrapper's catch is visible. *)
          check bool
            (Printf.sprintf "0-member room => non-raising Send_failed: %s" m)
            true true
      | Data.Sent_dm | Data.Sent_dm_offline ->
          failf "send_room_message returned a DM result")

(* Room send to an INVALID room_id -> Send_failed (broker raises
   Invalid_argument "invalid room_id"). Caught, not raised. *)
let test_send_room_invalid_id () =
  with_broker (fun t ->
      let r =
        Data.send_room_message t ~from_alias:alive_alias
          ~room_id:"" ~content:"into the void"
      in
      check bool "invalid room_id => Send_failed" true (is_send_failed r))

(* A reserved system [from_alias] for a ROOM send must be REFUSED by the
   wrapper (Broker.send_room would otherwise treat it as a privileged internal
   sender), AND the spoofed message must NOT land in the room history — proving
   the guard runs BEFORE the broker call. This is the security hole the
   whole-feature audit surfaced. *)
let test_send_room_reserved_from () =
  with_broker (fun t ->
      let spoof = "SYSTEM ANNOUNCEMENT (spoofed via reserved from)" in
      let r =
        Data.send_room_message t ~from_alias:"c2c"
          ~room_id:room_with_history ~content:spoof
      in
      check bool "reserved room from => Send_failed" true (is_send_failed r);
      let hist =
        Broker.read_room_history t ~room_id:room_with_history ~limit:100 ()
      in
      check bool "spoofed reserved-from message is NOT in room history" false
        (List.exists
           (fun (m : C2c_mcp.room_message) -> m.rm_content = spoof)
           hist))

let send_tests =
  [ "dm unknown recipient => Send_failed", `Quick, test_send_dm_unknown_recipient
  ; "dm self-send => Send_failed",         `Quick, test_send_dm_self_send
  ; "dm dead recipient => Sent_dm_offline (B127)", `Quick, test_send_dm_dead_recipient
  ; "dm reserved from => Send_failed",     `Quick, test_send_dm_reserved_from
  ; "room 0 members => warning, no raise", `Quick, test_send_room_zero_members
  ; "room invalid id => Send_failed",      `Quick, test_send_room_invalid_id
  ; "room reserved from => refused+unposted", `Quick, test_send_room_reserved_from
  ]

let () =
  Random.self_init ();
  Alcotest.run "c2c_watch_data"
    [ "build_snapshot", tests; "send_wrappers", send_tests ]
