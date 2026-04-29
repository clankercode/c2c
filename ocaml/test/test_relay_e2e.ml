(* Unit tests for relay_e2e.ml — S3 E2E encryption.
   Spec: M1-breakdown.md §S3. *)

open Relay_e2e

let test_enc_status () =
  Alcotest.(check string) "Ok" "ok" (enc_status_to_string Ok);
  Alcotest.(check string) "Plain" "plain" (enc_status_to_string Plain);
  Alcotest.(check string) "Failed" "failed" (enc_status_to_string Failed);
  Alcotest.(check string) "Not_for_me" "not-for-me" (enc_status_to_string Not_for_me);
  Alcotest.(check string) "Downgrade_warning" "downgrade-warning" (enc_status_to_string Downgrade_warning);
  Alcotest.(check string) "Key_changed" "key-changed" (enc_status_to_string Key_changed)

let test_sign_verify_roundtrip () =
  Mirage_crypto_rng_unix.use_default ();
  let priv, pub = Mirage_crypto_ec.Ed25519.generate () in
  let seed = Mirage_crypto_ec.Ed25519.priv_to_octets priv in
  let pk_raw = Mirage_crypto_ec.Ed25519.pub_to_octets pub in
  let msg = "hello world" in
  let sig_bytes = sign_ed25519 ~sk_seed:seed msg in
  Alcotest.(check bool) "verify ok" true (verify_ed25519 ~pk:pk_raw ~msg ~sig_:sig_bytes);
  Alcotest.(check bool) "verify tampered fails" false (verify_ed25519 ~pk:pk_raw ~msg:"tampered" ~sig_:sig_bytes)

let test_box_roundtrip () =
  Mirage_crypto_rng_unix.use_default ();
  let sk, pk_raw = Mirage_crypto_ec.X25519.gen_key () in
  let sk_seed = Mirage_crypto_ec.X25519.secret_to_octets sk in
  let pk_bytes = Bytes.of_string pk_raw in
  let pt = "secret message" in
  let nonce = random_nonce () in
  let boxed = match Hacl_star.Hacl.NaCl.box ~pt:(Bytes.of_string pt) ~n:(Bytes.of_string nonce) ~pk:pk_bytes ~sk:(Bytes.of_string sk_seed) with
    | Some ct -> ct
    | None -> Alcotest.fail "box returned None"
  in
  let opened = Hacl_star.Hacl.NaCl.box_open ~ct:boxed ~n:(Bytes.of_string nonce) ~pk:pk_bytes ~sk:(Bytes.of_string sk_seed) in
  match opened with
  | Some pt' -> Alcotest.(check string) "roundtrip ok" pt (Bytes.unsafe_to_string pt')
  | None -> Alcotest.fail "box_open returned None"

let test_canonical_json_byte_stability () =
  let e = {
    from_ = "alice";
    from_x25519 = None;
    from_ed25519 = None;
    to_ = Some "bob";
    room = None;
    ts = 1234567890L;
    enc = "box-x25519-v1";
    recipients = [ { alias = "bob"; nonce = Some "nonce123"; ciphertext = "ct123" } ];
    sig_b64 = "sig123";
    envelope_version = 1;
  } in
  let json1 = canonical_json e in
  let json2 = canonical_json e in
  Alcotest.(check string) "byte-stable" json1 json2

let test_canonical_json_sorted () =
  let e = {
    from_ = "alice";
    from_x25519 = None;
    from_ed25519 = None;
    to_ = Some "bob";
    room = None;
    ts = 1234567890L;
    enc = "box-x25519-v1";
    recipients = [ { alias = "bob"; nonce = Some "nonce123"; ciphertext = "ct123" } ];
    sig_b64 = "sig123";
    envelope_version = 1;
  } in
  let json = canonical_json e in
  let enc_pos = try String.index json 'e' with Not_found -> -1 in
  let from_pos = try String.index json 'f' with Not_found -> -1 in
  Alcotest.(check bool) "enc before from in sorted output" (enc_pos < from_pos) true

let test_downgrade_detection () =
  let ds = make_downgrade_state () in
  let e_plain = { from_ = "alice"; from_x25519 = None; from_ed25519 = None; to_ = Some "bob"; room = None; ts = 1L; enc = "plain"; recipients = []; sig_b64 = ""; envelope_version = 1 } in
  let (status, ds) = decide_enc_status ds e_plain in
  Alcotest.(check string) "first msg plain -> Plain" (enc_status_to_string status) "plain";
  let e_enc = { e_plain with enc = "box-x25519-v1" } in
  let (status, ds) = decide_enc_status ds e_enc in
  Alcotest.(check string) "encrypted after plain -> Ok" (enc_status_to_string status) "ok";
  let (status, _) = decide_enc_status ds e_plain in
  Alcotest.(check string) "plain after encrypted -> downgrade-warning" (enc_status_to_string status) "downgrade-warning"

let test_find_my_recipient_hit () =
  let recipients = [ { alias = "alice"; nonce = None; ciphertext = "" }; { alias = "bob"; nonce = Some "n"; ciphertext = "ct" } ] in
  match find_my_recipient ~my_alias:"bob" recipients with
  | Some r -> Alcotest.(check string) "found bob" r.alias "bob"
  | None -> Alcotest.fail "expected to find bob"

let test_find_my_recipient_miss () =
  let recipients = [ { alias = "alice"; nonce = None; ciphertext = "" } ] in
  match find_my_recipient ~my_alias:"bob" recipients with
  | Some _ -> Alcotest.fail "should not have found bob"
  | None -> Alcotest.(check unit) "miss ok" () ()

(* #alias-casefold: sender-written recipient entry "Bob" must still
   resolve when receiver's [my_alias] resolves as "bob". *)
let test_find_my_recipient_case_insensitive () =
  let recipients = [
    { alias = "alice"; nonce = None; ciphertext = "" };
    { alias = "Bob"; nonce = Some "n"; ciphertext = "ct" };
  ] in
  match find_my_recipient ~my_alias:"bob" recipients with
  | Some r -> Alcotest.(check string) "found Bob via lowercase 'bob'" r.alias "Bob"
  | None -> Alcotest.fail "expected to find Bob via case-insensitive lookup"

let test_tofu_mismatch () =
  Alcotest.(check bool) "same pk = no mismatch" false (check_pinned_ed25519_mismatch ~pinned_pk:"abc" ~claimed_pk:"abc");
  Alcotest.(check bool) "diff pk = mismatch" true (check_pinned_ed25519_mismatch ~pinned_pk:"abc" ~claimed_pk:"def");
  Alcotest.(check bool) "x25519 same = no mismatch" false (check_pinned_x25519_mismatch ~pinned_pk:"xyz" ~claimed_pk:"xyz");
  Alcotest.(check bool) "x25519 diff = mismatch" true (check_pinned_x25519_mismatch ~pinned_pk:"xyz" ~claimed_pk:"uvw")

(* CRIT-1 / Slice A — v1/v2 canonical_json dispatch.
   Plan: .collab/design/2026-04-29-relay-crypto-crit-fix-plan-cairn.md *)

(* Helper: generate an Ed25519 keypair; return (sk_seed, pk_raw). *)
let gen_ed25519 () =
  Mirage_crypto_rng_unix.use_default ();
  let priv, pub = Mirage_crypto_ec.Ed25519.generate () in
  let seed = Mirage_crypto_ec.Ed25519.priv_to_octets priv in
  let pk_raw = Mirage_crypto_ec.Ed25519.pub_to_octets pub in
  seed, pk_raw

(* CRIT-1 core — v2 envelope binds [from_x25519] in the signed blob.
   Mutating the field after signing must invalidate the signature. *)
let test_canonical_v2_includes_from_x25519 () =
  let seed, pk_raw = gen_ed25519 () in
  let e = {
    from_ = "alice";
    from_x25519 = Some "AAAA-x25519-pubkey-original";
    from_ed25519 = None;
    to_ = Some "bob";
    room = None;
    ts = 1700000000L;
    enc = "box-x25519-v1";
    recipients = [ { alias = "bob"; nonce = Some "nonce"; ciphertext = "ct" } ];
    sig_b64 = "";
    envelope_version = 2;
  } in
  let signed = set_sig e ~sk_seed:seed in
  Alcotest.(check bool) "v2 sig verifies" true (verify_envelope_sig ~pk:pk_raw signed);
  (* Mutate from_x25519 (attacker key swap); sig must fail. *)
  let mutated = { signed with from_x25519 = Some "BBBB-attacker-x25519" } in
  Alcotest.(check bool) "v2 verify rejects from_x25519 swap" false (verify_envelope_sig ~pk:pk_raw mutated);
  (* Sanity — also fails if from_x25519 is dropped to None. *)
  let dropped = { signed with from_x25519 = None } in
  Alcotest.(check bool) "v2 verify rejects from_x25519 drop" false (verify_envelope_sig ~pk:pk_raw dropped)

(* Back-compat — a v1 envelope (no envelope_version on wire, parsed as
   1) signs/verifies under v1 canonical_json with the new code. *)
let test_v1_back_compat_verify () =
  let seed, pk_raw = gen_ed25519 () in
  (* Hand-construct a v1-shape envelope (no from_x25519 covered). *)
  let e = {
    from_ = "legacy-sender";
    from_x25519 = None;
    from_ed25519 = None;
    to_ = Some "bob";
    room = None;
    ts = 1700000001L;
    enc = "box-x25519-v1";
    recipients = [ { alias = "bob"; nonce = Some "n"; ciphertext = "c" } ];
    sig_b64 = "";
    envelope_version = 1;
  } in
  let signed = set_sig e ~sk_seed:seed in
  Alcotest.(check bool) "v1 envelope verifies under new verifier" true (verify_envelope_sig ~pk:pk_raw signed);
  (* envelope_to_json on a v1 envelope must omit the envelope_version key
     so legacy wire bytes are unchanged. *)
  let json = envelope_to_json signed in
  let has_version_key = match json with
    | `Assoc fields -> List.mem_assoc "envelope_version" fields
    | _ -> false
  in
  Alcotest.(check bool) "v1 wire JSON omits envelope_version key" false has_version_key;
  (* envelope_of_json on a v1-shape JSON (no envelope_version key) must
     default the field to 1 so verify_envelope_sig dispatches v1 shape. *)
  let v1_wire = `Assoc [
    "from",       `String "legacy-sender";
    "to",         `String "bob";
    "room",       `Null;
    "ts",         `String "1700000001";
    "enc",        `String "box-x25519-v1";
    "recipients", `List [ `Assoc [
      "alias", `String "bob";
      "nonce", `String "n";
      "ciphertext", `String "c";
    ] ];
    "sig",        `String signed.sig_b64;
  ] in
  let parsed = envelope_of_json v1_wire in
  Alcotest.(check int) "wire parse defaults envelope_version to 1" 1 parsed.envelope_version;
  Alcotest.(check bool) "v1 envelope round-trips and verifies" true (verify_envelope_sig ~pk:pk_raw parsed)

(* Cutover-window contract: a v2-signed blob does NOT verify if the
   verifier ignores the envelope_version (i.e. attempts a v1-shape
   canonicalize). Documents why the verifier must dispatch on the
   self-claimed version field. *)
let test_v2_envelope_rejects_v1_verify_path () =
  let seed, pk_raw = gen_ed25519 () in
  let e_v2 = {
    from_ = "alice";
    from_x25519 = Some "AAAA-x25519-pk";
    from_ed25519 = None;
    to_ = Some "bob";
    room = None;
    ts = 1700000002L;
    enc = "box-x25519-v1";
    recipients = [ { alias = "bob"; nonce = Some "n"; ciphertext = "c" } ];
    sig_b64 = "";
    envelope_version = 2;
  } in
  let signed_v2 = set_sig e_v2 ~sk_seed:seed in
  Alcotest.(check bool) "v2 verifies normally" true (verify_envelope_sig ~pk:pk_raw signed_v2);
  (* Simulate a v1-only verifier: copy with envelope_version forced to
     1, which dispatches canonical_json to v1 shape (no from_x25519). *)
  let as_if_v1 = { signed_v2 with envelope_version = 1 } in
  Alcotest.(check bool) "v2-signed blob fails under v1-shape canonicalize" false (verify_envelope_sig ~pk:pk_raw as_if_v1)

(* Omit-key-when-None semantics: producer with [from_x25519 = None] under
   v2 — canonical blob does NOT include the "from_x25519" key at all
   (NOT included as a `Null), and verify still works. *)
let test_omit_from_x25519_v2_canonicalize () =
  let seed, pk_raw = gen_ed25519 () in
  let e = {
    from_ = "alice";
    from_x25519 = None;
    from_ed25519 = None;
    to_ = Some "bob";
    room = None;
    ts = 1700000003L;
    enc = "plain";
    recipients = [];
    sig_b64 = "";
    envelope_version = 2;
  } in
  let canon = canonical_json e in
  Alcotest.(check bool) "v2 canonical omits from_x25519 key when None"
    false
    (try ignore (Str.search_forward (Str.regexp_string "from_x25519") canon 0); true
     with Not_found -> false);
  let signed = set_sig e ~sk_seed:seed in
  Alcotest.(check bool) "v2 envelope without from_x25519 verifies" true (verify_envelope_sig ~pk:pk_raw signed);
  (* Bonus: when [from_x25519 = None], v2 canonical bytes equal v1
     canonical bytes (both omit the key). This is the clean degradation
     path mentioned in the design comment. *)
  let e_v1 = { e with envelope_version = 1 } in
  Alcotest.(check string) "v2-with-None-from_x25519 == v1 canonical" (canonical_json e_v1) canon

(* CRIT-1+B Slice B core — v2 envelope binds [from_ed25519] in the signed
   blob. Mutating the field after signing must invalidate the signature. *)
let test_canonical_v2_includes_from_ed25519 () =
  let seed, pk_raw = gen_ed25519 () in
  let e = {
    from_ = "alice";
    from_x25519 = Some "AAAA-x25519-pk";
    from_ed25519 = Some "BBBB-ed25519-claimed-original";
    to_ = Some "bob";
    room = None;
    ts = 1700000010L;
    enc = "box-x25519-v1";
    recipients = [ { alias = "bob"; nonce = Some "n"; ciphertext = "c" } ];
    sig_b64 = "";
    envelope_version = 2;
  } in
  let signed = set_sig e ~sk_seed:seed in
  Alcotest.(check bool) "v2 sig verifies" true (verify_envelope_sig ~pk:pk_raw signed);
  (* Mutate from_ed25519 (attacker key swap); sig must fail. *)
  let mutated = { signed with from_ed25519 = Some "CCCC-attacker-ed25519" } in
  Alcotest.(check bool) "v2 verify rejects from_ed25519 swap" false (verify_envelope_sig ~pk:pk_raw mutated);
  (* Sanity — also fails if from_ed25519 is dropped to None. *)
  let dropped = { signed with from_ed25519 = None } in
  Alcotest.(check bool) "v2 verify rejects from_ed25519 drop" false (verify_envelope_sig ~pk:pk_raw dropped)

(* Omit-key-when-None semantics for from_ed25519: same shape as
   from_x25519. Producer with both = None under v2 — canonical blob
   omits both keys; v2-bytes == v1-bytes for that shape. *)
let test_omit_from_ed25519_v2_canonicalize () =
  let seed, pk_raw = gen_ed25519 () in
  let e = {
    from_ = "alice";
    from_x25519 = Some "X25519-pk";
    from_ed25519 = None;
    to_ = Some "bob";
    room = None;
    ts = 1700000011L;
    enc = "box-x25519-v1";
    recipients = [];
    sig_b64 = "";
    envelope_version = 2;
  } in
  let canon = canonical_json e in
  Alcotest.(check bool) "v2 canonical omits from_ed25519 key when None"
    false
    (try ignore (Str.search_forward (Str.regexp_string "from_ed25519") canon 0); true
     with Not_found -> false);
  Alcotest.(check bool) "v2 canonical still includes from_x25519 when Some" true
    (try ignore (Str.search_forward (Str.regexp_string "from_x25519") canon 0); true
     with Not_found -> false);
  let signed = set_sig e ~sk_seed:seed in
  Alcotest.(check bool) "v2 envelope without from_ed25519 verifies" true (verify_envelope_sig ~pk:pk_raw signed)

(* Wire-format round-trip: envelope_to_json + envelope_of_json preserves
   from_ed25519 (b64url string). *)
let test_envelope_json_roundtrip_from_ed25519 () =
  let seed, _pk_raw = gen_ed25519 () in
  let e = {
    from_ = "alice";
    from_x25519 = Some "X25519-pk-b64";
    from_ed25519 = Some "Ed25519-pk-b64";
    to_ = Some "bob";
    room = None;
    ts = 1700000012L;
    enc = "box-x25519-v1";
    recipients = [];
    sig_b64 = "";
    envelope_version = 2;
  } in
  let signed = set_sig e ~sk_seed:seed in
  let wire = envelope_to_json signed in
  let parsed = envelope_of_json wire in
  Alcotest.(check (option string)) "from_ed25519 preserved through wire"
    (Some "Ed25519-pk-b64") parsed.from_ed25519;
  Alcotest.(check (option string)) "from_x25519 preserved through wire"
    (Some "X25519-pk-b64") parsed.from_x25519;
  (* Also: v1 envelope (no from_ed25519) round-trips with None. *)
  let e_v1 = {
    from_ = "legacy";
    from_x25519 = None;
    from_ed25519 = None;
    to_ = Some "bob";
    room = None;
    ts = 1700000013L;
    enc = "box-x25519-v1";
    recipients = [];
    sig_b64 = "";
    envelope_version = 1;
  } in
  let signed_v1 = set_sig e_v1 ~sk_seed:seed in
  let wire_v1 = envelope_to_json signed_v1 in
  let parsed_v1 = envelope_of_json wire_v1 in
  Alcotest.(check (option string)) "v1 from_ed25519 round-trips as None"
    None parsed_v1.from_ed25519

(* §7.1: v2 envelope without from_ed25519 must be rejected at parse time.
   This prevents an attacker from stripping the field to bypass TOFU. *)
let test_v2_without_from_ed25519_rejected () =
  (* Manually construct v2 JSON without from_ed25519 field. *)
  let v2_without_ed_json_str = "{\"from\":\"alice\",\"from_x25519\":\"x25519-pk\",\"to\":\"bob\",\"room\":null,\"ts\":1700000014,\"enc\":\"box-x25519-v1\",\"recipients\":[],\"sig\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"envelope_version\":2}" in
  let json = Yojson.Safe.from_string v2_without_ed_json_str in
  Alcotest.(check bool) "v2 without from_ed25519 raises"
    true
    (try ignore (Relay_e2e.envelope_of_json json); false
     with Failure msg ->
       (try ignore (Str.search_forward (Str.regexp_string "v2 envelope missing from_ed25519") msg 0); true
        with Not_found -> false)
     | _ -> false);
  (* v1 without from_ed25519 is still accepted (legacy compat). *)
  let v1_json_str = "{\"from\":\"alice\",\"to\":\"bob\",\"room\":null,\"ts\":1700000015,\"enc\":\"plain\",\"recipients\":[],\"sig\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"}" in
  let v1_json = Yojson.Safe.from_string v1_json_str in
  Alcotest.(check bool) "v1 without from_ed25519 still accepted" true
    (try ignore (Relay_e2e.envelope_of_json v1_json); true
     with _ -> false)

(* §7.1 micro-edges: v2 must reject explicit null and empty-string from_ed25519. *)
let test_v2_from_ed25519_micro_edges () =
  (* Edge 1: from_ed25519: null — Yojson.Safe parses null as `Null, pattern gives None,
     catches the existing envelope_version>=2 && from_ed25519=None guard. *)
  let v2_null_ed = "{\"from\":\"alice\",\"from_x25519\":\"x25519-pk\",\"from_ed25519\":null,\"to\":\"bob\",\"room\":null,\"ts\":1700000016,\"enc\":\"box-x25519-v1\",\"recipients\":[],\"sig\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"envelope_version\":2}" in
  let json_null = Yojson.Safe.from_string v2_null_ed in
  Alcotest.(check bool) "v2 with from_ed25519:null raises"
    true
    (try ignore (Relay_e2e.envelope_of_json json_null); false
     with Failure msg ->
       (try ignore (Str.search_forward (Str.regexp_string "v2 envelope missing from_ed25519") msg 0); true
        with Not_found -> false)
     | _ -> false);
  (* Edge 2: from_ed25519: "" — empty string now parsed as None (rejected by fix),
     catches the same guard. Before the fix this would bypass the =None check. *)
  let v2_empty_ed = "{\"from\":\"alice\",\"from_x25519\":\"x25519-pk\",\"from_ed25519\":\"\",\"to\":\"bob\",\"room\":null,\"ts\":1700000017,\"enc\":\"box-x25519-v1\",\"recipients\":[],\"sig\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"envelope_version\":2}" in
  let json_empty = Yojson.Safe.from_string v2_empty_ed in
  Alcotest.(check bool) "v2 with from_ed25519:\\\"\\\" raises"
    true
    (try ignore (Relay_e2e.envelope_of_json json_empty); false
     with Failure msg ->
       (try ignore (Str.search_forward (Str.regexp_string "v2 envelope missing from_ed25519") msg 0); true
        with Not_found -> false)
     | _ -> false)

(* Slice C — C2C_RELAY_E2E_STRICT_V2 strict-flip gate.

   When the env flag is on, [verify_envelope_sig] (and the bool form
   [verify_envelope_sig]) refuses to even attempt verification on
   envelopes with [envelope_version < 2]. The signature is NOT
   consulted — version is the gate. Default-off preserves the v1↔v2
   transition behavior.

   Tests use [Unix.putenv]/[Unix.unsetenv] in a [Fun.protect] block to
   restore the env after each case so peers can run in parallel. *)

let with_strict_v2_env (value : string option) (f : unit -> unit) : unit =
  let prev = Sys.getenv_opt "C2C_RELAY_E2E_STRICT_V2" in
  let restore () =
    match prev with
    | Some v -> Unix.putenv "C2C_RELAY_E2E_STRICT_V2" v
    | None ->
      (* OCaml's stdlib has no [Unix.unsetenv] in older versions;
         shell out via the existing helper if available, otherwise
         clear via empty string which [is_strict_v2_mode] treats as
         off. *)
      try Unix.putenv "C2C_RELAY_E2E_STRICT_V2" "" with _ -> ()
  in
  (match value with
   | Some v -> Unix.putenv "C2C_RELAY_E2E_STRICT_V2" v
   | None -> (try Unix.putenv "C2C_RELAY_E2E_STRICT_V2" "" with _ -> ()));
  Fun.protect ~finally:restore f

let test_strict_v2_default_off_v1_verifies () =
  with_strict_v2_env None (fun () ->
    let seed, pk_raw = gen_ed25519 () in
    let e = {
      from_ = "legacy-sender";
      from_x25519 = None;
      from_ed25519 = None;
      to_ = Some "bob";
      room = None;
      ts = 1700000100L;
      enc = "box-x25519-v1";
      recipients = [ { alias = "bob"; nonce = Some "n"; ciphertext = "c" } ];
      sig_b64 = "";
      envelope_version = 1;
    } in
    let signed = set_sig e ~sk_seed:seed in
    Alcotest.(check bool) "default-off: v1 envelope verifies"
      true (verify_envelope_sig ~pk:pk_raw signed))

let test_strict_v2_on_rejects_v1 () =
  with_strict_v2_env (Some "1") (fun () ->
    let seed, pk_raw = gen_ed25519 () in
    let e = {
      from_ = "legacy-sender";
      from_x25519 = None;
      from_ed25519 = None;
      to_ = Some "bob";
      room = None;
      ts = 1700000101L;
      enc = "box-x25519-v1";
      recipients = [ { alias = "bob"; nonce = Some "n"; ciphertext = "c" } ];
      sig_b64 = "";
      envelope_version = 1;
    } in
    let signed = set_sig e ~sk_seed:seed in
    Alcotest.(check bool)
      "strict-v2: v1 envelope rejected even with valid signature"
      false (verify_envelope_sig ~pk:pk_raw signed))

let test_strict_v2_on_v2_still_verifies () =
  with_strict_v2_env (Some "1") (fun () ->
    let seed, pk_raw = gen_ed25519 () in
    let e = {
      from_ = "alice";
      from_x25519 = Some "AAAA-x25519-pk";
      from_ed25519 = Some (b64_encode pk_raw);
      to_ = Some "bob";
      room = None;
      ts = 1700000102L;
      enc = "box-x25519-v1";
      recipients = [ { alias = "bob"; nonce = Some "n"; ciphertext = "c" } ];
      sig_b64 = "";
      envelope_version = 2;
    } in
    let signed = set_sig e ~sk_seed:seed in
    Alcotest.(check bool) "strict-v2: v2 envelope still verifies"
      true (verify_envelope_sig ~pk:pk_raw signed))

let test_strict_v2_detailed_emits_strict_variant () =
  with_strict_v2_env (Some "1") (fun () ->
    let seed, pk_raw = gen_ed25519 () in
    let e = {
      from_ = "legacy-sender";
      from_x25519 = None;
      from_ed25519 = None;
      to_ = Some "bob";
      room = None;
      ts = 1700000103L;
      enc = "box-x25519-v1";
      recipients = [ { alias = "bob"; nonce = Some "n"; ciphertext = "c" } ];
      sig_b64 = "";
      envelope_version = 1;
    } in
    let signed = set_sig e ~sk_seed:seed in
    let result = Relay_e2e.verify_envelope_sig_detailed ~pk:pk_raw signed in
    let is_strict_variant = match result with
      | Relay_e2e.Verify_err_strict_v2_required { rejected_version = 1 } -> true
      | _ -> false
    in
    Alcotest.(check bool)
      "strict-v2: detailed result emits Verify_err_strict_v2_required"
      true is_strict_variant)

let test_strict_v2_env_value_truthiness () =
  let make_v1 () =
    let seed, pk_raw = gen_ed25519 () in
    let e = {
      from_ = "legacy-sender";
      from_x25519 = None;
      from_ed25519 = None;
      to_ = Some "bob";
      room = None;
      ts = 1700000104L;
      enc = "box-x25519-v1";
      recipients = [ { alias = "bob"; nonce = Some "n"; ciphertext = "c" } ];
      sig_b64 = "";
      envelope_version = 1;
    } in
    set_sig e ~sk_seed:seed, pk_raw
  in
  (* "1", "true", "yes", "on" (any case) all reject; "0", "false", garbage all accept. *)
  let truthy = ["1"; "true"; "TRUE"; "yes"; "Yes"; "on"; "ON"] in
  let falsy = ["0"; "false"; "no"; "off"; ""; "garbage"; " "] in
  List.iter (fun v ->
    with_strict_v2_env (Some v) (fun () ->
      let signed, pk_raw = make_v1 () in
      Alcotest.(check bool)
        (Printf.sprintf "truthy %S rejects v1" v)
        false (verify_envelope_sig ~pk:pk_raw signed))
  ) truthy;
  List.iter (fun v ->
    with_strict_v2_env (Some v) (fun () ->
      let signed, pk_raw = make_v1 () in
      Alcotest.(check bool)
        (Printf.sprintf "falsy %S accepts v1" v)
        true (verify_envelope_sig ~pk:pk_raw signed))
  ) falsy

let () =
  Alcotest.run "relay_e2e" [
    "enc_status", [
      Alcotest.test_case "enc_status_to_string all variants" `Quick test_enc_status;
    ];
    "sign_verify", [
      Alcotest.test_case "Ed25519 sign/verify roundtrip" `Quick test_sign_verify_roundtrip;
    ];
    "box", [
      Alcotest.test_case "NaCl box/box_open roundtrip with 24B nonce" `Quick test_box_roundtrip;
    ];
    "canonical_json", [
      Alcotest.test_case "byte-stable across two calls" `Quick test_canonical_json_byte_stability;
      Alcotest.test_case "fields emitted in sorted order" `Quick test_canonical_json_sorted;
    ];
    "downgrade", [
      Alcotest.test_case "downgrade detection triggers correctly" `Quick test_downgrade_detection;
    ];
    "find_recipient", [
      Alcotest.test_case "find_my_recipient hit" `Quick test_find_my_recipient_hit;
      Alcotest.test_case "find_my_recipient miss" `Quick test_find_my_recipient_miss;
      Alcotest.test_case "find_my_recipient case-insensitive" `Quick test_find_my_recipient_case_insensitive;
    ];
    "tofu", [
      Alcotest.test_case "TOFU mismatch detection" `Quick test_tofu_mismatch;
    ];
    "envelope_v2", [
      Alcotest.test_case "v2 canonical_json includes from_x25519 (mutate→fail)"
        `Quick test_canonical_v2_includes_from_x25519;
      Alcotest.test_case "v1 envelope back-compat verify"
        `Quick test_v1_back_compat_verify;
      Alcotest.test_case "v2 sig fails under v1-shape canonicalize"
        `Quick test_v2_envelope_rejects_v1_verify_path;
      Alcotest.test_case "v2 with from_x25519=None omits the key"
        `Quick test_omit_from_x25519_v2_canonicalize;
      Alcotest.test_case "v2 canonical_json includes from_ed25519 (mutate→fail)"
        `Quick test_canonical_v2_includes_from_ed25519;
      Alcotest.test_case "v2 with from_ed25519=None omits the key"
        `Quick test_omit_from_ed25519_v2_canonicalize;
      Alcotest.test_case "envelope_to_json/of_json round-trips from_ed25519"
        `Quick test_envelope_json_roundtrip_from_ed25519;
      Alcotest.test_case "§7.1 v2 without from_ed25519 rejected at parse"
        `Quick test_v2_without_from_ed25519_rejected;
      Alcotest.test_case "§7.1 v2 from_ed25519 null and empty-string rejected"
        `Quick test_v2_from_ed25519_micro_edges;
    ];
    "strict_v2_slice_c", [
      Alcotest.test_case "default-off: v1 envelope verifies"
        `Quick test_strict_v2_default_off_v1_verifies;
      Alcotest.test_case "strict-v2: v1 envelope rejected"
        `Quick test_strict_v2_on_rejects_v1;
      Alcotest.test_case "strict-v2: v2 envelope still verifies"
        `Quick test_strict_v2_on_v2_still_verifies;
      Alcotest.test_case "strict-v2: detailed result emits Verify_err_strict_v2_required"
        `Quick test_strict_v2_detailed_emits_strict_variant;
      Alcotest.test_case "strict-v2: env-value truthiness matrix"
        `Quick test_strict_v2_env_value_truthiness;
    ];
  ]