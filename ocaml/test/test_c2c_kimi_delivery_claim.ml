(* Hermetic tests for C2c_kimi_delivery_claim (P3.M1.E1.T001/T002). *)

open Alcotest

let ( // ) = Filename.concat

let with_temp f =
  let dir =
    Filename.get_temp_dir_name ()
    // Printf.sprintf "c2c-kimi-claim-%08x" (Random.bits ())
  in
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f dir)

let test_message_key_stable () =
  let k1 =
    C2c_kimi_delivery_claim.message_key ~from_alias:"a" ~ts:1.5
      ~content:"hello"
  in
  let k2 =
    C2c_kimi_delivery_claim.message_key ~from_alias:"a" ~ts:1.5
      ~content:"hello"
  in
  let k3 =
    C2c_kimi_delivery_claim.message_key ~from_alias:"a" ~ts:1.5
      ~content:"other"
  in
  check string "stable" k1 k2;
  check bool "distinct content" true (k1 <> k3);
  check int "12 hex" 12 (String.length k1)

let test_try_claim_exclusive () =
  with_temp @@ fun root ->
  let session_id = "sess-1" in
  let msg_key = "abc123def456" in
  (match
     C2c_kimi_delivery_claim.try_claim ~broker_root:root ~session_id ~msg_key
       ~claimant:"notifier" ~ttl_s:30. ()
   with
   | Claimed -> ()
   | Busy _ -> fail "first claim must succeed");
  (match
     C2c_kimi_delivery_claim.try_claim ~broker_root:root ~session_id ~msg_key
       ~claimant:"deliver-service" ~ttl_s:30. ()
   with
   | Busy { holder; _ } ->
       check (option string) "holder" (Some "notifier") holder
   | Claimed -> fail "second claim must be Busy");
  (* Same claimant re-claim is Claimed. *)
  (match
     C2c_kimi_delivery_claim.try_claim ~broker_root:root ~session_id ~msg_key
       ~claimant:"notifier" ~ttl_s:30. ()
   with
   | Claimed -> ()
   | Busy _ -> fail "same claimant re-claim")

let test_release_allows_other () =
  with_temp @@ fun root ->
  let session_id = "sess-2" in
  let msg_key = "deadbeef0012" in
  ignore
    (C2c_kimi_delivery_claim.try_claim ~broker_root:root ~session_id ~msg_key
       ~claimant:"notifier" ~ttl_s:30. ());
  C2c_kimi_delivery_claim.release ~broker_root:root ~session_id ~msg_key
    ~claimant:"notifier";
  match
    C2c_kimi_delivery_claim.try_claim ~broker_root:root ~session_id ~msg_key
      ~claimant:"deliver-service" ~ttl_s:30. ()
  with
  | Claimed -> ()
  | Busy _ -> fail "after release other must claim"

let test_ttl_expiry_reclaim () =
  with_temp @@ fun root ->
  let session_id = "sess-3" in
  let msg_key = "cafebabef00d" in
  ignore
    (C2c_kimi_delivery_claim.try_claim ~broker_root:root ~session_id ~msg_key
       ~claimant:"notifier" ~ttl_s:0.05 ());
  Unix.sleepf 0.12;
  match
    C2c_kimi_delivery_claim.try_claim ~broker_root:root ~session_id ~msg_key
      ~claimant:"deliver-service" ~ttl_s:30. ()
  with
  | Claimed -> ()
  | Busy _ -> fail "expired claim must be reclaimable"

let test_release_wrong_claimant_noop () =
  with_temp @@ fun root ->
  let session_id = "sess-4" in
  let msg_key = "112233445566" in
  ignore
    (C2c_kimi_delivery_claim.try_claim ~broker_root:root ~session_id ~msg_key
       ~claimant:"notifier" ~ttl_s:30. ());
  C2c_kimi_delivery_claim.release ~broker_root:root ~session_id ~msg_key
    ~claimant:"deliver-service";
  match
    C2c_kimi_delivery_claim.try_claim ~broker_root:root ~session_id ~msg_key
      ~claimant:"deliver-service" ~ttl_s:30. ()
  with
  | Busy _ -> ()
  | Claimed -> fail "wrong claimant release must not free claim"

let test_claim_path_broker_local () =
  with_temp @@ fun root ->
  let p =
    C2c_kimi_delivery_claim.claim_path ~broker_root:root ~session_id:"s"
      ~msg_key:"k"
  in
  check bool "under broker" true
    (String.length p > String.length root
     && String.sub p 0 (String.length root) = root);
  check bool "claims dir component" true
    (let d = C2c_kimi_delivery_claim.claims_dir ~broker_root:root in
     String.length p >= String.length d)

let () =
  Random.self_init ();
  run "c2c kimi delivery claim (P3 C2)"
    [ ( "keys"
      , [ test_case "message_key stable" `Quick test_message_key_stable
        ; test_case "claim path broker-local" `Quick
            test_claim_path_broker_local
        ] )
    ; ( "claims"
      , [ test_case "exclusive dual claimer" `Quick test_try_claim_exclusive
        ; test_case "release allows other" `Quick test_release_allows_other
        ; test_case "TTL expiry reclaim" `Quick test_ttl_expiry_reclaim
        ; test_case "wrong claimant release noop" `Quick
            test_release_wrong_claimant_noop
        ] )
    ]
