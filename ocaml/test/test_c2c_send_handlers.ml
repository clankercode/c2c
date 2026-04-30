(* #388 tests for #450 Slice 6 handler module: c2c_send_handlers.ml *)

open Alcotest
module Broker = C2c_broker

(* ------------------------------------------------------------------------- *)
(* Test infrastructure                                                       *)
(* ------------------------------------------------------------------------- *)

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base (Printf.sprintf "c2c-send-%06x" (Random.bits ())) in
  Unix.mkdir dir 0o755;
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
(* Test suite                                                                *)
(* ------------------------------------------------------------------------- *)

let test_set = [
  "send missing sender alias", `Quick, test_send_missing_sender;
  "send self-send rejected", `Quick, test_send_self_rejected;
  "send invalid tag rejected", `Quick, test_send_invalid_tag;
  "send happy path", `Quick, test_send_happy_path;
  "send deferrable flag", `Quick, test_send_deferrable_flag;
  "send tag=fail prefix", `Quick, test_send_tag_fail_prefix;
  "send tag=urgent prefix", `Quick, test_send_tag_urgent_prefix;
  "send ephemeral flag", `Quick, test_send_ephemeral_flag;
  "send_all missing sender", `Quick, test_send_all_missing_sender;
  "send_all basic broadcast", `Quick, test_send_all_basic_broadcast;
  "send_all exclude_aliases", `Quick, test_send_all_exclude_aliases;
  "send_all no recipients", `Quick, test_send_all_no_recipients;
]

let () =
  Alcotest.run "c2c_send_handlers" [ "send_handlers", test_set ]
