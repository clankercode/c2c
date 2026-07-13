(* c2c_doctor_hooks.ml — `c2c doctor hooks` implementation.

   Detects dangling Claude hook scripts referenced by settings.json /
   settings.local.json. A typical failure mode is a profile-share migration
   that symlinks ~/.claude/hooks -> ~/.claude-shared/hooks but leaves the
   shared directory empty: the PostToolUse hook entry still points at an
   absolute path under ~/.claude/hooks that no longer resolves.

   The check is read-only and never raises: missing or unparseable config
   files are counted as skipped. *)

open Cmdliner.Term.Syntax

let ( // ) = Filename.concat

(* --- types ---------------------------------------------------------------- *)

type dangling = {
  config_file : string;
  event : string;
  command_path : string;
}

type dir_result = {
  dir : string;
  referenced : int;
  dangling : dangling list;
  skipped : int;
}

type agy_result = {
  installed : bool;
  skill_exists : bool;
  hooks_exists : bool;
  has_c2c_hooks : bool;
  alias_prefix_ok : bool;
  alias_prefix_reason : string option;
}

type result = {
  dirs : dir_result list;
  total_referenced : int;
  total_dangling : int;
  total_skipped : int;
  codex : codex_result;
  agy : agy_result;
}

and block_diff = {
  line : int;
  expected : string;
  actual : string;
}

and managed_block_status =
  | Not_installed
  | Current
  | Missing
  | Stale

and managed_block_result = {
  label : string;
  path : string;
  status : managed_block_status;
  reason : string;
  refresh_command : string option;
  first_diff : block_diff option;
}

and codex_result = {
  installed : bool;
  config : managed_block_result;
  agents_md : managed_block_result;
  total_issues : int;
  trust_index_drift : bool;
}

(* --- Codex delivery-mode classification (P1.M1.E1.T005) -------------------- *)
(*

   One shared vocabulary for `c2c doctor`, `c2c dev instances`, and `c2c
   status`:

     app-server              healthy app-server-backed remote TUI (T002/T006,
                             online-attached only). The transport's delivery
                             stack — arrival-time data injection (draft-safe,
                             T003/T004) + one gated turn for eligible LOCAL
                             mail when the thread is idle and DND is off
                             (T007) — is library-proven; until the
                             supervision wiring slice lands, the session's
                             live inbound path is still the hook fallback and
                             the summary states that explicitly.
     app-server-unavailable  an app-server launch was attempted but failed
                             (codex too old / capability probe failed / spawn
                             failure). Live delivery, if any, is the hook
                             boundary.
     hooks+wake              legacy input-injecting idle wake: hook-boundary
                             delivery plus a watcher that TYPES a nudge line
                             into an idle tmux/herdr pane so the injected
                             turn's hook drains.
     hooks                   hook-boundary delivery only (session activity /
                             turn boundaries) — an idle session does not see
                             mail until its next turn.
     unavailable             no codex delivery path configured at all.

   None of these is "instant"/arrival-time transcript delivery except the
   app-server injection path, and even there the model reads the injected
   items on its next turn. The classifier is pure (inputs injected) so it is
   unit-testable; the live gather is read-only — doctor observes and explains,
   it never mutates. It never reads or prints endpoints, tokens, or message
   bodies. *)

type codex_delivery_mode =
  | Cd_app_server
  | Cd_app_server_degraded  (* online-attached but the deliver loop never loaded a thread (B138) *)
  | Cd_app_server_unavailable
  | Cd_hooks_wake
  | Cd_hooks_only
  | Cd_unavailable

type codex_delivery = {
  cd_mode : codex_delivery_mode;
  cd_summary : string;
  cd_remediation : string option;
  cd_input_injecting : bool;
}

type codex_instance_delivery = {
  ci_name : string;
  ci_app_server_status : string option;
  ci_delivery : codex_delivery;
}

type codex_delivery_report = {
  cdr_default : codex_delivery; (* vanilla codex session on this machine *)
  cdr_instances : codex_instance_delivery list;
}

let codex_delivery_mode_label = function
  | Cd_app_server -> "app-server"
  | Cd_app_server_degraded -> "app-server (degraded: no thread loaded)"
  | Cd_app_server_unavailable -> "app-server-unavailable"
  | Cd_hooks_wake -> "hooks+wake"
  | Cd_hooks_only -> "hooks"
  | Cd_unavailable -> "unavailable"

(* Pure classifier. [app_server_status] is the T006 lifecycle status string
   for a managed instance ("starting" / "online-attached" / "offline" /
   "failed-startup"), or [None] for a vanilla session / no app-server record.
   An "offline" record classifies like [None]: the app-server unit ended, so
   the live question is what the hook fallback provides. *)
let classify_codex_hook_fallback ~(hooks_installed : bool)
    ~(wake_target : bool) : codex_delivery =
  if not hooks_installed then
    { cd_mode = Cd_unavailable;
      cd_summary =
        "no codex delivery path is configured (no c2c hooks block in \
         ~/.codex/config.toml, no app-server session)";
      cd_remediation = Some "run `c2c install codex`";
      cd_input_injecting = false }
  else if wake_target then
    { cd_mode = Cd_hooks_wake;
      cd_summary =
        "legacy input-injecting idle wake: hooks deliver at hook \
         boundaries, and when the session idles in a tmux/herdr pane the \
         wake watcher TYPES a one-line nudge into that pane so the \
         injected turn's hook drains the inbox. Delivery is \
         hook-boundary, not arrival-time";
      cd_remediation =
        Some "this input-injecting wake is the idle path for the hook \
              fallback; the default managed path (`c2c start codex`, \
              app-server transport) is the injection-free, draft-safe \
              arrival-time delivery when codex >= 0.144 is available";
      cd_input_injecting = true }
  else
    { cd_mode = Cd_hooks_only;
      cd_summary =
        "hook-boundary delivery only: messages surface when a codex hook \
         fires (session activity / turn boundaries); an idle session \
         does not see mail until its next turn";
      cd_remediation =
        Some "run the session inside tmux/herdr to enable idle wake \
              (or use `c2c start codex` on codex >= 0.144 — the default \
              app-server transport delivers arrival-time without hooks)";
      cd_input_injecting = false }

let classify_codex_delivery ~(app_server_status : string option)
    ~(degraded : bool) ~(hooks_installed : bool) ~(wake_target : bool)
    : codex_delivery =
  match app_server_status with
  | Some "online-attached" when degraded ->
      (* B138: the app-server transport is attached (authenticated loopback,
         live pid) BUT the managed deliver loop is DEGRADED — it registered and
         supervises the session yet never discovered a frontend thread to inject
         into, so inbound c2c mail is NOT actually being delivered this session.
         This is NOT a healthy LIVE path: report it distinctly with actionable
         remediation instead of overclaiming app-server LIVE. Persisted signal
         written by C2c_codex_deliver_loop / run_delivery_loop. *)
      { cd_mode = Cd_app_server_degraded;
        cd_summary =
          "app-server remote TUI is attached (transport online-attached over the \
           authenticated loopback boundary) BUT the managed delivery loop is \
           DEGRADED: no Codex thread has ever loaded, so the loop has nothing to \
           inject into and inbound c2c mail is NOT being auto-delivered this \
           session (the session is still supervised) (B138)";
        cd_remediation =
          Some "the app-server is attached but no Codex thread has loaded; open \
                or focus a thread in the remote TUI so the delivery loop can \
                discover it and inject inbound mail (`c2c dev diag <name>` shows \
                the live loop state)";
        cd_input_injecting = false }
  | Some "online-attached" ->
      (* Healthy TRANSPORT + LIVE delivery (B131). The remote TUI is attached
         over the authenticated loopback boundary AND the managed supervisor now
         drives the proven arrival-time data-injection + gated auto-turn loop
         against this session, with a frontend thread loaded (not degraded).
         Inbound c2c mail is auto-delivered (draft-safe data injection) and
         eligible LOCAL mail auto-turns when the thread is idle and DND is off —
         no hook boundary needed. This is a healthy path; no remediation. The
         delivery is data-injection, never input-injection. *)
      { cd_mode = Cd_app_server;
        cd_summary =
          "healthy app-server remote TUI (transport online-attached over the \
           authenticated loopback boundary) with LIVE managed delivery: inbound \
           c2c mail is auto-injected as arrival-time DATA (draft-safe — the \
           operator's composer is never touched) and eligible LOCAL mail starts \
           one gated auto-turn when the thread is idle and DND is off (B131)";
        cd_remediation = None;
        cd_input_injecting = false }
  | Some "starting" ->
      (* Not yet a healthy remote TUI — the frontend has not attached. Report
         the delivery the session actually has right now (the hook fallback),
         never the aspirational app-server label. *)
      let fb = classify_codex_hook_fallback ~hooks_installed ~wake_target in
      { fb with
        cd_summary =
          "app-server unit is starting (remote TUI not attached yet); until \
           it attaches, " ^ fb.cd_summary;
        cd_remediation =
          Some "if the instance stays in 'starting', inspect it with \
                `c2c dev diag <name>`" }
  | Some "failed-startup" ->
      (* The surviving delivery path is whatever the hook fallback provides —
         derive its summary and the input-injection flag from the shared
         fallback classifier so a live hooks+wake pane-typing path is never
         hidden under this label. *)
      let fb = classify_codex_hook_fallback ~hooks_installed ~wake_target in
      { cd_mode = Cd_app_server_unavailable;
        cd_summary =
          "app-server startup failed or the installed codex is incompatible \
           (app-server mode needs codex >= 0.144 with `app-server --listen \
           --ws-auth` and `--remote` support). Live delivery falls back to: "
          ^ fb.cd_summary;
        cd_remediation =
          Some "upgrade codex (`npm i -g @openai/codex`), then relaunch with \
                `c2c start codex` (the app-server transport is the default \
                managed path); `c2c dev diag <name>` shows the structured \
                startup diagnostic";
        cd_input_injecting = fb.cd_input_injecting }
  | Some _ (* "offline" or unknown *) | None ->
      classify_codex_hook_fallback ~hooks_installed ~wake_target

(* Read-only live gather of managed codex instances:
   (name, app_server_status, wake_target, degraded). Total — any failure reads
   as an empty list / absent field. Never loads endpoints or tokens (the T006
   status mapping only exposes the lifecycle label). [degraded] (B138) is the
   persisted deliver-loop signal: true iff the loop is supervising but never
   loaded a thread; false/absent → not known degraded. *)
let live_codex_instances () : (string * string option * bool * bool) list =
  try
    let base = C2c_start.instances_dir in
    if not (Sys.file_exists base && Sys.is_directory base) then []
    else
      Sys.readdir base |> Array.to_list |> List.sort String.compare
      |> List.filter_map (fun name ->
           match C2c_start.load_config_opt name with
           | Some cfg when cfg.C2c_start.client = "codex" ->
               let instance_dir = C2c_start.instance_dir name in
               let app_status =
                 match C2c_codex_session.status_of_instance ~instance_dir with
                 | Some st -> Some (C2c_codex_session.status_to_string st)
                 | None -> None
               in
               let wake =
                 try C2c_start.codex_wake_target_registered ~name ()
                 with _ -> false
               in
               (* B138: only the online-attached path cares about degraded, and
                  it fails closed (absent/stale/missing record → degraded) so we
                  never overclaim LIVE. Other statuses ignore the flag. *)
               let degraded =
                 match app_status with
                 | Some "online-attached" ->
                     (try C2c_codex_session.online_attached_delivery_degraded
                            ~instance_dir
                      with _ -> true)
                 | _ -> false
               in
               Some (name, app_status, wake, degraded)
           | _ -> None)
  with _ -> []

let codex_delivery_report ?hooks_installed
    ?(instances : (string * string option * bool * bool) list option) () :
    codex_delivery_report =
  let hooks_installed =
    match hooks_installed with
    | Some b -> b
    | None -> (try C2c_start.codex_hooks_installed () with _ -> false)
  in
  let instances =
    match instances with Some l -> l | None -> live_codex_instances ()
  in
  { cdr_default =
      classify_codex_delivery ~app_server_status:None ~degraded:false
        ~hooks_installed ~wake_target:false;
    cdr_instances =
      List.map
        (fun (name, app_status, wake, degraded) ->
          { ci_name = name;
            ci_app_server_status = app_status;
            ci_delivery =
              classify_codex_delivery ~app_server_status:app_status ~degraded
                ~hooks_installed ~wake_target:wake })
        instances }

(* --- pure helpers --------------------------------------------------------- *)

let contains s sub =
  let ls = String.length s and lsub = String.length sub in
  if lsub = 0 then true
  else if lsub > ls then false
  else
    let rec check i =
      if i + lsub > ls then false
      else if String.sub s i lsub = sub then true
      else check (i + 1)
    in
    check 0

let status_label = function
  | Not_installed -> "not_installed"
  | Current -> "current"
  | Missing -> "missing"
  | Stale -> "stale"

let trim_trailing_newlines s =
  let i = ref (String.length s) in
  while !i > 0 && (s.[!i - 1] = '\n' || s.[!i - 1] = '\r') do
    decr i
  done;
  if !i = String.length s then s else String.sub s 0 !i

let first_diff expected actual =
  let exp = String.split_on_char '\n' (trim_trailing_newlines expected) in
  let act = String.split_on_char '\n' (trim_trailing_newlines actual) in
  let rec loop line exp act =
    match exp, act with
    | [], [] -> None
    | e :: es, a :: as_ when e = a -> loop (line + 1) es as_
    | e :: _, a :: _ -> Some { line; expected = e; actual = a }
    | e :: _, [] -> Some { line; expected = e; actual = "<missing>" }
    | [], a :: _ -> Some { line; expected = "<missing>"; actual = a }
  in
  loop 1 exp act

let extract_managed_blocks ~begin_marker ~end_marker content =
  let blocks = ref [] in
  let current = ref None in
  let finish acc =
    blocks := String.concat "\n" (List.rev acc) :: !blocks;
    current := None
  in
  List.iter
    (fun line ->
      let trimmed = String.trim line in
      match !current with
      | None ->
          if trimmed = begin_marker then current := Some [ line ]
      | Some acc ->
          let acc = line :: acc in
          if trimmed = end_marker then finish acc else current := Some acc)
    (String.split_on_char '\n' content);
  (match !current with
   | Some acc -> finish acc
   | None -> ());
  List.rev !blocks

let state_keys block =
  let prefix = "[hooks.state.\"" in
  let prefix_len = String.length prefix in
  String.split_on_char '\n' block
  |> List.filter_map (fun line ->
       let line = String.trim line in
       let len = String.length line in
       if len > prefix_len && String.sub line 0 prefix_len = prefix then
         try
           let rest = String.sub line prefix_len (len - prefix_len) in
           match String.index_opt rest '"' with
           | Some idx -> Some (String.sub rest 0 idx)
           | None -> None
         with _ -> None
       else None)

let same_string_set a b =
  List.sort String.compare a = List.sort String.compare b

let first_token s =
  let s = String.trim s in
  if s = "" then ""
  else
    let n = String.length s in
    let rec find_ws i =
      if i >= n then n
      else match s.[i] with
        | ' ' | '\t' | '\n' | '\r' -> i
        | _ -> find_ws (i + 1)
    in
    let end_pos = find_ws 0 in
    if end_pos = n then s else String.sub s 0 end_pos

let is_dangling_command cmd =
  let token = first_token cmd in
  if token = "" then false
  else if Filename.is_relative token then false
  else if not (contains token "c2c") then false
  else not (Sys.file_exists token)

(* --- JSON walk ------------------------------------------------------------ *)

let commands_from_hook_group event hook_group acc =
  match hook_group with
  | `Assoc fields ->
      (match List.assoc_opt "hooks" fields with
       | Some (`List hooks) ->
           List.fold_left (fun acc' hook ->
             match hook with
             | `Assoc hfields ->
                 (match List.assoc_opt "command" hfields with
                  | Some (`String cmd) -> (event, cmd) :: acc'
                  | _ -> acc')
             | _ -> acc') acc hooks
       | _ -> acc)
  | _ -> acc

let commands_from_event event groups acc =
  match groups with
  | `List gs -> List.fold_left (fun acc' g -> commands_from_hook_group event g acc') acc gs
  | _ -> acc

let extract_commands json =
  match json with
  | `Assoc top ->
      (match List.assoc_opt "hooks" top with
       | Some (`Assoc events) ->
           List.fold_left (fun acc (event, groups) ->
             commands_from_event event groups acc) [] events
       | _ -> [])
  | _ -> []

(* --- per-file / per-dir scan ---------------------------------------------- *)

let scan_file config_file =
  let content = C2c_io.read_file_opt config_file in
  if content = "" then `skipped
  else
    try
      let json = Yojson.Safe.from_string content in
      let cmds = extract_commands json in
      let referenced = ref 0 in
      let dangling = ref [] in
      List.iter (fun (event, cmd) ->
        let token = first_token cmd in
        if token <> "" && not (Filename.is_relative token) && contains token "c2c" then begin
          incr referenced;
          if not (Sys.file_exists token) then
            dangling := { config_file; event; command_path = token } :: !dangling
        end) cmds;
      `ok (!referenced, List.rev !dangling)
    with _ -> `skipped

let scan_dir dir =
  let settings = dir // "settings.json" in
  let local_settings = dir // "settings.local.json" in
  let referenced = ref 0 in
  let dangling = ref [] in
  let skipped = ref 0 in
  let process path =
    match scan_file path with
    | `skipped -> incr skipped
    | `ok (r, d) -> referenced := !referenced + r; dangling := !dangling @ d
  in
  process settings;
  process local_settings;
  { dir; referenced = !referenced; dangling = !dangling; skipped = !skipped }

(* --- Codex managed block scan --------------------------------------------- *)

let home_dir () =
  match Sys.getenv_opt "HOME" with
  | Some h when String.trim h <> "" -> h
  | _ -> ""

let codex_paths ?home () =
  let home = match home with Some h -> h | None -> home_dir () in
  let codex_dir = home // ".codex" in
  (codex_dir // "config.toml", codex_dir // "AGENTS.md")

let block_result ~label ~path ~status ~reason ?refresh_command ?first_diff () =
  { label; path; status; reason; refresh_command; first_diff }

let not_installed_block ~label ~path =
  block_result ~label ~path ~status:Not_installed
    ~reason:"c2c codex install not detected" ()

let assess_block ~label ~path ~begin_marker ~end_marker ~expected ~installed =
  let blocks = extract_managed_blocks ~begin_marker ~end_marker installed in
  match blocks with
  | [] ->
      block_result ~label ~path ~status:Missing
        ~reason:"managed block is missing"
        ~refresh_command:"c2c install codex" ()
  | [ actual ] ->
      if trim_trailing_newlines actual = trim_trailing_newlines expected then
        block_result ~label ~path ~status:Current ~reason:"managed block is current" ()
      else
        block_result ~label ~path ~status:Stale
          ~reason:"managed block differs from current c2c render"
          ~refresh_command:"c2c install codex"
          ?first_diff:(first_diff expected actual)
          ()
  | _ ->
      block_result ~label ~path ~status:Stale
        ~reason:"multiple managed blocks found"
        ~refresh_command:"c2c install codex" ()

let check_codex_managed_blocks ?home () =
  let config_path, agents_md_path = codex_paths ?home () in
  let config_exists = Sys.file_exists config_path in
  let agents_exists = Sys.file_exists agents_md_path in
  let config_content = if config_exists then C2c_io.read_file_opt config_path else "" in
  let agents_content = if agents_exists then C2c_io.read_file_opt agents_md_path else "" in
  let installed =
    config_exists
    && (contains config_content "mcp_servers.c2c"
        || contains config_content C2c_codex_hooks.config_begin_marker)
    || contains agents_content C2c_codex_hooks.agents_md_begin_marker
  in
  if not installed then
    let config = not_installed_block ~label:"codex config.toml" ~path:config_path in
    let agents_md = not_installed_block ~label:"codex AGENTS.md" ~path:agents_md_path in
    { installed = false; config; agents_md; total_issues = 0; trust_index_drift = false }
  else
    let config_stripped =
      C2c_codex_hooks.strip_managed_block
        ~begin_marker:C2c_codex_hooks.config_begin_marker
        ~end_marker:C2c_codex_hooks.config_end_marker
        config_content
    in
    let expected_config =
      C2c_codex_hooks.render_hooks_block ~config_path ~existing:config_stripped
    in
    let config =
      assess_block ~label:"codex config.toml" ~path:config_path
        ~begin_marker:C2c_codex_hooks.config_begin_marker
        ~end_marker:C2c_codex_hooks.config_end_marker
        ~expected:expected_config ~installed:config_content
    in
    let agents_md =
      assess_block ~label:"codex AGENTS.md" ~path:agents_md_path
        ~begin_marker:C2c_codex_hooks.agents_md_begin_marker
        ~end_marker:C2c_codex_hooks.agents_md_end_marker
        ~expected:C2c_codex_hooks.agents_md_block ~installed:agents_content
    in
    let actual_config_blocks =
      extract_managed_blocks
        ~begin_marker:C2c_codex_hooks.config_begin_marker
        ~end_marker:C2c_codex_hooks.config_end_marker
        config_content
    in
    let trust_index_drift =
      match actual_config_blocks with
      | [ actual ] ->
          let actual_keys = state_keys actual in
          let expected_keys = state_keys expected_config in
          actual_keys <> [] && expected_keys <> []
          && not (same_string_set actual_keys expected_keys)
      | _ -> false
    in
    let config =
      if trust_index_drift && config.status = Stale then
        { config with
          reason =
            "managed trust-state group indices differ from current hook positions"
        }
      else config
    in
    let issue_count b =
      match b.status with
      | Current | Not_installed -> 0
      | Missing | Stale -> 1
    in
    let total_issues = issue_count config + issue_count agents_md in
    { installed = true; config; agents_md; total_issues; trust_index_drift }

(* --- public API ----------------------------------------------------------- *)

let claude_dirs () =
  match Sys.getenv_opt "C2C_DOCTOR_CLAUDE_DIRS" with
  | Some s when String.trim s <> "" ->
      String.split_on_char ':' s |> List.filter (fun d -> String.trim d <> "")
  | _ ->
      (match Sys.getenv_opt "CLAUDE_CONFIG_DIR" with
       | Some d when String.trim d <> "" -> [ String.trim d ]
       | _ ->
           let home =
             match Sys.getenv_opt "HOME" with
             | Some h -> h
             | None -> ""
           in
           if home = "" then []
           else [ home // ".claude"; home // ".claude-p"; home // ".claude-w" ])

let check_agy_status ?home () =
  let home = match home with Some h -> h | None -> try Sys.getenv "HOME" with Not_found -> "/tmp" in
  let skill = home // ".gemini" // "skills" // "c2c" // "SKILL.md" in
  let hooks = home // ".gemini" // "config" // "hooks.json" in
  let skill_exists = Sys.file_exists skill in
  let hooks_exists = Sys.file_exists hooks in
  let has_c2c_hooks =
    if hooks_exists then
      try
        let json = Yojson.Safe.from_file hooks in
        match json with
        | `Assoc fields -> List.mem_assoc "c2c-hooks" fields
        | _ -> false
      with _ -> false
    else false
  in
  let installed = skill_exists || has_c2c_hooks in
  let broker_root = C2c_utils.resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let regs = try C2c_mcp.Broker.list_registrations broker with _ -> [] in
  let agy_regs = List.filter (fun (r : C2c_mcp.registration) -> r.client_type = Some "agy" || r.registered_by = Some "agy-hook") regs in
  let bad_prefixes =
    List.filter (fun (r : C2c_mcp.registration) ->
      let len = String.length r.alias in
      not (len >= 4 && String.sub r.alias 0 4 = "agy-")
    ) agy_regs
  in
  let alias_prefix_ok = (bad_prefixes = []) in
  let alias_prefix_reason =
    if alias_prefix_ok then None
    else
      let aliases = List.map (fun (r : C2c_mcp.registration) -> r.alias) bad_prefixes in
      Some (Printf.sprintf "The following agy sessions do not have 'agy-' prefix: %s" (String.concat ", " aliases))
  in
  { installed; skill_exists; hooks_exists; has_c2c_hooks; alias_prefix_ok; alias_prefix_reason }

let check ?(dirs = claude_dirs ()) () =
  let dirs = List.filter (fun d -> Sys.file_exists d && Sys.is_directory d) dirs in
  let dir_results = List.map scan_dir dirs in
  let total_referenced = List.fold_left (fun acc d -> acc + d.referenced) 0 dir_results in
  let total_dangling = List.fold_left (fun acc d -> acc + List.length d.dangling) 0 dir_results in
  let total_skipped = List.fold_left (fun acc d -> acc + d.skipped) 0 dir_results in
  let codex = check_codex_managed_blocks () in
  let agy = check_agy_status () in
  { dirs = dir_results; total_referenced; total_dangling; total_skipped; codex; agy }

(* --- output formatters ---------------------------------------------------- *)

let pp_human r =
  Printf.printf "=== Claude hook dangle check ===\n\n";
  if r.dirs = [] then
    Printf.printf "No Claude config dirs found.\n"
  else begin
    List.iter (fun d ->
      Printf.printf "  dir: %s\n" d.dir;
      if d.referenced = 0 then
        Printf.printf "    no c2c hook commands referenced\n"
      else if d.dangling = [] then
        Printf.printf "    %d referenced hook command(s), all resolve\n" d.referenced
      else begin
        Printf.printf "    %d referenced hook command(s), %d dangling:\n"
          d.referenced (List.length d.dangling);
        List.iter (fun x ->
          Printf.printf "      %s:\n        %s\n" x.event x.command_path;
          Printf.printf "        → re-run `c2c install claude` (writes the hook script through the symlink), or restore the script into the shared hooks dir.\n"
        ) d.dangling
      end;
      if d.skipped > 0 then
        Printf.printf "    (%d config file(s) missing or unparseable — skipped)\n" d.skipped
    ) r.dirs;
    Printf.printf "\nSummary: %d referenced, %d dangling" r.total_referenced r.total_dangling;
    if r.total_skipped > 0 then
      Printf.printf " (%d skipped)" r.total_skipped;
    Printf.printf "\n"
  end;
  Printf.printf "\n=== Codex managed block check ===\n\n";
  let pp_block b =
    let status = status_label b.status in
    Printf.printf "  %s: %s\n" b.label status;
    Printf.printf "    path: %s\n" b.path;
    Printf.printf "    %s\n" b.reason;
    (match b.first_diff with
     | Some d ->
         Printf.printf "    first diff line %d:\n" d.line;
         Printf.printf "      expected: %s\n" d.expected;
         Printf.printf "      actual:   %s\n" d.actual
     | None -> ());
    (match b.refresh_command with
     | Some cmd -> Printf.printf "    → refresh: %s\n" cmd
     | None -> ())
  in
  if not r.codex.installed then
    Printf.printf "Codex c2c install not detected.\n"
  else begin
    pp_block r.codex.config;
    pp_block r.codex.agents_md;
    if r.codex.trust_index_drift then
      Printf.printf
        "  trust hashes: positional group indices drifted — run `c2c install codex`.\n";
    Printf.printf "\nSummary: %d Codex managed block issue(s)\n"
      r.codex.total_issues
  end;
  Printf.printf "\n=== Antigravity (agy) custom skill & hooks check ===\n\n";
  if not r.agy.installed then
    Printf.printf "Antigravity c2c install not detected.\n"
  else begin
    Printf.printf "  skill: %s\n" (if r.agy.skill_exists then "OK" else "MISSING — run `c2c install agy`");
    Printf.printf "  hooks: %s\n" (if r.agy.hooks_exists then "OK" else "MISSING (no hooks.json file)");
    Printf.printf "  c2c hooks key: %s\n" (if r.agy.has_c2c_hooks then "OK" else "MISSING — run `c2c install agy`");
    (match r.agy.alias_prefix_reason with
     | Some reason -> Printf.printf "  ⚠ %s\n" reason
     | None -> Printf.printf "  alias prefix constraints: OK (all live agy sessions are agy-*)\n")
  end

let to_json r =
  let dangling_to_json d =
    `Assoc [
      ("config_file", `String d.config_file);
      ("event", `String d.event);
      ("command_path", `String d.command_path)
    ]
  in
  let dir_to_json d =
    `Assoc [
      ("dir", `String d.dir);
      ("referenced", `Int d.referenced);
      ("dangling", `List (List.map dangling_to_json d.dangling));
      ("skipped", `Int d.skipped)
    ]
  in
  let diff_to_json d =
    `Assoc [
      ("line", `Int d.line);
      ("expected", `String d.expected);
      ("actual", `String d.actual)
    ]
  in
  let block_to_json b =
    `Assoc [
      ("label", `String b.label);
      ("path", `String b.path);
      ("status", `String (status_label b.status));
      ("reason", `String b.reason);
      ("refresh_command",
       match b.refresh_command with Some c -> `String c | None -> `Null);
      ("first_diff",
       match b.first_diff with Some d -> diff_to_json d | None -> `Null)
    ]
  in
  let codex_to_json c =
    `Assoc [
      ("installed", `Bool c.installed);
      ("config", block_to_json c.config);
      ("agents_md", block_to_json c.agents_md);
      ("total_issues", `Int c.total_issues);
      ("trust_index_drift", `Bool c.trust_index_drift)
    ]
  in
  let agy_to_json (a : agy_result) =
    `Assoc [
      ("installed", `Bool a.installed);
      ("skill_exists", `Bool a.skill_exists);
      ("hooks_exists", `Bool a.hooks_exists);
      ("has_c2c_hooks", `Bool a.has_c2c_hooks);
      ("alias_prefix_ok", `Bool a.alias_prefix_ok);
      ("alias_prefix_reason", match a.alias_prefix_reason with Some s -> `String s | None -> `Null)
    ]
  in
  `Assoc [
    ("dirs", `List (List.map dir_to_json r.dirs));
    ("total_referenced", `Int r.total_referenced);
    ("total_dangling", `Int r.total_dangling);
    ("total_skipped", `Int r.total_skipped);
    ("codex_managed_blocks", codex_to_json r.codex);
    ("total_codex_issues", `Int r.codex.total_issues);
    ("agy", agy_to_json r.agy)
  ]

let pp_json r = print_endline (Yojson.Safe.to_string (to_json r))

(* --- Codex delivery-mode output (T005) ------------------------------------ *)

let codex_delivery_to_json (d : codex_delivery) : Yojson.Safe.t =
  `Assoc [
    ("mode", `String (codex_delivery_mode_label d.cd_mode));
    ("summary", `String d.cd_summary);
    ("remediation",
     match d.cd_remediation with Some x -> `String x | None -> `Null);
    ("input_injecting", `Bool d.cd_input_injecting)
  ]

let codex_delivery_report_to_json (rep : codex_delivery_report) : Yojson.Safe.t =
  `Assoc [
    ("default", codex_delivery_to_json rep.cdr_default);
    ("instances",
     `List
       (List.map
          (fun i ->
            `Assoc [
              ("name", `String i.ci_name);
              ("app_server_status",
               match i.ci_app_server_status with
               | Some s -> `String s
               | None -> `Null);
              ("delivery", codex_delivery_to_json i.ci_delivery)
            ])
          rep.cdr_instances))
  ]

let pp_codex_delivery_human (rep : codex_delivery_report) =
  Printf.printf "\n=== Codex delivery mode ===\n\n";
  let pp_delivery indent (d : codex_delivery) =
    Printf.printf "%s%s\n" indent d.cd_summary;
    if d.cd_input_injecting then
      Printf.printf "%s(this mode injects input into the session's pane)\n" indent;
    match d.cd_remediation with
    | Some fix -> Printf.printf "%s→ %s\n" indent fix
    | None -> ()
  in
  Printf.printf "  default (vanilla codex session on this machine): %s\n"
    (codex_delivery_mode_label rep.cdr_default.cd_mode);
  pp_delivery "    " rep.cdr_default;
  if rep.cdr_instances = [] then
    Printf.printf "  (no managed codex instances)\n"
  else
    List.iter
      (fun i ->
        Printf.printf "  instance %s: %s%s\n" i.ci_name
          (codex_delivery_mode_label i.ci_delivery.cd_mode)
          (match i.ci_app_server_status with
           | Some s -> Printf.sprintf " (app_server_status=%s)" s
           | None -> "");
        pp_delivery "    " i.ci_delivery)
      rep.cdr_instances

let pp_codex_delivery_compact (rep : codex_delivery_report) =
  let inst_str =
    if rep.cdr_instances = [] then "no managed codex instances"
    else
      String.concat ", "
        (List.map
           (fun i ->
             Printf.sprintf "%s=%s" i.ci_name
               (codex_delivery_mode_label i.ci_delivery.cd_mode))
           rep.cdr_instances)
  in
  Printf.printf "Codex delivery: default=%s; %s\n"
    (codex_delivery_mode_label rep.cdr_default.cd_mode) inst_str

let pp_compact r =
  (if r.total_referenced = 0 then
     Printf.printf "Claude hooks: no c2c hook commands referenced\n"
   else if r.total_dangling = 0 then
     Printf.printf "Claude hooks: all %d resolve\n" r.total_referenced
   else
     Printf.printf "Claude hooks: %d referenced, %d dangling — run 'c2c doctor hooks' for details\n"
       r.total_referenced r.total_dangling);
  if not r.codex.installed then
    Printf.printf "Codex managed blocks: not installed\n"
  else if r.codex.total_issues = 0 then
    Printf.printf "Codex managed blocks: current\n"
  else
    Printf.printf
      "Codex managed blocks: %d stale/missing — run 'c2c install codex'\n"
      r.codex.total_issues

(* --- CLI ------------------------------------------------------------------ *)

let c2c_doctor_hooks_cmd =
  let json =
    Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Output machine-readable JSON.")
  in
  let compact =
    Cmdliner.Arg.(value & flag & info [ "compact" ]
      ~doc:"Single-line summary suitable for 'c2c doctor' rollup.")
  in
  let cmd =
    let+ json = json
    and+ compact = compact in
    let r = check () in
    let delivery = codex_delivery_report () in
    if json then
      (* Merge the T005 delivery report into the existing JSON envelope. *)
      (match to_json r with
       | `Assoc fields ->
           print_endline
             (Yojson.Safe.to_string
                (`Assoc
                  (fields
                  @ [ ("codex_delivery",
                       codex_delivery_report_to_json delivery) ])))
       | other -> print_endline (Yojson.Safe.to_string other))
    else if compact then begin
      pp_compact r;
      pp_codex_delivery_compact delivery
    end
    else begin
      pp_human r;
      pp_codex_delivery_human delivery
    end;
    if r.total_dangling > 0 || r.codex.total_issues > 0 then exit 1
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "hooks"
       ~doc:"Check Claude Code settings.json hook entries for dangling c2c \
             scripts, Codex managed-block drift, and the live Codex delivery \
             mode (app-server / app-server-unavailable / hooks+wake / hooks / \
             unavailable) with a remediation per degraded state.")
    cmd
