(* c2c_statusline_cmd — B155.

   A fast, one-line c2c state summary suited to a client statusline (Claude
   Code's [statusLine] settings hook, or a shell prompt). It answers the
   three questions an agent's status bar needs at a glance:

     - is this context set up (registered with an alias)?
     - what is my alias?
     - am I connected to the relay?

   plus two cheap extras that are high-signal for a swarm: repo/machine peer
   counts and unread inbox count.

   SPEED (hard requirement — this runs on every statusline refresh):
   everything here is PURE-LOCAL. No network round-trip is ever made. The
   relay-connected indicator is derived from the broker-owned connector-state
   file (the same local signal `c2c status`/`c2c doctor --relay` read without
   --relay), NOT a live probe. Measured ~30-40ms end-to-end, dominated by
   process startup — well inside Claude Code's ~300ms statusLine budget. We
   deliberately do NOT run the archive scan `c2c status` does (that adds
   ~150ms+); statusline only touches registrations, the relay snapshot, the
   connector-state file, the shared sessions broker, and the caller's own
   inbox file.  The peer icons are: `📦` = alive registrations in the current
   repository broker; `🖥️` = the deduplicated union of that broker and the
   shared sessions broker (the local registration wins if a session is present
   in both — not a relay-live claim).  The `🌐 ⇄ …` token is relay connectivity
   (globe + spaced arrows + status word; unusable states are dim, not red).
   (Set PI_C2C_ASCII=1 for plain-text fallbacks: `[relay]`, repo, machine.)

   CLIENT DETECTION: the host client is inferred from the environment
   (C2c_mcp.inferred_client_type_from_env). For Claude Code specifically, the
   [statusLine] command is fed a JSON blob on stdin (session_id, model, cwd,
   ...). When stdin is not a TTY we read that blob under a short bounded
   select() so the alias resolves from the JSON's session_id even when no
   CLAUDE_SESSION_ID is exported into the statusLine env, and we surface the
   model's display name. Reading is fail-open and never blocks. *)

open C2c_cli_helpers
open Cmdliner.Term.Syntax

(* --- pure rendering helpers (kept free of I/O for clarity + testability) --- *)

(* ASCII fallback (B169): when PI_C2C_ASCII=1 — the convention documented in
   [glyphs.ml] — substitute plain-ascii tokens for the unicode glyphs so the
   line stays readable in minimal terminals. Applied to the relay `🌐 ⇄ …`
   token and the repo/machine peer icons. *)
let ascii_mode () = Sys.getenv_opt "PI_C2C_ASCII" = Some "1"

(* Short, fixed token for each composite relay state. Leading `🌐 ⇄ ` is the
   globe (internet/relay) plus the canonical c2c relay-route glyph (see
   [glyphs.ml] routes.relay), spaced for readability; in ASCII mode it falls
   back to `[relay] `. Status word follows after a space
   (off/unreg/live/expired/…). Unreachable is labelled `off` (same as
   unconfigured) — a compact statusline treats both as "relay not usable". *)
let relay_token (s : Relay_state.state) =
  let g = if ascii_mode () then "[relay] " else "🌐 ⇄ " in
  match s with
  | Relay_state.Unconfigured -> g ^ "off"
  | Relay_state.Configured_not_registered -> g ^ "unreg"
  | Relay_state.Configured_unverified -> g ^ "?"
  | Relay_state.Registered_live -> g ^ "live"
  | Relay_state.Registered_expired -> g ^ "expired"
  | Relay_state.Registered_unreachable -> g ^ "off"

(* Severity → colour class for the relay token.
   [`Ok] green, [`Warn] yellow, [`Bad] red, [`Dim] dark-gray/faint (relay is
   optional or currently unusable; not an alarm — local swarm still works). *)
let relay_severity (s : Relay_state.state) =
  match s with
  | Relay_state.Registered_live -> `Ok
  | Relay_state.Unconfigured
  | Relay_state.Registered_unreachable -> `Dim
  | Relay_state.Configured_not_registered
  | Relay_state.Configured_unverified
  | Relay_state.Registered_expired -> `Warn

let ansi_of = function
  | `Ok -> "\027[32m"
  | `Warn -> "\027[33m"
  | `Bad -> "\027[31m"
  | `Dim -> "\027[2m"
  | `Bold -> "\027[1m"

let paint ~color sev s = if color then ansi_of sev ^ s ^ "\027[0m" else s

type info = {
  registered : bool;
  alias : string option;
  relay_state : Relay_state.state;
  relay_configured : bool;
  peers_alive : int; (* compatibility alias for [peers_repo_alive] *)
  peers_repo_alive : int;
  peers_machine_alive : int;
  unread : int;
  client : string option;
  model : string option; (* client-supplied (Claude statusLine JSON), display only *)
}

(* Assemble the single human line. Segments are joined by a dim middot. *)
let render_human ~color (i : info) =
  let sep = if color then " \027[2m·\027[0m " else " · " in
  let ident =
    match i.alias with
    | Some a when i.registered -> paint ~color `Ok a
    | Some a -> paint ~color `Warn a (* alias known but session not registered here *)
    | None -> paint ~color `Bad "not-registered"
  in
  let head = paint ~color `Bold "c2c" ^ " " ^ ident in
  let relay =
    paint ~color (relay_severity i.relay_state) (relay_token i.relay_state)
  in
  let segs = ref [ head; relay ] in
  (* Peer icons always take a trailing space before the count (e.g. `📦 2`,
     `🖥️ 3`) so emoji presentation width still leaves a clear gap. 🖥 without
     U+FE0F is text-presentation and looks glued to the digit; force emoji. *)
  let repo_glyph = if ascii_mode () then "repo" else "📦" in
  let machine_glyph = if ascii_mode () then "machine" else "🖥️" in
  segs := !segs @ [ Printf.sprintf "%s %d" repo_glyph i.peers_repo_alive
                    ; Printf.sprintf "%s %d" machine_glyph i.peers_machine_alive ];
  if i.unread > 0 then
    segs := !segs @ [ paint ~color `Warn (Printf.sprintf "%d unread" i.unread) ];
  (match i.model with Some m when m <> "" -> segs := !segs @ [ paint ~color `Dim m ] | _ -> ());
  String.concat sep !segs

let render_json (i : info) : Yojson.Safe.t =
  `Assoc
    [ ("registered", `Bool i.registered)
    ; ("alias", (match i.alias with Some a -> `String a | None -> `Null))
    ; ("relay_state", `String (Relay_state.state_to_string i.relay_state))
    ; ("relay_configured", `Bool i.relay_configured)
    ; ("peers_alive", `Int i.peers_alive)
    ; ("peers_repo_alive", `Int i.peers_repo_alive)
    ; ("peers_machine_alive", `Int i.peers_machine_alive)
    ; ("unread", `Int i.unread)
    ; ("client", (match i.client with Some c -> `String c | None -> `Null))
    ; ("model", (match i.model with Some m -> `String m | None -> `Null))
    ]

(* --- stdin JSON (Claude Code statusLine contract) -------------------------- *)

(* Read a JSON blob from stdin under HARD bounds so we never hang and never
   grow without limit — the Claude Code statusLine JSON is small (<4KB) and
   delivered up front. Returns None when stdin is a TTY (interactive shell),
   empty, or unparseable. Fail-open: any error yields None.

   Two independent caps (B155 review): an absolute wall-clock [deadline_s] over
   the whole read, and a [max_bytes] buffer cap — so a continuous producer
   (`yes | c2c statusline`) can neither hang nor exhaust memory; it just returns
   a truncated (hence unparseable → None) blob promptly. [timeout] bounds the
   initial "is there any data?" wait for the common non-TTY-but-no-data case. *)
let read_stdin_json ?(timeout = 0.1) ?(deadline_s = 0.25) ?(max_bytes = 65536)
    () : Yojson.Safe.t option =
  if (try Unix.isatty Unix.stdin with _ -> true) then None
  else
    let deadline = Unix.gettimeofday () +. deadline_s in
    match (try Unix.select [ Unix.stdin ] [] [] timeout with _ -> ([], [], [])) with
    | [], _, _ -> None
    | _ ->
        let buf = Buffer.create 512 in
        let chunk = Bytes.create 4096 in
        let rec loop () =
          if Buffer.length buf >= max_bytes then ()
          else
            let remaining = deadline -. Unix.gettimeofday () in
            if remaining <= 0. then ()
            else
              match Unix.read Unix.stdin chunk 0 4096 with
              | 0 -> ()
              | n ->
                  Buffer.add_subbytes buf chunk 0 n;
                  (match
                     (try Unix.select [ Unix.stdin ] [] [] (min 0.05 remaining)
                      with _ -> ([], [], []))
                   with
                   | [], _, _ -> ()
                   | _ -> loop ())
              | exception _ -> ()
        in
        loop ();
        let s = String.trim (Buffer.contents buf) in
        if s = "" then None else (try Some (Yojson.Safe.from_string s) with _ -> None)

let json_string_at path json =
  let rec go j = function
    | [] -> (match j with `String s -> Some s | _ -> None)
    | k :: rest ->
        (match j with
         | `Assoc fields -> (match List.assoc_opt k fields with Some v -> go v rest | None -> None)
         | _ -> None)
  in
  go json path

(* --- state gathering (all local, no network) ------------------------------ *)

let alias_for_session ~regs ~session_id =
  match session_id with
  | None -> None
  | Some sid ->
      (match
         List.find_opt (fun (r : C2c_mcp.registration) -> r.session_id = sid) regs
       with
       | Some r -> Some r.alias
       | None ->
           (* fall back to the auto-register alias only if it actually names a
              live registration in this broker (mirrors whoami). *)
           (match env_auto_alias () with
            | Some a
              when List.exists
                     (fun (r : C2c_mcp.registration) ->
                        C2c_mcp.Broker.alias_casefold r.alias
                        = C2c_mcp.Broker.alias_casefold a)
                     regs -> Some a
            | _ -> None))

let gather ~session_id_override ~model () : info =
  let now = Unix.gettimeofday () in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let session_id =
    match session_id_override with Some _ as s -> s | None -> env_session_id ()
  in
  let alias = alias_for_session ~regs ~session_id in
  let registered = alias <> None && session_id <> None
    && (match session_id with
        | Some sid ->
            List.exists (fun (r : C2c_mcp.registration) -> r.session_id = sid) regs
        | None -> false)
  in
  (* Relay snapshot is pure-local; override its alias with the one we resolved
     (which may have come from the stdin session_id override). *)
  let snap = C2c_relay_state.snapshot ~broker () in
  let snap = { snap with C2c_relay_state.alias } in
  let classification, _conn = C2c_relay_state.composite snap None ~now in
  let peers_alive =
    List.fold_left
      (fun acc r -> if C2c_mcp.Broker.registration_is_alive r then acc + 1 else acc)
      0 regs
  in
  let sessions_regs =
    try
      let sessions = C2c_mcp.Broker.create
          ~root:(C2c_repo_fp.resolve_sessions_broker_root ()) in
      C2c_mcp.Broker.list_registrations sessions
    with _ -> []
  in
  (* Deduplicate by the exact stable registration identity.  The current-repo
     registration is inserted first, so it has precedence when a session is
     visible through both the repo and sessions broker. *)
  let seen = Hashtbl.create (List.length regs + List.length sessions_regs) in
  let peers_machine_alive =
    List.fold_left
      (fun n r ->
        let r : C2c_mcp.registration = r in
        let key = (r.session_id, C2c_mcp.Broker.alias_casefold r.alias) in
        if Hashtbl.mem seen key then n
        else begin
          Hashtbl.add seen key ();
          if C2c_mcp.Broker.registration_is_alive r then n + 1 else n
        end)
      0 (regs @ sessions_regs)
  in
  let unread =
    match session_id with
    | Some sid -> (try List.length (C2c_mcp.Broker.read_inbox broker ~session_id:sid) with _ -> 0)
    | None -> 0
  in
  let client = C2c_mcp.inferred_client_type_from_env () in
  { registered;
    alias;
    relay_state = classification.Relay_state.state;
    relay_configured = C2c_relay_state.relay_configured snap;
    peers_alive;
    peers_repo_alive = peers_alive;
    peers_machine_alive;
    unread;
    client;
    model }

(* --- Claude Code statusLine install snippet -------------------------------- *)

let claude_config_snippet =
  {|Add this to your Claude Code settings.json (~/.claude/settings.json or
.claude/settings.json) to use c2c as your status line:

  {
    "statusLine": {
      "type": "command",
      "command": "c2c statusline",
      "padding": 0
    }
  }

Claude Code feeds session JSON (session_id, model, cwd) to the command on
stdin; `c2c statusline` reads it automatically so your alias resolves even
without CLAUDE_SESSION_ID in the statusLine environment.

The peer segments remain local-only: `📦` counts alive registrations in this
repository's broker; `🖥️` is the deduplicated machine-wide union of that broker
and the shared sessions broker.  A repo registration wins when the same
session_id/alias appears in both. The `🌐 ⇄ …` segment shows relay connectivity
(from local connector state — no probe; dim when off/unreachable). Neither peer
count includes relay-discovered remote peers or performs a network probe. (Set
PI_C2C_ASCII=1 for plain-text fallbacks.)|}

(* --- command --------------------------------------------------------------- *)

let statusline_cmd =
  let no_color =
    Cmdliner.Arg.(
      value & flag
      & info [ "no-color" ]
          ~doc:"Disable ANSI colour even on a TTY. Colour is auto-disabled \
                when stdout is not a TTY or when NO_COLOR is set.")
  in
  let client_flag =
    Cmdliner.Arg.(
      value & opt (some string) None
      & info [ "client" ] ~docv:"CLIENT"
          ~doc:"Override the auto-detected host client \
                (claude|codex|opencode|kimi|grok). Currently only affects the \
                reported client field; c2c reads the same local state for all \
                clients.")
  in
  let print_config =
    Cmdliner.Arg.(
      value & flag
      & info [ "print-config" ]
          ~doc:"Print the Claude Code settings.json snippet to wire `c2c \
                statusline` as your status line, then exit.")
  in
  let+ json = json_flag
  and+ no_color = no_color
  and+ client_override = client_flag
  and+ print_config = print_config in
  if print_config then (print_string claude_config_snippet; print_newline ())
  else begin
    (* Read the Claude-style stdin JSON (if any) for session_id + model. Never
       blocks; TTY stdin is skipped. *)
    let stdin_json = read_stdin_json () in
    let session_id_override =
      match stdin_json with
      | Some j -> json_string_at [ "session_id" ] j
      | None -> None
    in
    let model =
      match stdin_json with
      | Some j ->
          (match json_string_at [ "model"; "display_name" ] j with
           | Some _ as m -> m
           | None -> json_string_at [ "model"; "id" ] j)
      | None -> None
    in
    let info = gather ~session_id_override ~model () in
    let info =
      match client_override with Some c -> { info with client = Some c } | None -> info
    in
    if json then print_json (render_json info)
    else begin
      let color =
        (not no_color)
        && Sys.getenv_opt "NO_COLOR" = None
        && (try Unix.isatty Unix.stdout with _ -> false)
      in
      print_endline (render_human ~color info)
    end
  end

let statusline : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "statusline"
       ~doc:"One-line c2c state summary for a client status line (fast, \
             offline-safe)."
       ~man:
         [ `S "DESCRIPTION"
         ; `P "Prints a single concise line summarising this context's c2c \
               state: registration/alias, relay connectivity (the \
               `🌐 ⇄ <status>` segment, from local connector state — no \
               network probe), repository and machine-wide peer counts \
               (`📦` / `🖥️`), and unread inbox count. Designed to run on \
               every status-line refresh, so it is pure-local and fast \
               (~30-40ms)."
         ; `P "The $(b,📦) segment counts alive registrations in the current \
               repository broker. The $(b,🖥️) segment counts the deduplicated \
               union of that broker and the shared sessions broker; when a \
               registration is visible in both, the current-repository \
               registration takes precedence. The $(b,🌐 ⇄ …) segment shows \
               relay connectivity (dim/dark-gray when off or unreachable, not \
               red). Neither peer count includes relay-discovered remote peers \
               or makes a network request. In JSON these are \
               $(b,peers_repo_alive) and $(b,peers_machine_alive); \
               $(b,peers_alive) remains the compatibility alias for the \
               repo-local count. Set $(b,PI_C2C_ASCII=1) for plain-text \
               fallbacks (`[relay]`, repo, machine)."
         ; `P "Colour is emitted only on a TTY and honours $(b,NO_COLOR). Use \
               $(b,--json) for a machine-readable object, or $(b,--no-color) \
               to force plain text."
         ; `S "CLAUDE CODE"
         ; `P "Claude Code's $(b,statusLine) hook feeds session JSON on stdin; \
               $(b,c2c statusline) reads it automatically (session_id, model). \
               Run $(b,c2c statusline --print-config) for the settings.json \
               snippet."
         ; `S "EXAMPLES"
         ; `P "$(b,c2c statusline)          one-line summary"
         ; `Noblank
         ; `P "$(b,c2c statusline --json)   machine-readable object"
         ; `Noblank
         ; `P "$(b,c2c statusline --print-config)   Claude Code wiring snippet"
         ])
    statusline_cmd
