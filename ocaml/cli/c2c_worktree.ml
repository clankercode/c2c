(* c2c_worktree.ml — git worktree management helpers for per-agent isolation. *)

let ( // ) = Filename.concat

(** [git_command args] runs `git <args>` and returns (exit_code, stdout, stderr).
    Uses a pipe + subprocess to avoid deadlocks from full pipe buffers. *)
let git_command args =
  let git_path = Git_helpers.find_real_git () in
  let (cin_read, cin_write) = Unix.pipe () in
  let (cout_read, cout_write) = Unix.pipe () in
  let (cerr_read, cerr_write) = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
      (* child *)
      Unix.close cin_write; Unix.close cout_read; Unix.close cerr_read;
      Unix.dup2 cin_read Unix.stdin;
      Unix.dup2 cout_write Unix.stdout;
      Unix.dup2 cerr_write Unix.stderr;
      Unix.close cin_read; Unix.close cout_write; Unix.close cerr_write;
      let argv = Array.of_list (git_path :: args) in
      Unix.execvp git_path argv
  | pid ->
      (* parent *)
      Unix.close cin_read; Unix.close cout_write; Unix.close cerr_write;
      let buf_size = 4096 in
      let buf = Bytes.create buf_size in
      let rec read_all fd acc =
        match Unix.read fd buf 0 buf_size with
        | 0 -> acc
        | n -> read_all fd (Bytes.sub buf 0 n :: acc)
      in
      let stdout_data = read_all cout_read [] |> List.rev |> Bytes.concat (Bytes.create 0) |> Bytes.to_string in
      let stderr_data = read_all cerr_read [] |> List.rev |> Bytes.concat (Bytes.create 0) |> Bytes.to_string in
      Unix.close cin_write; Unix.close cout_read; Unix.close cerr_read;
      let _, status = Unix.waitpid [] pid in
      let code = match status with Unix.WEXITED n -> n | _ -> 127 in
      (code, stdout_data, stderr_data)

(** [worktrees_root ()] returns .c2c/worktrees/ under the repo root. *)
let worktrees_root () =
  match Git_helpers.git_repo_toplevel () with
  | Some repo_root -> repo_root // ".c2c" // "worktrees"
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
  let rec aux acc cur_alias cur_path cur_branch =
    match lines with
    | [] -> acc
    | line :: rest ->
      let trimmed = String.trim line in
      if trimmed = "" then aux acc cur_alias cur_path cur_branch
      else if trimmed.[0] <> ' ' then
        let path = trimmed in
        let alias = Filename.basename path in
        aux ((alias, path, "") :: acc) alias path ""
      else
        let cont = String.trim trimmed in
        if String.length cont >= 8 && String.sub cont 0 8 = "branch: " then
          let b = String.sub cont 8 (String.length cont - 8) in
          aux acc cur_alias cur_path b
        else aux acc cur_alias cur_path cur_branch
  in
  let results = aux [] "" "" "" in
  List.rev results

(** [prune_worktrees ()] removes stale worktree entries. *)
let prune_worktrees () =
  let (code, _, _) = git_command [ "worktree"; "prune" ] in
  code = 0
