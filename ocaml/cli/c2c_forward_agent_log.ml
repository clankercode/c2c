(* c2c_forward_agent_log — B193/B194: follow a coding-agent session
   transcript and forward ONLY the human-visible conversation — user input
   and assistant plaintext — to a c2c address, so a colleague (or a
   coordinator session, possibly on another machine via alias@host) can
   observe a session without the tool-call / thinking noise.

   All supported clients have a classifier: claude / codex / kimi / grok /
   agy tail an append-only jsonl transcript; opencode (per-message JSON
   files, no single transcript) is a polled directory source. `--format
   auto` resolves the format from the path (standard session-store
   locations) or by sniffing the first line.

   Layering: this module is the PURE core (jsonl classification, incremental
   tail reading, message formatting) plus the follow/forward loop. It depends
   only on c2c_mcp + c2c_watch_data (send wrapper) + yojson + unix so the
   whole pipeline is unit-testable without pulling in the CLI helper stack.
   The Cmdliner wiring lives in [C2c_forward_agent_log_cmd].

   SAFETY (B098 "bus, never RPC"): forwarded transcript excerpts are
   untrusted DATA. This command only reads a local file and enqueues ordinary
   messages via the normal send path; it adds no approval or RPC semantics,
   and nothing a recipient replies with feeds back into this watcher. The
   outbound sanitizer below is defence in depth, not a trust boundary. *)

module Broker = C2c_mcp.Broker

type role = User | Agent

let role_label = function User -> "[user]" | Agent -> "[agent]"

(* ------------------------------------------------------------------ *)
(* Claude Code transcript classification                               *)
(* ------------------------------------------------------------------ *)

(* Claude Code session transcripts (~/.claude*/projects/<slug>/<sid>.jsonl)
   are one JSON object per line. Shapes we care about (observed live,
   2026-07):
   - {"type":"user","message":{"role":"user","content":"..."}} — human input
     as a plain string (slash commands arrive wrapped in <command-*> tags).
   - {"type":"user","message":{"content":[{"type":"text",...}]}} — human /
     harness input as content blocks.
   - {"type":"user", ..., "toolUseResult":..., "message":{"content":
     [{"type":"tool_result",...}]}} — tool results echoed as user turns.
     NOISE.
   - {"type":"assistant","message":{"content":[{"type":"text"|"thinking"|
     "tool_use",...}]}} — one line per content block; only "text" blocks are
     chat output.
   - {"type":"system"|"summary"|"attachment"|"mode"|...} — meta. NOISE.
   - "isMeta":true lines (hook/system-injected) and "isSidechain":true lines
     (subagent transcripts) are NOISE.

   Anything malformed (partial write, non-JSON garbage) is skipped, never
   fatal: a live transcript can be mid-write at any moment. *)

let member key = function
  | `Assoc l -> ( match List.assoc_opt key l with Some v -> v | None -> `Null)
  | _ -> `Null

let bool_field key j = match member key j with `Bool b -> b | _ -> false

(* User-turn text that is injected machinery rather than typed input:
   hook/system reminders, local-command output echoes, c2c-delivered
   envelopes (the observer would otherwise see relayed mail twice), and
   interruption markers. Matched on the trimmed text prefix. The list is
   shared across formats: harnesses differ in envelope shape but inject the
   same kinds of context blocks (codex `<user_instructions>` /
   `<environment_context>`, gemini `<session_context>`, ...). *)
let user_noise_prefixes =
  [ "<system-reminder"
  ; "<local-command-stdout"
  ; "<local-command-stderr"
  ; "<c2c"
  ; "[Request interrupted"
  ; "<user_instructions"
  ; "<environment_context"
  ; "<permissions instructions"
  ; "<session_context"
  ]

let is_user_noise_text text =
  List.exists
    (fun p -> String.length text >= String.length p
              && String.sub text 0 (String.length p) = p)
    user_noise_prefixes

(* Extract the concatenated "text"-block payload of a content value.
   Returns [None] when the content contains a tool_result block (the whole
   event is a tool echo, not conversation). [drop_noise_blocks] additionally
   filters injected-machinery text blocks individually (user turns can in
   principle carry a harness-injected block alongside the typed text; drop
   the noise block, keep the typed one). *)
let text_of_content ?(drop_noise_blocks = false) (content : Yojson.Safe.t) :
    string option =
  match content with
  | `String s -> Some s
  | `List blocks ->
      let has_tool_result =
        List.exists
          (fun b -> match member "type" b with
             | `String "tool_result" -> true
             | _ -> false)
          blocks
      in
      if has_tool_result then None
      else
        let texts =
          List.filter_map
            (fun b ->
              match member "type" b, member "text" b with
              | `String "text", `String t ->
                  if drop_noise_blocks && is_user_noise_text (String.trim t)
                  then None
                  else Some t
              | _ -> None)
            blocks
        in
        Some (String.concat "\n\n" texts)
  | _ -> None

let classify_claude_line (line : string) : (role * string) option =
  match Yojson.Safe.from_string line with
  | exception _ -> None
  | j ->
      (* isCompactSummary: the post-compaction context-restore blob arrives
         as a huge plain-string user turn — machinery, not typed input. *)
      if
        bool_field "isMeta" j || bool_field "isSidechain" j
        || bool_field "isCompactSummary" j
      then None
      else
        let content = member "content" (member "message" j) in
        (match member "type" j with
         | `String "user" ->
             (* toolUseResult marks a tool-result echo even before looking at
                content blocks. *)
             if (match member "toolUseResult" j with `Null -> false | _ -> true)
             then None
             else (
               match text_of_content ~drop_noise_blocks:true content with
               | None -> None
               | Some text ->
                   let trimmed = String.trim text in
                   if trimmed = "" || is_user_noise_text trimmed then None
                   else Some (User, trimmed))
         | `String "assistant" -> (
             match text_of_content content with
             | None -> None
             | Some text ->
                 let trimmed = String.trim text in
                 if trimmed = "" then None else Some (Agent, trimmed))
         | _ -> None)

(* ------------------------------------------------------------------ *)
(* Codex transcript classification                                     *)
(* ------------------------------------------------------------------ *)

(* Codex CLI rollouts (~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl,
   observed live 2026-07) wrap every line as
   {"timestamp":...,"type":<kind>,"payload":{...}}. The human-visible
   conversation is the event stream:
   - {"type":"event_msg","payload":{"type":"user_message","message":"..."}}
   - {"type":"event_msg","payload":{"type":"agent_message","message":"..."}}
   Everything else is NOISE: session_meta, token_count / task_started /
   thread_goal_updated events, and the whole "response_item" mirror of the
   model context (which duplicates user input alongside injected AGENTS.md /
   permissions / developer blocks). *)

let classify_codex_line (line : string) : (role * string) option =
  match Yojson.Safe.from_string line with
  | exception _ -> None
  | j ->
      if member "type" j <> `String "event_msg" then None
      else
        let payload = member "payload" j in
        let role =
          match member "type" payload with
          | `String "user_message" -> Some User
          | `String "agent_message" -> Some Agent
          | _ -> None
        in
        (match (role, member "message" payload) with
        | Some role, `String text ->
            let trimmed = String.trim text in
            if trimmed = "" then None
            else if role = User && is_user_noise_text trimmed then None
            else Some (role, trimmed)
        | _ -> None)

(* ------------------------------------------------------------------ *)
(* Kimi transcript classification                                      *)
(* ------------------------------------------------------------------ *)

(* Two on-disk layouts (observed live 2026-07):

   1. Legacy kimi-cli context.jsonl
      (~/.kimi/sessions/<project-hash>/<uuid>/context.jsonl):
      one context entry per line, keyed by top-level "role".
      - {"role":"user","content":"..."} — human input (string, or text blocks).
      - {"role":"assistant","content":<string|blocks>,"tool_calls":[...]} —
        content is the chat text; block lists carry {"type":"think",...}
        reasoning (NOISE) alongside {"type":"text",...} output.
      - roles "_system_prompt" / "_checkpoint" / "_usage" / "tool" are
        machinery. NOISE.

   2. Kimi Code 0.23+ wire.jsonl
      (~/.kimi-code/sessions/wd_*/session_<uuid>/agents/<agent>/wire.jsonl):
      one wire event per line, keyed by top-level "type".
      - {"type":"context.append_message","message":{"role":"user",
        "content":[...],"origin":{"kind":"user"}}} — typed human input.
        origin.kind values other than "user" (injection, skill_activation,
        background_task, shell_command, cron_job, system_trigger, ...) are
        harness noise. NOISE.
      - {"type":"context.append_loop_event","event":{"type":"content.part",
        "part":{"type":"text","text":"..."}}} — assistant chat text.
        part.type "think" is reasoning. NOISE. tool.call / tool.result /
        step.begin / step.end are machinery. NOISE.
      - turn.prompt duplicates append_message for the same user turn — we
        only take append_message to avoid double-forwarding.
      - metadata / config.update / llm.request / usage.record / etc. NOISE.

   Both layouts share the "kimi" format id; auto-detect picks by path
   (context.jsonl / wire.jsonl / .kimi/ / .kimi-code/) or by sniff. *)

(* Legacy kimi-cli context.jsonl: top-level "role". *)
let classify_kimi_context_line (j : Yojson.Safe.t) : (role * string) option =
  let content = member "content" j in
  match member "role" j with
  | `String "user" -> (
      match text_of_content ~drop_noise_blocks:true content with
      | None -> None
      | Some text ->
          let trimmed = String.trim text in
          if trimmed = "" || is_user_noise_text trimmed then None
          else Some (User, trimmed))
  | `String "assistant" -> (
      match text_of_content content with
      | None -> None
      | Some text ->
          let trimmed = String.trim text in
          if trimmed = "" then None else Some (Agent, trimmed))
  | _ -> None

(* Kimi Code wire.jsonl: top-level "type". *)
let classify_kimi_wire_line (j : Yojson.Safe.t) : (role * string) option =
  match member "type" j with
  | `String "context.append_message" -> (
      let message = member "message" j in
      match (member "role" message, member "origin" message) with
      | `String "user", origin -> (
          (* Only typed human input: origin.kind = "user". Missing origin
             is treated as user so a stripped export still forwards. *)
          let kind =
            match member "kind" origin with
            | `String k -> k
            | `Null -> "user"
            | _ -> ""
          in
          if kind <> "user" then None
          else
            match
              text_of_content ~drop_noise_blocks:true (member "content" message)
            with
            | None -> None
            | Some text ->
                let trimmed = String.trim text in
                if trimmed = "" || is_user_noise_text trimmed then None
                else Some (User, trimmed))
      | _ -> None)
  | `String "context.append_loop_event" -> (
      let event = member "event" j in
      match member "type" event with
      | `String "content.part" -> (
          let part = member "part" event in
          match (member "type" part, member "text" part) with
          | `String "text", `String text ->
              let trimmed = String.trim text in
              if trimmed = "" then None else Some (Agent, trimmed)
          | _ -> None)
      | _ -> None)
  | _ -> None

let classify_kimi_line (line : string) : (role * string) option =
  match Yojson.Safe.from_string line with
  | exception _ -> None
  | j -> (
      (* Prefer the layout the line actually carries: top-level "role" is
         legacy context.jsonl; top-level wire "type" is Kimi Code. A line
         with neither is noise / unknown. *)
      match member "role" j with
      | `String _ -> classify_kimi_context_line j
      | _ -> classify_kimi_wire_line j)

(* ------------------------------------------------------------------ *)
(* Grok transcript classification                                      *)
(* ------------------------------------------------------------------ *)

(* Grok CLI (~/.grok/sessions/<urlencoded-cwd>/<uuid>/chat_history.jsonl,
   observed live 2026-07): lines are keyed by "type".
   - {"type":"user","content":[{"type":"text","text":"..."}]} — but only
     blocks wrapping the typed input in <user_query>...</user_query> are
     real input; other user lines are injected system-reminders / MCP
     status, and "synthetic_reason" marks harness-synthesized turns. NOISE
     unless a <user_query> wrapper is present (we forward its inner text).
   - {"type":"assistant","content":"..."} — chat text (empty string when
     the turn was tool_calls only).
   - "system" / "tool_result" / "reasoning" lines are machinery. NOISE. *)

(* Naive substring search; returns the index of the first occurrence of
   [sub] in [s] at or after [start]. *)
let find_sub (s : string) (sub : string) (start : int) : int option =
  let n = String.length s and m = String.length sub in
  if m = 0 then Some start
  else begin
    let found = ref None in
    let i = ref (max 0 start) in
    while !found = None && !i <= n - m do
      if String.sub s !i m = sub then found := Some !i else incr i
    done;
    !found
  end

(* Extract the trimmed inner text of the first <tag>...</tag> region; an
   unterminated open tag runs to the end of the string. *)
let extract_tagged ~(tag : string) (text : string) : string option =
  let open_t = "<" ^ tag ^ ">" and close_t = "</" ^ tag ^ ">" in
  match find_sub text open_t 0 with
  | None -> None
  | Some i ->
      let start = i + String.length open_t in
      let stop =
        match find_sub text close_t start with
        | Some k -> k
        | None -> String.length text
      in
      Some (String.trim (String.sub text start (stop - start)))

let classify_grok_line (line : string) : (role * string) option =
  match Yojson.Safe.from_string line with
  | exception _ -> None
  | j -> (
      match member "type" j with
      | `String "user" -> (
          if member "synthetic_reason" j <> `Null then None
          else
            match text_of_content (member "content" j) with
            | None -> None
            | Some text -> (
                match extract_tagged ~tag:"user_query" text with
                | Some q when q <> "" -> Some (User, q)
                | _ -> None))
      | `String "assistant" -> (
          match member "content" j with
          | `String s ->
              let trimmed = String.trim s in
              if trimmed = "" then None else Some (Agent, trimmed)
          | _ -> None)
      | _ -> None)

(* ------------------------------------------------------------------ *)
(* agy / Antigravity (Gemini CLI) transcript classification            *)
(* ------------------------------------------------------------------ *)

(* Gemini CLI chats (~/.gemini/tmp/<project>/chats/session-*.jsonl, observed
   live 2026-07): line 1 is a session header ({"sessionId","projectHash",...});
   later lines are either {"$set":{...}} journal ops (NOISE) or appended
   message objects:
   - {"type":"user","content":[{"text":"..."}]} — parts carry a bare "text"
     key (no "type" discriminator); the first user message is an injected
     <session_context> block (caught by the shared noise-prefix filter).
   - {"type":"gemini","content":"...","thoughts":[...]} — content is the
     chat text ("" when the turn was thoughts/toolCalls only); "thoughts"
     are reasoning. NOISE. *)

let agy_text_of_content (content : Yojson.Safe.t) : string option =
  match content with
  | `String s -> Some s
  | `List parts ->
      let texts =
        List.filter_map
          (fun p ->
            match member "text" p with `String t -> Some t | _ -> None)
          parts
      in
      if texts = [] then None else Some (String.concat "\n\n" texts)
  | _ -> None

let classify_agy_line (line : string) : (role * string) option =
  match Yojson.Safe.from_string line with
  | exception _ -> None
  | j -> (
      if member "$set" j <> `Null || member "sessionId" j <> `Null then None
      else
        match member "type" j with
        | `String "user" -> (
            match agy_text_of_content (member "content" j) with
            | None -> None
            | Some text ->
                let trimmed = String.trim text in
                if trimmed = "" || is_user_noise_text trimmed then None
                else Some (User, trimmed))
        | `String "gemini" -> (
            match member "content" j with
            | `String s ->
                let trimmed = String.trim s in
                if trimmed = "" then None else Some (Agent, trimmed)
            | _ -> None)
        | _ -> None)

(* ------------------------------------------------------------------ *)
(* Format registry + auto-detection                                    *)
(* ------------------------------------------------------------------ *)

(* "opencode" is also a supported format but is a directory source, not a
   line classifier — see the OpenCode section below and the Cmdliner
   wiring. *)
let classifier_for_format (fmt : string) :
    (string -> (role * string) option) option =
  match String.lowercase_ascii (String.trim fmt) with
  | "claude" -> Some classify_claude_line
  | "codex" -> Some classify_codex_line
  | "kimi" -> Some classify_kimi_line
  | "grok" -> Some classify_grok_line
  | "agy" | "gemini" -> Some classify_agy_line
  | _ -> None

let supported_formats =
  [ "auto"; "claude"; "codex"; "kimi"; "grok"; "agy"; "opencode" ]

let contains_sub (s : string) (sub : string) : bool =
  find_sub s sub 0 <> None

(* Path heuristics over the clients' standard session-store locations.
   Note: "/.kimi/" must not be confused with "/.kimi-code/" — the trailing
   slash after "kimi" keeps the legacy path from matching the Kimi Code
   state dir, so both branches are listed explicitly. *)
let detect_format_by_path ~(is_dir : bool) (path : string) : string option =
  let base = Filename.basename path in
  let has = contains_sub path in
  if is_dir || has "/storage/message/" then Some "opencode"
  else if base = "chat_history.jsonl" || has "/.grok/" then Some "grok"
  else if
    base = "context.jsonl" || base = "wire.jsonl" || has "/.kimi-code/"
    || has "/.kimi/"
  then Some "kimi"
  else if String.starts_with ~prefix:"rollout-" base || has "/.codex/" then
    Some "codex"
  else if
    has "/.gemini/"
    || (Filename.basename (Filename.dirname path) = "chats"
        && String.starts_with ~prefix:"session-" base)
  then Some "agy"
  else if has "/.claude" then Some "claude"
  else None

(* Content sniff over the first complete line, for transcripts that were
   copied out of their standard location. Every client's first line is
   distinctive: codex wraps in {"type":"session_meta"|...,"payload":...};
   gemini opens with a {"sessionId","projectHash"} header (and uses "$set"
   ops); legacy kimi keys entries by top-level "role"; Kimi Code wire opens
   with {"type":"metadata","protocol_version":...} or other wire events;
   claude nests the turn under "message"; grok puts "content" at top level
   next to "type". *)
let sniff_format_from_line (line : string) : string option =
  match Yojson.Safe.from_string line with
  | exception _ -> None
  | j -> (
      let has k = member k j <> `Null in
      match member "type" j with
      | `String ("session_meta" | "event_msg" | "response_item"
                | "turn_context" | "compacted") ->
          if has "payload" || has "timestamp" then Some "codex" else None
      | `String
          ( "metadata" | "context.append_message" | "context.append_loop_event"
          | "turn.prompt" | "turn.steer" | "config.update"
          | "tools.set_active_tools" | "llm.request" | "usage.record" ) ->
          (* Kimi Code wire.jsonl event names (protocol_version on metadata
             is the strongest signal; the other types are wire-only). *)
          Some "kimi"
      | _ ->
          if has "projectHash" && has "sessionId" then Some "agy"
          else if has "$set" then Some "agy"
          else if
            match member "role" j with `String _ -> true | _ -> false
          then Some "kimi"
          else if
            (* claude session lines carry transcript-graph keys (uuid links)
               or nest the turn under "message" *)
            has "message" || has "parentUuid" || has "leafUuid"
            || bool_field "isMeta" j
          then Some "claude"
          else if
            (match member "type" j with `String _ -> true | _ -> false)
            && has "content"
          then Some "grok"
          else None)

(* [head] is a prefix of the transcript's lines; the first line that sniffs
   to a format wins (transcripts open with format-neutral lines — e.g.
   claude's "file-history-snapshot" — so one line is not enough). *)
let detect_format ~(is_dir : bool) ~(head : string list) (path : string) :
    string option =
  match detect_format_by_path ~is_dir path with
  | Some f -> Some f
  | None -> List.find_map sniff_format_from_line head

(* ------------------------------------------------------------------ *)
(* Event timestamps + time-range filtering                             *)
(* ------------------------------------------------------------------ *)

(* Days since 1970-01-01 for a proleptic-Gregorian civil date (Howard
   Hinnant's civil_from_days inverse). *)
let days_from_civil ~(y : int) ~(m : int) ~(d : int) : int =
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let mp = (m + 9) mod 12 in
  let doy = (((153 * mp) + 2) / 5) + d - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

(* Parse a user- or transcript-supplied time into UTC epoch seconds:
   "2026-07-15", "2026-07-15T13:50", "2026-07-15 13:50:07",
   "2026-07-15T13:50:07.123Z", "2026-07-15T13:50:07+10:00", or bare epoch
   seconds. No timezone suffix means UTC. Fractional seconds are ignored. *)
let parse_time_spec (s : string) : float option =
  let s = String.trim s in
  let is_digit c = '0' <= c && c <= '9' in
  if s <> "" && String.for_all is_digit s then float_of_string_opt s
  else
    let zone_offset (z : string) : int option =
      if z = "" || z = "Z" || z = "z" then Some 0
      else if String.length z = 6 && (z.[0] = '+' || z.[0] = '-') then (
        try
          Scanf.sscanf (String.sub z 1 5) "%2d:%2d%!" (fun h m ->
              let off = (h * 3600) + (m * 60) in
              Some (if z.[0] = '-' then -off else off))
        with _ -> None)
      else None
    in
    let mk y mo d h mi sec rest =
      (* [rest] is "[.frac][Z|±HH:MM]" *)
      let zone =
        if String.length rest > 0 && rest.[0] = '.' then begin
          let i = ref 1 in
          while !i < String.length rest && is_digit rest.[!i] do incr i done;
          String.sub rest !i (String.length rest - !i)
        end
        else rest
      in
      match zone_offset zone with
      | None -> None
      | Some off ->
          if
            mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59
            || sec > 60
          then None
          else
            Some
              (float_of_int
                 ((days_from_civil ~y ~m:mo ~d * 86400)
                 + (h * 3600) + (mi * 60) + sec - off))
    in
    let attempts =
      [ (fun () ->
          Scanf.sscanf s "%4d-%2d-%2dT%2d:%2d:%2d%s" (fun y mo d h mi sec r ->
              mk y mo d h mi sec r))
      ; (fun () ->
          Scanf.sscanf s "%4d-%2d-%2d %2d:%2d:%2d%s" (fun y mo d h mi sec r ->
              mk y mo d h mi sec r))
      ; (fun () ->
          Scanf.sscanf s "%4d-%2d-%2dT%2d:%2d%s" (fun y mo d h mi r ->
              mk y mo d h mi 0 r))
      ; (fun () ->
          Scanf.sscanf s "%4d-%2d-%2d %2d:%2d%s" (fun y mo d h mi r ->
              mk y mo d h mi 0 r))
      ; (fun () ->
          Scanf.sscanf s "%4d-%2d-%2d%!" (fun y mo d -> mk y mo d 0 0 0 ""))
      ]
    in
    List.fold_left
      (fun acc attempt ->
        match acc with Some _ -> acc | None -> ( try attempt () with _ -> None))
      None attempts

(* claude / codex / agy lines all carry a top-level ISO-8601 "timestamp". *)
let line_time_of_timestamp_field (line : string) : float option =
  match Yojson.Safe.from_string line with
  | exception _ -> None
  | j -> (
      match member "timestamp" j with
      | `String ts -> parse_time_spec ts
      | _ -> None)

(* Kimi Code wire.jsonl events carry top-level "time" as unix-ms int;
   legacy context.jsonl has no per-event time. Fail open when absent. *)
let line_time_of_kimi (line : string) : float option =
  match Yojson.Safe.from_string line with
  | exception _ -> None
  | j -> (
      match member "time" j with
      | `Int ms -> Some (float_of_int ms /. 1000.0)
      | `Intlit s -> (
          match int_of_string_opt s with
          | Some ms -> Some (float_of_int ms /. 1000.0)
          | None -> None)
      | `Float ms -> Some (ms /. 1000.0)
      | _ -> None)

(* Formats with per-event timestamps we can range-filter on. legacy kimi
   context.jsonl and grok (chat_history.jsonl) carry none; Kimi Code wire
   uses top-level "time" (ms). opencode is handled by the directory source
   (message "time.created"). *)
let line_time_for_format (fmt : string) : (string -> float option) option =
  match String.lowercase_ascii (String.trim fmt) with
  | "claude" | "codex" | "agy" | "gemini" -> Some line_time_of_timestamp_field
  | "kimi" -> Some line_time_of_kimi
  | _ -> None

let in_time_range ~(since : float option) ~(until_ : float option)
    (t : float option) : bool =
  match t with
  | None -> true (* no reliable event time: fail open *)
  | Some t -> (
      (match since with Some s -> t >= s | None -> true)
      && match until_ with Some u -> t <= u | None -> true)

(* ------------------------------------------------------------------ *)
(* Compaction boundaries                                               *)
(* ------------------------------------------------------------------ *)

(* Long-lived sessions compact their context; replaying the whole
   transcript would resend enormous pre-compaction history. Markers
   (observed live, 2026-07):
   - claude: {"type":"system","subtype":"compact_boundary",
     "compactMetadata":{...}} (the follow-up isCompactSummary user line is
     dropped by the classifier).
   - codex: {"type":"compacted","payload":{...}} rollout items, and
     {"type":"event_msg","payload":{"type":"context_compacted"}} events.
   kimi wire has full_compaction.begin / context.apply_compaction but
   those are not used as replay boundaries yet; grok / agy have no known
   in-transcript marker; opencode's dir source has no transcript to
   replay-trim. *)

let is_claude_compaction (line : string) : bool =
  match Yojson.Safe.from_string line with
  | exception _ -> false
  | j -> member "subtype" j = `String "compact_boundary"

let is_codex_compaction (line : string) : bool =
  match Yojson.Safe.from_string line with
  | exception _ -> false
  | j -> (
      match member "type" j with
      | `String "compacted" -> true
      | `String "event_msg" ->
          member "type" (member "payload" j) = `String "context_compacted"
      | _ -> false)

let compaction_detector_for_format (fmt : string) : (string -> bool) option =
  match String.lowercase_ascii (String.trim fmt) with
  | "claude" -> Some is_claude_compaction
  | "codex" -> Some is_codex_compaction
  | _ -> None

(* Byte offset just past the last compaction marker among the complete
   lines currently in [path] (0 when none): replaying from this offset
   skips everything the session itself has already folded away. *)
let replay_start_offset ~(is_compaction : string -> bool) (path : string) :
    int =
  match open_in_bin path with
  | exception _ -> 0
  | ic ->
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
          let len = in_channel_length ic in
          let content = really_input_string ic len in
          let best = ref 0 in
          let start = ref 0 in
          for i = 0 to len - 1 do
            if content.[i] = '\n' then begin
              if is_compaction (String.sub content !start (i - !start)) then
                best := i + 1;
              start := i + 1
            end
          done;
          !best)

(* First (up to) [limit] newline-complete lines of [path], for sniffing. *)
let read_head_lines ?(limit = 50) (path : string) : string list =
  match open_in_bin path with
  | exception _ -> []
  | ic ->
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
          let rec go acc n =
            if n = 0 then List.rev acc
            else
              match input_line ic with
              | exception _ -> List.rev acc
              | line -> go (line :: acc) (n - 1)
          in
          go [] limit)

(* ------------------------------------------------------------------ *)
(* Incremental line consumption (tail -f semantics)                    *)
(* ------------------------------------------------------------------ *)

(* Split a byte buffer into complete lines (newline-terminated; the
   terminator is stripped) and the trailing partial remainder. A live
   transcript's last line may be mid-write — it stays in the remainder until
   its newline arrives, so partial JSON is never parsed. *)
let split_complete_lines (buf : string) : string list * string =
  let n = String.length buf in
  let lines = ref [] in
  let start = ref 0 in
  for i = 0 to n - 1 do
    if buf.[i] = '\n' then begin
      lines := String.sub buf !start (i - !start) :: !lines;
      start := i + 1
    end
  done;
  (List.rev !lines, String.sub buf !start (n - !start))

(* Input limits are intentionally independent from [--max-bytes], which caps
   the sanitized outbound body.  These limits protect the parser before it
   has classified or sanitized hostile/malformed live transcript data. *)
let max_raw_line_bytes = 1024 * 1024
let max_tail_read_bytes = 1024 * 1024
let max_lines_per_step = 256
let max_opencode_file_bytes = 1024 * 1024
let max_complete_message_bytes = 1024 * 1024

type tail_state = {
  offset : int;
  pending : string;
  dropping_oversize : bool;
  oversize_lines : int;
}

let initial_tail_state ?(from_start = false) (path : string) : tail_state =
  let size = try (Unix.stat path).Unix.st_size with _ -> 0 in
  {
    offset = (if from_start then 0 else size);
    pending = "";
    dropping_oversize = false;
    oversize_lines = 0;
  }

(* Read newly-appended bytes past [st.offset] and return the complete lines
   they yield. Handles truncation / rotation (file shrank below our offset →
   restart from 0 and drop the stale partial). Read errors are non-fatal and
   yield no lines. *)
let tail_read ?(max_offset : int option) ~(path : string) (st : tail_state) :
    string list * tail_state =
  match Unix.stat path with
  | exception _ -> ([], st)
  | { Unix.st_size = actual_size; _ } ->
      let st =
        if actual_size < st.offset then
          {
            offset = 0;
            pending = "";
            dropping_oversize = false;
            oversize_lines = st.oversize_lines;
          }
        else st
      in
      let size =
        match max_offset with
        | Some ceiling -> min actual_size ceiling
        | None -> actual_size
      in
      if size <= st.offset then ([], st)
      else begin
        match open_in_bin path with
        | exception _ -> ([], st)
        | ic ->
            Fun.protect
              ~finally:(fun () -> close_in_noerr ic)
              (fun () ->
                seek_in ic st.offset;
                let available = min (size - st.offset) max_tail_read_bytes in
                let chunk = really_input_string ic available in
                let lines = ref [] in
                let current = Buffer.create (String.length st.pending + 256) in
                Buffer.add_string current st.pending;
                let dropping = ref st.dropping_oversize in
                let dropped = ref st.oversize_lines in
                let consumed = ref 0 in
                let completed = ref 0 in
                while
                  !consumed < String.length chunk
                  && !completed < max_lines_per_step
                do
                  let c = chunk.[!consumed] in
                  incr consumed;
                  if c = '\n' then begin
                    if !dropping then begin
                      dropping := false
                    end else lines := Buffer.contents current :: !lines;
                    Buffer.clear current;
                    incr completed
                  end else if not !dropping then begin
                    if Buffer.length current < max_raw_line_bytes then
                      Buffer.add_char current c
                    else begin
                      Buffer.clear current;
                      dropping := true;
                      incr dropped
                    end
                  end
                done;
                ( List.rev !lines
                , {
                    offset = st.offset + !consumed;
                    pending = Buffer.contents current;
                    dropping_oversize = !dropping;
                    oversize_lines = !dropped;
                  } ))
      end

(* ------------------------------------------------------------------ *)
(* Forwarded-message formatting                                        *)
(* ------------------------------------------------------------------ *)

(* Drop terminal control strings before the Unicode control pass. Merely
   deleting ESC / C1 code points would leave their printable payload behind
   (for example "31m" from a CSI colour sequence, or an OSC window title).
   Both the 7-bit ESC introducers and their UTF-8-encoded C1 forms are
   recognised. Unterminated string controls consume the rest of the input:
   forwarding less is safer than leaking an OSC/DCS payload. *)
let strip_terminal_sequences (s : string) : string =
  let len = String.length s in
  let out = Buffer.create len in
  let rec consume_csi i =
    if i >= len then len
    else
      let c = Char.code s.[i] in
      if c >= 0x40 && c <= 0x7e then i + 1 else consume_csi (i + 1)
  in
  let rec consume_string_control i =
    if i >= len then len
    else if s.[i] = '\007' then i + 1
    else if s.[i] = '\027' && i + 1 < len && s.[i + 1] = '\\' then i + 2
    else if i + 1 < len && Char.code s.[i] = 0xc2
            && Char.code s.[i + 1] = 0x9c
    then i + 2
    else consume_string_control (i + 1)
  in
  let rec consume_escape i =
    if i >= len then len
    else
      let c = Char.code s.[i] in
      if c >= 0x20 && c <= 0x2f then consume_escape (i + 1)
      else i + 1
  in
  let rec loop i =
    if i >= len then Buffer.contents out
    else if s.[i] = '\027' then
      if i + 1 >= len then loop len
      else
        (match s.[i + 1] with
         | '[' -> loop (consume_csi (i + 2))
         | ']' | 'P' | 'X' | '^' | '_' ->
             loop (consume_string_control (i + 2))
         | _ -> loop (consume_escape (i + 1)))
    else if i + 1 < len && Char.code s.[i] = 0xc2 then
      (match Char.code s.[i + 1] with
       | 0x9b -> loop (consume_csi (i + 2))
       | 0x9d | 0x90 | 0x98 | 0x9e | 0x9f ->
           loop (consume_string_control (i + 2))
       | _ ->
           Buffer.add_char out s.[i];
           loop (i + 1))
    else begin
      Buffer.add_char out s.[i];
      loop (i + 1)
    end
  in
  loop 0

(* Remove all Unicode control and format characters. [Cc] covers NUL, C0,
   DEL and C1; [Cf] covers bidi isolates/overrides, zero-width spoofing
   controls, BOM, and related invisible formatting characters. [Zl]/[Zp]
   are also removed because renderers can treat them as unframed newlines.
   ASCII newlines are split before this pass and restored only by
   [frame_continuation_lines]. Malformed UTF-8 is dropped so the outbound
   boundary always emits UTF-8. *)
let strip_unicode_controls (s : string) : string =
  let out = Buffer.create (String.length s) in
  Uutf.String.fold_utf_8
    (fun () _ -> function
      | `Malformed _ -> ()
      | `Uchar u ->
          (match Uucp.Gc.general_category u with
           | `Cc | `Cf | `Zl | `Zp -> ()
           | _ -> Uutf.Buffer.add_utf_8 out u))
    () s;
  Buffer.contents out

let global_substitute (regexp : Str.regexp) (f : string -> string)
    (s : string) : string =
  Str.global_substitute regexp (fun whole -> f (Str.matched_string whole)) s

let authorization_re =
  Str.regexp_case_fold
    "\\b\\(authorization\\|proxy-authorization\\)[ \t]*:[^\n]*"

let bearer_re =
  Str.regexp_case_fold "\\bbearer[ \t]+[A-Za-z0-9._~+/-]+"

let credential_assignment_re =
  Str.regexp_case_fold
    ("\\b\\(password\\|passwd\\|pwd\\|secret\\|token\\|api[_-]*key\\|"
    ^ "access[_-]*key\\|access[_-]*token\\|client[_-]*secret\\|"
    ^ "private[_-]*key\\)\\b\\([ \t]*[=:][ \t]*\\)"
    ^ "\\(\"[^\"]*\"\\|'[^']*'\\|[^ \t&,;]+\\)")

let json_credential_assignment_re =
  Str.regexp_case_fold
    ("\"\\(authorization\\|proxy-authorization\\|password\\|passwd\\|pwd\\|"
    ^ "secret\\|token\\|api[_-]*key\\|access[_-]*key\\|access[_-]*token\\|"
    ^ "client[_-]*secret\\|private[_-]*key\\)\"\\([ \t]*:[ \t]*\\)"
    ^ "\\(\"[^\"]*\"\\|'[^']*'\\|[^ \t,;}]+\\)")

let url_userinfo_re =
  Str.regexp_case_fold
    "\\b\\([A-Za-z][A-Za-z0-9+.-]*://\\)[^/@ \t]+@"

let url_query_secret_re =
  Str.regexp_case_fold
    ("\\([?&]\\)\\(api[_-]*key\\|access[_-]*key\\|access[_-]*token\\|"
    ^ "authorization\\|password\\|passwd\\|secret\\|token\\|auth\\|key\\|"
    ^ "signature\\|sig\\|x-amz-signature\\|x-goog-signature\\)"
    ^ "\\([ \t]*=[ \t]*\\)\\([^&# \t]+\\)")

let jwt_re =
  Str.regexp
    "[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"

let api_key_shape_re =
  Str.regexp
    ("\\(sk-[A-Za-z0-9_-]+\\|gh[pousr]_[A-Za-z0-9]+\\|"
    ^ "xox[baprs]-[A-Za-z0-9-]+\\|AKIA[0-9A-Z]+\\|"
    ^ "AIza[0-9A-Za-z_-]+\\)")

let redact_line (line : string) : string =
  let line =
    global_substitute authorization_re (fun _ -> "Authorization: [REDACTED]")
      line
  in
  let line =
    global_substitute url_userinfo_re
      (fun _ -> Str.matched_group 1 line ^ "[REDACTED]@") line
  in
  let line =
    global_substitute url_query_secret_re
      (fun _ ->
        Str.matched_group 1 line ^ Str.matched_group 2 line
        ^ Str.matched_group 3 line ^ "[REDACTED]")
      line
  in
  let line =
    global_substitute json_credential_assignment_re
      (fun _ ->
        "\"" ^ Str.matched_group 1 line ^ "\"" ^ Str.matched_group 2 line
        ^ "[REDACTED]")
      line
  in
  let line =
    global_substitute credential_assignment_re
      (fun _ ->
        Str.matched_group 1 line ^ Str.matched_group 2 line ^ "[REDACTED]")
      line
  in
  let line =
    global_substitute bearer_re (fun _ -> "Bearer [REDACTED]") line
  in
  let line =
    global_substitute jwt_re
      (fun token ->
        match String.split_on_char '.' token with
        | [ header; payload; signature ]
          when String.length header >= 8 && String.length payload >= 8
               && String.length signature >= 8 ->
            "[REDACTED JWT]"
        | _ -> token)
      line
  in
  global_substitute api_key_shape_re
    (fun token ->
      if String.length token >= 16 then "[REDACTED API KEY]" else token)
    line

let pem_begin_re = Str.regexp "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"
let pem_end_re = Str.regexp "-----END [A-Z0-9 ]*PRIVATE KEY-----"

let contains_re regexp s =
  try
    ignore (Str.search_forward regexp s 0);
    true
  with Not_found -> false

(* Sanitisation is deliberately centralized here, immediately before the
   role label / truncation formatter used by every forward-agent-log source. *)
let sanitize_forward_text (text : string) : string =
  let lines = String.split_on_char '\n' (strip_terminal_sequences text) in
  let rec redact_pem inside acc = function
    | [] -> List.rev acc
    | line :: rest ->
        let line = strip_unicode_controls line in
        if inside then
          if contains_re pem_end_re line then redact_pem false acc rest
          else redact_pem true acc rest
        else if contains_re pem_begin_re line then
          redact_pem (not (contains_re pem_end_re line))
            ("[REDACTED PRIVATE KEY]" :: acc) rest
        else redact_pem false (redact_line line :: acc) rest
  in
  String.concat "\n" (redact_pem false [] lines)

let frame_continuation_lines (text : string) : string =
  match String.split_on_char '\n' text with
  | [] -> ""
  | first :: rest ->
      String.concat "\n" (first :: List.map (fun line -> "> " ^ line) rest)

(* Cut [s] to at most [max_bytes] bytes without splitting a UTF-8 sequence
   (back off over continuation bytes). *)
let truncate_utf8 (s : string) (max_bytes : int) : string =
  if String.length s <= max_bytes then s
  else begin
    let cut = ref (max 0 max_bytes) in
    while !cut > 0 && Char.code s.[!cut] land 0xC0 = 0x80 do decr cut done;
    String.sub s 0 !cut
  end

let format_forward_body ~(role : role) ~(max_bytes : int) (text : string) :
    string =
  let label = role_label role in
  let text = sanitize_forward_text text in
  if String.length text <= max_bytes then
    label ^ " " ^ frame_continuation_lines text
  else
    let cut = truncate_utf8 text max_bytes in
    Printf.sprintf "%s %s… [truncated: %d of %d bytes shown]" label
      (frame_continuation_lines cut) (String.length cut) (String.length text)

(* ------------------------------------------------------------------ *)
(* Forwarding loop                                                     *)
(* ------------------------------------------------------------------ *)

(* Test fixture gate (repo convention): with C2C_SEND_MESSAGE_FIXTURE=1 the
   send path prints what WOULD be sent instead of touching a broker. *)
let send_fixture_mode () =
  match Sys.getenv_opt "C2C_SEND_MESSAGE_FIXTURE" with
  | Some "1" -> true
  | _ -> false

(* Send one formatted body via the normal broker send path. *)
let deliver_via_broker ~(broker : Broker.t) ~(from_alias : string)
    ~(to_alias : string) (body : string) : (unit, string) result =
  match
    C2c_watch_data.send_dm broker ~from_alias ~to_alias ~content:body
  with
  | C2c_watch_data.Send_failed msg -> Error msg
  | _ -> Ok ()

type run_stats = { forwarded : int; send_failures : int }

let max_delivery_attempts = 4
let initial_retry_delay_s = 0.05
let max_retry_delay_s = 0.20

type delivery_outcome = Delivered | Abandoned of string

(* Keep the complete formatted event in this stack frame until delivery
   succeeds or the explicit bounded-loss policy is reached.  Backoff is
   deliberately short: this command mirrors a live conversation and must not
   stall transcript consumption indefinitely when its destination is down. *)
let send_with_retry ?(sleep = fun seconds ->
    ignore (Unix.select [] [] [] seconds))
    ~(send : string -> (unit, string) result) (body : string) :
    delivery_outcome =
  let rec attempt number delay =
    match send body with
    | Ok () -> Delivered
    | Error msg when number < max_delivery_attempts ->
        Printf.eprintf
          "[c2c-forward-agent-log] delivery attempt %d/%d failed: %s; retrying in %.2fs\n%!"
          number max_delivery_attempts msg delay;
        sleep delay;
        attempt (number + 1) (min max_retry_delay_s (delay *. 2.))
    | Error msg ->
        Printf.eprintf
          "[c2c-forward-agent-log] delivery failed after %d attempts: %s; dropping this event under the bounded retry loss policy. Restore the destination and replay with --from-start or --since.\n%!"
          max_delivery_attempts msg;
        Abandoned msg
  in
  attempt 1 initial_retry_delay_s

(* One pass: consume newly-completed lines, classify, forward. [send] is
   injected so tests can capture instead of enqueueing. *)
let step ?(max_offset : int option) ~(path : string)
    ~(classify : string -> (role * string) option)
    ~(max_bytes : int) ~(send : string -> (unit, string) result)
    (st : tail_state) (stats : run_stats) : tail_state * run_stats =
  let lines, st' = tail_read ?max_offset ~path st in
  if st'.oversize_lines > st.oversize_lines then
    Printf.eprintf
      "[c2c-forward-agent-log] dropped %d oversized transcript line(s) (limit %d bytes each); this is the documented malformed-input loss policy\n%!"
      (st'.oversize_lines - st.oversize_lines) max_raw_line_bytes;
  let stats =
    List.fold_left
      (fun stats line ->
        match classify line with
        | None -> stats
        | Some (role, text) ->
            let body = format_forward_body ~role ~max_bytes text in
            (match send_with_retry ~send body with
             | Delivered -> { stats with forwarded = stats.forwarded + 1 }
             | Abandoned _ ->
                 { stats with send_failures = stats.send_failures + 1 }))
      stats lines
  in
  (st', stats)

(* Follow [path] and forward filtered events until the process is killed
   (or, with [once], drain what is currently readable and return).
   [start_offset] (only meaningful when replaying) begins the replay at a
   byte offset instead of 0 — see [replay_start_offset]. *)
let run ?(start_offset : int option) ~(path : string)
    ~(classify : string -> (role * string) option) ~(max_bytes : int)
    ~(interval : float) ~(from_start : bool) ~(once : bool)
    ~(send : string -> (unit, string) result) () : run_stats =
  let st = initial_tail_state ~from_start:(from_start || once) path in
  let st =
    match start_offset with
    | Some o when from_start || once -> { st with offset = o }
    | _ -> st
  in
  let stats = { forwarded = 0; send_failures = 0 } in
  if once then
    (* [tail_read] deliberately bounds each pass. Drain up to the file size
       observed at invocation so --once retains its current-history contract
       without chasing a transcript that is still growing forever. *)
    let target_offset =
      try (Unix.stat path).Unix.st_size with _ -> st.offset
    in
    let rec drain st stats =
      if st.offset >= target_offset then stats
      else
        let st', stats =
          step ~max_offset:target_offset ~path ~classify ~max_bytes ~send st
            stats
        in
        if st'.offset <= st.offset then stats else drain st' stats
    in
    drain st stats
  else begin
    let rec loop st stats =
      let st, stats = step ~path ~classify ~max_bytes ~send st stats in
      ignore (Unix.select [] [] [] interval);
      loop st stats
    in
    loop st stats
  end

(* ------------------------------------------------------------------ *)
(* OpenCode storage-directory source                                   *)
(* ------------------------------------------------------------------ *)

(* OpenCode keeps no append-only transcript. Messages are individual JSON
   files under ~/.local/share/opencode/storage/message/<sessionID>/msg_*.json
   and their bodies live as parts under .../storage/part/<messageID>/
   prt_*.json (message and part ids embed a millisecond timestamp, so
   lexicographic order is chronological). We poll the message directory:
   - a user message is forwarded as soon as its file appears;
   - an assistant message only once its "time.completed" stamp exists —
     text parts stream (their files are rewritten as the text grows), so
     forwarding earlier would send half a sentence.
   Only "text"-type parts are conversation; "reasoning" / tool / step /
   snapshot parts, and text parts flagged "synthetic":true (harness-injected
   context), are NOISE. A message file that fails to parse is retried on the
   next poll (it may be mid-write); non-user/assistant roles are marked
   consumed and skipped. *)

type opencode_state = { done_ids : (string, unit) Hashtbl.t }

(* .../storage/message/<sessionID> -> .../storage/part *)
let opencode_part_root ~(message_dir : string) : string =
  Filename.concat (Filename.dirname (Filename.dirname message_dir)) "part"

type bounded_json = Json of Yojson.Safe.t | Unreadable | Json_too_large

let read_json_file_bounded (path : string) : bounded_json =
  match Unix.stat path with
  | exception _ -> Unreadable
  | { Unix.st_size = size; _ } when size > max_opencode_file_bytes ->
      Json_too_large
  | _ ->
    match open_in_bin path with
    | exception _ -> Unreadable
  | ic ->
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
          match
            Yojson.Safe.from_string
              (really_input_string ic (in_channel_length ic))
          with
          | exception _ -> Unreadable
          | j -> Json j)

let read_json_file (path : string) : Yojson.Safe.t option =
  match read_json_file_bounded path with Json j -> Some j | _ -> None

let opencode_message_files (dir : string) : string list =
  match Sys.readdir dir with
  | exception _ -> []
  | entries ->
      Array.to_list entries
      |> List.filter (fun e ->
             String.starts_with ~prefix:"msg_" e
             && Filename.check_suffix e ".json")
      |> List.sort compare

type opencode_text = Text_ready of string | Text_not_ready | Text_too_large

let opencode_message_text_bounded ~(part_root : string) ~(msg_id : string)
    ~(for_user : bool) : opencode_text =
  let dir = Filename.concat part_root msg_id in
  match Sys.readdir dir with
  | exception _ -> Text_not_ready
  | entries ->
      let files = Array.to_list entries |> List.sort compare in
      let out = Buffer.create 256 in
      let rec collect = function
        | [] -> Text_ready (Buffer.contents out)
        | e :: rest ->
            (match read_json_file_bounded (Filename.concat dir e) with
             | Unreadable -> Text_not_ready
             | Json_too_large -> Text_too_large
             | Json p ->
                 if member "type" p <> `String "text"
                    || bool_field "synthetic" p
                 then collect rest
                 else
                   match member "text" p with
                   | `String t ->
                       let trimmed = String.trim t in
                       if trimmed = ""
                          || (for_user && is_user_noise_text trimmed)
                       then collect rest
                       else
                         let separator = if Buffer.length out = 0 then 0 else 2 in
                         if
                           Buffer.length out + separator + String.length trimmed
                           > max_complete_message_bytes
                         then Text_too_large
                         else begin
                           if separator <> 0 then Buffer.add_string out "\n\n";
                           Buffer.add_string out trimmed;
                           collect rest
                         end
                   | _ -> collect rest)
      in
      collect files

let opencode_message_text ~(part_root : string) ~(msg_id : string)
    ~(for_user : bool) : string =
  match opencode_message_text_bounded ~part_root ~msg_id ~for_user with
  | Text_ready text -> text
  | Text_not_ready | Text_too_large -> ""

(* opencode message times are millisecond epochs under "time". *)
let opencode_message_time (j : Yojson.Safe.t) : float option =
  match member "created" (member "time" j) with
  | `Int ms -> Some (float_of_int ms /. 1000.)
  | `Float ms -> Some (ms /. 1000.)
  | `Intlit s -> Option.map (fun ms -> ms /. 1000.) (float_of_string_opt s)
  | _ -> None

(* One poll pass over the message directory. Mutates [st.done_ids]. *)
let opencode_step ?(since : float option) ?(until_ : float option)
    ~(message_dir : string) ~(max_bytes : int)
    ~(send : string -> (unit, string) result) (st : opencode_state)
    (stats : run_stats) : run_stats =
  let part_root = opencode_part_root ~message_dir in
  List.fold_left
    (fun stats fname ->
      let msg_id = Filename.chop_suffix fname ".json" in
      if Hashtbl.mem st.done_ids msg_id then stats
      else
        match read_json_file_bounded (Filename.concat message_dir fname) with
        | Unreadable -> stats
        | Json_too_large ->
            Printf.eprintf
              "[c2c-forward-agent-log] dropping oversized OpenCode message metadata %s (limit %d bytes); this is the documented malformed-input loss policy\n%!"
              msg_id max_opencode_file_bytes;
            Hashtbl.replace st.done_ids msg_id ();
            stats
        | Json j ->
            let forward role =
              if not (in_time_range ~since ~until_ (opencode_message_time j))
              then begin
                Hashtbl.replace st.done_ids msg_id ();
                stats
              end else
                match
                  opencode_message_text_bounded ~part_root ~msg_id
                    ~for_user:(role = User)
                with
                | Text_not_ready -> stats
                | Text_too_large ->
                    Printf.eprintf
                      "[c2c-forward-agent-log] dropping oversized OpenCode message %s (complete text limit %d bytes); this is the documented malformed-input loss policy\n%!"
                      msg_id max_complete_message_bytes;
                    Hashtbl.replace st.done_ids msg_id ();
                    stats
                | Text_ready "" ->
                    Hashtbl.replace st.done_ids msg_id ();
                    stats
                | Text_ready text ->
                    let body = format_forward_body ~role ~max_bytes text in
                    (match send_with_retry ~send body with
                     | Delivered ->
                         Hashtbl.replace st.done_ids msg_id ();
                         { stats with forwarded = stats.forwarded + 1 }
                     | Abandoned _ ->
                         Hashtbl.replace st.done_ids msg_id ();
                         { stats with
                           send_failures = stats.send_failures + 1
                         })
            in
            (match member "role" j with
            | `String "user" -> forward User
            | `String "assistant" ->
                if member "completed" (member "time" j) = `Null then stats
                else forward Agent
            | _ ->
                Hashtbl.replace st.done_ids msg_id ();
                stats))
    stats
    (opencode_message_files message_dir)

(* Without [from_start], everything already present at attach time is marked
   consumed unsent — mirroring the jsonl tail's start-at-EOF default. *)
let opencode_initial_state ?(from_start = false) (message_dir : string) :
    opencode_state =
  let st = { done_ids = Hashtbl.create 64 } in
  if not from_start then
    List.iter
      (fun f -> Hashtbl.replace st.done_ids (Filename.chop_suffix f ".json") ())
      (opencode_message_files message_dir);
  st

let run_opencode ?(since : float option) ?(until_ : float option)
    ~(message_dir : string) ~(max_bytes : int) ~(interval : float)
    ~(from_start : bool) ~(once : bool)
    ~(send : string -> (unit, string) result) () : run_stats =
  let st =
    opencode_initial_state ~from_start:(from_start || once) message_dir
  in
  let stats = { forwarded = 0; send_failures = 0 } in
  if once then opencode_step ?since ?until_ ~message_dir ~max_bytes ~send st stats
  else begin
    let rec loop stats =
      let stats =
        opencode_step ?since ?until_ ~message_dir ~max_bytes ~send st stats
      in
      ignore (Unix.select [] [] [] interval);
      loop stats
    in
    loop stats
  end
