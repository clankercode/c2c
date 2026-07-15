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

   SAFETY (B098 "bus, never RPC"): forwarded transcript excerpts are DATA.
   This command only reads a local file and enqueues ordinary messages via
   the normal send path; it adds no approval or RPC semantics, and nothing a
   recipient replies with feeds back into this watcher. *)

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
      if bool_field "isMeta" j || bool_field "isSidechain" j then None
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

(* Kimi Code CLI (~/.kimi/sessions/<project-hash>/<uuid>/context.jsonl,
   observed live 2026-07): one context entry per line, keyed by "role".
   - {"role":"user","content":"..."} — human input (string, or text blocks).
   - {"role":"assistant","content":<string|blocks>,"tool_calls":[...]} —
     content is the chat text; block lists carry {"type":"think",...}
     reasoning (NOISE) alongside {"type":"text",...} output.
   - roles "_system_prompt" / "_checkpoint" / "_usage" / "tool" are
     machinery. NOISE. *)

let classify_kimi_line (line : string) : (role * string) option =
  match Yojson.Safe.from_string line with
  | exception _ -> None
  | j -> (
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
      | _ -> None)

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

(* Path heuristics over the clients' standard session-store locations. *)
let detect_format_by_path ~(is_dir : bool) (path : string) : string option =
  let base = Filename.basename path in
  let has = contains_sub path in
  if is_dir || has "/storage/message/" then Some "opencode"
  else if base = "chat_history.jsonl" || has "/.grok/" then Some "grok"
  else if base = "context.jsonl" || has "/.kimi/" then Some "kimi"
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
   ops); kimi keys entries by top-level "role"; claude nests the turn under
   "message"; grok puts "content" at top level next to "type". *)
let sniff_format_from_line (line : string) : string option =
  match Yojson.Safe.from_string line with
  | exception _ -> None
  | j -> (
      let has k = member k j <> `Null in
      match member "type" j with
      | `String ("session_meta" | "event_msg" | "response_item"
                | "turn_context" | "compacted") ->
          if has "payload" || has "timestamp" then Some "codex" else None
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

type tail_state = { offset : int; pending : string }

let initial_tail_state ?(from_start = false) (path : string) : tail_state =
  let size = try (Unix.stat path).Unix.st_size with _ -> 0 in
  { offset = (if from_start then 0 else size); pending = "" }

(* Read newly-appended bytes past [st.offset] and return the complete lines
   they yield. Handles truncation / rotation (file shrank below our offset →
   restart from 0 and drop the stale partial). Read errors are non-fatal and
   yield no lines. *)
let tail_read ~(path : string) (st : tail_state) : string list * tail_state =
  match Unix.stat path with
  | exception _ -> ([], st)
  | { Unix.st_size = size; _ } ->
      let st =
        if size < st.offset then { offset = 0; pending = "" } else st
      in
      if size = st.offset then ([], st)
      else begin
        match open_in_bin path with
        | exception _ -> ([], st)
        | ic ->
            Fun.protect
              ~finally:(fun () -> close_in_noerr ic)
              (fun () ->
                seek_in ic st.offset;
                let len = size - st.offset in
                let chunk = really_input_string ic len in
                let lines, pending =
                  split_complete_lines (st.pending ^ chunk)
                in
                (lines, { offset = size; pending }))
      end

(* ------------------------------------------------------------------ *)
(* Forwarded-message formatting                                        *)
(* ------------------------------------------------------------------ *)

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
  if String.length text <= max_bytes then label ^ " " ^ text
  else
    let cut = truncate_utf8 text max_bytes in
    Printf.sprintf "%s %s… [truncated: %d of %d bytes shown]" label cut
      (String.length cut) (String.length text)

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

(* One pass: consume newly-completed lines, classify, forward. [send] is
   injected so tests can capture instead of enqueueing. *)
let step ~(path : string) ~(classify : string -> (role * string) option)
    ~(max_bytes : int) ~(send : string -> (unit, string) result)
    (st : tail_state) (stats : run_stats) : tail_state * run_stats =
  let lines, st = tail_read ~path st in
  let stats =
    List.fold_left
      (fun stats line ->
        match classify line with
        | None -> stats
        | Some (role, text) ->
            let body = format_forward_body ~role ~max_bytes text in
            (match send body with
             | Ok () -> { stats with forwarded = stats.forwarded + 1 }
             | Error msg ->
                 Printf.eprintf "[c2c-forward-agent-log] send failed: %s\n%!"
                   msg;
                 { stats with send_failures = stats.send_failures + 1 }))
      stats lines
  in
  (st, stats)

(* Follow [path] and forward filtered events until the process is killed
   (or, with [once], drain what is currently readable and return). *)
let run ~(path : string) ~(classify : string -> (role * string) option)
    ~(max_bytes : int) ~(interval : float) ~(from_start : bool)
    ~(once : bool) ~(send : string -> (unit, string) result) : run_stats =
  let st = initial_tail_state ~from_start:(from_start || once) path in
  let stats = { forwarded = 0; send_failures = 0 } in
  if once then
    let _st, stats = step ~path ~classify ~max_bytes ~send st stats in
    stats
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

let read_json_file (path : string) : Yojson.Safe.t option =
  match open_in_bin path with
  | exception _ -> None
  | ic ->
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
          match
            Yojson.Safe.from_string
              (really_input_string ic (in_channel_length ic))
          with
          | exception _ -> None
          | j -> Some j)

let opencode_message_files (dir : string) : string list =
  match Sys.readdir dir with
  | exception _ -> []
  | entries ->
      Array.to_list entries
      |> List.filter (fun e ->
             String.starts_with ~prefix:"msg_" e
             && Filename.check_suffix e ".json")
      |> List.sort compare

let opencode_message_text ~(part_root : string) ~(msg_id : string)
    ~(for_user : bool) : string =
  let dir = Filename.concat part_root msg_id in
  match Sys.readdir dir with
  | exception _ -> ""
  | entries ->
      Array.to_list entries
      |> List.sort compare
      |> List.filter_map (fun e ->
             match read_json_file (Filename.concat dir e) with
             | None -> None
             | Some p ->
                 if member "type" p <> `String "text" then None
                 else if bool_field "synthetic" p then None
                 else (
                   match member "text" p with
                   | `String t ->
                       let trimmed = String.trim t in
                       if trimmed = ""
                          || (for_user && is_user_noise_text trimmed)
                       then None
                       else Some trimmed
                   | _ -> None))
      |> String.concat "\n\n"

(* One poll pass over the message directory. Mutates [st.done_ids]. *)
let opencode_step ~(message_dir : string) ~(max_bytes : int)
    ~(send : string -> (unit, string) result) (st : opencode_state)
    (stats : run_stats) : run_stats =
  let part_root = opencode_part_root ~message_dir in
  List.fold_left
    (fun stats fname ->
      let msg_id = Filename.chop_suffix fname ".json" in
      if Hashtbl.mem st.done_ids msg_id then stats
      else
        match read_json_file (Filename.concat message_dir fname) with
        | None -> stats
        | Some j ->
            let forward role =
              Hashtbl.replace st.done_ids msg_id ();
              let text =
                opencode_message_text ~part_root ~msg_id
                  ~for_user:(role = User)
              in
              if text = "" then stats
              else
                let body = format_forward_body ~role ~max_bytes text in
                (match send body with
                | Ok () -> { stats with forwarded = stats.forwarded + 1 }
                | Error msg ->
                    Printf.eprintf
                      "[c2c-forward-agent-log] send failed: %s\n%!" msg;
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

let run_opencode ~(message_dir : string) ~(max_bytes : int)
    ~(interval : float) ~(from_start : bool) ~(once : bool)
    ~(send : string -> (unit, string) result) : run_stats =
  let st =
    opencode_initial_state ~from_start:(from_start || once) message_dir
  in
  let stats = { forwarded = 0; send_failures = 0 } in
  if once then opencode_step ~message_dir ~max_bytes ~send st stats
  else begin
    let rec loop stats =
      let stats = opencode_step ~message_dir ~max_bytes ~send st stats in
      ignore (Unix.select [] [] [] interval);
      loop stats
    in
    loop stats
  end
