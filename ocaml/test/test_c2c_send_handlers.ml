(* #388 tests for #450 Slice 6 handler module: c2c_send_handlers.ml *)

open Alcotest
module Broker = C2c_broker

(* ------------------------------------------------------------------------- *)
(* Test infrastructure                                                       *)
(* ------------------------------------------------------------------------- *)

let () = Random.self_init ()

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base (Printf.sprintf "c2c-send-%06x" (Random.bits ())) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) ->
    (* Stale dir from prior run — clean and recreate *)
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
    Unix.mkdir dir 0o755);
  Fun.protect
    ~finally:(fun () -> Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) |> ignore)
    (fun () -> f dir)

let yojson_of_string s = Yojson.Safe.from_string s

(* tool_result shape: { content: [{type: "text", text: <msg>}], isError: bool } *)
let get_is_error json =
  let open Yojson.Safe.Util in
  member "isError" json |> to_bool

let get_text_content json =
  let open Yojson.Safe.Util in
  member "content" json |> index 0 |> member "text" |> to_string

let contains_substring ~haystack ~needle =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen = 0 then true
  else if nlen > hlen then false
  else
    let rec loop i =
      if i + nlen > hlen then false
      else if String.sub haystack i nlen = needle then true
      else loop (i + 1)
    in
    loop 0

(* Register a single alive peer under [session_id] holding [alias].
   Mirrors willow's identity-test setup: pid=None, pid_start_time=None
   means [registration_is_alive] returns true via the pidless branch. *)
let register_alive broker ~session_id ~alias =
  Broker.register broker ~session_id ~alias ~pid:None ~pid_start_time:None ()

(* A pid far above any plausible pid_max — /proc/<pid> never exists, so
   [registration_is_alive] returns false. Used to register a known-but-dead
   peer (B127 offline-queue path). *)
let dead_pid = 0x7f00_0000

let register_dead broker ~session_id ~alias =
  Broker.register broker ~session_id ~alias ~pid:(Some dead_pid)
    ~pid_start_time:None ()

(* ------------------------------------------------------------------------- *)
(* send: missing sender alias (no session, no fallback) → error              *)
(* ------------------------------------------------------------------------- *)

let test_send_missing_sender () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-recipient" ~alias:"recipient";
      let args = `Assoc [
        ("to_alias", `String "recipient");
        ("content", `String "hi");
      ] in
      let result = Lwt_main.run
        (C2c_send_handlers.send ~broker
           ~session_id_override:(Some "session-orphan") ~arguments:args)
      in
      check bool "isError=true on missing sender" true (get_is_error result);
      let text = get_text_content result in
      check bool "mentions sender alias" true
        (contains_substring ~haystack:text ~needle:"alias"))

(* ------------------------------------------------------------------------- *)
(* send: from_alias = to_alias → "cannot send a message to yourself"         *)
(* ------------------------------------------------------------------------- *)

let test_send_self_rejected () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-self" ~alias:"loner";
      let args = `Assoc [
        ("to_alias", `String "loner");
        ("content", `String "talking to myself");
      ] in
      let result = Lwt_main.run
        (C2c_send_handlers.send ~broker
           ~session_id_override:(Some "session-self") ~arguments:args)
      in
      check bool "isError=true on self-send" true (get_is_error result);
      let text = get_text_content result in
      check bool "mentions self-send" true
        (contains_substring ~haystack:text ~needle:"yourself"))

(* ------------------------------------------------------------------------- *)
(* send: concurrent reg with session_id == alias — no cross-contamination     *)
(* Bug: current_registered_alias resolved the wrong alias after concurrent   *)
(* registrations where session_id equaled the alias.                          *)
(* ------------------------------------------------------------------------- *)

let test_send_concurrent_session_id_equals_alias () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-a" ~alias:"session-a";
      register_alive broker ~session_id:"session-b" ~alias:"session-b";

      let send_unchecked ~from_ss ~to_alias ~content =
        let args = `Assoc [
          ("to_alias", `String to_alias);
          ("content", `String content);
        ] in
        Lwt_main.run
          (C2c_send_handlers.send ~broker
             ~session_id_override:(Some from_ss) ~arguments:args)
      in

      let send_ok ~from_ss ~to_alias ~content =
        let result = send_unchecked ~from_ss ~to_alias ~content in
        check bool (Printf.sprintf "%s→%s isError=false" from_ss to_alias)
          false (get_is_error result);
        ()
      in

      let send_self_err ~ss =
        let result = send_unchecked ~from_ss:ss ~to_alias:ss ~content:"talking to self" in
        check bool (Printf.sprintf "%s→%s isError=true" ss ss) true (get_is_error result);
        let text = get_text_content result in
        check bool "mentions yourself" true
          (contains_substring ~haystack:text ~needle:"yourself")
      in

      (* step 3: A sends to B — must succeed *)
      send_ok ~from_ss:"session-a" ~to_alias:"session-b" ~content:"hello from A";

      (* step 4: B sends to A — must succeed *)
      send_ok ~from_ss:"session-b" ~to_alias:"session-a" ~content:"hello from B";

      (* step 5: A sends to A — must fail *)
      send_self_err ~ss:"session-a";

      (* step 6: B sends to B — must fail *)
      send_self_err ~ss:"session-b")

(* ------------------------------------------------------------------------- *)
(* send: invalid tag value rejected before enqueue                            *)
(* ------------------------------------------------------------------------- *)

let test_send_invalid_tag () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-sender" ~alias:"sender";
      register_alive broker ~session_id:"session-recipient" ~alias:"recipient";
      let args = `Assoc [
        ("to_alias", `String "recipient");
        ("content", `String "hi");
        ("tag", `String "not-a-real-tag");
      ] in
      let result = Lwt_main.run
        (C2c_send_handlers.send ~broker
           ~session_id_override:(Some "session-sender") ~arguments:args)
      in
      check bool "isError=true on invalid tag" true (get_is_error result);
      let text = get_text_content result in
      check bool "mentions rejection" true
        (contains_substring ~haystack:text ~needle:"rejected"))

(* ------------------------------------------------------------------------- *)
(* send: happy-path basic — receipt has queued:true, from_alias, to_alias    *)
(* ------------------------------------------------------------------------- *)

let test_send_happy_path () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-sender" ~alias:"sender";
      register_alive broker ~session_id:"session-recipient" ~alias:"recipient";
      let args = `Assoc [
        ("to_alias", `String "recipient");
        ("content", `String "hello there");
      ] in
      let result = Lwt_main.run
        (C2c_send_handlers.send ~broker
           ~session_id_override:(Some "session-sender") ~arguments:args)
      in
      check bool "isError=false on happy path" false (get_is_error result);
      let body = yojson_of_string (get_text_content result) in
      let open Yojson.Safe.Util in
      check bool "queued=true" true (body |> member "queued" |> to_bool);
      check string "from_alias" "sender" (body |> member "from_alias" |> to_string);
      check string "to_alias" "recipient" (body |> member "to_alias" |> to_string);
      check bool "ts is present" true
        (match body |> member "ts" with `Float _ | `Int _ -> true | _ -> false))

(* ------------------------------------------------------------------------- *)
(* send: deferrable=true reflected in receipt + queued message               *)
(* ------------------------------------------------------------------------- *)

let test_send_deferrable_flag () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-sender" ~alias:"sender";
      register_alive broker ~session_id:"session-recipient" ~alias:"recipient";
      let args = `Assoc [
        ("to_alias", `String "recipient");
        ("content", `String "low-priority note");
        ("deferrable", `Bool true);
      ] in
      let result = Lwt_main.run
        (C2c_send_handlers.send ~broker
           ~session_id_override:(Some "session-sender") ~arguments:args)
      in
      check bool "isError=false" false (get_is_error result);
      let body = yojson_of_string (get_text_content result) in
      let open Yojson.Safe.Util in
      check bool "receipt.deferrable=true" true
        (body |> member "deferrable" |> to_bool);
      let drained = Broker.drain_inbox ~drained_by:"test"
        broker ~session_id:"session-recipient" in
      check int "one message queued" 1 (List.length drained);
      let msg = List.hd drained in
      check bool "queued msg.deferrable=true" true msg.C2c_mcp_helpers.deferrable)

(* ------------------------------------------------------------------------- *)
(* send: tag=fail prepends 🔴 FAIL: prefix to queued content                  *)
(* ------------------------------------------------------------------------- *)

let test_send_tag_fail_prefix () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-sender" ~alias:"sender";
      register_alive broker ~session_id:"session-recipient" ~alias:"recipient";
      let args = `Assoc [
        ("to_alias", `String "recipient");
        ("content", `String "review verdict");
        ("tag", `String "fail");
      ] in
      let result = Lwt_main.run
        (C2c_send_handlers.send ~broker
           ~session_id_override:(Some "session-sender") ~arguments:args)
      in
      check bool "isError=false on tag=fail" false (get_is_error result);
      let drained = Broker.drain_inbox ~drained_by:"test"
        broker ~session_id:"session-recipient" in
      check int "one message queued" 1 (List.length drained);
      let msg = List.hd drained in
      check bool "content has fail-tag prefix" true
        (contains_substring ~haystack:msg.C2c_mcp_helpers.content ~needle:"FAIL:");
      check bool "content preserves body" true
        (contains_substring ~haystack:msg.C2c_mcp_helpers.content ~needle:"review verdict"))

(* ------------------------------------------------------------------------- *)
(* send: tag=urgent prepends ⚠️ URGENT: prefix to queued content              *)
(* ------------------------------------------------------------------------- *)

let test_send_tag_urgent_prefix () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-sender" ~alias:"sender";
      register_alive broker ~session_id:"session-recipient" ~alias:"recipient";
      let args = `Assoc [
        ("to_alias", `String "recipient");
        ("content", `String "act now");
        ("tag", `String "urgent");
      ] in
      let result = Lwt_main.run
        (C2c_send_handlers.send ~broker
           ~session_id_override:(Some "session-sender") ~arguments:args)
      in
      check bool "isError=false on tag=urgent" false (get_is_error result);
      let drained = Broker.drain_inbox ~drained_by:"test"
        broker ~session_id:"session-recipient" in
      check int "one message queued" 1 (List.length drained);
      let msg = List.hd drained in
      check bool "content has urgent-tag prefix" true
        (contains_substring ~haystack:msg.C2c_mcp_helpers.content ~needle:"URGENT:"))

(* ------------------------------------------------------------------------- *)
(* send: ephemeral=true → message queued for drain, not appended to archive   *)
(* (We verify the receipt path; archive-skip is enforced by drain_inbox.)    *)
(* ------------------------------------------------------------------------- *)

let test_send_ephemeral_flag () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-sender" ~alias:"sender";
      register_alive broker ~session_id:"session-recipient" ~alias:"recipient";
      let args = `Assoc [
        ("to_alias", `String "recipient");
        ("content", `String "off the record");
        ("ephemeral", `Bool true);
      ] in
      let result = Lwt_main.run
        (C2c_send_handlers.send ~broker
           ~session_id_override:(Some "session-sender") ~arguments:args)
      in
      check bool "isError=false on ephemeral" false (get_is_error result);
      let drained = Broker.drain_inbox ~drained_by:"test"
        broker ~session_id:"session-recipient" in
      check int "one message queued" 1 (List.length drained);
      let msg = List.hd drained in
      check bool "queued msg.ephemeral=true" true msg.C2c_mcp_helpers.ephemeral)

(* ------------------------------------------------------------------------- *)
(* B127: send to a known-but-dead local alias → durable offline queue.       *)
(* MCP-parity check that the handler receipt sets queued_offline, the mail    *)
(* lands in the dead registration's inbox, and liveness is never faked.       *)
(* ------------------------------------------------------------------------- *)

let test_send_offline_queues_durably () =
  with_temp_dir (fun parent ->
      (* Nest the broker under a clean parent: the handler's dead-target
         fallback scans sibling broker roots in [dirname primary_root], so a
         broker placed directly in /tmp would scan all of /tmp. *)
      let dir = Filename.concat parent "broker" in
      Unix.mkdir dir 0o755;
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-sender" ~alias:"sender";
      register_dead broker ~session_id:"session-recipient" ~alias:"recipient";
      let args = `Assoc [
        ("to_alias", `String "recipient");
        ("content", `String "hold for resume");
      ] in
      let result = Lwt_main.run
        (C2c_send_handlers.send ~broker
           ~session_id_override:(Some "session-sender") ~arguments:args)
      in
      check bool "isError=false on offline queue" false (get_is_error result);
      let body = yojson_of_string (get_text_content result) in
      let open Yojson.Safe.Util in
      check bool "receipt.queued=true" true (body |> member "queued" |> to_bool);
      check bool "receipt.queued_offline=true" true
        (body |> member "queued_offline" |> to_bool);
      check string "from_alias" "sender" (body |> member "from_alias" |> to_string);
      check string "to_alias" "recipient" (body |> member "to_alias" |> to_string);
      (* Mail is durable in the dead registration's own inbox (no drain). *)
      let inbox = Broker.read_inbox broker ~session_id:"session-recipient" in
      check int "offline mail persisted to dead session inbox" 1
        (List.length inbox);
      check string "persisted content" "hold for resume"
        (List.hd inbox).C2c_mcp_helpers.content;
      (* Offline queueing must NOT resurrect the peer. *)
      let reg =
        List.find_opt
          (fun (r : C2c_mcp_helpers.registration) ->
            r.session_id = "session-recipient")
          (Broker.list_registrations broker)
      in
      (match reg with
       | Some r ->
           check bool "recipient still not alive after offline queue" false
             (Broker.registration_is_alive r)
       | None -> fail "recipient registration vanished"))

(* ------------------------------------------------------------------------- *)
(* B127: an ephemeral offline message keeps its ephemeral flag on the durable *)
(* row (it must be durable while waiting; archive-skip happens on drain).     *)
(* ------------------------------------------------------------------------- *)

let test_send_offline_preserves_ephemeral () =
  with_temp_dir (fun parent ->
      let dir = Filename.concat parent "broker" in
      Unix.mkdir dir 0o755;
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-sender" ~alias:"sender";
      register_dead broker ~session_id:"session-recipient" ~alias:"recipient";
      let args = `Assoc [
        ("to_alias", `String "recipient");
        ("content", `String "off the record, offline");
        ("ephemeral", `Bool true);
      ] in
      let result = Lwt_main.run
        (C2c_send_handlers.send ~broker
           ~session_id_override:(Some "session-sender") ~arguments:args)
      in
      check bool "isError=false" false (get_is_error result);
      let body = yojson_of_string (get_text_content result) in
      let open Yojson.Safe.Util in
      check bool "receipt.queued_offline=true" true
        (body |> member "queued_offline" |> to_bool);
      let inbox = Broker.read_inbox broker ~session_id:"session-recipient" in
      check int "one offline message persisted" 1 (List.length inbox);
      check bool "durable offline row keeps ephemeral=true" true
        (List.hd inbox).C2c_mcp_helpers.ephemeral)

(* ------------------------------------------------------------------------- *)
(* send_all: missing sender alias → error                                    *)
(* ------------------------------------------------------------------------- *)

let test_send_all_missing_sender () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-peer" ~alias:"peer";
      let args = `Assoc [("content", `String "broadcast")] in
      let result = Lwt_main.run
        (C2c_send_handlers.send_all ~broker
           ~session_id_override:(Some "session-orphan") ~arguments:args)
      in
      check bool "isError=true on missing sender" true (get_is_error result))

(* ------------------------------------------------------------------------- *)
(* send_all: basic broadcast — sent_to lists alive peers, excludes sender    *)
(* ------------------------------------------------------------------------- *)

let test_send_all_basic_broadcast () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-sender" ~alias:"sender";
      register_alive broker ~session_id:"session-a" ~alias:"peer-a";
      register_alive broker ~session_id:"session-b" ~alias:"peer-b";
      let args = `Assoc [("content", `String "hello swarm")] in
      let result = Lwt_main.run
        (C2c_send_handlers.send_all ~broker
           ~session_id_override:(Some "session-sender") ~arguments:args)
      in
      check bool "isError=false" false (get_is_error result);
      let body = yojson_of_string (get_text_content result) in
      let open Yojson.Safe.Util in
      let sent_aliases =
        body |> member "sent_to" |> to_list
        |> List.map (fun j -> to_string j)
        |> List.sort compare
      in
      check (list string) "sent_to is peer-a, peer-b (sender excluded)"
        ["peer-a"; "peer-b"] sent_aliases)

(* ------------------------------------------------------------------------- *)
(* send_all: exclude_aliases honored                                         *)
(* ------------------------------------------------------------------------- *)

let test_send_all_exclude_aliases () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-sender" ~alias:"sender";
      register_alive broker ~session_id:"session-a" ~alias:"peer-a";
      register_alive broker ~session_id:"session-b" ~alias:"peer-b";
      let args = `Assoc [
        ("content", `String "hello some");
        ("exclude_aliases", `List [`String "peer-a"]);
      ] in
      let result = Lwt_main.run
        (C2c_send_handlers.send_all ~broker
           ~session_id_override:(Some "session-sender") ~arguments:args)
      in
      check bool "isError=false" false (get_is_error result);
      let body = yojson_of_string (get_text_content result) in
      let open Yojson.Safe.Util in
      let sent_aliases =
        body |> member "sent_to" |> to_list
        |> List.map (fun j -> to_string j)
      in
      check (list string) "sent_to is just peer-b (peer-a excluded)"
        ["peer-b"] sent_aliases)

(* ------------------------------------------------------------------------- *)
(* send_all: tag=fail prepends 🔴 FAIL: prefix to queued content             *)
(* ------------------------------------------------------------------------- *)

let test_send_all_tag_fail_prefix () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-sender" ~alias:"sender";
      register_alive broker ~session_id:"session-a" ~alias:"peer-a";
      register_alive broker ~session_id:"session-b" ~alias:"peer-b";
      let args = `Assoc [
        ("content", `String "review verdict");
        ("tag", `String "fail");
      ] in
      let result = Lwt_main.run
        (C2c_send_handlers.send_all ~broker
           ~session_id_override:(Some "session-sender") ~arguments:args)
      in
      check bool "isError=false on tag=fail" false (get_is_error result);
      (* peer-a and peer-b should both have received the FAIL:-prefixed message *)
      let drain_a = Broker.drain_inbox ~drained_by:"test"
        broker ~session_id:"session-a" in
      check int "peer-a got one message" 1 (List.length drain_a);
      let msg_a = List.hd drain_a in
      check bool "peer-a content has fail-tag prefix" true
        (contains_substring ~haystack:msg_a.C2c_mcp_helpers.content ~needle:"FAIL:");
      check bool "peer-a content preserves body" true
        (contains_substring ~haystack:msg_a.C2c_mcp_helpers.content ~needle:"review verdict");
      let drain_b = Broker.drain_inbox ~drained_by:"test"
        broker ~session_id:"session-b" in
      check int "peer-b got one message" 1 (List.length drain_b);
      let msg_b = List.hd drain_b in
      check bool "peer-b content has fail-tag prefix" true
        (contains_substring ~haystack:msg_b.C2c_mcp_helpers.content ~needle:"FAIL:");
      check bool "peer-b content preserves body" true
        (contains_substring ~haystack:msg_b.C2c_mcp_helpers.content ~needle:"review verdict"))

(* ------------------------------------------------------------------------- *)
(* send_all: sender is the only registration → sent_to is empty              *)
(* ------------------------------------------------------------------------- *)

let test_send_all_no_recipients () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-sender" ~alias:"sender";
      let args = `Assoc [("content", `String "anyone there?")] in
      let result = Lwt_main.run
        (C2c_send_handlers.send_all ~broker
           ~session_id_override:(Some "session-sender") ~arguments:args)
      in
      check bool "isError=false on empty broadcast" false (get_is_error result);
      let body = yojson_of_string (get_text_content result) in
      let open Yojson.Safe.Util in
      let sent_aliases =
        body |> member "sent_to" |> to_list
        |> List.map (fun j -> to_string j)
      in
      check (list string) "sent_to is empty" [] sent_aliases)

(* ------------------------------------------------------------------------- *)
(* send_all: receipt contains encrypted/plaintext arrays (#671 S1)           *)
(* Local recipients always land in plaintext (encryption is relay-only).     *)
(* ------------------------------------------------------------------------- *)

let test_send_all_receipt_has_enc_arrays () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-sender" ~alias:"sender";
      register_alive broker ~session_id:"session-a" ~alias:"peer-a";
      register_alive broker ~session_id:"session-b" ~alias:"peer-b";
      let args = `Assoc [("content", `String "hello encrypted")] in
      let result = Lwt_main.run
        (C2c_send_handlers.send_all ~broker
           ~session_id_override:(Some "session-sender") ~arguments:args)
      in
      check bool "isError=false" false (get_is_error result);
      let body = yojson_of_string (get_text_content result) in
      let open Yojson.Safe.Util in
      (* Receipt must have encrypted, plaintext, and sent_to arrays *)
      let encrypted =
        body |> member "encrypted" |> to_list
        |> List.map (fun j -> to_string j)
        |> List.sort compare
      in
      let plaintext =
        body |> member "plaintext" |> to_list
        |> List.map (fun j -> to_string j)
        |> List.sort compare
      in
      let sent_to =
        body |> member "sent_to" |> to_list
        |> List.map (fun j -> to_string j)
        |> List.sort compare
      in
      let key_changed =
        body |> member "key_changed" |> to_list
        |> List.map (fun j -> to_string j)
      in
      (* Local peers → all plaintext, none encrypted, none key_changed *)
      check (list string) "encrypted is empty for local peers" [] encrypted;
      check (list string) "plaintext contains both peers"
        ["peer-a"; "peer-b"] plaintext;
      check (list string) "key_changed is empty" [] key_changed;
      check (list string) "sent_to = plaintext (all local)"
        ["peer-a"; "peer-b"] sent_to)

(* ------------------------------------------------------------------------- *)
(* send_all: empty broadcast receipt has empty enc arrays (#671 S1)          *)
(* ------------------------------------------------------------------------- *)

let test_send_all_empty_receipt_enc_arrays () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-sender" ~alias:"sender";
      let args = `Assoc [("content", `String "echo?")] in
      let result = Lwt_main.run
        (C2c_send_handlers.send_all ~broker
           ~session_id_override:(Some "session-sender") ~arguments:args)
      in
      check bool "isError=false" false (get_is_error result);
      let body = yojson_of_string (get_text_content result) in
      let open Yojson.Safe.Util in
      let encrypted =
        body |> member "encrypted" |> to_list in
      let plaintext =
        body |> member "plaintext" |> to_list in
      check int "encrypted empty" 0 (List.length encrypted);
      check int "plaintext empty" 0 (List.length plaintext))

(* ------------------------------------------------------------------------- *)
(* send_all: messages actually delivered to each recipient (#671 S1)         *)
(* Verifies per-recipient enqueue_message works (replaced Broker.send_all).  *)
(* ------------------------------------------------------------------------- *)

let test_send_all_per_recipient_delivery () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-sender" ~alias:"sender";
      register_alive broker ~session_id:"session-a" ~alias:"peer-a";
      register_alive broker ~session_id:"session-b" ~alias:"peer-b";
      register_alive broker ~session_id:"session-c" ~alias:"peer-c";
      let args = `Assoc [
        ("content", `String "broadcast msg");
        ("exclude_aliases", `List [`String "peer-b"]);
      ] in
      let result = Lwt_main.run
        (C2c_send_handlers.send_all ~broker
           ~session_id_override:(Some "session-sender") ~arguments:args)
      in
      check bool "isError=false" false (get_is_error result);
      (* peer-a and peer-c should have messages; peer-b excluded *)
      let drain_a = Broker.drain_inbox ~drained_by:"test"
        broker ~session_id:"session-a" in
      check int "peer-a got one message" 1 (List.length drain_a);
      let msg_a = List.hd drain_a in
      check string "peer-a content" "broadcast msg" msg_a.C2c_mcp_helpers.content;
      let drain_b = Broker.drain_inbox ~drained_by:"test"
        broker ~session_id:"session-b" in
      check int "peer-b excluded" 0 (List.length drain_b);
      let drain_c = Broker.drain_inbox ~drained_by:"test"
        broker ~session_id:"session-c" in
      check int "peer-c got one message" 1 (List.length drain_c);
      let msg_c = List.hd drain_c in
      check string "peer-c content" "broadcast msg" msg_c.C2c_mcp_helpers.content)

(* ------------------------------------------------------------------------- *)
(* send: MCP from_alias spoofing — when caller's session is NOT registered,  *)
(* from_alias from arguments is used. If that alias is held by a different   *)
(* alive session WITH a real PID, the send must be rejected.                 *)
(* ------------------------------------------------------------------------- *)

let register_with_fake_pid broker ~session_id ~alias ~pid =
  Broker.register broker ~session_id ~alias ~pid:(Some pid) ~pid_start_time:None ()

let test_send_spoofed_from_rejected () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      (* victim: registered with a real PID, alive (our own PID is always alive) *)
      let my_pid = Unix.getpid () in
      register_with_fake_pid broker ~session_id:"session-victim" ~alias:"victim" ~pid:my_pid;
      (* caller-session is NOT registered — forces from_alias from arguments *)
      let args = `Assoc [
        ("to_alias", `String "victim");
        ("content", `String "forged message");
        ("from_alias", `String "victim");
      ] in
      let result = Lwt_main.run
        (C2c_send_handlers.send ~broker
           ~session_id_override:(Some "session-attacker") ~arguments:args)
      in
      check bool "isError=true on spoofed from_alias" true (get_is_error result);
      let text = get_text_content result in
      check bool "mentions rejection" true
        (contains_substring ~haystack:text ~needle:"reject"))

(* ------------------------------------------------------------------------- *)
(* send: from_alias == caller's own alias → allowed                          *)
(* When a caller sends with from_alias matching their own registration,      *)
(* the send should succeed normally.                                         *)
(* ------------------------------------------------------------------------- *)

let test_send_own_from_allowed () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-sender" ~alias:"sender";
      register_alive broker ~session_id:"session-recipient" ~alias:"recipient";
      let args = `Assoc [
        ("to_alias", `String "recipient");
        ("content", `String "legit message");
        ("from_alias", `String "sender");
      ] in
      let result = Lwt_main.run
        (C2c_send_handlers.send ~broker
           ~session_id_override:(Some "session-sender") ~arguments:args)
      in
      check bool "isError=false on own from_alias" false (get_is_error result);
      let body = yojson_of_string (get_text_content result) in
      let open Yojson.Safe.Util in
      check bool "queued=true" true (body |> member "queued" |> to_bool);
      check string "from_alias" "sender" (body |> member "from_alias" |> to_string))

(* ------------------------------------------------------------------------- *)
(* send: from_alias not registered by any alive session → allowed            *)
(* An unregistered alias (no alive holder) can be used as from_alias.        *)
(* This covers operator/test usage and the relay fallback path.              *)
(* ------------------------------------------------------------------------- *)

let test_send_unregistered_from_allowed () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      register_alive broker ~session_id:"session-recipient" ~alias:"recipient";
      (* "ghost" is not registered at all *)
      let args = `Assoc [
        ("to_alias", `String "recipient");
        ("content", `String "test message from unregistered");
        ("from_alias", `String "ghost");
      ] in
      (* session "session-ghost" is also not registered — no alive session
         holds "ghost", so the impersonation check should pass *)
      let result = Lwt_main.run
        (C2c_send_handlers.send ~broker
           ~session_id_override:(Some "session-ghost") ~arguments:args)
      in
      check bool "isError=false on unregistered from_alias" false (get_is_error result);
      let drained = Broker.drain_inbox ~drained_by:"test"
        broker ~session_id:"session-recipient" in
      check int "one message delivered" 1 (List.length drained);
      let msg = List.hd drained in
      check string "from_alias is ghost" "ghost" msg.C2c_mcp_helpers.from_alias)

(* ------------------------------------------------------------------------- *)
(* send_all: spoofed from_alias held by alive session → rejected             *)
(* ------------------------------------------------------------------------- *)

let test_send_all_spoofed_from_rejected () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      let my_pid = Unix.getpid () in
      register_with_fake_pid broker ~session_id:"session-victim" ~alias:"victim" ~pid:my_pid;
      let args = `Assoc [
        ("content", `String "forged broadcast");
        ("from_alias", `String "victim");
      ] in
      let result = Lwt_main.run
        (C2c_send_handlers.send_all ~broker
           ~session_id_override:(Some "session-attacker") ~arguments:args)
      in
      check bool "isError=true on spoofed from_alias in send_all" true (get_is_error result);
      let text = get_text_content result in
      check bool "mentions rejection" true
        (contains_substring ~haystack:text ~needle:"reject"))

(* ------------------------------------------------------------------------- *)
(* send: case variation spoofing — from_alias with different case must be    *)
(* caught by alias_casefold comparison. E.g. "Victim" vs "victim".           *)
(* ------------------------------------------------------------------------- *)

let test_send_case_variation_spoofing_rejected () =
  with_temp_dir (fun dir ->
      let broker = Broker.create ~root:dir in
      let my_pid = Unix.getpid () in
      register_with_fake_pid broker ~session_id:"session-victim" ~alias:"Victim" ~pid:my_pid;
      let args = `Assoc [
        ("to_alias", `String "Victim");
        ("content", `String "case-forged message");
        ("from_alias", `String "victim");
      ] in
      let result = Lwt_main.run
        (C2c_send_handlers.send ~broker
           ~session_id_override:(Some "session-attacker") ~arguments:args)
      in
      check bool "isError=true on case-variation spoofed from_alias" true (get_is_error result);
      let text = get_text_content result in
      check bool "mentions rejection" true
        (contains_substring ~haystack:text ~needle:"reject"))

(* ------------------------------------------------------------------------- *)
(* Test suite                                                                *)
(* ------------------------------------------------------------------------- *)

let test_set = [
  "send missing sender alias", `Quick, test_send_missing_sender;
  "send self-send rejected", `Quick, test_send_self_rejected;
  "send concurrent session_id==alias no cross-contamination", `Quick, test_send_concurrent_session_id_equals_alias;
  "send invalid tag rejected", `Quick, test_send_invalid_tag;
  "send happy path", `Quick, test_send_happy_path;
  "send deferrable flag", `Quick, test_send_deferrable_flag;
  "send tag=fail prefix", `Quick, test_send_tag_fail_prefix;
  "send tag=urgent prefix", `Quick, test_send_tag_urgent_prefix;
  "send ephemeral flag", `Quick, test_send_ephemeral_flag;
  "send offline queues durably (B127)", `Quick, test_send_offline_queues_durably;
  "send offline preserves ephemeral (B127)", `Quick, test_send_offline_preserves_ephemeral;
  "send_all missing sender", `Quick, test_send_all_missing_sender;
  "send_all basic broadcast", `Quick, test_send_all_basic_broadcast;
  "send_all exclude_aliases", `Quick, test_send_all_exclude_aliases;
  "send_all tag=fail prefix", `Quick, test_send_all_tag_fail_prefix;
  "send_all no recipients", `Quick, test_send_all_no_recipients;
  "send_all receipt has encrypted/plaintext arrays", `Quick, test_send_all_receipt_has_enc_arrays;
  "send_all empty receipt has empty enc arrays", `Quick, test_send_all_empty_receipt_enc_arrays;
  "send_all per-recipient delivery", `Quick, test_send_all_per_recipient_delivery;
  "send spoofed from_alias rejected", `Quick, test_send_spoofed_from_rejected;
  "send own from_alias allowed", `Quick, test_send_own_from_allowed;
  "send unregistered from_alias allowed", `Quick, test_send_unregistered_from_allowed;
  "send_all spoofed from_alias rejected", `Quick, test_send_all_spoofed_from_rejected;
  "send case variation spoofing rejected", `Quick, test_send_case_variation_spoofing_rejected;
]

let () =
  Alcotest.run "c2c_send_handlers" [ "send_handlers", test_set ]
