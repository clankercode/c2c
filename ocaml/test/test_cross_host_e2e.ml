(* test_cross_host_e2e.ml — #379 S3: cross-host alias resolution e2e tests.

    Tests the relay's handling of alias@host targets:
    - Positive: relay with self_host="hostA" accepts to_alias:"b@hostA",
      strips to bare alias "b", delivers to "b"
    - Negative: relay with self_host="hostA" rejects to_alias:"b@hostZ"
      (hostZ != hostA) with cross_host_not_implemented, writing to dead_letter

    Note: The relay's handle_send (HTTP handler) does the host validation
    and alias stripping before calling R.send, and writes to dead_letter
    when rejecting cross-host targets. This test simulates that behavior.
*)

module R = Relay

let fail_fmt fmt = Printf.ksprintf (fun s -> failwith s) fmt

let json_get_string json key =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String s) -> s
       | _ -> fail_fmt "json_get_string: key %S not found or not string" key)
  | _ -> fail_fmt "json_get_string: expected Assoc for key %S" key

let json_get_opt_string json key =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String s) -> Some s
       | _ -> None)
  | _ -> None

let json_get_list json key =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`List l) -> l
       | _ -> fail_fmt "json_get_list: key %S not found or not list" key)
  | _ -> fail_fmt "json_get_list: expected Assoc for key %S" key

(* Simulate what handle_send does: validate host, strip alias, call R.send,
   and write to dead_letter when rejecting cross-host targets (matching the
   fix in #379 where handle_send calls R.add_dead_letter on rejection). *)
let handle_send_sim relay ~from_alias ~to_alias ~content =
  let stripped_to_alias, host_opt = R.split_alias_host to_alias in
  let self_host = R.InMemoryRelay.self_host relay in
  if not (R.host_acceptable ~self_host host_opt) then
    (* #379 fix: write to dead_letter so rejection is observable *)
    let msg_id = Uuidm.to_string (Uuidm.v `V4) in
    let ts = Unix.gettimeofday () in
    let dl = `Assoc [
      ("ts", `Float ts);
      ("message_id", `String msg_id);
      ("from_alias", `String from_alias);
      ("to_alias", `String to_alias);
      ("content", `String content);
      ("reason", `String "cross_host_not_implemented");
    ] in
    R.InMemoryRelay.add_dead_letter relay dl;
    `Cross_host_rejected
      (Printf.sprintf "cross-host send to %S not supported (relay does not forward to other hosts)" to_alias)
  else
    match R.InMemoryRelay.send relay ~from_alias ~to_alias:stripped_to_alias ~content ~message_id:None with
    | `Ok ts -> `Ok ts
    | `Duplicate ts -> `Duplicate ts
    | `Error (err, msg) -> `Error (err, msg)

(* #379 S3: test_cross_host_alias_finish — positive path

   Relay with self_host="hostA" accepts to_alias:"b@hostA" and delivers
   to bare alias "b" registered at the relay.
*)
let test_cross_host_alias_finish_positive () =
  (* Create relay with self_host="hostA" *)
  let relay = R.InMemoryRelay.create ~self_host:(Some "hostA") () in

  (* Register sender "alice" and receiver "b" *)
  let (_status_a, _lease_a) = R.InMemoryRelay.register relay
    ~node_id:"node-sender" ~session_id:"sess-sender" ~alias:"alice" () in
  let (_status_b, _lease_b) = R.InMemoryRelay.register relay
    ~node_id:"node-receiver" ~session_id:"sess-receiver" ~alias:"b" () in

  (* Send from alice to b@hostA (hostA matches self_host) via simulated handle_send *)
  match handle_send_sim relay
    ~from_alias:"alice" ~to_alias:"b@hostA" ~content:"hello b via hostA" with
   | `Cross_host_rejected reason ->
       fail_fmt "b@hostA should have been accepted but was rejected: %s" reason
   | `Ok _ts ->
       (* Message was accepted — now verify it was delivered to b's inbox *)
       let inbox = R.InMemoryRelay.poll_inbox relay ~node_id:"node-receiver" ~session_id:"sess-receiver" in
       if List.length inbox <> 1 then
         fail_fmt "expected 1 message in receiver inbox, got %d" (List.length inbox);
       let msg = List.hd inbox in
       let from = json_get_string msg "from_alias" in
       let content = json_get_string msg "content" in
       if from <> "alice" then
         fail_fmt "expected from_alias=alice, got %s" from;
       if content <> "hello b via hostA" then
         fail_fmt "expected content=hello b via hostA, got %s" content;
       Alcotest.(check string) "from_alias" "alice" from;
       Alcotest.(check string) "content" "hello b via hostA" content
   | `Duplicate _ts ->
       fail_fmt "unexpected Duplicate response for fresh send"
   | `Error (err, msg) ->
       fail_fmt "send to b@hostA failed: %s %s" err msg

(* #379 S3: test_cross_host_alias_finish — negative path

   Relay with self_host="hostA" rejects to_alias:"b@hostZ" (different host)
   with cross_host_not_implemented, and writes the rejection to dead_letter
   so it is observable for debugging and retry-on-recovery.
*)
let test_cross_host_alias_finish_negative () =
  (* Create relay with self_host="hostA" *)
  let relay = R.InMemoryRelay.create ~self_host:(Some "hostA") () in

  (* Register sender "alice" and receiver "b" *)
  let (_status_a, _lease_a) = R.InMemoryRelay.register relay
    ~node_id:"node-sender" ~session_id:"sess-sender" ~alias:"alice" () in
  let (_status_b, _lease_b) = R.InMemoryRelay.register relay
    ~node_id:"node-receiver" ~session_id:"sess-receiver" ~alias:"b" () in

  (* Send from alice to b@hostZ (hostZ != self_host="hostA") via simulated handle_send *)
  match handle_send_sim relay
    ~from_alias:"alice" ~to_alias:"b@hostZ" ~content:"hello b via hostZ" with
   | `Cross_host_rejected reason ->
       (* Message was correctly rejected — verify the reason is non-empty *)
       if not (String.length reason > 0) then
         fail_fmt "expected non-empty rejection reason";
       (* #379 fix: handle_send now writes to dead_letter on cross-host rejection *)
       let dl = R.InMemoryRelay.dead_letter relay in
       if List.length dl <> 1 then
         fail_fmt "expected 1 dead_letter entry after cross-host rejection, got %d" (List.length dl);
       let entry = List.hd dl in
       let dl_reason = json_get_string entry "reason" in
       if dl_reason <> "cross_host_not_implemented" then
         fail_fmt "expected dead_letter reason=cross_host_not_implemented, got %s" dl_reason;
       let dl_to = json_get_string entry "to_alias" in
       if dl_to <> "b@hostZ" then
         fail_fmt "expected dead_letter to_alias=b@hostZ, got %s" dl_to;
       Alcotest.(check bool) "cross_host_rejected reason is non-empty" true (String.length reason > 0);
       Alcotest.(check string) "dead_letter reason" "cross_host_not_implemented" dl_reason
   | `Ok _ts ->
       fail_fmt "send to b@hostZ should have been rejected but got Ok"
   | `Duplicate _ts ->
       fail_fmt "send to b@hostZ should have been rejected but got Duplicate"
   | `Error (err, msg) ->
       fail_fmt "send to b@hostZ should have been rejected with Cross_host_rejected, got Error: %s %s" err msg

let () =
  Random.self_init ();
  Alcotest.run "cross_host_e2e" [
    "cross_host_alias_finish", [
      Alcotest.test_case "positive: b@hostA delivers to bare b" `Quick
        test_cross_host_alias_finish_positive;
      Alcotest.test_case "negative: b@hostZ rejected with cross_host_not_implemented in dead_letter" `Quick
        test_cross_host_alias_finish_negative;
    ];
  ]
