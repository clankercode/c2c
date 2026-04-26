(* c2c_worktree.ml — git worktree management helpers for per-agent isolation. *)

open Cmdliner.Term.Syntax

let ( // ) = Filename.concat

let rec mkdir_p dir =
  if dir = "/" || dir = "." || dir = "" then ()
  else if Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

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

(** [worktree_behind_origin ~wt_path ~threshold] checks if the worktree at [wt_path]
    is [threshold] or more commits behind origin/master.
    Returns a warning message if so, None otherwise. *)
let worktree_behind_origin ?(threshold=5) ~(wt_path:string) : string option =
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
    match worktree_behind_origin ~threshold:5 ~wt_path with
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

(** [is_dirty path] returns true if the worktree at [path] has any
    uncommitted changes (per `git status --porcelain`). *)
let is_dirty path =
  let (_, out, _) = git_command ~cwd:path ~quiet:true [ "status"; "--porcelain" ] in
  String.trim out <> ""

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
  | GcRefused of { reason : string }

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

(** [classify_worktree ~ignore_active (alias, path, branch)] runs the
    four refuse-checks and returns a [gc_candidate]. *)
let classify_worktree ~main_path ~ignore_active (_alias, path, branch) =
  let size = worktree_size_bytes path in
  let mk st = { gc_path = path; gc_branch = branch; gc_size = size; gc_status = st } in
  (* Defense-in-depth: never offer the main worktree even if list_worktrees
     surfaced it. *)
  if (match main_path with
      | Some mp ->
          let p_norm = try Unix.realpath path with _ -> path in
          let m_norm = try Unix.realpath mp with _ -> mp in
          p_norm = m_norm
      | None -> false) then
    mk (GcRefused { reason = "main worktree (never offered)" })
  else if is_dirty path then
    mk (GcRefused { reason = "dirty working tree" })
  else if not (head_ancestor_of_origin_master path) then
    mk (GcRefused { reason = "HEAD not ancestor of origin/master" })
  else
    let holders = if ignore_active then [] else cwd_holders path in
    match holders with
    | [] -> mk (GcRemovable { reason = "ancestor of origin/master, clean" })
    | (pid, cmd) :: _ ->
        let snippet =
          if String.length cmd > 60 then String.sub cmd 0 60 ^ "…" else cmd
        in
        mk (GcRefused { reason = Printf.sprintf "active cwd: pid=%d (%s)" pid snippet })

(** [scan_worktrees_for_gc ~ignore_active ()] enumerates worktrees under
    .worktrees/ and classifies each. The main worktree is filtered out
    early (defense-in-depth: classify_worktree also refuses it). *)
let scan_worktrees_for_gc ~ignore_active () =
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
  let candidates =
    List.filter
      (fun (_, path, _) ->
        let p_norm = try Unix.realpath path with _ -> path in
        (match main_norm with
         | Some mn -> p_norm <> mn
         | None -> true)
        && (let prefix = repo_root // ".worktrees" in
            String.length p_norm > String.length prefix
            && String.sub p_norm 0 (String.length prefix) = prefix))
      entries
  in
  List.map (classify_worktree ~main_path ~ignore_active) candidates

(** [gc_remove_path path] removes a worktree via `git worktree remove`.
    Returns true on success. *)
let gc_remove_path path =
  let (code, _, _) = git_command [ "worktree"; "remove"; path ] in
  code = 0

let render_gc_human ~candidates ~clean =
  let removable = List.filter (fun c ->
      match c.gc_status with GcRemovable _ -> true | _ -> false)
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
        | GcRefused _ -> ""
      in
      Printf.printf "  %-50s %-30s %s\n" c.gc_path c.gc_branch r)
    removable;
  Printf.printf "\nREFUSE (%d worktrees):\n" (List.length refused);
  List.iter (fun c ->
      let r = match c.gc_status with
        | GcRefused { reason } -> reason
        | GcRemovable _ -> ""
      in
      Printf.printf "  %-50s %-30s REFUSE: %s\n" c.gc_path c.gc_branch r)
    refused;
  if not clean then
    Printf.printf "\nRun with --clean to remove the REMOVABLE set. (Dry-run by default.)\n"

let render_gc_json ~candidates =
  let item c =
    let base =
      [ ("path", `String c.gc_path)
      ; ("branch", `String c.gc_branch)
      ; ("size_bytes", `String (Int64.to_string c.gc_size))
      ]
    in
    match c.gc_status with
    | GcRemovable { reason } ->
        `Assoc (base @ [ ("status", `String "removable")
                       ; ("reason", `String reason) ])
    | GcRefused { reason } ->
        `Assoc (base @ [ ("status", `String "refused")
                       ; ("refuse_reason", `String reason) ])
  in
  let removable = List.filter (fun c ->
      match c.gc_status with GcRemovable _ -> true | _ -> false)
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
         ; ("total_bytes", `String (Int64.to_string (sum_size candidates)))
         ])
    ; ("removable", `List (List.map item removable))
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
  let+ clean = clean_flag
  and+ json_out = json_flag
  and+ ignore_active = ignore_active_flag
  and+ path_prefix = path_prefix_flag in
  let all_candidates = scan_worktrees_for_gc ~ignore_active () in
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
  if json_out then begin
    print_endline (Yojson.Safe.to_string (render_gc_json ~candidates))
  end else begin
    render_gc_human ~candidates ~clean
  end;
  if clean then begin
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
        worktree_gc_term ]
