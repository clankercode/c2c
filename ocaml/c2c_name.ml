(* Shared name/alias sanitization used by c2c_start (instance names),
   the MCP broker (aliases/register), and the relay (peer ids).

   Rules: 1..64 chars, [A-Za-z0-9._-], no leading dot. Rejects '/',
   '@', '#', whitespace, and other shell/broker-hostile chars that
   would create nested dirs or collide with alias@repo#host syntax.

   Slice 1 of .collab/design/2026-06-17-c2c-opaque-host-id.md adds an
   OPTIONAL `<name>#<opaque_host_id>` suffix to the alias format
   (e.g. `lyra-quill#3d08761ae3f3`). The opaque_host_id is a 12-16 char
   lowercase hex string produced by `c2c host-id`. Use
   [is_valid_with_opaque_host_id] to validate the new shape; the
   original [is_valid] still rejects `#` for back-compat with the
   stricter local-broker rules. *)

let is_valid (n : string) : bool =
  let len = String.length n in
  if len = 0 || len > 64 then false
  else if n.[0] = '.' then false
  else begin
    let ok = ref true in
    String.iter (fun c ->
      let good =
        (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9')
        || c = '-' || c = '_' || c = '.'
      in
      if not good then ok := false
    ) n;
    !ok
  end

(* Returns true iff `s` is a 12-16 char lowercase hex string. *)
let is_opaque_host_id s =
  let len = String.length s in
  if len < 12 || len > 16 then false
  else begin
    let ok = ref true in
    String.iter (fun c ->
      let good = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') in
      if not good then ok := false
    ) s;
    !ok
  end

(* Validate an alias that may include an opaque_host_id suffix
   (`<name>#<12-16 hex>`). The total length must be <= 80 (1..64 name
   + 1 `#` + 12..16 hex); the leading char of `<name>` must not be a
   dot. When the suffix is absent, behaves identically to [is_valid]. *)
let is_valid_with_opaque_host_id (n : string) : bool =
  match String.index_opt n '#' with
  | None -> is_valid n
  | Some i ->
      let total = String.length n in
      if total > 80 then false
      else begin
        let name = String.sub n 0 i in
        let suffix = String.sub n (i + 1) (total - i - 1) in
        is_valid name && is_opaque_host_id suffix
      end

(* Split an alias into (name, host_id_opt). The name is the part
   before `#`; host_id_opt is the part after when well-formed, else
   None (and the caller should treat the alias as invalid). The split
   is purely positional; validation is the caller's responsibility
   (use [is_valid_with_opaque_host_id]). *)
let split_opaque_host_id (n : string) : string * string option =
  match String.index_opt n '#' with
  | None -> (n, None)
  | Some i ->
      let total = String.length n in
      let name = String.sub n 0 i in
      let suffix = String.sub n (i + 1) (total - i - 1) in
      (name, Some suffix)

let error_message (kind : string) (n : string) : string =
  Printf.sprintf
    "invalid %s '%s'. Allowed chars: [A-Za-z0-9._-], 1..64, no leading dot. \
     Optional suffix '#<opaque_host_id>' (12-16 lowercase hex) is allowed \
     for the relay alias shape."
    kind n
