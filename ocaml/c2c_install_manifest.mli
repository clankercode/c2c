(* c2c_install_manifest.mli — install receipt / manifest for c2c install/uninstall.

   The manifest records every artifact written by `c2c install <component>` so
   that `c2c uninstall <component>` can remove it surgically.  It is stored at
   $XDG_STATE_HOME/c2c/install-manifest.json (falling back to
   ~/.local/state/c2c/install-manifest.json) and updated with an atomic,
   flock-guarded write.

   Manifest writes are best-effort: install proceeds even if the manifest
   cannot be updated, and uninstall falls back to deterministic known paths. *)

(** Artifact kinds and their JSON/TOML removal metadata. *)
type artifact = {
  kind : string;              (** "owned-file" | "symlink" | "binary" | "schedule" |
                                  "shared-key" | "shared-block" | "shared-toml-section" *)
  path : string;              (** Absolute path to the file. *)
  key : string option;        (** For shared-key: JSON key path, e.g. "mcpServers.c2c". *)
  format : string option;     (** For shared-key: "json" | "toml". *)
  begin_marker : string option;   (** For shared-block: start marker line. *)
  end_marker : string option;     (** For shared-block: end marker line. *)
  legacy_marker : string option;  (** For shared-block: optional legacy single-line marker. *)
  section_prefix : string option; (** For shared-toml-section: section header prefix. *)
}

(** One install record per (component, target_dir) pair. *)
type install_record = {
  component : string;
  alias : string option;
  target_dir : string;
  c2c_version : string;
  ts : float;
  artifacts : artifact list;
}

(** Top-level manifest schema. *)
type manifest = {
  version : int;
  installs : install_record list;
}

(** Return the canonical manifest path.
    Honors [C2C_INSTALL_MANIFEST_PATH] for tests, then the XDG/state fallback. *)
val manifest_path : unit -> string

(** {1 Constructors} *)

val owned_file : string -> artifact
val symlink : string -> artifact
val binary : string -> artifact
val schedule : string -> artifact
val shared_key : path:string -> key:string -> format:string -> artifact
val shared_block :
  path:string -> begin_marker:string -> end_marker:string ->
  ?legacy_marker:string -> unit -> artifact
val shared_toml_section : path:string -> section_prefix:string -> artifact

(** {1 Read / write} *)

(** Read the manifest from disk.  Returns an empty version-1 manifest if the
    file is missing or unparseable. *)
val read_manifest : unit -> manifest

(** Replace or append a record keyed by [(component, target_dir)]. *)
val upsert_record : record:install_record -> unit

(** Remove the record for the given [(component, target_dir)] if present. *)
val remove_record : component:string -> target_dir:string -> unit

(** {1 Serialization helpers} *)

val artifact_to_json : artifact -> Yojson.Safe.t
val artifact_of_json : Yojson.Safe.t -> artifact
val manifest_to_json : manifest -> Yojson.Safe.t
val manifest_of_json : Yojson.Safe.t -> manifest
