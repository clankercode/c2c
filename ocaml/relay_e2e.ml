(* Layer 3 E2E encryption — Opportunistic NaCl box + Ed25519 signed envelopes.
   Spec: M1-breakdown.md §S3. *)

type enc_status =
  | Ok
  | Plain
  | Failed
  | Not_for_me
  | Downgrade_warning
  | Key_changed
  | Version_downgrade
    (** Slice B-min-version: receive-side defense against MITM
        envelope_version 2→1 stripping. Surfaced when the on-wire
        [envelope_version] is lower than the per-alias
        [min_observed_envelope_version] pin in [relay_pins.json].
        Rejected before sig verify so the audit trail clearly
        attributes to downgrade-policy, not sig-mismatch. *)

let enc_status_to_string = function
  | Ok -> "ok"
  | Plain -> "plain"
  | Failed -> "failed"
  | Not_for_me -> "not-for-me"
  | Downgrade_warning -> "downgrade-warning"
  | Key_changed -> "key-changed"
  | Version_downgrade -> "version-downgrade-rejected"

type recipient = {
  alias : string;
  nonce : string option;
  ciphertext : string;
}

type envelope = {
  from_ : string;
  from_x25519 : string option;  (** Sender's x25519 pubkey (b64url). Optional — absent on legacy envelopes. Used for x25519 TOFU on receive. *)
  from_ed25519 : string option;
    (** Sender's Ed25519 verify pubkey (b64url). Optional — absent on
        legacy v1 envelopes. Used for Ed25519 TOFU on first-contact and
        mismatch-reject on subsequent receive (Slice B,
        [.collab/design/2026-04-29-relay-crypto-crit-fix-plan-cairn.md]).
        v2 producers populate this with their local relay-identity key. *)
  to_ : string option;
  room : string option;
  ts : int64;
  enc : string;
  recipients : recipient list;
  sig_b64 : string;
  envelope_version : int;
    (** Canonical-blob version: 1 = legacy (does NOT cover [from_x25519]
        or [from_ed25519]), 2 = CRIT-1+B fix (covers both when [Some _],
        omits the corresponding key entirely when [None]). Default 1 on
        parse for back-compat. New OCaml producers emit 2. Verifier
        accepts both during the transition window (Slice A+B,
        [.collab/design/2026-04-29-relay-crypto-crit-fix-plan-cairn.md]).
        Strict-v2 flip is future Slice C. *)
}

(** Current envelope version emitted by OCaml producers. Bumped to 2 by
    Slice A so [from_x25519] is included in the Ed25519-signed canonical
    blob. Slice B extends v2 to also cover [from_ed25519]. *)
let current_envelope_version = 2

let b64_encode s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let b64_decode s =
  Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let rng_initialized = ref false

let ensure_rng () =
  if not !rng_initialized then begin
    Mirage_crypto_rng_unix.use_default ();
    rng_initialized := true
  end

let random_nonce () =
  ensure_rng ();
  Mirage_crypto_rng.generate 24

(* Canonical JSON — alpha-sorted keys for cross-platform determinism.
   Spec §S3: signature is over canonical JSON of {from,to,room,ts,enc,recipients}.
   Alpha-sorting ensures TS/Python clients that serialize with sorted keys
   produce bit-identical output, so Ed25519 sig verification works everywhere. *)
let sort_assoc (lst : (string * Yojson.Safe.t) list) : (string * Yojson.Safe.t) list =
  List.sort (fun (a, _) (b, _) -> String.compare a b) lst

let rec json_to_string_sorted (j : Yojson.Safe.t) : string =
  match j with
  | `Assoc fields ->
    let sorted = sort_assoc fields in
    let inner = List.map (fun (k, v) -> Printf.sprintf "%s:%s" (Yojson.Safe.to_string (`String k)) (json_to_string_sorted v)) sorted in
    "{" ^ String.concat "," inner ^ "}"
  | `List items ->
    let inner = List.map json_to_string_sorted items in
    "[" ^ String.concat "," inner ^ "]"
  | `String s -> Yojson.Safe.to_string (`String s)
  | `Null -> "null"
  | `Int i -> string_of_int i
  | `Intlit s -> s
  | `Float f -> string_of_float f
  | `Bool b -> string_of_bool b
  | _ -> Yojson.Safe.to_string j

(* Canonical-blob version dispatch (CRIT-1+B, Slice A+B).

   v1 (legacy): {enc, from, recipients, room, to, ts}
   v2 (CRIT-1+B): v1 fields PLUS "from_x25519" and "from_ed25519" when
   each is [Some _].

   Omit-key-when-None semantics for v2: if [from_x25519 = None] the
   ["from_x25519"] key is NOT included (NOT included as `Null), same
   for [from_ed25519]. This keeps the v2 canonical blob bit-identical
   to v1 when the sender chooses to omit both fields (e.g. plaintext-
   routed messages), preserving a clean degradation path and matching
   what TS verifiers expect when paraphrasing the canonical-blob
   field-list. *)
let canonical_json_v1 (e : envelope) : string =
  let rncs =
    `List (
      List.map (fun r ->
        let fields =
          [ "alias", `String r.alias ]
          @ (match r.nonce with Some n -> [ "nonce", `String n ] | None -> [ "nonce", `Null ])
          @ [ "ciphertext", `String r.ciphertext ]
        in
        `Assoc (sort_assoc fields)
      ) e.recipients
    )
  in
  let fields =
    sort_assoc [
      "from",      `String e.from_;
      "to",        (match e.to_ with Some s -> `String s | None -> `Null);
      "room",      (match e.room with Some s -> `String s | None -> `Null);
      "ts",        `Intlit (Int64.to_string e.ts);
      "enc",       `String e.enc;
      "recipients", rncs;
    ]
  in
  "{" ^ String.concat "," (List.map (fun (k, v) -> Printf.sprintf "%S:%s" k (json_to_string_sorted v)) fields) ^ "}"

let canonical_json_v2 (e : envelope) : string =
  let rncs =
    `List (
      List.map (fun r ->
        let fields =
          [ "alias", `String r.alias ]
          @ (match r.nonce with Some n -> [ "nonce", `String n ] | None -> [ "nonce", `Null ])
          @ [ "ciphertext", `String r.ciphertext ]
        in
        `Assoc (sort_assoc fields)
      ) e.recipients
    )
  in
  let base = [
    "from",      `String e.from_;
    "to",        (match e.to_ with Some s -> `String s | None -> `Null);
    "room",      (match e.room with Some s -> `String s | None -> `Null);
    "ts",        `Intlit (Int64.to_string e.ts);
    "enc",       `String e.enc;
    "recipients", rncs;
  ] in
  (* Omit-key-when-None: NOT a `Null branch — the key is absent. *)
  let with_x25519 = match e.from_x25519 with
    | Some pk -> ("from_x25519", `String pk) :: base
    | None -> base
  in
  let with_ed25519 = match e.from_ed25519 with
    | Some pk -> ("from_ed25519", `String pk) :: with_x25519
    | None -> with_x25519
  in
  let fields = sort_assoc with_ed25519 in
  "{" ^ String.concat "," (List.map (fun (k, v) -> Printf.sprintf "%S:%s" k (json_to_string_sorted v)) fields) ^ "}"

(** Dispatch on [e.envelope_version]: 1 → v1 shape, 2 → v2 shape, anything
    else → v2 shape (forward-compat: unknown future versions are assumed
    to at least cover what v2 covers; verifier will sig-fail if the
    actual canonical shape differs, which is the safe outcome). *)
let canonical_json (e : envelope) : string =
  match e.envelope_version with
  | 1 -> canonical_json_v1 e
  | _ -> canonical_json_v2 e

let sign_ed25519 ~sk_seed msg =
  match Mirage_crypto_ec.Ed25519.priv_of_octets sk_seed with
  | Error _ -> failwith "relay_e2e.sign_ed25519: invalid seed"
  | Ok priv -> Mirage_crypto_ec.Ed25519.sign ~key:priv msg

let verify_ed25519 ~pk ~msg ~sig_ =
  String.length pk = 32 && String.length sig_ = 64
  &&
  match Mirage_crypto_ec.Ed25519.pub_of_octets pk with
  | Error _ -> false
  | Ok pub -> Mirage_crypto_ec.Ed25519.verify ~key:pub sig_ ~msg

let box_easy ~pt ~n ~pk ~sk =
  match Hacl_star.Hacl.NaCl.box ~pt:(Bytes.of_string pt) ~n:(Bytes.of_string n) ~pk:(Bytes.of_string pk) ~sk:(Bytes.of_string sk) with
  | None -> None
  | Some ct -> Some (b64_encode (Bytes.unsafe_to_string ct))

let box_open_easy ~ct_b64 ~n ~pk ~sk =
  match b64_decode ct_b64 with
  | Error _ -> None
  | Ok ct ->
    match Hacl_star.Hacl.NaCl.box_open ~ct:(Bytes.of_string ct) ~n:(Bytes.of_string n) ~pk:(Bytes.of_string pk) ~sk:(Bytes.of_string sk) with
    | None -> None
    | Some pt -> Some (Bytes.unsafe_to_string pt)

let box_beforenm ~pk ~sk =
  match Hacl_star.Hacl.NaCl.box_beforenm ~pk:(Bytes.of_string pk) ~sk:(Bytes.of_string sk) with
  | None -> None
  | Some ck -> Some (Bytes.unsafe_to_string ck)

let box_afternm ~pt ~n ~(ck:string) =
  match Hacl_star.Hacl.NaCl.box_afternm ~pt:(Bytes.of_string pt) ~n ~ck:(Bytes.of_string ck) with
  | None -> None
  | Some ct -> Some (b64_encode (Bytes.unsafe_to_string ct))

let box_open_afternm ~ct_b64 ~n ~(ck:string) =
  match b64_decode ct_b64 with
  | Error _ -> None
  | Ok ct ->
    match Hacl_star.Hacl.NaCl.box_open_afternm ~ct:(Bytes.of_string ct) ~n ~ck:(Bytes.of_string ck) with
    | None -> None
    | Some pt -> Some (Bytes.unsafe_to_string pt)

let make_recipient ~alias ~ct_b64 ~nonce =
  { alias; nonce = Some nonce; ciphertext = ct_b64 }

let make_plain_recipient ~alias ~plaintext_b64 =
  { alias; nonce = None; ciphertext = plaintext_b64 }

let sign_envelope ~sk_seed (e : envelope) : string =
  let canon = canonical_json e in
  let sig_bytes = sign_ed25519 ~sk_seed canon in
  b64_encode sig_bytes

(** Slice C strict-v2 mode: when [C2C_RELAY_E2E_STRICT_V2] is set to a
    truthy value, the verifier rejects envelopes with [envelope_version
    < 2] regardless of signature validity. Default off — v1 envelopes
    continue to verify normally during the cutover window.

    Truthy: ["1"], ["true"], ["yes"], ["on"] (case-insensitive). Anything
    else (unset, ["0"], ["false"], etc.) is treated as off.

    Read via [Sys.getenv_opt] on every call so an env-var flip takes
    effect on the next verify without daemon restart — useful for ops
    flipping the gate during a soak window. *)
let is_strict_v2_mode () : bool =
  match Sys.getenv_opt "C2C_RELAY_E2E_STRICT_V2" with
  | None -> false
  | Some v ->
    (match String.lowercase_ascii (String.trim v) with
     | "1" | "true" | "yes" | "on" -> true
     | _ -> false)

let verify_envelope_sig ~pk (e : envelope) : bool =
  (* Slice C: strict-v2 gate refuses to even verify v1 envelopes when
     enabled. The min-observed-version pin (Slice B) gives a per-alias
     downgrade defense; this gate gives the global cutover. *)
  if is_strict_v2_mode () && e.envelope_version < 2 then false
  else
    match b64_decode e.sig_b64 with
    | Error _ -> false
    | Ok sig_bytes ->
      let canon = canonical_json e in
      verify_ed25519 ~pk ~msg:canon ~sig_:sig_bytes

(** Structured verify result for ops-debug. [Err] carries
    [version_attempted] = the [envelope_version] the verifier dispatched
    on. Useful when triaging cross-client interop failures during the
    v1↔v2 transition window. [Err_strict_v2_required] is emitted when
    Slice C strict-v2 mode is enabled and the envelope's version is < 2;
    the signature is NOT consulted. *)
type verify_result =
  | Verify_ok
  | Verify_err of { version_attempted : int }
  | Verify_err_strict_v2_required of { rejected_version : int }

let verify_envelope_sig_detailed ~pk (e : envelope) : verify_result =
  if is_strict_v2_mode () && e.envelope_version < 2 then
    Verify_err_strict_v2_required { rejected_version = e.envelope_version }
  else if verify_envelope_sig ~pk e
  then Verify_ok
  else Verify_err { version_attempted = e.envelope_version }

let encrypt_for_recipient ~pt ~recipient_pk_b64 ~our_sk_seed =
  let nonce = random_nonce () in
  let nonce_b64 = b64_encode nonce in
  match b64_decode recipient_pk_b64 with
  | Error _ -> None
  | Ok recipient_pk ->
    match Hacl_star.Hacl.NaCl.box ~pt:(Bytes.of_string pt) ~n:(Bytes.of_string nonce) ~pk:(Bytes.of_string recipient_pk) ~sk:(Bytes.of_string our_sk_seed) with
    | None -> None
    | Some ct -> Some (b64_encode (Bytes.unsafe_to_string ct), nonce_b64)

let decrypt_for_me ~ct_b64 ~nonce_b64 ~sender_pk_b64 ~our_sk_seed =
  match b64_decode ct_b64, b64_decode nonce_b64, b64_decode sender_pk_b64 with
  | Ok ct, Ok nonce, Ok sender_pk ->
    (match Hacl_star.Hacl.NaCl.box_open ~ct:(Bytes.of_string ct) ~n:(Bytes.of_string nonce) ~pk:(Bytes.of_string sender_pk) ~sk:(Bytes.of_string our_sk_seed) with
     | None -> None
     | Some pt -> Some (Bytes.unsafe_to_string pt))
  | _ -> None

let recipient_to_json (r : recipient) : Yojson.Safe.t =
  `Assoc (
    [ "alias", `String r.alias ]
    @ (match r.nonce with Some n -> [ "nonce", `String n ] | None -> [ "nonce", `Null ])
    @ [ "ciphertext", `String r.ciphertext ]
  )

let recipient_of_json (j : Yojson.Safe.t) =
  match j with
  | `Assoc _ ->
    let open Yojson.Safe.Util in
    let alias = member "alias" j |> to_string in
    let nonce = match member "nonce" j with
      | `Null -> None
      | `String s -> Some s
      | _ -> failwith "recipient_of_json: nonce must be string or null"
    in
    let ciphertext = member "ciphertext" j |> to_string in
    { alias; nonce; ciphertext }
  | _ -> failwith "recipient_of_json: expected object"

let envelope_to_json (e : envelope) : Yojson.Safe.t =
  `Assoc (
    [ "from",      `String e.from_ ]
    @ (match e.from_x25519 with Some pk -> [ "from_x25519", `String pk ] | None -> [])
    @ (match e.from_ed25519 with Some pk -> [ "from_ed25519", `String pk ] | None -> [])
    @ [ "to",        (match e.to_ with Some s -> `String s | None -> `Null)
      ; "room",      (match e.room with Some s -> `String s | None -> `Null)
      ; "ts",        `Intlit (Int64.to_string e.ts)
      ; "enc",       `String e.enc
      ; "recipients", `List (List.map recipient_to_json e.recipients)
      ; "sig",       `String e.sig_b64
      (* envelope_version: omit when 1 to keep wire-bytes byte-identical
         to legacy senders that never knew the field. v2 producers always
         emit it explicitly. *)
      ] @ (if e.envelope_version <= 1 then [] else
             [ "envelope_version", `Int e.envelope_version ])
    )

let envelope_of_json (j : Yojson.Safe.t) : (envelope, string) result =
  match j with
  | `Assoc _ ->
    let open Yojson.Safe.Util in
    let from_ = member "from" j |> to_string in
    let from_x25519 = match member "from_x25519" j with `String s -> Some s | _ -> None in
    let from_ed25519 = match member "from_ed25519" j with
      | `String s when s <> "" -> Some s  (* reject null and empty-string *)
      | _ -> None
    in
    let to_ = match member "to" j with
      | `Null -> Result.Ok None
      | `String s -> Result.Ok (Some s)
      | _ -> Result.Error "envelope_of_json: to must be string or null"
    in
    let room = match member "room" j with
      | `Null -> Result.Ok None
      | `String s -> Result.Ok (Some s)
      | _ -> Result.Error "envelope_of_json: room must be string or null"
    in
    (* Wire format for ts is permissive: producers emit Intlit (so the
       wire JSON has a bare number), but `Yojson.Safe.from_string` parses
       small numbers as `Int and large ones as `Intlit, and some legacy
       paths construct ts as `String. Accept all three. *)
    let ts = match member "ts" j with
      | `String s -> Result.Ok (Int64.of_string s)
      | `Int n -> Result.Ok (Int64.of_int n)
      | `Intlit s -> Result.Ok (Int64.of_string s)
      | _ -> Result.Error "envelope_of_json: ts must be number or string"
    in
    match to_, room, ts with
    | Result.Error e, _, _ -> Result.Error e
    | _, Result.Error e, _ -> Result.Error e
    | _, _, Result.Error e -> Result.Error e
    | Result.Ok to_, Result.Ok room, Result.Ok ts ->
      let enc = member "enc" j |> to_string in
      let recipients = member "recipients" j |> to_list |> List.map recipient_of_json in
      let sig_b64 = member "sig" j |> to_string in
      (* Default envelope_version to 1 on parse: legacy wire JSON has no
         such key. New v2 producers emit it explicitly as `Int. *)
      let envelope_version = match member "envelope_version" j with
        | `Int n -> n
        | `Intlit s -> (try int_of_string s with _ -> 1)
        | _ -> 1
      in
      (* §7.1: v2 envelopes MUST carry from_ed25519. Rejecting missing-field
         v2 envelopes closes the attack surface where an attacker strips the field
         to bypass TOFU (the field is what binds the Ed25519 identity to the
         envelope for signature verification). v1 envelopes are exempt (legacy compat). *)
      if envelope_version >= 2 && from_ed25519 = None then
        Result.Error "envelope_of_json: v2 envelope missing from_ed25519"
      else
        Result.Ok { from_; from_x25519; from_ed25519; to_; room; ts; enc; recipients; sig_b64; envelope_version }
  | _ -> Result.Error "envelope_of_json: expected object"

let find_my_recipient ~(my_alias : string) (recipients : recipient list) =
  (* #alias-casefold: recipient lookup is case-insensitive so a sender
     who wrote a recipient entry as "Foo" doesn't brick legitimate
     decryption when the recipient resolves as "foo". Inlined
     [String.lowercase_ascii] (matches [C2c_mcp.Broker.alias_casefold]
     semantics) to preserve the relay layer's Broker-free convention. *)
  let target = String.lowercase_ascii my_alias in
  List.find_opt (fun r -> String.lowercase_ascii r.alias = target) recipients

type downgrade_state = {
  seen_encrypted : bool;
}

let make_downgrade_state () = { seen_encrypted = false }

let decide_enc_status (ds : downgrade_state) (e : envelope) : enc_status * downgrade_state =
  match e.enc with
  | "box-x25519-v1" ->
    Ok, { ds with seen_encrypted = true }
  | "plain" ->
    if ds.seen_encrypted then
      Downgrade_warning, ds
    else
      Plain, ds
  | _ ->
    Plain, ds

(* TOFU helpers: comparison functions only. The known_keys store (per-alias pinned pubkeys)
   is managed by c2c_mcp.ml. Callers pass pinned_pk from known_keys + claimed_pk from the
   envelope. True return = mismatch → caller surfaces enc_status:"key-changed" and drops. *)
let check_pinned_ed25519_mismatch ~(pinned_pk : string) ~(claimed_pk : string) : bool =
  pinned_pk <> claimed_pk

let check_pinned_x25519_mismatch ~(pinned_pk : string) ~(claimed_pk : string) : bool =
  pinned_pk <> claimed_pk

let make_test_envelope ~from_ ~to_ ~room ~ts ~enc ~recipients =
  { from_; from_x25519 = None; from_ed25519 = None; to_; room; ts; enc;
    recipients; sig_b64 = ""; envelope_version = current_envelope_version }

let set_sig (e : envelope) ~sk_seed =
  let sig_b64 = sign_envelope ~sk_seed e in
  { e with sig_b64 }
