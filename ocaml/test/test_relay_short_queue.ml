(* S6: ShortQueue ring buffer tests *)

open Relay_short_queue

let mk_msg ~ts ~from ~to_ ?room_id content =
  { ts; from_alias = from; to_alias = to_; room_id; content }

let approx_equal ~expected ~actual ~tol =
  abs_float (expected -. actual) < tol

let test_push_and_get_after () =
  let q = ShortQueue.create () in
  let msg1 = mk_msg ~ts:100.0 ~from:"alice" ~to_:"bob" "hello" in
  let msg2 = mk_msg ~ts:200.0 ~from:"carol" ~to_:"bob" "hiya" in
  ShortQueue.push q ~binding_id:"b1" msg1;
  ShortQueue.push q ~binding_id:"b1" msg2;
  let msgs = ShortQueue.get_after q ~binding_id:"b1" ~since_ts:0.0 in
  Alcotest.(check int) "two msgs returned" 2 (List.length msgs);
  Alcotest.(check bool) "first msg ts ~100" true (approx_equal ~expected:100.0 ~actual:(List.hd msgs).ts ~tol:0.001)

let test_get_after_filters_by_ts () =
  let q = ShortQueue.create () in
  let msg1 = mk_msg ~ts:100.0 ~from:"alice" ~to_:"bob" "msg1" in
  let msg2 = mk_msg ~ts:200.0 ~from:"carol" ~to_:"bob" "msg2" in
  ShortQueue.push q ~binding_id:"b1" msg1;
  ShortQueue.push q ~binding_id:"b1" msg2;
  let msgs = ShortQueue.get_after q ~binding_id:"b1" ~since_ts:150.0 in
  Alcotest.(check int) "only second msg" 1 (List.length msgs);
  Alcotest.(check bool) "second msg ts ~200" true (approx_equal ~expected:200.0 ~actual:(List.hd msgs).ts ~tol:0.001)

let test_get_after_unknown_binding () =
  let q = ShortQueue.create () in
  let msgs = ShortQueue.get_after q ~binding_id:"unknown" ~since_ts:0.0 in
  Alcotest.(check int) "empty for unknown binding" 0 (List.length msgs)

let test_oldest_ts () =
  let q = ShortQueue.create () in
  Alcotest.(check bool) "none initially" true (Option.is_none (ShortQueue.oldest_ts q ~binding_id:"b1"));
  let msg1 = mk_msg ~ts:300.0 ~from:"alice" ~to_:"bob" "msg1" in
  let msg2 = mk_msg ~ts:100.0 ~from:"carol" ~to_:"bob" "msg2" in
  ShortQueue.push q ~binding_id:"b1" msg1;
  ShortQueue.push q ~binding_id:"b1" msg2;
  Alcotest.(check bool) "oldest is 100" true (match ShortQueue.oldest_ts q ~binding_id:"b1" with Some t -> approx_equal ~expected:100.0 ~actual:t ~tol:0.001 | None -> false)

let test_oldest_ts_unknown () =
  let q = ShortQueue.create () in
  Alcotest.(check bool) "none for unknown" true (Option.is_none (ShortQueue.oldest_ts q ~binding_id:"unknown"))

let test_multiple_bindings () =
  let q = ShortQueue.create () in
  let msg_a = mk_msg ~ts:100.0 ~from:"a" ~to_:"b" "msg_a" in
  let msg_b = mk_msg ~ts:200.0 ~from:"c" ~to_:"d" "msg_b" in
  ShortQueue.push q ~binding_id:"binding_a" msg_a;
  ShortQueue.push q ~binding_id:"binding_b" msg_b;
  let msgs_a = ShortQueue.get_after q ~binding_id:"binding_a" ~since_ts:0.0 in
  let msgs_b = ShortQueue.get_after q ~binding_id:"binding_b" ~since_ts:0.0 in
  Alcotest.(check int) "binding_a has 1 msg" 1 (List.length msgs_a);
  Alcotest.(check int) "binding_b has 1 msg" 1 (List.length msgs_b);
  Alcotest.(check string) "binding_a content" "msg_a" (List.hd msgs_a).content;
  Alcotest.(check string) "binding_b content" "msg_b" (List.hd msgs_b).content

let test_room_id_preserved () =
  let q = ShortQueue.create () in
  let msg = mk_msg ~ts:100.0 ~from:"alice" ~to_:"bob" ~room_id:"swarm-lounge" "room msg" in
  ShortQueue.push q ~binding_id:"b1" msg;
  let msgs = ShortQueue.get_after q ~binding_id:"b1" ~since_ts:0.0 in
  Alcotest.(check int) "one msg" 1 (List.length msgs);
  Alcotest.(check (option string)) "room_id preserved" (Some "swarm-lounge") (List.hd msgs).room_id

let test_clear () =
  let q = ShortQueue.create () in
  let msg = mk_msg ~ts:100.0 ~from:"alice" ~to_:"bob" "hello" in
  ShortQueue.push q ~binding_id:"b1" msg;
  Alcotest.(check int) "has 1 msg before clear" 1 (List.length (ShortQueue.get_after q ~binding_id:"b1" ~since_ts:0.0));
  ShortQueue.clear q ~binding_id:"b1";
  Alcotest.(check int) "empty after clear" 0 (List.length (ShortQueue.get_after q ~binding_id:"b1" ~since_ts:0.0));
  Alcotest.(check bool) "oldest_ts none after clear" true (Option.is_none (ShortQueue.oldest_ts q ~binding_id:"b1"))

let test_cleanup () =
  let q = ShortQueue.create () in
  let old = mk_msg ~ts:100.0 ~from:"alice" ~to_:"bob" "old" in
  let recent = mk_msg ~ts:500.0 ~from:"carol" ~to_:"dave" "recent" in
  ShortQueue.push q ~binding_id:"b1" old;
  ShortQueue.push q ~binding_id:"b1" recent;
  let cleaned = ShortQueue.cleanup q ~older_than:300.0 in
  Alcotest.(check int) "cleaned 1 msg" 1 cleaned;
  let msgs = ShortQueue.get_after q ~binding_id:"b1" ~since_ts:0.0 in
  Alcotest.(check int) "one msg remains" 1 (List.length msgs);
  Alcotest.(check bool) "remaining is recent" true (approx_equal ~expected:500.0 ~actual:(List.hd msgs).ts ~tol:0.001)

let test_push_ring_overwrite () =
  let q = ShortQueue.create () in
  for i = 1 to 1005 do
    let msg = mk_msg ~ts:(float i) ~from:"a" ~to_:"b" (Printf.sprintf "msg%d" i) in
    ShortQueue.push q ~binding_id:"b1" msg
  done;
  let msgs = ShortQueue.get_after q ~binding_id:"b1" ~since_ts:0.0 in
  Alcotest.(check int) "max 1000 msgs in ring" 1000 (List.length msgs);
  let newest = (List.hd msgs).ts in
  let oldest = (List.hd (List.rev msgs)).ts in
  Alcotest.(check bool) "newest is msg1005" true (newest = 1005.0);
  Alcotest.(check bool) "oldest is msg6" true (oldest = 6.0)

let tests = [
  "push_and_get_after",       `Quick, test_push_and_get_after;
  "get_after_filters_by_ts",  `Quick, test_get_after_filters_by_ts;
  "get_after_unknown",        `Quick, test_get_after_unknown_binding;
  "oldest_ts",               `Quick, test_oldest_ts;
  "oldest_ts_unknown",        `Quick, test_oldest_ts_unknown;
  "multiple_bindings",        `Quick, test_multiple_bindings;
  "room_id_preserved",        `Quick, test_room_id_preserved;
  "clear",                   `Quick, test_clear;
  "cleanup",                 `Quick, test_cleanup;
  "push_ring_overwrite",      `Quick, test_push_ring_overwrite;
]

let () =
  Alcotest.run "relay_short_queue" [ "s6", tests ]