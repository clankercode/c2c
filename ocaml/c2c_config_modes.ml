(** [C2c_config_modes] — report shared client configs whose permissions are
    wider than they should be (#84).

    {1 Why this exists}

    c2c edits configuration files the OPERATOR owns — [~/.claude.json],
    [~/.codex/config.toml], [~/.hermes/config.yaml], and friends. Since #84 an
    atomic write PRESERVES the target's mode instead of resetting it to the
    umask default, because [rename] swaps the inode and would otherwise widen
    any file the operator had restricted.

    Preserving is the right default: silently changing permissions on a file
    c2c did not create is the kind of helpfulness that breaks a shared-machine
    setup at the worst possible moment. But it has a corollary — c2c now
    preserves an over-permissive mode (a real [~/.codex/config.toml] observed
    at 0777) just as faithfully as a restrictive one, where the old bug used to
    narrow it by accident.

    So c2c reports and the operator decides. This module is the reporting half;
    it never changes a mode.

    {1 Where the path list comes from}

    The install manifest, not a hardcoded table. That means the list cannot
    drift as clients are added, and it names only files c2c actually wrote on
    THIS machine. The manifest is best-effort by design (install proceeds even
    if it cannot be written), so a missing or empty manifest yields [`Unknown]
    rather than a clean bill of health — reporting "no problems" from "no data"
    is the one answer that would actively mislead. *)

type verdict =
  | Clean of int  (** All good; carries how many shared configs were checked. *)
  | World_writable of string list  (** Offending paths, sorted. *)
  | Unknown of string  (** No usable manifest; carries the reason. *)

(** True for the manifest artifact kinds that denote a file c2c shares with the
    operator ([shared-key], [shared-block], [shared-toml-section]) as opposed
    to one it owns outright. Owned files are c2c's to set modes on, so they are
    deliberately out of scope. *)
let is_shared_kind (kind : string) : bool =
  String.length kind >= 6 && String.sub kind 0 6 = "shared"

(** Permission bits that make a file writable by anyone on the machine. Group
    write is deliberately NOT flagged: a shared group is a normal, deliberate
    setup, whereas world-write on a file holding MCP server definitions is not
    something anyone chooses on purpose. *)
let world_writable_mask = 0o002

let is_world_writable (path : string) : bool =
  match Unix.stat path with
  | st -> st.Unix.st_perm land world_writable_mask <> 0
  | exception _ -> false

(** [shared_paths manifest] is every distinct shared-config path recorded in
    [manifest], sorted. *)
let shared_paths (manifest : C2c_install_manifest.manifest) : string list =
  List.concat_map
    (fun (r : C2c_install_manifest.install_record) -> r.artifacts)
    manifest.installs
  |> List.filter (fun (a : C2c_install_manifest.artifact) -> is_shared_kind a.kind)
  |> List.map (fun (a : C2c_install_manifest.artifact) -> a.path)
  |> List.sort_uniq String.compare

(** [check ()] reads the install manifest and classifies the shared configs it
    records. Pure reporting — nothing is modified. *)
let check () : verdict =
  match C2c_install_manifest.read_manifest () with
  | exception _ -> Unknown "install manifest unreadable"
  | { C2c_install_manifest.installs = []; _ } ->
      Unknown "no install manifest — nothing recorded yet"
  | manifest -> (
      let paths = shared_paths manifest in
      match List.filter is_world_writable paths with
      | [] -> Clean (List.length paths)
      | offenders -> World_writable offenders)

(** [message verdict] is the one-line human summary. Offending paths are listed
    separately by the caller so they can be indented under it. *)
let message (v : verdict) : string =
  match v with
  | Unknown reason -> Printf.sprintf "config modes: unknown (%s)" reason
  | Clean n -> Printf.sprintf "config modes: ok (%d shared config(s) checked)" n
  | World_writable offenders ->
      Printf.sprintf
        "config modes: %d shared config(s) are WORLD-WRITABLE — c2c preserves \
         the mode it finds and will not tighten a file it did not create; fix \
         with `chmod o-w <path>`"
        (List.length offenders)

(** Paths to list under [message], empty unless something was flagged. *)
let offenders (v : verdict) : string list =
  match v with World_writable ps -> ps | Clean _ | Unknown _ -> []

let color (v : verdict) : [ `Green | `Yellow | `Gray ] =
  match v with Clean _ -> `Green | World_writable _ -> `Yellow | Unknown _ -> `Gray
