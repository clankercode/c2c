(* c2c_hook_cmd - Claude Code hook subcommands.
   Extracted from c2c.ml as part of the architecture refactoring. *)

let min_hook_runtime_ms = 100.0

let sleep_to_min_runtime start_time =
  (* Sleep so total runtime is at least min_hook_runtime_ms. Prevents Node.js
     ECHILD race: fast-exiting hooks are reaped by the kernel before Claude
     Code's waitpid(), which then fails with ECHILD. *)
  let elapsed_ms = (Unix.gettimeofday () -. start_time) *. 1000.0 in
  let sleep_s = max 0.0 ((min_hook_runtime_ms -. elapsed_ms) /. 1000.0) in
  if sleep_s > 0.0 then Unix.sleepf sleep_s

let hook_post_tool_cmd =
  (* Claude PostToolUse hook — CLI fallback for the standalone
     c2c-inbox-hook-ocaml binary (`~/.claude/hooks/c2c-inbox-check.sh` runs
     whichever is found first). Delivery semantics are shared through
     C2c_hook_lib.run_post_tool so both paths behave identically
     (claude-full-delivery slice): full message delivery by default with a
     push-only drain (deferrable messages wait for the next turn boundary,
     mirroring codex PostToolUse), the #387 A2 channel-capable skip (the MCP
     watcher owns delivery for managed claude — no dual-drain), the B042
     subagent guard, cold-boot fallback context, and the
     C2C_POST_TOOL_NUDGE_ONLY=1 legacy debounced-nudge opt-out. Session id
     resolves from the hook's stdin JSON first, then C2C_MCP_SESSION_ID. *)
  let open Cmdliner.Term in
  const (fun () ->
    let start_time = Unix.gettimeofday () in
    let exit_floored code =
      sleep_to_min_runtime start_time;
      exit code
    in
    if C2c_hook_lib.is_subagent_quiet () then exit_floored 0;
    (* B130: PostToolUse fires during a dispatched subagent's tool calls with a
       non-empty stdin `agent_id`. Draining/injecting there would leak the
       owner session's DMs into the unrelated subagent transcript. Top-level
       turns omit agent_id, so delivery is unaffected. *)
    if C2c_hook_lib.stdin_is_subagent_turn () then exit_floored 0;
    let session_id =
      match C2c_hook_lib.resolve_session_id () with
      | Ok "" -> exit_floored 0
      | Ok sid -> sid
      | Error msg -> prerr_endline msg; exit_floored 1
    in
    let broker_root = C2c_hook_lib.resolve_hook_broker_root () in
    try
      let output, _alias = C2c_hook_lib.run_post_tool ~session_id ~broker_root in
      C2c_hook_lib.print_post_tool_output output;
      exit_floored 0
    with e ->
      prerr_endline (Printexc.to_string e);
      exit_floored 1) $ const ()

let hook_post_tool : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "post-tool" ~doc:"PostToolUse hook: full-delivery drain (push-only; deferrable waits for the turn boundary) and emit messages. C2C_POST_TOOL_NUDGE_ONLY=1 restores the legacy debounced nudge line.")
    hook_post_tool_cmd

let hook_stop_cmd =
  let open Cmdliner.Term in
  const (fun () ->
    (* Uses C2c_hook_lib for shared stdin-parsing + drain logic, matching
       the standalone c2c_stop_hook.exe behaviour exactly. *)
    if C2c_hook_lib.is_subagent_quiet () then exit 0;
    (* B130: suppress on a subagent turn (non-empty stdin agent_id). Claude Code
       actually fires SubagentStop (not Stop) at a subagent turn end, so this is
       defensive; top-level Stop turns omit agent_id and deliver normally. *)
    if C2c_hook_lib.stdin_is_subagent_turn () then exit 0;
    let session_id =
      match C2c_hook_lib.resolve_session_id () with
      | Ok sid -> sid
      | Error _ -> exit 0
    in
    let broker_root = C2c_hook_lib.resolve_hook_broker_root () in
    if session_id = "" then exit 0;
    try
      let repo_broker, messages, _alias =
        (* Stop is a turn boundary: full drain, deferrable included. *)
        C2c_hook_lib.drain_all_messages ~push_only:false ~session_id
          ~broker_root ()
      in
      if messages = [] then exit 0;
      let messages_text = C2c_hook_lib.format_messages_as_text ~repo_broker messages in
      (* Stop's additionalContext is the documented non-error feedback path:
         it keeps the conversation going without representing ordinary c2c
         mail as a failed hook or a control-plane decision. *)
      let json : Yojson.Safe.t =
        `Assoc
          [ ( "hookSpecificOutput"
            , `Assoc
                [ ("hookEventName", `String "Stop")
                ; ("additionalContext", `String messages_text)
                ] )
          ]
      in
      Printf.printf "%s\n" (Yojson.Safe.to_string json);
      exit 0
    with e ->
      prerr_endline (Printexc.to_string e);
      exit 1) $ const ()

let hook_stop : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "stop" ~doc:"Stop hook: deliver queued messages on text-only turns as non-error additional context.")
    hook_stop_cmd

(* --- Codex hook (#5, vanilla-codex slice) ------------------------------------

   One command serves every codex hook event: the payload's hook_event_name
   tells us which event fired. Installed by `c2c install codex` for
   UserPromptSubmit + PostToolUse + SessionStart + SessionEnd (see C2c_codex_hooks for the
   event-choice rationale).

   Contract with codex (validated against codex-rs 0.142 schemas):
   - stdin: JSON payload {hook_event_name, session_id, cwd, ...}
   - stdout: either empty (no-op) or
       {"hookSpecificOutput":{"hookEventName":"<event>","additionalContext":"..."}}
     hookEventName is REQUIRED and must equal the event name (per-event const
     in the output schema, additionalProperties=false).
   - NEVER break the codex turn: any error -> exit 0 with empty stdout.
     Runtime is hard-capped via alarm() well under the configured hook
     timeout. *)

(* Events whose codex output schema supports hookSpecificOutput.additionalContext.
   Stop is absent on purpose: its output supports decision=block only, so
   draining on Stop would eat messages we cannot deliver. *)
let codex_context_events =
  [ "SessionStart"; "SessionEnd"; "UserPromptSubmit"; "PostToolUse"; "PreToolUse" ]

(* Codex emits one PostToolUse event per tool call, often as a burst.  A short
   fingerprint-aware debounce avoids redoing empty-inbox work for that burst.
   The fingerprint covers both the repo and cross-repo inboxes: a newly queued
   message always changes it and bypasses the debounce, so this is coalescing
   only, never a reason to defer delivery. *)
let codex_post_tool_debounce_s = 0.5

let codex_inbox_fingerprint ~roots ~session_id =
  List.map
    (fun root ->
      let path = Filename.concat root (session_id ^ ".inbox.json") in
      try
        let st = Unix.stat path in
        Printf.sprintf "%s:%d:%.9f" path st.Unix.st_size st.Unix.st_mtime
      with Unix.Unix_error _ -> path ^ ":missing")
    roots
  |> String.concat "|"

let codex_debounce_state_path ~broker_root ~session_id =
  let digest = Digestif.SHA256.digest_string session_id |> Digestif.SHA256.to_hex in
  Filename.concat (Filename.concat broker_root ".codex-hook-debounce") digest

let read_codex_debounce_state path =
  try
    match String.split_on_char '\t' (String.trim (C2c_io.read_file_opt path)) with
    | [ ts; fingerprint ] -> Some (float_of_string ts, fingerprint)
    | _ -> None
  with _ -> None

let codex_brokers_for_debounce ~broker_root ~global_root =
  [ broker_root; global_root ]
  |> List.filter (fun root -> String.trim root <> "")
  |> List.sort_uniq String.compare
  |> List.map (fun root -> C2c_mcp.Broker.create ~root)

let with_codex_debounce_locks ~broker_root ~global_root ~session_id f =
  let rec lock locked = function
    | [] -> f (List.rev locked)
    | broker :: rest ->
        C2c_mcp.Broker.with_inbox_lock broker ~session_id (fun () ->
          lock (broker :: locked) rest)
  in
  lock [] (codex_brokers_for_debounce ~broker_root ~global_root)

let codex_push_inboxes_empty ~broker_root ~global_root ~session_id =
  with_codex_debounce_locks ~broker_root ~global_root ~session_id
    (fun brokers ->
       let empty = not (List.exists
              (fun broker ->
                 C2c_mcp.Broker.inbox_has_push_messages_locked broker ~session_id)
              brokers) in
       empty)

let codex_post_tool_is_debounced ~broker_root ~global_root ~session_id =
  let fingerprint =
    codex_inbox_fingerprint ~roots:[ broker_root; global_root ] ~session_id
  in
  let path = codex_debounce_state_path ~broker_root ~session_id in
  let now = Unix.gettimeofday () in
  match read_codex_debounce_state path with
  | Some (last_ts, last_fingerprint) ->
      now -. last_ts < codex_post_tool_debounce_s
      && fingerprint = last_fingerprint
      && codex_push_inboxes_empty ~broker_root ~global_root ~session_id
  | None -> false

let record_codex_post_tool ~broker_root ~global_root ~session_id =
  try
    (* Enqueue and drain both use the same per-inbox lock.  Holding the locks
       while taking the post-drain snapshot means a message cannot be inserted
       between the empty check and state write.  Without this, a just-arrived
       message could be recorded as an unchanged fingerprint and the next hook
       would incorrectly suppress it. *)
    with_codex_debounce_locks ~broker_root ~global_root ~session_id
      (fun brokers ->
         let no_push_messages =
           not (List.exists
                  (fun broker ->
                     C2c_mcp.Broker.inbox_has_push_messages_locked broker ~session_id)
                  brokers)
         in
         if no_push_messages then begin
           let dir = Filename.dirname (codex_debounce_state_path ~broker_root ~session_id) in
           C2c_mcp.mkdir_p dir;
           let fingerprint =
             codex_inbox_fingerprint ~roots:[ broker_root; global_root ] ~session_id
           in
           ignore (C2c_io.write_file_atomic
             (codex_debounce_state_path ~broker_root ~session_id)
             (Printf.sprintf "%.9f\t%s\n" (Unix.gettimeofday ()) fingerprint))
         end)
  with _ -> ()

let read_stdin_all ~max_bytes =
  let chunk_size = 8192 in
  let chunk = Bytes.create chunk_size in
  let buf = Buffer.create chunk_size in
  let rec loop remaining =
    if remaining <= 0 then Buffer.contents buf
    else
      match input stdin chunk 0 (min chunk_size remaining) with
      | 0 -> Buffer.contents buf
      | n ->
          Buffer.add_subbytes buf chunk 0 n;
          loop (remaining - n)
  in
  try loop max_bytes with _ -> Buffer.contents buf

let payload_string_field payload name =
  match payload with
  | `Assoc fields ->
      (match List.assoc_opt name fields with
       | Some (`String s) when String.trim s <> "" -> Some (String.trim s)
       | _ -> None)
  | _ -> None

let codex_onboarding_text ~alias =
  Printf.sprintf
    "c2c: this codex session is now registered on the local agent-messaging \
     system as `%s`. Peer messages will appear automatically in your context \
     as `<c2c ...>` blocks. Key commands: `c2c whoami` (identity), `c2c list \
     --alive` (peers online), `c2c find <substr>` (peer lookup), `c2c send \
     <alias> \"msg\"` (DM), `c2c wait-inbox --timeout 5m` (blocking receive \
     when idle), `c2c rooms join swarm-lounge` (social room)."
    alias

let codex_wake_text ~alias =
  Printf.sprintf
    "c2c: connected as `%s`. Inbound agent messages arrive automatically via \
     hooks; send with `c2c send <alias> \"msg\"`, block-receive when idle \
     with `c2c wait-inbox`."
    alias

let codex_app_server_wake_text ~alias =
  Printf.sprintf
    "c2c: connected as `%s` through the managed Codex app-server. Inbound local \
     c2c messages are automatically injected into this thread at arrival time; \
     when this thread is idle, eligible local mail starts one safe steering turn. \
     Send with `c2c send <alias> \"msg\"`. Do not run `c2c init`: this session \
     is already registered."
    alias

(* --- B136: occasional app-server nudge for vanilla / hook-fallback codex -----

   Vanilla and hook-fallback codex sessions receive c2c mail at hook (turn)
   boundaries. The managed app-server transport (`c2c new codex`) delivers at
   arrival time. On SessionStart this appends a short, THROTTLED tip steering
   the operator toward the managed path — but NEVER in a session that already
   has app-server (or any managed) delivery, and only for TRULY vanilla codex
   (never launched via `c2c start/new codex`).

   Managed-marker investigation (B136): the spec proposed gating on
   [C2C_CODEX_INGRESS_LIVE] alone, on the premise it is inherited by the codex
   frontend + hooks. It is NOT: [C2c_codex_session.run_app_server] exports it in
   the launcher process only AFTER the frontend + app-server children are
   already spawned (both snapshot [Unix.environment ()] at spawn time), so the
   hooks a managed app-server session fires never see it. A managed app-server
   session also resolves in the hook as VANILLA — it persists
   `codex-session.json`, not the legacy instance `config.json` that
   [managed_session_id_from_codex_thread] reads, so [managed_sid_for_payload]
   is None; its broker registration is under the managed instance name, not the
   hook's payload thread id. B166 now gives the remote frontend the launcher's
   [C2C_MCP_SESSION_ID], while the app-server marker remains race-free before
   registration lands. INGRESS_LIVE or the thread mapping alone would therefore
   FAIL the "never nudge an app-server session" requirement.

   Fix: [C2c_codex_session.run] exports [C2C_CODEX_MANAGED=1] BEFORE any codex
   child (frontend/server/hook) is spawned, so every hook fired by a managed
   codex session inherits it. That is the load-bearing signal. The others are
   defence-in-depth. [codex_session_is_managed] ORs them all (any one
   suppresses the tip — fail toward NOT nudging):
     1. [C2C_CODEX_MANAGED] set — inherited marker for ANY managed codex launch
        (app-server AND hook-fallback). Primary, race-free.
     2. [C2C_CODEX_INGRESS_LIVE] set — belt-and-suspenders (a hook fired from
        the launcher process would see it).
     3. [C2C_MCP_SESSION_ID] set — any managed Codex frontend child env.
     4. [managed_sid_for_payload] <> None — legacy config.json thread mapping.
     5. the resolved session's registration has client_type "codex-app-server".
   See the B136 receipt for the full investigation. *)
let codex_appserver_nudge_every () =
  match Sys.getenv_opt "C2C_CODEX_APPSERVER_NUDGE_EVERY" with
  | None -> 5
  | Some s -> (match int_of_string_opt (String.trim s) with Some n -> n | None -> 5)

let codex_appserver_nudge_count_path ~broker_root =
  Filename.concat broker_root "codex-appserver-nudge.count"

let read_codex_appserver_nudge_count ~broker_root =
  try
    match
      int_of_string_opt
        (String.trim
           (C2c_io.read_file_opt (codex_appserver_nudge_count_path ~broker_root)))
    with
    | Some n when n >= 0 -> n
    | _ -> 0
  with _ -> 0

(* Returns true iff the counter was durably written. Callers gate the tip on a
   successful write so an I/O failure yields an empty tip (never a shown tip on
   a stale/failed counter). *)
let write_codex_appserver_nudge_count ~broker_root n =
  match
    (try
       C2c_io.write_file_atomic
         (codex_appserver_nudge_count_path ~broker_root)
         (string_of_int n ^ "\n")
     with _ -> Error "exn")
  with
  | Ok () -> true
  | Error _ -> false

(* Serialize the read-modify-write of the counter across concurrent SessionStart
   hooks (each is a separate process) with an flock on a sibling lockfile, so two
   simultaneous starts cannot both read N-1, both write N, and both emit. [f]
   returns the tip string ("" = no tip). Fails CLOSED — returns "" without
   running [f] — if the lockfile cannot be opened or the lock cannot be taken,
   so a lock failure can never let two hooks emit unserialized. *)
let with_codex_nudge_lock ~broker_root f =
  let lock_path = codex_appserver_nudge_count_path ~broker_root ^ ".lock" in
  match
    (try Some (Unix.openfile lock_path [ Unix.O_CREAT; Unix.O_RDWR ] 0o600)
     with _ -> None)
  with
  | None -> ""
  | Some fd ->
      Fun.protect
        ~finally:(fun () -> (try Unix.close fd with _ -> ()))
        (fun () ->
          match (try Unix.lockf fd Unix.F_LOCK 0; true with _ -> false) with
          | true -> f ()
          | false -> "")

let codex_appserver_nudge_text =
  "Tip: you're receiving c2c messages at turn boundaries (they surface when \
   your turn ends). For arrival-time delivery — messages appear the moment a \
   peer sends them — launch Codex via `c2c new codex`. Add `alias cx='c2c new \
   codex --'` to your shell rc, then `cx --model <model>`."

(* Any positive managed/app-server signal suppresses the vanilla nudge. *)
let codex_session_is_managed ~regs ~session_id ~managed_sid_for_payload =
  Sys.getenv_opt "C2C_CODEX_MANAGED" <> None
  || Sys.getenv_opt "C2C_CODEX_INGRESS_LIVE" <> None
  || (match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
      | Some s when String.trim s <> "" -> true
      | _ -> false)
  || managed_sid_for_payload <> None
  || List.exists
       (fun (r : C2c_mcp.registration) ->
          r.session_id = session_id && r.client_type = Some "codex-app-server")
       regs

(* Throttled nudge string ("" = not shown). Fully best-effort: any failure
   yields "" and never raises. Advances the persisted counter ONLY for eligible
   (truly-vanilla) fires, so managed sessions never move it, and only emits when
   the incremented counter was durably written. N<=0 disables. *)
let codex_appserver_nudge ~broker_root ~regs ~session_id ~managed_sid_for_payload
    =
  try
    let n = codex_appserver_nudge_every () in
    if n <= 0 then ""
    else if codex_session_is_managed ~regs ~session_id ~managed_sid_for_payload
    then ""
    else
      with_codex_nudge_lock ~broker_root (fun () ->
          let next = read_codex_appserver_nudge_count ~broker_root + 1 in
          if write_codex_appserver_nudge_count ~broker_root next && next mod n = 0
          then codex_appserver_nudge_text
          else "")
  with _ -> ""

let hook_codex_cmd =
  let open Cmdliner.Term in
  const (fun () ->
    (* Hard runtime cap: exit cleanly well before the configured hook timeout
       (10s) so a wedged broker dir can never stall a codex turn. *)
    (try
       Sys.set_signal Sys.sigalrm (Sys.Signal_handle (fun _ -> exit 0));
       ignore (Unix.alarm 8)
     with _ -> ());
    (try
       if C2c_hook_lib.is_subagent_quiet () then exit 0;
       let raw = read_stdin_all ~max_bytes:(1024 * 1024) in
       let payload =
         try Yojson.Safe.from_string (String.trim raw) with _ -> `Null
       in
       let event =
         match payload_string_field payload "hook_event_name" with
         | Some e -> e
         | None -> exit 0
       in
       if not (List.mem event codex_context_events) then exit 0;
       (* Auto-update the /c2c codex skill from the embedded blob on session
          start, so vanilla codex sessions pick up skill changes from a new
          binary without re-running `c2c install codex`. Best-effort. *)
       if event = "SessionStart" then C2c_setup.refresh_codex_skill_if_stale ();
       let broker_root = C2c_utils.resolve_broker_root () in
       let broker = C2c_mcp.Broker.create ~root:broker_root in
       let regs () = C2c_mcp.Broker.list_registrations broker in
       let registered sid =
         List.exists (fun (r : C2c_mcp.registration) -> r.session_id = sid) (regs ())
       in
       let payload_sid =
         match payload_string_field payload "session_id" with
         | Some s ->
             (match C2c_mcp.validate_session_id s with
              | Ok sid -> Some sid
              | Error _ -> None)
         | None -> None
       in
       let config_path =
         match Sys.getenv_opt "HOME" with
         | Some home -> Filename.concat home (Filename.concat ".codex" "config.toml")
         | None -> ""
       in
       let managed_sid_for_payload =
         match payload_sid with
         | Some tid ->
             C2c_mcp_helpers_post_broker.managed_session_id_from_codex_thread
               ~broker_root ~thread_id:tid
         | None -> None
       in
       if event = "SessionEnd" then begin
         let candidates =
           List.filter_map
             (fun x -> x)
             [ payload_sid; managed_sid_for_payload ]
         in
         (match
            List.find_opt
              (fun (r : C2c_mcp.registration) ->
                 r.registered_by = Some "codex-hook"
                 && List.exists (fun sid -> r.session_id = sid) candidates)
              (regs ())
          with
          | Some r -> ignore (C2c_mcp.Broker.deregister broker ~alias:r.alias)
          | None -> ());
         exit 0
       end;
       (* Identity resolution, most-specific first:
          1. payload session_id has a registration (previous auto-register
             or an exact-id registration) — use it.
          2. payload session_id maps to a managed `c2c start codex` instance
             (codex thread-id file) — use the managed session.
          3. for payload-free fallback events only, ambient env
             (C2C_MCP_SESSION_ID / CODEX_THREAD_ID) or the `c2c init`
             default-session statefile resolves to a registration.
          4. nothing resolved -> auto-register this codex session. The static
             installer alias hint is used only after step 2 proves a managed
             `c2c start codex` owns this payload thread; vanilla codex exec
             sessions get a fresh per-thread alias instead. *)
       (* True when [sid] resolves to a live codex-family registration — the
          launcher/hook already owns this identity. Guards managed-env adoption
          so a codex subprocess that merely inherited another client's
          C2C_MCP_SESSION_ID (e.g. a codex spawned inside managed claude) can
          never hijack that non-codex identity. *)
       let managed_codex_family_reg sid =
         List.exists
           (fun (r : C2c_mcp.registration) ->
              r.session_id = sid
              && (r.client_type = Some "codex-app-server"
                  || r.client_type = Some "codex"))
           (regs ())
       in
       let resolved =
         (* B137: a managed `c2c new codex` app-server frontend hands its broker
            session id to its hooks via the inherited env marker
            C2C_CODEX_APPSERVER_SESSION (exported by C2c_codex_session.run_app_server
            BEFORE the frontend is spawned; reset on hook-fallback so only a live
            app-server frontend carries it). That session is the identity the
            app-server deliver loop (C2c_codex_ingress) already owns. Adopt it
            directly and unconditionally — its thread->instance mapping (step2)
            is not the legacy config.json the hook reads, so it otherwise resolves
            as VANILLA and mints a SECOND per-thread identity (the B137
            dual-identity). The
            marker is race-free (does not depend on the launcher's broker
            registration having landed yet) and unambiguous (set only by the
            app-server launcher), so it is the most authoritative signal even
            though B166 also exports C2C_MCP_SESSION_ID to the frontend. *)
         let step_appserver_marker () =
           match Sys.getenv_opt "C2C_CODEX_APPSERVER_SESSION" with
           | Some s when String.trim s <> "" -> Some (String.trim s)
           | _ -> None
         in
         let step1 =
           match payload_sid with
           | Some sid when registered sid -> Some sid
           | _ -> None
         in
         let step2 () =
           match managed_sid_for_payload with
           | Some sid when registered sid -> Some sid
           | None -> None
           | Some _ -> None
         in
         (* Hook-fallback managed codex (NOT app-server): build_env sets
            C2C_MCP_SESSION_ID to the managed session id under which a prior fire
            (or the MCP server auto-register) already registered. Adopt it rather
            than mint a duplicate per-thread identity. Runs even when a payload
            session_id is present (unlike step3), reads env ONLY (no statefile
            fallback), and is gated on a codex-family client_type so a codex
            subprocess that merely inherited another client's C2C_MCP_SESSION_ID
            (e.g. codex spawned inside managed claude) cannot hijack that
          identity. App-server sessions resolve through the marker first, so
          this step remains the hook-fallback path. *)
         let step_managed_env () =
           match C2c_mcp.session_id_from_env () with
           | Some sid when managed_codex_family_reg sid -> Some sid
           | _ -> None
         in
          let step3 () =
            match payload_sid with
            | Some _ -> None
            | None ->
                (match C2c_cli_helpers.env_session_id () with
                 | Some sid when registered sid -> Some sid
                 | _ -> None)
          in
         match step_appserver_marker () with
         | Some _ as r -> r
         | None ->
         (match step1 with
         | Some _ -> step1
         | None ->
             (match step2 () with
              | Some _ as r -> r
              | None ->
                  (match step_managed_env () with
                   | Some _ as r -> r
                   | None ->
                       (match step3 () with
                        | Some _ as r -> r
                        | None -> None))))
       in
       let session_id, onboarded_alias =
         match resolved with
         | Some sid -> (sid, None)
         | None ->
             (* Auto-register: zero-setup onboarding for vanilla codex.
                Only when the payload carries a session_id — that id is
                stable for the conversation, so the registration persists
                and every later hook fire resolves via step 1 (no re-register
                loop). Without a payload sid we cannot register a stable
                identity, so stay silent. *)
             (match payload_sid with
              | None -> exit 0
              | Some payload_sid ->
                  (* from_auto_gen: client-prefixed aliases (codex-...) are on
                     the user-supplied blocklist; auto-generated ones bypass it
                     via the flag. Vanilla hooks always generate a fresh
                     payload-thread alias. Managed hooks may reuse the alias
                     `c2c install codex` wrote because the instance config maps
                     the native codex thread back to a stable c2c session id. *)
                  let managed_sid = managed_sid_for_payload in
                  let sid = Option.value managed_sid ~default:payload_sid in
                  let is_managed = Option.is_some managed_sid in
                  (* B188: prefer sticky alias for this session_id from another
                     broker fingerprint before minting / env alias. Managed
                     sessions with an explicit install/env alias still fall
                     through mint when no prior sticky hit exists.
                     B191: resolve + register run atomically under the global
                     per-session registration lock so concurrent hooks in
                     other repos converge on one alias. *)
                  let alias, _from_auto_gen, _prior_hit =
                    C2c_mcp.locked_sticky_auto_register ~session_id:sid
                      ~broker_root
                      ~mint:(fun () ->
                        if is_managed then
                          match C2c_cli_helpers.env_auto_alias () with
                          | Some a ->
                              ( a
                              , Sys.getenv_opt
                                  "C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN"
                                |> Option.map String.trim = Some "1" )
                          | None ->
                              (match
                                 C2c_codex_hooks.installer_alias_hint
                                   ~config_path
                               with
                               | Some a -> (a, true)
                               | None ->
                                   ( C2c_setup.default_alias_for_client "codex"
                                   , true ))
                        else
                          (C2c_setup.default_alias_for_client "codex", true))
                      ~register:(fun ~alias ~from_auto_gen ->
                        let pid =
                          if is_managed then
                            C2c_cli_helpers.resolve_registration_pid
                              ~session_id:sid ()
                          else
                            None
                        in
                        let pid_start_time =
                          C2c_mcp.Broker.capture_pid_start_time pid
                        in
                        let registered_by =
                          if is_managed then None else Some "codex-hook"
                        in
                        try
                          C2c_mcp.Broker.register broker ~session_id:sid ~alias
                            ~pid ~pid_start_time ~client_type:(Some "codex")
                            ~cwd:(payload_string_field payload "cwd")
                            ~registered_by
                            ~from_auto_gen ()
                        with e ->
                          (try
                             prerr_endline
                               ("c2c hook codex: auto-register failed: "
                                ^ Printexc.to_string e)
                           with _ -> ());
                          exit 0)
                      ()
                  in
                  (* Persist the identity for plain `c2c` CLI calls from this
                     codex session (same statefile `c2c init` uses), but never
                     steal a statefile that still points at a live identity. *)
                  (match C2c_cli_helpers.read_session_statefile ~broker_root with
                   | Some existing
                     when C2c_cli_helpers.statefile_session_registered ~broker_root existing -> ()
                   | _ ->
                       C2c_cli_helpers.write_session_statefile ~broker_root
                         ~session_id:sid ~alias ~client:(Some "codex"));
                  (sid, Some alias))
       in
       (* B137 / B168: is this an app-server-backed managed codex session?
          Detected by the inherited launcher marker (C2C_CODEX_APPSERVER_SESSION
          — present even before the launcher's broker registration lands, so the
          earliest hook fire is covered too) OR by the resolved session already
          carrying a "codex-app-server" registration.
          B168 decision: KEEP PostToolUse/UserPromptSubmit/Session* hooks
          ACTIVE (installed + identity adoption + onboarding wake text) for
          app-server agents — do not strip them. Delivery itself stays owned by
          the app-server deliver loop (idle inject + auto-turn, plus the 2-minute
          stale-inbox force-retry). The hook remains IDENTITY-ONLY for drain
          (adopted above; it does not register, drain, or touch wake targets) so
          we never dual-drain or dual-identity-storm. Hook-fallback managed
          codex (client_type "codex") is NOT ingress-owned — hooks remain its
          delivery + wake path. *)
       let ingress_owned =
         (match Sys.getenv_opt "C2C_CODEX_APPSERVER_SESSION" with
          | Some s when String.trim s <> "" -> true
          | _ -> false)
         || List.exists
              (fun (r : C2c_mcp.registration) ->
                 r.session_id = session_id
                 && r.client_type = Some "codex-app-server")
              (regs ())
       in
       (* Wake-target capture (codex-wake-inject): the hook runs with the
          codex process's env, so $TMUX/$TMUX_PANE and $HERDR_PANE_ID /
          $HERDR_SOCKET_PATH identify this session's pane for BOTH vanilla
          and managed sessions. Refresh on session boundaries (SessionStart —
          sessions move panes) and on fresh auto-register so the wake
          injector can nudge an idle session. Capture binds the hook process
          to the pane; exact replacement clears inherited/stale metadata when
          no valid binding exists. Must run before the B107 debounce early-exit:
          a fresh auto-register can arrive on a PostToolUse fire. *)
       let stored_wake_target =
         C2c_mcp.Broker.list_registrations broker
         |> List.find_opt (fun (r : C2c_mcp.registration) ->
                r.session_id = session_id)
         |> Option.map (fun (r : C2c_mcp.registration) ->
                r.tmux_location <> None || r.herdr_pane <> None)
         |> Option.value ~default:false
       in
       let binding_moved =
         stored_wake_target
         && not (C2c_wake_inject.binding_owns_current_process
                   ~broker_root ~session_id)
       in
       (* Never refresh wake targets for an app-server session: it delivers via
          the ingress loop (not wake-inject), so the targets are unused, and a
          NESTED codex that inherited the marker could otherwise overwrite the
          parent registration's pane. *)
       (if (not ingress_owned)
           && (event = "SessionStart" || Option.is_some onboarded_alias
               || binding_moved) then begin
          let tmux_location, herdr_pane, herdr_socket =
            C2c_wake_inject.refresh_wake_targets ~broker_root ~session_id ()
          in
          C2c_mcp.Broker.replace_wake_targets broker ~session_id
            ~tmux_location ~herdr_pane ~herdr_socket ()
        end);
       let global_root =
         try C2c_repo_fp.resolve_sessions_broker_root () with _ -> ""
       in
       if event = "PostToolUse"
          && codex_post_tool_is_debounced ~broker_root ~global_root ~session_id
       then exit 0;
       (* Drain. Turn boundaries (SessionStart / UserPromptSubmit) deliver
          everything including deferrable messages; mid-turn events
          (PostToolUse / PreToolUse) deliver only push (non-deferrable)
          messages, respecting sender intent. Ephemeral no-archive semantics
          are handled inside the broker drain. *)
       let full_drain = event = "SessionStart" || event = "UserPromptSubmit" in
       let repo_broker, messages =
         if ingress_owned then
           (* B137 / B168: app-server session — the hook drains NOTHING (still
              runs identity-only; PostToolHook stays installed/active). The
              C2c_codex_deliver_loop owns arrival-time delivery of the repo
              inbox (and B141 global inject-only); a second drainer here would
              race it and steal messages before injection / dual-delivery
              storm. Nested codex inheriting C2C_CODEX_APPSERVER_SESSION still
              cannot steal parent mail because this path never drains. Idle +
              >2min stale delivery are enforced in the app-server loop (B168),
              not by re-enabling hook drain. Identity was still adopted above,
              so no duplicate registration is created. *)
           (Some broker, [])
         else if full_drain then begin
           let repo_messages =
             if C2c_mcp.Broker.is_session_channel_capable broker ~session_id then []
             else C2c_mcp.Broker.drain_inbox ~drained_by:"hook" broker ~session_id
           in
           let global_messages =
             try
               let root = C2c_repo_fp.resolve_sessions_broker_root () in
               if C2c_hook_lib.global_inbox_exists ~root ~session_id then
                 let gb = C2c_mcp.Broker.create ~root in
                 C2c_mcp.Broker.drain_inbox ~drained_by:"hook" gb ~session_id
               else []
             with _ -> []
           in
           (Some broker, repo_messages @ global_messages)
         end
         else
           let rb, msgs, _alias =
             C2c_hook_lib.drain_all_messages ~session_id ~broker_root ()
           in
           (rb, msgs)
       in
       let messages_text = C2c_hook_lib.format_messages_as_text ~repo_broker messages in
       let intro =
         match onboarded_alias with
         | Some alias -> codex_onboarding_text ~alias
         | None ->
             if event = "SessionStart" then
               let alias =
                 List.find_map
                   (fun (r : C2c_mcp.registration) ->
                      if r.session_id = session_id then Some r.alias else None)
                   (regs ())
               in
               (match alias with
                | Some a when ingress_owned -> codex_app_server_wake_text ~alias:a
                | Some a -> codex_wake_text ~alias:a
                | None -> "")
             else ""
       in
       (* Changelog auto-show (B126): per-client, once per binary version
          change. Try-guarded — never break the turn. *)
       let changelog_context =
         if event = "SessionStart" then
           try
             Option.value
               (C2c_changelog.auto_show ~broker_root ~client:"codex"
                  ~now:(Unix.gettimeofday ()) ())
               ~default:""
           with _ -> ""
         else ""
       in
       (* B136: occasional app-server nudge — SessionStart only, vanilla only,
          throttled. Additive to the note; never replaces intro/messages. *)
       let appserver_nudge =
         if event = "SessionStart" then
           codex_appserver_nudge ~broker_root ~regs:(regs ()) ~session_id
             ~managed_sid_for_payload
         else ""
       in
       let context =
         [ intro; changelog_context; appserver_nudge; messages_text ]
         |> List.filter (fun s -> String.trim s <> "")
         |> String.concat "\n\n"
       in
       if context <> "" then begin
         let json : Yojson.Safe.t =
           `Assoc
             [ ( "hookSpecificOutput"
               , `Assoc
                   [ ("hookEventName", `String event)
                   ; ("additionalContext", `String context)
                   ] )
             ]
         in
         print_string (Yojson.Safe.to_string json);
         print_newline ()
       end;
       if event = "PostToolUse" then
         record_codex_post_tool ~broker_root ~global_root ~session_id;
       exit 0
     with
     | e ->
         (* Never break the codex turn: swallow everything, exit 0. *)
         (try prerr_endline ("c2c hook codex: " ^ Printexc.to_string e) with _ -> ());
         exit 0)) $ const ()

let hook_codex : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "codex"
       ~doc:"Codex CLI hook: reads the codex hook payload (JSON) on stdin, resolves this session's c2c identity (auto-registering vanilla sessions on first fire), drains the inbox, and emits messages as hookSpecificOutput.additionalContext. Installed into ~/.codex/config.toml by `c2c install codex`. Never fails the codex turn: errors exit 0 with empty output.")
    hook_codex_cmd

(* --- Claude session hook (claude-session-hooks slice) -------------------------

   Mirrors `c2c hook codex`'s structure and safety contract for Claude Code
   session-lifecycle events. Installed by `c2c install claude` for
   SessionStart + SessionEnd (script: ~/.claude/hooks/c2c-session-hook.sh).

   Contract with Claude Code:
   - stdin: JSON payload {hook_event_name, session_id, cwd, ...}; SessionStart
     additionally carries source: startup|resume|clear|compact.
   - stdout: either empty (no-op) or
       {"hookSpecificOutput":{"hookEventName":"<event>","additionalContext":"..."}}
   - NEVER break the claude turn: any error -> exit 0 with empty stdout.
     Runtime is hard-capped via alarm() well under the hook timeout.

   Identity resolution is env-FIRST (this differs from codex!): the hook
   process inherits the claude session's env, so a managed session
   (`c2c start claude`) carries C2C_MCP_SESSION_ID=<instance-name> — that
   registration IS the session identity; we must never fork a second
   registration from the payload UUID. *)

(* Events this hook handles. Add future events (e.g. UserPromptSubmit) here;
   the per-event behaviour dispatches on [event] below. *)
let claude_session_events = [ "SessionStart"; "SessionEnd" ]

let claude_onboarding_text ~alias ~session_id =
  Printf.sprintf
    "c2c: this Claude Code session is now registered on the local \
     agent-messaging system as `%s` (session ID: `%s`). Peer messages are delivered \
     automatically into your context as `<c2c ...>` blocks. Key commands: \
     `c2c whoami` (identity), `c2c list --alive` (peers online), `c2c find \
     <substr>` (peer lookup), `c2c send <alias> \"msg\"` (DM), `c2c \
     wait-inbox --timeout 5m` (blocking receive when idle), `c2c rooms join \
     swarm-lounge` (social room). Run the `/c2c` skill for the full reference."
    alias session_id

let claude_wake_text ~alias ~session_id =
  Printf.sprintf
    "c2c: connected as `%s` (session ID: `%s`). Inbound agent messages arrive automatically via \
     hooks; send with `c2c send <alias> \"msg\"`, block-receive when idle \
     with `c2c wait-inbox`. Run the `/c2c` skill for the full reference."
    alias session_id

let hook_claude_cmd =
  let open Cmdliner.Term in
  const (fun () ->
    let start_time = Unix.gettimeofday () in
    (* Fast exits must still hold the min-runtime floor: Claude Code's
       waitpid() hits ECHILD when a hook is reaped too quickly (same race
       sleep_to_min_runtime guards in hook_post_tool_cmd / hook_stop_cmd). *)
    let exit_floored code =
      (try sleep_to_min_runtime start_time with _ -> ());
      exit code
    in
    (* Hard runtime cap: exit cleanly well before the hook timeout so a
       wedged broker dir can never stall a claude session start. *)
    (try
       Sys.set_signal Sys.sigalrm (Sys.Signal_handle (fun _ -> exit 0));
       ignore (Unix.alarm 8)
     with _ -> ());
    (try
       (* Subagent guard (B042): spawned Claude subagents inherit the parent
          env and must never be registered or drained. *)
       if C2c_hook_lib.is_subagent_quiet () then exit_floored 0;
       let raw = read_stdin_all ~max_bytes:(1024 * 1024) in
       let payload =
         try Yojson.Safe.from_string (String.trim raw) with _ -> `Null
       in
       let event =
         match payload_string_field payload "hook_event_name" with
         | Some e -> e
         | None -> exit_floored 0
       in
       if not (List.mem event claude_session_events) then exit_floored 0;
       (* B130: a dispatched subagent turn carries a non-empty stdin `agent_id`
          (Claude Code's own `isSubagent = !!agent_id`). Never onboard / drain /
          inject for a subagent — it would leak the owner session's context into
          the subagent transcript. Top-level SessionStart omits agent_id, so
          onboarding + cold-boot delivery is unaffected. (Empirically subagents
          do not fire SessionStart, so this is defensive.) *)
       (match payload_string_field payload "agent_id" with
        | Some s when String.trim s <> "" -> exit_floored 0
        | _ -> ());
       (* Auto-update the /c2c claude skill from the embedded blob on session
          start, so sessions pick up skill changes from a new binary without
          re-running `c2c install claude`. Best-effort, never prints. *)
       if event = "SessionStart" then C2c_setup.refresh_claude_skill_if_stale ();
       let broker_root = C2c_utils.resolve_broker_root () in
       let broker = C2c_mcp.Broker.create ~root:broker_root in
       let regs () = C2c_mcp.Broker.list_registrations broker in
       let registered sid =
         List.exists (fun (r : C2c_mcp.registration) -> r.session_id = sid) (regs ())
       in
       let validated s =
         match C2c_mcp.validate_session_id s with
         | Ok sid -> Some sid
         | Error _ -> None
       in
       let payload_sid =
         Option.bind (payload_string_field payload "session_id") validated
       in
       let env_sid =
         match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
         | Some s when String.trim s <> "" -> validated (String.trim s)
         | _ -> None
       in
       if event = "SessionEnd" then begin
         (* Deregister ONLY hook auto-registrations for this session. Managed
            (`c2c start claude`) and MCP-registered sessions have a different
            registered_by and are never touched. *)
         let candidates = List.filter_map (fun x -> x) [ payload_sid; env_sid ] in
         (match
            List.find_opt
              (fun (r : C2c_mcp.registration) ->
                 r.registered_by = Some "claude-hook"
                 && List.exists (fun sid -> r.session_id = sid) candidates)
              (regs ())
          with
          | Some r -> ignore (C2c_mcp.Broker.deregister broker ~alias:r.alias)
          | None -> ());
         exit_floored 0
       end;
       (* SessionStart identity resolution, env first:
          1. C2C_MCP_SESSION_ID env has a registration (managed session, or
             any session whose env carries an explicit identity) — use it.
          2. payload session_id (claude-native UUID) has a registration
             (previous auto-register) — use it.
          3. payload-free fallback only: the `c2c init` statefile resolves to
             a live registration — use it. Restricted to payload-free fires
             (mirrors codex step 3 / B080): a fresh claude UUID must get a
             fresh identity, not inherit another session's statefile.
          4. nothing -> auto-register the payload session_id, UNLESS
             C2C_MCP_SESSION_ID is set: then the MCP server owns registration
             and auto-registering the payload UUID would fork a duplicate
             identity — stay silent instead. *)
       let resolved =
         match env_sid with
         | Some sid when registered sid -> Some sid
         | _ ->
             (match payload_sid with
              | Some sid when registered sid -> Some sid
              | Some _ -> None
              | None ->
                  (match C2c_cli_helpers.read_session_statefile ~broker_root with
                   | Some sid when registered sid -> Some sid
                   | _ -> None))
       in
       let session_id, onboarded_alias =
         match resolved with
         | Some sid -> (sid, None)
         | None ->
             if Option.is_some env_sid then exit_floored 0;
             (match payload_sid with
              | None -> exit_floored 0
              | Some sid ->
                  (* Auto-register: zero-setup onboarding for vanilla claude.
                     The payload UUID is stable for the conversation, so the
                     registration persists and every later fire resolves via
                     step 2 (no re-register loop). *)
                  (* B188: reuse sticky alias across broker fingerprints.
                     B191: resolve + register atomically under the global
                     per-session registration lock. *)
                  let alias, _from_auto_gen, _prior_hit =
                    C2c_mcp.locked_sticky_auto_register ~session_id:sid
                      ~broker_root
                      ~mint:(fun () ->
                        (C2c_setup.default_alias_for_client "claude", true))
                      ~register:(fun ~alias ~from_auto_gen ->
                        try
                          C2c_mcp.Broker.register broker ~session_id:sid ~alias
                            ~pid:None
                            ~pid_start_time:
                              (C2c_mcp.Broker.capture_pid_start_time None)
                            ~client_type:(Some "claude")
                            ~cwd:(payload_string_field payload "cwd")
                            ~registered_by:(Some "claude-hook")
                            ~from_auto_gen ()
                        with e ->
                          (try
                             prerr_endline
                               ("c2c hook claude: auto-register failed: "
                                ^ Printexc.to_string e)
                           with _ -> ());
                          exit_floored 0)
                      ()
                  in
                  (* Persist the identity for plain `c2c` CLI calls from this
                     claude session, but never steal a statefile that still
                     points at a live identity. *)
                  (match C2c_cli_helpers.read_session_statefile ~broker_root with
                   | Some existing
                     when C2c_cli_helpers.statefile_session_registered ~broker_root existing -> ()
                   | _ ->
                       C2c_cli_helpers.write_session_statefile ~broker_root
                         ~session_id:sid ~alias ~client:(Some "claude"));
                  (sid, Some alias))
       in
       let alias_of sid =
         List.find_map
           (fun (r : C2c_mcp.registration) ->
              if r.session_id = sid then Some r.alias else None)
           (regs ())
       in
       (* Part 1: onboarding (fresh auto-register) or wake note (known session). *)
       let intro =
         match onboarded_alias with
        | Some alias -> claude_onboarding_text ~alias ~session_id
        | None ->
             (match alias_of session_id with
              | Some a -> claude_wake_text ~alias:a ~session_id
              | None -> "")
       in
       (* Part 2: post-compact context (#317). SessionStart source=compact
          means the transcript was just compacted — re-inject operational
          context via the C2c_post_compact_hook library renderer (shared with
          the standalone c2c-post-compact-hook binary; the block is
          self-bounding at ~4KiB). *)
       let post_compact_context =
         if payload_string_field payload "source" = Some "compact" then
           try
             match C2c_post_compact_hook.repo_root (), alias_of session_id with
             | Some repo, Some alias ->
                 C2c_post_compact_hook.format_context_block
                   (C2c_post_compact_hook.Args.make ~alias ~repo
                      ~ts:(C2c_post_compact_hook.iso8601_now ()))
             | _ -> ""
           with _ -> ""
         else ""
       in
       (* Part 3: cold-boot context (#317). Fires once per session — the
          library keeps a marker at <broker_root>/.cold_boot_done/<sid>, so
          later SessionStarts (resume/compact) and the PostToolUse hook
          naturally no-op. Self-bounding. *)
       let cold_boot_context =
         try
           Option.value
             (C2c_cold_boot_context.context_for_session ~broker_root ~session_id)
             ~default:""
         with _ -> ""
       in
       (* Part 4: message drain (repo + global sessions broker) — full drain
          at the session boundary, EXCEPT the repo drain when the session is
          channel-capable (managed claude uses channel push; dual-drain would
          race the watcher). *)
       let repo_messages =
         if C2c_mcp.Broker.is_session_channel_capable broker ~session_id then []
         else C2c_mcp.Broker.drain_inbox ~drained_by:"hook" broker ~session_id
       in
       let global_messages =
         try
           let root = C2c_repo_fp.resolve_sessions_broker_root () in
           if C2c_hook_lib.global_inbox_exists ~root ~session_id then
             let gb = C2c_mcp.Broker.create ~root in
             C2c_mcp.Broker.drain_inbox ~drained_by:"hook" gb ~session_id
           else []
         with _ -> []
       in
       let messages_text =
         C2c_hook_lib.format_messages_as_text ~repo_broker:(Some broker)
           (repo_messages @ global_messages)
       in
       (* Part 5: changelog auto-show (B126). Per-client, once per binary
          version change. Try-guarded — never break the turn. *)
       let changelog_context =
         if event = "SessionStart" then
           try
             Option.value
               (C2c_changelog.auto_show ~broker_root ~client:"claude"
                  ~now:(Unix.gettimeofday ()) ())
               ~default:""
           with _ -> ""
         else ""
       in
       let context =
         [ intro; changelog_context; post_compact_context; cold_boot_context
         ; messages_text ]
         |> List.filter (fun s -> String.trim s <> "")
         |> String.concat "\n\n"
       in
       if context <> "" then begin
         let json : Yojson.Safe.t =
           `Assoc
             [ ( "hookSpecificOutput"
               , `Assoc
                   [ ("hookEventName", `String event)
                   ; ("additionalContext", `String context)
                   ] )
             ]
         in
         print_string (Yojson.Safe.to_string json);
         print_newline ()
       end;
       exit_floored 0
     with
     | e ->
         (* Never break the claude turn: swallow everything, exit 0. *)
         (try prerr_endline ("c2c hook claude: " ^ Printexc.to_string e) with _ -> ());
         exit_floored 0)) $ const ()

let hook_claude : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "claude"
       ~doc:"Claude Code session-lifecycle hook: reads the hook payload (JSON) on stdin, resolves this session's c2c identity env-first (auto-registering vanilla sessions on SessionStart), refreshes the /c2c skill, emits onboarding/wake text + cold-boot / post-compact context + queued messages as hookSpecificOutput.additionalContext, and deregisters hook auto-registrations on SessionEnd. Installed into ~/.claude/settings.json by `c2c install claude`. Never fails the claude turn: errors exit 0 with empty output.")
    hook_claude_cmd


let grok_session_events = [ "SessionStart"; "SessionEnd" ]

let hook_grok_cmd =
  let open Cmdliner.Term in
  const (fun () ->
    (try
       Sys.set_signal Sys.sigalrm (Sys.Signal_handle (fun _ -> exit 0));
       ignore (Unix.alarm 8)
     with _ -> ());
    (try
       if C2c_hook_lib.is_subagent_quiet () then exit 0;
       let raw = read_stdin_all ~max_bytes:(1024 * 1024) in
       let payload =
         try Yojson.Safe.from_string (String.trim raw) with _ -> `Null
       in
       (* Grok hook runner may use camelCase or snake_case; accept both. *)
       let event =
         match payload_string_field payload "hook_event_name" with
         | Some e -> e
         | None ->
             (match payload_string_field payload "hookEventName" with
              | Some e -> e
              | None ->
                  (match Sys.getenv_opt "GROK_HOOK_EVENT" with
                   | Some e when String.trim e <> "" -> String.trim e
                   | _ -> exit 0))
       in
       let event =
         match String.lowercase_ascii event with
         | "session_start" | "sessionstart" -> "SessionStart"
         | "session_end" | "sessionend" -> "SessionEnd"
         | other -> event
       in
       if not (List.mem event grok_session_events) then exit 0;
       if event = "SessionStart" then C2c_setup.refresh_grok_skill_if_stale ();
       let broker_root = C2c_utils.resolve_broker_root () in
       let broker = C2c_mcp.Broker.create ~root:broker_root in
       let regs () = C2c_mcp.Broker.list_registrations broker in
       let registered sid =
         List.exists (fun (r : C2c_mcp.registration) -> r.session_id = sid) (regs ())
       in
       let validated s =
         match C2c_mcp.validate_session_id s with
         | Ok sid -> Some sid
         | Error _ -> None
       in
       let payload_sid =
         match payload_string_field payload "session_id" with
         | Some s -> validated s
         | None ->
             (match payload_string_field payload "sessionId" with
              | Some s -> validated s
              | None -> None)
       in
       let env_sid =
         match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
         | Some s when String.trim s <> "" -> validated (String.trim s)
         | _ ->
             (match Sys.getenv_opt "GROK_SESSION_ID" with
              | Some s when String.trim s <> "" -> validated (String.trim s)
              | _ -> None)
       in
       if event = "SessionEnd" then begin
         let candidates = List.filter_map (fun x -> x) [ payload_sid; env_sid ] in
         (match
            List.find_opt
              (fun (r : C2c_mcp.registration) ->
                 r.registered_by = Some "grok-hook"
                 && List.exists (fun sid -> r.session_id = sid) candidates)
              (regs ())
          with
          | Some r -> ignore (C2c_mcp.Broker.deregister broker ~alias:r.alias)
          | None -> ());
         C2c_setup.remove_grok_session_identity_skill ();
         exit 0
       end;
       (* SessionStart identity resolution (CLI-first; no MCP required):
          1. env session already registered
          2. payload session already registered
          3. auto-register payload or env session id *)
       let resolved =
         match env_sid with
         | Some sid when registered sid -> Some sid
         | _ ->
             (match payload_sid with
              | Some sid when registered sid -> Some sid
              | _ -> None)
       in
       let session_id, onboarded_alias =
         match resolved with
         | Some sid -> (sid, None)
         | None ->
             let sid_opt =
               match payload_sid with
               | Some sid -> Some sid
               | None -> env_sid
             in
             (match sid_opt with
              | None -> exit 0
              | Some sid ->
                  (* B173: never adopt machine-global ~/.config/c2c/default-alias
                     for Grok auto-register — that file is clobbered by any
                     client's `c2c init` and was minting codex-/claude- aliases
                     for client_type=grok. Parity with vanilla codex/claude
                     hooks: mint a client-prefixed alias when no prior sticky
                     exists. B188: reuse sticky alias across fingerprints.
                     B191: resolve + register atomically under the global
                     per-session registration lock. *)
                  let alias, _from_auto_gen, _prior_hit =
                    C2c_mcp.locked_sticky_auto_register ~session_id:sid
                      ~broker_root
                      ~mint:(fun () ->
                        (C2c_setup.default_alias_for_client "grok", true))
                      ~register:(fun ~alias ~from_auto_gen ->
                        try
                          C2c_mcp.Broker.register broker ~session_id:sid ~alias
                            ~pid:None
                            ~pid_start_time:
                              (C2c_mcp.Broker.capture_pid_start_time None)
                            ~client_type:(Some "grok")
                            ~cwd:
                              (match payload_string_field payload "cwd" with
                               | Some c -> Some c
                               | None ->
                                   payload_string_field payload "workspaceRoot")
                            ~registered_by:(Some "grok-hook")
                            ~from_auto_gen ()
                        with e ->
                          (try
                             prerr_endline
                               ("c2c hook grok: auto-register failed: "
                                ^ Printexc.to_string e)
                           with _ -> ());
                          exit 0)
                      ()
                  in
                  (match C2c_cli_helpers.read_session_statefile ~broker_root with
                   | Some existing
                     when C2c_cli_helpers.statefile_session_registered ~broker_root existing -> ()
                   | _ ->
                       C2c_cli_helpers.write_session_statefile ~broker_root
                         ~session_id:sid ~alias ~client:(Some "grok"));
                  (sid, Some alias))       in
       (* #22: the identity skill is now identity-agnostic (byte-stable across
          all sessions), so it no longer consumes the resolved alias/session_id.
          The big match above still runs for its registration side effects. *)
       ignore (session_id, onboarded_alias);
       C2c_setup.write_grok_session_identity_skill ();
       (* Grok ignores passive-hook stdout for transcript inject; exit 0. *)
       exit 0
     with e ->
       (try prerr_endline ("c2c hook grok: " ^ Printexc.to_string e) with _ -> ());
       exit 0)) $ const ()

let hook_grok : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "grok"
       ~doc:"Grok Build TUI SessionStart/SessionEnd hook: auto-registers the session (registered_by=grok-hook), refreshes the /c2c skill, and writes a c2c-session identity skill (Grok cannot inject additionalContext). Installed by `c2c install grok`. Never fails the host turn.")
    hook_grok_cmd

let kimi_session_events = [ "SessionStart"; "SessionEnd" ]

(* #40: live managed `c2c start kimi` registrations owning [cwd].

   Kimi Code >= 0.27 runs sessions inside a SHARED long-lived `kimi server`
   daemon and spawns hook commands from that daemon's environment, so this hook
   CANNOT see the managed session's C2C_MCP_SESSION_ID /
   C2C_MCP_AUTO_REGISTER_ALIAS — one daemon serves many sessions, and its env
   describes none of them. Minting a fresh alias here therefore produced a
   SECOND, competing identity for an already-managed session (and re-keyed its
   notifier onto an inbox no mail lands in). The launcher now registers the
   managed alias itself; this lookup lets the hook recognise that row by
   [cwd] + live [pid] and adopt it instead of minting.

   Match criteria (all required): kimi client_type, NOT hook-registered
   (managed rows have no [registered_by]), same [cwd], and a live pid whose
   start-time matches the one recorded at registration.

   KNOWN LIMITATION (#40 F2) — this identifies the managed *instance owning the
   directory*, NOT the specific Kimi session that fired this hook. Nothing in
   the payload can do the latter: kimi's session_index maps session id to
   workDir only, and the hook cannot see the managed env. So a **co-located
   vanilla** kimi TUI — a bare `kimi` started in a directory that already has a
   managed instance — is adopted too: it never registers its own alias and its
   identity skill names the managed alias. Delivery is unaffected (the REST
   layer is workdir-keyed either way), and the ">= 2 managed" bail below does
   not cover this 1-managed + 1-vanilla case. Documented rather than fixed:
   the obvious fix (first-wins claim of the payload sid on the managed row)
   would silently strand a managed session that ever re-mints its session id,
   trading a cosmetic wrong-identity for a real deafness — not a trade worth
   making without knowing when kimi re-mints.

   The pid + pid_start_time pair is an anti-PID-REUSE guard, not proof of
   identity: it establishes that the registering instance is still alive, so a
   row left behind by a dead instance is never adopted. [pid_start_time] is
   corroborated because the launcher records it (via
   [Broker.capture_pid_start_time]) and a bare `/proc/<pid>` existence check
   would happily match an unrelated process that reused the pid. No recency
   window is applied — unlike [C2c_start.registration_is_adoptable], whose
   300s bound guards a *notifier binding* — because managed sessions
   legitimately run for days and a time bound would stop the hook adopting a
   perfectly live instance. Liveness here comes from the pid pair, which does
   not decay. Pure over [regs] so it is unit-testable without a broker. *)
let live_managed_kimi_registrations ~(cwd : string)
    (regs : C2c_mcp.registration list) : C2c_mcp.registration list =
  (* #40 F7: normalize both sides. The launcher writes [Sys.getcwd ()] (already
     canonical) but kimi's payload cwd is whatever the client passes, so a
     trailing slash or a symlinked path would silently defeat the match and
     resurrect the competing-alias bug. realpath is best-effort: on failure
     fall back to a trailing-slash strip rather than dropping the match. *)
  let normalize p =
    let p = String.trim p in
    let stripped =
      let n = String.length p in
      if n > 1 && p.[n - 1] = '/' then String.sub p 0 (n - 1) else p
    in
    try Unix.realpath stripped with _ -> stripped
  in
  let want = normalize cwd in
  let pid_is_live p start_time =
    p > 0
    && Sys.file_exists (Printf.sprintf "/proc/%d" p)
    &&
    match start_time with
    | None -> true (* pre-#40 row: pid existence is all we have *)
    | Some recorded -> (
        match C2c_mcp.Broker.capture_pid_start_time (Some p) with
        | Some now -> now = recorded
        | None -> false (* unreadable now but recorded then → fail closed *))
  in
  List.filter
    (fun (r : C2c_mcp.registration) ->
       r.client_type = Some "kimi"
       && r.registered_by <> Some "kimi-hook"
       && (match r.cwd with Some c -> normalize c = want | None -> false)
       && (match r.pid with
           | Some p -> pid_is_live p r.pid_start_time
           | None -> false))
    regs

let hook_kimi_cmd =
  let open Cmdliner.Term in
  const (fun () ->
    (try
       Sys.set_signal Sys.sigalrm (Sys.Signal_handle (fun _ -> exit 0));
       ignore (Unix.alarm 8)
     with _ -> ());
    (try
       if C2c_hook_lib.is_subagent_quiet () then exit 0;
       let raw = read_stdin_all ~max_bytes:(1024 * 1024) in
       let payload =
         try Yojson.Safe.from_string (String.trim raw) with _ -> `Null
       in
       let event =
         match payload_string_field payload "hook_event_name" with
         | Some e -> e
         | None ->
             (match payload_string_field payload "hookEventName" with
              | Some e -> e
              | None ->
                  (match Sys.getenv_opt "KIMI_HOOK_EVENT" with
                   | Some e when String.trim e <> "" -> String.trim e
                   | _ -> exit 0))
       in
       let event =
         match String.lowercase_ascii event with
         | "session_start" | "sessionstart" -> "SessionStart"
         | "session_end" | "sessionend" -> "SessionEnd"
         | _ -> event
       in
       if not (List.mem event kimi_session_events) then exit 0;
       let broker_root = C2c_utils.resolve_broker_root () in
       let broker = C2c_mcp.Broker.create ~root:broker_root in
       let validated s =
         match C2c_mcp.validate_session_id s with
         | Ok sid -> Some sid
         | Error _ -> None
       in
       let payload_sid =
         match payload_string_field payload "session_id" with
         | Some s -> validated s
         | None ->
             (match payload_string_field payload "sessionId" with
              | Some s -> validated s
              | None -> None)
       in
       let env_sid =
         match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
         | Some s when String.trim s <> "" -> validated (String.trim s)
         | _ -> None
       in
       let session_id_opt =
         match env_sid with
         | Some _ -> env_sid
         | None -> payload_sid
       in
       (* #40: never exit silently here. This bare `exit 0` is what made the
          managed-kimi registration gap take a live e2e to find. The hook must
          still never fail the host turn, so we log one line and exit 0. *)
       let session_id =
         match session_id_opt with
         | Some s -> s
         | None ->
             (try
                prerr_endline
                  "c2c hook kimi: no usable session id (payload \
                   session_id/sessionId missing or invalid, C2C_MCP_SESSION_ID \
                   unset) — skipping broker registration for this SessionStart. \
                   This session is unreachable by peers until it registers: run \
                   `c2c register` inside it, or launch it with `c2c start kimi`."
              with _ -> ());
             exit 0
       in
       if event = "SessionEnd" then begin
         let candidates = List.filter_map (fun x -> x) [ env_sid; payload_sid ] in
         (match
            List.find_opt
              (fun (r : C2c_mcp.registration) ->
                 r.registered_by = Some "kimi-hook"
                 && List.exists (fun sid -> r.session_id = sid) candidates)
              (C2c_mcp.Broker.list_registrations broker)
          with
          | Some r ->
              (* B238: stop hook-started notifier only for kimi-hook sessions —
                 never tear down a managed `c2c start kimi` notifier. *)
              (try C2c_kimi_notifier.stop_daemon ~alias:r.alias with _ -> ());
              ignore (C2c_mcp.Broker.deregister broker ~alias:r.alias)
          | None -> ());
         C2c_setup.remove_kimi_session_identity_skill ();
         exit 0
       end;
       (* SessionStart: ensure the session is registered FIRST (the durable,
          essential step), then arm the notifier. The non-essential /c2c skill
          refresh is deferred to AFTER arming (see below) so it can never eat
          the 8s alarm budget before the notifier fork — a loaded host used to
          leave the session registered-but-DEAF because the alarm guillotined
          the hook before ensure_daemon ran (#9, A(1)). *)
       let regs = C2c_mcp.Broker.list_registrations broker in
       (* #40: adopt a managed `c2c start kimi` identity when one owns this
          workspace, instead of minting a competing alias. See
          [live_managed_kimi_registrations] for why the hook cannot simply read
          the managed env. Ambiguity (two live managed kimi instances in one
          directory) is NOT resolvable from the hook payload — kimi's
          session_index only maps session id to workDir — so we bail loudly
          rather than guess and hijack the wrong instance's identity. The
          managed sessions are already registered by their launchers, so a bail
          costs nothing. *)
       let hook_cwd =
         match payload_string_field payload "cwd" with
         | Some c when String.trim c <> "" -> String.trim c
         | _ ->
             (match payload_string_field payload "workspaceRoot" with
              | Some c when String.trim c <> "" -> String.trim c
              | _ -> "")
       in
       let session_id =
         if hook_cwd = "" then session_id
         else
           match live_managed_kimi_registrations ~cwd:hook_cwd regs with
           | [ m ] ->
               (try
                  Printf.eprintf
                    "c2c hook kimi: adopting managed session '%s' (alias '%s') \
                     for %s — not minting a new alias.\n%!"
                    m.session_id m.alias hook_cwd
                with _ -> ());
               m.session_id
           | _ :: _ as many ->
               (try
                  Printf.eprintf
                    "c2c hook kimi: %d live managed kimi instances share cwd \
                     %s (%s) — cannot tell which one this SessionStart belongs \
                     to, so no registration is made here. Those instances are \
                     already registered by `c2c start`; to remove the \
                     ambiguity run at most one managed kimi per directory.\n%!"
                    (List.length many) hook_cwd
                    (String.concat ", "
                       (List.map (fun (r : C2c_mcp.registration) -> r.alias) many))
                with _ -> ());
               exit 0
           | [] -> session_id
       in
       (* #40 F6: on adoption this is necessarily true (we adopted an existing
          row's session_id), so the whole block below — including
          [write_session_statefile] — is skipped. That differs from every other
          hook path, which writes a statefile for a session it registered.
          Benign here and deliberate: the statefile is a fallback identity hint
          for surfaces that have no registration to read, and a managed session
          always has one (written by the launcher before the fork), so there is
          nothing to fall back to. Writing one would also duplicate identity
          state the launcher already owns and would have to be kept in sync
          with `c2c rename`. *)
       let already_registered =
         List.exists (fun (r : C2c_mcp.registration) -> r.session_id = session_id) regs
       in
       if not already_registered then begin
         let alias, from_auto_gen =
           match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
           | Some a when String.trim a <> "" ->
               let from_auto_gen =
                 match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN" with
                 | Some v when String.trim v = "1" -> true
                 | _ -> false
               in
               (String.trim a, from_auto_gen)
           | _ -> (C2c_setup.default_alias_for_client "kimi", true)
         in
         (try
            C2c_mcp.Broker.register broker ~session_id ~alias
              ~pid:None
              ~pid_start_time:(C2c_mcp.Broker.capture_pid_start_time None)
              ~client_type:(Some "kimi")
              ~cwd:
                (match payload_string_field payload "cwd" with
                 | Some c -> Some c
                 | None -> payload_string_field payload "workspaceRoot")
              ~registered_by:(Some "kimi-hook")
              ~from_auto_gen ()
          with e ->
            (try
               prerr_endline ("c2c hook kimi: auto-register failed: " ^ Printexc.to_string e)
             with _ -> ());
            exit 0);
         (match C2c_cli_helpers.read_session_statefile ~broker_root with
          | Some existing
            when C2c_cli_helpers.statefile_session_registered ~broker_root existing -> ()
          | _ ->
              C2c_cli_helpers.write_session_statefile ~broker_root
                ~session_id ~alias ~client:(Some "kimi"))
       end;
       (* Resolve live alias after register (or existing registration). *)
       let regs = C2c_mcp.Broker.list_registrations broker in
       let alias =
         match
           List.find_map
             (fun (r : C2c_mcp.registration) ->
                if r.session_id = session_id then Some r.alias else None)
             regs
         with
         | Some a -> a
         | None -> "unknown"
       in
       (* Prefer project cwd so the notifier's REST delivery can resolve the
          Kimi session_index workdir after fork+setsid. *)
       (match payload_string_field payload "cwd" with
        | Some c when String.trim c <> "" ->
            (try Unix.chdir (String.trim c) with _ -> ())
        | _ ->
            (match payload_string_field payload "workspaceRoot" with
             | Some c when String.trim c <> "" ->
                 (try Unix.chdir (String.trim c) with _ -> ())
             | _ -> ()));
       (* #9 A(1): DISARM the 8s hook alarm immediately before arming the
          notifier. The registration above is durable, so the session-start
          budget guard has done its job; the critical registered→armed window
          must NOT be interrupted. ensure_daemon forks+setsids a detached
          child and returns fast, and the detached child is unaffected by the
          parent's interval timer — but a still-armed SIGALRM landing between
          register and the fork was exactly what left sessions DEAF. Keep the
          outer `try … exit 0` so the hook still never fails the host turn. *)
       (try Sys.set_signal Sys.sigalrm Sys.Signal_ignore with _ -> ());
       (try ignore (Unix.alarm 0) with _ -> ());
       (* B238: arm a per-alias notifier for unmanaged sessions so DMs do not
          sit forever in inbox.json. Managed `c2c start kimi` already runs
          ensure_daemon; calling it again is upgrade-aware and no-ops when
          current. Tests set C2C_KIMI_HOOK_SKIP_NOTIFIER=1 to avoid forking. *)
       let skip_notifier =
         match Sys.getenv_opt "C2C_KIMI_HOOK_SKIP_NOTIFIER" with
         | Some v ->
             let t = String.lowercase_ascii (String.trim v) in
             t = "1" || t = "true" || t = "yes"
         | None -> false
       in
       let notifier_armed =
         if skip_notifier then false
         else
           (try
              match
                C2c_kimi_notifier.ensure_daemon
                  ~alias ~broker_root ~session_id ~tmux_pane:None ()
              with
              | Some _ -> true
              | None -> C2c_kimi_notifier.already_running alias
            with e ->
              (try
                 prerr_endline
                   ("c2c hook kimi: ensure_daemon failed: " ^ Printexc.to_string e)
               with _ -> ());
              C2c_kimi_notifier.already_running alias)
       in
       (* #9 A(1): RE-ARM a fresh alarm now that the fork is done. Disarming
          protected the register→fork window, but everything below is
          unbounded and takes a BLOCKING Unix.lockf F_LOCK on broker files
          (skill refresh, the #12 read_inbox peek, the identity-skill write),
          so a wedged lock-holder — precisely the loaded-host scenario this
          fix targets — would otherwise hang SessionStart forever instead of
          <=8s. ensure_daemon is itself bounded (~6s worst case) so it did not
          need the alarm. Restores the same exit-0 handler: the hook must
          still never fail the host turn. *)
       (try
          Sys.set_signal Sys.sigalrm (Sys.Signal_handle (fun _ -> exit 0));
          ignore (Unix.alarm 8)
        with _ -> ());
       (* #9 A(1): deferred /c2c skill refresh — non-essential cosmetic work,
          now that the durable register + notifier arm are both done and the
          alarm is disarmed. Best-effort; never blocks or fails the hook. *)
       (try C2c_setup.refresh_kimi_skill_if_stale () with _ -> ());
       (* #12: peek (never drain) the session inbox so the identity skill can
          surface any pre-startup backlog as an informational count. Read-only
          DATA — no delivery, no turn, no approval ("bus, never RPC", B098).
          System events (from "c2c-system") are excluded from the count. *)
       let queued_count =
         try
           C2c_mcp.Broker.read_inbox broker ~session_id
           |> List.filter (fun (m : C2c_mcp.message) ->
                  not
                    (C2c_kimi_notifier.is_system_event
                       ~from_alias:m.C2c_mcp.from_alias))
           |> List.length
         with _ -> 0
       in
       (* Identity skill: Kimi has no additionalContext inject; surface alias
          + receive-path nudge the same way Grok does, plus any queued backlog. *)
       C2c_setup.write_kimi_session_identity_skill
         ~alias ~session_id ~notifier_armed ~queued_count ();
       exit 0
     with e ->
       (try prerr_endline ("c2c hook kimi: " ^ Printexc.to_string e) with _ -> ());
       exit 0)) $ const ()

let hook_kimi : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "kimi"
       ~doc:"Kimi Code SessionStart/SessionEnd hook: auto-registers the session (registered_by=kimi-hook), refreshes the /c2c skill, arms a per-alias notifier when possible, and writes a c2c-session identity skill with a receive-path nudge (B238). Installed by `c2c install kimi`. Never fails the host turn.")
    hook_kimi_cmd

let hook_agy_cmd =
  let open Cmdliner.Term in
  const (fun event_opt ->
    (try
       Sys.set_signal Sys.sigalrm (Sys.Signal_handle (fun _ -> exit 0));
       ignore (Unix.alarm 8)
     with _ -> ());
    (try
       if C2c_hook_lib.is_subagent_quiet () then exit 0;
       let raw = read_stdin_all ~max_bytes:(1024 * 1024) in
       let payload =
         try Yojson.Safe.from_string (String.trim raw) with _ -> `Null
       in
       let event =
         match event_opt with
         | Some e -> e
         | None ->
             (match payload_string_field payload "hook_event_name" with
              | Some e -> e
              | None ->
                  (match payload_string_field payload "hookEventName" with
                   | Some e -> e
                   | None ->
                       (match Sys.getenv_opt "ANTIGRAVITY_HOOK_EVENT" with
                        | Some e when String.trim e <> "" -> String.trim e
                        | _ -> exit 0)))
       in
       let event =
         match String.lowercase_ascii event with
         | "session_start" | "sessionstart" -> "SessionStart"
         | "post_tool_use" | "posttooluse" -> "PostToolUse"
         | "stop" -> "Stop"
         | "session_end" | "sessionend" -> "SessionEnd"
         | other -> event
       in
       let conversation_id =
         match Sys.getenv_opt "ANTIGRAVITY_CONVERSATION_ID" with
         | Some s when String.trim s <> "" -> Some (String.trim s)
         | _ ->
             (match payload_string_field payload "conversationId" with
              | Some s -> Some s
              | None ->
                  (match payload_string_field payload "conversation_id" with
                   | Some s -> Some s
                   | None -> None))
       in
       let validated s =
         match C2c_mcp.validate_session_id s with
         | Ok sid -> Some sid
         | Error _ -> None
       in
       let payload_sid =
         match payload_string_field payload "session_id" with
         | Some s -> validated s
         | None ->
             (match payload_string_field payload "sessionId" with
              | Some s -> validated s
              | None -> None)
       in
       let env_sid =
         match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
         | Some s when String.trim s <> "" -> validated (String.trim s)
         | _ -> None
       in
       let target_sid =
         match env_sid with
         | Some s -> Some s
         | None ->
             (match payload_sid with
              | Some s -> Some s
              | None -> conversation_id)
       in
       let sid = match target_sid with Some s -> s | None -> exit 0 in
       let broker_root = C2c_utils.resolve_broker_root () in
       let broker = C2c_mcp.Broker.create ~root:broker_root in

       let ls_address =
         match Sys.getenv_opt "ANTIGRAVITY_LS_ADDRESS" with
         | Some s when String.trim s <> "" -> Some (String.trim s)
         | _ -> None
       in
       (match ls_address, conversation_id with
        | Some ls, Some conv ->
            C2c_agy_deliver.write_agy_env sid ~ls_address:ls ~conversation_id:conv
        | _ -> ());

       if event = "SessionStart" then begin
         let regs = C2c_mcp.Broker.list_registrations broker in
         let registered = List.exists (fun (r : C2c_mcp.registration) -> r.session_id = sid) regs in
         if not registered then begin
           (* B188: reuse sticky alias across broker fingerprints.
              B191: resolve + register atomically under the global
              per-session registration lock. *)
           let alias, _from_auto_gen, _prior_hit =
             C2c_mcp.locked_sticky_auto_register ~session_id:sid ~broker_root
               ~mint:(fun () ->
                 (C2c_setup.default_alias_for_client "agy", true))
               ~register:(fun ~alias ~from_auto_gen ->
                 try
                   C2c_mcp.Broker.register broker ~session_id:sid ~alias
                     ~pid:None
                     ~pid_start_time:
                       (C2c_mcp.Broker.capture_pid_start_time None)
                     ~client_type:(Some "agy")
                     ~cwd:
                       (match payload_string_field payload "cwd" with
                        | Some c -> Some c
                        | None -> payload_string_field payload "workspaceRoot")
                     ~registered_by:(Some "agy-hook")
                     ~from_auto_gen ()
                 with _ -> ())
               ()
           in
           (match C2c_cli_helpers.read_session_statefile ~broker_root with
            | Some existing
              when C2c_cli_helpers.statefile_session_registered ~broker_root existing -> ()
            | _ ->
                C2c_cli_helpers.write_session_statefile ~broker_root
                  ~session_id:sid ~alias ~client:(Some "agy"));
           ()
         end
       end;

       if event = "Stop" || event = "SessionEnd" then begin
         let regs = C2c_mcp.Broker.list_registrations broker in
         (match
            List.find_opt
              (fun (r : C2c_mcp.registration) ->
                 r.registered_by = Some "agy-hook" && r.session_id = sid)
              regs
          with
          | Some r -> ignore (C2c_mcp.Broker.deregister broker ~alias:r.alias)
          | None -> ());
         let env_file = C2c_agy_deliver.env_file_path sid in
         (try if Sys.file_exists env_file then Sys.remove env_file with _ -> ());
         exit 0
       end;

       if event = "PostToolUse" || event = "Stop" then begin
         (try
            C2c_agy_deliver.deliver_loop ~broker_root ~session_id:sid ~max_iterations:1 ~interval:0.01 ()
          with _ -> ())
       end;
       exit 0
     with e ->
       (try prerr_endline ("c2c hook agy: " ^ Printexc.to_string e) with _ -> ());
       exit 0))
  $ Cmdliner.Arg.(value & pos 0 (some string) None & info [] ~docv:"EVENT" ~doc:"Hook event name")

let hook_agy : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "agy"
       ~doc:"Antigravity CLI (agy) SessionStart/PostToolUse/Stop hook: auto-registers the session, updates the agy-env.json metadata, and triggers backup inbox draining. Installed by `c2c install agy`.")
    hook_agy_cmd

let hook : unit Cmdliner.Cmd.t =
  let info = Cmdliner.Cmd.info "hook"
    ~doc:"Hook subcommands for coding-agent host integration. Use 'post-tool' for Claude PostToolUse (drain inbox), 'stop' for Claude Stop (text-only turn delivery), 'claude' for Claude SessionStart/SessionEnd, 'codex' for all Codex CLI hook events, 'grok' for Grok SessionStart/SessionEnd, 'kimi' for Kimi Code SessionStart/SessionEnd, and 'agy' for Antigravity CLI."
  in
  (* Default to post-tool for backward compat: `c2c hook` (no subcommand) behaves
     as the PostToolUse hook, same as before the hook group refactor. *)
  Cmdliner.Cmd.group ~default:hook_post_tool_cmd info [ hook_post_tool; hook_stop; hook_codex; hook_claude; hook_grok; hook_kimi; hook_agy ]
