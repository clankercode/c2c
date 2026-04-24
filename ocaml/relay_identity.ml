(* Layer 3 peer identity — Ed25519 keypair + on-disk identity.json.
   Spec: docs/c2c-research/relay-peer-identity-spec.md. *)

type t = {
  version : int;
  alg : string;
  public_key : string;
  private_key_seed : string;
  fingerprint : string;
  created_at : string;
  alias_hint : string;
}

let unit_sep = "\x1f"

let b64url_encode s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let b64url_decode s =
  Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let default_path () =
  let home =
    try Sys.getenv "HOME"
    with Not_found -> "/"
  in
  let xdg =
    try Sys.getenv "XDG_CONFIG_HOME"
    with Not_found -> Filename.concat home ".config"
  in
  Filename.concat (Filename.concat xdg "c2c") "identity.json"

let fingerprint_of_pk pk =
  let digest = Digestif.SHA256.digest_string pk in
  let raw = Digestif.SHA256.to_raw_string digest in
  let enc = b64url_encode raw in
  (* 32 bytes → 43 chars of base64url-nopad (no truncation needed) *)
  let trimmed =
    if String.length enc > 43 then String.sub enc 0 43 else enc
  in
  "SHA256:" ^ trimmed

let rng_initialized = ref false

let ensure_rng () =
  if not !rng_initialized then begin
    Mirage_crypto_rng_unix.use_default ();
    rng_initialized := true
  end

let rfc3339_utc_now () =
  let t = Unix.gmtime (Unix.time ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (t.Unix.tm_year + 1900)
    (t.Unix.tm_mon + 1)
    t.Unix.tm_mday
    t.Unix.tm_hour
    t.Unix.tm_min
    t.Unix.tm_sec

let generate ?(alias_hint = "") () =
  ensure_rng ();
  let priv, pub = Mirage_crypto_ec.Ed25519.generate () in
  let seed = Mirage_crypto_ec.Ed25519.priv_to_octets priv in
  let pk = Mirage_crypto_ec.Ed25519.pub_to_octets pub in
  {
    version = 1;
    alg = "ed25519";
    public_key = pk;
    private_key_seed = seed;
    fingerprint = fingerprint_of_pk pk;
    created_at = rfc3339_utc_now ();
    alias_hint;
  }

let generate_ssh_key ~(priv_path : string) ~(alias : string) =
  if Sys.file_exists priv_path then Ok ()
  else
    let dir = Filename.dirname priv_path in
    let tmp_base = Filename.concat dir (Printf.sprintf "c2c_ssh_%s" alias) in
    let tmp_priv = tmp_base in
    let tmp_pub = tmp_base ^ ".pub" in
    let pub_path = priv_path ^ ".pub" in
    let email = alias ^ "@c2c.im" in
    let cmd = String.concat " && " [
      Printf.sprintf "ssh-keygen -t ed25519 -N '' -C '%s' -f '%s' -q" email tmp_priv;
      Printf.sprintf "mv '%s' '%s'" tmp_priv priv_path;
      Printf.sprintf "mv '%s' '%s'" tmp_pub pub_path
    ] in
    let rc = Sys.command cmd in
    if rc <> 0 then begin
      (try Sys.remove tmp_priv with _ -> ());
      (try Sys.remove tmp_pub with _ -> ());
      Error (Printf.sprintf "ssh-keygen failed with code %d" rc)
    end else Ok ()

let sign t msg =
  match Mirage_crypto_ec.Ed25519.priv_of_octets t.private_key_seed with
  | Error _ ->
      failwith "relay_identity.sign: invalid private key seed"
  | Ok priv -> Mirage_crypto_ec.Ed25519.sign ~key:priv msg

let verify ~pk ~msg ~sig_ =
  if String.length pk <> 32 || String.length sig_ <> 64 then false
  else
    match Mirage_crypto_ec.Ed25519.pub_of_octets pk with
    | Error _ -> false
    | Ok pub -> Mirage_crypto_ec.Ed25519.verify ~key:pub sig_ ~msg

let canonical_msg ~ctx fields =
  String.concat unit_sep (ctx :: fields)

let to_json t : Yojson.Safe.t =
  `Assoc [
    "version",     `Int t.version;
    "alg",         `String t.alg;
    "public_key",  `String (b64url_encode t.public_key);
    "private_key", `String (b64url_encode t.private_key_seed);
    "fingerprint", `String t.fingerprint;
    "created_at",  `String t.created_at;
    "alias_hint",  `String t.alias_hint;
  ]

let find_string fields name =
  match List.assoc_opt name fields with
  | Some (`String s) -> Ok s
  | Some _ -> Error (Printf.sprintf "field %s: expected string" name)
  | None -> Error (Printf.sprintf "missing field: %s" name)

let find_int fields name =
  match List.assoc_opt name fields with
  | Some (`Int i) -> Ok i
  | Some _ -> Error (Printf.sprintf "field %s: expected int" name)
  | None -> Error (Printf.sprintf "missing field: %s" name)

let ( let* ) = Result.bind

let of_json (j : Yojson.Safe.t) =
  match j with
  | `Assoc fields ->
    let* version = find_int fields "version" in
    let* alg = find_string fields "alg" in
    let* pk_enc = find_string fields "public_key" in
    let* sk_enc = find_string fields "private_key" in
    let* fingerprint = find_string fields "fingerprint" in
    let* created_at = find_string fields "created_at" in
    let alias_hint =
      match List.assoc_opt "alias_hint" fields with
      | Some (`String s) -> s
      | _ -> ""
    in
    let* public_key =
      match b64url_decode pk_enc with
      | Ok s when String.length s = 32 -> Ok s
      | Ok _ -> Error "public_key: expected 32 bytes after b64url decode"
      | Error (`Msg m) -> Error ("public_key b64url decode: " ^ m)
    in
    let* private_key_seed =
      match b64url_decode sk_enc with
      | Ok s when String.length s = 32 -> Ok s
      | Ok _ -> Error "private_key: expected 32 bytes after b64url decode"
      | Error (`Msg m) -> Error ("private_key b64url decode: " ^ m)
    in
    if version <> 1 then
      Error (Printf.sprintf "unsupported version: %d (expected 1)" version)
    else if alg <> "ed25519" then
      Error (Printf.sprintf "unsupported alg: %s (expected ed25519)" alg)
    else
      Ok {
        version; alg;
        public_key; private_key_seed;
        fingerprint; created_at; alias_hint;
      }
  | _ -> Error "identity json: expected object"

let mkdir_p_mode path mode =
  let rec aux p =
    if Sys.file_exists p then ()
    else begin
      aux (Filename.dirname p);
      try Unix.mkdir p mode
      with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  aux path

let save ?path t =
  let path = match path with Some p -> p | None -> default_path () in
  try
    let dir = Filename.dirname path in
    mkdir_p_mode dir 0o700;
    (* Ensure parent dir tightens to 0700 even if it pre-existed with
       looser perms. *)
    (try Unix.chmod dir 0o700 with Unix.Unix_error _ -> ());
    let tmp = path ^ ".tmp" in
    let fd =
      Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
    in
    let oc = Unix.out_channel_of_descr fd in
    let body = Yojson.Safe.pretty_to_string (to_json t) ^ "\n" in
    output_string oc body;
    flush oc;
    (try Unix.fsync fd with Unix.Unix_error _ -> ());
    close_out oc;
    Unix.chmod tmp 0o600;
    Unix.rename tmp path;
    Unix.chmod path 0o600;
    Ok ()
  with
  | Unix.Unix_error (e, fn, arg) ->
    Error (Printf.sprintf "save %s: %s (%s %s)"
             path (Unix.error_message e) fn arg)
  | Sys_error msg -> Error ("save: " ^ msg)

let load ?path () =
  let path = match path with Some p -> p | None -> default_path () in
  try
    let st = Unix.stat path in
    (* Reject anything looser than 0600 on the regular-file perm bits.
       Mirrors ssh: refuse to load world/group-readable key material. *)
    let perm = st.Unix.st_perm land 0o777 in
    if perm land 0o077 <> 0 then
      Error (Printf.sprintf
               "permissions too permissive on %s: %o (expected 0600)"
               path perm)
    else
      let ic = open_in path in
      let len = in_channel_length ic in
      let body = really_input_string ic len in
      close_in ic;
      (match Yojson.Safe.from_string body with
       | exception Yojson.Json_error msg ->
         Error ("identity json parse: " ^ msg)
       | j -> of_json j)
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
    Error (Printf.sprintf "identity file not found: %s" path)
  | Unix.Unix_error (e, fn, arg) ->
    Error (Printf.sprintf "load %s: %s (%s %s)"
             path (Unix.error_message e) fn arg)
  | Sys_error msg -> Error ("load: " ^ msg)

let write_openssh_key (id : t) ~(priv_path : string) =
  try
    if Sys.file_exists priv_path then Ok ()
    else
      let dir = Filename.dirname priv_path in
      (try ignore (Unix.stat dir) with Unix.Unix_error _ -> Unix.mkdir dir 0o700);
      match generate_ssh_key ~priv_path ~alias:id.alias_hint with
      | Ok () -> Ok ()
      | Error e -> Error e
  with
  | Unix.Unix_error (e, fn, arg) ->
      Error (Printf.sprintf "write_openssh_key %s: %s (%s %s)"
               priv_path (Unix.error_message e) fn arg)
  | Sys_error msg -> Error ("write_openssh_key: " ^ msg)

let load_or_create_at ~(path : string) ~(alias_hint : string) =
  match load ~path () with
  | Ok id ->
      (match write_openssh_key id ~priv_path:(path ^ ".ssh") with
       | Ok () -> ()
       | Error e -> Printf.eprintf "[load_or_create_at] openssh key write failed: %s\n%!" e);
      id
  | Error _ ->
      let id = generate ~alias_hint () in
      (match save ~path id with
       | Error e -> failwith ("load_or_create_at save: " ^ e)
       | Ok () ->
           (match write_openssh_key id ~priv_path:(path ^ ".ssh") with
            | Ok () -> ()
            | Error e -> Printf.eprintf "[load_or_create_at] openssh key write failed: %s\n%!" e);
           id)
