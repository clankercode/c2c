(* c2c_list_scope — repo-scope filtering for `c2c list` (#74).

   The `default` broker (and any busy repo broker) accumulates hundreds of
   unrelated agents that all landed in the same broker because they ran outside
   a git repo. Peer discovery there is meaningless: `c2c list` shows every
   agent that ever ran outside a repo on this machine, regardless of which
   directory it was in.

   The default `c2c list` therefore hides rows whose registration `cwd` is
   NOT the current scope directory (or a subdirectory of it). Scope directory =
   the git toplevel when the process is inside a repo, else the current working
   directory. `--all` (and `--global` / `--cross-repo`) bypass the filter.

   Fail-open: a row with NO cwd metadata is always SHOWN — never hide a
   possibly-live peer just because it lacks metadata. Per #74 the bulk of the
   noise DOES carry cwd (209/215 default rows), so cwd-filtering removes it
   without touching unclassifiable rows.

   These helpers are deliberately PURE (lexical, no filesystem) so they can be
   unit-tested directly; [resolve_scope_dir] is the only impure entry point. *)

(* Strip trailing slashes for a lexical directory comparison, keeping a lone
   "/" for the filesystem root. Whitespace-trimmed first. No filesystem access
   (no realpath) — cwd values are captured via [Sys.getcwd ()] at register time
   and are already absolute/canonical, and the scope dir comes from git
   toplevel or getcwd, so a lexical prefix test is correct and deterministic. *)
let normalize_dir (d : string) : string =
  let d = String.trim d in
  let n = String.length d in
  if n = 0 then ""
  else begin
    let last = ref (n - 1) in
    while !last > 0 && d.[!last] = '/' do decr last done;
    if !last = 0 && d.[0] = '/' then "/" else String.sub d 0 (!last + 1)
  end

(* row_in_scope: is a row whose registration cwd is [row_cwd] in scope for a
   listing anchored at [scope_dir]?
   - [None] or an empty/blank cwd → true (fail-open; never hide an
     unclassifiable, possibly-live peer).
   - otherwise → true iff the row cwd equals the scope dir or is a
     subdirectory of it (lexical prefix on the trailing-slash-normalized
     paths, so "/a/src" does NOT match scope "/a/s"). *)
let row_in_scope ~(scope_dir : string) ~(row_cwd : string option) : bool =
  match row_cwd with
  | None -> true
  | Some c when String.trim c = "" -> true
  | Some c ->
      let scope = normalize_dir scope_dir in
      if scope = "" then true
      else
        let c = normalize_dir c in
        c = scope || String.starts_with ~prefix:(scope ^ "/") c

(* Partition [rows] into (in_scope, hidden) using [cwd_of] to extract each
   row's registration cwd. [cwd_of] keeps this generic over the registration
   record so it is trivially unit-testable without constructing one. *)
let partition_by_scope ~(scope_dir : string) ~(cwd_of : 'a -> string option)
    (rows : 'a list) : 'a list * 'a list =
  List.partition (fun r -> row_in_scope ~scope_dir ~row_cwd:(cwd_of r)) rows

(* The scope directory for the current process: git toplevel when inside a
   repo, else the current working directory. Impure. *)
let resolve_scope_dir () : string =
  match Git_helpers.git_repo_toplevel () with
  | Some d -> d
  | None -> (try Sys.getcwd () with _ -> "")
