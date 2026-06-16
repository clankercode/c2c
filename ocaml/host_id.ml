(* host_id.ml — compute the opaque per-host identifier for c2c.

   Slice 1 of .collab/design/2026-06-17-c2c-opaque-host-id.md. The recipe
   is a direct port of the extension's `computeHostHash` in
   `pi-c2c/src/relay.ts:62-93` — same kind-prefixed input, same SHA256,
   same 12-lowercase-hex-char output. The production implementation uses
   `digestif.ocaml` (vendored SHA256), NOT shell-out to `sha256sum` (the
   reference PoC at ocaml/tools/host_id_poc.ml does shell-out for
   minimal-dependency testability; this is the production code).

   Stability chain (try in order, take first non-empty):
     1. /sys/class/dmi/id/product_uuid    kind="product_uuid"
     2. /etc/machine-id                   kind="machine_id"
     3. Unix.gethostname() (trimmed)      kind="hostname"
   Then: hex = sha256("<kind>=<value>")[:12] (lowercase).
   On a single source failure (no files readable, no hostname), returns
   the zero-id "000000000000" as a sentinel — caller decides whether
   that's a fatal error. *)

(* Trim a string. Returns "" for empty/whitespace-only input. *)
let trim s = String.trim s

let is_nonempty s = s <> ""

(* Try to read a file and return its trimmed contents if non-empty.
   Returns None on any I/O error (ENOENT, EACCES, EISDIR, ...). *)
let try_read_file path : string option =
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> try close_in ic with _ -> ())
      (fun () ->
         let n = in_channel_length ic in
         let s = really_input_string ic n in
         let t = trim s in
         if is_nonempty t then Some t else None)
  with _ -> None

(* Single-source primary + fallback. The kind string is the SALT prefix
   (e.g. "product_uuid=") — this is the value that gets hashed, so a
   product_uuid "abc" and a hostname "abc" intentionally produce
   different ids. *)
let pick_host_source () : (string * string) option =
  match try_read_file "/sys/class/dmi/id/product_uuid" with
  | Some v when is_nonempty v -> Some ("product_uuid", v)
  | _ ->
    match try_read_file "/etc/machine-id" with
    | Some v when is_nonempty v -> Some ("machine_id", v)
    | _ ->
      let h = trim (Unix.gethostname ()) in
      if is_nonempty h then Some ("hostname", h) else None

(* Compute the opaque per-host id. Returns 12 lowercase hex chars on
   success; "000000000000" when no source is available (caller should
   treat as fatal in a real workflow). *)
let compute_host_hash () : string =
  match pick_host_source () with
  | None -> "000000000000"
  | Some (kind, value) ->
    let input = Printf.sprintf "%s=%s" kind value in
    let digest = Digestif.SHA256.digest_string input in
    let hex = Digestif.SHA256.to_hex digest in
    (* `to_hex` returns 64 lowercase hex chars; recipe spec is 12. *)
    String.sub hex 0 12

(* Same as compute_host_hash but returns structured info for the
   --json CLI output: the kind+value used + the 12-char id. The kind
   and value are useful for diagnostics ("which source was used?")
   and for any future client that wants to surface them in its own
   UI. *)
type source_info = {
  kind : string;
  value : string;
  host_id : string;
}

let compute_host_hash_with_source () : source_info =
  match pick_host_source () with
  | None ->
    { kind = ""; value = ""; host_id = "000000000000" }
  | Some (kind, value) ->
    let host_id = compute_host_hash () in
    { kind; value; host_id }
