(* c2c_repo_fp.ml — shared repo fingerprint + broker root resolution.
   Lives in c2c_mcp library; used by c2c_start and c2c_utils. *)

let ( // ) = Filename.concat

(** {1 Repo fingerprint}

    The fingerprint is runtime-stable (git remote URL or toplevel path never
    change during a process lifetime). Memoize after first computation so we
    call git at most once per process, not once per RPC dispatch. *)

(** Uncached computation — shells out to git. Exposed for tests that need
    to force recomputation with a different git state. *)
let repo_fingerprint_uncached () =
  let data =
    match Git_helpers.git_first_line ~suppress_stderr:true ["config"; "--get"; "remote.origin.url"] with
    | Some url when url <> "" -> url
    | _ ->
        (match Git_helpers.git_repo_toplevel () with
         | Some t -> t
         | None -> "")
  in
  if data = "" then "default"
  else
    let hash = Digestif.SHA256.digest_string data in
    let hex = Digestif.SHA256.to_hex hash in
    String.sub hex 0 12

(** Memoized fingerprint — one git shell-out per process lifetime. *)
let repo_fingerprint =
  let cache = ref None in
  fun () ->
    match !cache with
    | Some v -> v
    | None ->
        let v = repo_fingerprint_uncached () in
        cache := Some v; v

(** XDG_STATE_HOME per XDG spec, with HOME fallback.
    Duplicated here because c2c_utils (CLI executable) can't be called from
    the library (c2c_mcp).
    NOTE: no longer consulted for broker-root resolution (see
    [resolve_broker_root_fallback]) — kept for the HOME-unset last resort
    and the XDG-profile split-brain detection below. *)
let xdg_state_home () =
  match Sys.getenv_opt "XDG_STATE_HOME" with
  | Some v when String.trim v <> "" -> String.trim v
  | _ ->
      (match Sys.getenv_opt "HOME" with
       | Some h when String.trim h <> "" -> String.trim h // ".local" // "state"
       | _ -> "/tmp")

(** C2C_STATE_HOME — c2c-specific state-relocation escape hatch. Unlike
    XDG_STATE_HOME (which agent harnesses repurpose per-profile, e.g. Claude
    Code profile-share exports XDG_STATE_HOME=~/.local/state/cc-p, silently
    fragmenting the machine-wide message bus), this var is only ever set by
    operators who genuinely want to relocate c2c state. *)
let c2c_state_home () =
  match Sys.getenv_opt "C2C_STATE_HOME" with
  | Some v when String.trim v <> "" -> Some (String.trim v)
  | _ -> None

(** Broker-root fallback path — pure; computes the path without consulting
    C2C_MCP_BROKER_ROOT and without emitting warnings.
    Order: C2C_STATE_HOME (explicit relocation) → $HOME/.c2c (canonical)
    → XDG default (HOME unset last resort).
    Generic XDG_STATE_HOME is deliberately NOT honored here: per-profile
    XDG overrides split the machine-wide broker (peers become invisible to
    each other). See #9 / 2026-07-06 split-brain incident. *)
let resolve_broker_root_fallback_path () =
  let fp = repo_fingerprint () in
  match c2c_state_home () with
  | Some s -> s // "c2c" // "repos" // fp // "broker"
  | None ->
      (match Sys.getenv_opt "HOME" with
       | Some h when String.trim h <> "" ->
           String.trim h // ".c2c" // "repos" // fp // "broker"
       | _ ->
           (* No HOME: XDG default chain (ultimately /tmp). *)
           xdg_state_home () // "c2c" // "repos" // fp // "broker")

(** Detect an XDG-profile broker that the resolver no longer selects.
    Returns [Some xdg_broker_path] when ALL of:
    - C2C_STATE_HOME is unset (operator did not explicitly relocate),
    - XDG_STATE_HOME is set,
    - $XDG_STATE_HOME/c2c/repos/<fp>/broker differs from the resolved
      fallback path, and
    - that XDG-profile broker contains a registry.json (real broker data —
      an empty dir is not split-brain).
    Used for the one-line stderr warning below and by `c2c health` /
    `c2c doctor` split-brain reporting. *)
let xdg_split_brain_broker () =
  match c2c_state_home () with
  | Some _ -> None
  | None ->
      (match Sys.getenv_opt "XDG_STATE_HOME" with
       | Some xdg when String.trim xdg <> "" ->
           let fp = repo_fingerprint () in
           let xdg_broker =
             String.trim xdg // "c2c" // "repos" // fp // "broker" in
           if xdg_broker <> resolve_broker_root_fallback_path ()
              && Sys.file_exists (xdg_broker // "registry.json")
           then Some xdg_broker
           else None
       | _ -> None)

(** One-line, once-per-process stderr warning when an orphaned XDG-profile
    broker exists. Goes to stderr only, so --json stdout is never polluted
    (same convention as the legacy-path warning in resolve_broker_root). *)
let xdg_split_brain_warned = ref false

let warn_xdg_split_brain () =
  if not !xdg_split_brain_warned then
    match xdg_split_brain_broker () with
    | Some xdg_broker ->
        xdg_split_brain_warned := true;
        Printf.eprintf
          "[WARNING] c2c broker data exists at XDG-profile path %s but the canonical root is %s — run 'c2c migrate-broker' to merge it (details: c2c doctor).\n%!"
          xdg_broker (resolve_broker_root_fallback_path ())
    | None -> ()

(** Broker-root fallback — computes the path without consulting C2C_MCP_BROKER_ROOT.
    Shared between resolve_broker_root (step 1 = env var) and
    resolve_broker_root_canonical (steps 2-4 = what we'd get without the env var).
    Emits the split-brain stderr warning (once per process) as a side effect. *)
let resolve_broker_root_fallback () =
  let p = resolve_broker_root_fallback_path () in
  warn_xdg_split_brain ();
  p

(** Check if a broker-root path matches the pre-#294 legacy layout
    (`<git-common-dir>/c2c/mcp`). Inline version of
    [C2c_broker_root_check.is_legacy_broker_root] to avoid a circular
    dependency (that module lives in the cli library). *)
let is_legacy_path path =
  let p = String.trim path in
  if p = "" then false
  else
    let needle = ".git" // "c2c" // "mcp" in
    let plen = String.length p and nlen = String.length needle in
    let rec loop i =
      if i + nlen > plen then false
      else if String.sub p i nlen = needle then true
      else loop (i + 1)
    in
    loop 0

(** Broker-root path resolution.
    Resolution order (2026-07-06, was coord1 2026-04-26 — generic
    XDG_STATE_HOME dropped to fix per-profile split-brain):
      1. C2C_MCP_BROKER_ROOT env var (explicit override)
      2. $C2C_STATE_HOME/c2c/repos/<fp>/broker  (if C2C_STATE_HOME set —
         c2c-specific relocation escape hatch)
      3. $HOME/.c2c/repos/<fp>/broker  (canonical default)
      4. ~/.local/state/c2c/repos/<fp>/broker  (HOME unset: XDG default fallback)
    The broker directory is created lazily on first use via Broker.ensure_root.

    When C2C_MCP_BROKER_ROOT points to a legacy .git/c2c/mcp path, the env
    var is ignored and the canonical fallback path is used instead. This
    prevents split-brain where different processes silently write to
    different registries. *)
let resolve_broker_root () =
  match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
  | Some dir when String.trim dir <> "" ->
      let p = String.trim dir in
      let abs_p = if Filename.is_relative p then Sys.getcwd () // p else p in
      if is_legacy_path abs_p then begin
        let canonical = resolve_broker_root_fallback () in
        Printf.eprintf
          "[WARNING] C2C_MCP_BROKER_ROOT points to legacy .git/c2c/mcp path.\n\
           \  Current value: %s\n\
           \  Canonical path: %s\n\
           \  Using canonical path to prevent split-brain.\n\
           \  To fix: unset C2C_MCP_BROKER_ROOT, or run: c2c migrate-broker\n%!"
          abs_p canonical;
        canonical
      end else abs_p
  | _ -> resolve_broker_root_fallback ()

(** Same as resolve_broker_root but always uses the fallback chain (steps 2-4),
    ignoring C2C_MCP_BROKER_ROOT. Used to detect stale env-var exports. *)
let resolve_broker_root_canonical () = resolve_broker_root_fallback ()

(** Global session-addressed broker root.

    This is intentionally not repo-fingerprinted: Claude PostToolUse payloads
    carry a real session_id even for sessions that never initialized c2c, so
    the rendezvous point must be fixed across repos and across processes.

    Resolution order (Option A, 2026-06-20):
      1. C2C_SESSIONS_BROKER_ROOT env var (explicit override)
      2. $HOME/.c2c/sessions/broker  (canonical pinned rendezvous)
      3. ~/.c2c/sessions/broker      (HOME unset fallback, relative to cwd)
 *)
let resolve_sessions_broker_root () =
  match Sys.getenv_opt "C2C_SESSIONS_BROKER_ROOT" with
  | Some dir when String.trim dir <> "" ->
      let p = String.trim dir in
      if Filename.is_relative p then Sys.getcwd () // p else p
  | _ ->
      (match Sys.getenv_opt "HOME" with
       | Some h when String.trim h <> "" ->
           String.trim h // ".c2c" // "sessions" // "broker"
       | _ -> ".c2c" // "sessions" // "broker")

(** {1 Scan all known broker roots for --global listing}

    Returns all broker-root directories discovered under both XDG and HOME
    canonical locations. Each entry is (fingerprint, absolute_path).
    Only directories containing a registry.json are included — empty or stale
    broker roots are filtered out. *)

let list_all_broker_roots () =
  let fp_to_paths = Hashtbl.create 8 in
  let consider_path fp path =
    if Sys.file_exists (path // "registry.json") then begin
      let existing = try Hashtbl.find fp_to_paths fp with Not_found -> "" in
      if existing = "" then Hashtbl.add fp_to_paths fp path
    end
  in
  let scan_repos_dir repos_dir =
    try
      Array.iter
        (fun fp -> consider_path fp (repos_dir // fp // "broker"))
        (Sys.readdir repos_dir)
    with Sys_error _ -> ()
  in
  (* $C2C_STATE_HOME/c2c/repos/<fp>/broker — explicit relocation (first win) *)
  (match c2c_state_home () with
   | Some s -> scan_repos_dir (s // "c2c" // "repos")
   | None -> ());
  (* ~/.c2c/repos/<fp>/broker — canonical default *)
  (match Sys.getenv_opt "HOME" with
   | Some h when String.trim h <> "" ->
       scan_repos_dir (String.trim h // ".c2c" // "repos")
   | _ -> ());
  (* $XDG_STATE_HOME/c2c/repos/<fp>/broker — XDG overrides / last resort *)
  let xdg = xdg_state_home () in
  if xdg <> "" then scan_repos_dir (xdg // "c2c" // "repos");
  (* Collect into sorted (fp, path) list *)
  let results = ref [] in
  Hashtbl.iter (fun fp path -> results := (fp, path) :: !results) fp_to_paths;
  List.sort (fun (fp_a, _) (fp_b, _) -> String.compare fp_a fp_b) !results
