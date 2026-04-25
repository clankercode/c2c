open Cmdliner.Term.Syntax

(** Coordinator utilities — cherry-pick with dirty-tree safety.

    AC:
    1. Multi-SHA cherry-pick (sequential)
    2. Pre-flight git status: if dirty, auto-stash (only working-tree dirty, not staged)
    3. On conflict: abort + report blocking SHA + restore stash + exit non-zero
    4. On success: pop stash; if pop conflicts, leave stash + warn
    5. Run just install-all and report build success/failure
    6. Tier-2 utility, coordinator-only (check C2C_COORDINATOR env or require explicit flag)
*)

(** ISO8601 UTC timestamp for stash messages. *)
let ts () =
  let t = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d%02d%02dT%02d%02d%02d"
    (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1) t.Unix.tm_mday
    t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec

(** Run a shell command, return int exit code. *)
let run cmd = Sys.command cmd

(** Run a command and capture its stdout as a string. *)
let run_capture cmd =
  let ic = Unix.open_process_in cmd in
  Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
    (fun () ->
       let rec loop acc =
         try loop (input_line ic :: acc)
         with End_of_file -> String.concat "\n" (List.rev acc)
       in
       loop [])

(** Check git status --porcelain in a repo.
    Returns (is_clean, is_working_dirty, lines). *)
let git_status repo =
  let cmd = Printf.sprintf "git -C %s status --porcelain" (Filename.quote repo) in
  let out = run_capture cmd in
  let lines =
    out |> String.split_on_char '\n'
    |> List.filter (fun l -> String.length l > 0)
  in
  if lines = [] then (true, false, []) else
    let working_dirty =
      List.exists
        (fun l ->
           String.length l >= 2
           && l.[0] = ' '
           && List.mem l.[1] ['M'; 'A'; 'D'; 'R'; 'C'])
        lines
    in
    (false, working_dirty, lines)

(** Returns true if the status line indicates a conflict marker. *)
let is_conflict_line (l : string) : bool =
  (String.length l >= 2 &&
   (String.sub l 0 2 = "UU" ||
    String.sub l 0 2 = "AA" ||
    String.sub l 0 2 = "DD"))

let git_stash_push repo msg =
  let cmd = Printf.sprintf "git -C %s stash push -u -m %s"
    (Filename.quote repo) (Filename.quote msg)
  in
  run cmd = 0

let git_stash_pop repo =
  let cmd = Printf.sprintf "git -C %s stash pop" (Filename.quote repo) in
  match run cmd with
  | 0 -> `Success
  | _ -> `Conflict

let git_cherry_pick repo sha =
  let cmd = Printf.sprintf "git -C %s cherry-pick %s"
    (Filename.quote repo) (Filename.quote sha)
  in
  let rc = run cmd in
  if rc = 0 then `Ok else
    let _, _, lines = git_status repo in
    if List.exists is_conflict_line lines then `Conflict else `Error

let git_abort repo =
  ignore (run (Printf.sprintf "git -C %s cherry-pick --abort" (Filename.quote repo)))

(** The main run logic. Calls exit() directly on error. *)
let run_coord_cherry_pick ~no_install ~shas =
  match Sys.getenv_opt "C2C_COORDINATOR" with
  | None | Some "" ->
      Printf.eprintf "error: C2C_COORDINATOR=1 required\n%!";
      exit 1
  | Some v ->
      if v <> "1" then (
        Printf.eprintf "error: C2C_COORDINATOR=1 required (got %s)\n%!" v;
        exit 1
      ) else begin
        let repo = match Sys.getenv_opt "C2C_REPO_ROOT" with
          | Some r -> r
          | None -> Sys.getcwd ()
        in
        Printf.printf "[coord-cherry-pick] repo=%s\n%!" repo;
        Printf.printf "[coord-cherry-pick] will cherry-pick: %s\n%!"
          (String.concat ", " shas);

        let is_clean, working_dirty, _status_lines = git_status repo in
        let stash_msg = Printf.sprintf "coord-cherry-pick-wip-%s" (ts ()) in
        let stashed = ref false in

        if not is_clean then begin
          if working_dirty then begin
            Printf.printf "[coord-cherry-pick] working tree dirty — stashing: %s\n%!" stash_msg;
            if git_stash_push repo stash_msg then begin
              stashed := true;
              Printf.printf "[coord-cherry-pick] stash created\n%!"
            end else begin
              Printf.eprintf "[coord-cherry-pick] ERROR: failed to stash dirty working tree\n%!";
              exit 1
            end
          end else
            Printf.printf "[coord-cherry-pick] staged changes present but working tree clean — proceeding\n%!"
        end;

        let blocked_sha = ref None in
        let success = List.for_all (fun sha ->
          Printf.printf "[coord-cherry-pick] cherry-picking %s...\n%!" sha;
          match git_cherry_pick repo sha with
          | `Ok ->
              Printf.printf "[coord-cherry-pick] %s applied ✓\n%!" sha;
              true
          | `Conflict ->
              Printf.eprintf "[coord-cherry-pick] FAILED on %s: conflict\n%!" sha;
              Printf.eprintf "[coord-cherry-pick] aborting cherry-pick...\n%!";
              git_abort repo;
              Printf.printf "[coord-cherry-pick] cherry-pick aborted\n%!";
              blocked_sha := Some sha;
              false
          | `Error ->
              Printf.eprintf "[coord-cherry-pick] FAILED on %s: unknown error\n%!" sha;
              Printf.eprintf "[coord-cherry-pick] aborting cherry-pick...\n%!";
              git_abort repo;
              Printf.printf "[coord-cherry-pick] cherry-pick aborted\n%!";
              blocked_sha := Some sha;
              false
        ) shas in

        if not success then begin
          if !stashed then begin
            Printf.printf "[coord-cherry-pick] restoring stash...\n%!";
            match git_stash_pop repo with
            | `Conflict ->
                Printf.eprintf "[coord-cherry-pick] WARNING: stash pop conflicted — stash left on stack\n%!"
            | `Success ->
                Printf.printf "[coord-cherry-pick] stash restored\n%!"
          end;
          match !blocked_sha with
          | Some sha -> Printf.eprintf "[coord-cherry-pick] BLOCKED at SHA: %s\n%!" sha; exit 1
          | None -> exit 1
        end else begin
          if !stashed then begin
            Printf.printf "[coord-cherry-pick] cherry-picks succeeded — popping stash...\n%!";
            match git_stash_pop repo with
            | `Conflict ->
                Printf.eprintf "[coord-cherry-pick] WARNING: stash pop conflicted — stash left on stack\n%!"
            | `Success ->
                Printf.printf "[coord-cherry-pick] stash restored ✓\n%!"
          end;

          if not no_install then begin
            Printf.printf "[coord-cherry-pick] running just install-all...\n%!";
            let rc = run (Printf.sprintf "cd %s && just install-all" (Filename.quote repo)) in
            if rc <> 0 then begin
              Printf.eprintf "[coord-cherry-pick] just install-all FAILED (exit %d)\n%!" rc;
              exit 1
            end else
              Printf.printf "[coord-cherry-pick] just install-all succeeded ✓\n%!"
          end;

          Printf.printf "[coord-cherry-pick] done\n%!"
        end
      end

let no_install_flag =
  Cmdliner.Arg.(value & flag & info [ "no-install" ]
    ~doc:"Skip just install-all after cherry-pick")

let sha_term =
  Cmdliner.Arg.(non_empty & pos_all string [] & info [] ~docv:"SHA" ~doc:"SHA(s) to cherry-pick")

let coord_cherry_pick_term =
  let+ no_install = no_install_flag
  and+ shas = sha_term in
  run_coord_cherry_pick ~no_install ~shas

let doc = "Coordinator helper: cherry-pick SHAs with dirty-tree safety + install."

let man = [
  `S "DESCRIPTION";
  `P "Cherry-pick one or more SHAs with automatic stash of dirty working tree.";
  `P "On conflict, aborts the cherry-pick sequence and restores the stash.";
  `P "Requires C2C_COORDINATOR=1 environment variable.";
]

let coord_cherry_pick_cmd =
  Cmdliner.Cmd.v (Cmdliner.Cmd.info "coord-cherry-pick" ~doc ~man) coord_cherry_pick_term
