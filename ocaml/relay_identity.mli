(** Layer 3 peer identity — Ed25519 keypair + on-disk identity.json.

    Spec: [docs/c2c-research/relay-peer-identity-spec.md].

    All binary fields at this API boundary are raw byte strings:
    - public key: 32 bytes
    - private key (seed): 32 bytes
    - signature: 64 bytes

    Serialization to/from the on-disk JSON uses base64url-nopad,
    matching the wire format in the spec. *)

type t = {
  version : int;
  alg : string;
  public_key : string;      (** 32 raw bytes *)
  private_key_seed : string;(** 32 raw bytes — the Ed25519 seed *)
  fingerprint : string;     (** "SHA256:<b64url-nopad-trimmed-43>" *)
  created_at : string;      (** RFC 3339 UTC *)
  alias_hint : string;      (** informational only, never authoritative *)
}

(** [default_path ()] resolves [$XDG_CONFIG_HOME/c2c/identity.json]
    (fallback [~/.config/c2c/identity.json]). *)
val default_path : unit -> string

(** [fingerprint_of_pk pk] = ["SHA256:" ^ base64url-nopad(sha256(pk))[0..42]].

    Matches the ssh-style short fingerprint defined in the spec. *)
val fingerprint_of_pk : string -> string

(** [generate ?alias_hint ()] creates a fresh Ed25519 keypair.

    Initializes the RNG on first call; safe to call multiple times. *)
val generate : ?alias_hint:string -> unit -> t

(** [sign identity msg] returns a 64-byte Ed25519 signature over [msg]. *)
val sign : t -> string -> string

(** [verify ~pk ~msg ~sig_] — verifies a 64-byte Ed25519 signature.

    Returns [false] on malformed pk (not 32 bytes) or malformed sig
    (not 64 bytes) rather than raising. *)
val verify : pk:string -> msg:string -> sig_:string -> bool

(** [canonical_msg ~ctx fields] = [ctx ^ "\x1f" ^ (join "\x1f" fields)].

    The single canonical message-to-sign construction per spec §3.4.
    Fields are joined with the ASCII unit separator (0x1F) and
    prefixed with the per-purpose SIGN_CTX literal. *)
val canonical_msg : ctx:string -> string list -> string

(** [to_json t] / [of_json j] — JSON serialization of [t].

    Binary fields are base64url-nopad. Mode 0600 enforced by
    [save]/[load], not by this conversion. *)
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result

(** [save ?path t] writes [t] atomically to [path] (default
    [default_path ()]). Enforces mode [0600] on the file and creates
    parent dirs with mode [0700]. Overwrites any existing file. *)
val save : ?path:string -> t -> (unit, string) result

(** [load ?path ()] reads and parses an identity file.

    Refuses to load files with permissions looser than [0600]
    (mirrors ssh's behavior on [~/.ssh/id_ed25519]). Returns
    [Error "permissions too permissive: ..."] in that case. *)
val load : ?path:string -> unit -> (t, string) result

(** [load_or_create_at ~path ~alias_hint] loads an identity from [path],
    or generates and saves a fresh one if [path] does not exist.
    Used for per-alias keys stored under [<broker_root>/keys/<alias>.ed25519]. *)
val load_or_create_at : path:string -> alias_hint:string -> t
