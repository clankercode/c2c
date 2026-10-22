(** Local, sender-bound contact authority. No network operations. All errors are
    fixed redacted messages. A store error must stop delivery, never select /send.
    Scope is exactly [dm-first-contact], matching the relay's contact_scope_v1. *)
type selection =
  | Legacy
  | Contact of {
      grant_id : string;
      grant_secret : string;
      recipient_pk : string;
      delivery_alias : string;
      allow_http : bool;
    }

val prepare :
  ?dir:string -> relay_url:string -> to_alias:string -> sender_pk:string ->
  from_alias:string -> content:string -> message_id:string -> now:float ->
  unit -> (selection, string) result
(** Commits the exact grant and payload hash before returning. Retry IDs are
    scoped by canonical relay and exact route, and never switch grant versions.
    Legacy IDs are pinned too: importing protection subsequently holds an old
    legacy ID instead of silently rerouting it or bypassing protection.
    Disabled routes hold all retries. Expired original grants hold retries even
    when a newer grant is current. Server revocation is authoritative: callers
    must preserve the ID/pending mail on denial and must never try another grant.
    An empty sender key is allowed only for an unprotected legacy route. *)

val import_file :
  ?dir:string -> relay_url:string -> to_alias:string -> sender_pk:string ->
  allow_http:bool -> path:string -> now:float -> unit -> (unit, string) result
(** The recipient-issued artifact must be trusted out of band. Import verifies
    its exact relay, route, keys, scope, secret verifier and expiry. It never
    derives the recipient from a display string or queries a relay. Rotations
    preserve identities and advance generation. Explicit reimport can reenable
    a disabled route; it cannot change that route's sender or recipient keys.
    HTTP requires explicit local consent on import; exported cards do not
    transfer this consent. Existing immutable grants cannot change consent. *)

val disable :
  ?dir:string -> relay_url:string -> to_alias:string -> unit -> (unit, string) result
(** Local tombstone, including for a previously unknown route. Retains grants
    and pins. This is not a relay-side revocation operation. *)

val list_metadata : ?dir:string -> unit -> (Yojson.Safe.t, string) result
(** JSON list of allowlisted current-route metadata; never secrets or bodies. *)

val export_file :
  ?dir:string -> relay_url:string -> to_alias:string -> path:string ->
  unit -> (unit, string) result
(** Explicit new regular output file only, created exclusively at mode 0600.
    No stdout, overwrite, or symlink following. Exports only enabled routes. *)

val canonical_url : string -> (string, string) result
(** Root HTTP(S) origin only; lowercases scheme/host and removes default port
    and trailing slash. Refuses userinfo, path prefixes, query and fragment. *)
val read_private_json : string -> (Yojson.Safe.t, string) result
(** Owner-only (0400 or 0600) regular single-link file, at most 64 KiB;
    checks lstat/fstat
    identity and refuses symlinks in every path component. *)
val default_dir : unit -> string
(** [$XDG_CONFIG_HOME/c2c/contacts], otherwise [$HOME/.config/c2c/contacts].
    Missing/invalid home configuration produces a store error at the boundary.
    Dedicated directory must be owned by this uid and exactly mode 0700;
    database must be mode 0600. Unsafe existing permissions are not repaired.
    A durable marker detects a missing database after initialization. Removing
    the entire store externally also removes that marker; callers must treat
    deliberate store-directory removal as authority reset, never routine GC. *)
