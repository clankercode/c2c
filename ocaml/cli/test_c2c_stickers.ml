(* test_c2c_stickers.ml — golden tests for the sticker envelope schema (#434).

   Slice S1 of the sticker-react implementation plan covers the PURE
   data-layer change: bumping the envelope to v2 and adding
   [target_msg_id]. This test file pins:

   - canonical_blob v1 byte-for-byte (legacy 8-field format, unchanged)
   - canonical_blob v2 byte-for-byte (new 9-field format with
     target_msg_id_or_empty)
   - envelope_of_json forward-compat: a v2 JSON missing [target_msg_id]
     decodes with [None] (we get this for free off the OCaml record
     decoder, but pin it so we don't regress)
   - sign-then-verify roundtrip for all three shapes:
     v1 envelope, v2 with target_msg_id, v2 with no target_msg_id
   - tamper detection: flipping target_msg_id post-sign breaks verify

   No filesystem; no [create_and_store]. Storage layout is a separate
   concern from schema, and the slice plan mandates these are pure
   data-layer goldens. *)

open Alcotest

(* --- helpers ----------------------------------------------------------- *)

let dummy_identity () =
  Mirage_crypto_rng_unix.use_default ();
  Relay_identity.generate ~alias_hint:"sticker-test" ()

let b64url_nopad s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

(* Build an envelope with deterministic ts/nonce so the canonical blob is
   pinnable. We do NOT try to pin the signature — Ed25519 from a fresh
   identity is non-deterministic across runs. We pin the *blob* and
   verify the signature roundtrips. *)
let mk_v1_env ~from_ ~to_ ~sticker_id ~note ~scope ~ts ~nonce ~sender_pk =
  C2c_stickers.{
    version = 1;
    from_;
    to_;
    sticker_id;
    note;
    target_msg_id = None;
    scope;
    ts;
    nonce;
    sender_pk;
    signature = "";
  }

let mk_v2_env ~from_ ~to_ ~sticker_id ~note ~target_msg_id ~scope ~ts ~nonce ~sender_pk =
  C2c_stickers.{
    version = 2;
    from_;
    to_;
    sticker_id;
    note;
    target_msg_id;
    scope;
    ts;
    nonce;
    sender_pk;
    signature = "";
  }

(* --- canonical_blob goldens -------------------------------------------- *)

let test_canonical_blob_v1_no_note () =
  let env = mk_v1_env
    ~from_:"alice" ~to_:"bob" ~sticker_id:"on-point"
    ~note:None ~scope:`Private
    ~ts:"2026-04-29T01:23:45Z" ~nonce:"AAAAAAAAAAAAAAAAAAAAAA"
    ~sender_pk:"PK"
  in
  let blob = C2c_stickers.canonical_blob env in
  check string "v1 8-field format, no note"
    "1|alice|bob|on-point||private|2026-04-29T01:23:45Z|AAAAAAAAAAAAAAAAAAAAAA"
    blob

let test_canonical_blob_v1_with_note () =
  let env = mk_v1_env
    ~from_:"alice" ~to_:"bob" ~sticker_id:"insight"
    ~note:(Some "great catch") ~scope:`Public
    ~ts:"2026-04-29T01:23:45Z" ~nonce:"NONCE0"
    ~sender_pk:"PK"
  in
  check string "v1 with note inlined"
    "1|alice|bob|insight|great catch|public|2026-04-29T01:23:45Z|NONCE0"
    (C2c_stickers.canonical_blob env)

let test_canonical_blob_v2_with_target () =
  let env = mk_v2_env
    ~from_:"alice" ~to_:"bob" ~sticker_id:"on-point"
    ~note:None ~target_msg_id:(Some "msg-abc123")
    ~scope:`Private
    ~ts:"2026-04-29T01:23:45Z" ~nonce:"NONCE0"
    ~sender_pk:"PK"
  in
  check string "v2 9-field format with target_msg_id"
    "2|alice|bob|on-point||private|2026-04-29T01:23:45Z|NONCE0|msg-abc123"
    (C2c_stickers.canonical_blob env)

let test_canonical_blob_v2_no_target () =
  (* v2 envelope WITHOUT target_msg_id is well-defined: empty string in
     the 9th field. This guarantees the blob is unambiguous: a v2 with
     None target_msg_id and a v1 envelope with the same other fields
     produce DIFFERENT blobs (different leading version, different field
     count), so the version-switched verification is collision-free. *)
  let env = mk_v2_env
    ~from_:"alice" ~to_:"bob" ~sticker_id:"on-point"
    ~note:None ~target_msg_id:None
    ~scope:`Private
    ~ts:"2026-04-29T01:23:45Z" ~nonce:"NONCE0"
    ~sender_pk:"PK"
  in
  check string "v2 with None target_msg_id keeps trailing empty field"
    "2|alice|bob|on-point||private|2026-04-29T01:23:45Z|NONCE0|"
    (C2c_stickers.canonical_blob env)

let test_v1_and_v2_blobs_differ_for_same_data () =
  (* Same surface fields → version controls the blob shape. This is the
     load-bearing guarantee for back-compat: an old v1 file on disk
     re-verifies because its version=1 in JSON drives the v1 blob. *)
  let v1 = mk_v1_env
    ~from_:"a" ~to_:"b" ~sticker_id:"on-point"
    ~note:None ~scope:`Private
    ~ts:"T" ~nonce:"N" ~sender_pk:"PK"
  in
  let v2 = mk_v2_env
    ~from_:"a" ~to_:"b" ~sticker_id:"on-point"
    ~note:None ~target_msg_id:None ~scope:`Private
    ~ts:"T" ~nonce:"N" ~sender_pk:"PK"
  in
  check bool "v1 and v2 produce different canonical blobs" true
    (C2c_stickers.canonical_blob v1 <> C2c_stickers.canonical_blob v2)

(* --- sign + verify roundtrips ------------------------------------------ *)

let sign_with id env =
  let env = { env with C2c_stickers.sender_pk = b64url_nopad id.Relay_identity.public_key } in
  C2c_stickers.sign_envelope ~identity:id env

let test_v1_roundtrip () =
  let id = dummy_identity () in
  let env = mk_v1_env
    ~from_:"alice" ~to_:"bob" ~sticker_id:"on-point"
    ~note:(Some "for the catch") ~scope:`Private
    ~ts:"2026-04-29T01:23:45Z" ~nonce:"NONCE_V1"
    ~sender_pk:""
  in
  let signed = sign_with id env in
  match C2c_stickers.verify_envelope signed with
  | Ok true -> ()
  | Ok false -> fail "v1 roundtrip: verify returned Ok false"
  | Error e -> failf "v1 roundtrip: %s" e

let test_v2_with_target_roundtrip () =
  let id = dummy_identity () in
  let env = mk_v2_env
    ~from_:"alice" ~to_:"bob" ~sticker_id:"on-point"
    ~note:None ~target_msg_id:(Some "msg-abc123")
    ~scope:`Private
    ~ts:"2026-04-29T01:23:45Z" ~nonce:"NONCE_V2A"
    ~sender_pk:""
  in
  let signed = sign_with id env in
  match C2c_stickers.verify_envelope signed with
  | Ok true -> ()
  | Ok false -> fail "v2(reaction) roundtrip: verify returned Ok false"
  | Error e -> failf "v2(reaction) roundtrip: %s" e

let test_v2_without_target_roundtrip () =
  let id = dummy_identity () in
  let env = mk_v2_env
    ~from_:"alice" ~to_:"bob" ~sticker_id:"on-point"
    ~note:None ~target_msg_id:None
    ~scope:`Private
    ~ts:"2026-04-29T01:23:45Z" ~nonce:"NONCE_V2B"
    ~sender_pk:""
  in
  let signed = sign_with id env in
  match C2c_stickers.verify_envelope signed with
  | Ok true -> ()
  | Ok false -> fail "v2(no-target) roundtrip: verify returned Ok false"
  | Error e -> failf "v2(no-target) roundtrip: %s" e

let test_tamper_target_msg_id () =
  (* Sign a v2 envelope with target_msg_id=Some "A", then flip to
     Some "B" without re-signing. verify must fail. This is the test
     that justifies including target_msg_id in the v2 canonical blob. *)
  let id = dummy_identity () in
  let env = mk_v2_env
    ~from_:"alice" ~to_:"bob" ~sticker_id:"on-point"
    ~note:None ~target_msg_id:(Some "msg-A")
    ~scope:`Private
    ~ts:"2026-04-29T01:23:45Z" ~nonce:"NONCE_TAMPER"
    ~sender_pk:""
  in
  let signed = sign_with id env in
  let tampered = { signed with C2c_stickers.target_msg_id = Some "msg-B" } in
  match C2c_stickers.verify_envelope tampered with
  | Ok true -> fail "tamper test: verify wrongly returned Ok true"
  | Ok false -> ()
  | Error _ -> ()  (* either Ok false or Error is acceptable failure *)

(* --- JSON forward-compat ----------------------------------------------- *)

(* Note: Yojson.Safe.to_string sorts/preserves the assoc order in
   envelope_to_json. We don't pin the JSON byte-for-byte (assoc order is
   an implementation detail of the encoder); we exercise the pair-wise
   roundtrip and the missing-field decode. *)

let make_json_no_target_field () =
  (* A v2 envelope JSON that OMITS the target_msg_id field. This shape
     happens when an old encoder wrote it OR the field was None. The
     decoder must produce target_msg_id = None either way. *)
  `Assoc [
    ("version", `Int 2);
    ("from", `String "alice");
    ("to", `String "bob");
    ("sticker_id", `String "on-point");
    ("scope", `String "private");
    ("ts", `String "2026-04-29T01:23:45Z");
    ("nonce", `String "NONCE0");
    ("sender_pk", `String "PK");
    ("signature", `String "SIG");
  ]

let test_decode_v2_missing_target_field () =
  match C2c_stickers.envelope_of_json (make_json_no_target_field ()) with
  | Error msg -> failf "decode failed: %s" msg
  | Ok env ->
    check int "version preserved" 2 env.C2c_stickers.version;
    check (option string) "missing target_msg_id decodes to None"
      None env.C2c_stickers.target_msg_id

let test_decode_v1_legacy_no_target_field () =
  (* A v1 JSON has no target_msg_id field; the decoded envelope must
     have target_msg_id = None and version = 1. *)
  let json = `Assoc [
    ("version", `Int 1);
    ("from", `String "alice");
    ("to", `String "bob");
    ("sticker_id", `String "on-point");
    ("scope", `String "private");
    ("ts", `String "2026-04-29T01:23:45Z");
    ("nonce", `String "NONCE0");
    ("sender_pk", `String "PK");
    ("signature", `String "SIG");
  ] in
  match C2c_stickers.envelope_of_json json with
  | Error msg -> failf "decode failed: %s" msg
  | Ok env ->
    check int "version 1 preserved" 1 env.C2c_stickers.version;
    check (option string) "v1 has no target_msg_id"
      None env.C2c_stickers.target_msg_id

let test_json_roundtrip_v2_with_target () =
  let env = mk_v2_env
    ~from_:"alice" ~to_:"bob" ~sticker_id:"on-point"
    ~note:(Some "great catch") ~target_msg_id:(Some "msg-abc")
    ~scope:`Private
    ~ts:"2026-04-29T01:23:45Z" ~nonce:"NONCE0"
    ~sender_pk:"PK"
  in
  let env = { env with C2c_stickers.signature = "SIG" } in
  let json = C2c_stickers.envelope_to_json env in
  match C2c_stickers.envelope_of_json json with
  | Error msg -> failf "roundtrip decode failed: %s" msg
  | Ok env' ->
    check int "version" 2 env'.C2c_stickers.version;
    check string "from" "alice" env'.C2c_stickers.from_;
    check string "to" "bob" env'.C2c_stickers.to_;
    check string "sticker_id" "on-point" env'.C2c_stickers.sticker_id;
    check (option string) "note" (Some "great catch") env'.C2c_stickers.note;
    check (option string) "target_msg_id" (Some "msg-abc")
      env'.C2c_stickers.target_msg_id

(* --- harness ----------------------------------------------------------- *)

let () =
  run "c2c_stickers schema v2"
    [ "canonical_blob",
      [ test_case "v1 8-field, no note" `Quick test_canonical_blob_v1_no_note
      ; test_case "v1 8-field, with note" `Quick test_canonical_blob_v1_with_note
      ; test_case "v2 9-field, with target_msg_id" `Quick test_canonical_blob_v2_with_target
      ; test_case "v2 9-field, target_msg_id=None" `Quick test_canonical_blob_v2_no_target
      ; test_case "v1 vs v2 differ for same surface fields" `Quick
          test_v1_and_v2_blobs_differ_for_same_data
      ]
    ; "sign+verify",
      [ test_case "v1 envelope" `Quick test_v1_roundtrip
      ; test_case "v2 reaction (target_msg_id=Some)" `Quick test_v2_with_target_roundtrip
      ; test_case "v2 peer-addressed (target_msg_id=None)" `Quick
          test_v2_without_target_roundtrip
      ; test_case "tamper target_msg_id breaks verify" `Quick test_tamper_target_msg_id
      ]
    ; "json",
      [ test_case "decode v2 JSON missing target field => None" `Quick
          test_decode_v2_missing_target_field
      ; test_case "decode v1 legacy JSON => target=None, version=1" `Quick
          test_decode_v1_legacy_no_target_field
      ; test_case "v2 with target roundtrips through to_json/of_json" `Quick
          test_json_roundtrip_v2_with_target
      ]
    ]
