(* c2c_doctor_cherry_pick_readiness.ml — `c2c doctor cherry-pick-readiness <SHA>`.

   Detects stale-base cherry-pick risk: when a slice SHA is based on an old
   master commit, cherry-picking onto current master risks --theirs data loss
   on files that have been heavily edited on master since the slice branched.

   Classification:
   - CLEAN: master is <20 commits ahead, OR no touched file has >100 new lines on master
   - HARD: master is >20 commits ahead AND a touched file has >100 new lines on master since merge-base

   Exit codes: 0 = CLEAN, 2 = HARD, 3 = CHAIN-WARN *)

open Cmdliner.Term.Syntax

let ( // ) = Filename.concat

type classification = [ `Clean | `Hard ]

let classification_to_string = function
  | `Clean -> "CLEAN"
  | `Hard -> "HARD-WARN"

let classification_exit_code = function
  | `Clean -> 0
  | `Hard -> 2

(** Pure chain-classification: [rev_list_shas] is the list of SHAs from
    [git rev-list <sha> ^origin/master ^master], newest first.
    Returns [`Ok] when the list has 0-1 entries (single commit or already
    on master), [`Chain_warn ancestors] when >1 (ancestors = all except
    the tip). *)
let classify_chain ~tip_sha ~rev_list_shas =
  let ancestors = List.filter (fun s -> s <> tip_sha) rev_list_shas in
  match ancestors with
  | [] -> `Ok
  | _ -> `Chain_warn ancestors

(* Run a git command, return stdout as list of lines on success, raise on failure *)
let git_run ~cwd cmd =
  let full = Printf.sprintf "git -C %s %s" (Filename.quote cwd) cmd in
  let ic = Unix.open_process_in full in
  Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic)) (fun () ->
    let rec read acc =
      try read ((input_line ic) :: acc)
      with End_of_file -> List.rev acc
    in
    read [])

(* Run a git command, return int on success (for --count commands) *)
let git_run_int ~cwd cmd =
  let lines = git_run ~cwd cmd in
  let s = String.concat "" lines |> String.trim in
  try int_of_string s with _ -> 0

(** Return the list of SHAs reachable from [sha] but NOT on
    [origin/master] or [master]. Includes [sha] itself if unlanded. *)
let chain_ancestors ~cwd sha =
  try
    let lines = git_run ~cwd
      (Printf.sprintf "rev-list %s ^origin/master ^master --" (Filename.quote sha))
    in
    List.map String.trim lines |> List.filter (fun s -> s <> "")
  with _ -> []

(* Classify a cherry-pick readiness check *)
let classify ~master_ahead ~risky_file_count =
  if master_ahead > 20 && risky_file_count > 0 then `Hard
  else `Clean

(* Format the output *)
let output_result ~sha ~merge_base ~master_ahead ~slice_ins ~slice_del
      ~risky_file_count ~classification =
  let open Printf in
  eprintf "=== cherry-pick-readiness: %s ===\n" sha;
  eprintf "  merge-base:      %s\n" merge_base;
  eprintf "  master ahead:    %d commit(s)\n" master_ahead;
  eprintf "  slice delta:     +%d / -%d lines\n" slice_ins slice_del;
  if risky_file_count = 0 then
    eprintf "  risky files:     none (>100 lines added on master since merge-base)\n"
  else
    eprintf "  risky files:     %d file(s) with >100 lines added on master — HARD-WARN\n"
      risky_file_count;
  eprintf "  classification:  %s\n" (classification_to_string classification);
  match classification with
  | `Clean -> eprintf "\n  ✓ CLEAN — cherry-pick is low-risk.\n"
  | `Hard -> eprintf "\n  🔴 HARD-WARN — high risk of --theirs data loss. Consider rebasing first.\n"

let output_chain_warning ~sha ~ancestors =
  let n = List.length ancestors in
  Printf.eprintf "\n  ⚠️  CHAIN-WARN — SHA %s has %d unlanded ancestor%s:\n" sha n (if n = 1 then "" else "s");
  Printf.eprintf "      %s\n" (String.concat " " ancestors);
  Printf.eprintf "      Cherry-picking the tip alone may break the build.\n";
  (* oldest ancestor is last in the list (rev-list is newest-first) *)
  let oldest = List.nth ancestors (n - 1) in
  Printf.eprintf "      Cherry-pick the full chain: git cherry-pick %s^..%s\n" oldest sha

let run_check sha_input =
  (* Find the repo toplevel *)
  let git_dir = match Git_helpers.git_repo_toplevel () with
    | None ->
        Printf.eprintf "error: must run from inside the c2c git repo.\n%!";
        exit 1
    | Some d -> d
  in

  (* 0. Resolve abbreviated SHA to full 40-char form so that
     classify_chain's string comparison works against rev-list output. *)
  let sha =
    try List.hd (git_run ~cwd:git_dir ("rev-parse " ^ Filename.quote sha_input)) |> String.trim
    with Failure _ ->
      Printf.eprintf "error: could not resolve SHA %s\n" sha_input;
      exit 1
  in

  (* 1. Resolve merge-base with master *)
  let merge_base =
    try List.hd (git_run ~cwd:git_dir ("merge-base master " ^ sha)) |> String.trim
    with Failure _ ->
      Printf.eprintf "error: could not resolve merge-base for SHA %s\n" sha;
      exit 1
  in

  (* 2. Count commits master is ahead of merge-base *)
  let master_ahead = git_run_int ~cwd:git_dir
    ("log --oneline " ^ merge_base ^ "..master | wc -l")
  in

  (* 3. Get slice diff stats: total insertions and deletions *)
  let diff_lines =
    try git_run ~cwd:git_dir ("diff " ^ sha ^ "~.." ^ sha ^ " --numstat")
    with Failure _ -> []
  in
  let slice_ins, slice_del =
    let ins_ref = ref 0 and del_ref = ref 0 in
    List.iter (fun line ->
      match String.split_on_char '\t' line with
      | [add; del; _filename] ->
          (try ins_ref := !ins_ref + int_of_string (String.trim add) with _ -> ());
          (try del_ref := !del_ref + int_of_string (String.trim del) with _ -> ())
      | _ -> ()
    ) diff_lines;
    (!ins_ref, !del_ref)
  in

  (* 4. Get files touched by the slice *)
  let slice_files =
    try git_run ~cwd:git_dir ("diff " ^ sha ^ "~.." ^ sha ^ " --name-only")
    with Failure _ -> []
  in

  (* 5. For each touched file, count lines added on master since merge-base.
     Risky = >100 lines added on master since merge-base. *)
  let risky_count =
    List.fold_left (fun acc file ->
      let added =
        try
          let out = String.concat "" (git_run ~cwd:git_dir
            ("log --oneline " ^ merge_base ^ "..master -- \"" ^ file ^ "\" --numstat | "
             ^ "awk 'NF==3 {s+=$1} END {print s+0}'"))
          in int_of_string (String.trim out)
        with _ -> 0
      in
      if added > 100 then acc + 1 else acc
    ) 0 slice_files
  in

  (* 6. Classify *)
  let classification = classify ~master_ahead ~risky_file_count:risky_count in

  (* 7. Output *)
  output_result ~sha ~merge_base ~master_ahead ~slice_ins ~slice_del
    ~risky_file_count:risky_count ~classification;

  (* 8. Chain-ancestor check *)
  let rev_list_shas = chain_ancestors ~cwd:git_dir sha in
  let chain_class = classify_chain ~tip_sha:sha ~rev_list_shas in
  (match chain_class with
   | `Ok -> ()
   | `Chain_warn ancestors ->
       output_chain_warning ~sha ~ancestors);

  (* Exit: HARD (2) takes precedence, then CHAIN (3), then CLEAN (0) *)
  let exit_code = match classification, chain_class with
    | `Hard, _ -> 2
    | _, `Chain_warn _ -> 3
    | `Clean, `Ok -> 0
  in
  exit exit_code

let sha_term =
  let open Cmdliner in
  let doc = "SHA of the commit to check cherry-pick readiness for." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"SHA" ~doc)

let main_term sha = run_check sha

let cmd_term =
  let open Cmdliner.Term in
  const (fun sha -> ignore (run_check sha)) $ sha_term

let doc = "Check if a SHA's branch is safe to cherry-pick onto current master \
           (detects stale-base --theirs data-loss risk and multi-commit chain \
           dependencies)."

let c2c_doctor_cherry_pick_readiness_cmd =
  Cmdliner.Cmd.v (Cmdliner.Cmd.info "cherry-pick-readiness" ~doc) cmd_term
