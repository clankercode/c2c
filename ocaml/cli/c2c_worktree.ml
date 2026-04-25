(* c2c_worktree.ml — git worktree management helpers for per-agent isolation. *)

open Cmdliner.Term.Syntax

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

(** [current_branch ()] returns the current git branch name, or None if detached/unavailable. *)
let current_branch () =
  let (code, output, _) = git_command [ "rev-parse"; "--abbrev-ref"; "HEAD" ] in
  if code = 0 then
    let b = String.trim output in
    if b = "" || b = "HEAD" then None else Some b
  else None

(** [is_worktree_dir ~path] returns true if [path] is a registered git worktree
    by checking git worktree list output for that path. *)
let is_worktree_dir ~(path : string) : bool =
  let (_, output, _) = git_command [ "worktree"; "list"; "--porcelain" ] in
  let lines = String.split_on_char '\n' output in
  let prefix = "worktree " in
  let pfx_len = String.length prefix in
  List.exists (fun line ->
    let trimmed = String.trim line in
    String.length trimmed >= pfx_len &&
    String.sub trimmed 0 pfx_len = prefix &&
    (let wt_path = String.sub trimmed pfx_len (String.length trimmed - pfx_len) in
     wt_path = path)
  ) lines

(** [ensure_worktree ~alias ~branch] creates a worktree for [alias] if it doesn't
    exist, using [branch]. Uses `git worktree add --force` so it handles
    partially-created worktrees from crashes. Returns the worktree directory. *)
let ensure_worktree ~(alias : string) ~(branch : string) : string =
  let root = worktrees_root () in
  let wt_dir = root // alias in
  C2c_utils.mkdir_p root;
  if Sys.file_exists wt_dir && is_worktree_dir ~path:wt_dir then wt_dir
  else begin
    if Sys.file_exists wt_dir then begin
      ignore (git_command [ "worktree"; "remove"; "--force"; wt_dir ]);
    end;
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

(** [auto_alias ()] returns the alias from C2C_MCP_AUTO_REGISTER_ALIAS env var,
    falling back to the hostname. *)
let auto_alias () =
  match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
  | Some alias when alias <> "" -> alias
  | _ ->
      let hostname = try Unix.gethostname () with _ -> "unknown" in
      hostname

(** [current_worktree_alias ()] returns the alias of the current worktree if we're
    in one, None otherwise. *)
let current_worktree_alias () =
  let wt_root = worktrees_root () in
  let rec aux cur =
    if cur = Filename.dirname cur || cur = "/" then None
    else if String.length cur >= String.length wt_root &&
            String.sub cur 0 (String.length wt_root) = wt_root then
      Some (Filename.basename cur)
    else aux (Filename.dirname cur)
  in
  try aux (Sys.getcwd ()) with _ -> None

(** [setup_worktree ~alias] creates a new worktree for [alias].
    Creates branch [agent/<alias>] off origin/master if it doesn't exist.
    Returns the worktree directory path and exit code. *)
let setup_worktree ~(alias : string) : (string * int) =
  let branch = "agent/" ^ alias in
  let wt_dir = worktrees_root () // alias in
  let (_code_fetch, _, _) = git_command [ "fetch"; "origin"; "master" ] in
  let (code_add, _, _stderr) = git_command [ "worktree"; "add"; "--force"; wt_dir; branch ] in
  if code_add = 0 then (wt_dir, 0)
  else (wt_dir, if Sys.file_exists wt_dir then 0 else 1)

(** [worktree_status ()] prints status of current worktree (or all worktrees). *)
let worktree_status () =
  let alias = current_worktree_alias () in
  match alias with
  | Some a ->
      Printf.printf "Current worktree: %s\n" a;
      Printf.printf "Worktree path:   %s\n" (worktrees_root () // a);
      Printf.printf "Branch:         agent/%s\n" a
  | None ->
      let all = list_worktrees () in
      if all = [] then Printf.printf "No worktrees found.\n"
      else begin
        Printf.printf "Worktrees:\n";
        List.iter (fun (a, path, branch) ->
          let current = if String.length path >= String.length (Sys.getcwd ()) &&
                           String.sub path 0 (String.length (Sys.getcwd ())) = Sys.getcwd () then " (current)" else "" in
          Printf.printf "  %s%s — %s\n" a current branch
        ) all
      end

(* --- CLI ----------------------------------------------------------- *)

let worktree_setup_term =
  let alias_opt =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS" ~doc:"Agent alias for this worktree.")
  in
  let+ alias_val = alias_opt in
  let alias = match alias_val with
    | Some a -> a
    | None -> auto_alias ()
  in
  let (wt_dir, exit_code) = setup_worktree ~alias in
  if exit_code = 0 then
    Printf.printf "Worktree created: %s\nBranch: agent/%s\nTo enter: cd %s\n" wt_dir alias wt_dir
  else
    Printf.eprintf "Worktree may exist: %s\n" wt_dir

let worktree_status_term =
  let+ () = Cmdliner.Term.const () in
  worktree_status ()

let worktree_list_term =
  let+ () = Cmdliner.Term.const () in
  let worktrees = list_worktrees () in
  match worktrees with
  | [] -> Printf.printf "  (no worktrees)\n"
  | items ->
      List.iter (fun (a, path, branch) ->
        let current = if String.length path >= String.length (Sys.getcwd ()) &&
                         String.sub path 0 (String.length (Sys.getcwd ())) = Sys.getcwd () then " (current)" else "" in
        Printf.printf "  %s%s — %s\n" a current branch
      ) items

let worktree_prune_term =
  let+ () = Cmdliner.Term.const () in
  if prune_worktrees () then
    Printf.printf "worktree prune: done\n"
  else
    Printf.eprintf "worktree prune: failed\n%!"

let worktree_group =
  Cmdliner.Cmd.group
    ~default:worktree_list_term
    (Cmdliner.Cmd.info "worktree" ~doc:"Manage per-agent git worktrees.")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List all worktrees.") worktree_list_term
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "prune" ~doc:"Remove stale worktree entries.") worktree_prune_term
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "setup" ~doc:"Create an isolated git worktree for this agent.") worktree_setup_term
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "status" ~doc:"Show current worktree state.") worktree_status_term ]