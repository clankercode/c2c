(* c2c_worktree.ml — git worktree management helpers for per-agent isolation. *)

let ( // ) = Filename.concat

(** [git_command args] runs `git <args>` and returns (exit_code, stdout, stderr).
    Uses Unix.open_process_in for stdout and ignores stderr (git worktree list
    only writes to stdout on success). This is the simplest safe approach. *)
let git_command args =
  let git_path = Git_helpers.find_real_git () in
  let argv = Array.of_list (git_path :: args) in
  let ic = Unix.open_process_args_in git_path argv in
  let buf_size = 4096 in
  let buf = Bytes.create buf_size in
  let rec drain acc =
    match input ic buf 0 buf_size with
    | 0 -> close_in ic; List.rev acc
    | n -> drain (Bytes.sub buf 0 n :: acc)
  in
  let stdout_data = drain [] |> Bytes.concat (Bytes.create 0) |> Bytes.to_string in
  let status = Unix.close_process_in ic in
  let code = match status with Unix.WEXITED n -> n | _ -> 127 in
  (code, stdout_data, "")

(** [worktrees_root ()] returns .c2c/worktrees/ under the git common dir.
    Uses git_common_dir_parent so it resolves to the main repo, not a worktree,
    ensuring all worktrees share the same registry regardless of where they're
    called from. *)
let worktrees_root () =
  match Git_helpers.git_common_dir_parent () with
  | Some parent -> parent // ".c2c" // "worktrees"
  | None -> failwith "not in a git repository"

(** [ensure_worktree ~alias ~branch] creates a worktree for [alias] if it doesn't
    exist, using [branch]. Uses `git worktree add --force` so it handles
    partially-created worktrees from crashes. Returns the worktree directory. *)
let ensure_worktree ~(alias : string) ~(branch : string) : string =
  let root = worktrees_root () in
  let wt_dir = root // alias in
  C2c_utils.mkdir_p root;
  if Sys.file_exists wt_dir then begin
    let (code, _, _) = git_command [ "worktree"; "list"; "--porcelain"; wt_dir ] in
    if code = 0 then wt_dir
    else begin
      ignore (git_command [ "worktree"; "remove"; "--force"; wt_dir ]);
      let (code2, _, _) = git_command [ "worktree"; "add"; "--force"; wt_dir; branch ] in
      if code2 <> 0 then Printf.eprintf "warning: worktree add failed for %s\n%!" alias;
      wt_dir
    end
  end else begin
    let (code, _, _) = git_command [ "worktree"; "add"; "--force"; wt_dir; branch ] in
    if code <> 0 then Printf.eprintf "warning: worktree add failed for %s\n%!" alias;
    wt_dir
  end

(** [list_worktrees ()] returns all worktrees as (alias, path, branch) triples.
    Parses `git worktree list --porcelain` output. *)
let list_worktrees () =
  let (_, output, _) = git_command [ "worktree"; "list"; "--porcelain" ] in
  let lines = String.split_on_char '\n' output in
  let worktree_prefix = "worktree " in
  let prefix_len = String.length worktree_prefix in
  let rec parse_block acc cur_alias cur_path cur_branch = function
    | [] -> (acc, cur_alias, cur_path, cur_branch)
    | "" :: rest ->
        let new_acc = match cur_path with
          | "" -> acc
          | _ -> (cur_alias, cur_path, cur_branch) :: acc
        in
        parse_block new_acc "" "" "" rest
    | line :: rest ->
        let trimmed = String.trim line in
        if trimmed = "" then parse_block acc cur_alias cur_path cur_branch rest
        else if String.length trimmed >= prefix_len && String.sub trimmed 0 prefix_len = worktree_prefix then
          let path = String.sub trimmed prefix_len (String.length trimmed - prefix_len) in
          let alias = Filename.basename path in
          parse_block acc alias path "" rest
        else if String.length trimmed >= 5 && String.sub trimmed 0 5 = "HEAD " then
          parse_block acc cur_alias cur_path cur_branch rest
        else if String.length trimmed >= 7 && String.sub trimmed 0 7 = "branch " then
          let b = String.sub trimmed 7 (String.length trimmed - 7) in
          parse_block acc cur_alias cur_path b rest
        else parse_block acc cur_alias cur_path cur_branch rest
  in
  let results, _, _, _ = parse_block [] "" "" "" lines in
  List.rev results

(** [prune_worktrees ()] removes stale worktree entries. *)
let prune_worktrees () =
  let (code, _, _) = git_command [ "worktree"; "prune" ] in
  code = 0
