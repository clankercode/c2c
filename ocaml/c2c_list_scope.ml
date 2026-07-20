(* c2c_list_scope — cwd-scope filtering for peer discovery on the shared
   `default` broker (#74).

   The `default` broker is a machine-wide junk drawer: every agent launched
   outside a git repo lands there, so unrelated agents in unrelated directories
   all see each other as peers (215 rows on one host, 209 with real non-repo
   cwds). Real repo brokers are already partitioned by fingerprint and do NOT
   need this filter — applying it there would hide same-repo worktree peers
   from each other (`git rev-parse --show-toplevel` differs per worktree while
   they share one fingerprint broker).

   Default `c2c list` / MCP `list` therefore hide rows whose registration
   `cwd` is NOT the current scope directory (or a subdirectory of it), BUT
   only when the listing's broker root is the `default` fingerprint broker.
   Scope directory = the git toplevel when the process is inside a repo, else
   the current working directory. CLI `--all` / `--global` / `--cross-repo`
   bypass the filter; MCP `include_all:true` does the same.

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

(* True when [broker_root] is the machine-wide `default` fingerprint broker.
   Layout is `.../repos/<fp>/broker`, so the fingerprint is the basename of
   the parent of the broker directory. Pure/lexical. *)
let is_default_broker_root (broker_root : string) : bool =
  let root = normalize_dir broker_root in
  if root = "" then false
  else
    let parent = Filename.dirname root in
    let fp = Filename.basename parent in
    fp = "default"

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

(* Apply the #74 filter when the broker is the shared `default` junk drawer
   and the caller has not opted out. Returns (kept, hidden_count). Pure
   except for [resolve_scope_dir] when filtering actually runs. *)
let maybe_filter_default_broker ~(broker_root : string) ~(apply : bool)
    ~(cwd_of : 'a -> string option) (rows : 'a list) : 'a list * int =
  if (not apply) || not (is_default_broker_root broker_root) then (rows, 0)
  else
    let scope_dir = resolve_scope_dir () in
    let (in_scope, hidden) = partition_by_scope ~scope_dir ~cwd_of rows in
    (in_scope, List.length hidden)
