(* Layer 3 E2E encryption — Opportunistic NaCl box + Ed25519 signed envelopes.
   Spec: M1-breakdown.md §S3. *)

type enc_status =
  | Ok
  | Plain
  | Failed
  | Not_for_me
  | Downgrade_warning
  | Key_changed

let enc_status_to_string = function
  | Ok -> "ok"
  | Plain -> "plain"
  | Failed -> "failed"
  | Not_for_me -> "not-for-me"
  | Downgrade_warning -> "downgrade-warning"
  | Key_changed -> "key-changed"

type recipient = {
  alias : string;
  nonce : string option;
  ciphertext : string;
}

type envelope = {
  from_ : string;
  to_ : string option;
  room : string option;
  ts : int64;
  enc : string;
  recipients : recipient list;
  sig_b64 : string;
}

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
    let inner = List.map (fun (k, v) -> Printf.sprintf "%S:%s" k (json_to_string_sorted v)) sorted in
    "{" ^ String.concat "," inner ^ "}"
  | `List items ->
    let inner = List.map json_to_string_sorted items in
    "[" ^ String.concat "," inner ^ "]"
  | `String s -> Printf.sprintf "%S" s
  | `Null -> "null"
  | `Int i -> string_of_int i
  | `Intlit s -> s
  | `Float f -> string_of_float f
  | `Bool b -> string_of_bool b
  | _ -> Yojson.Safe.to_string j

let canonical_json (e : envelope) : string =
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

let verify_envelope_sig ~pk (e : envelope) : bool =
  match b64_decode e.sig_b64 with
  | Error _ -> false
  | Ok sig_bytes ->
    let canon = canonical_json e in
    verify_ed25519 ~pk ~msg:canon ~sig_:sig_bytes

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
  `Assoc [
    "from",      `String e.from_;
    "to",        (match e.to_ with Some s -> `String s | None -> `Null);
    "room",      (match e.room with Some s -> `String s | None -> `Null);
    "ts",        `Intlit (Int64.to_string e.ts);
    "enc",       `String e.enc;
    "recipients", `List (List.map recipient_to_json e.recipients);
    "sig",       `String e.sig_b64;
  ]

let envelope_of_json (j : Yojson.Safe.t) : envelope =
  match j with
  | `Assoc _ ->
    let open Yojson.Safe.Util in
    let from_ = member "from" j |> to_string in
    let to_ = match member "to" j with `Null -> None | `String s -> Some s | _ -> failwith "envelope_of_json: to must be string or null" in
    let room = match member "room" j with `Null -> None | `String s -> Some s | _ -> failwith "envelope_of_json: room must be string or null" in
    let ts_str = member "ts" j |> to_string in
    let ts = Int64.of_string ts_str in
    let enc = member "enc" j |> to_string in
    let recipients = member "recipients" j |> to_list |> List.map recipient_of_json in
    let sig_b64 = member "sig" j |> to_string in
    { from_; to_; room; ts; enc; recipients; sig_b64 }
  | _ -> failwith "envelope_of_json: expected object"

let find_my_recipient ~(my_alias : string) (recipients : recipient list) =
  List.find_opt (fun r -> r.alias = my_alias) recipients

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
  { from_; to_; room; ts; enc; recipients; sig_b64 = "" }

let set_sig (e : envelope) ~sk_seed =
  let sig_b64 = sign_envelope ~sk_seed e in
  { e with sig_b64 }
