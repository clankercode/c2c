(** Per-client idle capability contract (P2.M2.E1.T002 / I011).

    Idle is a capability, not a global heuristic. The contract returns one of:
    - [Idle] — authoritative "safe to auto-restart by default"
    - [Busy] — authoritative "in-flight / not idle"
    - [Unknown reason] — no authoritative signal; policy MUST fail closed

    NEVER substitute activity-age / last-seen timestamps for authoritative
    idle. Heuristic helpers such as [C2c_start.agent_is_idle] and Kimi wire
    mtime checks are explicitly out of scope for this contract. *)

type idle_state =
  | Idle
  | Busy
  | Unknown of string

type client_kind =
  | Claude
  | OpenCode
  | Kimi
  | Agy
  | Codex_hooks
  | Codex_app_server

let idle_state_to_string = function
  | Idle -> "idle"
  | Busy -> "busy"
  | Unknown reason -> Printf.sprintf "unknown:%s" reason

let client_kind_of_string = function
  | "claude" -> Some Claude
  | "opencode" -> Some OpenCode
  | "kimi" -> Some Kimi
  | "agy" -> Some Agy
  | "codex-hooks" | "codex_hooks" -> Some Codex_hooks
  | "codex-app-server" | "codex_app_server" | "codex-appserver" ->
      Some Codex_app_server
  | "codex" ->
      (* Ambiguous without mapping presence; callers should resolve. *)
      None
  | _ -> None

let client_kind_to_string = function
  | Claude -> "claude"
  | OpenCode -> "opencode"
  | Kimi -> "kimi"
  | Agy -> "agy"
  | Codex_hooks -> "codex-hooks"
  | Codex_app_server -> "codex-app-server"

(** Default auto-restart is allowed only on authoritative Idle. *)
let auto_restart_allowed = function
  | Idle -> true
  | Busy | Unknown _ -> false

(** Resolve a managed client name + optional app-server mapping flag. *)
let resolve_client_kind ~(client : string) ~(has_app_server_mapping : bool) :
    client_kind option =
  match String.lowercase_ascii (String.trim client) with
  | "claude" -> Some Claude
  | "opencode" -> Some OpenCode
  | "kimi" -> Some Kimi
  | "agy" -> Some Agy
  | "codex" when has_app_server_mapping -> Some Codex_app_server
  | "codex" -> Some Codex_hooks
  | "codex-headless" -> Some Codex_hooks
  | other -> client_kind_of_string other

let default_opencode_freshness_s = 90.0

let parse_rfc3339_opt s =
  match Ptime.of_rfc3339 s with
  | Ok (t, _, _) -> Some (Ptime.to_float_s t)
  | Error _ -> None

let state_root = function
  | `Assoc _ as j -> (
      match Json_util.assoc_opt "state" j with
      | Some (`Assoc _ as state) -> state
      | _ -> j)
  | j -> j

(** Authoritative OpenCode path: plugin writes [agent.is_idle] on
    session.idle / session.status events into the instance statefile.
    Freshness is required so a stale snapshot cannot claim Idle forever. *)
let query_opencode_statefile ~(statefile : string) ~(now : float)
    ~(freshness_s : float) : idle_state =
  match C2c_io.read_json_opt statefile with
  | None -> Unknown "opencode statefile missing or unreadable"
  | Some json ->
      let state = state_root json in
      let updated_at =
        match Json_util.string_member "state_last_updated_at" state with
        | Some s -> parse_rfc3339_opt s
        | None -> (
            match Json_util.string_member "ts" json with
            | Some s -> parse_rfc3339_opt s
            | None -> None)
      in
      (match updated_at with
       | None -> Unknown "opencode statefile has no parseable timestamp"
       | Some ts when ts -. now > 5.0 ->
           (* Future skew: clock skew / corrupt timestamp must fail closed,
              not grant Idle until wall-clock catches up. 5s slack for mild NTP. *)
           Unknown
             (Printf.sprintf
                "opencode statefile timestamp in the future (skew %.1fs)"
                (ts -. now))
       | Some ts when now -. ts > freshness_s ->
           Unknown
             (Printf.sprintf
                "opencode statefile stale (age %.1fs > %.1fs)" (now -. ts)
                freshness_s)
       | Some _ -> (
           match Json_util.assoc_opt "agent" state with
           | None -> Unknown "opencode statefile missing agent block"
           | Some agent -> (
               match Json_util.bool_member "is_idle" agent with
               | Some true -> Idle
               | Some false -> Busy
               | None ->
                   Unknown "opencode agent.is_idle absent (null/unknown)")))

(** Codex app-server: only the owner's thread_status query is authoritative.
    Callers inject the already-queried status; this module does not open a
    websocket itself (keeps the contract pure/testable). *)
let query_app_server_status = function
  | `Idle -> Idle
  | `Active -> Busy
  | `Unknown -> Unknown "app-server thread status unknown"

let no_authoritative_tui client =
  Unknown
    (Printf.sprintf
       "no authoritative TUI idle path for %s (fail closed)" client)

(** Query the idle contract.

    Optional injectors keep the pure cases hermetic:
    - [app_server_status] — required for a non-Unknown app-server answer
    - [opencode_statefile] — override path (tests); default is
      [<instance_dir>/oc-plugin-state.json]
    - [now] / [opencode_freshness_s] — clock + freshness window *)
let query ~(kind : client_kind) ~(instance_dir : string) ?now
    ?(opencode_freshness_s = default_opencode_freshness_s)
    ?opencode_statefile ?app_server_status () : idle_state =
  let now = match now with Some t -> t | None -> Unix.gettimeofday () in
  match kind with
  | Codex_app_server -> (
      match app_server_status with
      | Some status -> query_app_server_status status
      | None -> Unknown "app-server status not queried")
  | OpenCode ->
      let path =
        match opencode_statefile with
        | Some p -> p
        | None -> Filename.concat instance_dir "oc-plugin-state.json"
      in
      query_opencode_statefile ~statefile:path ~now
        ~freshness_s:opencode_freshness_s
  | Claude -> no_authoritative_tui "claude"
  | Kimi -> no_authoritative_tui "kimi"
  | Agy -> no_authoritative_tui "agy"
  | Codex_hooks -> no_authoritative_tui "codex-hooks"

let query_client ~(client : string) ~(instance_dir : string)
    ~(has_app_server_mapping : bool) ?now ?opencode_freshness_s
    ?opencode_statefile ?app_server_status () : idle_state =
  match resolve_client_kind ~client ~has_app_server_mapping with
  | None ->
      Unknown
        (Printf.sprintf "unrecognized managed client %S" client)
  | Some kind ->
      query ~kind ~instance_dir ?now ?opencode_freshness_s ?opencode_statefile
        ?app_server_status ()
