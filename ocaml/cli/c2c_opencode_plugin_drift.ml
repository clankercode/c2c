(* c2c_opencode_plugin_drift.ml — `c2c doctor opencode-plugin-drift` implementation.

   Checks whether the deployed OpenCode plugin is a regular file that has
   drifted from the canonical git source (data/opencode-plugin/c2c.ts), or a
   symlink that correctly points to the canonical source. Reports:
   - OK: deployed is a symlink to canonical source
   - DRIFT: deployed is a regular file with different mtime or size vs canonical
   - STALE: deployed is a symlink but target is not canonical source
   - MISSING: no deployed plugin found

   Exits 1 if DRIFT or STALE (needs attention), 0 otherwise. *)

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

let check_drift () : unit =
  let deployed = deployed_path () in
  let canonical_exists, canonical_info =
    match file_info canonical with
    | Some info -> true, info
    | None -> false, (0, 0.0)
  in
  let deployed_info = file_info deployed in
  let deployed_is_symlink = match read_link deployed with Some _ -> true | None -> false in

  if not (Sys.file_exists deployed) then begin
    Printf.printf "MISSING: deployed plugin not found at %s\n" deployed;
    Printf.printf "  Run: cd /path/to/c2c && just install-all\n";
    exit 1
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
      exit 0
    end else begin
      Printf.printf "STALE: deployed plugin is a symlink but points to wrong target\n";
      Printf.printf "  deployed: %s -> %s\n" deployed target;
      Printf.printf "  expected: %s\n" canonical;
      exit 1
    end
  end else begin
    match deployed_info with
    | None ->
        Printf.printf "ERROR: could not stat deployed plugin at %s\n" deployed;
        exit 1
    | Some (d_size, d_mtime) ->
        if not canonical_exists then begin
          Printf.printf "UNKNOWN: canonical source not found at %s\n" canonical;
          Printf.printf "  deployed: size=%d mtime=%.0f\n" d_size d_mtime;
          exit 1
        end else begin
          let (c_size, c_mtime) = canonical_info in
          if d_size = c_size && abs_float (d_mtime -. c_mtime) < 1.0 then begin
            Printf.printf "OK: deployed plugin is in sync with canonical source\n";
            Printf.printf "  deployed:  %s (size=%d mtime=%.0f)\n" deployed d_size d_mtime;
            Printf.printf "  canonical: %s (size=%d mtime=%.0f)\n" canonical c_size c_mtime;
            exit 0
          end else begin
            Printf.printf "DRIFT: deployed plugin has diverged from canonical source\n";
            Printf.printf "  deployed:  %s (size=%d mtime=%.0f)\n" deployed d_size d_mtime;
            Printf.printf "  canonical: %s (size=%d mtime=%.0f)\n" canonical c_size c_mtime;
            Printf.printf "  Run: cd /path/to/c2c && just install-all\n";
            exit 1
          end
        end
  end

let opencode_plugin_drift_cmd =
  let open Cmdliner.Term in
  let doc = "Check if deployed OpenCode plugin has drifted from canonical source." in
  let info = Cmdliner.Cmd.info "opencode-plugin-drift" ~doc in
  let term = const (fun () -> check_drift ()) $ const () in
  Cmdliner.Cmd.v info term
