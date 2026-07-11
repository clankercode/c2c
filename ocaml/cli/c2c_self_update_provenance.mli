(** Package-manager provenance detection + delegation policy for
    [c2c self-update] (B101 / A003 / F101).

    Every input is injected (running binary realpath, PATH-resolved realpath,
    manager availability), so this module is pure and hermetic: unit tests
    exercise every branch without a real package manager, filesystem, or
    network. The [c2c_self_update] wrapper supplies the real inputs. *)

type install_method =
  | Standalone
      (** Plain binary in a normal bin dir — safe to update in place. *)
  | Npm
  | Pnpm
  | Bun
  | Unknown
      (** Binary lives inside a package store but the owning manager cannot be
          identified — refuse rather than guess. *)

val string_of_method : install_method -> string

(** The npm package that ships the c2c binary across all managers. *)
val package_name : string

type t = {
  method_ : install_method;
  binary_path : string;         (** realpath used for detection *)
  package_name : string;
  shadowed_by : string option;  (** [Some p] when a different [c2c] on PATH ([p])
                                    would run instead of [binary_path]. *)
}

(** Classify a path purely by its residency in a package-manager store.
    Looks only at path segments — no filesystem access. *)
val classify_path : string -> install_method

(** Detect provenance of the running binary.
    [binary_path] is its realpath; [resolved_on_path] is the realpath of the
    first [c2c] found on PATH ([None] when PATH has none). [bun_install] is the
    value of BUN_INSTALL (injected): a custom bun prefix need not contain a
    [.bun] segment, so a binary under it is reclassified from Npm to Bun. *)
val detect :
  ?bun_install:string ->
  binary_path:string ->
  resolved_on_path:string option ->
  unit ->
  t

(** Exact command to update via the owning manager, or [None] for
    standalone/unknown. [pinned] selects a version ([@latest] by default). *)
val delegate_command : install_method -> pinned:string option -> string option

(** Name of the CLI binary for the owning manager, or [None]. *)
val manager_binary : install_method -> string option

type action =
  | In_place_standalone
      (** Proceed with the verified in-place binary replacement. *)
  | Delegate of { method_ : install_method; command : string }
      (** Hand the update to the owning package manager. *)
  | Refuse of string  (** Abort with this actionable message. *)

(** Pure decision: given detected provenance, [check_only], [pinned] version,
    and whether the owning manager is available on PATH, return the action.
    Never mutates. Delegation under [check_only] reports the command without
    requiring the manager to be present. *)
val plan :
  t ->
  check_only:bool ->
  pinned:string option ->
  manager_available:bool ->
  action

(** One-line human description of the detected method (no environment leak). *)
val describe : t -> string

(** The single stdout JSON document for the dispatcher's delegate path (the
    real shipped shape). Five stable keys: [install_method], [delegate_command],
    [check_only], [executed], [exit_code] ([null] until the command runs).
    [executed] is [false] for the report/check path, [true] once the delegate
    command has run; [exit_code] is [Some rc] only then. *)
val delegate_json :
  method_:install_method ->
  command:string ->
  check_only:bool ->
  executed:bool ->
  exit_code:int option ->
  Yojson.Safe.t

(** The single stdout JSON document for the refuse paths: an [error] message
    plus [exit_code] (default [1]). *)
val error_json : ?exit_code:int -> string -> Yojson.Safe.t

(** Message classifying the result of an executed delegate command. *)
val delegate_outcome_message :
  install_method -> command:string -> rc:int -> string
