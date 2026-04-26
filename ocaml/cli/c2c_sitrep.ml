(* c2c_sitrep.ml — sitrep tooling subcommands

   Currently provides:
   - `c2c sitrep commit` — stage + commit the current local-hour sitrep
     file at <repo-root>/.sitreps/YYYY/MM/DD/HH.md with a sensible default
     message; idempotent if there's nothing to commit. *)

open Cmdliner.Term.Syntax

let ( // ) = Filename.concat

(** Sitrep paths use LOCAL time, matching the existing convention in this
    repo (sitreps are filed under the local hour the coordinator writes
    them, e.g. "10:00 UTC+10" lives at .sitreps/.../10.md). *)
let utc_now_path ~repo_root =
  let t = Unix.localtime (Unix.gettimeofday ()) in
  let year  = 1900 + t.Unix.tm_year in
  let month = 1 + t.Unix.tm_mon in
  let day   = t.Unix.tm_mday in
  let hour  = t.Unix.tm_hour in
  let rel = Printf.sprintf ".sitreps/%04d/%02d/%02d/%02d.md" year month day hour in
  let abs = repo_root // rel in
  (rel, abs, year, month, day, hour)

(** Local timezone label like "UTC+10" / "UTC-5" / "UTC". *)
let local_tz_label () =
  let now = Unix.gettimeofday () in
  let local = Unix.localtime now in
  let utc = Unix.gmtime now in
  let to_secs (t : Unix.tm) =
    t.tm_yday * 86400 + t.tm_hour * 3600 + t.tm_min * 60 + t.tm_sec
  in
  let local_secs = to_secs local in
  let utc_secs = to_secs utc in
  (* Wrap-around correction: if local and utc fall on different yday,
     the naive subtraction can overshoot ±43200; clamp into ±12h. *)
  let raw = local_secs - utc_secs in
  let raw =
    if raw >  43200 then raw - 86400
    else if raw < -43200 then raw + 86400
    else raw
  in
  let hours = raw / 3600 in
  if hours = 0 then "UTC"
  else Printf.sprintf "UTC%+d" hours

let resolve_repo_root () =
  match Git_helpers.git_repo_toplevel () with
  | Some r -> r
  | None ->
      Printf.eprintf "error: not in a git repository (cannot resolve repo root)\n%!";
      exit 1

(** Run a git subcommand silently in [cwd]. Returns rc + captured stderr. *)
let git_run ~cwd args =
  let git = "git" in
  let argv = Array.of_list (git :: args) in
  let cmd = String.concat " " (List.map Filename.quote (git :: args)) in
  let cmd = Printf.sprintf "cd %s && %s" (Filename.quote cwd) cmd in
  let _ = argv in
  let ic = Unix.open_process_in (cmd ^ " 2>&1") in
  let buf = Buffer.create 256 in
  (try
     while true do
       Buffer.add_string buf (input_line ic);
       Buffer.add_char buf '\n'
     done
   with End_of_file -> ());
  let status = Unix.close_process_in ic in
  let rc = match status with
    | Unix.WEXITED n -> n
    | _ -> 1
  in
  (rc, Buffer.contents buf)

(** Returns true if there's anything (staged or unstaged) for [path] under
    [repo_root]. *)
let has_changes ~repo_root ~path =
  let rc, out = git_run ~cwd:repo_root [ "status"; "--porcelain"; "--"; path ] in
  rc = 0 && String.trim out <> ""

let run_commit ~message =
  let repo_root = resolve_repo_root () in
  let (rel, abs, _year, _month, _day, hour) = utc_now_path ~repo_root in
  if not (Sys.file_exists abs) then begin
    Printf.printf "no sitrep at %s (local hour %02d, %s) — nothing to commit\n%!"
      rel hour (local_tz_label ());
    exit 0
  end;
  if not (has_changes ~repo_root ~path:rel) then begin
    Printf.printf "%s has no staged or unstaged changes — nothing to commit\n%!" rel;
    exit 0
  end;
  let rc, out = git_run ~cwd:repo_root [ "add"; "--"; rel ] in
  if rc <> 0 then begin
    Printf.eprintf "error: git add failed (rc=%d):\n%s%!" rc out;
    exit 1
  end;
  let msg = match message with
    | Some m -> m
    | None -> Printf.sprintf "sitrep: %02d:00 %s — auto-commit" hour (local_tz_label ())
  in
  let rc, out = git_run ~cwd:repo_root [ "commit"; "-m"; msg; "--"; rel ] in
  if rc <> 0 then begin
    Printf.eprintf "error: git commit failed (rc=%d):\n%s%!" rc out;
    exit 1
  end;
  print_string out;
  Printf.printf "committed %s with message: %s\n%!" rel msg

(* --- cmdliner wiring ------------------------------------------------------- *)

let sitrep_commit_cmd =
  let message_flag =
    Cmdliner.Arg.(value & opt (some string) None & info [ "message"; "m" ] ~docv:"MSG"
      ~doc:"Override the default commit message.")
  in
  let+ message = message_flag in
  run_commit ~message

let sitrep_group =
  Cmdliner.Cmd.group
    ~default:sitrep_commit_cmd
    (Cmdliner.Cmd.info "sitrep" ~doc:"Sitrep helper commands.")
    [ Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "commit"
           ~doc:"Stage and commit the current local-hour sitrep file \
                 (.sitreps/YYYY/MM/DD/HH.md, where HH is local time). \
                 No-op if the file does not exist or has no changes.")
        sitrep_commit_cmd ]
