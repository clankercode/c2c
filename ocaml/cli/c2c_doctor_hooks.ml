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
  kimi : kimi_delivery_result;
  kimi_hook : kimi_hook_result;
  grok : grok_identity_result;
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

(* B238: unmanaged Kimi sessions with mail but no notifier go deaf. *)
and kimi_session_issue = {
  ksi_alias : string;
  ksi_session_id : string;
  ksi_inbox_count : int;
  ksi_notifier_running : bool;
  ksi_registered_by : string option;
  ksi_fix_command : string;
  (* #42 (A3): liveness of the registration's process. [None] = pidless /
     unknown (legacy or torn-down managed row); [Some true] = alive;
     [Some false] = CONFIRMED dead. [--rearm] must NOT re-arm a confirmed-dead
     session — that mints a leaked headless notifier (the #42 amplification). *)
  ksi_proc_alive : bool option;
}

(* #42 (B): a managed kimi instance present on disk
   ([~/.local/share/c2c/instances/<name>]) with NO live registration on the
   broker being checked. The DEAF classifier and [--rearm] iterate only
   REGISTERED sessions, so this — the most common broken state — was invisible
   to both. It is a DIFFERENT failure from "registered but no notifier" and
   carries a different remediation (restart the managed instance, don't arm a
   notifier for a session that never registered). *)
and kimi_unregistered_managed = {
  kum_name : string;         (* managed instance name *)
  kum_alias : string;        (* configured alias *)
  kum_session_id : string;   (* configured session id (= name for managed kimi) *)
  kum_fix_command : string;
}

and kimi_delivery_result = {
  kd_sessions_checked : int;
  kd_deaf : kimi_session_issue list; (* inbox>0 and no notifier *)
  kd_no_notifier : kimi_session_issue list; (* registered kimi, no notifier (may be empty inbox) *)
  kd_unregistered_managed : kimi_unregistered_managed list; (* #42(B): on disk, never registered here *)
}

(* #50: the Kimi SessionStart hook (`c2c hook kimi`) is load-bearing for
   delivery IDENTITY (#41), not just wake. It writes kimi's own payload
   session id to a workspace-keyed record, and the notifier PREFERS that
   record when resolving which session to POST mail to. Where the hook is NOT
   installed, no record is written and session resolution silently reverts to
   the pre-#41 bug: binding to the newest session_index.jsonl entry (= the
   PREVIOUS session). The degradation is fail-safe but SILENT — nothing else
   distinguishes "delivery identity authoritative" from "delivery identity
   guesswork", which is exactly what doctor exists to surface. This is a
   config-based install check (NOT live-session based): it reads the same
   source of truth the installer writes. *)
and kimi_hook_result = {
  khook_config_path : string;   (* ~/.kimi-code/config.toml *)
  khook_config_exists : bool;   (* kimi config present at all (kimi in use) *)
  khook_installed : bool;       (* SessionStart [[hooks]] block present *)
}

(* #23(a): read-only Grok identity-drift detector. The Grok host injects
   C2C_MCP_SESSION_ID into tool shells (upstream, out of c2c scope); the c2c-side
   diagnostic is a PURE data cross-check between (1) grok broker registrations,
   (2) the CLI statefile identity, and (3) ~/.grok/active_sessions.json foreground
   pids. NO ancestor-pid resolution — the doctor runs in a different process tree,
   so it must not reuse session_id_from_grok_active_sessions. *)

(* #37: Grok has no local inject API, so idle wake is NONE unless the agent
   armed `c2c monitor` (a model decision → CONDITIONAL, never GUARANTEED).
   Pure classify so hermetic tests do not need a live monitor process. *)
and grok_wake_class =
  | Grok_wake_none
  | Grok_wake_conditional_monitor

and grok_wake_session = {
  gws_alias : string;
  gws_session_id : string;
  gws_monitor_alive : bool;
  gws_class : grok_wake_class;
}

and grok_identity_result = {
  gid_grok_regs : int; (* number of grok registrations on this broker *)
  gid_statefile_sid : string option; (* identity the CLI statefile points at *)
  gid_live_grok_sids : string list; (* grok reg sids corroborated alive in active_sessions *)
  gid_flagged : bool;
  gid_reason : string option;
  gid_remediation : string list; (* export line + candidate identities *)
  gid_wake_class : grok_wake_class; (* overall: CONDITIONAL if any live monitor lock *)
  gid_wake_sessions : grok_wake_session list;
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
  | Cd_app_server_unbound   (* #31: thread loaded + delivering, but the #24 guard refused its durable binding *)
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
  | Cd_app_server_unbound -> "app-server (degraded: thread binding refused)"
  | Cd_app_server_unavailable -> "app-server-unavailable"
  | Cd_hooks_wake -> "hooks+wake"
  | Cd_hooks_only -> "hooks"
  | Cd_unavailable -> "unavailable"

(* #27: a delivery mode with NO live c2c delivery path — a managed codex instance
   in one of these modes is DEAF (mail queues but is not read at arrival time).
   Hook modes ([Cd_hooks_only]/[Cd_hooks_wake]) still deliver at hook boundaries,
   so they are NOT deaf. *)
let codex_mode_is_degraded = function
  | Cd_app_server_degraded | Cd_app_server_unbound
  | Cd_app_server_unavailable | Cd_unavailable -> true
  | Cd_app_server | Cd_hooks_wake | Cd_hooks_only -> false

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

let classify_codex_delivery ~(binding_refused : bool)
    ~(app_server_status : string option)
    ~(degraded : bool) ~(hooks_installed : bool) ~(wake_target : bool)
    : codex_delivery =
  match app_server_status with
  | Some "online-attached" when degraded && binding_refused ->
      (* #31: DEGRADED, but not for the B138 reason — a Codex thread IS loaded
         and inbound mail IS being injected into it. What failed is the DURABLE
         thread binding: the #24 split-brain guard refused to record it because
         a live managed sibling already owns that thread. The B138 remediation
         ("open a thread") is unfollowable here — a thread is already open and
         discovered — so this gets its own classification whose remediation
         names the real action: resolve the sibling that owns the thread. *)
      { cd_mode = Cd_app_server_unbound;
        cd_summary =
          "app-server remote TUI is attached and a Codex thread IS loaded (mail \
           is being injected into it), BUT this unit's durable thread binding \
           was REFUSED because another live managed instance already owns that \
           thread (#24 split-brain guard). The binding is not recorded, so it \
           will not survive a restart and two units are pointed at one thread";
        cd_remediation =
          Some "another live managed codex instance already owns this thread; \
                list the managed instances (`c2c dev instances`) and stop or \
                re-point the sibling that owns it, then restart this instance \
                (`c2c restart <name>`) so it can bind the thread. Opening \
                another thread in the TUI will NOT clear this (#24/#31); \
                `c2c dev diag <name>` shows the live loop state";
        cd_input_injecting = false }
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
(* (name, app_server_status, wake_target, degraded, binding_refused) — the last
   field (#31) discriminates the two degraded shapes for the classifier. *)
let live_codex_instances () :
    (string * string option * bool * bool * bool) list =
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
                            ~instance_dir ()
                      with _ -> true)
                 | _ -> false
               in
               (* #31: also read WHY it is degraded, so the report can carry
                  the followable remediation. Never fails toward "refused". *)
               let binding_refused =
                 degraded
                 && (match app_status with
                     | Some "online-attached" ->
                         (try
                            C2c_codex_session
                            .online_attached_delivery_binding_refused
                              ~instance_dir ()
                          with _ -> false)
                     | _ -> false)
               in
               Some (name, app_status, wake, degraded, binding_refused)
           | _ -> None)
  with _ -> []

let codex_delivery_report ?hooks_installed
    ?(instances :
       (string * string option * bool * bool * bool) list option) () :
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
      classify_codex_delivery ~binding_refused:false ~app_server_status:None
        ~degraded:false ~hooks_installed ~wake_target:false;
    cdr_instances =
      List.map
        (fun (name, app_status, wake, degraded, binding_refused) ->
          { ci_name = name;
            ci_app_server_status = app_status;
            ci_delivery =
              classify_codex_delivery ~binding_refused
                ~app_server_status:app_status ~degraded
                ~hooks_installed ~wake_target:wake })
        instances }

(* #27: the DEAF managed codex instances in a report — those with no live c2c
   delivery path (degraded / app-server-unavailable / unavailable). *)
let codex_deaf_instances (rep : codex_delivery_report) : codex_instance_delivery list =
  List.filter (fun i -> codex_mode_is_degraded i.ci_delivery.cd_mode) rep.cdr_instances

(* #27: one-line rollup for `c2c doctor`, mirroring the Kimi DEAF summary line.
   [None] when every managed codex instance has a live delivery path. Pure so the
   doctor summary and tests share it. *)
let codex_deaf_summary (rep : codex_delivery_report) : string option =
  match codex_deaf_instances rep with
  | [] -> None
  | deaf ->
      Some
        (Printf.sprintf
           "Codex delivery: %d instance(s) with no live c2c delivery path (%s) \
            — run 'c2c doctor hooks'"
           (List.length deaf)
           (String.concat ", "
              (List.map
                 (fun i ->
                   Printf.sprintf "%s=%s" i.ci_name
                     (codex_delivery_mode_label i.ci_delivery.cd_mode))
                 deaf)))

(* Pure exit-status predicate for `c2c doctor hooks`: does the run represent an
   actionable FAILURE (exit 1) rather than a clean check (exit 0)? Extracted so
   the contract is pinned by tests instead of living only inside the cmdliner
   closure. #27 added [codex_deaf] — a DEAF managed codex instance is exactly as
   actionable as a DEAF kimi session or grok identity drift, and must fail the
   check so scripts/CI can detect it. *)
let doctor_hooks_exit_failure ~(total_dangling : int) ~(codex_issues : int)
    ~(kimi_deaf : int) ~(grok_flagged : bool) ~(codex_deaf : int) : bool =
  total_dangling > 0
  || codex_issues > 0
  || kimi_deaf > 0
  || grok_flagged
  || codex_deaf > 0

(* #27: observability helper shared by `c2c send`. Given the live (or injected)
   codex instances, return a sender warning when [to_alias] names a managed codex
   instance whose delivery mode has NO live c2c path (degraded / unavailable).
   [None] for a healthy instance, or a recipient that is not a managed codex
   instance. Pure (instances injected) so it is unit-testable and never touches a
   socket — it is OBSERVABILITY ONLY (message content is untouched; nothing here
   triggers or gates delivery). *)
let codex_send_delivery_warning ?hooks_installed
    ?(instances :
       (string * string option * bool * bool * bool) list option)
    (to_alias : string) : string option =
  let rep = codex_delivery_report ?hooks_installed ?instances () in
  match List.find_opt (fun i -> i.ci_name = to_alias) rep.cdr_instances with
  | Some i when codex_mode_is_degraded i.ci_delivery.cd_mode ->
      Some
        (Printf.sprintf
           "recipient %s has no live c2c delivery path (codex delivery %s); \
            message queued but may not be read — see `c2c doctor hooks`"
           to_alias (codex_delivery_mode_label i.ci_delivery.cd_mode))
  | _ -> None

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

(* #50: is the `c2c hook kimi` SessionStart hook installed? Mirrors the
   codex/agy managed-block checks: it reads the INSTALLED CONFIG, not live
   sessions. The source of truth is the SessionStart [[hooks]] block that
   `c2c install kimi` appends to ~/.kimi-code/config.toml, keyed by
   C2c_kimi_hook.session_start_hook_block_id — so this check consults the same
   marker the installer writes rather than inventing a path. When the block is
   absent, kimi delivery-identity resolution silently degrades to
   session_index.jsonl index-order guessing (the #41 regression). *)
let check_kimi_session_start_hook ?home () : kimi_hook_result =
  let home =
    match home with
    | Some h -> h
    | None -> (try Sys.getenv "HOME" with Not_found -> "/tmp")
  in
  let config_path = home // ".kimi-code" // "config.toml" in
  let config_exists = Sys.file_exists config_path in
  let installed =
    try
      C2c_kimi_hook.toml_block_already_present
        ~block_id:C2c_kimi_hook.session_start_hook_block_id
        ~config_path ()
    with _ -> false
  in
  { khook_config_path = config_path
  ; khook_config_exists = config_exists
  ; khook_installed = installed
  }

(* B238 pure classifier: given a registration snapshot + inbox depth +
   notifier liveness, decide whether the session is "deaf" (mail waiting,
   no delivery daemon). Exposed for unit tests. *)
let is_kimi_registration (r : C2c_mcp.registration) =
  (match r.client_type with Some "kimi" -> true | _ -> false)
  || (match r.registered_by with Some "kimi-hook" -> true | _ -> false)
  || (let a = String.lowercase_ascii r.alias in
      String.length a >= 5 && String.sub a 0 5 = "kimi-")

(* #42: /proc liveness of a pid (best-effort). Mirrors [pid_alive] defined
   later in the grok section; declared here because the kimi classifier needs
   it earlier in the file. *)
let kimi_pid_alive pid = C2c_liveness.pid_alive pid

let classify_kimi_session
    ~(alias : string)
    ~(session_id : string)
    ~(inbox_count : int)
    ~(notifier_running : bool)
    ~(registered_by : string option)
    ?pid
    ()
  : kimi_session_issue option * bool (* issue-if-no-notifier, is_deaf *)
  =
  let fix =
    Printf.sprintf
      "c2c start kimi -n %s   # preferred: managed notifier + REST delivery\n\
       # or arm a receive path inside the session:\n\
       #   Monitor({ description: \"c2c inbox watcher\", command: \"c2c monitor\", persistent: true })\n\
       # or drain once: C2C_MCP_SESSION_ID=%s c2c poll-inbox"
      (Filename.quote alias) (Filename.quote session_id)
  in
  (* [None] pid = liveness unknown (pidless / torn-down managed row); we do NOT
     assert death from an absent pid. [Some p] resolves to CONFIRMED
     alive/dead. *)
  let proc_alive = match pid with None -> None | Some p -> Some (kimi_pid_alive p) in
  let issue =
    { ksi_alias = alias
    ; ksi_session_id = session_id
    ; ksi_inbox_count = inbox_count
    ; ksi_notifier_running = notifier_running
    ; ksi_registered_by = registered_by
    ; ksi_fix_command = fix
    ; ksi_proc_alive = proc_alive
    }
  in
  if notifier_running then
    (None, false)
  else
    let deaf = inbox_count > 0 in
    (Some issue, deaf)

(* #42 (B): the managed-instances dir. Mirrors [C2c_start.instances_dir] but
   duplicated here on purpose — the doctor-hooks test executable does NOT link
   c2c_start (see its (modules ...) in ocaml/cli/dune), so depending on it would
   break the hermetic build. Honors the same [C2C_INSTANCES_DIR] override tests
   use. *)
let kimi_instances_dir ?home () =
  match Sys.getenv_opt "C2C_INSTANCES_DIR" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ ->
    let home =
      match home with Some h -> h | None -> (try Sys.getenv "HOME" with Not_found -> "/tmp")
    in
    home // ".local" // "share" // "c2c" // "instances"

(* #42 (B): read the minimal fields of an on-disk instance config.json we need
   to classify it. Read-only, best-effort ([None] on any parse error). *)
type kimi_instance_on_disk = {
  kio_name : string;
  kio_client : string;
  kio_alias : string;
  kio_session_id : string;
  kio_broker_root : string option;
}

let read_instance_config path : kimi_instance_on_disk option =
  match (try Some (Yojson.Safe.from_file path) with _ -> None) with
  | Some (`Assoc fields) ->
    let str k = match List.assoc_opt k fields with Some (`String s) -> Some s | _ -> None in
    (match str "name", str "client" with
     | Some name, Some client ->
       Some
         { kio_name = name
         ; kio_client = client
         ; kio_alias = (match str "alias" with Some a -> a | None -> name)
         ; kio_session_id = (match str "session_id" with Some s -> s | None -> name)
         ; kio_broker_root = str "broker_root"
         }
     | _ -> None)
  | _ -> None

(* #42 (B): managed kimi instances on disk with NO registration on [broker_root].
   Scoped to this broker: an instance is included when its persisted broker_root
   equals [broker_root] (normalized) OR it persisted none (the common case — the
   default resolver was used). This deliberately excludes instances that ARE
   registered (those are covered by the normal DEAF / no-notifier classification
   above). Case-insensitive alias/session match, mirroring broker alias
   casefolding. *)
let unregistered_managed_kimi_instances ?home ~broker_root ~(regs : C2c_mcp.registration list) () =
  let dir = kimi_instances_dir ?home () in
  let norm p = try Unix.realpath p with _ -> p in
  let broker_root_n = norm broker_root in
  let ci s = String.lowercase_ascii (String.trim s) in
  let entries = try Sys.readdir dir with _ -> [||] in
  Array.fold_left
    (fun acc name ->
      let cfg_path = dir // name // "config.json" in
      match read_instance_config cfg_path with
      | Some c when c.kio_client = "kimi" ->
        let broker_scoped =
          match c.kio_broker_root with
          | None -> true
          | Some br -> norm br = broker_root_n
        in
        let has_registration =
          List.exists
            (fun (r : C2c_mcp.registration) ->
               ci r.session_id = ci c.kio_session_id || ci r.alias = ci c.kio_alias)
            regs
        in
        if broker_scoped && not has_registration then
          { kum_name = c.kio_name
          ; kum_alias = c.kio_alias
          ; kum_session_id = c.kio_session_id
          ; kum_fix_command =
              Printf.sprintf
                "c2c restart %s   # managed instance exists on disk but never \
                 registered — restart it (do NOT --rearm: there is no session \
                 to deliver to)"
                (Filename.quote c.kio_name)
          }
          :: acc
        else acc
      | _ -> acc)
    [] entries
  |> List.rev

let check_kimi_delivery ?broker_root () : kimi_delivery_result =
  let broker_root =
    match broker_root with
    | Some r -> r
    | None -> C2c_utils.resolve_broker_root ()
  in
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let regs =
    try C2c_mcp.Broker.list_registrations broker with _ -> []
  in
  let kimi_regs = List.filter is_kimi_registration regs in
  let deaf = ref [] in
  let no_notifier = ref [] in
  List.iter
    (fun (r : C2c_mcp.registration) ->
      let inbox_count =
        try List.length (C2c_mcp.Broker.read_inbox broker ~session_id:r.session_id)
        with _ -> 0
      in
      let notifier_running =
        try C2c_kimi_notifier.already_running r.alias with _ -> false
      in
      match
        classify_kimi_session
          ~alias:r.alias
          ~session_id:r.session_id
          ~inbox_count
          ~notifier_running
          ~registered_by:r.registered_by
          ?pid:r.pid
          ()
      with
      | None, _ -> ()
      | Some issue, is_deaf ->
          no_notifier := issue :: !no_notifier;
          if is_deaf then deaf := issue :: !deaf)
    kimi_regs;
  { kd_sessions_checked = List.length kimi_regs
  ; kd_deaf = List.rev !deaf
  ; kd_no_notifier = List.rev !no_notifier
  ; kd_unregistered_managed =
      (try unregistered_managed_kimi_instances ~broker_root ~regs () with _ -> [])
  }

(* --- #9 A(2): `c2c doctor hooks --rearm` self-heal for DEAF kimi sessions --

   A kimi session goes DEAF when it is registered (mail lands in its inbox) but
   no notifier daemon is running to drain it (see the hook-alarm race fixed by
   A(1)). `--rearm` walks the EXACT DEAF set already computed by
   [check_kimi_delivery] (inbox>0 AND no notifier) and arms a notifier for each,
   keyed by the registration's REAL session_id so [run_once] drains the inbox
   the mail actually landed in. Healthy sessions (notifier running) and merely
   idle ones (empty inbox) are never in [kd_deaf], so they are never touched.

   Hermetic tests set C2C_KIMI_HOOK_SKIP_NOTIFIER=1 (the same fixture the kimi
   hook honours) so no real notifier is forked: the outcome is recorded as
   [Rearm_skipped_fixture] and callers can assert on the reported set. *)
type rearm_outcome =
  | Rearm_armed              (* ensure_daemon forked/adopted a notifier *)
  | Rearm_already_running    (* a live notifier was already present *)
  | Rearm_failed of string   (* ensure_daemon raised / returned no pid *)
  | Rearm_skipped_fixture    (* C2C_KIMI_HOOK_SKIP_NOTIFIER=1 — no fork *)
  | Rearm_skipped_dead       (* #42(A3): registration process CONFIRMED dead — arming would mint a leaked headless notifier *)

type rearm_result = {
  rr_alias : string;
  rr_session_id : string;
  rr_outcome : rearm_outcome;
}

let rearm_skip_fixture () =
  match Sys.getenv_opt "C2C_KIMI_HOOK_SKIP_NOTIFIER" with
  | Some v ->
      let t = String.lowercase_ascii (String.trim v) in
      t = "1" || t = "true" || t = "yes"
  | None -> false

(* Arm a notifier for every DEAF kimi session. Pure w.r.t. healthy sessions:
   it only iterates [kd_deaf], each of which is guaranteed [notifier_running =
   false]. Never raises. Exposed for unit tests. *)
let rearm_deaf_kimi_sessions ?broker_root () : rearm_result list =
  let broker_root =
    match broker_root with
    | Some r -> r
    | None -> C2c_utils.resolve_broker_root ()
  in
  let delivery = check_kimi_delivery ~broker_root () in
  let skip = rearm_skip_fixture () in
  List.map
    (fun (i : kimi_session_issue) ->
      let outcome =
        if skip then Rearm_skipped_fixture
        (* #42(A3): CONFIRM-DEAD before deciding NOT to re-arm. Only a positively
           confirmed-dead process ([Some false]) is skipped — arming there would
           fork a notifier that POSTs headless turns into a dead session (quota
           burn) and eats its mail. Unknown liveness ([None] — pidless legacy /
           torn-down managed row) is NOT treated as death: we preserve the
           existing heal for sessions whose liveness we cannot establish. *)
        else if i.ksi_proc_alive = Some false then Rearm_skipped_dead
        else
          try
            match
              C2c_kimi_notifier.ensure_daemon
                ~alias:i.ksi_alias ~broker_root
                ~session_id:i.ksi_session_id ~tmux_pane:None ()
            with
            | Some _ -> Rearm_armed
            | None ->
                if C2c_kimi_notifier.already_running i.ksi_alias then
                  Rearm_already_running
                else Rearm_failed "ensure_daemon returned no pid"
          with e -> Rearm_failed (Printexc.to_string e)
      in
      { rr_alias = i.ksi_alias
      ; rr_session_id = i.ksi_session_id
      ; rr_outcome = outcome })
    delivery.kd_deaf

let pp_rearm_human (results : rearm_result list) =
  if results = [] then
    print_endline "no DEAF kimi sessions to re-arm"
  else
    List.iter
      (fun r ->
        let status =
          match r.rr_outcome with
          | Rearm_armed -> "re-armed notifier"
          | Rearm_already_running -> "notifier already running"
          | Rearm_failed msg -> "FAILED: " ^ msg
          | Rearm_skipped_fixture -> "attempted (fixture skip — no fork)"
          | Rearm_skipped_dead -> "skipped (process confirmed dead — not re-armed)"
        in
        Printf.printf "kimi %s (session %s): %s\n"
          r.rr_alias r.rr_session_id status)
      results

(* --- Grok identity-drift detector (#23a) + wake honesty (#37) -------------- *)

(* A grok registration, mirroring is_kimi_registration: client_type=grok, or
   registered_by=grok-hook, or the sticky client prefix "grok-". *)
let is_grok_registration (r : C2c_mcp.registration) =
  (match r.client_type with Some "grok" -> true | _ -> false)
  || (match r.registered_by with Some "grok-hook" -> true | _ -> false)
  || (let a = String.lowercase_ascii r.alias in
      String.length a >= 5 && String.sub a 0 5 = "grok-")

(* #37 pure classifier: Grok idle wake is never GUARANTEED. A live per-alias
   monitor lock (cheap evidence that `c2c monitor` is armed) upgrades NONE →
   CONDITIONAL for that session. Arming remains a model decision. *)
let classify_grok_wake ~(monitor_alive : bool) : grok_wake_class =
  if monitor_alive then Grok_wake_conditional_monitor else Grok_wake_none

let grok_wake_class_label = function
  | Grok_wake_none -> "NONE"
  | Grok_wake_conditional_monitor -> "CONDITIONAL"

let grok_wake_class_detail = function
  | Grok_wake_none ->
      "NONE at true idle (no local inject API; CONDITIONAL only if agent armed c2c monitor)"
  | Grok_wake_conditional_monitor ->
      "CONDITIONAL (live c2c monitor lock detected — still a model-armed path, not a guarantee)"

(* An active_sessions.json foreground entry: its session id and pid liveness.
   Liveness is checked directly against /proc (the doctor process is unrelated
   to the Grok TUI process tree, so ancestor-pid resolution would be wrong). *)
type grok_active_entry = {
  gae_session_id : string;
  gae_pid : int option;
  gae_alive : bool;
}

let pid_alive pid = C2c_liveness.pid_alive pid

(* Cheap read of <broker>/.monitor-locks/<alias>.lock: true only when the
   lockfile holds a pid that is currently alive in /proc. Stale/missing locks
   and unreadable files are false. Matches #354 lock layout. *)
let grok_monitor_lock_alive ~broker_root ~alias =
  let lock_path =
    Filename.concat
      (Filename.concat broker_root ".monitor-locks")
      (alias ^ ".lock")
  in
  if not (Sys.file_exists lock_path) then false
  else
    try
      let ic = open_in lock_path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
          let line =
            try String.trim (input_line ic) with End_of_file -> ""
          in
          match int_of_string_opt line with
          | Some p when p > 0 -> pid_alive p
          | _ -> false)
    with _ -> false

(* Parse ~/.grok/active_sessions.json (path via the shared helper, which honors
   C2C_GROK_ACTIVE_SESSIONS for tests). Pure/read-only; [] on any error. Unlike
   session_id_from_grok_active_sessions it does NOT filter by ancestor pid — it
   reports every entry with its own /proc liveness. *)
let read_grok_active_entries ?path () : grok_active_entry list =
  let path =
    match path with
    | Some p -> p
    | None -> C2c_mcp_helpers_post_broker.grok_active_sessions_path ()
  in
  if not (Sys.file_exists path) then []
  else
    match (try Some (Yojson.Safe.from_file path) with _ -> None) with
    | Some (`List entries) ->
        List.filter_map
          (function
            | `Assoc fields ->
                let sid =
                  match List.assoc_opt "session_id" fields with
                  | Some (`String s) when String.trim s <> "" ->
                      Some (String.trim s)
                  | _ -> None
                in
                let pid =
                  match List.assoc_opt "pid" fields with
                  | Some (`Int p) -> Some p
                  | Some (`Intlit s) -> int_of_string_opt s
                  | Some (`Float f) -> Some (int_of_float f)
                  | _ -> None
                in
                (match sid with
                 | Some sid ->
                     let alive =
                       match pid with Some p -> pid_alive p | None -> false
                     in
                     Some { gae_session_id = sid; gae_pid = pid; gae_alive = alive }
                 | None -> None)
            | _ -> None)
          entries
    | _ -> []

(* Grok-scoped identity candidates for remediation, reusing the shared #26
   shape so `c2c doctor` and the identity fail-closed surface agree. *)
let grok_candidates ~broker_root =
  C2c_identity_candidates.candidate_registrations ~broker_root
  |> List.filter (fun (alias, _sid, client, registered_by, _liveness) ->
       client = "grok"
       || registered_by = "grok-hook"
       || (let a = String.lowercase_ascii alias in
           String.length a >= 5 && String.sub a 0 5 = "grok-"))

let check_grok_identity ?broker_root () : grok_identity_result =
  let broker_root =
    match broker_root with
    | Some r -> r
    | None -> C2c_utils.resolve_broker_root ()
  in
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let regs = try C2c_mcp.Broker.list_registrations broker with _ -> [] in
  let grok_regs = List.filter is_grok_registration regs in
  let grok_reg_sids =
    List.map (fun (r : C2c_mcp.registration) -> r.session_id) grok_regs
  in
  let statefile_sid = C2c_identity_candidates.read_session_statefile ~broker_root in
  let active = read_grok_active_entries () in
  let alive_active_sids =
    List.filter_map
      (fun e -> if e.gae_alive then Some e.gae_session_id else None)
      active
  in
  (* grok registrations corroborated by an alive foreground active_sessions
     entry — the only identities we treat as authoritative. *)
  let live_grok_sids =
    List.filter (fun sid -> List.mem sid alive_active_sids) grok_reg_sids
  in
  let sole_live =
    match live_grok_sids with [ sid ] -> Some sid | _ -> None
  in
  let statefile_is_grok =
    match statefile_sid with
    | Some sid -> List.mem sid grok_reg_sids
    | None -> false
  in
  (* Flag conditions (see #23). Detector is quiet when there are no grok
     registrations at all — nothing to disambiguate. *)
  let reason =
    if grok_regs = [] then None
    else
      match statefile_sid with
      | Some sid when statefile_is_grok
                      && not (List.mem sid alive_active_sids) ->
          Some
            (Printf.sprintf
               "the CLI statefile identity (session %s) is a grok registration \
                that is NOT an alive foreground Grok session (its pid is dead or \
                absent from ~/.grok/active_sessions.json) — inbound DMs are being \
                misattributed to a stale identity"
               sid)
      | Some sid
        when statefile_is_grok && sole_live <> None
             && sole_live <> Some sid ->
          Some
            (Printf.sprintf
               "the CLI statefile identity (session %s) disagrees with the live \
                Grok session resolved from ~/.grok/active_sessions.json (session \
                %s)"
               sid
               (match sole_live with Some s -> s | None -> "?"))
      | _ ->
          if List.length grok_regs >= 2 && sole_live = None then
            Some
              (Printf.sprintf
                 "%d grok registrations exist but none is a singly-corroborated \
                  live foreground session in ~/.grok/active_sessions.json — \
                  identity is ambiguous and DMs may be misrouted"
                 (List.length grok_regs))
          else None
  in
  let flagged = reason <> None in
  let remediation =
    if not flagged then []
    else
      let live_hint =
        match sole_live with
        | Some sid -> Printf.sprintf "export C2C_MCP_SESSION_ID=%s" sid
        | None ->
            "export C2C_MCP_SESSION_ID=<your live grok session id>   # pick YOURS below"
      in
      let cands = grok_candidates ~broker_root in
      live_hint
      :: (if cands = [] then []
          else
            "candidate grok identities in this broker:"
            :: List.map
                 (fun c -> "  " ^ C2c_identity_candidates.render_candidate_registration c)
                 cands)
  in
  (* #37: per-session wake class. Prefer the cheap monitor-lock probe when a
     live pid is present; otherwise stay NONE. Overall class is CONDITIONAL if
     any session has a live monitor, else NONE when any grok regs exist. *)
  let wake_sessions =
    List.map
      (fun (r : C2c_mcp.registration) ->
        let monitor_alive =
          grok_monitor_lock_alive ~broker_root ~alias:r.alias
        in
        let cls = classify_grok_wake ~monitor_alive in
        { gws_alias = r.alias;
          gws_session_id = r.session_id;
          gws_monitor_alive = monitor_alive;
          gws_class = cls })
      grok_regs
  in
  let wake_class =
    if List.exists (fun s -> s.gws_class = Grok_wake_conditional_monitor) wake_sessions
    then Grok_wake_conditional_monitor
    else Grok_wake_none
  in
  { gid_grok_regs = List.length grok_regs;
    gid_statefile_sid = statefile_sid;
    gid_live_grok_sids = live_grok_sids;
    gid_flagged = flagged;
    gid_reason = reason;
    gid_remediation = remediation;
    gid_wake_class = wake_class;
    gid_wake_sessions = wake_sessions }

let check ?(dirs = claude_dirs ()) () =
  let dirs = List.filter (fun d -> Sys.file_exists d && Sys.is_directory d) dirs in
  let dir_results = List.map scan_dir dirs in
  let total_referenced = List.fold_left (fun acc d -> acc + d.referenced) 0 dir_results in
  let total_dangling = List.fold_left (fun acc d -> acc + List.length d.dangling) 0 dir_results in
  let total_skipped = List.fold_left (fun acc d -> acc + d.skipped) 0 dir_results in
  let codex = check_codex_managed_blocks () in
  let agy = check_agy_status () in
  let kimi = check_kimi_delivery () in
  let kimi_hook = check_kimi_session_start_hook () in
  let grok = check_grok_identity () in
  { dirs = dir_results; total_referenced; total_dangling; total_skipped; codex; agy; kimi; kimi_hook; grok }

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
  end;
  Printf.printf "\n=== Kimi delivery (B238) ===\n\n";
  (* #42(B): managed instances present on disk but never registered — a distinct
     failure from "registered but no notifier", printed first so it is not lost
     when there are also registered sessions. *)
  if r.kimi.kd_unregistered_managed <> [] then begin
    Printf.printf "  managed instance(s) on disk with NO registration here:\n";
    List.iter
      (fun (u : kimi_unregistered_managed) ->
        Printf.printf "    ✗ %s (alias=%s session=%s) — not registered\n"
          u.kum_name u.kum_alias u.kum_session_id;
        Printf.printf "      → fix: %s\n" u.kum_fix_command)
      r.kimi.kd_unregistered_managed
  end;
  if r.kimi.kd_sessions_checked = 0 then
    (if r.kimi.kd_unregistered_managed = [] then
       Printf.printf "No registered Kimi sessions on this broker.\n")
  else begin
    Printf.printf "  registered kimi sessions: %d\n" r.kimi.kd_sessions_checked;
    if r.kimi.kd_deaf = [] && r.kimi.kd_no_notifier = [] then
      Printf.printf "  all have a live c2c kimi-notifier (or empty+armed).\n"
    else begin
      if r.kimi.kd_deaf <> [] then begin
        Printf.printf "  DEAF (undelivered inbox + no notifier):\n";
        List.iter
          (fun (i : kimi_session_issue) ->
            Printf.printf "    ✗ %s session=%s inbox=%d registered_by=%s\n"
              i.ksi_alias i.ksi_session_id i.ksi_inbox_count
              (match i.ksi_registered_by with Some s -> s | None -> "?");
            Printf.printf "      → fix:\n";
            List.iter
              (fun line -> Printf.printf "        %s\n" line)
              (String.split_on_char '\n' i.ksi_fix_command))
          r.kimi.kd_deaf
      end;
      let warn_only =
        List.filter
          (fun (i : kimi_session_issue) ->
             not (List.exists
                    (fun (d : kimi_session_issue) -> d.ksi_alias = i.ksi_alias)
                    r.kimi.kd_deaf))
          r.kimi.kd_no_notifier
      in
      if warn_only <> [] then begin
        Printf.printf "  no notifier (inbox empty — will go deaf on first DM):\n";
        List.iter
          (fun (i : kimi_session_issue) ->
            Printf.printf "    ⚠ %s session=%s registered_by=%s\n"
              i.ksi_alias i.ksi_session_id
              (match i.ksi_registered_by with Some s -> s | None -> "?"))
          warn_only
      end
    end
  end;
  Printf.printf "\n=== Kimi SessionStart hook (delivery identity #41) ===\n\n";
  if not r.kimi_hook.khook_config_exists then
    Printf.printf "Kimi c2c install not detected (no %s).\n" r.kimi_hook.khook_config_path
  else if r.kimi_hook.khook_installed then
    Printf.printf
      "  SessionStart hook: OK (`c2c hook kimi` present — delivery-identity record authoritative per #41)\n"
  else begin
    Printf.printf
      "  ✗ DEGRADED: `c2c hook kimi` SessionStart hook is NOT installed in %s.\n"
      r.kimi_hook.khook_config_path;
    Printf.printf
      "      Kimi delivery-identity resolution reverts to session_index.jsonl index-order guessing (the #41 regression):\n";
    Printf.printf
      "      mail can be POSTed to the PREVIOUS session in this workspace, silently.\n";
    Printf.printf "      → fix: c2c install kimi\n"
  end;
  Printf.printf "\n=== Grok identity check ===\n\n";
  if r.grok.gid_grok_regs = 0 then
    Printf.printf "No registered Grok sessions on this broker.\n"
  else begin
    Printf.printf "  registered grok sessions: %d\n" r.grok.gid_grok_regs;
    Printf.printf "  statefile identity: %s\n"
      (match r.grok.gid_statefile_sid with Some s -> s | None -> "(none)");
    Printf.printf "  live grok sessions (active_sessions.json): %s\n"
      (match r.grok.gid_live_grok_sids with
       | [] -> "(none corroborated)"
       | l -> String.concat ", " l);
    if not r.grok.gid_flagged then
      Printf.printf "  identity OK (no drift detected).\n"
    else begin
      (match r.grok.gid_reason with
       | Some reason -> Printf.printf "  ✗ DRIFT: %s\n" reason
       | None -> ());
      if r.grok.gid_remediation <> [] then begin
        Printf.printf "      → fix:\n";
        List.iter
          (fun line -> Printf.printf "        %s\n" line)
          r.grok.gid_remediation
      end
    end;
    (* #37: honest wake class — Grok has no local inject API. *)
    Printf.printf "  wake: %s\n"
      (grok_wake_class_detail r.grok.gid_wake_class);
    List.iter
      (fun (s : grok_wake_session) ->
        Printf.printf "    %s (session %s): %s%s\n"
          s.gws_alias s.gws_session_id
          (grok_wake_class_label s.gws_class)
          (if s.gws_monitor_alive then " (monitor lock alive)" else ""))
      r.grok.gid_wake_sessions;
    if r.grok.gid_wake_class = Grok_wake_none then
      Printf.printf
        "      → arm: Monitor({ description: \"c2c inbox watcher\", \
         command: \"c2c monitor\", persistent: true })\n"
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
  let kimi_issue_to_json (i : kimi_session_issue) =
    `Assoc [
      ("alias", `String i.ksi_alias);
      ("session_id", `String i.ksi_session_id);
      ("inbox_count", `Int i.ksi_inbox_count);
      ("notifier_running", `Bool i.ksi_notifier_running);
      ("registered_by",
       match i.ksi_registered_by with Some s -> `String s | None -> `Null);
      ("proc_alive",
       (match i.ksi_proc_alive with Some b -> `Bool b | None -> `Null));
      ("fix_command", `String i.ksi_fix_command)
    ]
  in
  let kimi_unregistered_to_json (u : kimi_unregistered_managed) =
    `Assoc [
      ("name", `String u.kum_name);
      ("alias", `String u.kum_alias);
      ("session_id", `String u.kum_session_id);
      ("fix_command", `String u.kum_fix_command)
    ]
  in
  let kimi_to_json (k : kimi_delivery_result) =
    `Assoc [
      ("sessions_checked", `Int k.kd_sessions_checked);
      ("deaf", `List (List.map kimi_issue_to_json k.kd_deaf));
      ("no_notifier", `List (List.map kimi_issue_to_json k.kd_no_notifier));
      ("deaf_count", `Int (List.length k.kd_deaf));
      ("no_notifier_count", `Int (List.length k.kd_no_notifier));
      (* #42(B): managed instances on disk with no live registration here. *)
      ("unregistered_managed",
       `List (List.map kimi_unregistered_to_json k.kd_unregistered_managed));
      ("unregistered_managed_count",
       `Int (List.length k.kd_unregistered_managed))
    ]
  in
  let kimi_hook_to_json (k : kimi_hook_result) =
    `Assoc [
      ("config_path", `String k.khook_config_path);
      ("config_exists", `Bool k.khook_config_exists);
      ("session_start_hook_installed", `Bool k.khook_installed);
      (* degraded iff kimi is in use (config present) but the hook block is absent *)
      ("delivery_identity_degraded",
       `Bool (k.khook_config_exists && not k.khook_installed))
    ]
  in
  let grok_wake_session_to_json (s : grok_wake_session) =
    `Assoc [
      ("alias", `String s.gws_alias);
      ("session_id", `String s.gws_session_id);
      ("monitor_alive", `Bool s.gws_monitor_alive);
      ("wake_class", `String (grok_wake_class_label s.gws_class))
    ]
  in
  let grok_to_json (g : grok_identity_result) =
    `Assoc [
      ("grok_registrations", `Int g.gid_grok_regs);
      ("statefile_sid",
       match g.gid_statefile_sid with Some s -> `String s | None -> `Null);
      ("live_grok_sids", `List (List.map (fun s -> `String s) g.gid_live_grok_sids));
      ("flagged", `Bool g.gid_flagged);
      ("reason", match g.gid_reason with Some s -> `String s | None -> `Null);
      ("remediation", `List (List.map (fun s -> `String s) g.gid_remediation));
      ("wake_class", `String (grok_wake_class_label g.gid_wake_class));
      ("wake_detail", `String (grok_wake_class_detail g.gid_wake_class));
      ("wake_sessions", `List (List.map grok_wake_session_to_json g.gid_wake_sessions))
    ]
  in
  `Assoc [
    ("dirs", `List (List.map dir_to_json r.dirs));
    ("total_referenced", `Int r.total_referenced);
    ("total_dangling", `Int r.total_dangling);
    ("total_skipped", `Int r.total_skipped);
    ("codex_managed_blocks", codex_to_json r.codex);
    ("total_codex_issues", `Int r.codex.total_issues);
    ("agy", agy_to_json r.agy);
    ("kimi_delivery", kimi_to_json r.kimi);
    ("kimi_session_start_hook", kimi_hook_to_json r.kimi_hook);
    ("grok_identity", grok_to_json r.grok)
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
          rep.cdr_instances));
    (* #27: machine-readable DEAF rollup, mirroring the kimi deaf/deaf_count
       fields so scripted consumers can detect a silently-deaf managed codex
       without re-deriving the mode classification. *)
    ("deaf",
     `List
       (List.map
          (fun i ->
            `Assoc [
              ("name", `String i.ci_name);
              ("mode", `String (codex_delivery_mode_label i.ci_delivery.cd_mode))
            ])
          (codex_deaf_instances rep)));
    ("deaf_count", `Int (List.length (codex_deaf_instances rep)));
    ("deaf_summary",
     match codex_deaf_summary rep with Some s -> `String s | None -> `Null)
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
      rep.cdr_instances;
  (* #27: prominent DEAF rollup so a silently-deaf managed codex (dead deliver
     loop / stale heartbeat / failed app-server) is not buried in the per-
     instance list — mirrors the Kimi DEAF summary line. *)
  (match codex_deaf_instances rep with
   | [] -> ()
   | deaf ->
       Printf.printf
         "\n  ✗ DEAF: %d managed codex instance(s) with no live c2c delivery path:\n"
         (List.length deaf);
       List.iter
         (fun i ->
           Printf.printf "    ✗ %s (%s)\n" i.ci_name
             (codex_delivery_mode_label i.ci_delivery.cd_mode))
         deaf;
       Printf.printf
         "    → mail to these queues but may not be read at arrival time; \
          see `c2c doctor hooks`\n")

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
    (codex_delivery_mode_label rep.cdr_default.cd_mode) inst_str;
  (* #27: append the DEAF rollup line so the compact `c2c doctor` summary also
     surfaces a silently-deaf managed codex, mirroring the Kimi DEAF line. *)
  (match codex_deaf_summary rep with
   | Some line -> Printf.printf "%s\n" line
   | None -> ())

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
      r.codex.total_issues;
  let n_deaf = List.length r.kimi.kd_deaf in
  let n_none = List.length r.kimi.kd_no_notifier in
  let n_unreg = List.length r.kimi.kd_unregistered_managed in
  (* #42(B): surface unregistered managed instances distinctly in the rollup. *)
  if n_unreg > 0 then
    Printf.printf
      "Kimi delivery: %d managed instance(s) on disk NOT registered — run 'c2c restart <name>'\n"
      n_unreg;
  if r.kimi.kd_sessions_checked = 0 then
    (if n_unreg = 0 then
       Printf.printf "Kimi delivery: no registered kimi sessions\n")
  else if n_deaf > 0 then
    Printf.printf
      "Kimi delivery: %d DEAF (undelivered+no notifier) — run 'c2c doctor hooks'\n"
      n_deaf
  else if n_none > 0 then
    Printf.printf
      "Kimi delivery: %d session(s) without notifier — prefer 'c2c start kimi'\n"
      n_none
  else
    Printf.printf "Kimi delivery: %d session(s) armed\n"
      r.kimi.kd_sessions_checked;
  if r.grok.gid_grok_regs = 0 then
    Printf.printf "Grok identity: no registered grok sessions\n"
  else begin
    if r.grok.gid_flagged then
      Printf.printf
        "Grok identity: DRIFT (%d registration(s)) — run 'c2c doctor hooks'\n"
        r.grok.gid_grok_regs
    else
      Printf.printf "Grok identity: %d session(s), no drift\n"
        r.grok.gid_grok_regs;
    (* #37 compact wake honesty line — always printed when grok regs exist. *)
    Printf.printf "Grok wake: %s\n"
      (grok_wake_class_detail r.grok.gid_wake_class)
  end

(* --- CLI ------------------------------------------------------------------ *)

(* --- --fix: restore dangling c2c-owned hook scripts ----------------------- *)

(* Known c2c-owned Claude hook scripts mapped to their canonical content — the
   same sources `c2c install claude` writes. When a profile-share setup shares
   ~/.claude*/hooks -> ~/.claude-shared/hooks and one profile's `c2c uninstall`
   removes the shared script, sibling profiles keep a dangling settings.json
   reference (#19); `--fix` rewrites the script from these constants. *)
let c2c_hook_script_content basename =
  match basename with
  | "c2c-inbox-check.sh" -> Some C2c_claude_hook_scripts.claude_hook_script
  | "c2c-stop-deliver.sh" -> Some C2c_claude_hook_scripts.claude_stop_hook_script
  | "c2c-session-hook.sh" -> Some C2c_claude_hook_scripts.claude_session_hook_script
  | _ -> None

(* [path] comes from the operator's own settings.json (a dangling reference, so
   no file is clobbered) and [content] is a fixed benign c2c script — anyone who
   can edit settings.json already controls the hook command that runs, so writing
   the canonical script to wherever they pointed it is not an added trust
   boundary. *)
let restore_hook_script path content =
  try
    let dir = Filename.dirname path in
    (try C2c_utils.mkdir_p dir with _ -> ());
    let tmp = Printf.sprintf "%s.tmp.%d" path (Unix.getpid ()) in
    let oc = open_out_bin tmp in
    Fun.protect ~finally:(fun () -> close_out oc)
      (fun () -> output_string oc content);
    Unix.chmod tmp 0o755;
    Unix.rename tmp path;
    Ok ()
  with e -> Error (Printexc.to_string e)

(* Restore every dangling c2c-owned hook script, deduped by path (the same
   shared script is typically referenced by several profiles). Returns
   (restored, unknown, failed). Never raises. *)
let fix_dangling (r : result) =
  let seen = Hashtbl.create 16 in
  let restored = ref [] and unknown = ref [] and failed = ref [] in
  List.iter
    (fun (dir : dir_result) ->
      List.iter
        (fun (d : dangling) ->
          let path = d.command_path in
          if not (Hashtbl.mem seen path) then begin
            Hashtbl.add seen path ();
            match c2c_hook_script_content (Filename.basename path) with
            | None -> unknown := path :: !unknown
            | Some content -> (
                match restore_hook_script path content with
                | Ok () -> restored := path :: !restored
                | Error msg -> failed := (path, msg) :: !failed)
          end)
        dir.dangling)
    r.dirs;
  (List.rev !restored, List.rev !unknown, List.rev !failed)

let c2c_doctor_hooks_cmd =
  let json =
    Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Output machine-readable JSON.")
  in
  let compact =
    Cmdliner.Arg.(value & flag & info [ "compact" ]
      ~doc:"Single-line summary suitable for 'c2c doctor' rollup.")
  in
  let fix =
    Cmdliner.Arg.(value & flag & info [ "fix" ]
      ~doc:"Restore dangling c2c-owned Claude hook scripts \
            (c2c-inbox-check.sh, c2c-stop-deliver.sh, c2c-session-hook.sh) to \
            the paths referenced by settings.json, rewriting them from the same \
            source `c2c install claude` uses. Settings.json is not modified. \
            With --json the repair still runs, silently, so the emitted report \
            reflects the post-fix state.")
  in
  let rearm =
    Cmdliner.Arg.(value & flag & info [ "rearm" ]
      ~doc:"Self-heal DEAF kimi sessions: for every kimi registration with an \
            undelivered inbox and no running notifier (B238), arm a notifier \
            keyed by the registration's real session_id so queued mail drains. \
            Healthy/idle sessions are never touched. With --json the repair \
            still runs, silently, so the emitted report reflects the post-arm \
            state.")
  in
  let cmd =
    let+ json = json
    and+ compact = compact
    and+ fix = fix
    and+ rearm = rearm in
    (if fix then begin
       let r0 = check () in
       let restored, unknown, failed = fix_dangling r0 in
       (* Under --json, repair silently so we don't corrupt the JSON envelope;
          the post-fix [check ()] below reflects the result. *)
       if not json then begin
         List.iter (Printf.printf "restored hook script: %s\n") restored;
         List.iter
           (Printf.printf
              "cannot auto-restore (not a c2c-owned hook script): %s\n")
           unknown;
         List.iter
           (fun (p, m) -> Printf.printf "FAILED to restore %s: %s\n" p m)
           failed;
         if restored = [] && unknown = [] && failed = [] then
           print_endline "no dangling c2c hook scripts to restore";
         print_newline ();
         flush stdout
       end
     end);
    (if rearm then begin
       let results = rearm_deaf_kimi_sessions () in
       (* Under --json, arm silently so we don't corrupt the JSON envelope; the
          post-arm [check ()] below reflects the result. *)
       if not json then begin
         pp_rearm_human results;
         print_newline ();
         flush stdout
       end
     end);
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
    (* #27: codex DEAF now fails the check too (see [doctor_hooks_exit_failure])
       — otherwise `c2c doctor hooks` printed the red DEAF block and still
       exited 0, so no script/CI could detect the failure it exists to surface. *)
    if doctor_hooks_exit_failure
         ~total_dangling:r.total_dangling
         ~codex_issues:r.codex.total_issues
         ~kimi_deaf:(List.length r.kimi.kd_deaf)
         ~grok_flagged:r.grok.gid_flagged
         ~codex_deaf:(List.length (codex_deaf_instances delivery))
    then exit 1
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "hooks"
       ~doc:"Check Claude Code settings.json hook entries for dangling c2c \
             scripts, Codex managed-block drift, the live Codex delivery \
             mode (app-server / app-server-unavailable / hooks+wake / hooks / \
             unavailable), Kimi sessions that are DEAF (undelivered inbox \
             + no notifier — B238), Grok identity drift (statefile identity \
             not corroborated by a live foreground session — #23), and Grok \
             wake class honesty (NONE / CONDITIONAL-if-monitor-armed — #37).")
    cmd
