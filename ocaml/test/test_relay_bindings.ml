(* Layer 3 slice 4 — registry schema + first-bind-wins for identity_pk *)

open Relay

let mk_pk b =
  String.make 32 b

let test_register_without_pk_legacy () =
  let r = InMemoryRelay.create () in
  let (status, _) =
    InMemoryRelay.register r ~node_id:"n1" ~session_id:"s1" ~alias:"alice" ()
  in
  Alcotest.(check string) "ok status" "ok" status;
  Alcotest.(check (option string)) "no binding recorded"
    None (InMemoryRelay.identity_pk_of r ~alias:"alice")

let test_first_bind_stores_pk () =
  let r = InMemoryRelay.create () in
  let pk = mk_pk '\x01' in
  let (status, _) =
    InMemoryRelay.register r ~node_id:"n1" ~session_id:"s1"
      ~alias:"alice" ~identity_pk:pk ()
  in
  Alcotest.(check string) "ok status" "ok" status;
  Alcotest.(check (option string)) "pk recorded"
    (Some pk) (InMemoryRelay.identity_pk_of r ~alias:"alice")

let test_rebind_same_pk_accepted () =
  let r = InMemoryRelay.create () in
  let pk = mk_pk '\x02' in
  let _ = InMemoryRelay.register r ~node_id:"n1" ~session_id:"s1"
    ~alias:"bob" ~identity_pk:pk () in
  let (status, _) =
    InMemoryRelay.register r ~node_id:"n1" ~session_id:"s1"
      ~alias:"bob" ~identity_pk:pk ()
  in
  Alcotest.(check string) "second register with same pk ok" "ok" status

let test_rebind_different_pk_rejected () =
  let r = InMemoryRelay.create () in
  let pk1 = mk_pk '\x03' in
  let pk2 = mk_pk '\x04' in
  let _ = InMemoryRelay.register r ~node_id:"n1" ~session_id:"s1"
    ~alias:"carol" ~identity_pk:pk1 () in
  let (status, _) =
    InMemoryRelay.register r ~node_id:"n1" ~session_id:"s1"
      ~alias:"carol" ~identity_pk:pk2 ()
  in
  Alcotest.(check string) "mismatch rejected"
    relay_err_alias_identity_mismatch status;
  Alcotest.(check (option string)) "binding unchanged"
    (Some pk1) (InMemoryRelay.identity_pk_of r ~alias:"carol")

let test_legacy_then_bind () =
  (* Register without a pk first, then supply one — should bind. *)
  let r = InMemoryRelay.create () in
  let _ = InMemoryRelay.register r ~node_id:"n1" ~session_id:"s1"
    ~alias:"dave" () in
  Alcotest.(check (option string)) "no binding yet"
    None (InMemoryRelay.identity_pk_of r ~alias:"dave");
  let pk = mk_pk '\x05' in
  let (status, _) =
    InMemoryRelay.register r ~node_id:"n1" ~session_id:"s1"
      ~alias:"dave" ~identity_pk:pk ()
  in
  Alcotest.(check string) "ok status" "ok" status;
  Alcotest.(check (option string)) "binding created on first pk"
    (Some pk) (InMemoryRelay.identity_pk_of r ~alias:"dave")

let tests = [
  "register_without_pk_legacy",  `Quick, test_register_without_pk_legacy;
  "first_bind_stores_pk",        `Quick, test_first_bind_stores_pk;
  "rebind_same_pk_accepted",     `Quick, test_rebind_same_pk_accepted;
  "rebind_different_pk_rejected",`Quick, test_rebind_different_pk_rejected;
  "legacy_then_bind",            `Quick, test_legacy_then_bind;
]

let () =
  Alcotest.run "relay_bindings" [ "layer3_slice4", tests ]
