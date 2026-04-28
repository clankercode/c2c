(* c2c_migrate.ml — broker dir migration logic.

   Implements `c2c migrate-broker` (#360 hotfix). The previous version
   shipped a hardcoded copy-list that missed real legacy artifacts
   (keys/, allowed_signers, broker.log, room_history.d/, top-level
   *.inbox.json, .monitor-locks/, pending-orphan-replay.*, …) — see
   `.collab/findings/2026-04-28T04-50-00Z-stanza-coder-migrate-broker-silent-data-loss.md`.

   New shape: walk the legacy tree and classify each entry into one of:
     - Copy            : real broker state, must move with the broker
     - Deny_process_local : recreated by the running broker, do not copy
     - Already_at_canonical : exists at destination, skip
     - Unknown         : aborts the migration with a clear error

   The classifier uses an explicit deny-list (PID files + lockfiles) and
   a default-COPY policy for everything else. New artifact classes that
   appear in the legacy dir without an explicit copy/deny rule are
   intentionally COPY-by-default — silent skipping is the bug we are
   fixing — but if a future change wants stricter behavior it can flip
   the default and surface UNKNOWN entries via fail-loud.

   Two-phase commit:
     phase 1 — copy every COPY entry into the destination
     phase 2 — verify each copied path exists at the destination
     phase 3 — only after verify succeeds, remove the legacy tree
   Failures in phase 1/2 leave the legacy tree untouched. *)

let ( // ) = Filename.concat

type classification =
  | Copy                 (** real broker state — must be migrated *)
  | Deny_process_local of string  (** reason — recreated by broker, safe to drop *)
  | Already_at_canonical (** destination already has this path — skip *)
  | Unknown of string    (** classifier could not place this entry — abort *)

type entry = {
  rel_path : string;       (** path relative to legacy root *)
  is_dir : bool;
  classification : classification;
}

(* ------------------------------------------------------------------ *)
(* Classification                                                     *)
(* ------------------------------------------------------------------ *)

(** Process-local file? PID files and lockfiles are recreated by the running
    broker (flock sidecar pattern, see c2c_mcp.ml:1140 / 1569 / 1828 / 2191
    / 2194). Their contents do not survive a move because the kernel-held
    fcntl lock is bound to the open fd in the source process, not the file
    bytes. Safe — and correct — to drop them on migration. *)
let is_process_local_basename name =
  if Filename.check_suffix name ".pid" then Some "pid file (process-local)"
  else if Filename.check_suffix name ".lock" then Some "fcntl/flock sidecar (recreated lazily)"
  else None

(** Classify one entry. Top-level entries get the deny-list check; nested
    entries inside known-state subdirs (archive/, memory/, keys/, rooms/,
    room_history.d/, inbox.json.d/, archive/, .leases/, .sitreps/,
    .cold_boot_done/, .monitor-locks/, nudge/) are always COPY — even if
    they happen to end in .lock — because the parent dir is being copied
    wholesale and an internal lock sidecar moving with its data is fine.

    Only the broker root's TOP-LEVEL .lock / .pid files are denied — those
    are the ones an actively-running broker is holding. *)
let classify_top_level ~src_root ~dest_root rel_path is_dir =
  let dest_path = dest_root // rel_path in
  if Sys.file_exists dest_path then Already_at_canonical
  else if is_dir then Copy
  else begin
    (* Verify the entry is a copyable file kind (regular or symlink). Anything
       else (FIFO, socket, char/block device) has no defined copy semantics and
       is a fail-loud Unknown, not a silent skip. *)
    let abs = src_root // rel_path in
    let kind =
      try Some (Unix.lstat abs).Unix.st_kind with _ -> None
    in
    match kind with
    | Some Unix.S_REG | Some Unix.S_LNK ->
        (match is_process_local_basename rel_path with
         | Some reason -> Deny_process_local reason
         | None -> Copy)
    | Some Unix.S_FIFO -> Unknown "FIFO/named pipe — no defined copy semantics"
    | Some Unix.S_SOCK -> Unknown "socket — no defined copy semantics"
    | Some Unix.S_CHR -> Unknown "character device — no defined copy semantics"
    | Some Unix.S_BLK -> Unknown "block device — no defined copy semantics"
    | Some Unix.S_DIR -> Copy  (* shouldn't reach here; is_dir handled above *)
    | None -> Unknown "could not stat entry"
  end

(* ------------------------------------------------------------------ *)
(* Walk the legacy tree                                               *)
(* ------------------------------------------------------------------ *)

(** Enumerate top-level entries of [src_root] and classify each. We do NOT
    recurse here — directories are copied wholesale in phase 1, so the
    classifier only needs the top-level structure. *)
let enumerate ~src_root ~dest_root : entry list =
  if not (Sys.file_exists src_root) then []
  else
    let entries =
      try Array.to_list (Sys.readdir src_root)
      with _ -> []
    in
    let entries = List.filter (fun n -> n <> "." && n <> "..") entries in
    let entries = List.sort String.compare entries in
    List.map (fun name ->
      let abs = src_root // name in
      let is_dir =
        try Sys.is_directory abs with _ -> false
      in
      { rel_path = name
      ; is_dir
      ; classification = classify_top_level ~src_root ~dest_root name is_dir
      }
    ) entries

(* ------------------------------------------------------------------ *)
(* Copy primitives                                                    *)
(* ------------------------------------------------------------------ *)

let mkdir_p dir =
  let rec loop d =
    if d = "/" || d = "." || d = "" then ()
    else if Sys.file_exists d then ()
    else begin
      loop (Filename.dirname d);
      try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  loop dir

let copy_file_bytes src dst =
  mkdir_p (Filename.dirname dst);
  let buf_size = 65536 in
  let buf = Bytes.create buf_size in
  let src_ic = open_in src in
  Fun.protect ~finally:(fun () -> close_in src_ic) @@ fun () ->
  let dst_oc = open_out dst in
  Fun.protect ~finally:(fun () -> close_out dst_oc) @@ fun () ->
  let rec loop () =
    let n = input src_ic buf 0 buf_size in
    if n = 0 then ()
    else begin output dst_oc buf 0 n; loop () end
  in
  loop ();
  (* Preserve mode (mostly relevant for keys/ — 0o600). *)
  (try
     let st = Unix.stat src in
     Unix.chmod dst (st.Unix.st_perm)
   with _ -> ())

let rec copy_tree src dst =
  let st = Unix.lstat src in
  match st.Unix.st_kind with
  | Unix.S_DIR ->
      mkdir_p dst;
      let entries =
        try Array.to_list (Sys.readdir src)
        with _ -> []
      in
      List.iter (fun n ->
        if n <> "." && n <> ".." then
          copy_tree (src // n) (dst // n)
      ) entries;
      (try
         let st = Unix.stat src in
         Unix.chmod dst (st.Unix.st_perm)
       with _ -> ())
  | Unix.S_REG -> copy_file_bytes src dst
  | Unix.S_LNK ->
      let target = Unix.readlink src in
      (try Unix.symlink target dst with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  | _ ->
      (* sockets, fifos, devices — should never appear in a broker dir *)
      ()

(* ------------------------------------------------------------------ *)
(* Remove legacy tree (phase 3)                                       *)
(* ------------------------------------------------------------------ *)

let rec remove_tree path =
  if not (Sys.file_exists path) then ()
  else
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        let entries =
          try Array.to_list (Sys.readdir path)
          with _ -> []
        in
        List.iter (fun n ->
          if n <> "." && n <> ".." then
            remove_tree (path // n)
        ) entries;
        (try Unix.rmdir path with _ -> ())
    | _ ->
        (try Unix.unlink path with _ -> ())

(* ------------------------------------------------------------------ *)
(* High-level driver                                                  *)
(* ------------------------------------------------------------------ *)

type outcome = {
  ok : bool;
  copied : string list;
  skipped_already : string list;
  denied : (string * string) list;  (* path, reason *)
  unknown : (string * string) list; (* path, reason *)
  error : string option;
}

let empty_outcome = {
  ok = true;
  copied = [];
  skipped_already = [];
  denied = [];
  unknown = [];
  error = None;
}

(** Format a single classification line for `--dry-run` and human output. *)
let render_entry e =
  let kind = if e.is_dir then "DIR " else "FILE" in
  match e.classification with
  | Copy -> Printf.sprintf "  [WILL COPY]              %s %s" kind e.rel_path
  | Deny_process_local reason ->
      Printf.sprintf "  [WILL DENY]              %s %s  -- %s" kind e.rel_path reason
  | Already_at_canonical ->
      Printf.sprintf "  [ALREADY AT CANONICAL]   %s %s" kind e.rel_path
  | Unknown reason ->
      Printf.sprintf "  [UNKNOWN — WILL ABORT]   %s %s  -- %s" kind e.rel_path reason

(** Run the migration. If [dry_run], only enumerate + print classifications;
    no writes. If any entry classifies as [Unknown], abort BEFORE any copy
    even when not dry-running.

    Returns a structured outcome (used by both human and JSON output paths). *)
let run ~src_root ~dest_root ~dry_run ~print_line =
  if not (Sys.file_exists src_root) then
    { empty_outcome with ok = false
    ; error = Some (Printf.sprintf "source broker does not exist: %s" src_root) }
  else if src_root = dest_root then
    { empty_outcome with ok = false
    ; error = Some "from and to paths are the same" }
  else begin
    let entries = enumerate ~src_root ~dest_root in
    print_line (Printf.sprintf "Scanned %d entries in legacy broker root:" (List.length entries));
    List.iter (fun e -> print_line (render_entry e)) entries;
    let unknowns = List.filter_map (fun e ->
      match e.classification with
      | Unknown reason -> Some (e.rel_path, reason)
      | _ -> None
    ) entries in
    if unknowns <> [] then begin
      print_line "";
      print_line "ABORT: unclassified entries found. Refusing to migrate to avoid silent data loss.";
      print_line "Add explicit copy/deny rules in c2c_migrate.ml or remove the entries before retrying.";
      { empty_outcome with ok = false
      ; unknown = unknowns
      ; error = Some "unclassified entries present — aborting" }
    end else if dry_run then begin
      let copied = List.filter_map (fun e ->
        match e.classification with Copy -> Some e.rel_path | _ -> None) entries in
      let skipped = List.filter_map (fun e ->
        match e.classification with Already_at_canonical -> Some e.rel_path | _ -> None) entries in
      let denied = List.filter_map (fun e ->
        match e.classification with
        | Deny_process_local r -> Some (e.rel_path, r)
        | _ -> None) entries in
      print_line "";
      print_line "DRY RUN complete. Run without --dry-run to execute.";
      { ok = true; copied; skipped_already = skipped; denied; unknown = []; error = None }
    end else begin
      (* Phase 1: copy *)
      mkdir_p dest_root;
      let to_copy = List.filter (fun e ->
        match e.classification with Copy -> true | _ -> false) entries in
      let copy_errors = ref [] in
      List.iter (fun e ->
        let src = src_root // e.rel_path in
        let dst = dest_root // e.rel_path in
        try copy_tree src dst
        with exn ->
          copy_errors := (e.rel_path, Printexc.to_string exn) :: !copy_errors
      ) to_copy;
      if !copy_errors <> [] then begin
        let msgs = List.map (fun (p, e) -> Printf.sprintf "  %s: %s" p e) !copy_errors in
        print_line "";
        print_line "COPY FAILED — legacy tree NOT removed. Errors:";
        List.iter print_line msgs;
        { empty_outcome with ok = false
        ; error = Some "copy phase failed; legacy tree preserved" }
      end else begin
        (* Phase 2: verify *)
        let missing = List.filter_map (fun e ->
          let dst = dest_root // e.rel_path in
          if Sys.file_exists dst then None
          else Some e.rel_path
        ) to_copy in
        if missing <> [] then begin
          print_line "";
          print_line "VERIFY FAILED — destination missing entries. Legacy tree NOT removed:";
          List.iter (fun p -> print_line ("  " ^ p)) missing;
          { empty_outcome with ok = false
          ; error = Some "verify phase failed; legacy tree preserved" }
        end else begin
          (* Phase 3: remove legacy *)
          List.iter (fun e ->
            let src = src_root // e.rel_path in
            remove_tree src
          ) entries;
          (* Try to remove the legacy root itself if empty *)
          (try Unix.rmdir src_root with _ -> ());
          let copied = List.map (fun e -> e.rel_path) to_copy in
          let skipped = List.filter_map (fun e ->
            match e.classification with Already_at_canonical -> Some e.rel_path | _ -> None) entries in
          let denied = List.filter_map (fun e ->
            match e.classification with
            | Deny_process_local r -> Some (e.rel_path, r)
            | _ -> None) entries in
          print_line "";
          print_line (Printf.sprintf "Migration complete: %d copied, %d skipped, %d denied (process-local)."
                        (List.length copied) (List.length skipped) (List.length denied));
          { ok = true; copied; skipped_already = skipped; denied; unknown = []; error = None }
        end
      end
    end
  end
