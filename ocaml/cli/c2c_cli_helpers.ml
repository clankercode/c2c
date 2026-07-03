(* c2c_cli_helpers — shared CLI helper functions.
   Extracted from c2c.ml so extracted subcommand modules can share them
   without circular dependencies on the main executable module. *)

open Cmdliner.Term.Syntax
open C2c_mcp
module Relay = Relay
open C2c_types
open C2c_commands
open C2c_utils
open C2c_agent
module Repo_fp = C2c_repo_fp

let debug_enabled =
  match Sys.getenv_opt "C2C_MCP_DEBUG" with
  | Some v ->
      let n = String.lowercase_ascii (String.trim v) in
      not (List.mem n [ "0"; "false"; "no"; "" ])
  | None -> false

let ( // ) = Filename.concat

let rec rm_rf path =
  if Sys.is_directory path then (
    Array.iter (fun entry -> rm_rf (path // entry)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

(* Resolve the Claude config dir.
   Prefers CLAUDE_CONFIG_DIR if set, otherwise resolves ~/.claude as a symlink
   (so profile dirs like ~/.claude-mm/ work via the symlink). *)
let resolve_claude_dir () =
  match Sys.getenv_opt "CLAUDE_CONFIG_DIR" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ ->
      let dot_claude = Filename.concat (Sys.getenv "HOME") ".claude" in
      (try
         let rec resolve_link p max_depth =
           if max_depth <= 0 then p
           else
             let stat = Unix.lstat p in
             if stat.Unix.st_kind = Unix.S_LNK then
               let target = Unix.readlink p in
               let resolved = if Filename.is_relative target then
                                Filename.concat (Filename.dirname p) target
                              else target in
               resolve_link resolved (max_depth - 1)
             else p
         in
         resolve_link dot_claude 10
       with _ -> dot_claude)

(* --- broker root resolution (delegated to C2c_utils) ---------------------- *)

let resolve_broker_root = C2c_utils.resolve_broker_root

let resolve_effective_broker_root ?(explicit_root : string option = None) ~cross_repo () =
  match explicit_root with
  | Some r when String.trim r <> "" -> String.trim r
  | _ ->
      if cross_repo then Repo_fp.resolve_sessions_broker_root ()
      else resolve_broker_root ()

let broker_root_from_env () =
  match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
  | Some path when String.trim path <> "" -> Some path
  | _ -> None

let git_repo_toplevel () =
  match Git_helpers.git_repo_toplevel () with
  | Some line when Sys.is_directory line -> Some line
  | _ -> None

let git_shorthash () =
  match Git_helpers.git_shorthash () with
  | Some line when int_of_string_opt line = None -> Some line
  | _ -> None

let version_string () =
  let base = Version.version in
  let ts = C2c_time.now_iso8601_utc () in
  (* #420: use the SHA embedded at compile time rather than shelling
     out to `git rev-parse` on every invocation. The shell-out cost
     was ~1s wall-clock and fired even on slate's #418 fast-path,
     undercutting that slice's startup-latency win. *)
  match Version.git_sha with
  | "unknown" | "" -> Printf.sprintf "%s %s" base ts
  | h -> Printf.sprintf "%s %s %s" base h ts

let find_python_script script =
  match git_repo_toplevel () with
  | Some dir ->
      let path = dir // script in
      if Sys.file_exists path then Some path else None
  | None -> None

(* --- session / alias resolution ------------------------------------------- *)

let env_session_id () =
  match C2c_mcp.session_id_from_env () with
  | Some s ->
      if debug_enabled then Printf.eprintf "[DEBUG env_session_id] returning Some=%s\n%!" s;
      Some s
  | None ->
      if debug_enabled then Printf.eprintf "[DEBUG env_session_id] returning None\n%!";
      None

let env_auto_alias () =
  match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
  | Some v when String.trim v <> "" -> Some (String.trim v)
  | _ -> None

let env_client_type () =
  match Sys.getenv_opt "C2C_MCP_CLIENT_TYPE" with
  | Some v when String.trim v <> "" -> Some (String.trim v)
  | _ -> None

let is_coordinator () =
  Sys.getenv_opt "C2C_COORDINATOR" = Some "1"

let validate_from_override broker ~caller_session_id ~from_alias =
  if is_coordinator () then ()
  else begin
    let from_cf = C2c_mcp.Broker.alias_casefold from_alias in
    let regs = C2c_mcp.Broker.list_registrations broker in
    let caller_owns_from =
      match caller_session_id with
      | Some sid ->
          List.exists
            (fun (r : C2c_mcp.registration) ->
               C2c_mcp.Broker.alias_casefold r.alias = from_cf && r.session_id = sid)
            regs
      | None -> false
    in
    if not caller_owns_from then begin
      let from_registered_to_other =
        List.exists
          (fun (r : C2c_mcp.registration) ->
             C2c_mcp.Broker.alias_casefold r.alias = from_cf
             && (match caller_session_id with
                 | Some sid -> r.session_id <> sid
                 | None -> true))
          regs
      in
      if from_registered_to_other then begin
        Printf.eprintf
          "refusing to send as '%s': that alias is registered to a different session than yours.\n- If you ARE %s: set C2C_MCP_SESSION_ID to that session's id so the broker recognizes you (this is the usual fix).\n- To relay on behalf of another agent: set C2C_COORDINATOR=1.\n- Otherwise: send as your own alias.\n%!"
          from_alias from_alias;
        exit 1
      end else begin
        Printf.eprintf
          "refusing to send as '%s': alias is not registered in this broker.\n\
           - Anti-impersonation: the broker only allows sending as a registered alias\n\
           to prevent one agent from spoofing another's identity.\n\
           - To send as this alias: register it first with `c2c register --alias %s`,\n\
           or set C2C_MCP_SESSION_ID to the session that owns it.\n\
           - To relay on behalf of another agent: set C2C_COORDINATOR=1.\n%!"
          from_alias from_alias;
        exit 1
      end
    end
  end

let resolve_alias ?(override : string option = None) broker =
  match override with
  | Some a when String.trim a <> "" ->
      let r = String.trim a in
      validate_from_override broker
        ~caller_session_id:(env_session_id ())
        ~from_alias:r;
      if debug_enabled then Printf.eprintf "[DEBUG resolve_alias] override=%s\n%!" r;
      r
  | _ ->
      (* Prefer C2C_MCP_SESSION_ID lookup over C2C_MCP_AUTO_REGISTER_ALIAS.
         C2C_MCP_SESSION_ID identifies the actual registered session; using it
         to look up the registered alias handles the case where the caller
         (e.g. a container with C2C_MCP_AUTO_REGISTER_ALIAS=peer-b-{ts})
         is not the actual sender alias. *)
      match env_session_id () with
      | Some sid ->
          let regs = C2c_mcp.Broker.list_registrations broker in
          (match
             List.find_opt
               (fun (r : C2c_mcp.registration) -> r.session_id = sid)
               regs
           with
          | Some r ->
              if debug_enabled then Printf.eprintf "[DEBUG resolve_alias] from_sid=%s -> alias=%s\n%!" sid r.alias;
              r.alias
          | None -> (
              (* Session not registered in this broker; fall back to
                 env_auto_alias for non-MCP callers. *)
              match env_auto_alias () with
              | Some a ->
                  if debug_enabled then Printf.eprintf "[DEBUG resolve_alias] sid=%s not registered, fallback=%s\n%!" sid a;
                  a
              | None ->
                  if is_coordinator () then (
                    (* B040: C2C_COORDINATOR=1 without --from: self-resolve from
                       env_auto_alias or default to "coordinator" instead of failing. *)
                    let fallback = Option.value (env_auto_alias ()) ~default:"coordinator" in
                    if debug_enabled then Printf.eprintf "[DEBUG resolve_alias] coordinator self-resolve to %s\n%!" fallback;
                    fallback
                  ) else (
                    (* B040: Session not registered here — common when --root
                       targets a different broker. Use the session_id itself as
                       the sender label rather than failing hard. *)
                    if debug_enabled then Printf.eprintf "[DEBUG resolve_alias] sid=%s not registered in target broker, using sid as sender label\n%!" sid;
                    sid
                  )))
      | None -> (
          match env_auto_alias () with
          | Some a ->
              if debug_enabled then Printf.eprintf "[DEBUG resolve_alias] from_env_auto_alias=%s\n%!" a;
              a
          | None ->
              if is_coordinator () then (
                (* B040: C2C_COORDINATOR=1 without session or alias: use "coordinator" *)
                if debug_enabled then Printf.eprintf "[DEBUG resolve_alias] coordinator fallback to 'coordinator'\n%!";
                "coordinator"
              ) else begin
                Printf.eprintf
                  "error: cannot determine your alias.\n\
                   Try one of these fixes:\n\
                     c2c init\n\
                     c2c register --alias <your-alias> --session-id <session-id>\n\
                     c2c whoami\n\
                   Advanced: set C2C_MCP_AUTO_REGISTER_ALIAS or C2C_MCP_SESSION_ID.\n%!";
                exit 1
              end)

let resolve_session_id () =
  match env_session_id () with
  | Some sid -> sid
  | None ->
      Printf.eprintf
        "error: cannot determine session ID. Set C2C_MCP_SESSION_ID or run from a supported client session.\n%!";
      exit 1

(* Like resolve_session_id but falls back to alias-based lookup when the
   session_id in the env doesn't match any registration. This handles the case
   where C2C_MCP_SESSION_ID was set by the harness to one value (e.g. "planner1")
   but the actual broker registration used a different session_id (e.g. "opencode-c2c")
   because the MCP server registered under a different identifier. *)
let resolve_session_id_by_alias broker alias =
  let alias_norm = String.lowercase_ascii alias in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let matches =
    List.filter
      (fun (r : C2c_mcp.registration) -> String.lowercase_ascii r.alias = alias_norm)
      regs
  in
  match matches with
  | [] ->
      Printf.eprintf "error: alias %s is not registered in this broker.\n%!" alias;
      exit 1
  | regs ->
      let live =
        List.filter
          (fun r -> C2c_mcp.Broker.registration_liveness_state r = C2c_mcp.Broker.Alive)
          regs
      in
      let chosen = match live with r :: _ -> r | [] -> List.hd regs in
      if debug_enabled then
        Printf.eprintf "[DEBUG resolve_sid_by_alias] alias=%s session_id=%s matches=%d live=%d\n%!"
          alias chosen.session_id (List.length regs) (List.length live);
      chosen.session_id

let resolve_session_id_for_inbox ?alias broker =
  match alias with
  | Some a -> resolve_session_id_by_alias broker a
  | None ->
      let sid = resolve_session_id () in
      let regs = C2c_mcp.Broker.list_registrations broker in
      let has_direct = List.exists (fun (r : C2c_mcp.registration) -> r.session_id = sid) regs in
      if debug_enabled then Printf.eprintf "[DEBUG resolve_sid_for_inbox] sid=%s has_direct=%b regs_count=%d\n%!"
        sid has_direct (List.length regs);
      if has_direct then sid
      else begin
        (* Fall back: look for a registration whose alias matches C2C_MCP_AUTO_REGISTER_ALIAS *)
        match env_auto_alias () with
        | None -> sid (* no fallback available, use original sid *)
        | Some alias ->
            (match List.find_opt (fun (r : C2c_mcp.registration) -> r.alias = alias) regs with
             | None -> sid
             | Some r ->
                 Printf.eprintf
                   "info: C2C_MCP_SESSION_ID=%s not in registry; using session_id=%s (alias=%s)\n%!"
                   sid r.session_id alias;
                 r.session_id)
      end

(* --- output helpers -------------------------------------------------------- *)

let json_flag =
  Cmdliner.Arg.(value & flag & info [ "json"; "j" ] ~doc:"Output machine-readable JSON.")

let cross_repo_flag =
  Cmdliner.Arg.(value & flag & info [ "cross-repo"; "global-broker" ]
    ~doc:"Target the cross-repo sessions broker ($(b,~/.c2c/sessions/broker)) instead of this repo's per-repo broker. Auto-resolves the rendezvous root (override with $(b,C2C_SESSIONS_BROKER_ROOT)); no manual $(b,C2C_MCP_BROKER_ROOT) needed. An explicit $(b,--root), where available, still wins.")

let print_json json =
  Yojson.Safe.pretty_to_channel stdout json;
  print_newline ()

(* Commands that are runnable in any session (Tier1/Tier2) but are
   de-emphasised in the curated `c2c commands` / `c2c --help` listings
   unless `--dev` (or `--all`) is passed. Orthogonal to the tier map:
   hiding here only affects help text, never runnability. See
   .collab/design/2026-06-26-c2c-list-glyphs-registry.md. *)
let hidden_unless_dev = [ "list-glyphs" ]

(* One-line descriptions for the hidden-unless-dev commands, used to render
   the curated DEV section. *)
let hidden_unless_dev_descriptions =
  [ ("list-glyphs", "(dev) emit the canonical c2c TUI glyph registry as JSON") ]

(* The (name, description) rows to render in the curated DEV section —
   driven by `hidden_unless_dev` so the gate and the listing never drift. *)
let dev_listing_entries () =
  List.filter_map
    (fun name ->
      Option.map (fun d -> (name, d)) (List.assoc_opt name hidden_unless_dev_descriptions))
    hidden_unless_dev

(* Scan argv for `--dev` (mirrors the existing `--all` pre-scan). When
   present, curated listings reveal `hidden_unless_dev` entries (and dev
   sections behave as `--all` does). *)
let argv_has_dev () =
  let n = Array.length Sys.argv in
  let rec loop i = i < n && (Sys.argv.(i) = "--dev" || loop (i + 1)) in
  loop 1

let current_c2c_command () =
  let fallback =
    if Array.length Sys.argv > 0 then Sys.argv.(0) else "c2c"
  in
  let resolved =
    try Unix.readlink "/proc/self/exe"
    with Unix.Unix_error _ -> fallback
  in
  if Filename.is_relative resolved then Sys.getcwd () // resolved else resolved

(* --- MCP nudge: steer agents toward MCP tools when available ---------------- *)

(** Print a one-line nudge to stderr when the agent could use an MCP tool
    instead of the CLI. Fires only when:
    - MCP session env vars are present (C2C_MCP_SESSION_ID, C2C_MCP_AUTO_REGISTER_ALIAS)
    - C2C_CLI_FORCE is not set
    Does not affect command exit code — always returns unit. *)
let mcp_nudge_if_needed ~cmd =
  if Sys.getenv_opt "C2C_CLI_FORCE" = Some "1" then ()
  else
    let env_has_value var =
      match Sys.getenv_opt var with
      | Some s when String.trim s <> "" -> true
      | _ -> false
    in
    if env_has_value "C2C_MCP_SESSION_ID" && env_has_value "C2C_MCP_AUTO_REGISTER_ALIAS" then
      let tool_name =
        match cmd with
        | "send"      -> "mcp__c2c__send"
        | "poll-inbox"| "peek-inbox" -> "mcp__c2c__poll_inbox"
        | "list"      -> "mcp__c2c__list"
        | "whoami"    -> "mcp__c2c__whoami"
        | _ -> ""
      in
      if tool_name <> "" then
        Printf.eprintf
          "hint: MCP is available — consider using %s instead of `c2c %s`\n\
           (suppress with C2C_CLI_FORCE=1)\n%!"
          tool_name cmd
let mkdir_p = C2c_utils.mkdir_p
