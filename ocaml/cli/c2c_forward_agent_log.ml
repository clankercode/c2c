(* c2c_forward_agent_log — B193: follow a coding-agent session transcript
   (jsonl) and forward ONLY the human-visible conversation — user input and
   assistant plaintext — to a c2c address, so a colleague (or a coordinator
   session, possibly on another machine via alias@host) can observe a session
   without the tool-call / thinking noise.

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
   interruption markers. Matched on the trimmed text prefix. *)
let user_noise_prefixes =
  [ "<system-reminder"
  ; "<local-command-stdout"
  ; "<local-command-stderr"
  ; "<c2c"
  ; "[Request interrupted"
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

(* Format registry — Claude Code first-class today; add other clients'
   transcript formats here. *)
let classifier_for_format (fmt : string) :
    (string -> (role * string) option) option =
  match String.lowercase_ascii (String.trim fmt) with
  | "claude" -> Some classify_claude_line
  | _ -> None

let supported_formats = [ "claude" ]

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
