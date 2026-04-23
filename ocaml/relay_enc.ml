(* Layer 3 encryption identity — X25519 keypair + on-disk enc_identity.json.
   Spec: M1-breakdown.md §S1. *)

type t = {
  version : int;
  alg : string;
  public_key : string;  (* 32 bytes, raw X25519 public key *)
  private_key_seed : string;  (* 32 bytes, raw X25519 secret *)
  created_at : string;
}

let ( // ) = Filename.concat

let b64url_encode s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let b64url_decode s =
  Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let default_path ~session_id =
  let home =
    try Sys.getenv "HOME"
    with Not_found -> "/"
  in
  let xdg =
    try Sys.getenv "XDG_DATA_HOME"
    with Not_found -> Filename.concat (Filename.concat home ".local") "share"
  in
  let keys_dir = Filename.concat (Filename.concat xdg "c2c") "keys" in
  (* One X25519 keypair per session, alongside Ed25519 identity. *)
  keys_dir // session_id ^ ".x25519"

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

let generate () =
  ensure_rng ();
  let secret, public = Mirage_crypto_ec.X25519.gen_key () in
  let private_key_seed = Mirage_crypto_ec.X25519.secret_to_octets secret in
  {
    version = 1;
    alg = "x25519";
    public_key = public;
    private_key_seed;
    created_at = rfc3339_utc_now ();
  }

let public_key_b64 t = b64url_encode t.public_key

let to_json t : Yojson.Safe.t =
  `Assoc [
    "version",     `Int t.version;
    "alg",         `String t.alg;
    "public_key",  `String (b64url_encode t.public_key);
    "private_key", `String (b64url_encode t.private_key_seed);
    "created_at",  `String t.created_at;
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
      let* created_at = find_string fields "created_at" in
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
      else if alg <> "x25519" then
        Error (Printf.sprintf "unsupported alg: %s (expected x25519)" alg)
      else
        Ok { version; alg; public_key; private_key_seed; created_at }
  | _ -> Error "enc identity json: expected object"

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

let save ~path t =
  try
    let dir = Filename.dirname path in
    mkdir_p_mode dir 0o700;
    (try Unix.chmod dir 0o700 with Unix.Unix_error _ -> ());
    let tmp = path ^ ".tmp" in
    let fd =
      Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
    in
    let oc = Unix.out_channel_of_descr fd in
    let body = Yojson.Safe.pretty_to_string (to_json t) ^ "\n" in
    output_string oc body;
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

let load ~path () =
  try
    let st = Unix.stat path in
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
           Error ("enc identity json parse: " ^ msg)
       | j -> of_json j)
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
      Error (Printf.sprintf "enc identity file not found: %s" path)
  | Unix.Unix_error (e, fn, arg) ->
      Error (Printf.sprintf "load %s: %s (%s %s)"
               path (Unix.error_message e) fn arg)
  | Sys_error msg -> Error ("load: " ^ msg)

(* Load or generate a keypair for the given session. *)
let load_or_generate ~session_id =
  let path = default_path ~session_id in
  match load ~path () with
  | Ok t -> Ok t
  | Error _ ->
      (* Key doesn't exist yet — generate and save. *)
      let t = generate () in
      match save ~path t with
      | Ok () -> Ok t
      | Error e -> Error ("save after generate: " ^ e)
