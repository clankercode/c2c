(* Staleness detection for managed instances (idea I010). See c2c_stale.mli. *)

type verdict =
  | Current
  | Stale
  | Unknown of string

let proc_exe pid = Printf.sprintf "/proc/%d/exe" pid

(* [dev:ino] of the file a path resolves to. [Unix.stat] follows the
   /proc/<pid>/exe symlink to its target inode even when the on-disk name was
   unlinked (deleted-but-open) — exactly the post-install case. *)
let dev_ino path =
  match Unix.stat path with
  | st -> Some (st.Unix.st_dev, st.Unix.st_ino)
  | exception _ -> None

let file_size path =
  match Unix.stat path with
  | st -> Some st.Unix.st_size
  | exception _ -> None

(* SHA-256 of a file's contents. Reads /proc/<pid>/exe directly, which yields
   the running image's bytes even after the on-disk name was replaced. Returns
   [None] on any read error (permission, gone). Mirrors the streaming-free
   approach in C2c_mcp_helpers.best_effort_file_sha256. *)
let sha256_file path =
  match
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let len = in_channel_length ic in
        really_input_string ic len
        |> Digestif.SHA256.digest_string
        |> Digestif.SHA256.to_hex)
  with
  | hex -> Some hex
  | exception _ -> None

let compare_images ~target ~installed : verdict =
  match (dev_ino target, dev_ino installed) with
  | None, _ ->
      Unknown
        (Printf.sprintf "cannot read %s (process gone or not permitted)" target)
  | _, None -> Unknown "cannot resolve installed binary image"
  | Some di, Some inst_di when di = inst_di ->
      (* Same inode: unambiguously the same on-disk image. *)
      Current
  | Some _, Some _ -> (
      (* Different inode. install-all's rm+cp mints a fresh inode on every
         install, so this fires even when the compiled code is unchanged.
         Distinguish "same code, new inode" from a real upgrade by content:
         size is a cheap discriminator before hashing ~23 MB twice. *)
      match (file_size target, file_size installed) with
      | Some s1, Some s2 when s1 <> s2 -> Stale
      | _ -> (
          match (sha256_file target, sha256_file installed) with
          | Some h1, Some h2 -> if h1 = h2 then Current else Stale
          | _ ->
              Unknown "different inode; could not hash images to confirm"))

let classify ~installed_exe pid : verdict =
  compare_images ~target:(proc_exe pid) ~installed:installed_exe

let verdict_label = function
  | Current -> "current"
  | Stale -> "stale"
  | Unknown _ -> "unknown"
