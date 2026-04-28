(* c2c_opencode_plugin_drift.ml — `c2c doctor opencode-plugin-drift` implementation.

   Checks whether the deployed OpenCode plugin is a regular file that has
   drifted from the canonical git source (data/opencode-plugin/c2c.ts), or a
   symlink that correctly points to the canonical source. Reports:
   - OK: deployed is a symlink to canonical source
   - DRIFT: deployed is a regular file with different mtime or size vs canonical
   - STALE: deployed is a symlink but target is not canonical source
   - MISSING: no deployed plugin found

   Also scans <cwd>/.opencode/c2c-debug.log for `=== c2c plugin boot ===` entries
   grouped by pid; if any pid has >1 boot entry with distinct paths, the plugin
   was double-loaded from different bun-cache locations (a #337 follow-up:
   the symlink + globalThis guard prevent the bug at install/load time, but a
   debug-log scan catches future bun-cache duplicates the symlink check might
   miss).

   Exits 1 if DRIFT, STALE, or double-boot detected (needs attention), 0
   otherwise. *)

open Cmdliner.Term.Syntax

let ( // ) = Filename.concat

let canonical = "data" // "opencode-plugin" // "c2c.ts"

let deployed_path () =
  let home = try Sys.getenv "HOME" with Not_found -> "" in
  home // ".config" // "opencode" // "plugins" // "c2c.ts"

let file_info path =
  try
    let st = Unix.stat path in
    Some (st.Unix.st_size, st.Unix.st_mtime)
  with Unix.Unix_error _ -> None

let read_link path =
  try Some (Unix.readlink path) with Unix.Unix_error _ -> None

(* --- #386: debug-log double-boot scan ---------------------------------

   Reads <cwd>/.opencode/c2c-debug.log (capped at last 10000 lines) and
   parses lines emitted by data/opencode-plugin/c2c.ts:217:

     [<ts>] pid=<N> === c2c plugin boot sha=<sha> path=<path> ===

   For each pid, collects the distinct path= values. If any pid has
   more than one distinct path, returns Error with a message naming the
   pid + paths. Missing log file => Ok () (no scan possible, not a
   failure). Read errors => Ok () (best-effort). *)

let read_last_lines path max_lines =
  try
    let ic = open_in path in
    let finally () = try close_in ic with _ -> () in
    Fun.protect ~finally (fun () ->
      let buf = Array.make max_lines "" in
      let count = ref 0 in
      let head = ref 0 in
      (try
         while true do
           let line = input_line ic in
           buf.(!head) <- line;
           head := (!head + 1) mod max_lines;
           if !count < max_lines then incr count
         done
       with End_of_file -> ());
      (* Reconstruct in chronological order. *)
      let n = !count in
      let start =
        if n < max_lines then 0
        else !head
      in
      List.init n (fun i -> buf.((start + i) mod max_lines)))
  with Sys_error _ -> []

(* Boot line shape: "[<ts>] pid=<N> === c2c plugin boot sha=<sha> path=<P> ===".
   Returns Some (pid, path) on a match. *)
let parse_boot_line line =
  let re = Str.regexp "^\\[[^]]*\\] pid=\\([0-9]+\\) === c2c plugin boot sha=[a-f0-9]+ path=\\(.+\\) ===$" in
  if Str.string_match re line 0 then
    let pid = Str.matched_group 1 line in
    let path = Str.matched_group 2 line in
    Some (pid, path)
  else None

let group_by_pid entries =
  let tbl = Hashtbl.create 8 in
  List.iter (fun (pid, path) ->
    let cur = try Hashtbl.find tbl pid with Not_found -> [] in
    if not (List.mem path cur) then
      Hashtbl.replace tbl pid (path :: cur))
    entries;
  Hashtbl.fold (fun pid paths acc -> (pid, List.rev paths) :: acc) tbl []

let debug_log_path () =
  Filename.concat (Sys.getcwd ()) (".opencode" ^ Filename.dir_sep ^ "c2c-debug.log")

let check_debug_log_double_boot ?log_path () : (unit, string) result =
  let path = match log_path with Some p -> p | None -> debug_log_path () in
  if not (Sys.file_exists path) then Ok ()
  else
    let lines = read_last_lines path 10000 in
    let entries = List.filter_map parse_boot_line lines in
    let grouped = group_by_pid entries in
    let dups = List.filter (fun (_pid, paths) -> List.length paths > 1) grouped in
    match dups with
    | [] -> Ok ()
    | _ ->
        let buf = Buffer.create 256 in
        Buffer.add_string buf
          "DOUBLE-BOOT: c2c-debug.log shows >1 plugin boot per pid (different paths)";
        List.iter (fun (pid, paths) ->
          Buffer.add_string buf (Printf.sprintf "\n  pid=%s loaded %d distinct paths:" pid (List.length paths));
          List.iter (fun p -> Buffer.add_string buf (Printf.sprintf "\n    - %s" p)) paths)
          dups;
        Buffer.add_string buf
          "\n  cause: bun import-cache duplicate (or symlink/globalThis guard bypassed)";
        Buffer.add_string buf
          "\n  fix: clear ~/.bun/install/cache, rm -rf .opencode/plugins, then `just install-all`";
        Error (Buffer.contents buf)

(* Runs the debug-log double-boot scan and prints a warning if duplicates
   are present. Returns true iff a duplicate was found (caller should treat
   that as an exit-1 escalator regardless of upstream verdict). *)
let run_debug_log_scan_and_print () : bool =
  match check_debug_log_double_boot () with
  | Ok () -> false
  | Error msg ->
      print_endline msg;
      true

let check_drift () : unit =
  let deployed = deployed_path () in
  let canonical_exists, canonical_info =
    match file_info canonical with
    | Some info -> true, info
    | None -> false, (0, 0.0)
  in
  let deployed_info = file_info deployed in
  let deployed_is_symlink = match read_link deployed with Some _ -> true | None -> false in

  let primary_code =
    if not (Sys.file_exists deployed) then begin
      Printf.printf "MISSING: deployed plugin not found at %s\n" deployed;
      Printf.printf "  Run: cd /path/to/c2c && just install-all\n";
      1
    end else if deployed_is_symlink then begin
      let target = match read_link deployed with Some t -> t | None -> "" in
      let resolved_target =
        if Filename.is_relative target then
          Filename.concat (Filename.dirname deployed) target
        else target
      in
      let canonical_abs = Filename.concat (Sys.getcwd ()) canonical in
      if resolved_target = canonical_abs || resolved_target = canonical then begin
        Printf.printf "OK: deployed plugin is a symlink correctly pointing to canonical source\n";
        Printf.printf "  deployed: %s -> %s\n" deployed target;
        0
      end else begin
        Printf.printf "STALE: deployed plugin is a symlink but points to wrong target\n";
        Printf.printf "  deployed: %s -> %s\n" deployed target;
        Printf.printf "  expected: %s\n" canonical;
        1
      end
    end else begin
      match deployed_info with
      | None ->
          Printf.printf "ERROR: could not stat deployed plugin at %s\n" deployed;
          1
      | Some (d_size, d_mtime) ->
          if not canonical_exists then begin
            Printf.printf "UNKNOWN: canonical source not found at %s\n" canonical;
            Printf.printf "  deployed: size=%d mtime=%.0f\n" d_size d_mtime;
            1
          end else begin
            let (c_size, c_mtime) = canonical_info in
            if d_size = c_size && abs_float (d_mtime -. c_mtime) < 1.0 then begin
              Printf.printf "OK: deployed plugin is in sync with canonical source\n";
              Printf.printf "  deployed:  %s (size=%d mtime=%.0f)\n" deployed d_size d_mtime;
              Printf.printf "  canonical: %s (size=%d mtime=%.0f)\n" canonical c_size c_mtime;
              0
            end else begin
              Printf.printf "DRIFT: deployed plugin has diverged from canonical source\n";
              Printf.printf "  deployed:  %s (size=%d mtime=%.0f)\n" deployed d_size d_mtime;
              Printf.printf "  canonical: %s (size=%d mtime=%.0f)\n" canonical c_size c_mtime;
              Printf.printf "  Run: cd /path/to/c2c && just install-all\n";
              1
            end
          end
    end
  in
  (* #386 follow-up to #337: scan c2c-debug.log for >1 plugin boot per pid.
     Symlink + globalThis guard prevent double-load at install/load time;
     this catches future bun-cache duplicates the symlink check might miss. *)
  let dup = run_debug_log_scan_and_print () in
  exit (if dup then 1 else primary_code)

let opencode_plugin_drift_cmd =
  let open Cmdliner.Term in
  let doc = "Check OpenCode plugin drift + double-boot. Verifies the deployed plugin matches the canonical source (symlink or in-sync regular file) and scans .opencode/c2c-debug.log for >1 plugin boot per pid (#386 follow-up to #337)." in
  let info = Cmdliner.Cmd.info "opencode-plugin-drift" ~doc in
  let term = const (fun () -> check_drift ()) $ const () in
  Cmdliner.Cmd.v info term
