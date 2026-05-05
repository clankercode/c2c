(* c2c_worktree.ml — git worktree management helpers for per-agent isolation. *)

open Cmdliner.Term.Syntax

let ( // ) = Filename.concat

let mkdir_p = C2c_mcp.mkdir_p

let resolve_broker_root () = C2c_repo_fp.resolve_broker_root ()

(* ---- Email-to-alias resolution (also in c2c_coord.ml; kept here so
    c2c_worktree.ml is self-contained for the CLI tier) ---------------- *)

(** Map a git author email to a c2c broker alias.
    Resolution order:
      1. Built-in table (current swarm members)
      2. None → "unknown" (caller handles gracefully) *)
let email_to_alias_map =
  [ "stanza-coder@c2c.im",         "stanza-coder"
  ; "jungle-coder@c2c.im",         "jungle-coder"
  ; "coordinator1@c2c.im",          "coordinator1"
  ; "m@xk.io",                     "Max"
  ; "galaxy-coder@c2c.im",         "galaxy-coder"
  ; "slate-coder@c2c.im",          "slate-coder"
  ; "test-agent@c2c.im",           "test-agent"
  ; "test-agent-oc@c2c.im",        "test-agent-oc"
  ; "tundra-coder@c2c.im",         "tundra-coder"
  ; "storm-beacon@c2c.im",         "storm-beacon"
  ; "storm-ember@c2c.im",          "storm-ember"
  ; "lyra-quill@c2c.im",           "lyra-quill"
  ; "cedar-coder@c2c.im",          "cedar-coder"
  ; "fern-coder@c2c.im",           "fern-coder"
  ; "birch-coder@c2c.im",          "birch-coder"
  ; "willow-coder@c2c.im",         "willow-coder"
  ; "c2c@c2c.im",                  "c2c"
  ]

let email_to_alias_opt email =
  let lo = String.lowercase_ascii email in
  List.assoc_opt lo email_to_alias_map

(** [git_command ?cwd ?(quiet=false) args] runs `git <args>` in [cwd] (default: current dir)
    and returns (exit_code, stdout, stderr).
    Uses `sh -c` to change directory and optionally suppress stderr.
    [git_path] defaults to Git_helpers.find_real_git (). *)
let git_command ?(cwd=".") ?(quiet=false) ?(git_path=None) args =
  let git_exec = match git_path with
    | Some p -> p
    | None -> Git_helpers.find_real_git ()
  in
  let git_argv = String.concat " " (List.map Filename.quote args) in
  let redirect = if quiet then " 2>/dev/null" else "" in
  let sh_cmd = if cwd = "." || cwd = "" then
    Printf.sprintf "%s %s%s" git_exec git_argv redirect
  else
    Printf.sprintf "cd %s && %s %s%s" (Filename.quote cwd) git_exec git_argv redirect
  in
  let ic = Unix.open_process_args_in "/bin/sh" [| "/bin/sh"; "-c"; sh_cmd |] in
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
  mkdir_p root;
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

(** [worktrees_dir ()] returns .worktrees/ under the main repo root.
    Uses git_common_dir_parent to always resolve to the main repo, not a
    worktree subdirectory. This ensures all worktrees land at the repo root
    regardless of where the command is invoked from. *)
let worktrees_dir () =
  match Git_helpers.git_common_dir_parent () with
  | Some parent -> parent // ".worktrees"
  | None -> failwith "not in a git repository"

(** [is_valid_slice_name s] returns true if [s] is safe to use in a worktree path.
    Uses [a-zA-Z0-9_-] only — no slash, no spaces, no special chars. *)
let is_valid_slice_name (s : string) : bool =
  String.length s > 0 &&
  let valid_chars = Str.regexp "^[a-zA-Z0-9_-]+$" in
  try Str.string_match valid_chars s 0 && Str.match_end () = String.length s
  with Not_found -> false

(** [is_valid_branch_name s] returns true if [s] is a valid git branch name.
    Allows alphanumerics, hyphens, underscores, and forward slashes (for
    hierarchical branch names like fix/my-slice). *)
let is_valid_branch_name (s : string) : bool =
  String.length s > 0 &&
  let valid_chars = Str.regexp "^[a-zA-Z0-9_/-]+$" in
  try Str.string_match valid_chars s 0 && Str.match_end () = String.length s
  with Not_found -> false

let stale_origin_warning ~local_master_ahead =
  if local_master_ahead <= 0 then None
  else
    Some
      (Printf.sprintf
         "warning: origin/master is %d commit(s) behind local master; this worktree will still branch from origin/master, but coordinator cherry-pick conflicts are more likely."
         local_master_ahead)

let local_master_ahead_of_origin () =
  let (code, stdout, _) = git_command [ "rev-list"; "--count"; "origin/master..master" ] in
  if code <> 0 then None else int_of_string_opt (String.trim stdout)

let local_master_behind_origin () =
  let (code, stdout, _) = git_command [ "rev-list"; "--count"; "master..origin/master" ] in
  if code <> 0 then None else int_of_string_opt (String.trim stdout)

let stale_local_master_warning ~local_master_behind =
  if local_master_behind <= 0 then None
  else
    Some
      (Printf.sprintf
         "warning: local master is %d commit(s) behind origin/master — run `git fetch origin && git merge --ff-only origin/master` to sync before manually branching. `c2c worktree start` still branches from origin/master correctly, but agents using `git checkout -b branch master` will get a stale base."
         local_master_behind)

(** [worktree_behind_origin ~wt_path] checks if the worktree at [wt_path]
    is 5 or more commits behind origin/master.
    Returns a warning message if so, None otherwise. *)
let worktree_behind_origin ~(wt_path:string) : string option =
  let threshold = 5 in
  let (_code_fetch, _, _) = git_command ~cwd:wt_path ~quiet:true
    [ "fetch"; "origin"; "master" ] in
  let (code, stdout, _) = git_command ~cwd:wt_path
    [ "rev-list"; "--count"; "HEAD..origin/master" ] in
  if code <> 0 then None
  else
    match int_of_string_opt (String.trim stdout) with
    | Some n when n >= threshold ->
        Some (Printf.sprintf
          "WARN: worktree '%s' is %d commit(s) behind origin/master — rebase recommended to avoid cherry-pick conflicts"
          (Filename.basename wt_path) n)
    | Some _ -> None
    | None -> None

(** [check_all_worktree_bases ()] checks all worktrees for base staleness. *)
let check_all_worktree_bases () =
  let all = list_worktrees () in
  let has_warnings = ref false in
  List.iter (fun (_alias, wt_path, _branch) ->
    match worktree_behind_origin ~wt_path with
    | Some msg ->
        has_warnings := true;
        Printf.eprintf "%s\n%!" msg
    | None -> ()
  ) all;
  !has_warnings

(** [start_worktree ~slice_name ~branch_name] creates an isolated worktree for a slice.
    Creates branch [branch_name] off origin/master, places worktree at .worktrees/<slice_name>.
    Returns the worktree path on success, raises on failure. *)
let start_worktree ~(slice_name : string) ~(branch_name : string) : string =
  let wt_dir = worktrees_dir () // slice_name in
  (* Ensure parent exists *)
  let parent = Filename.dirname wt_dir in
  mkdir_p parent;
  (* Check for existing worktree at this path *)
  if is_worktree_dir ~path:wt_dir then
    raise (Failure ("worktree already exists: " ^ wt_dir));
  if Sys.file_exists wt_dir then
    raise (Failure ("path already exists and is not a worktree: " ^ wt_dir));
  (* Fetch origin/master to ensure we have it *)
  let (_code_fetch, _, _) = git_command [ "fetch"; "origin"; "master" ] in
  (match local_master_ahead_of_origin () with
   | Some count ->
       (match stale_origin_warning ~local_master_ahead:count with
        | Some msg -> Printf.eprintf "%s\n%!" msg
        | None -> ())
   | None -> ());
  (match local_master_behind_origin () with
   | Some count ->
       (match stale_local_master_warning ~local_master_behind:count with
        | Some msg -> Printf.eprintf "%s\n%!" msg
        | None -> ())
   | None -> ());
  (* Create worktree with new branch from origin/master *)
  let (code, _stdout, stderr) = git_command [ "worktree"; "add"; "--force"; "-b"; branch_name; wt_dir; "origin/master" ] in
  if code <> 0 then
    raise (Failure ("git worktree add failed (exit " ^ string_of_int code ^ "): " ^ stderr));
  wt_dir

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

let worktree_start_term =
  let slice_term =
    let doc = "Slice name — used for both the worktree directory (.worktrees/<slice>) and branch (fix/<slice>)." in
    Cmdliner.Arg.(required & pos ~rev:true 0 (some string) None & info [] ~docv:"SLICE" ~doc)
  in
  let branch_overrides =
    let doc = "Override the branch name. Default is fix/<slice>." in
    Cmdliner.Arg.(value & opt (some string) None & info [ "branch" ] ~docv:"BRANCH" ~doc)
  in
  let+ slice_name = slice_term
  and+ branch_override = branch_overrides in
  let branch_name = match branch_override with
    | Some b -> b
    | None -> "fix/" ^ slice_name
  in
  if not (is_valid_slice_name slice_name) then
    Printf.eprintf "error: slice name must be alphanumeric, hyphens, and underscores only.\n%!"
  else if not (is_valid_branch_name branch_name) then
    Printf.eprintf "error: branch name must be alphanumeric, hyphens, underscores, and forward slashes only.\n%!"
  else
    match start_worktree ~slice_name ~branch_name with
    | wt_dir ->
        Printf.printf "Worktree created: %s\n" wt_dir;
        Printf.printf "Branch: %s\n" branch_name;
        Printf.printf "To enter: cd %s\n" wt_dir;
        Printf.printf "To enter (eval): eval $(c2c worktree start %s)\n" slice_name
    | exception Failure msg ->
        Printf.eprintf "error: %s\n%!" msg

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

let worktree_check_bases_term =
  let+ () = Cmdliner.Term.const () in
  ignore (check_all_worktree_bases ())

(* --- subcommand: worktree gc (#313) --------------------------------------
   Detect candidate worktrees safe to remove and (with --clean) delete them.
   Refuses to touch:
     - dirty working trees
     - branches/HEADs not yet ancestors of origin/master
     - worktrees with a live process holding cwd inside (override
       --ignore-active for stale-PID cases)
     - the main worktree itself (defense-in-depth: even if list_worktrees
       returns it, it's filtered out)

    The "ancestor of origin/master" boundary is the deliberately stricter
    choice — local master may have unpushed cherry-picks, but origin is
    the provably-reproducible baseline. Implication: worktrees won't GC
    until after a push lands their branch on origin/master. *)

(** [is_meta_only_path path] returns true if [path] (a file or directory
    within a worktree) is a "meta" path — sitrep, collab doc, personal
    log, or common build-artifact path — rather than real code. These paths
    are excluded from the "real code blocking GC" check (both for commit-level
    meta-filter and for the dirty-tree meta-ignorance feature). *)
let is_meta_only_path (path : string) : bool =
  (* Prefix-based patterns (dirs) *)
  List.exists (fun prefix ->
    String.length path >= String.length prefix
    && String.sub path 0 (String.length prefix) = prefix)
    [ ".sitreps/"
    ; ".collab/updates/"
    ; ".collab/design/"
    ; ".c2c/personal-logs/"
    ; ".c2c/memory/"
    ; "volumes/"      (* Docker/compose volumes *)
    ; "_build/"       (* Dune build output *) ]
  || (String.length path >= 4 && String.sub path 0 4 = ".git")
  (* Suffix-based patterns (common artifact file types) *)
  || (List.exists (fun suffix ->
         let len = String.length suffix in
         String.length path >= len
         && String.sub path (String.length path - len) len = suffix)
        [ ".log"; ".lock"; ".bak" ])

(** [commit_touches_noncode_paths ~cwd sha] returns true if commit [sha]
    only touches meta paths (sitreps, collab docs, personal logs, .git).
    Uses `git diff-tree --no-commit-id --name-only -r` to list paths.
    Returns false if any path is real code. *)
let commit_touches_noncode_paths ~(cwd : string) (sha : string) : bool =
  let (code, out, _) =
    git_command ~cwd ~quiet:true
      [ "diff-tree"; "--no-commit-id"; "--name-only"; "-r"; sha ]
  in
  if code <> 0 then false
  else
    let paths = String.split_on_char '\n' (String.trim out) in
    List.for_all is_meta_only_path paths

(** [is_dirty ?strict path] returns true if the worktree at [path] has
    uncommitted changes.

    When [strict] is false (default), meta-only and artifact paths
    (.sitreps/, .collab/, volumes/, _build/, *.log, *.lock, *.bak, etc.)
    are filtered from the dirty check — a worktree whose only dirty files
    are these meta/artifact paths is considered NOT dirty.

    When [strict] is true, any git status output means dirty (the original
    behaviour, restored via the --strict-dirty flag). *)
let is_dirty ?(strict : bool = false) path =
  let (_, out, _) = git_command ~cwd:path ~quiet:true [ "status"; "--porcelain" ] in
  let out = String.trim out in
  if out = "" then false
  else if strict then true
  else
    (* Parse porcelain output and check if ALL dirty paths are ignorable.
       Porcelain format: "XY filename" where XY is status, filename starts at pos 3.
       Lines are '\n'-separated. *)
    let lines = String.split_on_char '\n' out in
    let dirty_non_meta = List.filter (fun line ->
      if String.length line < 4 then false
      else
        let filename = String.sub line 3 (String.length line - 3) in
        not (is_meta_only_path filename)
    ) lines in
    dirty_non_meta <> []

(** [head_ancestor_of_origin_master path] returns true if the worktree
    HEAD is an ancestor of origin/master. Works for both attached
    branches and detached HEADs. False if origin/master is unreachable
    or if HEAD is ahead of origin. *)
let head_ancestor_of_origin_master path =
  let (code, _, _) =
    git_command ~cwd:path ~quiet:true
      [ "merge-base"; "--is-ancestor"; "HEAD"; "origin/master" ]
  in
  code = 0

(** [head_ancestor_of_master path] returns true if the worktree
    HEAD is an ancestor of the local master branch. Works for both
    attached branches and detached HEADs. False if master does not
    exist or HEAD is not an ancestor. This is the "slice landed on
    local master" signal in the coord-only-pushes workflow. *)
let head_ancestor_of_master path =
  let (code, _, _) =
    git_command ~cwd:path ~quiet:true
      [ "merge-base"; "--is-ancestor"; "HEAD"; "master" ]
  in
  code = 0

(** [head_equivalent_on_origin_master path] returns true if every commit
    unique to this branch (not on origin/master) has a content-equivalent
    on origin/master.

    Detects cherry-picked slices where the content has landed but the
    commit SHA is not an ancestor (cherry-picking creates a new commit object).

    Algorithm:
    1. Get the list of commits unique to this branch:
         git log --format=%H refs/remotes/origin/master..HEAD
    2. Run: git cherry refs/remotes/origin/master HEAD
    3. Collect SHAs marked with "+" (not on origin/master)
    4. Return true only if NONE of the branch-unique commits are in the "+" set

    This correctly handles:
    - Single-commit cherry-picked slice: only HEAD is branch-unique, and if it
      shows "-" in cherry output, the whole branch is content-equivalent.
    - Multi-commit branch: ALL branch-unique commits must show "-" to be GC-eligible.
    - Pre-existing history commits (already on origin/master) are excluded from
      the branch-unique set, so they don't cause false positives in cherry output. *)
let head_equivalent_on_origin_master path =
  (* Step 1: get commits unique to this branch (not on origin/master) *)
  let (code1, branch_shas_out, _) =
    git_command ~cwd:path ~quiet:true
      [ "log"; "--format=%H"; "refs/remotes/origin/master..HEAD" ]
  in
  if code1 <> 0 then false
  else
    let branch_shas =
      List.filter (fun s -> String.length s = 40)
        (String.split_on_char '\n' (String.trim branch_shas_out))
    in
    (* Empty list = HEAD is already an ancestor (would have matched the
       head_ancestor_of_origin_master check). Treat as false. *)
    if branch_shas = [] then false
    else
      (* Step 2: get cherry output *)
      let (code2, cherry_out, _) =
        git_command ~cwd:path ~quiet:true
          [ "cherry"; "refs/remotes/origin/master"; "HEAD" ]
      in
      if code2 <> 0 then false
      else
        (* Step 3: collect SHAs marked "+" in cherry output *)
        let cherry_lines = String.split_on_char '\n' (String.trim cherry_out) in
        let plus_shas =
          List.fold_right (fun line acc ->
            let trimmed = String.trim line in
            if String.length trimmed >= 42 && trimmed.[0] = '+' then
              let sha = String.sub trimmed 2 40 in
              sha :: acc
            else acc)
            cherry_lines []
        in
        (* Step 4: return true only if NO branch-unique commits are in the "+" list *)
        not (List.exists (fun sha -> List.mem sha plus_shas) branch_shas)

(** [main_worktree_path ()] returns the absolute path of the repo's main
    worktree (the first entry in `git worktree list --porcelain`). *)
let main_worktree_path () =
  let (code, out, _) = git_command ~quiet:true [ "worktree"; "list"; "--porcelain" ] in
  if code <> 0 then None
  else
    let lines = String.split_on_char '\n' out in
    let prefix = "worktree " in
    let plen = String.length prefix in
    let rec find = function
      | [] -> None
      | line :: rest ->
          let t = String.trim line in
          if String.length t >= plen && String.sub t 0 plen = prefix then
            Some (String.sub t plen (String.length t - plen))
          else find rest
    in
    find lines

(** [cwd_holders path] scans /proc/<pid>/cwd symlinks and returns
    [(pid, cmdline)] pairs for any process whose cwd is inside [path].
    Linux-only — on macOS/BSD this returns []. *)
let cwd_holders path =
  if not (Sys.file_exists "/proc") then []
  else
    let path_norm =
      try Unix.realpath path with _ -> path
    in
    let path_with_slash = path_norm ^ "/" in
    let pids =
      try
        Sys.readdir "/proc"
        |> Array.to_list
        |> List.filter (fun e ->
            String.length e > 0 &&
            let c = e.[0] in c >= '0' && c <= '9')
      with _ -> []
    in
    List.filter_map
      (fun pid_s ->
        let cwd_link = "/proc/" ^ pid_s ^ "/cwd" in
        match try Some (Unix.readlink cwd_link) with _ -> None with
        | None -> None
        | Some cwd ->
            (* Match either exactly the path, or any descendant. *)
            if cwd = path_norm
               || (String.length cwd > String.length path_with_slash
                   && String.sub cwd 0 (String.length path_with_slash)
                      = path_with_slash) then begin
              let cmdline_path = "/proc/" ^ pid_s ^ "/cmdline" in
              let cmdline =
                try
                  let ic = open_in cmdline_path in
                  Fun.protect ~finally:(fun () -> try close_in ic with _ -> ())
                    (fun () ->
                      let buf = Buffer.create 256 in
                      (try
                         while true do
                           let c = input_char ic in
                           Buffer.add_char buf (if c = '\x00' then ' ' else c)
                         done
                       with End_of_file -> ());
                      String.trim (Buffer.contents buf))
                with _ -> ""
              in
              Some (int_of_string pid_s, cmdline)
            end else None)
      pids

(** [worktree_size_bytes path] returns the disk usage of [path] in
    bytes via `du -sb`. Returns 0L on error. *)
let worktree_size_bytes path =
  let cmd = Printf.sprintf "du -sb %s 2>/dev/null" (Filename.quote path) in
  let ic = Unix.open_process_in cmd in
  let line =
    try Some (input_line ic) with End_of_file -> None
  in
  ignore (Unix.close_process_in ic);
  match line with
  | None -> 0L
  | Some l ->
      (match String.split_on_char '\t' l with
       | n :: _ -> (try Int64.of_string (String.trim n) with _ -> 0L)
       | [] -> 0L)

type gc_status =
  | GcRemovable of { reason : string }
  | GcRefused of { reason : string; unmerged_commits : (string * string) list }
  | GcPossiblyActive of { reason : string }
    (* #314: branch tip equals origin/master HEAD AND worktree was set
       up within the active-window. Soft REFUSE — `--clean` skips it,
       operator can override by committing-or-deleting. Heuristic
       protects fresh `git worktree add` checkouts whose owner is
       reading code in the main tree (so /proc/cwd misses them) but
       hasn't committed anything yet. *)

type gc_candidate =
  { gc_path : string
  ; gc_branch : string
  ; gc_size : int64
  ; gc_status : gc_status
  }

let format_bytes b =
  let f = Int64.to_float b in
  if f >= 1.0e9 then Printf.sprintf "%.1f GB" (f /. 1.0e9)
  else if f >= 1.0e6 then Printf.sprintf "%.1f MB" (f /. 1.0e6)
  else if f >= 1.0e3 then Printf.sprintf "%.1f KB" (f /. 1.0e3)
  else Printf.sprintf "%Ld B" b

(** [git_author_email ~cwd sha] returns the author email of commit [sha]
    in the repository at [cwd]. None on error. *)
let git_author_email ~cwd sha =
  let (code, out, _) =
    git_command ~cwd ~quiet:true [ "log"; "-1"; "--format=%ae"; sha ]
  in
  if code = 0 then
    let email = String.trim out in
    if email = "" || String.length email >= 6 && String.sub email 0 6 = "fatal:" then None else Some email
  else None

(** [head_sha path] returns the resolved HEAD commit SHA for the
    worktree at [path]. Empty string on error. *)
let head_sha path =
  let (code, out, _) =
    git_command ~cwd:path ~quiet:true [ "rev-parse"; "HEAD" ]
  in
  if code = 0 then String.trim out else ""

(** [origin_master_sha path] returns the SHA of refs/remotes/origin/master
    as known to the worktree (its shared object DB). Empty string on
    error. *)
let origin_master_sha path =
  let (code, out, _) =
    git_command ~cwd:path ~quiet:true [ "rev-parse"; "origin/master" ]
  in
  if code = 0 then String.trim out else ""

(** [head_age_seconds path] returns the age of the HEAD commit in seconds,
    i.e. time elapsed since the most recent commit in the worktree.
    Uses `git log -1 --format=%ct` (Unix timestamp of committer date).
    Returns None on error (e.g. empty repo, no commits yet). *)
let head_age_seconds path =
  let (code, out, _) =
    git_command ~cwd:path ~quiet:true [ "log"; "-1"; "--format=%ct" ]
  in
  if code <> 0 then None
  else
    match int_of_string_opt (String.trim out) with
    | None -> None
    | Some ts -> Some (Unix.gettimeofday () -. float ts)

(** [worktree_admin_dir path] returns the per-worktree admin dir (under
    [<git-common-dir>/worktrees/<name>/]) reported by `git rev-parse
    --git-dir` from inside the worktree. None on error. *)
let worktree_admin_dir path =
  let (code, out, _) =
    git_command ~cwd:path ~quiet:true [ "rev-parse"; "--git-dir" ]
  in
  if code <> 0 then None
  else
    let d = String.trim out in
    (* If the path is relative, resolve it inside the worktree. *)
    let abs =
      if Filename.is_relative d then Filename.concat path d else d
    in
    Some abs

(** [worktree_age_seconds path] returns the seconds since the worktree's
    admin dir was last modified (mtime). The mtime is set when git
    creates the admin dir at `worktree add` time and updated by certain
    git operations; for "fresh, untouched worktree" detection it's
    the load-bearing signal. None when the dir can't be stat'd. *)
let worktree_age_seconds path =
  match worktree_admin_dir path with
  | None -> None
  | Some d ->
      (try
         let st = Unix.stat d in
         Some (Unix.gettimeofday () -. st.Unix.st_mtime)
       with _ -> None)

(** [is_meta_only_path path] returns true if [path] (a file or directory
    within a worktree) is a "meta" path — sitrep, collab doc, personal
    log, or common build-artifact path — rather than real code. These paths
    are excluded from the "real code blocking GC" check (both for commit-level
    meta-filter and for the dirty-tree meta-ignorance feature). *)
let is_meta_only_path (path : string) : bool =
  (* Prefix-based patterns (dirs) *)
  List.exists (fun prefix ->
    String.length path >= String.length prefix
    && String.sub path 0 (String.length prefix) = prefix)
    [ ".sitreps/"
    ; ".collab/updates/"
    ; ".collab/design/"
    ; ".c2c/personal-logs/"
    ; ".c2c/memory/"
    ; "volumes/"      (* Docker/compose volumes *)
    ; "_build/"       (* Dune build output *) ]
  || (String.length path >= 5 && String.sub path 0 5 = ".git/"
      (* .git/ prefixes .git/worktrees, .git/config, etc. — git internals.
         .gitignore and .gitattributes do NOT start with .git/ — they are
         project files in the working tree, not git-internal metadata. *))
  (* Suffix-based patterns (common artifact file types) *)
  || (List.exists (fun suffix ->
         let len = String.length suffix in
         String.length path >= len
         && String.sub path (String.length path - len) len = suffix)
        [ ".log"; ".lock"; ".bak" ])

(** [commit_touches_noncode_paths ~cwd sha] returns true if commit [sha]
    only touches meta paths (sitreps, collab docs, personal logs, .git).
    Uses `git diff-tree --no-commit-id --name-only -r` to list paths.
    Returns false if any path is real code. *)
let commit_touches_noncode_paths ~(cwd : string) (sha : string) : bool =
  let (code, out, _) =
    git_command ~cwd ~quiet:true
      [ "diff-tree"; "--no-commit-id"; "--name-only"; "-r"; sha ]
  in
  if code <> 0 then false
  else
    let paths = String.split_on_char '\n' (String.trim out) in
    List.for_all is_meta_only_path paths

(** [is_meta_commit subject] returns true if the commit subject indicates
    a "meta" commit (sitrep, docs, findings, design, chore, todo, etc.)
    that is safe to lose during worktree GC. These are contextual artifacts
    committed during active slice work but never cherry-picked to master. *)
let is_meta_commit subject =
  let s = String.lowercase_ascii subject in
  let meta_prefixes =
    [ "sitrep"; "docs"; "chore"; "research"; "findings"; "todo"
    ; "collab"; "design"; "log(coord"; "wip(coord"; "wip:"; "wip("
    ; "add .collab"; "update .collab"; "add docs"; "update docs"
    ]
  in
  List.exists (fun pfx ->
    String.length s >= String.length pfx &&
    String.sub s 0 (String.length pfx) = pfx
  ) meta_prefixes
(** [unmerged_cherry_commits path] returns the list of (sha, subject) pairs
    for commits on this branch that are NOT content-equivalent to anything
    on origin/master (the "+" lines from git cherry). Empty list means
    all branch content has landed. *)
let unmerged_cherry_commits path =
  let (code, cherry_out, _) =
    git_command ~cwd:path ~quiet:true
      [ "cherry"; "-v"; "refs/remotes/origin/master"; "HEAD" ]
  in
  if code <> 0 then []
  else
    let lines = String.split_on_char '\n' (String.trim cherry_out) in
    List.filter_map (fun line ->
      let trimmed = String.trim line in
      if String.length trimmed > 2 && trimmed.[0] = '+' then
        let rest = String.sub trimmed 2 (String.length trimmed - 2) in
        (* rest is "SHA subject..." *)
        let sha_end = min 40 (String.length rest) in
        let sha = String.sub rest 0 sha_end in
        let subject = if String.length rest > 41 then
          String.sub rest 41 (String.length rest - 41)
        else "" in
        Some (sha, String.trim subject)
      else None
    ) lines

(** [classify_worktree ~ignore_active ~active_window_hours
    (alias, path, branch)] runs the refuse-checks and returns a
    [gc_candidate]. The freshness heuristic (#314) marks worktrees
    where HEAD == origin/master AND the admin dir is within
    [active_window_hours] as POSSIBLY_ACTIVE — a soft REFUSE that
    `--clean` skips, so a peer who set up a worktree minutes ago and
    went to read code elsewhere doesn't lose their setup. *)
(** Read `<worktree>/.git` (a "gitdir: <abs>" pointer file written by
    `git worktree add`) and return the admin dir's absolute path
    without invoking git — the read does NOT bump admin-dir mtime,
    unlike `git rev-parse --git-dir`. Falls back to [worktree_admin_dir]
    if the .git file isn't there or doesn't have the expected shape. *)
let admin_dir_no_git_call path =
  let dotgit = Filename.concat path ".git" in
  let from_pointer =
    try
      let ic = open_in dotgit in
      Fun.protect
        ~finally:(fun () -> try close_in ic with _ -> ())
        (fun () ->
          let line = try input_line ic with End_of_file -> "" in
          let prefix = "gitdir: " in
          let plen = String.length prefix in
          if String.length line >= plen
             && String.sub line 0 plen = prefix then
            let rel = String.trim (String.sub line plen (String.length line - plen)) in
            Some (if Filename.is_relative rel then Filename.concat path rel else rel)
          else
            None)
    with _ -> None
  in
  match from_pointer with
  | Some p -> Some p
  | None -> worktree_admin_dir path

(** Stat the admin dir mtime via the pointer-file path, BEFORE any git
    commands run against the worktree. (#314 lyra review: `git status`,
    `merge-base`, and `rev-parse` all touch the admin dir and refresh
    its mtime — measurement perturbs the system. Snapshot first.) *)
let snapshot_age_seconds path =
  match admin_dir_no_git_call path with
  | None -> None
  | Some d ->
      (try
         let st = Unix.stat d in
         Some (Unix.gettimeofday () -. st.Unix.st_mtime)
       with _ -> None)

let classify_worktree ~main_path ~ignore_active ~active_window_hours
    ~strict_dirt (_alias, path, branch) =
  let size = worktree_size_bytes path in
  let mk st = { gc_path = path; gc_branch = branch; gc_size = size; gc_status = st } in
  (* Snapshot admin-dir mtime BEFORE any git commands run (#314):
     is_dirty (git status), head_ancestor_of_origin_master (merge-base),
     head_equivalent_on_origin_master (git cherry), and head_sha /
     origin_master_sha (rev-parse) all touch the admin dir and bump its
     mtime. Without this snapshot, an actually-old worktree at
     HEAD==origin/master would misclassify as POSSIBLY_ACTIVE. *)
  let age_snapshot = snapshot_age_seconds path in
  (* Defense-in-depth: never offer the main worktree even if list_worktrees
     surfaced it. *)
  if (match main_path with
      | Some mp ->
          let p_norm = try Unix.realpath path with _ -> path in
          let m_norm = try Unix.realpath mp with _ -> mp in
          p_norm = m_norm
      | None -> false) then
    mk (GcRefused { reason = "main worktree (never offered)"; unmerged_commits = [] })
  else if is_dirty ~strict:strict_dirt path then
    mk (GcRefused { reason = "dirty working tree"; unmerged_commits = [] })
  else if not (head_ancestor_of_origin_master path || head_ancestor_of_master path || head_equivalent_on_origin_master path) then
    let unmerged = unmerged_cherry_commits path in
    if unmerged = [] then
      (* git cherry returned no '+' lines — treat as equivalent *)
      mk (GcRemovable { reason = "content-equivalent (no unmerged commits), clean" })
    else if List.for_all (fun (_sha, subj) -> is_meta_commit subj) unmerged then
      (* All unmerged commits are meta (sitreps, docs, findings) — safe to lose *)
      mk (GcRemovable { reason = Printf.sprintf "only meta commits unmerged (%d sitreps/docs/findings — safe to lose)" (List.length unmerged) })
    else
      (* Second-pass: check from main tree perspective. Worktree-internal
         git cherry can miss cherry-picks that had conflict resolution
         (different patch-id). Running from the main tree where the shared
         object store sees both sides gives accurate results. *)
      let head_rev =
        let (c, o, _) = git_command ~cwd:path ~quiet:true ["rev-parse"; "HEAD"] in
        if c = 0 then String.trim o else ""
      in
      let main_tree_says_equivalent =
        if head_rev = "" then false
        else
          (* Run git cherry from main tree against the worktree HEAD SHA.
             The main tree's shared object store sees both sides of cherry-picks
             accurately, unlike running from within the worktree where shared
             history depth confuses patch-id matching. *)
          let main_cwd = match main_path with Some p -> p | None -> "." in
          let (code, cherry_out, _) =
            git_command ~cwd:main_cwd ~quiet:true
              [ "cherry"; "refs/remotes/origin/master"; head_rev ]
          in
          if code <> 0 then false
          else
            (* Classify the main-tree's own '+' lines by subject.
               Don't cross-reference worktree SHAs — the main tree traversal
               produces different commit objects. Instead: if ALL '+' commits
               from the main-tree perspective are meta → safe to GC. *)
            let plus_lines =
              String.split_on_char '\n' (String.trim cherry_out)
              |> List.filter (fun line ->
                let t = String.trim line in
                String.length t >= 42 && t.[0] = '+')
            in
            if plus_lines = [] then true  (* no unmerged from main perspective *)
            else
              (* For each '+' SHA, get its subject and check if it's meta *)
              let all_plus_are_meta =
                List.for_all (fun line ->
                  let t = String.trim line in
                  let sha = String.sub t 2 40 in
                  let (rc, subj, _) =
                    git_command ~cwd:main_cwd ~quiet:true
                      [ "log"; "-1"; "--format=%s"; sha ]
                  in
                  if rc <> 0 then false
                  else is_meta_commit (String.trim subj)
                ) plus_lines
              in
              all_plus_are_meta
      in
      if main_tree_says_equivalent then
        mk (GcRemovable { reason = Printf.sprintf "content-equivalent from main-tree perspective (remaining unmerged are meta — safe to lose)" })
      else
        mk (GcRefused { reason = "HEAD not ancestor of origin/master or master (and not content-equivalent via git-cherry)"; unmerged_commits = unmerged })
  else
    let holders = if ignore_active then [] else cwd_holders path in
    match holders with
    | (pid, cmd) :: _ ->
        let snippet =
          if String.length cmd > 60 then String.sub cmd 0 60 ^ "…" else cmd
        in
        mk (GcRefused { reason = Printf.sprintf "active cwd: pid=%d (%s)" pid snippet; unmerged_commits = [] })
    | [] ->
        (* Freshness heuristic (#314). HEAD == origin/master + admin dir
           young = "set up but no work yet, owner may be reading
           elsewhere." Uses [age_snapshot] (taken before git commands)
           so the heuristic doesn't measure its own classification time. *)
        let head = head_sha path in
        let origin_head = origin_master_sha path in
        let head_eq_origin =
          head <> "" && origin_head <> "" && head = origin_head
        in
        let young =
          match age_snapshot with
          | Some age -> age < active_window_hours *. 3600.0
          | None -> true  (* conservative: if stat fails, assume fresh — don't GC *)
        in
        if head_eq_origin && young then
          let age = match age_snapshot with Some s -> s | None -> 0.0 in
          let age_h = age /. 3600.0 in
          mk (GcPossiblyActive
                { reason = Printf.sprintf
                    "fresh setup (HEAD==origin/master, age %.1fh < %.1fh \
                     window); owner may be working in another cwd"
                    age_h active_window_hours })
        else
          let removable_reason =
            if head_ancestor_of_origin_master path then
              "ancestor of origin/master, clean"
            else if head_ancestor_of_master path then
              "ancestor of local master, clean"
            else
              "content-equivalent (cherry-picked), clean"
          in
          mk (GcRemovable { reason = removable_reason })

(** [scan_worktrees_for_gc ~ignore_active ~active_window_hours
    ~age_threshold_days ()] enumerates worktrees under .worktrees/ and
    classifies each. The main worktree is filtered out early
    (defense-in-depth: classify_worktree also refuses it).

    If [age_threshold_days] is set, only worktrees whose HEAD commit is
    at least that many days old are considered. This lets operators
    target old, abandoned worktrees without affecting recently-active ones.
    Combined with the "ancestor of origin/master" and "content-equivalent
    via git-cherry" checks, this gives a "old AND definitely abandoned"
    signal for safe GC. *)
let scan_worktrees_for_gc ~ignore_active ~active_window_hours
    ~strict_dirt ~age_threshold_days () =
  let main_path = main_worktree_path () in
  let main_norm = match main_path with
    | Some mp -> (try Some (Unix.realpath mp) with _ -> Some mp)
    | None -> None
  in
  let entries = list_worktrees () in
  (* Filter to .worktrees/<name> shape; never ad-hoc external worktrees. *)
  let cwd = Sys.getcwd () in
  let repo_root = match main_path with
    | Some mp -> mp
    | None -> cwd
  in
  (* Prune stale worktree references before scanning.
     This removes entries for worktrees that were partially deleted,
     preventing "cd: No such file or directory" errors during classification. *)
  let (_ : int * string * string) =
    git_command ~cwd:repo_root ~quiet:true ["worktree"; "prune"]
  in
  let candidates =
    List.filter
      (fun (_, path, _) ->
        let p_norm = try Unix.realpath path with _ -> path in
        (match main_norm with
         | Some mn -> p_norm <> mn
         | None -> true)
         && (let prefix = repo_root // ".worktrees" ^ "/" in
            (* Anchor on trailing slash so .worktrees-other/foo
               doesn't match the .worktrees prefix. (#313 review by
               lyra-quill.) *)
            String.length p_norm > String.length prefix
             && String.sub p_norm 0 (String.length prefix) = prefix))
      entries
  in
  List.map
    (classify_worktree ~main_path ~ignore_active ~active_window_hours ~strict_dirt)
    candidates

(** Parallel git-batched worktree GC scan using a bounded thread pool.
    Each worker processes multiple worktrees sequentially (all git commands
    for a given worktree run serially, avoiding git object-db lock
    contention), while worktrees are distributed across N workers for
    parallelism.  With N=32 workers and ~600 worktrees, wall-clock time
    drops from ~5 min (sequential) to ~10-15 s on typical SSD.

    Design:
    - Thread pool: N=32 workers share a mutex-protected work queue.
    - Each worker pops candidate indices from the queue, processes that
      worktree's git batch sequentially, then stores the result.
    - [ignore_active] and [active_window_hours] are closed over at
      spawn time (values fixed for the duration of the scan). *)

let num_parallel_workers = 32

(** All git/read-only shell results for one worktree classification.
    Pre-computing these per worktree eliminates the sequential
    git-spawn overhead of the original [classify_worktree]. *)
type git_batch = {
  gb_size : int64;
  gb_age_snapshot : float option;
  gb_is_dirty : bool;
  gb_head_ancestor_of_origin_master : bool;
  gb_head_ancestor_of_master : bool;
  gb_head_equivalent : bool;
  gb_head_sha : string;
  gb_origin_master_sha : string;
  gb_cwd_holders : (int * string) list;
}

(** [run_git_batch ~ignore_active ~strict_dirt path] runs all git/read commands for one
    worktree and returns a [git_batch]. Sequential within each call (git
    object-db locks make per-command threading within a worktree counterproductive). *)
let run_git_batch ~ignore_active ~strict_dirt path =
  let size = worktree_size_bytes path in
  let age_snapshot = snapshot_age_seconds path in
  (* [dirty_code]: when [strict_dirt] is true, any git status output means dirty.
     When false, filter out meta-only/artifact paths (same logic as [is_dirty]). *)
  let dirty_code =
    let (_, out, _) = git_command ~cwd:path ~quiet:true [ "status"; "--porcelain" ] in
    let out = String.trim out in
    if out = "" then false
    else if strict_dirt then true
    else
      let lines = String.split_on_char '\n' out in
      let dirty_non_meta = List.filter (fun line ->
        if String.length line < 4 then false
        else
          let filename = String.sub line 3 (String.length line - 3) in
          not (is_meta_only_path filename)
      ) lines in
      dirty_non_meta <> []
  in
  let (ancestor_origin_code, _) =
    let (code, _, _) = git_command ~cwd:path ~quiet:true
      [ "merge-base"; "--is-ancestor"; "HEAD"; "origin/master" ] in
    (code = 0, ())
  in
  let (ancestor_master_code, _) =
    let (code, _, _) = git_command ~cwd:path ~quiet:true
      [ "merge-base"; "--is-ancestor"; "HEAD"; "master" ] in
    (code = 0, ())
  in
  let (code_log, branch_shas_out, _) =
    git_command ~cwd:path ~quiet:true
      [ "log"; "--format=%H"; "refs/remotes/origin/master..HEAD" ]
  in
  let branch_shas =
    if code_log <> 0 then []
    else List.filter (fun s -> String.length s = 40)
           (String.split_on_char '\n' (String.trim branch_shas_out))
  in
  let head_equivalent =
    if branch_shas = [] then false
    else
      let (code_cherry, cherry_out, _) =
        git_command ~cwd:path ~quiet:true
          [ "cherry"; "refs/remotes/origin/master"; "HEAD" ]
      in
      if code_cherry <> 0 then false
      else
        let cherry_lines = String.split_on_char '\n' (String.trim cherry_out) in
        let plus_shas =
          List.fold_right (fun line acc ->
            let trimmed = String.trim line in
            if String.length trimmed >= 42 && trimmed.[0] = '+' then
              String.sub trimmed 2 40 :: acc
            else acc)
            cherry_lines []
        in
        not (List.exists (fun sha -> List.mem sha plus_shas) branch_shas)
  in
  let (head_out, _) =
    let (_, out, _) = git_command ~cwd:path ~quiet:true [ "rev-parse"; "HEAD" ] in
    (out, ())
  in
  let (origin_out, _) =
    let (_, out, _) = git_command ~cwd:path ~quiet:true [ "rev-parse"; "origin/master" ] in
    (out, ())
  in
  let head_sha = if head_out = "" then "" else String.trim head_out in
  let origin_master_sha = if origin_out = "" then "" else String.trim origin_out in
  let cwd_holders_list = if ignore_active then [] else cwd_holders path in
  { gb_size = size; gb_age_snapshot = age_snapshot;
    gb_is_dirty = dirty_code;
    gb_head_ancestor_of_origin_master = ancestor_origin_code;
    gb_head_ancestor_of_master = ancestor_master_code;
    gb_head_equivalent = head_equivalent;
    gb_head_sha = head_sha; gb_origin_master_sha = origin_master_sha;
    gb_cwd_holders = cwd_holders_list }

(** [classify_from_git_batch batch (alias, path, branch) main_path
    active_window_hours] classifies using a pre-computed [git_batch].  Logic
    mirrors [classify_worktree] but reads batch fields instead of running
    git commands. *)
let classify_from_git_batch batch (_alias, path, branch) main_path
    active_window_hours =
  let { gb_size; gb_age_snapshot; gb_is_dirty;
        gb_head_ancestor_of_origin_master; gb_head_ancestor_of_master;
        gb_head_equivalent; gb_head_sha; gb_origin_master_sha;
        gb_cwd_holders } = batch in
  let mk st = { gc_path = path; gc_branch = branch; gc_size = gb_size; gc_status = st } in
  if (match main_path with
      | Some mp ->
          let p_norm = try Unix.realpath path with _ -> path in
          let m_norm = try Unix.realpath mp with _ -> mp in
          p_norm = m_norm
      | None -> false) then
    mk (GcRefused { reason = "main worktree (never offered)"; unmerged_commits = [] })
  else if gb_is_dirty then
    mk (GcRefused { reason = "dirty working tree"; unmerged_commits = [] })
  else if not (gb_head_ancestor_of_origin_master || gb_head_ancestor_of_master || gb_head_equivalent) then
    let unmerged = unmerged_cherry_commits path in
    if unmerged = [] then
      mk (GcRemovable { reason = "content-equivalent (no unmerged commits), clean" })
    else if List.for_all (fun (_sha, subj) -> is_meta_commit subj) unmerged then
      mk (GcRemovable { reason = Printf.sprintf "only meta commits unmerged (%d sitreps/docs/findings — safe to lose)" (List.length unmerged) })
    else
      (* Second-pass: main-tree perspective cherry check *)
      let head_rev = gb_head_sha in
      let main_tree_says_equivalent =
        if head_rev = "" then false
        else
          let main_cwd = match main_path with Some p -> p | None -> "." in
          let (code, cherry_out, _) =
            git_command ~cwd:main_cwd ~quiet:true
              [ "cherry"; "refs/remotes/origin/master"; head_rev ]
          in
          if code <> 0 then false
          else
            let plus_lines =
              String.split_on_char '\n' (String.trim cherry_out)
              |> List.filter (fun line ->
                let t = String.trim line in
                String.length t >= 42 && t.[0] = '+')
            in
            if plus_lines = [] then true
            else
              List.for_all (fun line ->
                let t = String.trim line in
                let sha = String.sub t 2 40 in
                let (rc, subj, _) =
                  git_command ~cwd:main_cwd ~quiet:true
                    [ "log"; "-1"; "--format=%s"; sha ]
                in
                if rc <> 0 then false
                else is_meta_commit (String.trim subj)
              ) plus_lines
      in
      if main_tree_says_equivalent then
        mk (GcRemovable { reason = "content-equivalent from main-tree perspective (remaining unmerged are meta — safe to lose)" })
      else
        mk (GcRefused { reason = "HEAD not ancestor of origin/master or master (and not content-equivalent via git-cherry)"; unmerged_commits = unmerged })
  else
    match gb_cwd_holders with
    | (pid, cmd) :: _ ->
        let snippet = if String.length cmd > 60 then String.sub cmd 0 60 ^ "…" else cmd in
        mk (GcRefused { reason = Printf.sprintf "active cwd: pid=%d (%s)" pid snippet; unmerged_commits = [] })
    | [] ->
        let head_eq_origin =
          gb_head_sha <> "" && gb_origin_master_sha <> "" && gb_head_sha = gb_origin_master_sha in
        let young = match gb_age_snapshot with
          | Some age -> age < active_window_hours *. 3600.0
          | None -> true in  (* conservative: if stat fails, assume fresh — don't GC *)
        if head_eq_origin && young then
          let age = match gb_age_snapshot with Some s -> s | None -> 0.0 in
          let age_h = age /. 3600.0 in
          mk (GcPossiblyActive
                { reason = Printf.sprintf
                    "fresh setup (HEAD==origin/master, age %.1fh < %.1fh \
                     window); owner may be working in another cwd"
                    age_h active_window_hours })
        else
          mk (GcRemovable { reason = "ancestor of origin/master or master, clean" })

(** [scan_worktrees_for_gc_parallel ~ignore_active ~active_window_hours ~strict_dirt ()]
    parallel counterpart of [scan_worktrees_for_gc].  Distributes worktrees
    across [num_parallel_workers] threads; each worker processes its chunk
    sequentially.  Main thread busy-waits for all results. *)
let scan_worktrees_for_gc_parallel ~ignore_active ~active_window_hours ~strict_dirt () =
  let main_path = main_worktree_path () in
  let main_norm = match main_path with
    | Some mp -> (try Some (Unix.realpath mp) with _ -> Some mp)
    | None -> None
  in
  let entries = list_worktrees () in
  let cwd = Sys.getcwd () in
  let repo_root = match main_path with Some mp -> mp | None -> cwd in
  let candidates =
    List.filter
      (fun (_, path, _) ->
        let p_norm = try Unix.realpath path with _ -> path in
        (match main_norm with Some mn -> p_norm <> mn | None -> true)
        && (let prefix = repo_root // ".worktrees" ^ "/" in
            String.length p_norm > String.length prefix
            && String.sub p_norm 0 (String.length prefix) = prefix))
      entries
  in
  let n = List.length candidates in
  (* results.(i) = Some (alias, path, branch, gc_candidate) once done *)
  let results : (string * string * string * gc_candidate) option array =
    Array.make n None
  in
  let results_mutex = Mutex.create () in
  (* Work queue: list of indices still to process *)
  let work_queue = ref (List.init n (fun i -> i)) in
  let queue_mutex = Mutex.create () in
  let rec worker () =
    let rec loop () =
      (* Pop next index from queue *)
      let opt_idx =
        Mutex.lock queue_mutex;
        (match !work_queue with
         | [] -> Mutex.unlock queue_mutex; None
         | idx :: rest ->
             work_queue := rest;
             Mutex.unlock queue_mutex;
             Some idx)
      in
      match opt_idx with
      | None -> ()
      | Some idx ->
          let (alias, path, branch) = List.nth candidates idx in
          let batch = run_git_batch ~ignore_active ~strict_dirt path in
          let gc = classify_from_git_batch batch (alias, path, branch) main_path active_window_hours in
          Mutex.lock results_mutex;
          Array.unsafe_set results idx (Some (alias, path, branch, gc));
          Mutex.unlock results_mutex;
          loop ()
    in
    loop ()
  in
  (* Spawn all workers — thread handles not stored (workers run to completion) *)
  List.iter (fun _ -> ignore (Thread.create worker ()))
    (List.init num_parallel_workers Fun.id);
  (* Wait for all results to be filled *)
  let rec wait_for_all () =
    let done_count =
      Mutex.lock results_mutex;
      let count = Array.fold_left (fun acc opt ->
        match opt with Some _ -> acc + 1 | None -> acc) 0 results
      in
      Mutex.unlock results_mutex;
      count
    in
    if done_count < n then (Thread.delay 0.05; wait_for_all ()) else ()
  in
  wait_for_all ();
  (* Assemble gc_candidate list in original order *)
  List.map (fun i ->
    match Array.unsafe_get results i with
    | Some (_, _, _, gc) -> gc
    | None ->
        let (_, path, branch) = List.nth candidates i in
        { gc_path = path; gc_branch = branch; gc_size = 0L;
          gc_status = GcRefused { reason = "classification failed (parallel scan)"; unmerged_commits = [] } })
    (List.init n Fun.id)

(** [gc_remove_path path] removes a worktree via `git worktree remove`.
    Returns true on success. *)
let gc_remove_path path =
  let (code, _, _) = git_command [ "worktree"; "remove"; path ] in
  code = 0

(** [gc_remove_path_force path] force-removes a worktree via `git worktree remove --force`.
    Used by the interactive triage to override REFUSE classifications.
    Returns true on success. *)
let gc_remove_path_force path =
  let (code, _, _) = git_command [ "worktree"; "remove"; "--force"; path ] in
  code = 0

(** [unmerged_commits path] returns the set of commits unique to this branch
    (not on origin/master), categorized by whether `git cherry` marks them as
    equivalent (-) or unique (+).
    Returns (plus_shas, minus_shas, output_lines). *)
let unmerged_commits path =
  (* Collect branch-unique SHAs: commits reachable from HEAD but not from origin/master *)
  let (code1, branch_shas_out, _) =
    git_command ~cwd:path ~quiet:true
      [ "log"; "--format=%H"; "refs/remotes/origin/master..HEAD" ]
  in
  let _branch_shas =
    if code1 <> 0 then []
    else
      List.filter (fun s -> String.length s = 40)
        (String.split_on_char '\n' (String.trim branch_shas_out))
  in
  (* Run git cherry to classify each unique commit *)
  let (code2, cherry_out, _) =
    git_command ~cwd:path ~quiet:true
      [ "cherry"; "refs/remotes/origin/master"; "HEAD" ]
  in
  let plus_shas, minus_shas, lines =
    if code2 <> 0 then [], [], []
    else
      let cherry_lines = String.split_on_char '\n' (String.trim cherry_out) in
      let plus, minus, all_lines =
        List.fold_right
          (fun line (p_acc, m_acc, l_acc) ->
            let trimmed = String.trim line in
            if trimmed = "" then (p_acc, m_acc, l_acc)
            else if String.length trimmed >= 42 then
              let marker = trimmed.[0] in
              let sha = String.sub trimmed 2 40 in
              if marker = '+' then (sha :: p_acc, m_acc, trimmed :: l_acc)
              else if marker = '-' then (p_acc, sha :: m_acc, trimmed :: l_acc)
              else (p_acc, m_acc, trimmed :: l_acc)
            else (p_acc, m_acc, l_acc))
          cherry_lines ([], [], [])
      in
      (plus, minus, all_lines)
  in
  (plus_shas, minus_shas, lines)

(** [print_unmerged_summary path] prints a one-line summary of unmerged commits
    for the triage header, plus the first few cherry lines for quick context. *)
let print_unmerged_summary ~indent path =
  let (plus_shas, minus_shas, lines) = unmerged_commits path in
  let total = List.length plus_shas + List.length minus_shas in
  Printf.printf "%s  git cherry: %d commit(s) not on origin/master\n" indent total;
  (* Show cherry lines truncated to last 8 *)
  let lines_show = if List.length lines > 8 then List.rev (let rec pick n = function [] -> [] | x :: xs -> if n <= 0 then [] else x :: pick (n-1) xs in pick 8 (List.rev lines)) else lines in
  List.iter (fun l ->
      Printf.printf "%s    %s\n" indent l)
    lines_show

(** [show_inspect_detail path] prints full git log of unmerged commits
    for deep inspection when the operator chooses [I]nspect. *)
let show_inspect_detail path =
  let (plus_shas, _, _) = unmerged_commits path in
  if plus_shas = [] then
    Printf.printf "  (all branch commits are content-equivalent to origin/master)\n"
  else begin
    (* Show git log of commits unique to this branch (not on origin/master) *)
    let (_, log_out, _) =
      git_command ~cwd:path
        [ "log"; "--format=%h %s (%ad)"; "--date=short";
          "refs/remotes/origin/master..HEAD" ]
    in
    let log_lines = String.split_on_char '\n' (String.trim log_out) in
    let non_empty = List.filter ((<>) "") log_lines in
    if non_empty = [] then
      Printf.printf "  (no commit history found)\n"
    else begin
      Printf.printf "\n  Unmerged commits (%d total):\n" (List.length plus_shas);
      List.iter (fun l -> Printf.printf "    %s\n" l)
        non_empty
    end
  end

(** [interactive_triage candidates] presents each REFUSE-classified worktree
    to the operator for triage. Prompts [D]elete / [S]kip / [I]nspect.
    Returns the count of deleted worktrees. *)
let interactive_triage ~candidates =
  let refused = List.filter (fun c ->
      match c.gc_status with GcRefused _ -> true | _ -> false)
      candidates
  in
  if refused = [] then begin
    Printf.printf "No REFUSE-classified worktrees to triage.\n";
    0
  end else begin
    Printf.printf "\n=== Interactive GC Triage (%d REFUSE worktrees) ===\n"
      (List.length refused);
    Printf.printf "Classify each worktree: [D]elete (force-remove) / [S]kip / [I]nspect\n\n";
    let deleted_count = ref 0 in
    let rec loop = function
      | [] ->
          Printf.printf "\nTriage complete. %d worktree(s) deleted.\n" !deleted_count
      | c :: rest ->
          let reason = match c.gc_status with GcRefused { reason } -> reason | _ -> "?" in
          Printf.printf "--- REFUSE: %s ---\n" (Filename.basename c.gc_path);
          Printf.printf "  Path:    %s\n" c.gc_path;
          Printf.printf "  Branch:  %s\n" c.gc_branch;
          Printf.printf "  Size:    %s\n" (format_bytes c.gc_size);
          Printf.printf "  Reason:  %s\n" reason;
          Printf.printf "\n";
          print_unmerged_summary ~indent:"  " c.gc_path;
          Printf.printf "\n  [D]elete  [S]kip  [I]nspect: %!";
          let choice =
            try
              let line = read_line () in
              String.trim line
            with End_of_file -> "s"
          in
          match String.lowercase_ascii choice with
          | "d" ->
              Printf.printf "  → Deleting (force)...\n";
              if gc_remove_path_force c.gc_path then begin
                incr deleted_count;
                Printf.printf "  → Removed %s\n" c.gc_path;
              end else begin
                Printf.eprintf "  → FAILED to remove %s\n" c.gc_path;
              end;
              loop rest
          | "i" ->
              Printf.printf "\n";
              show_inspect_detail c.gc_path;
              Printf.printf "\n  [D]elete  [S]kip (after inspect): %!";
              let retry_choice =
                try read_line () with End_of_file -> "s"
              in
              (match String.lowercase_ascii (String.trim retry_choice) with
               | "d" ->
                   Printf.printf "  → Deleting (force)...\n";
                   if gc_remove_path_force c.gc_path then begin
                     incr deleted_count;
                     Printf.printf "  → Removed %s\n" c.gc_path;
                   end else begin
                     Printf.eprintf "  → FAILED to remove %s\n" c.gc_path;
                   end;
               | _ -> Printf.printf "  → Skipped.\n");
              loop rest
          | _ ->
              Printf.printf "  → Skipped.\n";
              loop rest
    in
    loop refused;
    !deleted_count
  end

let render_gc_human ~candidates ~clean ~verbose =
  let removable = List.filter (fun c ->
      match c.gc_status with GcRemovable _ -> true | _ -> false)
      candidates
  in
  let possibly_active = List.filter (fun c ->
      match c.gc_status with GcPossiblyActive _ -> true | _ -> false)
      candidates
  in
  let refused = List.filter (fun c ->
      match c.gc_status with GcRefused _ -> true | _ -> false)
      candidates
  in
  let sum_size cs =
    List.fold_left (fun acc c -> Int64.add acc c.gc_size) 0L cs
  in
  let total_size = sum_size candidates in
  let removable_size = sum_size removable in
  Printf.printf "Worktree GC scan (%d worktrees, %s total)\n\n"
    (List.length candidates) (format_bytes total_size);
  Printf.printf "REMOVABLE (%d worktrees, %s):\n"
    (List.length removable) (format_bytes removable_size);
  List.iter (fun c ->
      let r = match c.gc_status with
        | GcRemovable { reason } -> reason
        | _ -> ""
      in
      Printf.printf "  %-50s %8s  %-30s %s\n" c.gc_path (format_bytes c.gc_size) c.gc_branch r;
      if verbose && String.length r >= 18 && (try String.sub r 0 18 = "content-equivalent" with _ -> false) then
        Printf.printf "    (all branch commits content-matched on origin/master via git-cherry)\n";
      if verbose && String.length r >= 14 && (try String.sub r 0 14 = "shared-orphan" with _ -> false) then
        Printf.printf "    (all unmerged commits are shared orphans — burn-distributed, content is safe)\n";
      if verbose && String.length r >= 9 && (try String.sub r 0 9 = "meta-only" with _ -> false) then
        Printf.printf "    (unique commits touch only sitrep/docs/meta paths — safe to GC, content preserved)\n")
    removable;
  if possibly_active <> [] then begin
    (* `[!]` prefix flags POSSIBLY_ACTIVE as "review me" rather than
       "blocked" — distinct from REFUSE so an operator's eye sees
       "this is a fresh worktree, owner may be using it elsewhere"
       not just "another refuse-path." *)
    Printf.printf "\n[!] POSSIBLY_ACTIVE (%d worktrees, soft-refused — \
                   --clean skips, override by committing or deleting):\n"
      (List.length possibly_active);
    List.iter (fun c ->
        let r = match c.gc_status with
          | GcPossiblyActive { reason } -> reason
          | _ -> ""
        in
        Printf.printf "  [!] %-46s %8s  %-30s %s\n" c.gc_path (format_bytes c.gc_size) c.gc_branch r)
      possibly_active
  end;
  Printf.printf "\nREFUSE (%d worktrees):\n" (List.length refused);
  List.iter (fun c ->
      let (r, unmerged) = match c.gc_status with
        | GcRefused { reason; unmerged_commits } -> (reason, unmerged_commits)
        | _ -> ("", [])
      in
      Printf.printf "  %-50s %8s  %-30s REFUSE: %s\n" c.gc_path (format_bytes c.gc_size) c.gc_branch r;
      if verbose && unmerged <> [] then begin
        List.iter (fun (sha, subj) ->
          let short_sha = if String.length sha > 8 then String.sub sha 0 8 else sha in
          Printf.printf "    + %s %s\n" short_sha subj
        ) (List.filteri (fun i _ -> i < 10) unmerged);
        if List.length unmerged > 10 then
          Printf.printf "    ... +%d more\n" (List.length unmerged - 10)
      end)
    refused;
  if not clean then begin
    Printf.printf "\nTotal reclaimable: %s (%d worktrees)\n"
      (format_bytes removable_size) (List.length removable);
    Printf.printf "Run with --clean to remove the REMOVABLE set \
                   (POSSIBLY_ACTIVE skipped). Dry-run by default.\n"
  end

(* ---- shared-orphan deduplication ----------------------------------------
    Post-classification pass: for each GcRefused worktree, check whether ALL
    of its unmerged commits (the + lines from git cherry) appear in more than
    [threshold] worktrees total. If so, the worktree's commits are shared
    orphans — burn-distributed artifacts that exist identically in many
    branches. The content has not been lost; it was distributed simultaneously
    to all agents during the Apr 28-29 surge. Reclassify to GcRemovable.

    [threshold] defaults to 5: a commit appearing in ≥6 worktrees is considered
    a shared orphan. Set --shared-orphan-threshold=0 to disable.
 *)

(** [sha_count_map_of_refused candidates] builds a SHA → worktree-count map
    from all unmerged commits (+ lines from git cherry) across all GcRefused
    worktrees in [candidates]. Only GcRefused entries contribute entries;
    other classifications are skipped. *)
let sha_count_map_of_refused candidates =
  List.fold_left (fun acc c ->
    match c.gc_status with
    | GcRefused { unmerged_commits; _ } ->
        List.fold_left (fun acc (sha, _subj) ->
          (* Extract just the first 40 hex chars of the SHA. *)
          let sha = String.sub sha 0 (min 40 (String.length sha)) in
          let prev = try Hashtbl.find acc sha with Not_found -> 0 in
          Hashtbl.replace acc sha (prev + 1);
          acc
        ) acc unmerged_commits
    | _ -> acc)
    (Hashtbl.create 64)
    candidates

(** [all_shares_are_orphans ~threshold sha unmerged count] returns true when
    [count] > [threshold] — i.e., this SHA appears in enough worktrees to be
    considered a shared orphan. *)
let is_shared_orphan ~threshold count = count > threshold

(** [deduplicate_shared_orphans ~threshold candidates] reclassifies each
    GcRefused worktree as GcRemovable using a combined two-layer strategy:

    Layer 1 — shared orphans: if ALL unmerged commits appear in >threshold
    worktrees, reclassify as REMOVABLE ("shared-orphan" reason).

    Layer 2 — meta-only unique commits: for worktrees that fail Layer 1
    (have some unique/unshared commits), check whether those unique commits
    ALL touch only meta paths (sitreps, collab docs, .git internals).
    If so, reclassify as REMOVABLE ("meta-only" reason) — the unique content
    is not lost work, just documentation overhead.

    This combines the shared-orphan insight with the meta-path heuristic
    into a single pass, reclassifying worktrees that have e.g. 789 shared
    orphans + 2 sitrep-only unique commits. *)
let deduplicate_shared_orphans ~threshold candidates =
  if threshold <= 0 then candidates
  else begin
    let sha_counts = sha_count_map_of_refused candidates in
    (* Layer 3 support: build a set of all commit subjects on origin/master.
       One git invocation, O(1) lookups per unique commit. Used to detect
       cherry-picked work where patch-ids differ but subjects match. *)
    let master_subjects =
      let main_cwd =
        match main_worktree_path () with
        | Some p -> p
        | None -> "."
      in
      let (code, out, _) =
        git_command ~cwd:main_cwd ~quiet:true
          [ "log"; "--format=%s"; "refs/remotes/origin/master" ]
      in
      let tbl = Hashtbl.create 4096 in
      if code = 0 then begin
        String.split_on_char '\n' out
        |> List.iter (fun line ->
          let s = String.trim line in
          if s <> "" then Hashtbl.replace tbl s true)
      end;
      tbl
    in
    List.map (fun c ->
      match c.gc_status with
      | GcRefused { reason = _; unmerged_commits } ->
          if unmerged_commits = [] then c
          else begin
            (* Partition unmerged commits into shared orphans vs unique commits *)
            let unique_commits, shared_commits =
              List.fold_left (fun (uniq, shared) (sha, subj) ->
                let bare_sha = String.sub sha 0 (min 40 (String.length sha)) in
                let cnt = try Hashtbl.find sha_counts bare_sha with Not_found -> 0 in
                if is_shared_orphan ~threshold cnt then
                  (uniq, (bare_sha, cnt, subj) :: shared)
                else
                  ((bare_sha, cnt, subj) :: uniq, shared)
              ) ([], []) unmerged_commits
            in
            (* Layer 1: all shared orphans → REMOVABLE *)
            if unique_commits = [] then begin
              let top_shares =
                List.sort (fun (_, c1, _) (_, c2, _) -> Int.compare c2 c1)
                  shared_commits
                |> List.filteri (fun i _ -> i < 3)
              in
              let reason_strs =
                List.map (fun (sha, cnt, _) ->
                  let short = if String.length sha >= 8 then String.sub sha 0 8 else sha in
                  Printf.sprintf "%s(+%d)" short cnt
                ) top_shares
              in
              let reason' = Printf.sprintf "shared-orphan (all %d unmerged SHAs shared across >%d worktrees: %s)"
                (List.length unmerged_commits) threshold (String.concat ", " reason_strs)
              in
              { c with gc_status = GcRemovable { reason = reason' } }
            end else begin
              (* Layer 2: unique commits — check if they are ALL meta-only *)
              let all_meta_only =
                List.fold_left (fun ok (bare_sha, _, _) ->
                  ok && commit_touches_noncode_paths ~cwd:c.gc_path bare_sha
                ) true unique_commits
              in
              if all_meta_only then
                let n_unique = List.length unique_commits in
                let n_shared = List.length shared_commits in
                let reason' = Printf.sprintf "meta-only (all %d unique commit(s) touch only sitrep/docs/meta; %d shared orphans filtered)"
                  n_unique n_shared
                in
                { c with gc_status = GcRemovable { reason = reason' } }
              else
                (* Layer 3: subject-match heuristic. For unique commits that
                   aren't meta-only by path, check if their subjects appear on
                   origin/master. If ALL unique commits have a subject match,
                   the work was cherry-picked (just with different patch-ids
                   due to conflict resolution). *)
                let all_subjects_on_master =
                  List.for_all (fun (_sha, _cnt, subj) ->
                    Hashtbl.mem master_subjects subj
                  ) unique_commits
                in
                if all_subjects_on_master then
                  let n_unique = List.length unique_commits in
                  let n_shared = List.length shared_commits in
                  let reason' = Printf.sprintf "subject-superseded (all %d unique commit(s) have matching subjects on master; %d shared orphans filtered)"
                    n_unique n_shared
                  in
                  { c with gc_status = GcRemovable { reason = reason' } }
                else c
            end
          end
      | _ -> c)
      candidates
  end

(* ---- ask-authors GC phase --------------------------------------------
    For worktrees classified REFUSE, auto-DM the commit author asking if
    the worktree is still active. Reclassify based on response:
    - "superseded" / "done" / "gone" → GcRemovable (author says GC it)
    - "active" / "keep" / "working" → stays GcRefused (author says keep)
    - timeout (default 60s) → stays GcRefused (no response = conservatively keep)
 *)

type ask_author_response =
  | Response_active
  | Response_superseded
  | Response_timeout

(** [ask_worktree_author ~broker ~our_alias ~alias ~path ~branch ~timeout_s]
    sends a DM to [alias] asking about [path] and collects a response within
    [timeout_s] seconds. Returns what the author said, or Response_timeout on silence.
    The coordinator polls its own inbox for the author's reply. *)
let ask_worktree_author ~broker ~our_alias ~alias ~path ~branch ~timeout_s =
  let msg_body =
    Printf.sprintf
      "Worktree GC inquiry: is this worktree still active or superseded?\n\
        Path: %s\n\
        Branch: %s\n\
       Reply with ONE word: 'active' (keep) or 'superseded' (safe to GC).\n\
       Timeout: %d seconds."
      path branch timeout_s
  in
  let start_t = Unix.gettimeofday () in
  (* Send the DM from our coordinator alias *)
  (try
     C2c_mcp.Broker.enqueue_message broker ~from_alias:our_alias ~to_alias:alias
       ~content:msg_body ()
    with e ->
      Printf.eprintf "[ask_authors] enqueue_message to %s failed: %s\n%!" alias (Printexc.to_string e));
  (* If we don't know our own session_id, we can't read our inbox to collect
     the author's reply. Bail early with timeout rather than reading a
     nonexistent inbox. *)
  let our_session = C2c_mcp.session_id_from_env () in
  match our_session with
  | None -> Response_timeout
  | Some session ->
      let rec poll () =
        let elapsed = Unix.gettimeofday () -. start_t in
        if elapsed >= Float.of_int timeout_s then Response_timeout
        else begin
          (* Sleep to avoid busy-looping *)
          ignore (Unix.select [] [] [] 1.0);
          let msgs = try C2c_mcp.Broker.read_inbox broker ~session_id:session
            with _ -> [] in
          let normalized s = String.trim (String.lowercase_ascii s) in
          let reply = List.fold_left (fun acc (m : C2c_mcp.message) ->
              if m.from_alias = alias then Some (normalized m.content) :: acc else acc)
            [] msgs in
          match reply with
          | [] -> poll ()
          | Some s :: _ ->
              if s = "active" || s = "keep" || s = "working" then Response_active
              else if s = "superseded" || s = "done" || s = "gone" || s = "delete" || s = "gc" then Response_superseded
              else poll ()
          | None :: _ -> poll ()
        end
      in
      poll ()

(** [resolve_worktree_author_alias ~path] returns the c2c alias for the
    author of the HEAD commit in [path], or None if unknown/erroneous. *)
let resolve_worktree_author_alias ~path =
  let sha = head_sha path in
  if sha = "" then None
  else
    match git_author_email ~cwd:path sha with
    | None -> None
    | Some email -> email_to_alias_opt email

(** [ask_authors_and_reclassify ~broker ~timeout_s ~verbose candidates] sends DMs
    to authors of REFUSE worktrees asking if they're active. Returns [candidates]
    with GcRefused entries potentially reclassified to GcRemovable based on
    author responses. *)
let ask_authors_and_reclassify ~broker ~timeout_s ~verbose candidates =
  let refused = List.filter (fun c ->
      match c.gc_status with GcRefused _ -> true | _ -> false)
    candidates
  in
  if refused = [] then begin
    if verbose then
      Printf.printf "\n(no REFUSE worktrees to ask about)\n";
    candidates
  end else begin
    if verbose then
      Printf.printf "\n[--ask-authors] inquiring about %d REFUSE worktree(s)...\n"
        (List.length refused);
    let our_alias =
      match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
      | Some a -> a | None -> "coordinator1"
    in
    let results = List.map (fun c ->
        match resolve_worktree_author_alias ~path:c.gc_path with
        | None ->
            if verbose then
              Printf.printf "  %s: could not resolve author alias (skipping)\n"
                (Filename.basename c.gc_path);
            (c, None)
        | Some alias ->
            if verbose then
              Printf.printf "  %s: asking %s...\n"
                (Filename.basename c.gc_path) alias;
            let response = ask_worktree_author ~broker ~our_alias ~alias
                ~path:c.gc_path ~branch:c.gc_branch ~timeout_s in
            (c, Some response))
      refused
    in
    (* Reclassify based on responses *)
    List.map (fun (c, resp) ->
        match resp with
        | Some Response_superseded ->
            if verbose then
              Printf.printf "  %s: author says SUPERSEDED → GcRemovable\n"
                (Filename.basename c.gc_path);
            { c with gc_status = GcRemovable { reason = "author confirmed superseded via --ask-authors" } }
        | Some Response_active ->
            if verbose then
              Printf.printf "  %s: author says ACTIVE → stays REFUSE\n"
                (Filename.basename c.gc_path);
            c
        | Some Response_timeout ->
            if verbose then
              Printf.printf "  %s: author timed out → stays REFUSE\n"
                (Filename.basename c.gc_path);
            c
        | None -> c)
      results
  end

(* Emit byte counts as numeric JSON: `Int when in 63-bit OCaml int
   range (effectively always for filesystem sizes), `Intlit otherwise.
   Strings would force jq consumers to | tonumber. *)
let json_of_int64 i =
  if i >= Int64.of_int min_int && i <= Int64.of_int max_int
  then `Int (Int64.to_int i)
  else `Intlit (Int64.to_string i)

let render_gc_json ~candidates =
  let item c =
    let base =
      [ ("path", `String c.gc_path)
      ; ("branch", `String c.gc_branch)
      ; ("size_bytes", json_of_int64 c.gc_size)
      ]
    in
    match c.gc_status with
    | GcRemovable { reason } ->
        `Assoc (base @ [ ("status", `String "removable")
                       ; ("reason", `String reason) ])
    | GcPossiblyActive { reason } ->
        `Assoc (base @ [ ("status", `String "possibly_active")
                       ; ("reason", `String reason) ])
    | GcRefused { reason; unmerged_commits } ->
        let commits_json = `List (List.map (fun (sha, subj) ->
          `Assoc [("sha", `String sha); ("subject", `String subj)]) unmerged_commits) in
        `Assoc (base @ [ ("status", `String "refused")
                       ; ("refuse_reason", `String reason)
                       ; ("unmerged_commits", commits_json) ])
  in
  let removable = List.filter (fun c ->
      match c.gc_status with GcRemovable _ -> true | _ -> false)
      candidates
  in
  let possibly_active = List.filter (fun c ->
      match c.gc_status with GcPossiblyActive _ -> true | _ -> false)
      candidates
  in
  let refused = List.filter (fun c ->
      match c.gc_status with GcRefused _ -> true | _ -> false)
      candidates
  in
  let sum_size cs =
    List.fold_left (fun acc c -> Int64.add acc c.gc_size) 0L cs
  in
  `Assoc
    [ ("scan", `Assoc
         [ ("total_worktrees", `Int (List.length candidates))
         ; ("total_bytes", json_of_int64 (sum_size candidates))
         ])
    ; ("removable", `List (List.map item removable))
    ; ("possibly_active", `List (List.map item possibly_active))
    ; ("refused", `List (List.map item refused))
    ]

let worktree_gc_term =
  let open Cmdliner in
  let clean_flag =
    Arg.(value & flag & info ["clean"]
           ~doc:"Actually remove the REMOVABLE set. Default is dry-run.")
  in
  let json_flag =
    Arg.(value & flag & info ["json"] ~doc:"Output machine-readable JSON.")
  in
  let ignore_active_flag =
    Arg.(value & flag & info ["ignore-active"]
           ~doc:"Skip the live-cwd-holder check. Use only when the \
                 cwd-holding process is known dead (stale /proc entry).")
  in
  let path_prefix_flag =
    Arg.(value & opt (some string) None & info ["path-prefix"] ~docv:"PREFIX"
           ~doc:"Filter to worktrees whose basename starts with PREFIX. \
                 Useful for bounding --clean to a known set, e.g. \
                 --path-prefix=gc-test- when manually exercising the GC.")
  in
  let active_window_flag =
    Arg.(value & opt float 2.0 & info ["active-window-hours"] ~docv:"HOURS"
           ~doc:"Freshness window for the POSSIBLY_ACTIVE heuristic (#314): \
                 worktrees whose HEAD == origin/master AND admin-dir mtime \
                 is younger than HOURS are soft-refused (--clean skips). \
                 Default: 2.0. Set 0 to disable the heuristic entirely.")
  in
  let age_flag =
    let doc = "Only consider worktrees whose last commit is at least AGE days old. \
               Format: integer with optional 'd' suffix (e.g. 30d or 30). \
               Combined with --clean, targets \"old AND abandoned\" worktrees. \
               Without this flag, all worktrees are considered regardless of age." in
    Arg.(value & opt (some string) None & info ["age"] ~docv:"AGE"
           ~doc)
  in
  let verbose_flag =
    Arg.(value & flag & info ["verbose"; "v"]
           ~doc:"Show per-commit cherry detail for REFUSE'd worktrees \
                 and annotate REMOVABLE worktrees that are content-equivalent \
                 (cherry-picked) rather than direct ancestors.")
  in
  let shared_orphan_threshold_flag =
    Arg.(value & opt int 5 & info ["shared-orphan-threshold"] ~docv:"N"
           ~doc:"Reclassify REFUSE worktrees as REMOVABLE when all their \
                 unmerged commits (git cherry + lines) appear in more than N \
                 worktrees. Shared orphan commits are burn-distributed commits \
                 that exist identically across many worktrees (sitrep/docs \
                 bursts). Set 0 to disable. Default: 5.")
  in
  let ask_authors_flag =
    Arg.(value & flag & info ["ask-authors"]
           ~doc:"For REFUSE-classified worktrees, auto-DM the commit author \
                 asking if the worktree is still active. \
                 'superseded'/'done'/'gone' → reclassified GcRemovable. \
                 'active'/'keep'/'working' or timeout → stays REFUSE. \
                 Default timeout: 60s. Combined with --clean to also remove \
                 author-confirmed superseded worktrees.")
  in
  let interactive_flag =
    Arg.(value & flag & info ["interactive"]
           ~doc:"Interactive triage for REFUSE-classified worktrees. \
                 For each refused worktree, shows unmerged commits via git-cherry \
                 and prompts [D]elete / [S]kip / [I]nspect. \
                 Allows force-removing worktrees that auto-GC refuses \
                 (e.g. not ancestor of origin/master but content has landed). \
                 Cannot be combined with --json.")
  in
  let no_meta_filter_flag =
    Arg.(value & flag & info ["no-meta-filter"]
           ~doc:"Disable the meta-path filter: REFUSE-classified worktrees with \
                 only sitrep/collab/personal-log commits are NOT reclassified \
                 as REMOVABLE. Use this to only trust the git-ancestor and \
                 git-cherry equivalence checks.")
  in
  let strict_dirty_flag =
    Arg.(value & flag & info ["strict-dirty"]
           ~doc:"Disable dirty-path meta-ignorance: a worktree with any \
                 git-status output (even if only meta/artifact files like \
                 .sitreps/, volumes/, *.log, *.lock) is considered dirty. \
                 Default (without this flag): meta-only dirty paths are \
                 filtered, so a worktree dirty only due to build artifacts \
                 or sitrep logs is treated as clean.")
  in
  let parallel_flag =
    Arg.(value & flag & info ["parallel"; "P"]
           ~doc:"Use parallel scan (32 threads) for large worktree sets. \
                 Default: sequential.  With ~600 worktrees, parallel \
                 reduces scan time from ~5 min to ~15 s.")
  in
  let+ clean = clean_flag
  and+ json_out = json_flag
  and+ ignore_active = ignore_active_flag
  and+ path_prefix = path_prefix_flag
  and+ active_window_hours = active_window_flag
  and+ age_str = age_flag
  and+ verbose = verbose_flag
  and+ interactive = interactive_flag
  and+ ask_authors = ask_authors_flag
  and+ no_meta_filter = no_meta_filter_flag
  and+ strict_dirty = strict_dirty_flag
  and+ shared_orphan_threshold = shared_orphan_threshold_flag
  and+ parallel = parallel_flag in
  let meta_filter = not no_meta_filter in
  if interactive && json_out then begin
    Printf.eprintf "error: --interactive and --json are mutually exclusive.\n%!";
    exit 1
  end;
  if ask_authors && json_out then begin
    Printf.eprintf "error: --ask-authors and --json are mutually exclusive.\n%!";
    exit 1
  end;
  (* Parse --age value: "30d", "30", "7d" → float days *)
  let age_threshold_days =
    match age_str with
    | None -> None
    | Some s ->
        let s = String.trim s in
        let s = if s <> "" && s.[String.length s - 1] = 'd'
                then String.sub s 0 (String.length s - 1)
                else s in
        match float_of_string_opt s with
        | Some d when d > 0.0 -> Some d
        | _ ->
            Printf.eprintf "error: invalid --age value %S (expected e.g. 30d or 30)\n%!" s;
            None
  in
  let all_candidates =
    if parallel then
      scan_worktrees_for_gc_parallel ~ignore_active ~active_window_hours ~strict_dirt:strict_dirty ()
    else
      scan_worktrees_for_gc ~ignore_active ~active_window_hours
        ~strict_dirt:strict_dirty ~age_threshold_days ()
  in
  let candidates = match path_prefix with
    | None -> all_candidates
    | Some pfx ->
        List.filter
          (fun c ->
            let base = Filename.basename c.gc_path in
            String.length base >= String.length pfx
            && String.sub base 0 (String.length pfx) = pfx)
          all_candidates
  in
  (* Deduplicate shared orphans: reclassify REFUSE worktrees whose unmerged
     commits all appear in >threshold other worktrees. These are burn-distributed
     commits (sitrep/docs bursts from Apr 28-29) that exist identically across
     many worktrees — safe to GC once we know the content is shared. *)
  let candidates =
    if shared_orphan_threshold > 0 then
      deduplicate_shared_orphans ~threshold:shared_orphan_threshold candidates
    else candidates
  in
  (* Ask authors about REFUSE worktrees and reclassify based on responses *)
  let candidates =
    if ask_authors then
      let broker_root = resolve_broker_root () in
      let broker = C2c_mcp.Broker.create ~root:broker_root in
      ask_authors_and_reclassify ~broker ~timeout_s:60 ~verbose candidates
    else candidates
  in
  (* Meta-path filter: reclassify GcRefused → GcRemovable when all
     unmerged commits touch only meta paths (sitreps, collab docs, personal logs).
     The --no-meta-filter flag disables this pass. *)
  let candidates =
    if meta_filter then
      List.map (fun c ->
        match c.gc_status with
        | GcRefused { reason = _; unmerged_commits } when unmerged_commits <> [] ->
            (* All unmerged commits must be meta-only to reclassify *)
            let all_meta = List.for_all (fun (sha, _) ->
              commit_touches_noncode_paths ~cwd:c.gc_path sha
            ) unmerged_commits in
            if all_meta then
              { c with gc_status = GcRemovable
                         { reason = "all unmerged commits are meta-only (sitreps/docs)" } }
            else c
        | _ -> c)
      candidates
    else candidates
  in
  (* Age reclassification: REFUSE worktrees older than --age threshold get
     promoted to POSSIBLY_ACTIVE with a note about manual review.
     This makes --age useful for surfacing old abandoned branches
     without auto-deleting them. Applied after meta-path filter so
     GcRemovable worktrees (confirmed abandoned via meta commits) are
     preserved and not re-promoted. *)
  let candidates =
    match age_threshold_days with
    | None -> candidates
    | Some days ->
        let threshold_s = days *. 86400.0 in
        List.map (fun c ->
          match c.gc_status with
          | GcRefused { reason; unmerged_commits } ->
              (match head_age_seconds c.gc_path with
               | None -> c  (* can't determine age — keep REFUSE *)
               | Some age_s when age_s >= threshold_s ->
                   { c with gc_status = GcPossiblyActive
                              { reason = Printf.sprintf
                                  "older than %.0fd, consider manual review \
                                   (was REFUSE: %s)"
                                  days reason } }
               | Some _ -> c)  (* younger than threshold — keep REFUSE *)
          | _ -> c)
        candidates
  in
  (* Fresh-worktree protection: when --clean is passed, worktrees whose HEAD
     commit is younger than 30 minutes are promoted from GcRemovable to
     GcPossibly_ACTIVE — this is an absolute time-based guard that bypasses
     the admin-dir mtime heuristic. Prevents newly-created worktrees from
     being removed by --clean even if they appear "abandoned" by other signals.
     Applied after all other classification so GcRemovable is confirmed. *)
  let candidates =
    if clean then
      let fresh_threshold_s = 30.0 *. 60.0 in
      List.map (fun c ->
        match c.gc_status with
        | GcRemovable { reason } ->
            (match head_age_seconds c.gc_path with
             | None -> c  (* can't determine age — keep REMOVABLE *)
             | Some age_s when age_s < fresh_threshold_s ->
                 { c with gc_status = GcPossiblyActive
                            { reason = Printf.sprintf
                                "fresh worktree (HEAD %.0fmin old); --clean skipped \
                                 (was REMOVABLE: %s)"
                                (age_s /. 60.0) reason } }
             | Some _ -> c)  (* old enough — keep REMOVABLE *)
        | _ -> c)
      candidates
    else candidates
  in
  if interactive then begin
    ignore (interactive_triage ~candidates)
  end else if json_out then begin
    print_endline (Yojson.Safe.to_string (render_gc_json ~candidates))
  end else begin
    render_gc_human ~candidates ~clean ~verbose
  end;
  if clean && not interactive then begin
    let removable = List.filter (fun c ->
        match c.gc_status with GcRemovable _ -> true | _ -> false)
      candidates
    in
    let freed = ref 0L in
    let removed = ref 0 in
    if not json_out then
      Printf.printf "\nRemoving %d worktrees...\n" (List.length removable);
    List.iter (fun c ->
        if gc_remove_path c.gc_path then begin
          incr removed;
          freed := Int64.add !freed c.gc_size;
          if not json_out then
            Printf.printf "  removed %s\n" c.gc_path
        end else begin
          if not json_out then
            Printf.eprintf "  FAILED to remove %s\n" c.gc_path
        end)
      removable;
    if not json_out then
      Printf.printf "Done. %d removed, %s freed.\n" !removed (format_bytes !freed)
  end


(* --- subcommand: worktree shim-test-gc ---------------------------------
   Scans and (with --clean) deletes refs under refs/c2c-stashes/shim-test/.
   These are test-checkpoint refs created by test_git_shim.sh — they point to
   orphaned commits (never on any branch) so they accumulate silently.
   GC is safe: the commits are exclusively test fixtures, not user data. *)

type shim_test_entry = {
  ref_name: string;
  commit_sha: string;
  commit_age_days: int;
}

(** [list_shim_test_refs ()] returns all refs under refs/c2c-stashes/shim-test/
    with their target SHA and approximate age in days. *)
let list_shim_test_refs () =
  let (code, output, _) =
    git_command ~quiet:true
      [ "for-each-ref"; "--format=%(refname) %(objectname) %(creatordate:unix)";
        "refs/c2c-stashes/shim-test/" ]
  in
  if code <> 0 || String.trim output = "" then []
  else
    let now = Unix.gettimeofday () in
    let one_day = 86400.0 in
    List.filter_map (fun line ->
      match String.split_on_char ' ' line |> List.filter ((<>) "") with
      | [ref_name; sha; age_str] ->
          (try
             let age_unix = float_of_string age_str in
             let days = int_of_float ((now -. age_unix) /. one_day) in
             Some { ref_name; commit_sha = sha; commit_age_days = days }
           with _ -> None)
      | _ -> None)
      (String.split_on_char '\n' output)

(** [delete_shim_test_ref ref_name] deletes a single refs/c2c-stashes/shim-test/ ref. *)
let delete_shim_test_ref ref_name =
  let (code, _, _) = git_command [ "update-ref"; "-d"; ref_name ] in
  code = 0

let shim_test_gc_term =
  let open Cmdliner in
  let clean_flag =
    Arg.(value & flag & info ["clean"]
           ~doc:"Actually delete the refs. Default is dry-run.")
  in
  let json_flag =
    Arg.(value & flag & info ["json"]
           ~doc:"Output machine-readable JSON.")
  in
  let+ clean = clean_flag
  and+ json_out = json_flag in
  let entries = list_shim_test_refs () in
  if json_out then begin
    let items = List.map (fun e ->
      `Assoc [
        ("ref", `String e.ref_name);
        ("sha", `String e.commit_sha);
        ("age_days", `Int e.commit_age_days);
      ]) entries
    in
    print_endline (Yojson.Safe.to_string (`List items))
  end else begin
    Printf.printf "Shim-test refs GC (%d entries)\n\n" (List.length entries);
    if entries = [] then
      Printf.printf "  (no refs/c2c-stashes/shim-test/ entries)\n"
    else begin
      List.iter (fun e ->
        let age_str = if e.commit_age_days = 0 then "<1d"
          else if e.commit_age_days = 1 then "1d"
          else Printf.sprintf "%dd" e.commit_age_days in
        Printf.printf "  %-55s %s  (%s)\n" e.ref_name e.commit_sha age_str)
        entries;
      if clean then begin
        let deleted = ref 0 in
        Printf.printf "\nDeleting %d refs...\n" (List.length entries);
        List.iter (fun e ->
          if delete_shim_test_ref e.ref_name then begin
            incr deleted;
            Printf.printf "  deleted %s\n" e.ref_name
          end else
            Printf.eprintf "  FAILED to delete %s\n" e.ref_name)
          entries;
        Printf.printf "Done. %d deleted.\n" !deleted
      end else begin
        Printf.printf "\nDry-run: pass --clean to delete.\n"
      end
    end
  end

(* --- subcommand: worktree branch-clutter-gc (#522) -------------------------
   Scans .git/config for stale [branch "<name>"] entries whose
   remote-tracking refs (refs/remotes/origin/<name>) no longer exist.
   Such entries are left behind after a branch is deleted and git fetch --prune
   removes the origin/ ref, but the config section persists.

   Classification:
   - ORPHANED: no remote-tracking ref, no local ref → safe to remove
   - HAS_REMOTE: remote-tracking ref still exists → keep (active or unmerged)
   - HAS_LOCAL: local ref still exists → keep (still in use)
   - NO_REMOTE_CONFIG: entry exists but .remote is not "origin" → keep (custom)

   The ORPHANED category is always safe to remove (--clean). *)

type branch_entry = {
  name: string;
  has_remote: bool;    (* refs/remotes/origin/<name> exists *)
  has_local: bool;     (* refs/heads/<name> exists *)
  remote: string option; (* branch.<name>.remote value *)
}

let get_git_config_branch_entries () =
  (* Read all branch.<name>.* entries via --list and filter to .remote keys *)
  let (code, output, _) = git_command ~quiet:true
    [ "config"; "--list" ]
  in
  if code <> 0 || String.trim output = "" then []
  else begin
    let entries = ref [] in
    let prefix = "branch." in
    let suffix = ".remote" in
    List.iter (fun line ->
      if String.length line < String.length prefix + String.length suffix + 2 then ()
      else
        let eq_idx = try String.index line '=' with Not_found -> -1 in
        if eq_idx < 0 then ()
        else
          let key = String.sub line 0 eq_idx in
          let value = String.sub line (eq_idx + 1) (String.length line - eq_idx - 1) in
          (* Check if key ends with ".remote" *)
          let key_len = String.length key in
          let suff_len = String.length suffix in
          if key_len < suff_len + 1 then ()
          else if String.sub key (key_len - suff_len) suff_len <> suffix then ()
          else
            let name = String.sub key (String.length prefix)
              (key_len - String.length prefix - suff_len) in
            (* Skip empty names *)
            if name = "" then ()
            else
              (* Check if remote-tracking ref exists *)
              let remote_ref = "refs/remotes/origin/" ^ name in
              let (rc_rt, _, _) = git_command ~quiet:true
                [ "rev-parse"; "--verify"; "--quiet"; remote_ref ]
              in
              (* Check if local ref exists *)
              let local_ref = "refs/heads/" ^ name in
              let (rc_loc, _, _) = git_command ~quiet:true
                [ "rev-parse"; "--verify"; "--quiet"; local_ref ]
              in
              entries := {
                name;
                has_remote = (rc_rt = 0);
                has_local = (rc_loc = 0);
                remote = Some value;
              } :: !entries)
      (String.split_on_char '\n' output);
    List.rev !entries
  end

let remove_branch_config name =
  (* Remove all branch.<name>.* keys from config *)
  let (code, _, _) = git_command
    [ "config"; "--remove-section"; "branch." ^ name ]
  in
  code = 0

let branch_clutter_gc_term =
  let open Cmdliner in
  let clean_flag =
    Arg.(value & flag & info ["clean"]
           ~doc:"Actually remove the ORPHANED entries. Default is dry-run.")
  in
  let json_flag =
    Arg.(value & flag & info ["json"]
           ~doc:"Output machine-readable JSON.")
  in
  let+ clean = clean_flag
  and+ json_out = json_flag in
  let entries = get_git_config_branch_entries () in
  let orphaned = List.filter (fun e ->
      (not e.has_remote) && (not e.has_local) &&
      e.remote = Some "origin") entries
  in
  let has_remote = List.filter (fun e -> e.has_remote) entries in
  let has_local = List.filter (fun e -> e.has_local) entries in
  let no_remote_config = List.filter (fun e ->
      e.remote <> Some "origin" && not e.has_remote && not e.has_local) entries
  in
  if json_out then begin
    let item e status =
      `Assoc [("name", `String e.name); ("status", `String status)]
    in
    let json = `Assoc [
      ("orphaned", `List (List.map (fun e -> item e "orphaned") orphaned));
      ("has_remote", `List (List.map (fun e -> item e "has_remote") has_remote));
      ("has_local", `List (List.map (fun e -> item e "has_local") has_local));
      ("no_remote_config", `List (List.map (fun e -> item e "no_remote_config") no_remote_config));
    ] in
    print_endline (Yojson.Safe.to_string json)
  end else begin
    Printf.printf "Branch config GC — %d entries found\n\n" (List.length entries);
    Printf.printf "  ORPHANED (safe to --clean): %d\n"
      (List.length orphaned);
    List.iter (fun e ->
        Printf.printf "    %s\n" e.name)
      orphaned;
    if has_remote <> [] then begin
      Printf.printf "\n  HAS_REMOTE (keep): %d\n" (List.length has_remote);
      List.iter (fun e ->
          Printf.printf "    %s\n" e.name)
        (List.rev (List.rev has_remote))
    end;
    if has_local <> [] then begin
      Printf.printf "\n  HAS_LOCAL (keep): %d\n" (List.length has_local);
      List.iter (fun e ->
          Printf.printf "    %s\n" e.name)
        (List.rev (List.rev has_local))
    end;
    if no_remote_config <> [] then begin
      Printf.printf "\n  NO_REMOTE_CONFIG (keep): %d\n"
        (List.length no_remote_config);
      List.iter (fun e ->
          Printf.printf "    %s (remote=%s)\n" e.name
            (match e.remote with Some r -> r | None -> "?"))
        (List.rev (List.rev no_remote_config))
    end;
    if clean then begin
      if orphaned <> [] then begin
        Printf.printf "\nRemoving %d orphaned entries...\n"
          (List.length orphaned);
        let removed = ref 0 in
        List.iter (fun e ->
          if remove_branch_config e.name then begin
            incr removed;
            Printf.printf "  removed %s\n" e.name
          end else
            Printf.eprintf "  FAILED to remove %s\n" e.name)
          orphaned;
        Printf.printf "Done. %d removed.\n" !removed
      end else
        Printf.printf "\nNo orphaned entries to remove.\n"
    end else
      Printf.printf "\nDry-run: pass --clean to remove orphaned entries.\n"
  end

let worktree_group =
  Cmdliner.Cmd.group
    ~default:worktree_list_term
    (Cmdliner.Cmd.info "worktree" ~doc:"Manage per-agent git worktrees.")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List all worktrees.") worktree_list_term
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "prune" ~doc:"Remove stale worktree entries.") worktree_prune_term
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "setup" ~doc:"Create an isolated git worktree for this agent.") worktree_setup_term
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "status" ~doc:"Show current worktree state.") worktree_status_term
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "start" ~doc:"Create an isolated git worktree for a new slice, branched from origin/master.") worktree_start_term
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "check-bases" ~doc:"Check all worktrees for stale origin/master bases.") worktree_check_bases_term
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "gc"
        ~doc:"Detect and (with --clean) remove worktrees safe to delete: \
              clean working tree, HEAD ancestor of origin/master, no live \
              process holding cwd, and not the main worktree (#313).")
        worktree_gc_term
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "branch-clutter-gc"
        ~doc:"Audit and (with --clean) remove orphaned [branch \"<name>\"] \
              entries from .git/config whose remote-tracking refs no longer exist.")
        branch_clutter_gc_term
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "shim-test-gc"
        ~doc:"List and (with --clean) delete refs/c2c-stashes/shim-test/ \
              checkpoint refs. These are test fixtures from test_git_shim.sh, \
              not user data — GC is always safe.")
        shim_test_gc_term
    ]
