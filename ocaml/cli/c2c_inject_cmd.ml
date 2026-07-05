(* c2c_inject_cmd - PTY inject and screen subcommands.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open Cmdliner.Term.Syntax

(* --- keycode parsing for inject ------------------------------------------- *)

(** [inject_keycode s] parses a keycode literal and returns the expanded string.
    Supported keycodes:
      :enter  -> "\r"
      :esc    -> "\x1b"
      :ctrlc  -> "\x03"
      :ctrlz  -> "\x1a"
      :up     -> "\x1b[A"
      :down   -> "\x1b[B"
      :left   -> "\x1b[D"
      :right  -> "\x1b[C"
      :tab    -> "\x09"
      :backspace -> "\x7f"
    Plain text is returned as-is. Unknown :xxx forms cause an error. *)
let inject_keycode (s : string) : string =
  match s with
  | ":enter" -> "\r"
  | ":esc" -> "\x1b"
  | ":ctrlc" -> "\x03"
  | ":ctrlz" -> "\x1a"
  | ":up" -> "\x1b[A"
  | ":down" -> "\x1b[B"
  | ":left" -> "\x1b[D"
  | ":right" -> "\x1b[C"
  | ":tab" -> "\x09"
  | ":backspace" -> "\x7f"
  | other ->
      if String.length other > 0 && other.[0] = ':' then (
        Printf.eprintf "error: unknown keycode %S. Known: :enter, :esc, :ctrlc, :ctrlz, :up, :down, :left, :right, :tab, :backspace\n%!" other;
        exit 1)
      else other

(* --- UUID and timestamp helpers for history injection --- *)

(** Generate a random UUID v4 string. *)
let uuid_v4 () =
  let hex_char n =
    let hex_chars = "0123456789abcdef" in
    hex_chars.[n land 0xf]
  in
  let segment n = String.init n (fun _ -> hex_char (Random.int 16)) in
  let segments = Array.init 5 (fun i ->
    match i with
    | 0 -> segment 8
    | 1 -> segment 4
    | 2 -> "4" ^ segment 3
    | 3 -> String.make 1 "abcdef".[Random.int 6] ^ segment 3
    | 4 -> segment 12
    | _ -> segment 8)  (* should not happen *)
  in
  Printf.sprintf "%s-%s-%s-%s-%s" segments.(0) segments.(1) segments.(2) segments.(3) segments.(4)

(** Return current UTC timestamp as ISO 8601 string. *)
let timestamp_utc () = C2c_time.now_iso8601_utc ()

(** Slugify a path for Claude project directory naming.
    "/home/xertrov/foo" -> "-home-xertrov-foo" *)
let slugify_path (path : string) : string =
  String.map (fun c -> if c = '/' then '-' else c) path

(* --- session resolution for inject (pure OCaml) --- *)

(** Read a session JSON file and return session data as an assoc list.
    Returns None if the file doesn't exist or is invalid JSON. *)
let read_session_json (path : string) : (string * Yojson.Safe.t) list option =
  try
    let json = Yojson.Safe.from_file path in
    Some (Yojson.Safe.Util.to_assoc json)
  with _ -> None

(** Find a session by session_id or PID in a session JSON file.
    Returns Some (sessionId, cwd, pid) if found. *)
let find_session_in_file (path : string) (identifier : string) :
    (string * string * int) option =
  match read_session_json path with
  | None -> None
  | Some fields ->
      let get_string key =
        try Some (List.assoc key fields |> Yojson.Safe.Util.to_string) with _ -> None
      in
      let get_int key =
        try Some (List.assoc key fields |> Yojson.Safe.Util.to_int) with _ -> None
      in
      let session_id = get_string "sessionId" in
      let name = get_string "name" in
      let pid = get_int "pid" in
      let cwd = get_string "cwd" in
      let matches =
        (match session_id with Some s when s = identifier -> true | _ -> false) ||
        (match name with Some n when n = identifier -> true | _ -> false) ||
        (match pid with Some p when string_of_int p = identifier -> true | _ -> false)
      in
      if matches then
        match session_id, cwd, pid with
        | Some sid, Some c, Some p -> Some (sid, c, p)
        | _ -> None
      else None

(** Iterate over session directories looking for a matching session.
    Returns Some (session_id, cwd, pid) if found. *)
let find_session_by_identifier (identifier : string) :
    (string * string * int) option =
  let session_dirs = [
    (Sys.getenv "HOME") ^ "/.claude/sessions";
    (Sys.getenv "HOME") ^ "/.claude-p/sessions";
    (Sys.getenv "HOME") ^ "/.claude-w/sessions";
  ] in
  let rec walk_dirs dirs =
    match dirs with
    | [] -> None
    | dir :: rest ->
        if Sys.is_directory dir then
          let entries =
            try Array.to_list (Sys.readdir dir)
            with Sys_error _ -> []
          in
          let rec check_entries entries =
            match entries with
            | [] -> walk_dirs rest
            | entry :: rest_entries ->
                let path = Filename.concat dir entry in
                (match find_session_in_file path identifier with
                 | Some result -> Some result
                 | None -> check_entries rest_entries)
          in
          check_entries entries
        else walk_dirs rest
  in
  walk_dirs session_dirs

(** Find the transcript path for a session.
    Searches in ~/.claude/projects/ for a file named <session_id>.jsonl.
    Also tries the slugified cwd path. *)
let find_transcript_path (session_id : string) (cwd : string option) : string option =
  let home = Sys.getenv "HOME" in
  let projects_dir = Filename.concat home ".claude/projects" in
  if Sys.is_directory projects_dir then
    let entries =
      try Array.to_list (Sys.readdir projects_dir)
      with Sys_error _ -> []
    in
    let rec check entries =
      match entries with
      | [] -> None
      | entry :: rest ->
          let jsonl_path = Filename.concat projects_dir (Filename.concat entry (session_id ^ ".jsonl")) in
          if Sys.file_exists jsonl_path then Some jsonl_path
          else check rest
    in
    check entries
  else None

(* --- history injection (pure OCaml) --- *)

(** Inject a message by appending a user entry to the session's history.jsonl.
    Returns the transcript path used on success, or None on failure. *)
let inject_via_history (session_id : string) (cwd : string option) (message : string) : string option =
  let transcript_path =
    match cwd with
    | Some c ->
        (* Try slugified cwd path first *)
        let slug = slugify_path c in
        let home = Sys.getenv "HOME" in
        let path = Filename.concat home (Printf.sprintf ".claude/projects/%s/%s.jsonl" slug session_id) in
        if Sys.file_exists path then Some path else None
    | None -> None
  in
  let transcript_path =
    match transcript_path with
    | Some p -> Some p
    | None ->
        (* Try to find by scanning projects dir *)
        find_transcript_path session_id cwd
  in
  match transcript_path with
  | None -> None
  | Some path ->
      let parent_uuid = uuid_v4 () in
      let entry = `Assoc [
        ("parentUuid", `String parent_uuid);
        ("isSidechain", `Bool false);
        ("promptId", `String (uuid_v4 ()));
        ("type", `String "user");
        ("message", `Assoc [
            ("role", `String "user");
            ("content", `String message)
          ]);
        ("uuid", `String (uuid_v4 ()));
        ("timestamp", `String (timestamp_utc ()));
        ("userType", `String "external");
        ("entrypoint", `String "cli");
        ("cwd", `String (Option.value cwd ~default:"/home/xertrov"));
        ("sessionId", `String session_id);
        ("version", `String "2.1.109");
        ("gitBranch", `String "HEAD")
      ] in
      (try
         let oc = open_out_gen [Open_creat; Open_append] 0o644 path in
         Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
           output_string oc (Yojson.Safe.to_string entry ^ "\n"));
         Some path
       with Sys_error _ -> None)

(* --- PTY injection (shell out to pty_inject helper) --- *)

(** Path to the pty_inject helper binary. *)
let pty_inject_path () =
  match Sys.getenv_opt "C2C_PTY_INJECT" with
  | Some p -> p
  | None -> "/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject"

(** Inject via PTY using the pty_inject helper.
    Writes bracketed paste sequence then Enter after submit_delay seconds. *)
let inject_via_pty (terminal_pid : int) (pts_num : string) (message : string)
    ~(submit_delay : float) : bool =
  let inject_bin = pty_inject_path () in
  if not (Sys.file_exists inject_bin) then (
    Printf.eprintf "error: pty_inject helper not found at %s\n%!" inject_bin;
    false
  ) else
    let cmd = Printf.sprintf "%s %d %s '%s' %.3f"
      inject_bin terminal_pid pts_num
      (String.escaped message) submit_delay
    in
    let rc = Sys.command cmd in
    rc = 0

(* --- PTY helpers (shared by inject and screen) --- *)

(** Extract pts number from a /dev/pts/N path string. *)
let extract_pts (path : string) : string option =
  let prefix = "/dev/pts/" in
  if String.length path > String.length prefix
     && String.sub path 0 (String.length prefix) = prefix
  then
    Some (String.sub path (String.length prefix)
            (String.length path - String.length prefix))
  else None

(** Read the tty symlink target for a given fd of a process. *)
let read_tty_link (pid : int) (fd : string) : string option =
  try
    let path = Printf.sprintf "/proc/%d/fd/%s" pid fd in
    Some (Unix.readlink path)
  with _ -> None

(** Read a file's contents as a string.
    #388: delegates to C2c_utils (re-exported from C2c_io). *)
let read_file = C2c_utils.read_file

(** Find the pts number for a given PID by checking its stdio fds. *)
let resolve_pts_from_pid (pid : int) : string option =
  List.fold_left (fun acc fd ->
    match acc with
    | Some _ -> acc
    | None ->
        (match read_tty_link pid fd with
         | Some path -> extract_pts path
         | None -> None)
  ) None ["0"; "1"; "2"]

(** Check if a process has a given pts as a master tty-index.
    Returns true if the fdinfo for any fd contains "tty-index:\t<PTS>\n"
    and the fd links to /dev/ptmx. *)
let is_terminal_owner_for_pts (pid : int) (pts_num : string) : bool =
  try
    let fdinfo_dir = Printf.sprintf "/proc/%d/fdinfo" pid in
    if not (Sys.is_directory fdinfo_dir) then false
    else
      let entries = Sys.readdir fdinfo_dir in
      let result = ref false in
      Array.iter (fun entry ->
        if not !result then
          (try
             let fdinfo_path = Filename.concat fdinfo_dir entry in
             let content = read_file fdinfo_path in
             let needle = Printf.sprintf "tty-index:\t%s\n" pts_num in
             if String.length content >= String.length needle
                && String.sub content 0 (String.length needle) = needle
             then
               (try
                  let fd_path = Printf.sprintf "/proc/%d/fd/%s" pid entry in
                  let link = Unix.readlink fd_path in
                  if link = "/dev/ptmx" then result := true
                with _ -> ())
           with _ -> ())
      ) entries;
      !result
  with _ -> false

(** Walk the parent chain of a process looking for one that owns the given pts.
    Returns the terminal owner's PID if found. *)
let find_terminal_owner (session_pid : int) (pts_num : string) : int option =
  let rec walk (pid : int) (seen : int list) =
    if List.mem pid seen then None
    else
      (try
         if is_terminal_owner_for_pts pid pts_num then Some pid
         else
           let ppid =
             try
               let status_path = Printf.sprintf "/proc/%d/status" pid in
               let content = read_file status_path in
               let rec find_ppid lines =
                 match lines with
                 | [] -> None
                 | line :: rest ->
                     if String.length line >= 6
                        && String.sub line 0 6 = "PPid:\t"
                     then
                       (try Some (int_of_string (String.sub line 6 (String.length line - 6)))
                        with _ -> None)
                     else find_ppid rest
               in
               find_ppid (String.split_on_char '\n' content)
             with _ -> None
           in
           match ppid with
           | Some parent when parent > 0 -> walk parent (pid :: seen)
           | _ -> None
      with _ -> None)
  in
  walk session_pid []

(* --- inject target resolution (pure OCaml) --- *)

(** Result of resolving an injection target. *)
type inject_target = {
  terminal_pid : int;  (* 0 if not available (SSH session) *)
  pts_num : string;
  session_id : string option;
  cwd : string option;
  has_terminal_owner : bool;
}

(** Resolve an injection target from claude session identifier, PID, or explicit coords.
    For SSH sessions (no terminal owner), terminal_pid=0 but pts_num is still returned. *)
let resolve_inject_target
    (claude_session : string option)
    (pid : int option)
    (terminal_pid : int option)
    (pts : string option) : inject_target =
  match claude_session, pid, (terminal_pid, pts) with
  | Some session, None, (None, None) -> (
      (* Resolve by session identifier *)
      match find_session_by_identifier session with
      | None ->
          Printf.eprintf "error: session %S not found\n%!" session;
          exit 1
      | Some (session_id, cwd, proc_pid) ->
          let pts_num =
            match resolve_pts_from_pid proc_pid with
            | Some p -> p
            | None -> (
                (* Try with the session id directly as a PID hint *)
                match int_of_string_opt session with
                | Some p when p > 0 ->
                    (match resolve_pts_from_pid p with
                     | Some p -> p
                     | None -> "0")
                | _ -> "0"
              )
          in
          let tp, has_tp =
            match find_terminal_owner proc_pid pts_num with
            | Some t -> (t, true)
            | None -> (0, false)
          in
          { terminal_pid = tp; pts_num; session_id = Some session_id; cwd = Some cwd;
            has_terminal_owner = has_tp }
    )
  | None, Some p, (None, None) -> (
      (* Resolve by PID *)
      match resolve_pts_from_pid p with
      | None ->
          Printf.eprintf "error: pid %d has no /dev/pts on fds 0/1/2\n%!" p;
          exit 1
      | Some pts_num ->
          let tp, has_tp =
            match find_terminal_owner p pts_num with
            | Some t -> (t, true)
            | None -> (0, false)
          in
          { terminal_pid = tp; pts_num; session_id = None; cwd = None;
            has_terminal_owner = has_tp }
    )
  | _, _, (Some tp, Some pn) ->
      (* Explicit coordinates *)
      { terminal_pid = tp; pts_num = pn; session_id = None; cwd = None;
        has_terminal_owner = tp > 0 }
  | _ ->
      Printf.eprintf "error: must specify --claude-session, --pid, or --terminal-pid + --pts\n%!";
      exit 1

(* --- subcommand: inject claude -------------------------------------------- *)

(** Escape a string for XML attribute values. *)
let xml_escape (s : string) : string =
  let b = Buffer.create (String.length s * 2) in
  String.iter (fun c ->
    match c with
    | '&' -> Buffer.add_string b "&amp;"
    | '<' -> Buffer.add_string b "&lt;"
    | '>' -> Buffer.add_string b "&gt;"
    | '"' -> Buffer.add_string b "&quot;"
    | _ -> Buffer.add_char b c
  ) s;
  Buffer.contents b

(** Render a message payload as a <c2c> XML envelope. If [raw] is true,
    returns the message unchanged. *)
let render_payload (message : string) (event : string) (sender : string)
    (alias : string) (raw : bool) : string =
  if raw || String.length message > 0 && message.[0] = '<' then
    message
  else
    let attrs = Printf.sprintf "event=%S from=%S"
      event (xml_escape sender)
    in
    let attrs = if alias <> "" then attrs ^ Printf.sprintf " to=%S" (xml_escape alias) else attrs in
    let attrs = attrs ^ " source=\"pty\" source_tool=\"c2c_inject\" action_after=\"continue\"" in
    Printf.sprintf "<c2c %s>\n%s\n</c2c>" attrs message

(** The submit delay for Kimi clients (in seconds). *)
let kimi_submit_delay = 1.5

(** Effective submit delay for a given client. Returns the explicit delay or
    the client-specific default. *)
let effective_submit_delay (client : string) (explicit_delay : float option) : float =
  match explicit_delay with
  | Some d -> d
  | None ->
      if client = "kimi" then kimi_submit_delay
      else 0.2

(** Inject command: one-shot message/keycode injection into a Claude/Codex session. *)
let inject_cmd =
  let claude_session =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "claude-session" ] ~docv:"NAME_OR_ID"
      ~doc:"Target Claude session by name, session ID, or PID.")
  in
  let pid =
    Cmdliner.Arg.(value & opt (some int) None &
      info [ "pid" ] ~docv:"PID"
      ~doc:"Target any process by PID.")
  in
  let terminal_pid =
    Cmdliner.Arg.(value & opt (some int) None &
      info [ "terminal-pid" ] ~docv:"PID"
      ~doc:"Terminal emulator PID (use with --pts).")
  in
  let pts =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "pts" ] ~docv:"N"
      ~doc:"PTY slave number (required with --terminal-pid).")
  in
  let client =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "client" ] ~docv:"CLIENT"
      ~doc:"Client label: claude, codex, opencode, kimi, generic (default: generic).")
  in
  let event =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "event" ] ~docv:"EVENT"
      ~doc:"Event tag (default: message).")
  in
  let sender =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "from" ] ~docv:"SENDER"
      ~doc:"Sender name (default: c2c-inject).")
  in
  let alias =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "alias" ] ~docv:"ALIAS"
      ~doc:"Sender alias.")
  in
  let raw =
    Cmdliner.Arg.(value & flag &
      info [ "raw" ]
      ~doc:"Do not wrap message in <c2c> XML envelope.")
  in
  let delay =
    Cmdliner.Arg.(value & opt (some float) None &
      info [ "delay" ] ~docv:"MS"
      ~doc:"Delay between parts in milliseconds (default: 500).")
  in
  let method_ =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "method" ] ~docv:"METHOD"
      ~doc:"Injection method: pty, history, auto (default: auto).")
  in
  let dry_run =
    Cmdliner.Arg.(value & flag &
      info [ "dry-run" ]
      ~doc:"Show what would be injected without sending.")
  in
  let json =
    Cmdliner.Arg.(value & flag &
      info [ "json" ]
      ~doc:"Output JSON result.")
  in
  let+ claude_session = claude_session
  and+ pid = pid
  and+ terminal_pid = terminal_pid
  and+ pts = pts
  and+ client = client
  and+ event = event
  and+ sender = sender
  and+ alias = alias
  and+ raw = raw
  and+ delay = delay
  and+ method_ = method_
  and+ dry_run = dry_run
  and+ json = json
  and+ msg_tokens = Cmdliner.Arg.(non_empty & pos_all string [] & info [] ~docv:"MESSAGE" ~doc:"Message text or keycode (:enter, :esc, :ctrlc, etc.)")
  in
  (* Parse tokens: keycodes (:enter etc.) and plain text *)
  let parts : (string * string) list =
    List.map (fun token ->
      if String.length token > 0 && token.[0] = ':' then
        (token, inject_keycode token)
      else
        (token, token)
    ) msg_tokens
  in
  let full_text = String.concat " " (List.map snd parts) in
  let event_str = Option.value event ~default:"message" in
  let sender_str = Option.value sender ~default:"c2c-inject" in
  let alias_str = Option.value alias ~default:"" in
  let client_str = Option.value client ~default:"generic" in
  let method_str = Option.value method_ ~default:"auto" in
  let delay_ms = Option.value delay ~default:500.0 in
  let delay_s = delay_ms /. 1000.0 in
  let submit_delay = effective_submit_delay client_str (Some delay_s) in
  let payload = render_payload full_text event_str sender_str alias_str raw in
  if dry_run then (
    let action = "would inject" in
    let method_desc = if method_str <> "auto" then Printf.sprintf " via %s" method_str else "" in
    let text_preview = if String.length full_text > 50 then String.sub full_text 0 50 ^ "..." else full_text in
    print_endline (Printf.sprintf "%s into %s%s: %s" action client_str method_desc text_preview);
    exit 0
  );
  (* Resolve target *)
  let target = resolve_inject_target claude_session pid terminal_pid pts in
  let method_used = ref None in
  (* Try PTY injection if method is pty or auto *)
  if !method_used = None && (method_str = "pty" || method_str = "auto") then
    if target.terminal_pid > 0 then (
      let ok = inject_via_pty target.terminal_pid target.pts_num payload ~submit_delay in
      if ok then method_used := Some "pty"
    );
  (* Try history injection if method is history or auto *)
  if !method_used = None && (method_str = "history" || method_str = "auto") then
    match target.session_id with
    | None ->
        Printf.eprintf "error: history injection requires --claude-session (session ID unknown for --pid/--terminal-pid)\n%!";
        exit 1
    | Some session_id ->
        match inject_via_history session_id target.cwd full_text with
        | None ->
            Printf.eprintf "error: history injection failed (transcript not found)\n%!";
            exit 1
        | Some _path ->
            method_used := Some "history"
  ;
  (match !method_used with
   | None ->
       Printf.eprintf "error: injection failed (tried pty and history)\n%!";
       exit 1
   | Some m ->
       if json then (
         let result = `Assoc [
           ("ok", `Bool true);
           ("client", `String client_str);
           ("method", `String m);
           ("terminal_pid", `Int target.terminal_pid);
           ("pts", `String target.pts_num);
           ("payload", `String (String.sub payload 0 (min (String.length payload) 200)));
           ("dry_run", `Bool false);
           ("submit_delay", `Float submit_delay);
         ] in
         print_endline (Yojson.Safe.pretty_to_string result)
       ) else (
         let text_preview = if String.length full_text > 50 then String.sub full_text 0 50 ^ "..." else full_text in
         print_endline (Printf.sprintf "injected into %s via %s: %s" client_str m text_preview)
       )
  );
  exit 0

let inject = Cmdliner.Cmd.v (Cmdliner.Cmd.info "inject" ~doc:"Inject messages or keycodes into a live session.") inject_cmd

(* --- subcommand: screen ---------------------------------------------------- *)

(** Resolve a pts number from a Claude session identifier using pure OCaml.
    Returns (terminal_pid, pts_num). For SSH sessions where terminal_pid is empty, returns (0, pts_num).
    Uses session JSON files to find the PID, then reads /proc/<pid>/fd/0 for the current pts. *)
let resolve_claude_session (session : string) : (int * string) =
  match find_session_by_identifier session with
  | None ->
      Printf.eprintf "error: session %S not found\n%!" session;
      exit 1
  | Some (session_id, _cwd, proc_pid) ->
      let pts_num =
        match resolve_pts_from_pid proc_pid with
        | Some p -> p
        | None ->
            (* Session found but process has no pts — try using session_id directly as PID hint *)
            (match int_of_string_opt session with
             | Some p when p > 0 ->
                 (match resolve_pts_from_pid p with
                  | Some p -> p
                  | None -> "0")
             | _ -> "0")
      in
      let tp, has_tp =
        match find_terminal_owner proc_pid pts_num with
        | Some t -> (t, true)
        | None -> (0, false)
      in
      (if tp = 0 && has_tp then () else ());  (* suppress unused warning *)
      (tp, pts_num)

(** Resolve (terminal_pid, pts_num) from a raw process PID.
    We read the pts from /proc/<pid>/fd/{0,1,2} then optionally find the terminal owner
    by walking the parent chain and scanning fdinfos.
    Returns (0, pts_num) if terminal owner cannot be found (e.g., SSH sessions). *)
let resolve_pid_target (pid : int) : (int * string) =
  match resolve_pts_from_pid pid with
  | None ->
      Printf.eprintf "error: pid %d has no /dev/pts on fds 0/1/2\n%!" pid;
      exit 1
  | Some pts_num -> (
      match find_terminal_owner pid pts_num with
      | None ->
          (* Terminal owner not found (e.g., SSH session). Still return pts for screen reading. *)
          (0, pts_num)
      | Some tp -> (tp, pts_num)
    )

let screen_cmd =
  let claude_session =
    Cmdliner.Arg.(value & opt (some string) None & info [ "claude-session" ] ~docv:"NAME_OR_ID" ~doc:"Resolve target by Claude session name, session ID, or PID.")
  in
  let pid =
    Cmdliner.Arg.(value & opt (some int) None & info [ "pid" ] ~docv:"PID" ~doc:"Target any process by PID.")
  in
  let terminal_pid =
    Cmdliner.Arg.(value & opt (some int) None & info [ "terminal-pid" ] ~docv:"PID" ~doc:"Terminal emulator PID.")
  in
  let pts =
    Cmdliner.Arg.(value & opt (some string) None & info [ "pts" ] ~docv:"N" ~doc:"PTY slave number (required with --terminal-pid).")
  in
  let+ claude_session = claude_session
  and+ pid = pid
  and+ terminal_pid = terminal_pid
  and+ pts = pts in
  let (_ : int), pts_num =
    match claude_session, pid, (terminal_pid, pts) with
    | Some session, None, (None, None) ->
        (* Resolve via claude_list_sessions.py *)
        resolve_claude_session session
    | None, Some p, (None, None) ->
        (* Resolve via /proc walk *)
        resolve_pid_target p
    | _, _, (Some _tp, Some pn) ->
        (* Explicit coordinates — pts provided directly, terminal_pid not used *)
        (0, pn)
    | _ ->
        Printf.eprintf "error: must specify one of --claude-session, --pid, or --terminal-pid + --pts\n%!";
        exit 1
  in
  let pts_dev = Printf.sprintf "/dev/pts/%s" pts_num in
  if not (Sys.file_exists pts_dev) then (
    Printf.eprintf "error: %s does not exist\n%!" pts_dev;
    exit 1);
  (* Read from the PTY slave — for terminal emulators this gives scrollback buffer.
     For SSH sessions this may block, so we use dd with a short read limit. *)
  let ic = Unix.open_process_in (Printf.sprintf "timeout 1 dd if=%s bs=4096 count=256 2>/dev/null" pts_dev) in
  Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic)) (fun () ->
    let buf = Buffer.create 16384 in
    (try while true do
         let chunk = Bytes.create 4096 in
         let n = input ic chunk 0 4096 in
         if n > 0 then Buffer.add_subbytes buf chunk 0 n else raise End_of_file
       done with End_of_file -> ());
    let content = Buffer.contents buf in
    print_string content;
    if String.length content > 0 && content.[String.length content - 1] <> '\n' then print_newline ()
  )

let screen = Cmdliner.Cmd.v (Cmdliner.Cmd.info "screen" ~doc:"Capture PTY screen content as text.") screen_cmd
