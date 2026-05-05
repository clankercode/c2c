(* c2c_start — OCaml port of the managed-instance lifecycle. *)

let ( // ) = Filename.concat

module StringSet = Set.Make(String)

(** [fds_to_close ~preserve] is a pure function that returns the list of
    file descriptors that [close_unlisted_fds] would close — i.e. all fds in
    /proc/self/fd except those in [preserve] and stdin/stdout/stderr.
    This is testable without closing anything.

    Structural errors (permission denied accessing /proc/self/fd, malformed fd
    names) are propagated — only EINTR is retried. A bare [] on error would
    silently disable all fd closing, creating the exact leak we're trying to fix. *)
let fds_to_close ~(preserve : Unix.file_descr list) : Unix.file_descr list =
  let stdio = [Unix.stdin; Unix.stdout; Unix.stderr] in
  let rec with_eintr thunk =
    match thunk () with
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> with_eintr thunk
    | result -> result
  in
  try
    let fd_dir = with_eintr (fun () -> Unix.opendir "/proc/self/fd") in
    Fun.protect ~finally:(fun () -> try Unix.closedir fd_dir with _ -> ())
      (fun () ->
        let rec loop fds =
          match with_eintr (fun () -> Unix.readdir fd_dir) with
          | exception End_of_file -> List.rev fds
          | "." | ".." -> loop fds
          | name ->
              let fd = int_of_string name in
              if List.mem fd (List.map Obj.magic stdio) then loop fds
              else if List.mem fd (List.map Obj.magic preserve) then loop fds
              else loop ((Obj.magic fd) :: fds)
        in
        loop [])
  with Unix.Unix_error (e, _, _) as ex ->
    if e = Unix.EINTR then []
    else raise ex

let close_unlisted_fds ~(preserve : Unix.file_descr list) =
  List.iter (fun fd -> try Unix.close fd with _ -> ()) (fds_to_close ~preserve)

let likes_shell_substitution (s : string) : bool =
  let len = String.length s in
  let is_escaped i =
    let rec count j =
      if j < 0 then 0
      else if s.[j] = '\\' then 1 + count (j - 1)
      else 0
    in
    let n = count (i - 1) in n > 0 && n mod 2 = 1
  in
  let rec scan i =
    if i >= len then false
    else
      match s.[i] with
      | '$' when i + 1 < len && not (is_escaped i) ->
          let next = s.[i + 1] in
          if next = '$' then scan (i + 2)
          else if next = '\\' then scan (i + 2)
          else if next = '(' then
            let depth = ref 1 in
            let j = ref (i + 2) in
            while !j < len && !depth > 0 do
              (match s.[!j] with
               | '(' -> incr depth
               | ')' -> decr depth
               | _ -> ());
              incr j
            done;
            if !depth = 0 then true else scan (i + 1)
          else scan (i + 1)
      | '`' when not (is_escaped i) ->
          let rec find_close j escaped =
            if j >= len then false
            else if escaped then find_close (j + 1) false
            else
              match s.[j] with
              | '\\' -> find_close (j + 1) true
              | '`' -> true
              | _ -> find_close (j + 1) false
          in
          if find_close (i + 1) false then true else scan (i + 1)
      | _ -> scan (i + 1)
  in
  scan 0

(* Terminal title — OSC-0 / tmux pane title.
   Respects NO_COLOR and TERM=dumb. Title format: "<glyph> <alias> (<client>)"
   Called from run_outer_loop so operators can scan tmux panes at a glance. *)
let set_terminal_title ~(alias : string) ~(client : string) ~(glyph : string) =
  if Sys.getenv_opt "NO_COLOR" <> None then () else
  (match Sys.getenv_opt "TERM" with
   | Some "dumb" | None -> ()
   | _ ->
     let title = Printf.sprintf "%s %s (%s)" glyph alias client in
     let osc = Printf.sprintf "\027]0;%s\027\\" title in
     let tmux = Printf.sprintf "\027]2;%s\027\\" title in
     output_string stdout osc;
     flush stdout;
     (match Sys.getenv_opt "TMUX" with
      | Some _ ->
          output_string stdout tmux;
          flush stdout
      | None -> ()))

(* Title ticker — background thread that periodically recomputes the status glyph
   based on broker state (inbox depth, DND) and updates the terminal title.
   Respects NO_COLOR and TERM=dumb. *)
let compute_status_glyph ~(broker_root : string) ~(session_id : string) : string =
  if Sys.getenv_opt "NO_COLOR" <> None then "●" else
  (match Sys.getenv_opt "TERM" with
   | Some "dumb" | None -> "●"
   | _ ->
     let broker = C2c_mcp.Broker.create ~root:broker_root in
     let has_mail = match C2c_mcp.Broker.read_inbox broker ~session_id with
       | [] -> false | _ -> true
     in
     let is_dnd = C2c_mcp.Broker.is_dnd broker ~session_id in
     let glyph = (if has_mail then "✉" else "") ^ (if is_dnd then "⏸" else "") in
     if glyph = "" then "●" else glyph)

let start_title_ticker ~(broker_root : string) ~(session_id : string)
    ~(alias : string) ~(client : string) ~(poll_interval_s : float) : unit =
  ignore (Thread.create (fun () ->
    let rec loop () =
      Unix.sleepf poll_interval_s;
      let glyph = compute_status_glyph ~broker_root ~session_id in
      set_terminal_title ~alias ~client ~glyph;
      loop ()
    in
    loop ()) ())

type heartbeat_schedule =
  | Interval of float
  | Aligned_interval of { interval_s : float; offset_s : float }

type managed_heartbeat = {
  heartbeat_name : string;
  schedule : heartbeat_schedule;
  interval_s : float;
  message : string;
  command : string option;
  command_timeout_s : float;
  clients : string list;
  role_classes : string list;
  enabled : bool;
  idle_only : bool;
  (** When true (default), the heartbeat fires only when the target agent
      appears idle — i.e. its broker registration's [last_activity_ts] is
      older than [idle_threshold_s] (or absent). This avoids waking an
      already-active agent mid-thought. Set false to restore the
      always-fire-on-tick behavior. *)
  idle_threshold_s : float;
  (** Activity-age cutoff for idle-only mode. Defaults to [interval_s]:
      if the agent has touched the broker within the last interval,
      they're considered active and the heartbeat is skipped. *)
}

let default_managed_heartbeat_content =
  "Session heartbeat. Poll your C2C inbox and handle any messages. \
If you have exhausted all work, ask coordinator1 (or swarm-lounge) for more."

(* Push-aware variant for clients that already receive inbound messages
   via channel notifications (no manual poll needed). The "wake / pick
   up next slice" framing is preserved; only the poll instruction is
   dropped. *)
let push_aware_heartbeat_content =
  "Session heartbeat — pick up the next slice / advance the goal. \
   (Messages arrive via channel notifications; no manual poll_inbox needed.) \
   If you have exhausted all work, ask coordinator1 (or swarm-lounge) for more."

let codex_heartbeat_interval_s = 240.0
let codex_heartbeat_content = default_managed_heartbeat_content

let default_heartbeat_clients =
  [ "claude"; "codex"; "opencode"; "kimi"; "crush" ]

let builtin_managed_heartbeat =
  { heartbeat_name = "default"
  ; schedule = Interval codex_heartbeat_interval_s
  ; interval_s = codex_heartbeat_interval_s
  ; message = default_managed_heartbeat_content
  ; command = None
  ; command_timeout_s = 30.0
  ; clients = default_heartbeat_clients
  ; role_classes = []
  ; enabled = true
  ; idle_only = true
  ; idle_threshold_s = codex_heartbeat_interval_s
  }

let codex_heartbeat_enabled ~(client : string) : bool =
  client = "codex"

let should_start_codex_heartbeat ~(client : string) ~(deliver_started : bool) :
    bool =
  codex_heartbeat_enabled ~client && deliver_started

let parse_bool_like (s : string) : bool option =
  match String.lowercase_ascii (String.trim s) with
  | "true" | "1" | "yes" | "on" -> Some true
  | "false" | "0" | "no" | "off" -> Some false
  | _ -> None

let strip_quotes (s : string) : string =
  let s = String.trim s in
  if String.length s >= 2
     && ((s.[0] = '"' && s.[String.length s - 1] = '"')
         || (s.[0] = '\'' && s.[String.length s - 1] = '\'')) then
    String.sub s 1 (String.length s - 2)
  else s

let parse_string_list_literal (s : string) : string list =
  let s = String.trim s in
  if String.length s >= 2 && s.[0] = '[' && s.[String.length s - 1] = ']' then
    let inner = String.sub s 1 (String.length s - 2) in
    String.split_on_char ',' inner
    |> List.map (fun item -> strip_quotes (String.trim item))
    |> List.filter (fun item -> item <> "")
  else
    let v = strip_quotes s in
    if v = "" then [] else [ v ]

let parse_heartbeat_duration_s (raw : string) : (float, string) result =
  let s = String.trim raw |> strip_quotes in
  if s = "" then Error "heartbeat duration is empty"
  else
    let len = String.length s in
    let unit_char = s.[len - 1] in
    let multiplier, number_part =
      match unit_char with
      | 's' | 'S' -> (1.0, String.sub s 0 (len - 1))
      | 'm' | 'M' -> (60.0, String.sub s 0 (len - 1))
      | 'h' | 'H' -> (3600.0, String.sub s 0 (len - 1))
      | _ -> (1.0, s)
    in
    try
      let value = float_of_string (String.trim number_part) *. multiplier in
      if value <= 0.0 then Error ("heartbeat duration must be positive: " ^ raw)
      else Ok value
    with Failure _ ->
      Error ("invalid heartbeat duration: " ^ raw)

let parse_heartbeat_schedule (raw : string) : (heartbeat_schedule, string) result =
  let s = String.trim raw |> strip_quotes in
  if s = "" then Error "heartbeat schedule is empty"
  else if s.[0] <> '@' then
    match parse_heartbeat_duration_s s with
    | Ok n -> Ok (Interval n)
    | Error _ as e -> e
  else
    let body = String.sub s 1 (String.length s - 1) in
    let interval_part, offset_part =
      match String.index_opt body '+' with
      | None -> (body, "0s")
      | Some idx ->
          ( String.sub body 0 idx
          , String.sub body (idx + 1) (String.length body - idx - 1) )
    in
    match parse_heartbeat_duration_s interval_part,
          parse_heartbeat_duration_s offset_part with
    | Ok interval_s, Ok offset_s ->
        Ok (Aligned_interval { interval_s; offset_s })
    | Error e, _ | _, Error e -> Error e

let interval_s_of_schedule = function
  | Interval n -> n
  | Aligned_interval { interval_s; _ } -> interval_s

let next_heartbeat_delay_s ~(now : float) (hb : managed_heartbeat) : float =
  match hb.schedule with
  | Interval n -> n
  | Aligned_interval { interval_s; offset_s } ->
      let shifted = now -. offset_s in
      let slots = floor (shifted /. interval_s) +. 1.0 in
      let next = (slots *. interval_s) +. offset_s in
      max 0.001 (next -. now)

let enqueue_heartbeat ~broker_root ~alias ~content =
  C2c_schedule_fire.enqueue_heartbeat ~broker_root ~alias ~content

let agent_is_idle ~now ~idle_threshold_s ~last_activity_ts =
  C2c_schedule_fire.agent_is_idle ~now ~idle_threshold_s ~last_activity_ts

let last_activity_ts_for_alias ~broker_root ~alias =
  C2c_schedule_fire.last_activity_ts_for_alias ~broker_root ~alias

let should_fire_heartbeat ~(broker_root : string) ~(alias : string)
    (hb : managed_heartbeat) : bool =
  if not hb.idle_only then true
  else
    let now = Unix.gettimeofday () in
    let last_activity_ts =
      C2c_schedule_fire.last_activity_ts_for_alias ~broker_root ~alias
    in
    C2c_schedule_fire.agent_is_idle ~now ~idle_threshold_s:hb.idle_threshold_s
      ~last_activity_ts

let enqueue_codex_heartbeat ~(broker_root : string) ~(alias : string) : unit =
  enqueue_heartbeat ~broker_root ~alias ~content:codex_heartbeat_content

let command_allowlist =
  [ [ "c2c"; "quota" ]
  ; [ "c2c"; "history" ]
  ; [ "c2c"; "list" ]
  ; [ "c2c"; "doctor" ]
  ; [ "c2c"; "instances" ]
  ]

let split_command_words (cmd : string) : string list =
  String.split_on_char ' ' (String.trim cmd)
  |> List.map String.trim
  |> List.filter ((<>) "")

let heartbeat_command_allowed (cmd : string) : bool =
  let words = split_command_words cmd in
  List.exists (fun allowed -> words = allowed) command_allowlist

let run_allowed_heartbeat_command ~(timeout_s : float) (cmd : string) : string =
  if not (heartbeat_command_allowed cmd) then
    Printf.sprintf "[skipped disallowed heartbeat command: %s]" cmd
  else
    let timeout_s = max 1.0 timeout_s |> ceil |> int_of_float in
    let cmd =
      Printf.sprintf "timeout %ds %s" timeout_s cmd
    in
    let ic = Unix.open_process_in cmd in
    try
      let buf = Buffer.create 256 in
      (try
         while true do
           Buffer.add_string buf (input_line ic);
           Buffer.add_char buf '\n'
         done
       with End_of_file -> ());
      let status = Unix.close_process_in ic in
      let output = String.trim (Buffer.contents buf) in
      match status with
      | Unix.WEXITED 0 -> output
      | Unix.WEXITED n ->
          Printf.sprintf "[heartbeat command exited %d]\n%s" n output
      | Unix.WSIGNALED n ->
          Printf.sprintf "[heartbeat command signaled %d]" n
      | Unix.WSTOPPED n ->
          Printf.sprintf "[heartbeat command stopped %d]" n
    with e ->
      (try ignore (Unix.close_process_in ic) with _ -> ());
      Printf.sprintf "[heartbeat command failed: %s]" (Printexc.to_string e)

(* Look up the [automated_delivery] flag for an alias from the broker
   registry. Returns [None] when the alias is unregistered or the
   registration predates this field — consumers treat that case as
   "not push-capable" (conservative default). *)
let automated_delivery_for_alias ~(broker_root : string) ~(alias : string)
    : bool option =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  match C2c_mcp.Broker.list_registrations broker
        |> List.find_opt (fun (r : C2c_mcp.registration) -> r.alias = alias) with
  | Some reg -> reg.automated_delivery
  | None -> None

(* Push-aware swap of the heartbeat body. The swap fires only when:
   (1) the configured [message] equals the legacy default, and
   (2) the target alias is push-capable (automated_delivery = Some true).
   Operator-authored custom messages pass through verbatim. *)
let heartbeat_body_for_alias ~(broker_root : string) ~(alias : string)
    ~(message : string) : string =
  if message <> default_managed_heartbeat_content then message
  else
    match automated_delivery_for_alias ~broker_root ~alias with
    | Some true -> push_aware_heartbeat_content
    | _ -> message

let render_heartbeat_content ?(broker_root : string option)
    ?(alias : string option) (hb : managed_heartbeat) : string =
  let body =
    match broker_root, alias with
    | Some root, Some a ->
        heartbeat_body_for_alias ~broker_root:root ~alias:a ~message:hb.message
    | _ -> hb.message
  in
  match hb.command with
  | None -> body
  | Some cmd ->
      let output =
        run_allowed_heartbeat_command ~timeout_s:hb.command_timeout_s cmd
      in
      if String.trim output = "" then body
      else
        Printf.sprintf "%s\n\n[heartbeat:%s command output]\n%s"
          body hb.heartbeat_name output

let start_managed_heartbeat ~(broker_root : string) ~(alias : string)
    (hb : managed_heartbeat) : unit =
  ignore (Thread.create (fun () ->
    let rec loop first =
      let sleep_s =
        if first then next_heartbeat_delay_s ~now:(Unix.gettimeofday ()) hb
        else hb.interval_s
      in
      Unix.sleepf sleep_s;
      (try
         if should_fire_heartbeat ~broker_root ~alias hb then
           enqueue_heartbeat ~broker_root ~alias
             ~content:(render_heartbeat_content ~broker_root ~alias hb)
         else
           (* Agent has been active within idle_threshold — skip this tick to
              avoid waking them mid-thought. The next interval re-checks. *)
           ()
       with _ -> ());
      loop false
    in
    loop true) ())

(* Stoppable variant — returns an [Atomic.t bool] stop flag.  Setting it to
   [true] causes the thread to exit within ~5s (it checks between sleep
   chunks).  Used by the schedule-watcher thread for hot-reload. *)
let start_managed_heartbeat_stoppable ~(broker_root : string) ~(alias : string)
    (hb : managed_heartbeat) : bool Atomic.t =
  let stop = Atomic.make false in
  ignore (Thread.create (fun () ->
    let rec loop first =
      if Atomic.get stop then ()
      else begin
        let sleep_s =
          if first then next_heartbeat_delay_s ~now:(Unix.gettimeofday ()) hb
          else hb.interval_s
        in
        (* Sleep in small chunks so stop flag is checked frequently *)
        let sleep_chunk = 5.0 in
        let remaining = ref sleep_s in
        while !remaining > 0.0 && not (Atomic.get stop) do
          let chunk = Float.min sleep_chunk !remaining in
          Unix.sleepf chunk;
          remaining := !remaining -. chunk
        done;
        if not (Atomic.get stop) then begin
          (try
             if should_fire_heartbeat ~broker_root ~alias hb then
               enqueue_heartbeat ~broker_root ~alias
                 ~content:(render_heartbeat_content ~broker_root ~alias hb)
           with _ -> ());
          loop false
        end
      end
    in
    loop true) ());
  stop

let start_codex_heartbeat ~(broker_root : string) ~(alias : string)
    ~(interval_s : float) : unit =
  start_managed_heartbeat ~broker_root ~alias
    { builtin_managed_heartbeat with
      heartbeat_name = "codex";
      schedule = Interval interval_s;
      interval_s;
      clients = [ "codex" ];
    }

(* setpgid(2) binding — OCaml 5.x's Unix module omits this call.
   Implementation in ocaml/cli/c2c_posix_stubs.c. *)
external setpgid : int -> int -> unit = "caml_c2c_setpgid"

(* tcsetpgrp(3) binding — errors suppressed inside the stub. After the
   child forks into its own pgid, we hand it the controlling terminal
   so it's the tty's foreground process group; otherwise TUIs like
   opencode detect background-pg and exit 109. *)
external tcsetpgrp : Unix.file_descr -> int -> unit = "caml_c2c_tcsetpgrp"
external getpgrp : unit -> int = "caml_c2c_getpgrp"

(* forkpty(3) binding — fork with PTY. Parent gets master_fd and child_pid;
   child gets slave as stdin/stdout/stderr. Used by the generic PTY client. *)
external forkpty_MasterChild : unit -> int * int = "caml_c2c_forkpty_MasterChild"

(* ---------------------------------------------------------------------------
 * Repo-level .c2c/config.toml reader
 * --------------------------------------------------------------------------- *)

let repo_config_path () =
  Filename.concat (Sys.getcwd ()) (".c2c" // "config.toml")

let repo_config_enable_channels () : bool =
  let path = repo_config_path () in
  if not (Sys.file_exists path) then false
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) @@ fun () ->
    let rec loop () =
      match try Some (input_line ic) with End_of_file -> None with
      | None -> false
      | Some line ->
        let trimmed = String.trim line in
        if trimmed = "" || String.length trimmed > 0 && trimmed.[0] = '#' then loop ()
        else if String.length trimmed >= 15 &&
                String.sub trimmed 0 15 = "enable_channels" &&
                (String.length trimmed = 15 ||
                 String.get trimmed 15 = ' ' ||
                 String.get trimmed 15 = '=') then
          let rest =
            let i = try String.index trimmed '=' with Not_found -> 15 in
            String.trim (String.sub trimmed (i + 1) (String.length trimmed - i - 1))
          in
          let v = if String.length rest >= 2 && rest.[0] = '"' && rest.[String.length rest - 1] = '"'
            then String.sub rest 1 (String.length rest - 2)
            else rest
          in
          v = "true" || v = "1" || v = "yes" || v = "on"
        else loop ()
    in
    loop ()

let repo_config_git_attribution () : bool =
  let path = repo_config_path () in
  if not (Sys.file_exists path) then true
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) @@ fun () ->
    let rec loop () =
      match try Some (input_line ic) with End_of_file -> None with
      | None -> true
      | Some line ->
        let trimmed = String.trim line in
        if trimmed = "" || String.length trimmed > 0 && trimmed.[0] = '#' then loop ()
        else if String.length trimmed >= 16 &&
                String.sub trimmed 0 16 = "git_attribution" &&
                (String.length trimmed = 16 ||
                 String.get trimmed 16 = ' ' ||
                 String.get trimmed 16 = '=') then
          let rest =
            let i = try String.index trimmed '=' with Not_found -> 16 in
            String.trim (String.sub trimmed (i + 1) (String.length trimmed - i - 1))
          in
          let v = if String.length rest >= 2 && rest.[0] = '"' && rest.[String.length rest - 1] = '"'
            then String.sub rest 1 (String.length rest - 2)
            else rest
          in
          v = "true" || v = "1" || v = "yes" || v = "on"
        else loop ()
    in
    loop ()

let repo_config_git_sign () : bool =
  let path = repo_config_path () in
  if not (Sys.file_exists path) then true
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) @@ fun () ->
    let rec loop () =
      match try Some (input_line ic) with End_of_file -> None with
      | None -> true
      | Some line ->
        let trimmed = String.trim line in
        if trimmed = "" || String.length trimmed > 0 && trimmed.[0] = '#' then loop ()
        else if String.length trimmed >= 8 &&
                String.sub trimmed 0 8 = "git_sign" &&
                (String.length trimmed = 8 ||
                 String.get trimmed 8 = ' ' ||
                 String.get trimmed 8 = '=') then
          let rest =
            let i = try String.index trimmed '=' with Not_found -> 8 in
            String.trim (String.sub trimmed (i + 1) (String.length trimmed - i - 1))
          in
          let v = if String.length rest >= 2 && rest.[0] = '"' && rest.[String.length rest - 1] = '"'
            then String.sub rest 1 (String.length rest - 2)
            else rest
          in
          v = "true" || v = "1" || v = "yes" || v = "on"
        else loop ()
    in
    loop ()

(** [repo_config_supervisor_strategy ()] reads the [supervisor_strategy] field
    from [~/.c2c/repo.json]. Returns the configured strategy string, or
    [None] if the field is absent or malformed.

    The field is a top-level string in repo.json:
      { "supervisor_strategy": "first-alive", ... }

    This is the read-side counterpart to the [supervisor_strategy] field written
    by [c2c init --supervisor-strategy]. Without this reader the field was
    dead state — configured but never consulted (#524). *)
let repo_config_supervisor_strategy () : string option =
  let repo_json =
    let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
    Filename.concat home (".c2c" // "repo.json")
  in
  if not (Sys.file_exists repo_json) then None
  else
    match Yojson.Safe.from_file repo_json with
    | `Assoc fields ->
        (match List.assoc_opt "supervisor_strategy" fields with
         | Some (`String s) when String.trim s <> "" -> Some (String.trim s)
         | _ -> None)
    | _ -> None

let read_toml_sections_with_prefix_from_path (path : string) (prefix : string) :
    (string * (string * string) list) list =
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) @@ fun () ->
    let current = ref None in
    let acc = ref [] in
    let add section k v =
      let existing = Option.value (List.assoc_opt section !acc) ~default:[] in
      acc := (section, (k, v) :: existing)
             :: List.remove_assoc section !acc
    in
    (try
       while true do
         let line = input_line ic in
         let t = String.trim line in
         if t = "" || (String.length t > 0 && t.[0] = '#') then ()
         else if String.length t > 2 && t.[0] = '['
                 && t.[String.length t - 1] = ']' then begin
           let section = String.sub t 1 (String.length t - 2) in
           current :=
             if section = prefix then Some "default"
             else
               let dotted = prefix ^ "." in
               if String.length section > String.length dotted
                  && String.sub section 0 (String.length dotted) = dotted then
                 Some (String.sub section (String.length dotted)
                         (String.length section - String.length dotted))
               else None
         end else
           match !current, String.index_opt t '=' with
           | Some section, Some eq ->
               let k = String.trim (String.sub t 0 eq) in
               let v =
                 String.sub t (eq + 1) (String.length t - eq - 1)
                 |> String.trim |> strip_quotes
               in
               if k <> "" then add section k v
           | _ -> ()
       done;
       assert false
     with End_of_file ->
       List.map (fun (section, entries) -> (section, List.rev entries))
         (List.rev !acc))

let read_toml_sections_with_prefix (prefix : string) :
    (string * (string * string) list) list =
  read_toml_sections_with_prefix_from_path (repo_config_path ()) prefix

(* --------------------------------------------------------------------------- *
 * [swarm] section (#341)
 *
 * Per-repo overrides for swarm-wide rendered strings. Today this is just
 * [restart_intro], the kickoff prompt template emitted into the agent's
 * transcript when [c2c start <client>] launches a fresh session. The
 * thunk pattern (function-of-unit) mirrors the planned #318 v3 helpers
 * (swarm_config_coordinator_alias / swarm_config_social_room) so all
 * three converge on the same lookup once #318 lands.
 * --------------------------------------------------------------------------- *)

(* Default restart/kickoff intro template. Placeholders {name}, {alias},
   {role} are substituted at render time by [default_kickoff_prompt] in
   cli/c2c.ml. Override via [swarm] restart_intro in .c2c/config.toml. *)
let builtin_swarm_restart_intro : string =
  "You have been started as a c2c swarm agent.\n\
   Always reply to fellow agents using c2c_send (MCP tool `mcp__c2c__send`, or `c2c send` from the CLI) — plain assistant text is invisible to peers.\n\
   Instance: {name}  Alias: {alias}{role}\n\
   Getting started:\n\
   1. Poll your inbox:  use the MCP poll_inbox tool (or: c2c poll-inbox)\n\
   2. See active peers: c2c list\n\
   3. Post in the lounge: send_room swarm-lounge with a hello message\n\
   4. Read CLAUDE.md for the mission brief and open tasks\n\n\
   The swarm coordinates via c2c instant messaging. You are now part of it.\n\
   Reminder: replies to peers must go through c2c_send (`mcp__c2c__send` / `c2c send`) — they don't see your assistant output."

(* Decode common backslash escapes in a TOML basic-string value
   (newline, tab, backslash, quote). Lets operators encode multi-line
   restart_intro overrides on a single TOML line. Conservative: unknown
   escapes pass through unchanged. *)
let decode_toml_basic_escapes (s : string) : string =
  let buf = Buffer.create (String.length s) in
  let len = String.length s in
  let i = ref 0 in
  while !i < len do
    let c = s.[!i] in
    if c = '\\' && !i + 1 < len then begin
      (match s.[!i + 1] with
       | 'n' -> Buffer.add_char buf '\n'
       | 't' -> Buffer.add_char buf '\t'
       | 'r' -> Buffer.add_char buf '\r'
       | '\\' -> Buffer.add_char buf '\\'
       | '"' -> Buffer.add_char buf '"'
       | '\'' -> Buffer.add_char buf '\''
       | other -> Buffer.add_char buf '\\'; Buffer.add_char buf other);
      i := !i + 2
    end else begin
      Buffer.add_char buf c;
      incr i
    end
  done;
  Buffer.contents buf

(* Read [swarm] restart_intro from .c2c/config.toml (#341). Returns the
   user override (with \n etc decoded) or [builtin_swarm_restart_intro]
   when the section/key is absent. *)
let swarm_config_restart_intro () : string =
  let sections = read_toml_sections_with_prefix "swarm" in
  match List.assoc_opt "default" sections with
  | None -> builtin_swarm_restart_intro
  | Some entries ->
      (match List.assoc_opt "restart_intro" entries with
       | None -> builtin_swarm_restart_intro
       | Some "" -> builtin_swarm_restart_intro
       | Some v -> decode_toml_basic_escapes v)

(* --------------------------------------------------------------------------- *
 * Coordinator-backup fallthrough config (slice/coord-backup-fallthrough)
 *
 * Per-DM redundancy: when a permission DM's primary recipient doesn't
 * ack within an idle window, the broker scheduler forwards to the next
 * backup in [coord_chain]. Full design lives in
 * .collab/design/2026-04-29-coord-backup-fallthrough-stanza.md. The
 * config thunks below land in this slice; the broker scheduler that
 * consumes them lands in the follow-up implementation slice.
 *
 * All three keys live under [swarm]. Defaults are conservative:
 *   coord_chain                       -> [] (feature disabled until
 *                                            an operator opts in)
 *   coord_fallthrough_idle_seconds    -> 120.0
 *   coord_fallthrough_broadcast_room  -> "swarm-lounge"
 * --------------------------------------------------------------------------- *)

let default_coord_fallthrough_idle_seconds : float = 120.0

let default_coord_fallthrough_broadcast_room : string = "swarm-lounge"

(* Read [swarm] coord_chain from .c2c/config.toml. Returns the configured
   list (parsed as a TOML inline string-array) or the empty list when the
   section/key is absent. Empty list means "no fallthrough chain
   configured" — the scheduler treats it as feature-off for this repo. *)
let swarm_config_coord_chain () : string list =
  let sections = read_toml_sections_with_prefix "swarm" in
  match List.assoc_opt "default" sections with
  | None -> []
  | Some entries ->
      (match List.assoc_opt "coord_chain" entries with
       | None -> []
       | Some "" -> []
       | Some v -> parse_string_list_literal v)

(* Read [swarm] coord_fallthrough_idle_seconds. Float seconds the
   primary (and each subsequent backup) has to ack before the next
   backup gets DM'd. Defaults to 120.0. Unparseable values fall back to
   the default rather than raising — config errors should not crash
   the broker. *)
let swarm_config_coord_fallthrough_idle_seconds () : float =
  let sections = read_toml_sections_with_prefix "swarm" in
  match List.assoc_opt "default" sections with
  | None -> default_coord_fallthrough_idle_seconds
  | Some entries ->
      (match List.assoc_opt "coord_fallthrough_idle_seconds" entries with
       | None -> default_coord_fallthrough_idle_seconds
       | Some "" -> default_coord_fallthrough_idle_seconds
       | Some v ->
           (try float_of_string (String.trim v)
            with _ -> default_coord_fallthrough_idle_seconds))

(* Read [swarm] coord_fallthrough_broadcast_room. Room ID for the final
   "all coords missing" broadcast tier. Empty string disables the
   broadcast tier (TTL alone handles end-of-life). Defaults to
   "swarm-lounge". *)
let swarm_config_coord_fallthrough_broadcast_room () : string =
  let sections = read_toml_sections_with_prefix "swarm" in
  match List.assoc_opt "default" sections with
  | None -> default_coord_fallthrough_broadcast_room
  | Some entries ->
      (match List.assoc_opt "coord_fallthrough_broadcast_room" entries with
       | None -> default_coord_fallthrough_broadcast_room
       | Some v -> String.trim v)

let assoc_bool key entries default =
  match List.assoc_opt key entries with
  | None -> default
  | Some v -> Option.value (parse_bool_like v) ~default

let assoc_duration key entries default =
  match List.assoc_opt key entries with
  | None -> default
  | Some v ->
      (match parse_heartbeat_duration_s v with
       | Ok n -> n
       | Error _ -> default)

let assoc_list key entries default =
  match List.assoc_opt key entries with
  | None -> default
  | Some v -> parse_string_list_literal v

let heartbeat_from_entries ~(name : string) (base : managed_heartbeat)
    (entries : (string * string) list) : managed_heartbeat =
  let schedule =
    match List.assoc_opt "schedule" entries with
    | Some raw ->
        (match parse_heartbeat_schedule raw with
         | Ok schedule -> schedule
         | Error _ -> base.schedule)
    | None ->
        (match List.assoc_opt "interval" entries with
         | Some raw ->
             (match parse_heartbeat_duration_s raw with
              | Ok interval_s -> Interval interval_s
              | Error _ -> base.schedule)
         | None -> base.schedule)
  in
  { heartbeat_name = name
  ; schedule
  ; interval_s = interval_s_of_schedule schedule
  ; message =
      Option.value (List.assoc_opt "message" entries) ~default:base.message
  ; command =
      (match List.assoc_opt "command" entries with
       | Some "" -> None
       | Some v -> Some v
       | None -> base.command)
  ; command_timeout_s =
      assoc_duration "command_timeout" entries base.command_timeout_s
  ; clients = assoc_list "clients" entries base.clients
  ; role_classes = assoc_list "role_classes" entries base.role_classes
  ; enabled = assoc_bool "enabled" entries base.enabled
  ; idle_only = assoc_bool "idle_only" entries base.idle_only
  ; idle_threshold_s =
      assoc_duration "idle_threshold" entries base.idle_threshold_s
  }

let repo_config_managed_heartbeats () : managed_heartbeat list =
  read_toml_sections_with_prefix "heartbeat"
  |> List.map (fun (name, entries) ->
       heartbeat_from_entries ~name
         { builtin_managed_heartbeat with heartbeat_name = name }
         entries)

let managed_heartbeats_from_toml_path (path : string) : managed_heartbeat list =
  read_toml_sections_with_prefix_from_path path "heartbeat"
  |> List.map (fun (name, entries) ->
       heartbeat_from_entries ~name
         { builtin_managed_heartbeat with heartbeat_name = name }
         entries)

let managed_heartbeat_of_schedule_entry (e : C2c_mcp.schedule_entry) : managed_heartbeat =
  let schedule =
    if e.s_align <> "" then
      match parse_heartbeat_schedule e.s_align with
      | Ok s -> s
      | Error _ -> Interval e.s_interval_s
    else Interval e.s_interval_s
  in
  { heartbeat_name = e.s_name
  ; schedule
  ; interval_s = e.s_interval_s
  ; message = e.s_message
  ; command = None
  ; command_timeout_s = 30.0
  ; clients = []  (* empty = all clients except codex-headless, per should_heartbeat_apply_to_client *)
  ; role_classes = []
  ; enabled = e.s_enabled
  ; idle_only = e.s_only_when_idle
  ; idle_threshold_s = e.s_idle_threshold_s
  }


let heartbeat_name_from_role_key ~(prefix : string) (key : string) :
    (string * string) option =
  let dotted = prefix ^ "." in
  if String.length key <= String.length dotted
     || String.sub key 0 (String.length dotted) <> dotted then
    None
  else
    let rest = String.sub key (String.length dotted)
        (String.length key - String.length dotted) in
    match String.index_opt rest '.' with
    | None -> None
    | Some dot ->
        let name = String.sub rest 0 dot in
        let field = String.sub rest (dot + 1) (String.length rest - dot - 1) in
        Some (name, field)

let role_named_heartbeat_entries (role : C2c_role.t) :
    (string * (string * string) list) list =
  let acc = ref [] in
  let add name field value =
    let existing = Option.value (List.assoc_opt name !acc) ~default:[] in
    acc := (name, (field, value) :: existing) :: List.remove_assoc name !acc
  in
  List.iter
    (fun (key, value) ->
      match heartbeat_name_from_role_key ~prefix:"c2c.heartbeats" key with
      | Some (name, field) -> add name field value
      | None -> ())
    role.C2c_role.c2c_heartbeats;
  List.map (fun (name, entries) -> (name, List.rev entries)) (List.rev !acc)

let merge_heartbeats (specs : managed_heartbeat list) :
    managed_heartbeat list =
  let acc = ref [] in
  List.iter
    (fun hb ->
      acc := (hb.heartbeat_name, hb)
             :: List.remove_assoc hb.heartbeat_name !acc)
    specs;
  List.rev_map snd !acc

let normalized_role_default_entries (role : C2c_role.t) =
  List.map
    (fun (key, value) ->
      let prefix = "c2c.heartbeat." in
      if String.length key > String.length prefix
         && String.sub key 0 (String.length prefix) = prefix then
        (String.sub key (String.length prefix)
           (String.length key - String.length prefix), value)
      else (key, value))
    role.C2c_role.c2c_heartbeat

let should_heartbeat_apply_to_client ~(client : string)
    ~(deliver_started : bool) (hb : managed_heartbeat) : bool =
  let client_allowed =
    if hb.clients = [] then
      client <> "codex-headless"
    else
      List.mem client hb.clients
  in
  hb.enabled
  && client_allowed
  && (client <> "codex" || deliver_started)

let should_heartbeat_apply_to_role ~(role : C2c_role.t option)
    (hb : managed_heartbeat) : bool =
  match hb.role_classes with
  | [] -> true
  | classes ->
      (match role with
       | Some r ->
           (match r.C2c_role.role_class with
            | Some rc -> List.mem rc classes
            | None -> false)
       | None -> false)

let resolve_managed_heartbeats ~(client : string) ~(deliver_started : bool)
    ~(role : C2c_role.t option)
    ?(per_agent_specs : managed_heartbeat list = [])
    (config_specs : managed_heartbeat list) :
    managed_heartbeat list =
  let merged_config = merge_heartbeats (builtin_managed_heartbeat :: config_specs) in
  let merged_role =
    match role with
    | None -> merged_config
    | Some r ->
        let role_default =
          if r.C2c_role.c2c_heartbeat = [] then []
          else
            let base =
              Option.value
                (List.find_opt
                   (fun hb -> hb.heartbeat_name = "default")
                   merged_config)
                ~default:builtin_managed_heartbeat
            in
            [ heartbeat_from_entries ~name:"default" base
                (normalized_role_default_entries r) ]
        in
        let role_named =
          role_named_heartbeat_entries r
          |> List.map (fun (name, entries) ->
               let base =
                 Option.value
                   (List.find_opt
                      (fun hb -> hb.heartbeat_name = name)
                      merged_config)
                   ~default:{ builtin_managed_heartbeat with
                              heartbeat_name = name }
               in
               heartbeat_from_entries ~name base entries)
        in
        merge_heartbeats (merged_config @ role_default @ role_named)
  in
  let merged = merge_heartbeats (merged_role @ per_agent_specs) in
  merged
  |> List.filter (should_heartbeat_apply_to_client ~client ~deliver_started)
  |> List.filter (should_heartbeat_apply_to_role ~role)

(* S5: role -> schedule persistence.
   Returns role-derived heartbeats separately so they can be:
   (a) written to .c2c/schedules/<alias>/ before the watcher starts
   (b) skipped in the direct start_managed_heartbeat path (watcher picks them up)

   Config/per-agent heartbeats are returned as the second element and are
   started directly (not persisted — they come from repo config or instance
   dirs, not role files). *)
let resolve_managed_heartbeats_and_persist_role
    ~(client : string) ~(deliver_started : bool)
    ~(role : C2c_role.t option)
    ?(per_agent_specs : managed_heartbeat list = [])
    (config_specs : managed_heartbeat list) :
    managed_heartbeat list * managed_heartbeat list =
  let merged_config = merge_heartbeats (builtin_managed_heartbeat :: config_specs) in
  let role_hbs =
    match role with
    | None -> []
    | Some r ->
        let role_default =
          if r.C2c_role.c2c_heartbeat = [] then []
          else
            let base =
              Option.value
                (List.find_opt
                   (fun hb -> hb.heartbeat_name = "default")
                   merged_config)
                ~default:builtin_managed_heartbeat
            in
            [ heartbeat_from_entries ~name:"default" base
                (normalized_role_default_entries r) ]
        in
        let role_named =
          role_named_heartbeat_entries r
          |> List.map (fun (name, entries) ->
               let base =
                 Option.value
                   (List.find_opt
                      (fun hb -> hb.heartbeat_name = name)
                      merged_config)
                   ~default:{ builtin_managed_heartbeat with
                               heartbeat_name = name }
               in
               heartbeat_from_entries ~name base entries)
        in
        role_default @ role_named
  in
  (* merged: full set including config + role entries, then per-agent overrides *)
  let merged =
    match role with
    | None ->
        merge_heartbeats (merged_config @ per_agent_specs)
    | Some _ ->
        merge_heartbeats (merged_config @ role_hbs @ per_agent_specs)
  in
  let filtered =
    merged
    |> List.filter (should_heartbeat_apply_to_client ~client ~deliver_started)
    |> List.filter (should_heartbeat_apply_to_role ~role)
  in
  (* Split: role_hbs that passed filters are persisted (watcher starts them);
     everything else (config + per-agent, and role entries that failed filters)
     is started directly. *)
  let role_filtered =
    role_hbs
    |> List.filter (should_heartbeat_apply_to_client ~client ~deliver_started)
    |> List.filter (should_heartbeat_apply_to_role ~role)
  in
  let non_role = List.filter (fun hb -> not (List.mem hb role_filtered)) filtered in
  non_role, role_filtered

(* S5: Convert a managed_heartbeat (role-derived) to a schedule_entry for TOML
   persistence. Inverse of managed_heartbeat_of_schedule_entry.

   Duration -> string conversion: the same durations used in heartbeat.toml
   (e.g. "4.1m", "1h", "30s"). We serialize as bare seconds when clean,
   otherwise as float+s suffix. *)
let format_duration_s (s : float) : string =
  if s = floor s && s >= 0. && s < 60. then
    string_of_int (int_of_float s)
  else
    Printf.sprintf "%gs" s

let schedule_entry_of_managed_heartbeat (hb : managed_heartbeat) : C2c_mcp.schedule_entry =
  let align =
    match hb.schedule with
    | Interval _ -> ""
    | Aligned_interval { interval_s; offset_s } ->
        if offset_s = 0. then
          Printf.sprintf "@%s" (format_duration_s interval_s)
        else
          Printf.sprintf "@%s+%s"
            (format_duration_s interval_s)
            (format_duration_s offset_s)
  in
  { C2c_mcp.
    s_name = hb.heartbeat_name
  ; s_interval_s = hb.interval_s
  ; s_align = align
  ; s_message = hb.message
  ; s_only_when_idle = hb.idle_only
  ; s_idle_threshold_s = hb.idle_threshold_s
  ; s_enabled = hb.enabled
  ; s_created_at = C2c_time.now_iso8601_utc ()
  ; s_updated_at = C2c_time.now_iso8601_utc ()
  }

(* S5: TOML escape (same as c2c_schedule_handlers.escape_toml_string). *)
let escape_toml_string s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c ->
    match c with
    | '\\' -> Buffer.add_string buf "\\\\"
    | '"'  -> Buffer.add_string buf "\\\""
    | c    -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

(* S5: Render a schedule_entry to TOML string (same format as c2c_schedule). *)
let render_schedule_entry (e : C2c_mcp.schedule_entry) : string =
  let buf = Buffer.create 256 in
  Buffer.add_string buf "[schedule]\n";
  Buffer.add_string buf (Printf.sprintf "name = \"%s\"\n" (escape_toml_string e.C2c_mcp.s_name));
  Buffer.add_string buf (Printf.sprintf "interval_s = %.6g\n" e.C2c_mcp.s_interval_s);
  Buffer.add_string buf (Printf.sprintf "align = \"%s\"\n" (escape_toml_string e.C2c_mcp.s_align));
  Buffer.add_string buf (Printf.sprintf "message = \"%s\"\n" (escape_toml_string e.C2c_mcp.s_message));
  Buffer.add_string buf (Printf.sprintf "only_when_idle = %b\n" e.C2c_mcp.s_only_when_idle);
  Buffer.add_string buf (Printf.sprintf "idle_threshold_s = %.6g\n" e.C2c_mcp.s_idle_threshold_s);
  Buffer.add_string buf (Printf.sprintf "enabled = %b\n" e.C2c_mcp.s_enabled);
  Buffer.add_string buf (Printf.sprintf "created_at = \"%s\"\n" (escape_toml_string e.C2c_mcp.s_created_at));
  Buffer.add_string buf (Printf.sprintf "updated_at = \"%s\"\n" (escape_toml_string e.C2c_mcp.s_updated_at));
  Buffer.contents buf

(* S5: Persist role-derived heartbeats to .c2c/schedules/<alias>/.
   Writes one .toml per heartbeat entry. Idempotent — each boot overwrites
   with fresh updated_at timestamps. The watcher thread (started after this)
   will pick up these files and start their timers. *)
let persist_role_heartbeats_to_schedule_dir ~(alias : string)
    (role_hbs : managed_heartbeat list) : unit =
  if role_hbs = [] then () else
  let dir = C2c_mcp.schedule_base_dir alias in
  (try C2c_io.mkdir_p dir with _ -> ());
  List.iter (fun hb ->
    let entry = schedule_entry_of_managed_heartbeat hb in
    let path = C2c_mcp.schedule_entry_path alias entry.C2c_mcp.s_name in
    let content = render_schedule_entry entry in
    try C2c_io.write_file path content with _ -> ()
  ) role_hbs

(* Schedule watcher thread — stat-polls the schedule directory every 10s,
   starting/stopping heartbeat threads as files are added, changed, or
   removed.  Handles the initial load on first iteration, so the startup
   path no longer needs to call [schedule_dir_managed_heartbeats] directly. *)
let start_schedule_watcher ~(broker_root : string) ~(alias : string)
    ~(client : string) ~(deliver_started : bool)
    ~(role : C2c_role.t option) : unit =
  ignore (Thread.create (fun () ->
    let poll_interval = 10.0 in
    (* fname -> (stop flag, mtime) *)
    let active : (string, bool Atomic.t * float) Hashtbl.t =
      Hashtbl.create 16
    in
    let try_start_schedule fname path mtime =
      match C2c_io.read_file_opt path with
      | "" -> ()
      | content ->
          let e = C2c_mcp.parse_schedule content in
          if e.s_name <> "" && e.s_enabled then begin
            let hb = managed_heartbeat_of_schedule_entry e in
            if should_heartbeat_apply_to_client ~client ~deliver_started hb
               && should_heartbeat_apply_to_role ~role hb then begin
              let stop =
                start_managed_heartbeat_stoppable ~broker_root ~alias hb
              in
              Hashtbl.replace active fname (stop, mtime)
            end
          end
    in
    let load_schedules () =
      let dir = C2c_mcp.schedule_base_dir alias in
      let current_files =
        try
          Array.to_list (Sys.readdir dir)
          |> List.filter (fun n ->
              String.length n > 5
              && String.sub n (String.length n - 5) 5 = ".toml")
          |> List.sort String.compare
        with Sys_error _ | Unix.Unix_error _ -> []
      in
      let current_set =
        List.fold_left (fun s n -> StringSet.add n s)
          StringSet.empty current_files
      in
      (* Stop threads for removed files *)
      let to_remove = ref [] in
      Hashtbl.iter (fun fname (stop, _) ->
        if not (StringSet.mem fname current_set) then begin
          Atomic.set stop true;
          to_remove := fname :: !to_remove
        end) active;
      List.iter (Hashtbl.remove active) !to_remove;
      (* Check for new/changed files *)
      List.iter (fun fname ->
        let path = Filename.concat dir fname in
        let mtime =
          try (Unix.stat path).Unix.st_mtime with _ -> 0.0
        in
        match Hashtbl.find_opt active fname with
        | Some (_, old_mtime) when mtime = old_mtime ->
            () (* unchanged *)
        | Some (stop, _) ->
            (* Changed — stop old thread, start new *)
            Atomic.set stop true;
            Hashtbl.remove active fname;
            try_start_schedule fname path mtime
        | None ->
            (* New file *)
            try_start_schedule fname path mtime)
        current_files
    in
    let rec loop () =
      (try load_schedules () with _ -> ());
      Unix.sleepf poll_interval;
      loop ()
    in
    loop ()) ())

let load_role_for_heartbeat ~(client : string) (agent_name : string option) :
    C2c_role.t option =
  match agent_name with
  | None -> None
  | Some name ->
      (try
         let path = C2c_role.resolve_agent_path ~name ~client in
         if Sys.file_exists path then Some (C2c_role.parse_file path) else None
       with _ -> None)

(* ---------------------------------------------------------------------------
 * pmodel (provider:model) preferences
 *
 * Config shape (in .c2c/config.toml):
 *
 *     [pmodel]
 *     default  = "anthropic:claude-opus-4-7"
 *     review   = "anthropic:claude-sonnet-4-6"
 *     planning = ":groq:openai/gpt-oss-120b"
 *
 * Parsing rule for a single value:
 *   - If the string starts with a leading ':' (prefix char), strip it and
 *     then split on the FIRST colon of the remainder. This lets the model
 *     name itself contain colons (rare, but e.g. namespaced paths).
 *   - Otherwise split on the FIRST colon.
 *   - An empty provider, empty model, or missing colon is an error.
 * --------------------------------------------------------------------------- *)

type pmodel = { provider : string; model : string }

(* parse_pmodel: see docs above. Returns Ok {provider; model} or Error msg.
   The leading ':' prefix char signals "the model name may contain colons,
   so don't naively split on the first one" — but we still split on the
   first colon *after* the prefix. That is sufficient to separate provider
   from model while allowing arbitrary colons in model. *)
let parse_pmodel (s : string) : (pmodel, string) result =
  let s = String.trim s in
  if s = "" then Error "pmodel: empty value"
  else
    let body = if s.[0] = ':' then String.sub s 1 (String.length s - 1) else s in
    match String.index_opt body ':' with
    | None ->
      Error (Printf.sprintf "pmodel: missing ':' separator in %S" s)
    | Some i ->
      let provider = String.sub body 0 i in
      let model = String.sub body (i + 1) (String.length body - i - 1) in
      if provider = "" then Error (Printf.sprintf "pmodel: empty provider in %S" s)
      else if model = "" then Error (Printf.sprintf "pmodel: empty model in %S" s)
      else Ok { provider; model }

(* Minimal TOML-ish reader for the [pmodel] table: key = "value" lines.
   We deliberately hand-roll (matches the style of repo_config_enable_channels
   above) rather than pulling in a TOML dep. Returns a (key, raw_value) assoc. *)
let read_pmodel_raw () : (string * string) list =
  let path = repo_config_path () in
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) @@ fun () ->
    let in_table = ref false in
    let acc = ref [] in
    (try
      while true do
        let line = input_line ic in
        let t = String.trim line in
        if t = "" || (String.length t > 0 && t.[0] = '#') then ()
        else if String.length t > 0 && t.[0] = '[' then begin
          (* new table header — we care only about exactly "[pmodel]" *)
          in_table := (t = "[pmodel]")
        end
        else if !in_table then begin
          match String.index_opt t '=' with
          | None -> ()
          | Some eq ->
            let k = String.trim (String.sub t 0 eq) in
            let v = String.trim (String.sub t (eq + 1) (String.length t - eq - 1)) in
            (* strip surrounding double quotes if present *)
            let v =
              if String.length v >= 2 && v.[0] = '"' && v.[String.length v - 1] = '"'
              then String.sub v 1 (String.length v - 2)
              else v
            in
            if k <> "" then acc := (k, v) :: !acc
        end
      done;
      assert false
    with End_of_file -> List.rev !acc)

(* repo_config_pmodel: returns (key, pmodel) pairs for keys that parse cleanly.
   Malformed entries are silently skipped — callers that want strict
   behavior can use read_pmodel_raw + parse_pmodel directly. *)
let repo_config_pmodel () : (string * pmodel) list =
  read_pmodel_raw ()
  |> List.filter_map (fun (k, v) ->
       match parse_pmodel v with
       | Ok p -> Some (k, p)
       | Error _ -> None)

(* Convenience lookup by use-case key (e.g. "default", "review"). *)
let repo_config_pmodel_lookup (use_case : string) : pmodel option =
  List.assoc_opt use_case (repo_config_pmodel ())

(* Minimal TOML-ish reader for the [default_binary] table.
   Allows repo-local overrides for client binaries (e.g. when multiple versions
   of the same client are installed and the system PATH resolves a release build
   that lacks features needed for xml-fd delivery).
   Example .c2c/config.toml entry:
     [default_binary]
     codex = "/home/user/.local/bin/codex"
   Note: inline comments (# ...) after values are not supported; put comments
   on their own lines above the key.
*)
let repo_config_default_binary (client : string) : string option =
  let path = repo_config_path () in
  if not (Sys.file_exists path) then None
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) @@ fun () ->
    let in_table = ref false in
    let result = ref None in
    (try
      while !result = None do
        let line = input_line ic in
        let t = String.trim line in
        if t = "" || (String.length t > 0 && t.[0] = '#') then ()
        else if String.length t > 0 && t.[0] = '[' then
          in_table := (t = "[default_binary]")
        else if !in_table then begin
          match String.index_opt t '=' with
          | None -> ()
          | Some eq ->
            let k = String.trim (String.sub t 0 eq) in
            if k = client then begin
              let v = String.trim (String.sub t (eq + 1) (String.length t - eq - 1)) in
              let v =
                if String.length v >= 2 && v.[0] = '"' && v.[String.length v - 1] = '"'
                then String.sub v 1 (String.length v - 2)
                else v
              in
              if v <> "" then result := Some v
            end
        end
      done
    with End_of_file -> ());
    !result

let normalize_model_override_for_client ~(client : string) (raw : string)
    : (string, string) result =
  let value = String.trim raw in
  if value = "" then Error "--model cannot be empty"
  else
    match client with
    | "opencode" ->
        (match parse_pmodel value with
         | Ok p -> Ok (p.provider ^ "/" ^ p.model)
         | Error e ->
             Error (Printf.sprintf
                      "opencode --model requires provider:model input (%s)" e))
    | "claude" | "codex" | "codex-headless" | "kimi" | "crush" ->
        if String.contains value ':' then
          (match parse_pmodel value with
           | Ok p -> Ok p.model
           | Error e -> Error e)
        else Ok value
    | _ -> Error (Printf.sprintf "unknown client for --model normalization: %s" client)

let current_c2c_command () =
  let fallback =
    if Array.length Sys.argv > 0 then Sys.argv.(0) else "c2c"
  in
  let resolved =
    try Unix.readlink "/proc/self/exe"
    with Unix.Unix_error _ -> fallback
  in
  if Filename.is_relative resolved then Sys.getcwd () // resolved else resolved

let write_json_file_atomic (path : string) (json : Yojson.Safe.t) : unit =
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let oc =
    open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_text ] 0o600 tmp
  in
  let cleanup_tmp () = try Unix.unlink tmp with _ -> () in
  (try
     Fun.protect
       ~finally:(fun () -> try close_out oc with _ -> ())
       (fun () ->
          Yojson.Safe.to_channel oc json;
          flush oc;
          (* #603: fsync before rename ensures the temp file's data is flushed
             to disk before the atomic-replace rename commits it, so readers
             always see either old or new content, never partial.
             Mirrors c2c_broker.ml's write_json_file pattern (#54).
             Best-effort — EINVAL on unusual filesystems is silently ignored. *)
          (try Unix.fsync (Unix.descr_of_out_channel oc)
           with Unix.Unix_error _ -> ()))
   with e ->
     cleanup_tmp ();
     raise e);
  try Unix.rename tmp path
  with e ->
    cleanup_tmp ();
    raise e

(* ---------------------------------------------------------------------------
 * Client adapter — unified client abstraction (Phase 1: opencode POC)
 * --------------------------------------------------------------------------- *)

(** CLIENT_ADAPTER: per-client behavior capsule.
   Replaces bespoke per-client functions scattered through c2c_start.ml.
   Phase 1 implements opencode as proof-of-concept; remaining clients follow. *)
module type CLIENT_ADAPTER = sig
  val name : string

  val config_dir : string
  val agent_dir : string
  val instances_subdir : string

  val binary : string
  val needs_deliver : bool

  val needs_poker : bool
  val poker_event : string option
  val poker_from : string option
  val extra_env : (string * string) list
  val session_id_env : string option

  val build_start_args :
    name:string ->
    ?alias_override:string ->
    ?model_override:string ->
    ?resume_session_id:string ->
    ?extra_args:string list ->
    unit -> string list

  val refresh_identity :
    name:string ->
    alias:string ->
    broker_root:string ->
    project_dir:string ->
    instances_dir:string ->
    agent_name:string option ->
    unit

  val probe_capabilities : binary_path:string -> (string * bool) list

  (** [deliver_kickoff ~name ~alias ~kickoff_text ?broker_root ()] performs
      whatever per-client side-effects are needed so the supplied kickoff
      text reaches the freshly-launched session.  Returns a list of
      [(KEY, VALUE)] env pairs that the caller MUST append to the launch
      env array (e.g. opencode's [C2C_AUTO_KICKOFF=1] / kickoff-path
      handshake with its plugin).

      Adapters that have nothing to do return [Ok []]:
      - claude: kickoff is a positional argv in [prepare_launch_args].
      - kimi: kickoff is [--prompt] argv in [prepare_launch_args].
      - codex (#143c): kickoff is an XML pipe write in [run_outer_loop]
        (parent-side, after fork, before the deliver daemon starts).
      - gemini (#143d): kickoff is a positional argv in
        [prepare_launch_args].

      The launch loop calls this contract method for every client so
      adapters that DO have side-effects (opencode writes a kickoff
      file + returns env pairs) can extend coverage without inlining
      per-client gates.  See task #143. *)
  val deliver_kickoff :
    name:string ->
    alias:string ->
    kickoff_text:string ->
    ?broker_root:string ->
    unit ->
    ((string * string) list, string) result
end

(* ---------------------------------------------------------------------------
 * Client configurations
 * --------------------------------------------------------------------------- *)

type client_config = {
  binary : string;
  deliver_client : string;
  needs_deliver : bool;
  needs_poker : bool;
  poker_event : string option;
  poker_from : string option;
  extra_env : (string * string) list;
}

let clients : (string, client_config) Stdlib.Hashtbl.t = Stdlib.Hashtbl.create 5

let () =
  (* claude: PostToolUse hook + MCP channel notifications handle delivery.
     Python c2c_deliver_inbox.py is not needed and its PTY-inject path
     adds the CAP_SYS_PTRACE preflight banner for no benefit. *)
  Stdlib.Hashtbl.add clients "claude"
    { binary = "claude"; deliver_client = "claude";
      needs_deliver = false; needs_poker = false;
      poker_event = None; poker_from = None;
      extra_env = [] };
  Stdlib.Hashtbl.add clients "codex"
    { binary = "codex"; deliver_client = "codex";
      needs_deliver = true; needs_poker = false;
      poker_event = None; poker_from = None; extra_env = [] };
  (* opencode: the TypeScript c2c plugin (.opencode/plugins/c2c.ts) handles
     delivery in-process via client.session.promptAsync. Python deliver
     daemon is redundant and surfaces a noisy CAP_SYS_PTRACE banner in the
     TUI when setcap is missing. *)
  Stdlib.Hashtbl.add clients "opencode"
    { binary = "opencode"; deliver_client = "opencode";
      needs_deliver = false; needs_poker = false;
      poker_event = None; poker_from = None; extra_env = [] };
  (* kimi: delivery via C2c_kimi_notifier — file-based notification-store push.
     The deprecated wire-bridge path was removed in the kimi-wire-bridge-cleanup
     slice. *)
  Stdlib.Hashtbl.add clients "kimi"
    { binary = "kimi"; deliver_client = "kimi";
      needs_deliver = false; needs_poker = true;
      poker_event = Some "heartbeat"; poker_from = Some "kimi-poker";
      extra_env = [] };
  Stdlib.Hashtbl.add clients "crush"
    { binary = "crush"; deliver_client = "crush";
      needs_deliver = true; needs_poker = false;
      poker_event = None; poker_from = None; extra_env = [] };
  (* gemini (#406b): Google's Gemini CLI. MCP-server-based delivery via
     `gemini mcp` config (written by `c2c install gemini` — slice #406a),
     no separate deliver daemon, no wire bridge, no poker. The `trust:
     true` flag on the c2c MCP server entry bypasses tool-call confirmation
     prompts, so automated `c2c restart gemini` works without TTY
     auto-answer (unlike Claude's #399b dance). *)
  Stdlib.Hashtbl.add clients "gemini"
    { binary = "gemini"; deliver_client = "gemini";
      needs_deliver = false; needs_poker = false;
      poker_event = None; poker_from = None; extra_env = [] };
  (* codex-headless: minimal unblocker for broker-driven XML delivery.
     We wire the bridge behind a c2c-owned stdin pipe and use the deliver daemon
     to feed that pipe. Richer operator steering / queue management remains future work. *)
  Stdlib.Hashtbl.add clients "codex-headless"
    { binary = "codex-turn-start-bridge"; deliver_client = "codex-headless";
      needs_deliver = true; needs_poker = false;
      poker_event = None; poker_from = None; extra_env = [] };
  (* pty: generic PTY-backed client. forks a PTY pair, execs the user's command
     on the slave, and delivers inbound c2c messages by writing to the master fd
     (bracketed paste + delay + Enter, a la pty_inject). *)
  Stdlib.Hashtbl.add clients "pty"
    { binary = "pty"; deliver_client = "pty";
      needs_deliver = false; needs_poker = false;
      poker_event = None; poker_from = None; extra_env = [] }
  ;
  (* tmux: generic lifecycle-decoupled delivery to an existing pane. The
     "binary" is only used for preflight availability; c2c owns no inner
     client process in this mode. *)
  Stdlib.Hashtbl.add clients "tmux"
    { binary = "tmux"; deliver_client = "tmux";
      needs_deliver = false; needs_poker = false;
      poker_event = None; poker_from = None; extra_env = [] }

let supported_clients = Stdlib.Hashtbl.fold (fun k _ acc -> k :: acc) clients []

(* ---------------------------------------------------------------------------
 * Per-client adapter modules (Phase 1: opencode POC)
 * --------------------------------------------------------------------------- *)

let client_adapters : (string, (module CLIENT_ADAPTER)) Stdlib.Hashtbl.t =
  Stdlib.Hashtbl.create 5

module OpenCodeAdapter : CLIENT_ADAPTER = struct
  let name = "opencode"

  let config_dir = ".opencode"
  let agent_dir = "agents"
  let instances_subdir = "opencode"

  let binary = "opencode"
  let needs_deliver = false

  let needs_poker = false
  let poker_event = None
  let poker_from = None
  let extra_env = []
  let session_id_env = Some "OPENCODE_SESSION_ID"

  let build_start_args ~name ?alias_override ?model_override ?resume_session_id
      ?(extra_args=[]) () =
    let session_arg = match resume_session_id with
     | Some sid when String.length sid >= 3 && String.sub sid 0 3 = "ses" ->
         [ "--session"; sid ]
     | _ -> []
    in
    let base = [ "--log-level"; "INFO" ] @ session_arg in
    match model_override with
    | Some m when String.trim m <> "" -> base @ [ "--model"; m ]
    | _ -> base

  let refresh_identity ~name ~alias ~broker_root ~project_dir ~instances_dir
      ~agent_name =
    let config_dir = project_dir // ".opencode" in
    let config_path = config_dir // "opencode.json" in
    (if Sys.file_exists config_path then
      (try
        let cfg = Yojson.Safe.from_file config_path in
        let identity_env = [
          ("C2C_MCP_BROKER_ROOT", `String broker_root);
          ("C2C_MCP_AUTO_JOIN_ROOMS", `String "swarm-lounge");
          ("C2C_MCP_AUTO_DRAIN_CHANNEL", `String "0");
          ("C2C_CLI_COMMAND", `String (current_c2c_command ()));
        ] in
        let merge_env env_obj new_pairs =
          let existing = match env_obj with `Assoc p -> p | _ -> [] in
          let keys = List.map fst new_pairs in
          let drop_keys = ["C2C_MCP_AUTO_REGISTER_ALIAS"; "C2C_MCP_SESSION_ID"] in
          let kept = List.filter (fun (k, _) ->
            not (List.mem k keys) && not (List.mem k drop_keys)) existing in
          `Assoc (kept @ new_pairs)
        in
        let put key v pairs =
          if List.mem_assoc key pairs
          then List.map (fun (k, x) -> if k = key then (k, v) else (k, x)) pairs
          else pairs @ [(key, v)]
        in
        let updated = match cfg with
          | `Assoc top ->
              let mcp_obj = match List.assoc_opt "mcp" top with Some m -> m | None -> `Assoc [] in
              let mcp_pairs = match mcp_obj with `Assoc p -> p | _ -> [] in
              let c2c_obj = match List.assoc_opt "c2c" mcp_pairs with Some c -> c | None -> `Assoc [] in
              let c2c_pairs = match c2c_obj with `Assoc p -> p | _ -> [] in
              let env_obj = match List.assoc_opt "environment" c2c_pairs with Some e -> e | None -> `Assoc [] in
              let env_updated = merge_env env_obj identity_env in
              let c2c_updated = `Assoc (put "environment" env_updated c2c_pairs) in
              let mcp_updated = `Assoc (put "c2c" c2c_updated mcp_pairs) in
              `Assoc (put "mcp" mcp_updated top)
          | other -> other
        in
        let tmp = config_path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
        (try
          let oc = open_out tmp in
          (try Yojson.Safe.pretty_to_channel oc updated; output_char oc '\n'
           with e -> close_out_noerr oc; raise e);
          close_out oc;
          Unix.rename tmp config_path
        with _ -> ())
      with _ -> ()));
    let sidecar_path = instances_dir // name // "c2c-plugin.json" in
    (try
      let existing = if Sys.file_exists sidecar_path then
        (match Yojson.Safe.from_file sidecar_path with `Assoc p -> p | _ -> [])
      else []
      in
      (* Drift-prevention follow-up to #504 / kimi-mcp-canonical-server:
         omit broker_root from the sidecar when it equals the resolver
         default. Persisting the resolver-default value re-pins stale
         paths after future migrations; the opencode TS plugin has its
         own canonical resolver (mirrors C2c_repo_fp.resolve_broker_root)
         so an absent field falls back correctly. Only persist when the
         operator explicitly overrode. *)
      let resolver_default =
        try C2c_repo_fp.resolve_broker_root () with _ -> ""
      in
      let identity_base =
        (match agent_name with Some n -> [("agent_name", `String n)] | None -> [])
        @ [
          ("session_id", `String name);
          ("alias", `String alias);
        ]
      in
      let identity =
        if broker_root = "" || broker_root = resolver_default
        then identity_base
        else identity_base @ [ ("broker_root", `String broker_root) ]
      in
      (* Always strip stale broker_root from existing file so the skip
         actually takes effect on resume. *)
       let stripped_keys = "session_id" :: "alias" :: "broker_root" :: [] in
       let kept = List.filter (fun (k, _) -> not (List.mem k stripped_keys)) existing in
       write_json_file_atomic sidecar_path (`Assoc (kept @ identity))
     with _ -> ())

  let probe_capabilities ~binary_path =
    let plugin_path = Filename.concat (Sys.getcwd ()) ".opencode" // "plugins" // "c2c.ts" in
    ["opencode_plugin", Sys.file_exists plugin_path]

  (* Real impl. Refactored from the inline opencode kickoff sites in
     [c2c_start.ml:3700] (env-var gate) + [:3913] (file-write gate) per
     #143.

     Behavior:
       1. Writes [<inst_dir>/kickoff-prompt.txt] with [kickoff_text].
       2. Returns the [(C2C_AUTO_KICKOFF, "1")] +
          [(C2C_KICKOFF_PROMPT_PATH, <path>)] env pairs the launch loop
          must append to the launch env array, so the c2c plugin in
          [.opencode/plugins/c2c.ts] picks them up and proactively
          delivers the prompt if the TUI never fires session.created
          on its own.

     [instance_dir] is defined later in the file, so we replicate the
     exact path-resolution it uses (the [C2C_INSTANCES_DIR] env override
     + [$HOME/.local/share/c2c/instances/<name>] default) inline here. *)
  let deliver_kickoff ~name ~alias:_ ~kickoff_text
      ?broker_root:_ () =
    if kickoff_text = "" then Ok []
    else
      let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
      let inst_base =
        match Sys.getenv_opt "C2C_INSTANCES_DIR" with
        | Some d when String.trim d <> "" -> String.trim d
        | _ -> Filename.concat home (".local/share/c2c/instances")
      in
      let inst_dir = Filename.concat inst_base name in
      let path = Filename.concat inst_dir "kickoff-prompt.txt" in
      try
        C2c_io.mkdir_p inst_dir;
        let oc = open_out path in
        Fun.protect ~finally:(fun () -> close_out oc)
          (fun () -> output_string oc kickoff_text);
        Ok [
          ("C2C_AUTO_KICKOFF", "1");
          ("C2C_KICKOFF_PROMPT_PATH", path);
        ]
      with e ->
        Error (Printf.sprintf
                 "OpenCodeAdapter.deliver_kickoff: %s"
                 (Printexc.to_string e))
end

let () = Stdlib.Hashtbl.add client_adapters "opencode" (module OpenCodeAdapter)

(* ---------------------------------------------------------------------------
 * Paths
 * --------------------------------------------------------------------------- *)

let home_dir () =
  try Sys.getenv "HOME" with Not_found -> "/home/" ^ Sys.getenv "USER"

let opencode_log_dir () = home_dir () // ".local" // "share" // "opencode" // "log"

let latest_opencode_log () : string option =
  let dir = opencode_log_dir () in
  if not (Sys.file_exists dir) then None
  else
    try
      let entries = Array.to_list (Sys.readdir dir) in
      let logs = List.filter (fun f ->
        Filename.check_suffix f ".log" &&
        String.length f > 0 &&
        f.[0] <> '.') entries
      in
      if logs = [] then None
      else
        let latest = List.hd (List.sort String.compare (List.rev logs)) in
        Some (dir // latest)
    with _ -> None

let instances_dir =
  match Sys.getenv_opt "C2C_INSTANCES_DIR" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ -> Filename.concat (home_dir ()) ".local" // "share" // "c2c" // "instances"

let mkdir_p dir = C2c_io.mkdir_p dir

let write_git_shim_atomic ~(shim_bin_path : string) ~(c2c_bin_path : string)
    ~(real_git_path : string) : unit =
  (* Atomic install: write to a temp file in the same directory, fsync it,
     then rename to the target path. Same pattern as write_json_file_atomic.
     Temp file is in the same directory so fsync guarantees rename sees it
     on the same filesystem. Best-effort fsync — EINVAL on unusual filesystems
     is silently ignored. *)
  let q = Filename.quote in
  let tmp = shim_bin_path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let oc =
    open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_text ] 0o600 tmp
  in
  let cleanup_tmp () = try Unix.unlink tmp with _ -> () in
  (try
     Fun.protect
       ~finally:(fun () -> try close_out oc with _ -> ())
       (fun () ->
          output_string oc "#!/bin/bash\n";
          output_string oc
            "# Delegation shim: git attribution for managed sessions.\n";
          output_string oc
            "# Delegates allowed operations to git-pre-reset (pre-reset guard) on PATH.\n";
          output_string oc
            "# git-pre-reset is installed in the same directory and handles dangerous-op\n";
          output_string oc
            "# guard (reset --hard, commit on main, checkout -f on main).\n";
          output_string oc "if [ \"${C2C_GIT_SHIM_ACTIVE:-}\" = \"1\" ]; then\n";
          output_string oc (Printf.sprintf "  exec %s \"$@\"\n" (q real_git_path));
          output_string oc "fi\n";
          output_string oc "export C2C_GIT_SHIM_ACTIVE=1\n";
          (* Delegate to git-pre-reset (the pre-reset/pre-commit guard) for allowed
             operations. git-pre-reset is installed alongside this shim in the same
             directory (swarm_git_shim_dir) and is found via PATH ordering. *)
          output_string oc "exec git-pre-reset \"$@\"\n";
          flush oc;
          (try Unix.fsync (Unix.descr_of_out_channel oc)
           with Unix.Unix_error _ -> ()))
   with e ->
     cleanup_tmp ();
     raise e);
  try Unix.rename tmp shim_bin_path
  with e ->
    cleanup_tmp ();
    raise e

(* smoke-check: run bash -n on the installed shim. Refuse to proceed if the
   file is syntax-broken. This guards against a partial write (from a previous
   crash) leaving a broken shim that then gets installed. *)
let shim_syntax_check (path : string) : unit =
  let cmd = Printf.sprintf "bash -n %s" (Filename.quote path) in
  let rc = Sys.command cmd in
  if rc <> 0 then
    failwith ("shim_syntax_check failed: " ^ path)

(* ----------------------------------------------------------------------------
 * #462 — swarm-wide git-shim install.
 *
 * v1 wrote one shim per managed-session instance under
 * [instance_dir/<name>/bin/git]. v2 adds a single canonical install
 * shared by every [c2c start <client>] invocation, so the shim is
 * present uniformly without a write per session.
 *
 * Path resolution:
 *   1. [C2C_GIT_SHIM_DIR] (explicit override, e.g. tests)
 *   2. [$XDG_STATE_HOME/c2c/bin] (canonical when XDG set)
 *   3. [$HOME/.local/state/c2c/bin] (XDG default fallback)
 *
 * [ensure_swarm_git_shim_installed ()] is idempotent — mkdirs the
 * directory, rewrites the shim file (cheap, content is small) and
 * chmods +x. Safe to call on every [c2c start]. Returns the shim
 * directory so callers can prepend it to PATH.
 * --------------------------------------------------------------------------- *)

let swarm_git_shim_dir () =
  match Sys.getenv_opt "C2C_GIT_SHIM_DIR" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ -> C2c_repo_fp.xdg_state_home () // "c2c" // "bin"

(* S6c: detect whether the MCP server child handles schedule-timer firing.
   When c2c start sets C2C_MCP_SCHEDULE_TIMER=1 in its own process env
   (after also passing it to the child via build_env), this returns true
   so the parent skips its own schedule watcher thread — avoiding
   duplicate heartbeats. *)
let mcp_schedule_timer_active () =
  match Sys.getenv_opt "C2C_MCP_SCHEDULE_TIMER" with
  | Some v ->
      let n = String.lowercase_ascii (String.trim v) in
      List.mem n ["1"; "true"; "yes"; "on"]
  | None -> false

(* ----------------------------------------------------------------------------
 * Install the pre-reset guard shim (git-pre-reset) into the swarm shim dir.
 * Copies the repo's git-shim.sh to git-pre-reset in [dir] and chmods +x.
 * The pre-reset shim intercepts dangerous git operations (reset --hard, commit
 * on main) and refuses them for non-coordinators.  It is distinct from the
 * attribution shim (the "git" shim that wraps `c2c git`); both live in the same
 * dir and are found via PATH ordering.
 * --------------------------------------------------------------------------- *)
let install_pre_reset_shim ~(dir : string) =
  let src =
    match Git_helpers.git_repo_toplevel () with
    | None -> failwith "install_pre_reset_shim: not in a git repo"
    | Some r -> r // "git-shim.sh"
  in
  let dst = dir // "git-pre-reset" in
  if not (Sys.file_exists src) then
    failwith ("install_pre_reset_shim: source not found: " ^ src);
  (* Copy src to dst; idempotent.  Use cp rather than OCaml IO to handle
     the shebang/interpreter correctly without binary-mode edge-cases. *)
  let q s = Filename.quote s in
  let rc = Sys.command (Printf.sprintf "cp %s %s" (q src) (q dst)) in
  if rc <> 0 then failwith ("install_pre_reset_shim: cp failed: " ^ src ^ " -> " ^ dst);
  try Unix.chmod dst 0o755 with _ -> ()

let ensure_swarm_git_shim_installed () =
  let dir = swarm_git_shim_dir () in
  mkdir_p dir;
  let shim_bin_path = dir // "git" in
  let c2c_bin_path = current_c2c_command () in
  let real_git_path = Git_helpers.find_real_git () in
  write_git_shim_atomic ~shim_bin_path ~c2c_bin_path ~real_git_path;
  shim_syntax_check shim_bin_path;
  (try Unix.chmod shim_bin_path 0o755 with _ -> ());
  (* Also install the pre-reset guard (git-pre-reset) from the repo's
     git-shim.sh into the same shim directory. Idempotent. *)
  install_pre_reset_shim ~dir;
  dir

let ensure_fifo path =
  (try
     if Sys.file_exists path then
       match (Unix.stat path).Unix.st_kind with
       | Unix.S_FIFO -> ()
       | _ ->
           Sys.remove path;
           Unix.mkfifo path 0o600
     else
       Unix.mkfifo path 0o600
   with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    | Sys_error _ -> ())

let with_file_lock (path : string) (f : unit -> 'a) : 'a =
  let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT ] 0o644 in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
      (try Unix.close fd with _ -> ()))
    (fun () ->
      Unix.lockf fd Unix.F_LOCK 0;
      f ())

let clear_registration_pid ~(broker_root : string) ~(session_id : string) : unit =
  let reg_path = broker_root // "registry.json" in
  let lock_path = broker_root // "registry.json.lock" in
  if Sys.file_exists reg_path then
    with_file_lock lock_path (fun () ->
      let json = try Yojson.Safe.from_file reg_path with _ -> `List [] in
      let updated =
        match json with
        | `List regs ->
            `List
              (List.map
                 (fun r ->
                   match r with
                   | `Assoc fields ->
                       let sid =
                         match List.assoc_opt "session_id" fields with
                         | Some (`String s) -> s
                         | _ -> ""
                       in
                       if sid = session_id then
                         `Assoc
                           (List.filter
                              (fun (k, _) -> k <> "pid" && k <> "pid_start_time")
                              fields)
                       else r
                   | _ -> r)
                 regs)
        | _ -> json
      in
      write_json_file_atomic reg_path updated)

let read_pid_start_time (pid : int) : int option =
  let path = Printf.sprintf "/proc/%d/stat" pid in
  try
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> try close_in ic with _ -> ())
      (fun () ->
        let line = input_line ic in
        match String.rindex_opt line ')' with
        | None -> None
        | Some idx ->
            let tail = String.sub line (idx + 2) (String.length line - idx - 2) in
            let parts = String.split_on_char ' ' tail in
            (match List.nth_opt parts 19 with
             | Some token ->
                 (try Some (int_of_string token) with _ -> None)
             | None -> None))
  with Sys_error _ | End_of_file -> None

let eager_register_managed_alias ~(broker_root : string) ~(session_id : string)
    ~(alias : string) ~(pid : int) ~(client_type : string) : unit =
  (* Managed codex-headless needs broker reachability before the bridge has
     produced a thread id. Ensure the broker dir exists before taking the
     registry lock so the eager registration path can bootstrap cleanly. *)
  mkdir_p broker_root;
  let reg_path = broker_root // "registry.json" in
  let lock_path = broker_root // "registry.json.lock" in
  let pid_start_time = read_pid_start_time pid in
  let now = Unix.gettimeofday () in
  let row =
    `Assoc
      ([ ("session_id", `String session_id)
       ; ("alias", `String alias)
       ; ("pid", `Int pid)
       ; ("registered_at", `Float now)
       ; ("client_type", `String client_type) ]
       @ (match pid_start_time with
          | Some n -> [ ("pid_start_time", `Int n) ]
          | None -> []))
  in
  with_file_lock lock_path (fun () ->
    let regs =
      match (try Yojson.Safe.from_file reg_path with _ -> `List []) with
      | `List items -> items
      | _ -> []
    in
    let kept =
      List.filter
        (function
          | `Assoc fields ->
              let sid =
                match List.assoc_opt "session_id" fields with
                | Some (`String s) -> s
                | _ -> ""
              in
              let existing_alias =
                match List.assoc_opt "alias" fields with
                | Some (`String s) -> s
                | _ -> ""
              in
              sid <> session_id && existing_alias <> alias
          | _ -> false)
        regs
    in
    write_json_file_atomic reg_path (`List (row :: kept)))

let instance_dir name = instances_dir // name
let per_agent_managed_heartbeats ~(name : string) : managed_heartbeat list =
  managed_heartbeats_from_toml_path (instance_dir name // "heartbeat.toml")

let config_path name = instance_dir name // "config.json"
let meta_json_path name = instance_dir name // "meta.json"
let outer_pid_path name = instance_dir name // "outer.pid"
let inner_pid_path name = instance_dir name // "inner.pid"
let deliver_pid_path name = instance_dir name // "deliver.pid"
let poker_pid_path name = instance_dir name // "poker.pid"
let stderr_log_path name = instance_dir name // "stderr.log"
let client_log_path name = instance_dir name // "client.log"
let headless_thread_id_handoff_path name = instance_dir name // "thread-id-handoff.jsonl"
let headless_xml_fifo_path name = instance_dir name // "xml-input.fifo"
let bridge_events_fifo_path name = instance_dir name // "bridge-events.fifo"
let bridge_responses_fifo_path name = instance_dir name // "bridge-responses.fifo"
let deaths_jsonl_path broker_root = broker_root // "deaths.jsonl"
let tmux_info_path name = instance_dir name // "tmux.json"
let expected_cwd_path name = instance_dir name // "expected-cwd"

(* Write the expected-CWD file at start and restart time.  The outer
   wrapper's cwd at launch is the canonical expected path — if the agent's
   inner shell drifts to a different tree, this file lets the broker detect
   the mismatch.  Best-effort: silently skips on errors. *)
let write_expected_cwd ~(name : string) : unit =
  let path = expected_cwd_path name in
  try
    let cwd = Unix.realpath (Sys.getcwd ()) in
    let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
    let oc = open_out_gen [Open_wronly; Open_creat; Open_trunc; Open_text] 0o600 tmp in
    Fun.protect ~finally:(fun () -> try close_out oc with _ -> ())
      (fun () ->
         output_string oc cwd;
         flush oc;
         (try Unix.fsync (Unix.descr_of_out_channel oc)
          with Unix.Unix_error _ -> ()));
    Unix.rename tmp path
  with _ -> ()

(* Orphan-inbox replay: persists across the c2c restart exec gap.
   cmd_restart saves orphan messages here before exec; the MCP server
   injects them into the new session's inbox after auto_register_startup.
   Path is in the broker root (not instance dir) so the MCP server can
   find it without knowing the instance name. *)

(* Capture orphan inbox messages before restart, save to pending-replay file,
   and delete the orphan inbox. Called in cmd_restart before execvp so
   messages queued during the restart gap are preserved.
   The Broker.capture_orphan_for_restart call handles the full atomic sequence:
   read → write pending → delete orphan, all under inbox lock, so a write
   failure leaves the orphan intact. *)
let capture_orphan_inbox_for_restart ~(broker_root : string) ~(session_id : string) : int =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  C2c_mcp.Broker.capture_orphan_for_restart broker ~session_id

(* Replay captured orphan messages into the new session's inbox.
   Called in the MCP server after auto_register_startup, so messages
   queued during the restart gap are delivered to the new session. *)
let replay_pending_orphan_inbox ~(broker_root : string) ~(session_id : string) : int =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  C2c_mcp.Broker.replay_pending_orphan_inbox broker ~session_id

(* Capture tmux session name if running inside a tmux session.
   Writes {session} to tmux_info_path. Silently skips if $TMUX is not set
   or tmux commands fail. Only 'session' is read back by read_tmux_location_opt;
   pane_pid and captured_at were dead fields (#523). *)
let capture_and_write_tmux_location name =
  match Sys.getenv_opt "TMUX" with
  | None -> ()
  | Some _ ->
      let tmux_info_file = tmux_info_path name in
      let capture cmd =
        try
          let ic = Unix.open_process_in cmd in
          Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
            (fun () -> Some (input_line ic))
        with _ -> None
      in
      match capture "tmux display -p '#S:#I.#P'", capture "tmux display -p '#{pane_pid}'" with
      | Some session, Some _pane_pid ->
          (try
            let tmux_json =
              Printf.sprintf "{\n  \"session\": \"%s\"\n}\n"
                (String.trim session)
            in
            let oc = open_out tmux_info_file in
            Fun.protect ~finally:(fun () -> close_out oc)
              (fun () -> output_string oc tmux_json)
          with _ -> ())
      | _ -> ()

(* Read the tmux session:window.pane from the per-instance tmux.json file,
   written by [capture_and_write_tmux_location] at session start. Returns
   [None] if the file does not exist or lacks a "session" field. *)
let read_tmux_location_opt (name : string) : string option =
  let path = tmux_info_path name in
  if not (Sys.file_exists path) then None
  else
    try
      let json = Yojson.Safe.from_file path in
      let rec get_string = function
        | `Assoc fields ->
            (match List.assoc_opt "session" fields with
             | Some (`String s) -> Some s
             | _ -> None)
        | _ -> None
      in
      get_string json
    with _ -> None

type tmux_target_info = { tmux_location : string }

let parse_tmux_target_info line =
  match String.split_on_char ' ' (String.trim line) |> List.filter ((<>) "") with
  | loc :: _ -> Some { tmux_location = loc }
  | _ -> None

let tmux_shell_command_of_argv argv =
  String.concat " " (List.map Filename.quote argv)

let tmux_message_payload messages =
  C2c_wire_bridge.format_prompt messages

let run_process ?stdin_file command args =
  let stdin_fd =
    match stdin_file with
    | Some path -> Unix.openfile path [ Unix.O_RDONLY ] 0
    | None -> Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0
  in
  Fun.protect
    ~finally:(fun () -> try Unix.close stdin_fd with _ -> ())
    (fun () ->
      try
        let pid =
          Unix.create_process command (Array.of_list (command :: args))
            stdin_fd Unix.stdout Unix.stderr
        in
        match Unix.waitpid [] pid with
        | _, Unix.WEXITED 0 -> true
        | _, Unix.WEXITED _ | _, Unix.WSIGNALED _ | _, Unix.WSTOPPED _ -> false
      with _ -> false)

let capture_process command args =
  try
    let ic = Unix.open_process_args_in command (Array.of_list (command :: args)) in
    let output =
      let buf = Buffer.create 128 in
      (try
         while true do
           Buffer.add_string buf (input_line ic);
           Buffer.add_char buf '\n'
         done
       with End_of_file -> ());
      Buffer.contents buf
    in
    match Unix.close_process_in ic with
    | Unix.WEXITED 0 -> Some (String.trim output)
    | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> None
  with _ -> None

let validate_tmux_target loc =
  match
    capture_process "tmux"
      [ "display-message"; "-t"; loc; "-p"; "#S:#I.#P #{pane_id}" ]
  with
  | Some line -> parse_tmux_target_info line
  | None -> None

let tmux_send_enter loc =
  let prev_ext =
    match capture_process "tmux" [ "show"; "-sv"; "extended-keys" ] with
    | Some s when String.trim s <> "" -> String.trim s
    | _ -> "off"
  in
  ignore (run_process "tmux" [ "set"; "-s"; "extended-keys"; "off" ]);
  let ok = run_process "tmux" [ "send-keys"; "-t"; loc; "Enter" ] in
  ignore (run_process "tmux" [ "set"; "-s"; "extended-keys"; prev_ext ]);
  ok

let tmux_send_shell_command loc argv =
  match argv with
  | [] -> true
  | _ ->
      let command = tmux_shell_command_of_argv argv in
      run_process "tmux" [ "send-keys"; "-t"; loc; command ]
      && tmux_send_enter loc

let tmux_paste_and_submit loc payload =
  let tmp =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "c2c-tmux-payload-%d-%06x" (Unix.getpid ()) (Random.bits ()))
  in
  let buffer_name = Printf.sprintf "c2c-%d-%06x" (Unix.getpid ()) (Random.bits ()) in
  let write_payload () =
    let oc = open_out tmp in
    Fun.protect ~finally:(fun () -> close_out oc)
      (fun () -> output_string oc payload)
  in
  try
    write_payload ();
    let ok =
      run_process "tmux" [ "load-buffer"; "-b"; buffer_name; tmp ]
      && run_process "tmux" [ "paste-buffer"; "-t"; loc; "-b"; buffer_name ]
      && tmux_send_enter loc
    in
    ignore (run_process "tmux" [ "delete-buffer"; "-b"; buffer_name ]);
    (try Sys.remove tmp with _ -> ());
    ok
  with e ->
    (try Sys.remove tmp with _ -> ());
    raise e

(* #399: Auto-answer the Claude Code development-channel consent prompt.
   After spawning Claude Code with --dangerously-load-development-channels server:c2c,
   the Claude Code binary shows an interactive consent prompt:
     "I am using this for local development [1]"
   We detect this via tmux capture-pane and auto-press 1 to proceed,
   so `c2c restart claude` can run unattended without a human keypress.
   Timeout after 10s so we don't wedge on non-channel prompts (e.g. rate limits). *)

let tmux_capture_pane (loc : string) : string option =
  (* Capture the visible scrollback buffer of a tmux pane as a single string.
     tmux capture-pane -t <loc> -p  dumps raw pane content (including ANSI
     escape sequences from the Claude startup banner). We only care about
     whether the consent needle is present, so exact formatting doesn't matter. *)
  capture_process "tmux" [ "capture-pane"; "-t"; loc; "-p" ]

let auto_answer_dev_channel_prompt ~(tmux_location : string) : bool =
  (* Returns true if the prompt was detected and answered, false if not found within timeout.
     The caller logs appropriately; this function only returns the detection outcome. *)
  let needle = "I am using this for local development" in
  let timeout_s = 10.0 in
  let start = Unix.gettimeofday () in
  let rec poll () =
    let elapsed = Unix.gettimeofday () -. start in
    if elapsed >= timeout_s then (
      (* Timeout — consent prompt never appeared. Leave it visible for the user. *)
      false
    ) else (
      match tmux_capture_pane tmux_location with
      | Some content ->
          if (try ignore (Str.search_forward (Str.regexp_string needle) content 0); true with Not_found -> false) then (
            (* Prompt detected — send "1" to select the first option (confirm). *)
            let ok = run_process "tmux" [ "send-keys"; "-t"; tmux_location; "1" ] in
            if ok then begin
              (* Send Enter to confirm the selection. *)
              ignore (tmux_send_enter tmux_location);
              true
            end else
              false
          ) else (
            (* Not yet present — short sleep and retry. *)
            Unix.sleepf 0.2;
            poll ()
          )
      | None ->
          (* tmux capture failed — bail and let the user handle it manually. *)
          false
    )
  in
  poll ()

(* [#523] removed pane_id and captured_at — only 'session' is read back
   by read_tmux_location_opt. Dead fields removed from write. *)
let write_tmux_target_info name (info : tmux_target_info) =
  let path = tmux_info_path name in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () ->
      Yojson.Safe.pretty_to_channel oc
        (`Assoc [ ("session", `String info.tmux_location) ]);
      output_char oc '\n')

let tmux_deliver_once ~broker_root ~session_id ~target =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  C2c_mcp.Broker.with_inbox_lock broker ~session_id (fun () ->
      let messages = C2c_mcp.Broker.read_inbox broker ~session_id in
      match messages with
      | [] -> 0
      | _ ->
          let payload = tmux_message_payload messages in
          if tmux_paste_and_submit target payload then begin
            C2c_mcp.Broker.append_archive ~drained_by:"tmux" broker ~session_id ~messages;
            C2c_mcp.Broker.save_inbox broker ~session_id [];
            List.length messages
          end else
            0)

(* Tee stderr to inst_dir/stderr.log with 2 MB ring rotation.
   Returns (pipe_write_fd, stop_write_fd, tee_thread). The explicit stop pipe
   avoids hanging forever when a child descendant keeps stderr inherited after
   the managed client exits; EOF on the stderr tee pipe is not reliable then. *)
let start_stderr_tee ~inst_dir ~outer_stderr_fd =
  let log_path = inst_dir // "stderr.log" in
  let max_bytes = 2 * 1024 * 1024 in
  let (pipe_read_fd, pipe_write_fd) = Unix.pipe ~cloexec:false () in
  let (stop_read_fd, stop_write_fd) = Unix.pipe ~cloexec:false () in
  let buf = Buffer.create 4096 in
  let tee_thread = Thread.create (fun () ->
    let chunk = Bytes.create 4096 in
    let log_fd = ref None in
    let open_log () =
      match !log_fd with
      | Some _ -> ()
      | None ->
        (try
          let fd = Unix.openfile log_path
            Unix.[ O_WRONLY; O_CREAT; O_APPEND ] 0o644 in
          log_fd := Some fd
        with _ -> ())
    in
    let rotate_if_needed fd =
      try
        let size = (Unix.fstat fd).Unix.st_size in
        if size >= max_bytes then begin
          (* Keep second half as ring *)
          let half = max_bytes / 2 in
          let tmp = log_path ^ ".rot" in
          let ic = open_in log_path in
          (try seek_in ic half with _ -> ());
          let oc = open_out tmp in
          (try
            while true do
              output_char oc (input_char ic)
            done
          with End_of_file -> ());
          close_in ic; close_out oc;
          Unix.rename tmp log_path;
          Unix.close fd;
          log_fd := None;
          open_log ()
        end
      with _ -> ()
    in
    let flush_line line =
      (* Write to outer stderr *)
      (try
        let s = line ^ "\n" in
        let b = Bytes.of_string s in
        ignore (Unix.write outer_stderr_fd b 0 (Bytes.length b))
      with _ -> ());
      (* Write to log *)
      open_log ();
      (match !log_fd with
       | None -> ()
       | Some fd ->
           rotate_if_needed fd;
           (match !log_fd with
            | None -> ()
            | Some fd2 ->
                let s = line ^ "\n" in
                (try ignore (Unix.write fd2 (Bytes.of_string s) 0 (String.length s))
                 with _ -> ())))
    in
    (try
      while true do
        let ready, _, _ = Unix.select [ pipe_read_fd; stop_read_fd ] [] [] (-1.) in
        if List.mem stop_read_fd ready then raise Exit;
        if List.mem pipe_read_fd ready then begin
          let n = Unix.read pipe_read_fd chunk 0 (Bytes.length chunk) in
          if n = 0 then raise Exit;
          let s = Bytes.sub_string chunk 0 n in
          Buffer.add_string buf s;
          (* Flush complete lines *)
          let content = Buffer.contents buf in
          let lines = String.split_on_char '\n' content in
          let rec flush_lines = function
            | [] -> ()
            | [ partial ] -> Buffer.clear buf; Buffer.add_string buf partial
            | line :: rest -> flush_line line; flush_lines rest
          in
          flush_lines lines
        end
      done
    with _ -> ());
    (* Flush remainder *)
    let rest = Buffer.contents buf in
    if rest <> "" then flush_line rest;
    Unix.close stop_read_fd;
    Unix.close pipe_read_fd;
    (match !log_fd with Some fd -> Unix.close fd | None -> ())
  ) () in
  (pipe_write_fd, stop_write_fd, tee_thread)

let signal_name n =
  if n = Sys.sigterm then "term"
  else if n = Sys.sigkill then "kill"
  else if n = Sys.sighup then "hup"
  else if n = Sys.sigint then "int"
  else if n = Sys.sigusr1 then "usr1"
  else if n = Sys.sigusr2 then "usr2"
  else if n = Sys.sigpipe then "pipe"
  else if n = Sys.sigalrm then "alrm"
  else if n = Sys.sigchld then "chld"
  else if n = Sys.sigsegv then "segv"
  else if n = Sys.sigabrt then "abrt"
  else Printf.sprintf "sig%d" n

(* Append a death record when inner client exits non-zero. *)
let record_death ~broker_root ~name ~client ~exit_code ~duration_s ~inst_dir =
  let log_path = inst_dir // "stderr.log" in
  let last_lines =
    try
      let ic = open_in log_path in
      let lines = ref [] in
      (try while true do
        lines := input_line ic :: !lines
      done with End_of_file -> ());
      close_in ic;
      let all = List.rev !lines in
      let n = List.length all in
      let skip = max 0 (n - 50) in
      let rec drop i lst = match lst with [] -> [] | _ :: t -> if i > 0 then drop (i-1) t else lst in
      drop skip all
    with _ -> []
  in
  let ts = Unix.gettimeofday () in
  let entry = `Assoc
    [ ("ts", `Float ts)
    ; ("name", `String name)
    ; ("client", `String client)
    ; ("exit_code", `Int exit_code)
    ; ("duration_s", `Float duration_s)
    ; ("last_stderr", `List (List.map (fun l -> `String l) last_lines))
    ] in
  let path = deaths_jsonl_path broker_root in
  (try
    let oc = open_out_gen [ Open_wronly; Open_creat; Open_append ] 0o644 path in
    output_string oc (Yojson.Safe.to_string entry);
    output_char oc '\n';
    close_out oc
  with _ -> ())

(* alias word pool lives in [C2c_alias_words] (#388 — converged from
   the duplicated 128-entry literal previously inlined here and in
   cli/c2c_setup.ml). *)

let generate_alias () =
  let () = Random.self_init () in
  let words = C2c_alias_words.words in
  let n = Array.length words in
  let rec loop () =
    let w1 = words.(Random.int n) in
    let w2 = words.(Random.int n) in
    if w1 = w2 then loop () else Printf.sprintf "%s-%s" w1 w2
  in
  loop ()

let default_name _client =
  (* #277: drop the "<client>-" prefix; the random word pair is already
     unique enough and the prefix added noise to instance/alias display. *)
  generate_alias ()

(* ---------------------------------------------------------------------------
 * Broker root
 * --------------------------------------------------------------------------- *)

let git_common_dir () =
  try
    let ic = Unix.open_process_in "git rev-parse --git-common-dir 2>/dev/null" in
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
      (fun () -> String.trim (input_line ic))
  with _ -> ""

(* Delegates to C2c_repo_fp.resolve_broker_root for the authoritative implementation.
   Uses Digestif.SHA256 for repo fingerprint (same as C2c_utils). *)
let resolve_broker_root () = C2c_repo_fp.resolve_broker_root ()

let broker_root () = resolve_broker_root ()

(* ---------------------------------------------------------------------------
 * Instance config persistence
 * --------------------------------------------------------------------------- *)

type instance_config = {
  name : string;
  client : string;
  session_id : string;
  resume_session_id : string;
  codex_resume_target : string option;
  alias : string;
  extra_args : string list;
  created_at : float;
  last_launch_at : float option;
  last_exit_code : int option;
  last_exit_reason : string option;
  broker_root : string;
  auto_join_rooms : string;
  binary_override : string option;
  model_override : string option;
  agent_name : string option;
}

let write_config (cfg : instance_config) =
  let dir = instance_dir cfg.name in
  mkdir_p dir;
  let path = config_path cfg.name in
  (* #504: skip persisting broker_root when it equals the resolver default.
     Persisting verbatim is what pinned the swarm to stale fingerprints across
     migrations: once `broker_root` is in the saved config, the resume path
     re-injects it into env even after the wrapper / .mcp.json env has been
     scrubbed, silently overriding the resolver. By only persisting when the
     value differs from the current default, drift can't accumulate across
     re-launches; intentional overrides still round-trip. *)
  let resolver_default = try resolve_broker_root () with _ -> "" in
  let broker_root_field =
    if cfg.broker_root = "" || cfg.broker_root = resolver_default then []
    else [ ("broker_root", `String cfg.broker_root) ]
  in
  let fields =
    [ ("name", `String cfg.name)
    ; ("client", `String cfg.client)
    ; ("session_id", `String cfg.session_id)
    ; ("resume_session_id", `String cfg.resume_session_id)
    ; ("alias", `String cfg.alias)
    ; ("extra_args", `List (List.map (fun s -> `String s) cfg.extra_args))
    ; ("created_at", `Float cfg.created_at) ]
    @ broker_root_field
    @ [ ("auto_join_rooms", `String cfg.auto_join_rooms) ]
    @
    (match cfg.last_launch_at with
     | Some t -> [ ("last_launch_at", `Float t) ]
     | None -> [])
    @
    (match cfg.codex_resume_target with
     | Some sid -> [ ("codex_resume_target", `String sid) ]
     | None -> [])
    @
    (match cfg.binary_override with
     | Some b -> [ ("binary_override", `String b) ]
     | None -> [])
    @
    (match cfg.model_override with
     | Some m -> [ ("model_override", `String m) ]
     | None -> [])
    @
    (match cfg.agent_name with
     | Some n -> [ ("agent_name", `String n) ]
     | None -> [])
    @
    (match cfg.last_exit_code with
     | Some c -> [ ("last_exit_code", `Int c) ]
     | None -> [])
    @
    (match cfg.last_exit_reason with
     | Some r -> [ ("last_exit_reason", `String r) ]
     | None -> [])
  in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () ->
      Yojson.Safe.pretty_to_channel oc (`Assoc fields);
      output_string oc "\n")

let load_config_opt (name : string) : instance_config option =
  let path = config_path name in
  if not (Sys.file_exists path) then None
  else
    match C2c_io.read_json_opt path with
    | None -> None
    | Some json ->
        let a = match json with `Assoc a -> a | _ -> raise Not_found in
        let gs k = match List.assoc_opt k a with Some (`String s) -> s | _ -> raise Not_found in
        let gso k = match List.assoc_opt k a with Some (`String s) -> Some s | _ -> None in
        let gf k = match List.assoc_opt k a with Some (`Float f) -> f | Some (`Int i) -> float_of_int i | _ -> raise Not_found in
        let gfo k = match List.assoc_opt k a with Some (`Float f) -> Some f | Some (`Int i) -> Some (float_of_int i) | _ -> None in
        let gio k = match List.assoc_opt k a with Some (`Int i) -> Some i | _ -> None in
        let gl k = match List.assoc_opt k a with Some (`List l) -> List.map (function `String s -> s | _ -> raise Not_found) l | _ -> [] in
        (* #504 + #501: broker_root is optional in the persisted config
           (post-migration write_config skips it when == resolver default).
           When absent or empty at load time, fall back to the resolver's
           canonical default — env > XDG > $HOME/.c2c/repos/<fp>/broker —
           preventing the stale-fingerprint drift that pinned peers to old
           broker roots across migrations. *)
        let broker_root_loaded =
          match gso "broker_root" with
          | Some s when s <> "" -> s
          | _ -> (try resolve_broker_root () with _ -> "")
        in
        Some { name = gs "name"; client = gs "client"; session_id = gs "session_id";
               resume_session_id = gs "resume_session_id"; codex_resume_target = gso "codex_resume_target"; alias = gs "alias";
               extra_args = gl "extra_args"; created_at = gf "created_at"; last_launch_at = gfo "last_launch_at";
               broker_root = broker_root_loaded; auto_join_rooms = gs "auto_join_rooms";
               binary_override = gso "binary_override";
               model_override = gso "model_override";
               agent_name = gso "agent_name";
               last_exit_code = gio "last_exit_code";
               last_exit_reason = gso "last_exit_reason" }

(* Resolve effective extra_args on (re-)launch.

   #471: a previous run of `c2c start <client> -n NAME -- ARGS` persists
   ARGS to the instance config. If the operator next invokes
   `c2c start <client> -n NAME` with NO trailing `--`, we must NOT silently
   re-apply the persisted ARGS — that's how a one-off bad invocation
   ("--prompt eaten by argv parser") becomes a sticky boot loop.

   Option A: a plain re-launch (cli_extra_args = []) always means
   "no extra args this time". Persisted extra_args are only honored
   when the operator passes the same `--` ARGS again. To override,
   pass `-- --foo bar` (replaces) or pass nothing (clears). *)
let resolve_effective_extra_args
    ~(cli_extra_args : string list)
    ~(persisted_extra_args : string list) : string list =
  ignore persisted_extra_args;
  cli_extra_args

(* Resolve effective extra_args on (re-)launch.

   #471: a previous run of `c2c start <client> -n NAME -- ARGS` persists
   ARGS to the instance config. If the operator next invokes
   `c2c start <client> -n NAME` with NO trailing `--`, we must NOT silently
   re-apply the persisted ARGS — that's how a one-off bad invocation
   ("--prompt eaten by argv parser") becomes a sticky boot loop.

   Option A: a plain re-launch (cli_extra_args = []) always means
   "no extra args this time". Persisted extra_args are only honored
   when the operator passes the same `--` ARGS again. To override,
   pass `-- --foo bar` (replaces) or pass nothing (clears). *)
let resolve_effective_extra_args
    ~(cli_extra_args : string list)
    ~(persisted_extra_args : string list) : string list =
  ignore persisted_extra_args;
  cli_extra_args

let load_config (name : string) : instance_config =
  match load_config_opt name with
  | Some cfg -> cfg
  | None ->
      Printf.eprintf "error: config not found for instance '%s'\n%!" name;
      exit 1

(** [#159 Slice C] After a successful broker register with a new alias, scan all
    instance configs and update any whose [session_id] matches the given
    [session_id] to use the new [alias]. This prevents stale-alias drift on
    restart. *)
let sync_instance_alias ~(session_id : string) ~(alias : string) : unit =
  let entries =
    try Array.to_list (Sys.readdir instances_dir) with _ -> []
  in
  List.iter
    (fun name ->
       let full = Filename.concat instances_dir name in
       try
         if Sys.is_directory full && Sys.file_exists (Filename.concat full "config.json") then
           match load_config_opt name with
           | None -> ()
           | Some cfg when cfg.session_id = session_id && cfg.alias <> alias ->
               write_config { cfg with alias }
           | _ -> ()
       with Not_found | Sys_error _ -> ())
    entries

let persist_headless_thread_id ~(name : string) ~(thread_id : string) : unit =
  match load_config_opt name with
  | None -> ()
  | Some cfg ->
      write_config { cfg with resume_session_id = thread_id }

(* ---------------------------------------------------------------------------
 * Process utilities
 * --------------------------------------------------------------------------- *)

let pid_alive (pid : int) : bool =
  try Unix.kill pid 0; true with Unix.Unix_error _ -> false

let read_pid (path : string) : int option =
  try
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in ic)
      (fun () -> int_of_string_opt (String.trim (input_line ic)))
  with _ -> None

let write_pid (path : string) (pid : int) =
  let dir = Filename.dirname path in
  mkdir_p dir;
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc (Printf.sprintf "%d\n" pid))

let remove_pidfile (path : string) =
  try Sys.remove path with Unix.Unix_error _ | Sys_error _ -> ()

(* ---------------------------------------------------------------------------
 * Instance lock  — prevents two concurrent `c2c start` for the same name.
 * Uses POSIX advisory record locks (lockf F_TLOCK via OCaml Unix.lockf).
 * The kernel releases the lock automatically on process exit / crash, so
 * no stale-lock cleanup is needed.
 * --------------------------------------------------------------------------- *)

(** Registry precheck: if the alias/session-id is already alive in the broker
    registry, print a human-readable FATAL message and exit 1.  Called before
    the flock so the common-case error says "alias foo is alive" rather than
    the more opaque "lock held". *)
let check_registry_alias_alive ~(broker_root : string) ~(name : string) : unit =
  let reg_path = broker_root // "registry.json" in
  if not (Sys.file_exists reg_path) then ()
  else begin
    match (try Some (Yojson.Safe.from_file reg_path) with _ -> None) with
    | None -> ()
    | Some (`List regs) ->
        let alive_entry =
          List.find_opt (fun r ->
            match r with
            | `Assoc fields ->
                let sid   = (match List.assoc_opt "session_id" fields with Some (`String s) -> s | _ -> "") in
                let alias = (match List.assoc_opt "alias"      fields with Some (`String a) -> a | _ -> "") in
                (sid = name || alias = name) &&
                (match List.assoc_opt "pid" fields with Some (`Int p) -> pid_alive p | _ -> false)
            | _ -> false) regs
        in
        (match alive_entry with
         | None -> ()
         | Some (`Assoc fields) ->
             let alias = (match List.assoc_opt "alias" fields with Some (`String a) -> a | _ -> name) in
             let pid_s = (match List.assoc_opt "pid" fields with Some (`Int p) -> string_of_int p | _ -> "unknown") in
             Printf.eprintf
               "FATAL: alias '%s' is already alive in registry (pid %s).\n\
                \  Stop it first:  c2c stop %s\n%!"
               alias pid_s name;
             exit 1
         | _ -> ())
    | _ -> ()
  end

(** Acquire an exclusive POSIX advisory lock on `outer_pid_path name`.
    Writes our PID into the file.  Returns the open fd — caller MUST keep it
    referenced for the lifetime of the outer process (closing it releases the
    lock; the kernel does so automatically on process exit).
    On conflict, prints FATAL and exits 1 immediately. *)
let acquire_instance_lock ~(name : string) : Unix.file_descr =
  let path = outer_pid_path name in
  mkdir_p (Filename.dirname path);
  let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT ] 0o644 in
  match Unix.lockf fd Unix.F_TLOCK 0 with
  | () ->
      (* Lock acquired: truncate and write our PID. *)
      Unix.ftruncate fd 0;
      let s = string_of_int (Unix.getpid ()) ^ "\n" in
      ignore (Unix.write_substring fd s 0 (String.length s));
      fd
  | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES | Unix.EWOULDBLOCK), _, _) ->
      (* Another process holds the lock — read their PID for diagnostics. *)
      let existing_pid =
        try
          ignore (Unix.lseek fd 0 Unix.SEEK_SET);
          let buf = Bytes.create 32 in
          let n = Unix.read fd buf 0 32 in
          int_of_string_opt (String.trim (Bytes.sub_string buf 0 n))
        with _ -> None
      in
      Unix.close fd;
      Printf.eprintf
        "FATAL: instance '%s' already running (pid %s).\n\
         \  Stop it first:  c2c stop %s\n%!"
        name
        (Option.fold ~none:"unknown" ~some:string_of_int existing_pid)
        name;
      exit 1

let run_tmux_loop ~(name : string) ~(tmux_location : string)
    ~(tmux_command : string list) ~(broker_root : string)
    ?(alias_override : string option) ?(auto_join_rooms : string option) () : int =
  let loc = String.trim tmux_location in
  if loc = "" then begin
    Printf.eprintf "error: c2c start tmux requires --loc <tmux-target>\n%!";
    exit 1
  end;
  let target_info =
    match validate_tmux_target loc with
    | Some info -> info
    | None ->
        Printf.eprintf "error: tmux target %S not found or not accessible\n%!" loc;
        exit 1
  in
  let effective_alias = Option.value alias_override ~default:name in
  let inst_dir = instance_dir name in
  mkdir_p inst_dir;
  check_registry_alias_alive ~broker_root ~name;
  let _lock_fd = acquire_instance_lock ~name in
  write_pid (outer_pid_path name) (Unix.getpid ());
  write_tmux_target_info name target_info;
  let cleanup_and_exit code =
    remove_pidfile (outer_pid_path name);
    (try clear_registration_pid ~broker_root ~session_id:name with _ -> ());
    code
  in
  ignore (Sys.signal Sys.sigterm (Sys.Signal_handle (fun _ ->
      ignore (cleanup_and_exit 0);
      exit 0)));
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  C2c_mcp.Broker.register broker ~session_id:name ~alias:effective_alias
    ~pid:(Some (Unix.getpid ()))
    ~pid_start_time:(C2c_mcp.Broker.read_pid_start_time (Unix.getpid ()))
    ~client_type:(Some "tmux") ();
  let rooms =
    Option.value auto_join_rooms ~default:"swarm-lounge"
    |> String.split_on_char ','
    |> List.map String.trim
    |> List.filter ((<>) "")
  in
  List.iter
    (fun room_id ->
      try ignore (C2c_mcp.Broker.join_room broker ~room_id
                    ~alias:effective_alias ~session_id:name)
      with _ -> ())
    rooms;
  Printf.printf "[c2c-start/%s] tmux target=%s outer pid=%d\n%!"
    name target_info.tmux_location (Unix.getpid ());
  if tmux_command <> [] then begin
    Printf.printf "[c2c-start/%s] starting command in tmux target: %s\n%!"
      name (tmux_shell_command_of_argv tmux_command);
    if not (tmux_send_shell_command target_info.tmux_location tmux_command) then begin
      Printf.eprintf "error: failed to send startup command to tmux target %s\n%!"
        target_info.tmux_location;
      exit (cleanup_and_exit 1)
    end;
    (* #399: after launching, poll for the Claude dev-channel consent prompt
       and auto-answer it so `c2c start tmux` / `c2c restart claude` work
       unattended. The prompt appears after the MCP handshake begins.
       Give Claude a moment to start up before polling. *)
    Unix.sleepf 1.0;
    if auto_answer_dev_channel_prompt ~tmux_location:target_info.tmux_location then
      Printf.printf "[c2c-start/%s] dev-channel consent auto-answered\n%!" name
    else
      Printf.printf "[c2c-start/%s] dev-channel consent not detected (normal if not first launch)\n%!" name
  end;
  let rec loop () =
    match validate_tmux_target target_info.tmux_location with
    | None ->
        Printf.eprintf "[c2c-start/%s] tmux target disappeared: %s\n%!"
          name target_info.tmux_location;
        cleanup_and_exit 1
    | Some _ ->
        ignore (tmux_deliver_once ~broker_root ~session_id:name
                  ~target:target_info.tmux_location);
        Unix.sleepf 2.0;
        loop ()
  in
  loop ()

(* ---------------------------------------------------------------------------
 * Cleanup stale OpenUI Zig cache
 * --------------------------------------------------------------------------- *)

let cleanup_stale_opentui_zig_cache () : int =
  let tmp_dir = "/tmp" in
  let min_age = 300.0 in
  let now = Unix.gettimeofday () in
  let deleted = ref 0 in
  (try
     let entries = Sys.readdir tmp_dir in
     Array.iter
       (fun entry ->
         if String.length entry > 5
            && String.sub entry 0 4 = ".fea"
            && Filename.check_suffix entry ".so" then
           let path = tmp_dir // entry in
           (try
              let st = Unix.stat path in
              if now -. st.st_mtime >= min_age then (
                (try Sys.remove path with _ -> ());
                incr deleted
              )
            with _ -> ()))
       entries
   with _ -> ());
  !deleted

(* ---------------------------------------------------------------------------
 * Build environment
 * --------------------------------------------------------------------------- *)

let build_env ?(broker_root_override : string option = None)
    ?(auto_join_rooms_override : string option = None)
    ?(role_class_opt : string option = None)
    ?(client : string option = None)
    ?(reply_to_override : string option = None)
    ?(tmux_location : string option = None)
    (name : string) (alias_override : string option) : string array =
  let br = Option.value broker_root_override ~default:(broker_root ()) in
  (* Only set C2C_MCP_AUTO_JOIN_ROOMS when explicitly requested *)
  let auto_join_rooms =
    match Sys.getenv_opt "C2C_AUTO_JOIN_ROLE_ROOM", role_class_opt, auto_join_rooms_override with
    | Some "1", Some rc, _ when String.trim rc <> "" ->
        let role_room = C2c_role.role_class_to_room rc in
        (match role_room with
         | Some rr -> (match auto_join_rooms_override with
                       | Some "" -> Some rr
                       | Some existing -> Some (existing ^ "," ^ rr)
                       | None -> Some rr)
         | None -> auto_join_rooms_override)
    | _ -> auto_join_rooms_override
  in
  let auto_join_base = match auto_join_rooms with
    | Some "" -> []
    | Some rooms -> [ "C2C_MCP_AUTO_JOIN_ROOMS", rooms ]
    | None -> []
  in
  (* Resolve the absolute path of this c2c binary so the plugin always uses the
     correct OCaml binary even when a Python ./c2c shim exists in the project CWD
     (avoids fork-bomb: plugin runC2c() would otherwise resolve bare "c2c" via PATH
     which could pick up ./c2c if CWD is in PATH). *)
  let c2c_bin = current_c2c_command () in
  let enable_git_shim = repo_config_git_attribution () in
  let client_session_additions =
    match client with
    | Some "claude" -> [ "CLAUDE_CODE_PARENT_SESSION_ID", name ]
    | Some "opencode" -> [ "OPENCODE_SESSION_ID", name ]
    | Some "kimi" -> [ "KIMI_SESSION_ID", name ]
    | Some "crush" -> [ "CRUSH_SESSION_ID", name ]
    | _ -> []
  in
  let additions =
    let alias = Option.value alias_override ~default:name in
    let base = [
    "C2C_WRAPPER_SELF", "1";  (* marks the wrapper process itself; bash subshells of the managed client don't inherit this *)
    "C2C_MCP_SESSION_ID", name;
    "C2C_INSTANCE_NAME", name;
    "C2C_MCP_AUTO_REGISTER_ALIAS", alias;
    "C2C_MCP_BROKER_ROOT", br;
    "C2C_MCP_AUTO_DRAIN_CHANNEL", "0";
    (* Managed sessions opt in to experimental channel-delivery. No-op on
       clients that don't declare experimental.claude/channel in initialize,
       so harmless where unsupported. *)
    "C2C_MCP_CHANNEL_DELIVERY", "1";
    (* Per-instance git author identity (#467). Sets the standard git
       env-var overrides so any git invocation from inside the managed
       session attributes commits to <alias>, regardless of whether the
       c2c-git shim is reachable on PATH. Belt-and-suspenders alongside
       the shim (#462): the shim handles `git commit` via PATH lookup,
       these env vars handle the case where the shim is bypassed (e.g.
       /usr/bin/git, kimi's bash tool with stripped PATH, sandboxed
       subprocess). Closes the slate-coder author misattribution that
       affected every kimi self-authored commit before the notifier
       slice (`b6455d8e`, `cb740ecf`, `664c2281`). *)
    "GIT_AUTHOR_NAME", alias;
    "GIT_AUTHOR_EMAIL", alias ^ "@c2c.im";
    "GIT_COMMITTER_NAME", alias;
    "GIT_COMMITTER_EMAIL", alias ^ "@c2c.im";
    (* S6c: tell the MCP server child to run its own Lwt schedule timer,
       which reads .c2c/schedules/<alias>/ and fires via C2c_schedule_fire.
       The parent (c2c start) also sets this in its own env so
       mcp_schedule_timer_active() returns true → skip the schedule watcher
       thread, avoiding duplicate heartbeats. *)
    "C2C_MCP_SCHEDULE_TIMER", "1";
    ] in
    let base = base @ auto_join_base in
    let base = base @ match reply_to_override with
      | Some r -> [ "C2C_MCP_REPLY_TO", r ]
      | None -> [] in
    (* #517: tmux session:window.pane target for this managed session.
       Read from the per-instance tmux.json written at startup so the inner
       MCP server can include it in its registration. *)
    let base = base @ match tmux_location with
      | Some loc -> [ "C2C_TMUX_LOCATION", loc ]
      | None -> [] in
    let base =
      if client = Some "claude" then
        (* For claude managed sessions, force claude_channel capability so
           channel-push works without requiring the client to advertise
           experimental.claude/channel in its initialize request. *)
        base @ [ "C2C_MCP_FORCE_CAPABILITIES", "claude_channel" ]
      else
        base
    in
    let base = base @ [ "C2C_CLI_COMMAND", c2c_bin ] in
    let base = base @ client_session_additions in
    if enable_git_shim then
      let shim_bin_dir = instance_dir name // "bin" in
      base @ [ "C2C_GIT_SHIM_DIR", shim_bin_dir ]
    else
      base
  in
  (* Strip any existing copies of overridden keys from the inherited env, then
     append our authoritative values. This avoids the duplicate-key bug where
     both the parent's C2C_MCP_SESSION_ID and the child's appear in the array
     (previously a buggy in-place replacement left both copies).
     Also strip CLAUDE_SESSION_ID: when starting a new managed session, the child
     should create a fresh session rather than inheriting the parent's. *)
  let legacy_native_session_keys =
    [ "CLAUDE_SESSION_ID"; "CODEX_SESSION_ID"; "CODEX_THREAD_ID"; "OPENCODE_SESSION_ID";
      "KIMI_SESSION_ID"; "CRUSH_SESSION_ID" ]
  in
  (* Always strip C2C_MCP_FORCE_CAPABILITIES from inherited env. For
     client="claude" we re-add it via `additions` above; for any other client
     we want it gone so claude-only capabilities don't leak from the parent
     shell into Codex/OpenCode/Kimi/Crush managed sessions. *)
  let override_keys =
    ("C2C_MCP_FORCE_CAPABILITIES" :: legacy_native_session_keys)
    @ ("C2C_GIT_SHIM_ACTIVE" :: List.map fst additions)
  in
  let env_key e =
    try String.sub e 0 (String.index e '=') with Not_found -> e
  in
  let filtered = Array.to_list (Unix.environment ())
    |> List.filter (fun e -> not (List.mem (env_key e) override_keys))
  in
  let filtered =
    if enable_git_shim then List.filter (fun e -> env_key e <> "PATH") filtered
    else filtered
  in
  let new_entries = List.map (fun (k, v) -> Printf.sprintf "%s=%s" k v) additions in
  if enable_git_shim then
    (* #462: prepend the canonical swarm-wide shim dir, with the
       per-instance dir as defense-in-depth (covers configurations
       where the swarm dir was unwritable / removed underfoot). *)
    let swarm_shim_dir = swarm_git_shim_dir () in
    let inst_shim_dir = instance_dir name // "bin" in
    let existing_path =
      match Sys.getenv_opt "PATH" with
      | Some path -> path
      | None -> ""
    in
    let path_entry =
      "PATH=" ^ swarm_shim_dir ^ ":" ^ inst_shim_dir ^
      (if existing_path <> "" then ":" ^ existing_path else "")
    in
    Array.of_list ((path_entry :: filtered) @ new_entries)
  else
    Array.of_list (filtered @ new_entries)

(* ---------------------------------------------------------------------------
 * OpenCode identity files refresh
 * Ensures .opencode/opencode.json and .opencode/c2c-plugin.json have the
 * correct session_id + alias for this managed instance before launch.
 * Called by start_inner when client = "opencode".
 * --------------------------------------------------------------------------- *)

let refresh_opencode_identity ~name ~alias ~broker_root ~project_dir ~instances_dir
    ~agent_name =
  let module A = (val (Stdlib.Hashtbl.find client_adapters "opencode") : CLIENT_ADAPTER) in
  A.refresh_identity ~name ~alias ~broker_root ~project_dir ~instances_dir ~agent_name

(* ---------------------------------------------------------------------------
 * Kimi MCP config generation
 * --------------------------------------------------------------------------- *)

let kimi_mcp_config_path (name : string) : string =
  instance_dir name // "kimi-mcp.json"

let has_explicit_kimi_mcp_config (extra_args : string list) : bool =
  List.exists
    (fun arg ->
      List.mem arg [ "--mcp-config-file"; "--mcp-config" ]
      || (String.length arg > 14 && String.sub arg 0 14 = "--mcp-config=")
      || (String.length arg > 20 && String.sub arg 0 20 = "--mcp-config-file="))
    extra_args

let repo_toplevel () : string =
  try
    let ic = Unix.open_process_in "git rev-parse --show-toplevel 2>/dev/null" in
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
      (fun () -> String.trim (input_line ic))
  with _ -> ""

(* Fallback: derive repo root from a broker_root like "/path/to/repo/.git/c2c/mcp".
   Used when c2c_start is running in the instance dir (no git context). *)
let repo_toplevel_from_broker (broker_root : string) : string =
  let suffix = "/.git/c2c/mcp" in
  let bl = String.length broker_root and sl = String.length suffix in
  if bl > sl && String.sub broker_root (bl - sl) sl = suffix
  then String.sub broker_root 0 (bl - sl)
  else ""

(* Resolve the repo root: cwd-based first (works when called from the repo),
   then broker_root-derived (works from the instance dir outer loop). *)
let resolve_repo_root ~(broker_root : string) : string =
  let a = repo_toplevel () in
  if a <> "" then a
  else repo_toplevel_from_broker broker_root

let build_kimi_mcp_config (name : string) (br : string) (alias_override : string option) : Yojson.Safe.t =
  let alias = Option.value alias_override ~default:name in
  (* #479: derive from C2c_mcp.base_tool_names (single source of truth).
     Previously hand-maintained — see #478 comment. *)
  let c2c_mcp_tools =
    List.map (fun name -> "mcp__c2c__" ^ name) C2c_mcp.base_tool_names
  in
  (* Drift-prevention (kimi-mcp-canonical-server, follow-up to #504):
     omit C2C_MCP_BROKER_ROOT from the env block when it equals the
     resolver default. Same rule as write_config in #504 — persisting
     the resolver-default value re-injects stale paths after future
     migrations. Only persist when the operator explicitly overrode.
     Additionally, add broker_root_source so the receiving MCP server
     knows how to interpret the absent field:
       "resolver"  = broker_root was default; re-resolve at startup
       "override"  = broker_root was explicitly set; use C2C_MCP_BROKER_ROOT *)
  let resolver_default = try resolve_broker_root () with _ -> "" in
  let env_pairs =
    let base = [
      "C2C_MCP_SESSION_ID", `String name;
      "C2C_MCP_AUTO_REGISTER_ALIAS", `String alias;
      "C2C_MCP_AUTO_JOIN_ROOMS", `String "swarm-lounge";
      "C2C_MCP_AUTO_DRAIN_CHANNEL", `String "0";
    ] in
    if br = "" || br = resolver_default
    then ("broker_root_source", `String "resolver") :: base
    else
      ("C2C_MCP_BROKER_ROOT", `String br)
      :: ("broker_root_source", `String "override") :: base
  in
  `Assoc [ "mcpServers",
    `Assoc [ "c2c",
      `Assoc [ "type", `String "stdio";
               (* Canonical OCaml MCP server (was: python3 c2c_mcp.py — deprecated). *)
               "command", `String "c2c-mcp-server";
               "args", `List [];
               "env", `Assoc env_pairs;
               "allowedTools", `List (List.map (fun t -> `String t) c2c_mcp_tools) ] ] ]

(* ---------------------------------------------------------------------------
 * Claude session-file probe
 *
 * Claude stores conversations at ~/.claude/projects/<project-slug>/<uuid>.jsonl.
 * The slug is derived from cwd, so we don't know it up front — just scan every
 * project dir for <uuid>.jsonl. Cheap: one readdir of ~/.claude/projects plus
 * one stat per subdir.
 * --------------------------------------------------------------------------- *)

let claude_session_exists uuid =
  let probe_root root =
    if not (Sys.file_exists root) then false
    else
      try
        let entries = Sys.readdir root in
        Array.exists (fun slug ->
          Sys.file_exists (root // slug // (uuid ^ ".jsonl"))
        ) entries
      with _ -> false
  in
  let default_root = home_dir () // ".claude" // "projects" in
  let custom_root =
    try Some (Sys.getenv "CLAUDE_CONFIG_DIR" // "projects")
    with Not_found -> None
  in
  probe_root default_root ||
    (match custom_root with
     | Some root -> probe_root root
     | None -> false)

(* ---------------------------------------------------------------------------
 * Launch argument preparation
   * --------------------------------------------------------------------------- *)
let prepare_launch_args ~(name : string) ~(client : string)
    ~(extra_args : string list) ~(broker_root : string)
    ?(alias_override : string option) ?(resume_session_id : string option)
    ?(binary_override : string option) ?(model_override : string option)
    ?(codex_xml_input_fd : string option)
    ?(codex_resume_target : string option)
    ?(thread_id_fd : string option)
    ?(server_request_events_fd : string option)
    ?(server_request_responses_fd : string option)
    ?(agent_name : string option)
    ?(kickoff_prompt : string option) () : string list =
  let args =
    match client with
    | "claude" ->
        (* Dispatch to ClaudeAdapter; agent_name and kickoff_prompt are appended
           here since they are not in the adapter interface. *)
        let module A = (val (Stdlib.Hashtbl.find client_adapters "claude") : CLIENT_ADAPTER) in
        let agent_args =
          match agent_name with
          | Some n -> [ "--agent"; n ]
          | None -> []
        in
        let kickoff_args =
          match kickoff_prompt with
          | Some p when p <> "" && resume_session_id = None -> [ p ]
          | _ -> []
        in
        (A.build_start_args ~name ?alias_override ?model_override ?resume_session_id ())
        @ agent_args @ kickoff_args
    | "opencode" ->
        let module A = (val (Stdlib.Hashtbl.find client_adapters "opencode") : CLIENT_ADAPTER) in
        (* The compiled agent file is written at .opencode/agents/<name>.md
           (instance name), so opencode's --agent flag must resolve to the
           instance name (= compiled-file basename), not the role name. *)
        let agent_args = match agent_name with Some _ -> [ "--agent"; name ] | None -> [] in
        A.build_start_args ~name ?alias_override ?model_override ?resume_session_id ()
        @ agent_args
    | "codex" ->
        (* Normalise the two resume signals into the single resume_session_id understood
           by CodexAdapter: non-empty = specific session; "" = resume --last; None = fresh. *)
        let module A = (val (Stdlib.Hashtbl.find client_adapters "codex") : CLIENT_ADAPTER) in
        let eff_resume =
          match codex_resume_target with
          | Some sid when String.trim sid <> "" -> Some sid
          | _ -> (match resume_session_id with Some _ -> Some "" | None -> None)
        in
        A.build_start_args ~name ?alias_override ?model_override
          ?resume_session_id:eff_resume ()
    | "kimi" ->
        (* KimiAdapter writes the per-instance MCP config and prepends the flag.
           Pass extra_args so the adapter can detect an already-present --mcp-config-file;
           extra_args are NOT consumed by the adapter (prepare_launch_args appends them
           uniformly at the end, so they won't be doubled).

           kickoff_prompt is for fresh spawns only; resumes pick up the existing session
           without re-injection.  On resume (resume_session_id = Some _), kimi-cli
           interprets --prompt as a finite work cycle — it processes the kickoff items,
           completes them, then exits code=0, killing the managed session.  Suppress the
           flag entirely on resume. *)
        let module A = (val (Stdlib.Hashtbl.find client_adapters "kimi") : CLIENT_ADAPTER) in
        let prompt_args =
          match resume_session_id with
          | Some _ -> []  (* resuming — don't re-kickoff; session already has instructions *)
          | None ->
            match kickoff_prompt with
            | Some p when p <> "" -> [ "--prompt"; p ]
            | _ -> []
        in
        let agent_file_args =
          match agent_name with
          | Some n -> [ "--agent-file"; C2c_role.kimi_agent_yaml_path ~name:n ]
          | None -> []
        in
        A.build_start_args ~name ?alias_override ?model_override ?resume_session_id
          ~extra_args:extra_args ()
        @ prompt_args @ agent_file_args
    | "gemini" ->
        (* #406b: GeminiAdapter handles --resume <idx>|latest, --model. No
           dev-channels or PTY auto-answer (Gemini uses settings.json
           `trust: true` instead of an interactive consent prompt). *)
        let module A = (val (Stdlib.Hashtbl.find client_adapters "gemini") : CLIENT_ADAPTER) in
        (* #143d: kickoff_prompt as positional trailing arg, fresh spawn only *)
        let prompt_args =
          match resume_session_id with
          | Some _ -> []  (* resuming — don't re-kickoff *)
          | None ->
            match kickoff_prompt with
            | Some p when p <> "" -> [ p ]
            | _ -> []
        in
        A.build_start_args ~name ?alias_override ?model_override ?resume_session_id ()
        @ prompt_args
    | "codex-headless" ->
        [ "--stdin-format"; "xml";
          "--codex-bin"; "codex";
          (* approval-policy=on-request: bridge forwards permission events via
             --server-request-events-fd (fd 6) and reads decisions from
             --server-request-responses-fd (fd 7). The deliver daemon handles
             the full supervisor round-trip and writes the response back. *)
          "--approval-policy"; "on-request" ]
        @ (match codex_resume_target with
           | Some sid when String.trim sid <> "" -> [ "--thread-id"; sid ]
           | _ ->
               (match resume_session_id with
                | Some sid when String.trim sid <> "" -> [ "--thread-id"; sid ]
                | _ -> []))
        @ (match thread_id_fd with
           | Some fd -> [ "--thread-id-fd"; fd ]
           | None -> [])
        @ (match server_request_events_fd with
           | Some fd -> [ "--server-request-events-fd"; fd ]
           | None -> [])
        @ (match server_request_responses_fd with
           | Some fd -> [ "--server-request-responses-fd"; fd ]
           | None -> [])
    | _ -> []
  in
  let args =
    match client with
    | "codex" ->
        (match server_request_events_fd with
         | Some fd -> [ "--server-request-events-fd"; fd ]
         | None -> [])
        @ (match server_request_responses_fd with
           | Some fd -> [ "--server-request-responses-fd"; fd ]
           | None -> [])
        @ args
    | _ -> args
  in
  (* Adapter-dispatched clients apply model_override internally; skip the
     generic append here to avoid passing --model twice. *)
  let args =
    if Stdlib.Hashtbl.mem client_adapters client then args
    else
      match model_override with
      | Some model when String.trim model <> "" -> args @ [ "--model"; model ]
      | _ -> args
  in
  let args =
    match client, codex_xml_input_fd with
    | "codex", Some fd -> [ "--xml-input-fd"; fd ] @ args
    | _ -> args
  in
  args @ extra_args

(* ---------------------------------------------------------------------------
 * Binary lookup
 * --------------------------------------------------------------------------- *)

let find_binary (name : string) : string option =
  (* Absolute path: use directly without PATH search. *)
  if String.length name > 0 && name.[0] = '/' then
    (if Sys.file_exists name then
       (try Unix.access name [ Unix.X_OK ]; Some name with _ -> None)
     else None)
  else
  let path = try Sys.getenv "PATH" with Not_found -> "" in
  let rec search dirs =
    match dirs with
    | [] -> None
    | dir :: rest ->
        let full = dir // name in
        if Sys.file_exists full then
          (try Unix.access full [ Unix.X_OK ]; Some full with _ -> search rest)
        else search rest
  in
  search (String.split_on_char ':' path)

(* Detect cc- profile wrapper scripts (cc-mm, cc-w, cc-zai, etc.).
   These are designed to be called directly without extra args, not via
   c2c start --bin which passes 'start <name> --resume <sid> --name <name>'.
   For cc- wrappers, we invoke them directly so they manage their own session. *)
let is_cc_wrapper (binary_path : string) : bool =
  let basename = Filename.basename binary_path in
  String.length basename >= 3 && String.sub basename 0 3 = "cc-"
let is_cc_wrapper_str (name : string) : bool =
  String.length name >= 3 && String.sub name 0 3 = "cc-"

(* ---------------------------------------------------------------------------
 * Sidecar script paths
 * --------------------------------------------------------------------------- *)

let deliver_command ~(broker_root : string) : (string * string list) option =
  (* OCaml c2c-deliver-inbox is the only supported delivery daemon.
     Python fallback is deprecated and removed. *)
  Option.map (fun path -> (path, [])) (find_binary "c2c-deliver-inbox")

let command_help_contains (binary_path : string) (needle : string) : bool =
  let contains needle haystack =
    let nlen = String.length needle
    and hlen = String.length haystack in
    let rec loop i =
      if i + nlen > hlen then false
      else if String.sub haystack i nlen = needle then true
      else loop (i + 1)
    in
    loop 0
  in
  try
    let cmd = Printf.sprintf "%s --help 2>/dev/null" (Filename.quote binary_path) in
    let ic = Unix.open_process_in cmd in
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
      (fun () ->
        let found = ref false in
        (try
           while not !found do
             let line = input_line ic in
             if contains needle line then found := true
           done
         with End_of_file -> ());
        !found)
  with _ -> false

let codex_supports_xml_input_fd (binary_path : string) : bool =
  command_help_contains binary_path "--xml-input-fd"

let codex_supports_server_request_fds (binary_path : string) : bool =
  command_help_contains binary_path "--server-request-events-fd"
  && command_help_contains binary_path "--server-request-responses-fd"

let bridge_supports_thread_id_fd (binary_path : string) : bool =
  command_help_contains binary_path "--thread-id-fd"

type pty_inject_capability = [ `Ok | `Missing_cap of string | `Unknown ]

let read_first_line command =
  try
    let ic = Unix.open_process_in command in
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
      (fun () ->
        try Some (String.trim (input_line ic))
        with End_of_file -> Some "")
  with _ -> None

let check_pty_inject_capability ?python_path ?yama_ptrace_scope ?getcap_output () :
    pty_inject_capability =
  let py =
    match python_path with
    | Some path -> path
    | None -> (
        match read_first_line "command -v python3 2>/dev/null" with
        | Some line when line <> "" -> line
        | _ -> "python3")
  in
  let yama_value =
    match yama_ptrace_scope with
    | Some value -> Some value
    | None ->
        (try
           let ic = open_in "/proc/sys/kernel/yama/ptrace_scope" in
           Some
             (Fun.protect ~finally:(fun () -> close_in ic)
                (fun () -> String.trim (input_line ic)))
         with _ -> None)
  in
  match yama_value with
  | Some "0" -> `Ok
  | Some _ | None ->
      let line =
        match getcap_output with
        | Some value -> Some value
        | None ->
            read_first_line
              (Printf.sprintf "getcap %s 2>/dev/null" (Filename.quote py))
      in
      let has_cap text =
        let needle = "cap_sys_ptrace" in
        let nl = String.length needle and ll = String.length text in
        let rec loop i =
          if i + nl > ll then false
          else if String.sub text i nl = needle then true
          else loop (i + 1)
        in
        loop 0
      in
      (match line with
       | Some "" -> `Missing_cap py
       | Some text when has_cap text -> `Ok
       | Some _ -> `Missing_cap py
       | None -> `Unknown)

let probed_capabilities ~(client : string) ~(binary_path : string) : string list =
  let open C2c_capability in
  let add_if cap enabled acc =
    if enabled then to_string cap :: acc else acc
  in
  let pty_inject_ok =
    match check_pty_inject_capability () with
    | `Ok -> true
    | `Missing_cap _ | `Unknown -> false
  in
  []
  |> add_if Claude_channel (client = "claude")
  |> add_if Opencode_plugin (client = "opencode")
  |> add_if Pty_inject
       (pty_inject_ok
        && List.mem client [ "claude"; "codex"; "opencode"; "crush" ])
  |> add_if Codex_xml_fd (client = "codex" && codex_supports_xml_input_fd binary_path)
  |> add_if Codex_headless_thread_id_fd
       (client = "codex-headless" && bridge_supports_thread_id_fd binary_path)
  |> List.rev

(* ---------------------------------------------------------------------------
 * Per-client adapter modules (Phase 2: claude + codex + kimi)
 *
 * All three satisfy CLIENT_ADAPTER.  model_override is applied inside the
 * adapter so the outer prepare_launch_args skips the generic model append for
 * adapter-dispatched clients (avoids the double-apply that would otherwise
 * occur — see the guard in prepare_launch_args below).
 * extra_args are NOT consumed by these adapters; prepare_launch_args appends
 * them uniformly after the adapter call, consistent with the opencode pattern.
 * --------------------------------------------------------------------------- *)

module ClaudeAdapter : CLIENT_ADAPTER = struct
  let name = "claude"
  let config_dir = ".claude"
  let agent_dir = "agents"
  let instances_subdir = "claude"

  let binary = "claude"
  let needs_deliver = false

  let needs_poker = false
  let poker_event = None
  let poker_from = None
  let extra_env = []
  let session_id_env = Some "CLAUDE_CODE_PARENT_SESSION_ID"

  let build_start_args ~name ?alias_override:_ ?model_override ?resume_session_id
      ?(extra_args = []) () =
    (* Note: agent_name and kickoff_prompt are not in the adapter interface.
       prepare_launch_args appends them as part of extra_args before calling here. *)
    ignore extra_args;
    let dev_channel_args =
      [ "--dangerously-load-development-channels"; "server:c2c" ]
    in
    let base =
      match resume_session_id with
      | Some sid ->
          let flag = if claude_session_exists sid then "--resume" else "--session-id" in
          [ flag; sid; "--name"; name ] @ dev_channel_args
      | None -> [ "--name"; name ] @ dev_channel_args
    in
    match model_override with
    | Some m when String.trim m <> "" -> base @ [ "--model"; m ]
    | _ -> base

  let refresh_identity ~name:_ ~alias:_ ~broker_root:_ ~project_dir:_ ~instances_dir:_
      ~agent_name:_ =
    (* Claude configures itself via C2C_MCP_* env vars injected at launch;
       no per-launch config-file update is required. *)
    ()

  let probe_capabilities ~binary_path:_ =
    (* claude_channel: always available for managed claude sessions.
       pty_inject: checked dynamically via check_pty_inject_capability in probed_capabilities. *)
    [ "claude_channel", true ]

  (* Argv-based delivery is handled in [build_start_args] /
     [prepare_launch_args] (see the "claude" branch which appends
     [kickoff_prompt] as a positional argv element).  This contract
     method exists to satisfy the CLIENT_ADAPTER signature uniformly;
     we deliberately do NOT re-route claude kickoff through it because
     positional-argv is already correct. *)
  let deliver_kickoff ~name:_ ~alias:_ ~kickoff_text:_ ?broker_root:_ () =
    Ok []
end

module CodexAdapter : CLIENT_ADAPTER = struct
  let name = "codex"
  let config_dir = ".codex"
  let agent_dir = ""   (* codex has no agent-dir concept *)
  let instances_subdir = "codex"

  let binary = "codex"
  let needs_deliver = true

  let needs_poker = false
  let poker_event = None
  let poker_from = None
  let extra_env = []
  let session_id_env = None   (* codex uses C2C_MCP_SESSION_ID directly *)

  let build_start_args ~name:_ ?alias_override:_ ?model_override ?resume_session_id
      ?(extra_args = []) () =
    (* Note: codex_xml_input_fd is not in the adapter interface; prepare_launch_args
       prepends [ "--xml-input-fd"; fd ] after the adapter call when needed.
       resume_session_id="" signals "resume --last" (generic resume);
       resume_session_id=<non-empty> is a specific codex session id. *)
    ignore extra_args;
    let base =
      match resume_session_id with
      | Some sid when String.trim sid <> "" -> [ "resume"; sid ]
      | Some _ -> [ "resume"; "--last" ]
      | None -> []
    in
    match model_override with
    | Some m when String.trim m <> "" -> base @ [ "--model"; m ]
    | _ -> base

  let refresh_identity ~name:_ ~alias:_ ~broker_root:_ ~project_dir:_ ~instances_dir:_
      ~agent_name:_ =
    (* Codex configures itself via C2C_MCP_* env vars and ~/.codex/config.toml
       written by c2c install codex; no per-launch refresh is needed. *)
    ()

  let probe_capabilities ~binary_path =
    (* codex_xml_fd: only if the installed binary supports --xml-input-fd.
       pty_inject: checked dynamically via check_pty_inject_capability in probed_capabilities. *)
    [ "codex_xml_fd", codex_supports_xml_input_fd binary_path ]

  (* #143c: Codex kickoff is delivered via the XML pipe in the launch loop
     (parent-side, after fork, before the deliver daemon starts).  The
     adapter's deliver_kickoff is a no-op — the real write happens in the
     launch loop where codex_xml_pipe is in scope. *)
  let deliver_kickoff ~name:_ ~alias:_ ~kickoff_text:_ ?broker_root:_ () =
    Ok []
end

module KimiAdapter : CLIENT_ADAPTER = struct
  let name = "kimi"
  let config_dir = ".kimi"
  let agent_dir = ""   (* kimi has no agent-dir concept *)
  let instances_subdir = "kimi"

  let binary = "kimi"
  let needs_deliver = false
  (* Delivery via C2c_kimi_notifier (file-based notification-store push).
     The deprecated wire-bridge path was removed in the kimi-wire-bridge-cleanup
     slice. *)
  let needs_poker = true
  let poker_event = Some "heartbeat"
  let poker_from = Some "kimi-poker"
  let extra_env = []
  let session_id_env = Some "KIMI_SESSION_ID"

  let build_start_args ~name ?alias_override ?model_override ?resume_session_id
      ?(extra_args = []) () =
    (* #139: --session is now passed when resume_session_id is Some, enabling
       restart-with-context. Used by `c2c restart kimi -n <alias>` to preserve
       agent state across restarts. kimi-cli supports
       `--session/-S/--resume/-r <UUID>` natively; we use --session to match
       the c2c instance-state field name. When resume_session_id is None or
       empty, kimi creates a fresh session as before.

       Write the per-instance MCP config to the instance dir and prepend the flag.
       extra_args are inspected for an existing --mcp-config-file flag but are NOT
       included in the return — prepare_launch_args appends them uniformly after.

        --yolo: managed sessions are agent-driven, no human at the keyboard for this
        pane. `--yolo` makes kimi auto-approve all tool calls
        (`is_auto_approve()` returns True) AND auto-dismisses AskUserQuestion prompts —
        matching the c2c convention "When you are talking to other models, do not
        use tools like AskUserQuestion".

        With #142 (slice 2: hook script installation, SHA `0f85a486`), the hook
        script at `~/.local/bin/c2c-kimi-approval-hook.sh` is the actual permission
        boundary when uncommented in the operator's `~/.config/kimi/kimi-cli.toml`
        [[hooks]] block. `--yolo` is therefore safe: it gives kimi permission to
        execute tools unconditionally, but the hook script intercepts and gates
        each tool call — so the operator has a reviewable audit trail without
        blocking the agent.

        Mirrors the Claude managed-session posture (`--dangerously-load-development-channels`).

       Research: kimi-permissions audit 2026-04-29 (Option A).

       Max-steps-per-turn raised from kimi-cli default (1000) to 9999 for
       long-running agentic swarm work; matches opencode posture (#153).

       Persistence gotcha: kimi saves `yolo=true` (or `afk=true` on older sessions)
       to its session state on disk. If an operator later runs `kimi -C` against the
       same session-id outside c2c management, the session stays in yolo/afk mode
       until explicitly toggled off. The same persistence applies to `state.json`
       seeds written by `c2c start` (#158). *)
    let br = broker_root () in
    let session_args =
      match resume_session_id with
      | Some sid when String.trim sid <> "" -> [ "--session"; sid ]
      | _ -> []
    in
    let base =
      "--yolo" ::
      "--max-steps-per-turn" :: "9999" ::
      session_args
      @ (match model_override with
         | Some m when String.trim m <> "" -> [ "--model"; m ]
         | _ -> [])
    in
    if not (has_explicit_kimi_mcp_config extra_args) then begin
      let cfg_path = kimi_mcp_config_path name in
      mkdir_p (Filename.dirname cfg_path);
      let oc = open_out cfg_path in
      Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
        Yojson.Safe.pretty_to_channel oc (build_kimi_mcp_config name br alias_override);
        output_string oc "\n");
      "--mcp-config-file" :: cfg_path :: base
    end else
      base

  let refresh_identity ~name:_ ~alias:_ ~broker_root:_ ~project_dir:_ ~instances_dir:_
      ~agent_name:_ =
    (* Kimi MCP config is written fresh at each launch via build_start_args;
       no additional per-launch refresh is needed. *)
    ()

  let probe_capabilities ~binary_path:_ =
    (* Kimi delivery is via C2c_kimi_notifier; no special capabilities needed. *)
    []

  (* Kickoff for kimi is delivered via [--prompt] argv injected in
     [prepare_launch_args] (see the "kimi" branch).  This contract
     method is intentionally a no-op; the kickoff text surfaces as
     kimi's first user-turn and is naturally visible in TUI scrollback.
     See #158. *)
  let deliver_kickoff ~name:_ ~alias:_ ~kickoff_text:_ ?broker_root:_ () =
    Ok []
end

module GeminiAdapter : CLIENT_ADAPTER = struct
  (* #406b: Google's Gemini CLI adapter.

     Delivery shape: Gemini exposes first-class MCP server support
     (`gemini mcp add` / `mcp list` / `mcp remove`); `c2c install gemini`
     (#406a) writes ~/.gemini/settings.json with the c2c MCP server entry
     and `trust: true` so tool-call confirmation prompts are pre-approved.
     No deliver daemon, no wire bridge, no poker, no PTY auto-answer
     (Gemini has no equivalent of Claude's #399b dev-channel consent
     prompt — the trust gate is settings-based, not interactive).

     Resume semantics: Gemini uses a numeric session index (per-project)
     with `gemini --resume <idx>` / `--resume latest` / `--list-sessions`.
     c2c's instance config stores a session-id string; for v1 we map that
     to `--resume latest` on resume. Operators wanting a specific index
     can pass it via `c2c start gemini -- --resume 3` (extra_args
     forwarded by prepare_launch_args). A future slice could persist the
     latest-index per-instance for round-tripping.

     OAuth seeding caveat: ~/.gemini/oauth_creds.json must exist before
     the first managed launch. `c2c install gemini` surfaces a one-line
     reminder; we don't pre-seed creds here. *)

  let name = "gemini"
  let config_dir = ".gemini"
  let agent_dir = ""   (* gemini has no agent-dir concept *)
  let instances_subdir = "gemini"

  let binary = "gemini"
  let needs_deliver = false

  let needs_poker = false
  let poker_event = None
  let poker_from = None
  let extra_env = []
  let session_id_env = None
    (* Gemini does not consume a session-id env var; resume is via
       --resume <idx>|latest, threaded through build_start_args. *)

  let build_start_args ~name:_ ?alias_override:_ ?model_override
      ?resume_session_id ?(extra_args = []) () =
    ignore extra_args;
    let resume_args =
      match resume_session_id with
      | None -> []
      | Some sid ->
        let s = String.trim sid in
        if s = "" then []
        else
          (* If the operator already passed --resume in extra_args,
             prepare_launch_args appends them after our base; let theirs
             win by emitting nothing here. Otherwise default to "latest"
             unless the stored session_id parses as a numeric index. *)
          let is_numeric =
            String.length s > 0
            && String.for_all (fun c -> c >= '0' && c <= '9') s
          in
          let target = if is_numeric then s else "latest" in
          [ "--resume"; target ]
    in
    let base = resume_args in
    match model_override with
    | Some m when String.trim m <> "" -> base @ [ "--model"; m ]
    | _ -> base

  let refresh_identity ~name:_ ~alias:_ ~broker_root:_ ~project_dir:_
      ~instances_dir:_ ~agent_name:_ =
    (* Gemini's c2c MCP server is configured via ~/.gemini/settings.json
       (written by `c2c install gemini`); env vars in that entry carry the
       broker root + alias. No per-launch config-file refresh needed. *)
    ()

  let probe_capabilities ~binary_path:_ =
    (* gemini_mcp: always available for managed gemini sessions.
       The MCP delivery channel is configured by `c2c install gemini`. *)
    [ "gemini_mcp", true ]

  (* #143d: Gemini kickoff is delivered via positional argv in
     prepare_launch_args (same pattern as Claude and Kimi).  The
     adapter's deliver_kickoff is a no-op. *)
  let deliver_kickoff ~name:_ ~alias:_ ~kickoff_text:_ ?broker_root:_ () =
    Ok []
end

let () = Stdlib.Hashtbl.add client_adapters "claude" (module ClaudeAdapter)
let () = Stdlib.Hashtbl.add client_adapters "codex" (module CodexAdapter)
let () = Stdlib.Hashtbl.add client_adapters "kimi" (module KimiAdapter)
let () = Stdlib.Hashtbl.add client_adapters "gemini" (module GeminiAdapter)

(* #143: top-level helper that dispatches kickoff delivery to the
   registered [CLIENT_ADAPTER] for [client], or returns [Ok []] if no
   adapter is registered.  Exposed in [c2c_start.mli] so unit tests can
   exercise the contract without driving the full launch loop. *)
let deliver_kickoff_for_client
    ~(client : string) ~(name : string) ~(alias : string)
    ~(kickoff_text : string) ?broker_root
    () : ((string * string) list, string) result =
  match Stdlib.Hashtbl.find_opt client_adapters client with
  | None -> Ok []
  | Some m ->
    let module A = (val m : CLIENT_ADAPTER) in
    A.deliver_kickoff ~name ~alias ~kickoff_text ?broker_root ()

let parse_rfc3339_utc s =
  match Ptime.of_rfc3339 s with
  | Ok (t, _, _) -> Some (Ptime.to_float_s t)
  | Error _ -> None

let opencode_statefile_path (name : string) : string =
  instance_dir name // "oc-plugin-state.json"

(* Delegate to canonical option-returning JSON helpers (audit #388 —
   converged with the formerly-local copies in [c2c_mcp.ml]). The
   semantics are identical: [Some s] iff the field is a JSON string;
   [None] for missing keys, non-objects, or non-string values. *)
let assoc_opt = Json_util.assoc_opt

let string_member = Json_util.string_member

let opencode_plugin_active ~name ~now ~freshness_window_s =
  let path = opencode_statefile_path name in
  if not (Sys.file_exists path) then false
  else
    try
      let json = Yojson.Safe.from_file path in
      let state =
        match assoc_opt "state" json with
        | Some state -> state
        | None -> json
      in
      let session_matches =
        match string_member "c2c_session_id" state with
        | Some session_id -> String.equal session_id name
        | None -> false
      in
      if not session_matches then false
      else
        let plugin_source =
          match assoc_opt "activity_sources" state with
          | Some sources -> (
              match assoc_opt "plugin" sources with
              | Some source -> source
              | None -> `Null)
          | None -> `Null
        in
        let source_matches =
          match string_member "source_type" plugin_source with
          | Some "plugin" -> true
          | Some _ -> false
          | None -> true
        in
        match string_member "last_active_at" plugin_source with
        | Some ts when source_matches -> (
            match parse_rfc3339_utc ts with
            | Some last_active -> now -. last_active <= freshness_window_s
            | None -> false)
        | _ -> false
    with _ -> false

let runtime_capabilities ?(now = Unix.gettimeofday ())
    ?(opencode_plugin_freshness_window_s = 60.0)
    ~(client : string) ~(name : string) () : string list =
  let open C2c_capability in
  let add_if cap enabled acc =
    if enabled then to_string cap :: acc else acc
  in
  []
  |> add_if Opencode_plugin_active
       (client = "opencode"
        && opencode_plugin_active ~name ~now
             ~freshness_window_s:opencode_plugin_freshness_window_s)
  |> List.rev

let managed_capabilities ?(now = Unix.gettimeofday ())
    ?(opencode_plugin_freshness_window_s = 60.0)
    ~(client : string) ~(name : string) ~(binary_path : string) () : string list =
  let static_caps = probed_capabilities ~client ~binary_path in
  let runtime_caps =
    runtime_capabilities ~now ~opencode_plugin_freshness_window_s
      ~client ~name ()
  in
  List.fold_left
    (fun acc cap -> if List.mem cap acc then acc else acc @ [ cap ])
    static_caps runtime_caps

let should_enable_opencode_fallback ?(startup_grace_s = 60.0)
    ?(opencode_plugin_freshness_window_s = 60.0)
    ~(name : string) ~(start_time : float) ~(now : float) () : bool =
  now -. start_time >= startup_grace_s
  && not
       (opencode_plugin_active ~name ~now
          ~freshness_window_s:opencode_plugin_freshness_window_s)

let delivery_mode ?(now = Unix.gettimeofday ()) ?(startup_grace_s = 60.0)
    ?(opencode_plugin_freshness_window_s = 60.0) ?available_capabilities
    ~(client : string) ~(name : string) ~(binary_path : string)
    ~(start_time : float option) () : string =
  let caps =
    match available_capabilities with
    | Some caps -> caps
    | None ->
        managed_capabilities ~now ~opencode_plugin_freshness_window_s
          ~client ~name ~binary_path ()
  in
  let has cap = C2c_capability.has caps cap in
  match client with
  | "claude" ->
      if has C2c_capability.Claude_channel then "channel_push" else "hook_poll"
  | "opencode" ->
      if has C2c_capability.Opencode_plugin_active then "plugin"
      else
        (match start_time with
         | Some started_at when
             not (should_enable_opencode_fallback ~startup_grace_s
                    ~opencode_plugin_freshness_window_s
                    ~name ~start_time:started_at ~now ()) ->
             "plugin_grace"
         | _ when has C2c_capability.Pty_inject -> "native_pty_fallback"
         | _ -> "plugin_stale_no_fallback")
  | "kimi" -> "notifier"
  | "codex" ->
      if has C2c_capability.Codex_xml_fd then "xml_fd"
      else if has C2c_capability.Pty_inject then "pty_notify"
      else "unavailable"
  | "codex-headless" ->
      if has C2c_capability.Codex_headless_thread_id_fd then "xml_fifo"
      else "unavailable"
  | "tmux" -> "tmux_send_keys"
  | "crush" ->
      if has C2c_capability.Pty_inject then "pty_notify" else "unavailable"
  | _ -> "unknown"

let inject_message_via_c2c ~(client_pid : int) (msg : C2c_mcp.message) : bool =
  let command = current_c2c_command () in
  let argv =
    [| command
     ; "inject"
     ; "--pid"
     ; string_of_int client_pid
     ; "--client"
     ; "opencode"
     ; "--method"
     ; "pty"
     ; "--from"
     ; msg.from_alias
     ; "--alias"
     ; msg.to_alias
     ; msg.content
    |]
  in
  let devnull = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  Fun.protect
    ~finally:(fun () -> try Unix.close devnull with _ -> ())
    (fun () ->
      try
        let pid =
          Unix.create_process_env command argv (Unix.environment ())
            Unix.stdin devnull devnull
        in
        match Unix.waitpid [] pid with
        | _, Unix.WEXITED 0 -> true
        | _, Unix.WEXITED _ | _, Unix.WSIGNALED _ | _, Unix.WSTOPPED _ -> false
      with _ -> false)

let try_opencode_native_fallback_once ~broker_root ~(name : string)
    ~(client_pid : int) : bool =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  C2c_mcp.Broker.with_inbox_lock broker ~session_id:name (fun () ->
      let messages = C2c_mcp.Broker.read_inbox broker ~session_id:name in
      match messages with
      | [] -> true
      | _ ->
          let delivered =
            List.for_all (inject_message_via_c2c ~client_pid) messages
          in
          if delivered then begin
            C2c_mcp.Broker.append_archive ~drained_by:"c2c_inject" broker ~session_id:name ~messages;
            C2c_mcp.Broker.save_inbox broker ~session_id:name []
          end;
          delivered)

let missing_role_capabilities ~(client : string) ~(binary_path : string)
    (role : C2c_role.t) : string list =
  C2c_capability.missing_required ~required:role.required_capabilities
    ~available:(probed_capabilities ~client ~binary_path)

let poker_script_path ~(broker_root : string) : string option =
  match resolve_repo_root ~broker_root with
  | "" -> None
  | dir ->
      let p = dir // "c2c_poker.py" in
      if Sys.file_exists p then Some p else None

(* ---------------------------------------------------------------------------
 * Sidecar daemon spawning
 * --------------------------------------------------------------------------- *)

let start_deliver_daemon ~(name : string) ~(client : string)
    ~(broker_root : string) ?(child_pid_opt : int option)
    ?command_override
    ?(xml_output_fd : string option) ?(xml_output_path : string option)
    ?(event_fifo_path : string option) ?(response_fifo_path : string option)
    ?(preserve_fds : Unix.file_descr list option)
    ?(pty_master_fd : int option) () : int option =
  match (match command_override with Some cmd -> Some cmd | None -> deliver_command ~broker_root) with
  | None -> None
  | Some (command, prefix_args) ->
      let args =
        prefix_args
        @ [ "--client"; client; "--session-id"; name;
          "--loop"; "--broker-root"; broker_root ]
        @ (match xml_output_fd, xml_output_path with
           | None, None -> [ "--notify-only" ]
           | _ -> [])
        @ (match xml_output_fd with None -> [] | Some fd -> [ "--xml-output-fd"; fd ])
        @ (match xml_output_path with None -> [] | Some path -> [ "--xml-output-path"; path ])
        @ (match event_fifo_path with None -> [] | Some path -> [ "--event-fifo"; path ])
        @ (match response_fifo_path with None -> [] | Some path -> [ "--response-fifo"; path ])
        @ (match child_pid_opt with None -> [] | Some p -> [ "--pid"; string_of_int p ])
        @ (match pty_master_fd with None -> [] | Some fd -> [ "--pty-master-fd"; string_of_int fd ])
      in
      try
        let argv = Array.of_list (command :: args) in
        let env = Unix.environment () in
        match Unix.fork () with
        | 0 ->
            (try ignore (Sys.signal Sys.sigchld Sys.Signal_default) with _ -> ());
            (try ignore (Sys.signal Sys.sigpipe Sys.Signal_default) with _ -> ());
            (* Sidecars must not keep the pane's terminal fds alive. Codex sideband
               delivery is especially sensitive here: inheriting the controlling tty
               can wedge shutdown even after the managed child exits. *)
            let devnull = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
            (try Unix.dup2 devnull Unix.stdin with _ -> ());
            (try Unix.dup2 devnull Unix.stdout with _ -> ());
            (try Unix.dup2 devnull Unix.stderr with _ -> ());
             (try
                if devnull <> Unix.stdin && devnull <> Unix.stdout && devnull <> Unix.stderr
                then Unix.close devnull
              with _ -> ());
            (* Close all inherited non-stdio fds before exec to prevent
               sidecar-fd-leak hang: unrelated parent fds (xml pipes, tees)
               can keep shutdown paths alive after the managed client exits.
               Preserve preserve_fds: includes the xml output fd when set,
               plus any caller-passed fds (e.g. event fifo). *)
            close_unlisted_fds ~preserve:(Option.value preserve_fds ~default:[]);
            (try Unix.execvpe command argv env
             with _ -> exit 127)
        | pid -> Some pid
      with Unix.Unix_error _ -> None

let start_poker ~(name : string) ~(client : string)
    ~(broker_root : string) ?(child_pid_opt : int option) () : int option =
  let cfg = try Some (Stdlib.Hashtbl.find clients client) with Not_found -> None in
  match cfg with
  | None | Some { needs_poker = false; _ } -> None
  | Some cfg ->
      let pid = match child_pid_opt with None -> 0 | Some p -> p in
      let sender = match cfg.poker_from with None -> "c2c-poker" | Some s -> s in
      let event = match cfg.poker_event with None -> "heartbeat" | Some e -> e in
      C2c_poker.start ~name ~pid ~interval:600.0 ~event ~sender ~alias:"" ~broker_root

let start_headless_thread_id_watcher ~(name : string) ~(path : string) : Thread.t =
  Thread.create
    (fun () ->
      let rec wait_for_line attempts_remaining =
        if attempts_remaining <= 0 then ()
        else if Sys.file_exists path then
          try
            let ic = open_in path in
            Fun.protect ~finally:(fun () -> try close_in ic with _ -> ())
              (fun () ->
                let line = String.trim (input_line ic) in
                if line = "" then (
                  Unix.sleepf 0.1;
                  wait_for_line (attempts_remaining - 1)
                ) else
                  match Yojson.Safe.from_string line with
                  | `Assoc fields ->
                      (match List.assoc_opt "thread_id" fields with
                       | Some (`String thread_id) when String.trim thread_id <> "" ->
                           persist_headless_thread_id ~name ~thread_id
                       | _ -> ())
                  | _ -> ())
          with
          | End_of_file ->
              Unix.sleepf 0.1;
              wait_for_line (attempts_remaining - 1)
          | Sys_error _ | Yojson.Json_error _ ->
              Unix.sleepf 0.1;
              wait_for_line (attempts_remaining - 1)
        else (
          Unix.sleepf 0.1;
          wait_for_line (attempts_remaining - 1)
        )
      in
      (* Poll for up to ~2 minutes; the bridge only writes one line, so a
         simple file-backed handoff is more robust than a long-lived sideband
         pipe for the current headless unblocker path. *)
      wait_for_line 1200)
    ()

(* ---------------------------------------------------------------------------
 * PTY generic client
 * --------------------------------------------------------------------------- *)

(* Reuses C2c_pty_inject.pty_inject from the shared c2c_pty_inject module.
   Kept here for now so existing call sites in pty_deliver_loop don't break.
   When all callers migrate to c2c_pty_inject.ml this alias can be removed. *)
let pty_inject = C2c_pty_inject.pty_inject

(* Parse -- separator from extra_args. Returns (cmd, argv) if found, or exits with error. *)
let parse_pty_cmd_argv (extra_args : string list) : (string * string list) =
  let rec split_on_dashdash (before : string list) (after : string list) : (string * string list) =
    match after with
    | [] ->
        Printf.eprintf "error: c2c start pty requires '--' followed by the command to run.\n%!";
        Printf.eprintf "  Example: c2c start pty -- bash\n%!";
        exit 1
    | "--" :: rest ->
        if rest = [] then begin
          Printf.eprintf "error: -- must be followed by a command.\n%!";
          exit 1
        end else
          (List.hd rest, List.tl rest)
    | x :: xs -> split_on_dashdash (x :: before) xs
  in
  split_on_dashdash [] extra_args

(* PTY deliver loop: polls broker inbox and writes messages to PTY master fd.
   Exits when child_pid is no longer alive (child exited).
   Uses C2c_pty_inject.pty_inject for the actual injection. *)
let pty_deliver_loop ~(master_fd : Unix.file_descr) ~(broker_root : string)
    ~(session_id : string) ~(name : string) ~(child_pid : int) : unit =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let poll_interval = 0.1 in  (* 100ms *)
  while pid_alive child_pid do
    let messages = C2c_mcp.Broker.drain_inbox ~drained_by:"pty" broker ~session_id in
    List.iter (fun (msg : C2c_mcp.message) ->
      (try C2c_pty_inject.pty_inject ~master_fd msg.content
       with e ->
         (* Race 1 fix: per-message error isolation — one failed inject must not
            abort the remaining messages in the batch. The drain_inbox lock is
            already released before this iteration starts, so failures here do
            not affect broker state. Log and continue. *)
         Printf.eprintf "warning: pty_inject failed for message %s: %s\n%!"
           (Option.value msg.message_id ~default:"<no-id>")
           (Printexc.to_string e))
    ) messages;
    ignore (Unix.select [] [] [] poll_interval)
  done

(* run_pty_loop: fork PTY pair, exec user's command on slave, deliver via master *)
let run_pty_loop ~(name : string) ~(extra_args : string list)
    ~(broker_root : string) ?(alias_override : string option) () : int =
  let session_id = name in
  let cmd, cmd_argv = parse_pty_cmd_argv extra_args in
  let full_cmd = cmd :: cmd_argv in
  (* forkpty: atomically fork and set up PTY. Parent gets master fd + child pid.
     Child already has slave as stdin/stdout/stderr. *)
  let master_fd, pid = forkpty_MasterChild () in
  let master_fd : Unix.file_descr = Obj.magic master_fd in
  if pid = 0 then begin
    (* Child: exec the user's command (slave is already stdin/stdout/stderr) *)
    (try
      (* Reset signals before exec *)
      ignore (Sys.signal Sys.sigchld Sys.Signal_default);
      ignore (Sys.signal Sys.sigpipe Sys.Signal_default);
      (* Set process group in child too (double-set for safety) *)
      (try ignore (setpgid 0 0) with _ -> ());
      (* Exec the command — slave fd is already dup'd to stdin/out/err *)
      Unix.execvp cmd (Array.of_list full_cmd)
    with
    | Unix.Unix_error (e, _, _) ->
        Printf.eprintf "error: exec %s failed: %s\n%!" cmd (Unix.error_message e);
        exit 127
    | e ->
        Printf.eprintf "error: exec %s failed: %s\n%!" cmd (Printexc.to_string e);
        exit 127)
  end else begin
    (* Parent *)
    (* Register the managed alias *)
    (try
      eager_register_managed_alias ~broker_root ~session_id ~alias:name
        ~pid ~client_type:"pty"
    with e ->
      Printf.eprintf "warning: registration failed: %s\n%!" (Printexc.to_string e));
    (* PTY deliver loop (runs in parent, polling broker and writing to master) *)
    (try pty_deliver_loop ~master_fd ~broker_root ~session_id ~name ~child_pid:pid with _ -> ());
    (* When pty_deliver_loop exits (e.g. on error), kill the child and wait *)
    (try Unix.kill pid Sys.sigterm with _ -> ());
    ignore (Unix.waitpid [] pid);
    Unix.close master_fd;
    0
  end

(* ---------------------------------------------------------------------------
 * Outer loop
 * --------------------------------------------------------------------------- *)

let finalize_outer_loop_exit
    ~(cleanup_and_exit : int -> int)
    ~(print_resume : string -> unit)
    ~(resume_cmd : string)
    ~(exit_code : int) : int =
  let code = cleanup_and_exit exit_code in
  print_resume resume_cmd;
  code

let run_outer_loop ~(name : string) ~(client : string)
    ~(extra_args : string list) ~(broker_root : string)
    ?(binary_override : string option) ?(alias_override : string option)
    ?(session_id : string option) ?(resume_session_id : string option)
    ?(codex_resume_target : string option)
    ?(model_override : string option)
    ?(one_hr_cache = false) ?(kickoff_prompt : string option)
    ?(auto_join_rooms : string option)
    ?(agent_name : string option) ?(reply_to : string option)
    ?no_prompt () : int =
  let no_prompt =
    (Option.value no_prompt ~default:false) || (Sys.getenv_opt "C2C_NO_PROMPT" = Some "1")
  in
  let session_id = Option.value session_id ~default:name in
  let cfg =
    try Stdlib.Hashtbl.find clients client
    with Not_found ->
      Printf.eprintf "error: unknown client '%s'\n%!" client; exit 1
  in
  (* Load the role file early so we can derive C2C_COORDINATOR=1 for #381. *)
  let agent_role =
    match agent_name with
    | None -> None
    | Some n ->
        (try
          let path = C2c_role.resolve_agent_path ~name:n ~client in
          if Sys.file_exists path then Some (C2c_role.parse_file path) else None
        with _ -> None)
  in
  (* Binary resolution order:
     1. explicit --binary flag (binary_override)
     2. [default_binary] table in .c2c/config.toml
     3. client config default (e.g. "codex") *)
  let binary =
    match binary_override with
    | Some b -> b
    | None ->
      (match repo_config_default_binary client with
       | Some b -> b
       | None -> cfg.binary)
  in
  match find_binary binary with
  | None ->
      Printf.eprintf "error: '%s' not found in PATH. Install %s first.\n%!" binary client;
      exit 2
  | Some binary_path ->
      if client = "codex-headless" && not (bridge_supports_thread_id_fd binary_path) then begin
        Printf.eprintf
          "error: codex-headless requires codex-turn-start-bridge with \
           --thread-id-fd support for lazy thread-id persistence\n%!";
        exit 1
      end;
      (* Leave SIGCHLD at default so waitpid works for the managed inner child.
         Sidecar children (deliver, poker) are started with their own
         process groups; they will eventually become zombies until the outer
         process itself exits, which is acceptable — the outer loop is short-lived. *)

      let inst_dir = instance_dir name in
      mkdir_p inst_dir;
      capture_and_write_tmux_location name;
      write_expected_cwd ~name;
      if repo_config_git_attribution () then begin
        (* #462: install the canonical swarm-wide shim once per
           [c2c start]. Idempotent; the per-instance shim below
           remains as defense-in-depth and matches the PATH order
           used by [build_inner_env]. *)
        (try ignore (ensure_swarm_git_shim_installed ()) with _ -> ());
        let shim_bin_dir = inst_dir // "bin" in
        mkdir_p shim_bin_dir;
        let shim_bin_path = shim_bin_dir // "git" in
        let c2c_bin_path = current_c2c_command () in
        let real_git_path = Git_helpers.find_real_git () in
        write_git_shim_atomic ~shim_bin_path ~c2c_bin_path ~real_git_path;
        shim_syntax_check shim_bin_path;
        (try Unix.chmod shim_bin_path 0o755 with _ -> ());
        (* Also install git-pre-reset in the per-instance dir for
           defense-in-depth — matches ensure_swarm_git_shim_installed. *)
        (try install_pre_reset_shim ~dir:shim_bin_dir with _ ->
           Printf.eprintf "warning: per-instance git-pre-reset install failed\n%!")
      end;
      (* Registry precheck: human-readable "alias alive" error before flock. *)
      check_registry_alias_alive ~broker_root ~name;
      (* Exclusive instance lock: prevents two concurrent starts for the same
         name; kernel releases on exit so no stale-lock cleanup needed.
         _lock_fd must stay in scope to hold the lock for the outer lifetime. *)
      let _lock_fd = acquire_instance_lock ~name in

      let deliver_pid = ref None in
      let poker_pid = ref None in
      (* Inner child PID — set after fork so the SIGTERM handler can kill it. *)
      let inner_child_pid = ref None in

      let stop_sidecar pid_opt =
        match pid_opt with
        | None -> ()
        | Some p ->
            (try Unix.kill p Sys.sigterm with Unix.Unix_error _ -> ());
            (* Wait up to 2s for graceful exit using waitpid WNOHANG.
               Using WNOHANG avoids zombie reaping confusion: we just poll
               until the process exits or 2s elapses. *)
            let rec wait_try n =
              if n <= 0 then ()
              else (
                match Unix.waitpid [Unix.WNOHANG] p with
                | 0, _ -> Unix.sleepf 0.1; wait_try (n - 1)
                | _, _ -> ()
              )
            in
            wait_try 20;
            (try Unix.kill p Sys.sigkill with Unix.Unix_error _ -> ())
      in

      let kill_inner_target signal pid =
        try
          if client = "codex-headless" then Unix.kill pid signal
          else Unix.kill (- pid) signal
        with Unix.Unix_error _ -> ()
      in

      let cleanup_and_exit code =
        (* Kill inner client's entire process group (opencode, node, c2c monitor, …)
           before cleaning up sidecars. The inner ran with setpgid 0 0 so its
           PGID == its PID; killing -pid kills the whole group. *)
        (match !inner_child_pid with
         | None -> ()
         | Some p ->
             kill_inner_target Sys.sigterm p;
             Unix.sleepf 0.3;
             kill_inner_target Sys.sigkill p);
        stop_sidecar !deliver_pid;
        stop_sidecar !poker_pid;
        remove_pidfile (outer_pid_path name);
        remove_pidfile (inner_pid_path name);
        remove_pidfile (deliver_pid_path name);
        remove_pidfile (poker_pid_path name);
        (* Clear pid from registration so the entry shows Unknown instead of
           ghost-alive if the PID is later reused by an unrelated process.
           Done inline (not via C2c_mcp.Broker) to avoid a compile-time
           cycle: c2c_mcp.mli re-exports C2c_start, so C2c_start cannot
           depend on C2c_mcp. *)
        (try clear_registration_pid ~broker_root ~session_id:name with _ -> ());
        code
      in

      (* Install SIGTERM handler so `c2c stop` (which sends SIGTERM to the outer)
         triggers a clean shutdown instead of leaving sidecars and the inner client
         orphaned as ppid=1 zombies. *)
      ignore (Sys.signal Sys.sigterm (Sys.Signal_handle (fun _ ->
        ignore (cleanup_and_exit 0);
        exit 0)));

      (* Cleanup stale zig cache *)
      (try
         let n = cleanup_stale_opentui_zig_cache () in
         if n > 0 then Printf.printf "[c2c-start/%s] cleaned %d stale /tmp/.fea*.so file(s)\n" name n
       with _ -> ());

      Printf.printf "[c2c-start/%s] iter 1: launching %s (outer pid=%d)\n%!"
        name client (Unix.getpid ());

      let effective_alias = Option.value alias_override ~default:name in
      set_terminal_title ~alias:effective_alias ~client ~glyph:"●";

      let start_time = Unix.gettimeofday () in

      (* Build env — read tmux location from the per-instance file written
         at startup so the inner MCP server receives it via C2C_TMUX_LOCATION. *)
      let tmux_loc = read_tmux_location_opt name in
      let env = build_env ~broker_root_override:(Some broker_root)
          ~auto_join_rooms_override:auto_join_rooms ~client:(Some client)
          ~reply_to_override:reply_to ~tmux_location:tmux_loc
          name alias_override in
      let env =
        Array.append env
          (Array.of_list
             (List.map (fun (k, v) -> Printf.sprintf "%s=%s" k v) cfg.extra_env))
      in
      let env = Array.append env [| Printf.sprintf "C2C_MCP_CLIENT_PID=%d" (Unix.getpid ()) |] in
      let env =
        if one_hr_cache then
          Array.append env [| "ENABLE_PROMPT_CACHING_1H=1" |]
        else env
      in
      (* #381: if the role has coordinator: true, propagate C2C_COORDINATOR=1
         so the managed client knows it was launched with coordinator privileges. *)
      let env =
        match agent_role with
        | Some r when r.C2c_role.coordinator = Some true ->
            Array.append env [| "C2C_COORDINATOR=1" |]
        | _ -> env
      in
      (* #143: route kickoff delivery through [CLIENT_ADAPTER.deliver_kickoff]
         instead of inlining per-client gates here.  The adapter performs any
         per-client side-effects (e.g. opencode writes the per-instance
         [kickoff-prompt.txt] consumed by [.opencode/plugins/c2c.ts]) and
         returns env pairs we must append to the launch env so the plugin
         picks up the handshake.  Adapters that don't have a working kickoff
         path warn-and-skip, returning [Ok []] — the launch path is unchanged
         for those clients. *)
      let env =
        match kickoff_prompt with
        | None -> env
        | Some kickoff_text when kickoff_text = "" -> env
        | Some kickoff_text ->
          let alias = Option.value alias_override ~default:name in
          (match
             deliver_kickoff_for_client
               ~client ~name ~alias ~kickoff_text ~broker_root ()
           with
           | Ok pairs when pairs = [] -> env
           | Ok pairs ->
             Array.append env
               (Array.of_list
                  (List.map (fun (k, v) ->
                       Printf.sprintf "%s=%s" k v) pairs))
           | Error msg ->
             Printf.eprintf
               "[c2c-start/%s] kickoff delivery failed: %s\n%!"
               name msg;
             env)
      in
      (* For opencode resume: surface the ses_* session id to the plugin via
         C2C_OPENCODE_SESSION_ID so bootstrapRootSession can match and
         auto-kickoff won't clobber the requested session with a new one. *)
      let env =
        match client, resume_session_id with
        | "opencode", Some s
          when String.length s >= 4 && String.sub s 0 4 = "ses_" ->
            Array.append env [| Printf.sprintf "C2C_OPENCODE_SESSION_ID=%s" s |]
        | _ -> env
      in
      (* Surface the active agent name to the c2c plugin so promptAsync
         calls can pass body.agent and preserve the session mode. Without
         this, every inbound c2c message resets the active OpenCode
         agent/mode back to the default. See #167 Thread B. *)
      let env =
        match client, agent_name with
        | "opencode", Some n ->
            Array.append env [| Printf.sprintf "C2C_AGENT_NAME=%s" n |]
        | _ -> env
      in

      (* #158: Pre-create kimi session dir + empty context.jsonl so
         Session.find() succeeds and loads our seeded state.json.
         Empty context.jsonl is the gatekeeper that switches kimi from
         "create" to "find" mode.  wire.jsonl is left untouched so
         resumed=False (new-session behaviour).  Only seed state.json
         when it does not already exist (respect resume). *)
      (if client = "kimi" then
         match resume_session_id with
         | Some sid when String.trim sid <> "" ->
             let wh = Digest.to_hex (Digest.string (Sys.getcwd ())) in
             let kimi_share =
               match Sys.getenv_opt "KIMI_SHARE_DIR" with
               | Some d when d <> "" -> d
               | _ -> (try Sys.getenv "HOME" with Not_found -> "/tmp") // ".kimi"
             in
             let sdir = kimi_share // "sessions" // wh // sid in
             mkdir_p sdir;
             let ctx = sdir // "context.jsonl" in
             if not (Sys.file_exists ctx) then
               (let oc = open_out ctx in close_out oc);
             let state_path = sdir // "state.json" in
             if not (Sys.file_exists state_path) then
               (let oc = open_out state_path in
                Fun.protect ~finally:(fun () -> close_out oc)
                  (fun () ->
                     output_string oc
                       ({|{"version":1,"approval":{"yolo":true,"afk":false,"auto_approve_actions":["run command","edit file outside of working directory"]},"additional_dirs":[],"custom_title":null,"title_generated":false,"title_generate_attempts":0,"plan_mode":false,"plan_session_id":null,"plan_slug":null,"wire_mtime":null,"archived":false,"archived_at":null,"auto_archive_exempt":false,"todos":[]}|}
                        ^ "\n")))
         | _ -> ());

      (* Launch args *)
      (* cc- wrappers (cc-mm, cc-w, etc.) are profile launchers designed to be called
         directly without extra args. They handle their own session/profile management.
         For these, we invoke them directly so they start an interactive session. *)
      let codex_permission_sideband_enabled =
        client = "codex" && codex_supports_server_request_fds binary_path
      in
      let permission_sideband_enabled =
        client = "codex-headless" || codex_permission_sideband_enabled
      in
      let launch_args =
        let codex_xml_input_fd =
          if client = "codex" && codex_supports_xml_input_fd binary_path then Some "3"
          else None
        in
        let thread_id_fd =
          if client = "codex-headless" then Some "5" else None
        in
        let server_request_events_fd =
          if permission_sideband_enabled then Some "6" else None
        in
        let server_request_responses_fd =
          if permission_sideband_enabled then Some "7" else None
        in
        if is_cc_wrapper binary_path then
          (* cc-* wrappers supply their own session + channel flags.
             Don't re-inject the dev-channel flags here — duplicating
             creates parser confusion / ugly argv. Wrapper script is
             responsible for passing --dangerously-load-development-channels
             server:c2c through to claude. *)
          []
        else
          prepare_launch_args ~name ~client ~extra_args ~broker_root
            ?alias_override ?resume_session_id ?binary_override ?model_override
            ?codex_resume_target
            ?codex_xml_input_fd
            ?thread_id_fd
            ?server_request_events_fd
            ?server_request_responses_fd
            ?agent_name
            ?kickoff_prompt ()
      in
      let headless_xml_fifo =
        if client = "codex-headless" then
          let path = headless_xml_fifo_path name in
          (* Managed headless launches looked healthy while the bridge still
             ignored broker-fed XML over an anonymous stdin pipe. A named fifo
             keeps the transport aligned with the direct bridge probes that do
             emit thread-id handoff correctly, and gives the deliver sidecar a
             stable reopenable path owned by c2c. *)
          ensure_fifo path;
          Some path
        else None
      in
      let thread_id_handoff_path_opt =
        if client = "codex-headless" then
          let path = headless_thread_id_handoff_path name in
          let oc = open_out path in
          close_out oc;
          Some path
        else None
      in
      let request_events_fifo_opt =
        if permission_sideband_enabled then
          let path = bridge_events_fifo_path name in
          ensure_fifo path;
          Some path
        else None
      in
      let request_responses_fifo_opt =
        if permission_sideband_enabled then
          let path = bridge_responses_fifo_path name in
          ensure_fifo path;
          Some path
        else None
      in
      let cmd =
        match client, headless_xml_fifo, thread_id_handoff_path_opt, request_events_fifo_opt, request_responses_fifo_opt with
        | "codex-headless", Some fifo_path, Some handoff_path, Some events_fifo_path, Some responses_fifo_path ->
            [ "/bin/bash"; "-lc";
              "bridge=\"$1\"; fifo=\"$2\"; handoff=\"$3\"; events=\"$4\"; responses=\"$5\"; shift 5; \
               exec \"$bridge\" \"$@\" < \"$fifo\" 5> \"$handoff\" 6> \"$events\" 7<> \"$responses\"";
              "c2c-codex-headless";
              binary_path;
              fifo_path;
              handoff_path;
              events_fifo_path;
              responses_fifo_path ]
            @ launch_args
        | _ -> binary_path :: launch_args
      in

      (* [#504] Print the resolved launch command so operators can see exactly what
         was spawned without needing strace. Written to stderr so it doesn't
         pollute stdout of the managed session. *)
      Printf.eprintf "[c2c-start] launch: %s\n%!"
        (String.concat " " (List.map Filename.quote cmd));

      (* Write meta.json with launch metadata *)
      let meta_path = meta_json_path name in
      let meta_entries = [
        ("client", `String client);
        ("binary", `String binary_path);
        ("args", `List (List.map (fun s -> `String s) launch_args));
        ("pid", `Int (Unix.getpid ()));
        ("start_ts", `Float start_time);
      ] in
      (try
        let oc = open_out meta_path in
        Fun.protect ~finally:(fun () -> close_out oc)
          (fun () ->
            Yojson.Safe.pretty_to_channel oc (`Assoc meta_entries);
            output_string oc "\n")
      with _ -> ());

      (* For OpenCode: refresh opencode.json env + sidecar with this instance's
         session_id and alias so the MCP server auto-registers the right identity.
         Use resolve_repo_root so we only write to the actual git project dir,
         not to whatever cwd happens to be (avoids overwriting in test scenarios). *)
      (if client = "opencode" then begin
        let alias = Option.value alias_override ~default:name in
        let project_dir = resolve_repo_root ~broker_root in
        if project_dir <> "" then begin
          (* Self-heal: if opencode.json is missing, offer to run c2c install opencode.
             On a TTY prompt the user (default Y); non-TTY or piped runs install silently
             so `c2c start opencode` in scripts and --auto pipelines are non-interactive. *)
          let config_path = Filename.concat project_dir ".opencode" // "opencode.json" in
          (if not (Sys.file_exists config_path) then begin
            let stdin_is_tty = (try Unix.isatty Unix.stdin with _ -> false) in
            let do_install =
              if no_prompt then false
              else if stdin_is_tty then begin
                Printf.eprintf
                  "  [c2c start] .opencode/opencode.json not found — \
                   c2c install opencode has not been run.\n\
                   \  Run it now? [Y/n] %!";
                let answer = try String.trim (input_line stdin) with End_of_file -> "" in
                let lower = String.lowercase_ascii answer in
                lower = "" || lower = "y" || lower = "yes"
              end else
                true  (* non-TTY: always install silently *)
            in
            if do_install then begin
              if not stdin_is_tty then
                Printf.eprintf
                  "  [c2c start] .opencode/opencode.json not found — \
                   running c2c install opencode...\n%!";
              ignore (Sys.command "c2c install opencode 2>/dev/null")
            end else
              Printf.eprintf
                "  [c2c start] skipping install — \
                 session may not auto-register without opencode.json\n%!"
          end);
          refresh_opencode_identity ~name ~alias ~broker_root ~project_dir ~instances_dir ~agent_name;
          (* Write the canonical plugin from data/opencode-plugin/c2c.ts to
             .opencode/plugins/c2c.ts so that branch switches in the shared
             working tree cannot clobber the live plugin file.  Always-overwrite:
             data/opencode-plugin/ is the source of truth; the written artifact
             is intentionally .gitignore-d. *)
          let plugin_src = project_dir // "data" // "opencode-plugin" // "c2c.ts" in
          let plugin_dir = project_dir // ".opencode" // "plugins" in
          let plugin_dst = plugin_dir // "c2c.ts" in
          (if Sys.file_exists plugin_src then begin
            C2c_io.mkdir_p plugin_dir;
            (try
              let ic = open_in plugin_src in
              let n = in_channel_length ic in
              let content = Bytes.create n in
              Fun.protect ~finally:(fun () -> close_in ic)
                (fun () -> really_input ic content 0 n);
              let oc = open_out plugin_dst in
              Fun.protect ~finally:(fun () -> close_out oc)
                (fun () -> output_bytes oc content)
            with e ->
              Printf.eprintf
                "  [c2c start] warning: failed to write opencode plugin: %s\n%!"
                (Printexc.to_string e))
          end)
        end
      end);

      (* #143: kickoff file write happens inside
         [CLIENT_ADAPTER.deliver_kickoff] (see env-pairs construction
         above); this site previously inlined the opencode-only file
         write and is now a no-op. *)
      ();

      (* Symlink latest opencode log to client.log *)
      (if client = "opencode" then
        (match latest_opencode_log () with
         | Some log_path ->
             let client_log = client_log_path name in
             (try
               (try Unix.unlink client_log with _ -> ());
               Unix.symlink log_path client_log
             with _ -> ())
         | None -> ()));

      (* Save TTY attrs *)
      let old_tty =
        (try if Unix.isatty Unix.stdin then Some (Unix.tcgetattr Unix.stdin) else None
         with _ -> None)
      in

      (* Tee child stderr to inst_dir/stderr.log.
         Save outer stderr fd first so the tee thread can write to it.
         Skip the tee when outer stderr is a TTY: opencode (and possibly
         other node-based clients) detect stderr TTY-vs-pipe mismatch
         relative to stdin and exit 109. When stderr is a pipe/file (e.g.
         `c2c start … 2>log`), the tee is safe. Detected operator-side
         repro: tmux pane launch of `c2c start opencode` → 109 in 1.1s;
         same command with `2>log` works fine. *)
      let stderr_is_tty = try Unix.isatty Unix.stderr with _ -> false in
      let outer_stderr_fd = Unix.dup Unix.stderr in
      let (tee_write_fd_opt, tee_stop_fd_opt, tee_thread_opt) =
        if stderr_is_tty then (None, None, None)
        else
          let (fd, stop_fd, th) = start_stderr_tee ~inst_dir ~outer_stderr_fd in
          (Some fd, Some stop_fd, Some th)
      in

      (* Spawn the managed client with SIGCHLD reset to SIG_DFL. The outer
         loop sets SIGCHLD=SIG_IGN to auto-reap its own
         sidecar children (deliver daemon, poker). SIG_IGN is inherited
         across execve, so without this reset the managed client (Claude
         Code, Codex, etc.) would inherit it too — the kernel would auto-
         reap every hook child it spawns, and Node.js/libuv's waitpid()
         would then fail with ECHILD. Verified on Claude Code 2.1.114:
         SigIgn=0x11000 on the client process produced PostToolUse ECHILD
         on roughly every non-trivial tool call. Forking manually lets us
         reset the disposition in the child between fork and exec. *)
      let child_pid_opt =
        try
          let codex_xml_pipe =
            if client = "codex" && List.mem "--xml-input-fd" launch_args then
              Some (Unix.pipe ~cloexec:false ())
            else None
          in
          (* S10 (#482): compute pre-deliver hook path for codex clients.
             The hook is sourced before exec so deliver-watch runs as a sibling
             of the client (same outer wrapper), not a child of the client.
             Only for clients that need deliver (codex, codex-headless). *)
          let pre_deliver_hook_opt =
            if cfg.needs_deliver then
              let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
              let hook_path =
                Filename.concat home (Printf.sprintf ".c2c/clients/%s/start-hooks/pre-deliver.sh" client)
              in
              if Sys.file_exists hook_path then Some hook_path else None
            else None
          in
          let pid = match Unix.fork () with
            | 0 ->
                (try ignore (Sys.signal Sys.sigchld Sys.Signal_default) with _ -> ());
                (try ignore (Sys.signal Sys.sigpipe Sys.Signal_default) with _ -> ());
                (* Interactive TUI clients run in their own process group so cleanup can
                   take down descendants atomically. codex-headless stays in the pane's
                   foreground group: isolating it into a fresh pgid under tmux can crash
                   the bridge before broker-fed XML is processed. *)
                (try if client <> "codex-headless" then setpgid 0 0 with _ -> ());
                (* Hand the controlling TTY's foreground process group to
                   the child's new pgid for interactive TUI clients only.
                   codex-headless replaces stdin with a broker-owned pipe, so
                   it must not participate in tty foreground handoff; under
                   tmux that path can wedge or crash the bridge before the
                   first XML message arrives. *)
                (try
                   if client <> "codex-headless" && Unix.isatty Unix.stdin then
                     tcsetpgrp Unix.stdin (Unix.getpid ())
                 with _ -> ());
                (* Redirect child stderr through the tee pipe (only when
                   we installed one; otherwise child inherits outer stderr). *)
                (match tee_write_fd_opt with
                 | Some fd ->
                     (try Unix.dup2 fd Unix.stderr with _ -> ());
                     (try Unix.close fd with _ -> ())
                 | None -> ());
                (match codex_xml_pipe with
                 | Some (read_fd, write_fd) ->
                     let fd3 : Unix.file_descr = Obj.magic 3 in
                     (try Unix.dup2 read_fd fd3 with _ -> ());
                     if read_fd <> fd3 then (try Unix.close read_fd with _ -> ());
                     (try Unix.close write_fd with _ -> ())
                 | None -> ());
                (let dup_fifo_to_fd path flags target_fd =
                   let fd = Unix.openfile path flags 0o600 in
                   try
                     Unix.dup2 fd target_fd;
                     if fd <> target_fd then Unix.close fd
                   with e ->
                     (try Unix.close fd with _ -> ());
                     raise e
                 in
                 match request_events_fifo_opt, request_responses_fifo_opt with
                 | Some events_path, Some responses_path when client = "codex" ->
                     let fd6 : Unix.file_descr = Obj.magic 6 in
                     let fd7 : Unix.file_descr = Obj.magic 7 in
                     dup_fifo_to_fd events_path [ Unix.O_WRONLY ] fd6;
                     dup_fifo_to_fd responses_path [ Unix.O_RDWR ] fd7
                 | _ -> ());
                 (try Unix.close outer_stderr_fd with _ -> ());
                 (* [#504] Echo the resolved launch command from the child so operators can
                    see exactly what execvpe received — after all fd redirects are done. *)
                 Printf.eprintf "[c2c-start] launch (child): %s\n%!"
                   (String.concat " " (List.map Filename.quote cmd));
                 (match pre_deliver_hook_opt with
                  | Some hook_path ->
                      (* S10 (#482): source the pre-deliver hook before exec.
                         The hook forks deliver-watch.sh as a sibling of the client.
                         C2C_DELIVER_XML_FD=4 is hardcoded: fd 4 is duped to the codex
                         xml pipe write end in the child before this point. *)
                      let args_str = String.concat " " (List.map Filename.quote cmd) in
                      let hook_cmd =
                        Printf.sprintf "C2C_DELIVER_XML_FD=4 source %s && exec %s"
                          (Filename.quote hook_path) args_str
                      in
                      let bash_argv = [|"bash"; "-c"; hook_cmd|] in
                      (try Unix.execvpe "bash" bash_argv env
                       with e ->
                         Printf.eprintf "exec bash (hook) failed: %s\n%!" (Printexc.to_string e);
                         exit 127)
                  | None ->
                      (try Unix.execvpe (List.hd cmd) (Array.of_list cmd) env
                       with e ->
                         Printf.eprintf "exec %s failed: %s\n%!" binary_path (Printexc.to_string e);
                         exit 127))
            | p -> p
          in
          (* Record inner pid so `c2c restart-self` can SIGTERM just the
             managed child without killing the outer loop. Also used by the
             SIGTERM handler so `c2c stop` can kill the whole inner pgid. *)
          inner_child_pid := Some pid;
          write_pid (inner_pid_path name) pid;
          (if client = "codex-headless" then
             (try
                eager_register_managed_alias
                  ~broker_root
                  ~session_id:name
                  ~alias:(Option.value alias_override ~default:name)
                  ~pid
                  ~client_type:"codex-headless"
              with _ -> ()));
          (match thread_id_handoff_path_opt with
           | Some path ->
               (* In XML mode the bridge does not start/resume a thread until it sees the first
                  <message>. So headless startup cannot wait for a thread-id handoff here; we
                  persist it lazily when the bridge emits it after the first real input. *)
               ignore (start_headless_thread_id_watcher ~name ~path)
           | None -> ());
          (* #143c: deliver kickoff to codex via XML pipe (before deliver daemon
             starts).  The pipe write_fd is in scope from the fork block above.
             We write the kickoff as a <message> XML frame that Codex reads from
             its --xml-input-fd.

             Note: the frame format here is deliberately simpler than the
             deliver-daemon's format (which wraps content in a <c2c event=
             "message" from="..." to="..."> inner envelope — see
             [c2c_pty_inject.ml:xml_deliver_loop_daemon]).  The kickoff is
             a raw user turn, not a c2c peer message, so the inner c2c
             envelope is omitted. *)
          (match client, kickoff_prompt, codex_xml_pipe with
           | "codex", Some p, Some (_read_fd, write_fd) when p <> "" ->
               (try
                  let escaped = C2c_mcp.xml_escape p in
                  let frame =
                    Printf.sprintf
                      "<message type=\"user\" queue=\"AfterAnyItem\">%s</message>\n"
                      escaped
                  in
                  let bytes = Bytes.of_string frame in
                  let len = Bytes.length bytes in
                  let _written = Unix.write write_fd bytes 0 len in
                  Printf.eprintf
                    "[c2c-start] kickoff delivered to codex via XML pipe (%d bytes)\n%!"
                    len
                with e ->
                  Printf.eprintf
                    "[c2c-start] kickoff XML pipe write failed: %s — continuing without kickoff\n%!"
                    (Printexc.to_string e))
           | _ -> ());
          (* Start deliver daemon (PTY notify path, used for Codex). *)
          (if !deliver_pid = None && cfg.needs_deliver then
             let xml_output_fd, xml_output_path =
               match client, codex_xml_pipe, headless_xml_fifo with
               | "codex-headless", _, Some path -> (None, Some path)
               | _, Some (_read_fd, write_fd), _ ->
                   let fd4 : Unix.file_descr = Obj.magic 4 in
                   (try Unix.dup2 write_fd fd4 with _ -> ());
                   (Some ("4", fd4), None)
               | _ -> (None, None)
              in
               let preserve_fds =
                 match xml_output_fd with
                 | Some (_, fd) -> [fd]
                 | None -> []
                in
                try
                  begin
                    match
                      start_deliver_daemon
                        ~name
                        ~client
                        ~broker_root
                        ?child_pid_opt:(Some pid)
                        ?xml_output_fd:(Option.map fst xml_output_fd)
                        ?xml_output_path
                        ?event_fifo_path:request_events_fifo_opt
                        ?response_fifo_path:request_responses_fifo_opt
                        ~preserve_fds
                        ()
                    with
                   | Some p ->
                       deliver_pid := Some p;
                       write_pid (deliver_pid_path name) p
                   | None ->
                       (* If the daemon failed to start, unlink the event fifo (the fallback
                          daemon does not use it). The response fifo is passed to the fallback
                          daemon below so do NOT unlink it here — doing so would cause ENOENT
                          when the fallback daemon tries to open it. fd4 is closed only after
                          both daemon attempts fail via the outer match below. *)
                       (match request_events_fifo_opt with
                        | Some p -> (try Unix.unlink p with _ -> ())
                        | None -> ());
                       (match xml_output_fd with
                         | Some _ ->
                             (* Fallback: try again without xml fd; the daemon will use
                                notify-only mode. Still pass response fifo for permission
                                sideband if it was set up. *)
                             (match
                               start_deliver_daemon ~name ~client ~broker_root ?child_pid_opt:(Some pid) ?response_fifo_path:request_responses_fifo_opt ~preserve_fds:[] ()
                             with
                             | Some p ->
                                 deliver_pid := Some p;
                                 write_pid (deliver_pid_path name) p
                             | None -> ())
                         | None -> ());
                       (* Now clean up the response fifo (fallback is done with it). *)
                       (match request_responses_fifo_opt with
                        | Some p -> (try Unix.unlink p with _ -> ())
                        | None -> ());
                    match xml_output_fd with
                    | Some (_, fd4) -> (try Unix.close fd4 with _ -> ())
                    | None -> ()
                  end
                with exn ->
                  (* On exception, clean up any fd4 and fifos that may have been set up.
                     This ensures we do not leak resources if start_deliver_daemon raises
                     (e.g. failure to create the daemon process). *)
                  (match xml_output_fd with
                   | Some (_, fd4) -> (try Unix.close fd4 with _ -> ())
                   | None -> ());
                  (match request_events_fifo_opt with
                   | Some p -> (try Unix.unlink p with _ -> ())
                   | None -> ());
                  (match request_responses_fifo_opt with
                   | Some p -> (try Unix.unlink p with _ -> ())
                   | None -> ());
                  raise exn
              );
          (if client = "opencode" then
             let startup_grace_s =
               match Sys.getenv_opt "C2C_OPENCODE_PLUGIN_GRACE_S" with
               | Some s -> (try float_of_string s with _ -> 60.0)
               | None -> 60.0
             in
             let heartbeat_stale_s =
               match Sys.getenv_opt "C2C_OPENCODE_PLUGIN_STALE_S" with
               | Some s -> (try float_of_string s with _ -> 60.0)
               | None -> 60.0
             in
             let poll_interval_s =
               match Sys.getenv_opt "C2C_OPENCODE_FALLBACK_CHECK_S" with
               | Some s -> (try float_of_string s with _ -> 10.0)
               | None -> 10.0
             in
             let pty_capability = check_pty_inject_capability () in
             let child_pid_for_fallback = pid in
             ignore (Thread.create
               (fun () ->
                 Unix.sleepf startup_grace_s;
                 let rec loop () =
                   if not (pid_alive child_pid_for_fallback) then
                     ()
                   else if
                     should_enable_opencode_fallback
                       ~startup_grace_s
                       ~opencode_plugin_freshness_window_s:heartbeat_stale_s
                       ~name
                       ~start_time
                       ~now:(Unix.gettimeofday ())
                       ()
                   then
                     begin
                       (match pty_capability with
                        | `Ok ->
                            ignore
                              (try_opencode_native_fallback_once ~broker_root ~name
                                 ~client_pid:child_pid_for_fallback)
                        | `Missing_cap _ | `Unknown -> ());
                       Unix.sleepf poll_interval_s;
                       loop ()
                     end
                   else (
                     Unix.sleepf poll_interval_s;
                     loop ()
                   )
                 in
                 loop ())
               ())
           );
          (match codex_xml_pipe with
           | Some (read_fd, write_fd) ->
               (try Unix.close read_fd with _ -> ());
               (try Unix.close write_fd with _ -> ())
           | None -> ());
          (* Start kimi-notifier (file-based notification-store push).
             File-based notification push to ~/.kimi/sessions/<wh>/<sid>/notifications/.
             Optionally tmux send-keys-wakes the kimi pane when idle. See
             c2c_kimi_notifier.mli + .collab/research/2026-04-29T10-27-00Z-stanza-
             coder-kimi-notification-store-push-validated.md. *)
          (if client = "kimi" then begin
             let alias = Option.value alias_override ~default:name in
             let tmux_pane = Sys.getenv_opt "TMUX_PANE" in
             match
               C2c_kimi_notifier.start_daemon
                 ~alias ~broker_root ~session_id:name ~tmux_pane ()
             with
             | Some _ -> ()
             | None -> ()
           end);
           (* Start poker *)
          (if !poker_pid = None && cfg.needs_poker then
             match start_poker ~name ~client ~broker_root ?child_pid_opt:(Some pid) () with
             | Some p -> poker_pid := Some p; write_pid (poker_pid_path name) p
             | None -> ());
          (* Start periodic title ticker — updates glyph based on broker state (✉ ⏸). *)
          start_title_ticker ~broker_root ~session_id:name ~alias:effective_alias
            ~client ~poll_interval_s:30.0;
          (* Start managed heartbeats — broker-mail-based self messages. They
             use the same inbox transport as ordinary c2c messages; per-client
             delivery sidecars/plugins then handle actual presentation. *)
           let heartbeat_role = load_role_for_heartbeat ~client agent_name in
           (* S5: split role heartbeats (persist to .toml, watcher starts them)
              from config/per-agent heartbeats (start directly). *)
           let non_role_specs, role_specs =
             resolve_managed_heartbeats_and_persist_role ~client
               ~deliver_started:(Option.is_some !deliver_pid)
               ~role:heartbeat_role
               ~per_agent_specs:(per_agent_managed_heartbeats ~name)
               (repo_config_managed_heartbeats ())
           in
           (* S5: persist role heartbeats BEFORE starting watcher — watcher will
              pick them up on its first scan and start their timer threads. *)
           persist_role_heartbeats_to_schedule_dir
             ~alias:effective_alias role_specs;
           List.iter
             (start_managed_heartbeat ~broker_root ~alias:effective_alias)
             non_role_specs;
           (* S6c: Mirror C2C_MCP_SCHEDULE_TIMER into the parent env so
             mcp_schedule_timer_active() sees it. build_env passes the
             same var to the MCP child. Respect operator overrides: only
             set if not already present in the environment. *)
          (match Sys.getenv_opt "C2C_MCP_SCHEDULE_TIMER" with
           | None -> Unix.putenv "C2C_MCP_SCHEDULE_TIMER" "1"
           | Some _ -> ());
          (* Schedule-dir heartbeats: skip when the MCP server handles
             scheduling (S6c dedup — C2C_MCP_SCHEDULE_TIMER=1 set in
             build_env). The MCP server's Lwt timer reads the same
             .c2c/schedules/<alias>/ dir. Fall back to the c2c start
             watcher thread if the operator explicitly set the env var
             to 0/false/no/off. *)
          if not (mcp_schedule_timer_active ()) then
            start_schedule_watcher ~broker_root ~alias:effective_alias
              ~client ~deliver_started:(Option.is_some !deliver_pid)
              ~role:heartbeat_role;
          pid
        with Unix.Unix_error (Unix.EINTR, _, _) -> 0
      in

      let exit_code, exit_reason =
        if child_pid_opt = 0 then (130, Some "term")
        else
          (try
             let rec wait_for_child () =
               match Unix.waitpid [ Unix.WUNTRACED ] child_pid_opt with
               | _, Unix.WSIGNALED n -> (128 + n, Some (signal_name n))
               | _, Unix.WSTOPPED sig_n when sig_n = Sys.sigtstp ->
                   (* Ctrl-Z (SIGTSTP) on the child's foreground pgrp: user
                      wants to suspend. Reclaim the TTY, stop ourselves so
                      the shell sees a suspended job, then on SIGCONT hand
                      the TTY back, resume the child, and keep waiting. *)
                   Printf.eprintf
                     "[c2c-start/%s] child stopped (SIGTSTP=%d); suspending outer\n%!"
                     name sig_n;
                   (try tcsetpgrp Unix.stdin (Unix.getpid ()) with _ -> ());
                   (try Unix.kill (Unix.getpid ()) Sys.sigstop with _ -> ());
                   (try tcsetpgrp Unix.stdin child_pid_opt with _ -> ());
                   (try Unix.kill (- child_pid_opt) Sys.sigcont with _ -> ());
                   wait_for_child ()
               | _, Unix.WSTOPPED sig_n ->
                   (* SIGTTIN/SIGTTOU/SIGSTOP etc — not a user suspend.
                      Resume the child and keep waiting; don't propagate
                      the stop to ourselves (would strand the outer on
                      clean-exit paths like opencode's Ctrl-D shutdown). *)
                   Printf.eprintf
                     "[c2c-start/%s] child stopped (sig=%d, not SIGTSTP=%d); SIGCONTing, not suspending\n%!"
                     name sig_n Sys.sigtstp;
                   (try Unix.kill (- child_pid_opt) Sys.sigcont with _ -> ());
                   wait_for_child ()
               | _, Unix.WEXITED 0 -> (0, Some "clean")
               | _, Unix.WEXITED n -> (n, Some (Printf.sprintf "exit:%d" n))
               | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_for_child ()
             in
             let code, reason = wait_for_child () in
             (* Reclaim the controlling TTY before writing anything. The child held
                the terminal's foreground pgrp (via tcsetpgrp in the child). On a
                normal Ctrl-D exit it doesn't release it, so any write the outer makes
                while backgrounded triggers SIGTTOU and stops the outer process —
                leaving `fg` with a ghost job in the shell. *)
             (try
               if Unix.isatty Unix.stdin then
                 tcsetpgrp Unix.stdin (getpgrp ())
             with _ -> ());
             (* Reap grandchildren for clients that run in their own process group. *)
             kill_inner_target Sys.sigterm child_pid_opt;
             Unix.sleepf 0.5;
             kill_inner_target Sys.sigkill child_pid_opt;
             (code, reason)
           with _ -> (1, None))
      in

      (* Shutdown sequence for tee thread:
         1. Close outer_stderr_fd FIRST — forces any blocked write in the tee
            thread to fail with EBADF, causing flush_line to raise.
         2. Close tee_write_fd — sends EOF to the tee thread's read end.
         3. Signal stop pipe — tee thread exits via raise Exit in select.
         4. Thread.join — returns immediately since tee thread exited.

         The previous order (close tee_write_fd → signal stop → join → close
         outer_stderr_fd) could deadlock: if tee thread was blocked in
         flush_line writing to outer_stderr_fd, it never returned to select
         to check the stop pipe, so the stop signal never fired. *)
      (try Unix.close outer_stderr_fd with _ -> ());
      (match tee_write_fd_opt with
       | Some fd -> (try Unix.close fd with _ -> ())
       | None -> ());
      (match tee_stop_fd_opt with
       | Some fd ->
           (try ignore (Unix.write_substring fd "x" 0 1) with _ -> ());
           (try Unix.close fd with _ -> ())
       | None -> ());
      (match tee_thread_opt with
       | Some th -> Thread.join th
       | None -> ());

      (* Restore TTY *)
      (match old_tty with
       | Some t -> (try Unix.tcsetattr Unix.stdin Unix.TCSANOW t with _ -> ())
       | None -> ());

      let elapsed = Unix.gettimeofday () -. start_time in
      Printf.printf "[c2c-start/%s] inner exited code=%d after %.1fs (pid=%d)\n%!"
        name exit_code elapsed child_pid_opt;

      (* Exit 109 from opencode = DB lock contention (multiple opencode instances
         sharing the same ~/.local/share/opencode/opencode.db). Surfaces as a
         silent fast exit with no stderr output. *)
      if client = "opencode" && exit_code = 109 then begin
        let n_oc = try
          let ic = Unix.open_process_in "pgrep -c -f '.opencode.*--log-level' 2>/dev/null" in
          let n = try int_of_string (String.trim (input_line ic)) with _ -> 0 in
          ignore (Unix.close_process_in ic); n
        with _ -> 0 in
        Printf.eprintf
          "hint: opencode exited 109 — likely database lock contention.\n\
           \  There are ~%d other opencode process(es) sharing ~/.local/share/opencode/opencode.db.\n\
           \  Fix: stop other (unmanaged) opencode instances first.\n\
           \    pgrep -a opencode          # list running instances\n\
           \    pkill -f '.opencode'       # kill all (use with care)\n\
           \    c2c instances              # check c2c-managed instances\n%!"
           n_oc
      end;

      (* #514 S2: stale broker_root — re-launch with freshly-resolved broker_root.
         The MCP server child exited 42 when its inherited C2C_MCP_BROKER_ROOT
         didn't match what C2c_repo_fp.resolve_broker_root() would compute fresh.
         This can happen after a git remote URL change or migrate-broker.
         We stop sidecars, capture orphan messages, then re-exec with the
         canonical broker_root so the next iteration registers in the right broker.
         Note: we cannot use cmd_restart here because it would try to kill and
         wait for our own outer PID (deadlock). Instead, we inline the orphan
         capture + execvp path directly. *)
      if exit_code = 42 then begin
        (* Stop sidecars (deliver, poker). *)
        stop_sidecar !deliver_pid;
        stop_sidecar !poker_pid;
        (* Capture orphan inbox — messages that arrived during the restart gap.
           Saved to pending-replay so the MCP server injects them after
           auto_register_startup completes in the fresh session. *)
        let session_id_for_replay =
          match load_config_opt name with
          | Some cfg -> cfg.resume_session_id | None -> name
        in
        let replayed =
          try capture_orphan_inbox_for_restart
                ~broker_root ~session_id:session_id_for_replay
          with _ -> 0
        in
        if replayed > 0 then
          Printf.printf "[c2c-start/%s] captured %d orphan message%s for replay\n%!"
            name replayed (if replayed = 1 then "" else "s");
        (* Compute a fresh broker_root (canonical resolution from current git ctx)
           and set it in the environment before re-execing. Unsetting the env var
           would make resolve_broker_root() recompute from git fingerprint, which
           is what we want — we set it to the freshly-computed value so the
           re-execed process sees the canonical path explicitly. *)
        let fresh_broker_root =
          try C2c_repo_fp.resolve_broker_root () with _ -> broker_root
        in
        Unix.putenv "C2C_MCP_BROKER_ROOT" fresh_broker_root;
        Printf.printf
          "[c2c-start/%s] stale broker_root detected (child exit 42); \
           re-executing with fresh broker_root=%s\n%!"
          name fresh_broker_root;
        (* Re-exec the current c2c binary with the same arguments.
           The fresh C2C_MCP_BROKER_ROOT in the env will be used by the
           re-execed cmd_start → resolve_broker_root() path. *)
        let argv = Array.of_list (Sys.argv |> Array.to_list) in
        Unix.execvp argv.(0) argv
      end;

      (* Record structured death on non-zero exit *)
      if exit_code <> 0 then
        record_death ~broker_root ~name ~client ~exit_code ~duration_s:elapsed ~inst_dir;

      (* Record exit context in instance config for restart-coord diagnostics *)
      (match load_config_opt name with
       | Some cfg ->
           write_config { cfg with last_exit_code = Some exit_code; last_exit_reason = exit_reason }
       | None -> ());

      let resume_cmd =
        let sid =
          match client, codex_resume_target, resume_session_id with
          | "codex", Some target, _ when String.trim target <> "" -> target
          | _, _, Some sid -> sid
          | _ -> session_id
        in
        Printf.sprintf "c2c start %s -n %s --session-id %s" client name sid
        ^ (match binary_override with None -> "" | Some b -> Printf.sprintf " --bin %s" b)
      in
      ignore
        (finalize_outer_loop_exit
           ~cleanup_and_exit
           ~print_resume:(fun cmd -> print_endline ("\nresume via: " ^ cmd))
           ~resume_cmd
           ~exit_code);
      exit_code

(* ---------------------------------------------------------------------------
 * Commands
 * --------------------------------------------------------------------------- *)

(** Resolve the effective model for a client launch using 3-way priority:
    explicit --model flag > role pmodel > saved instance config.
    Pure function for testability. Used by cmd_start on resume. *)
let resolve_model_override
    ~(model_override : string option)
    ~(role_pmodel_override : string option)
    ~(saved_model_override : string option) : string option =
  match model_override with
  | Some _ -> model_override
  | None ->
      (match role_pmodel_override with
       | Some _ -> role_pmodel_override
       | None -> saved_model_override)

let cmd_start ~(client : string) ~(name : string) ~(extra_args : string list)
    ?(binary_override : string option) ?(alias_override : string option)
    ?(session_id_override : string option) ?(model_override : string option)
    ?(role_pmodel_override : string option)
    ?(one_hr_cache = false) ?(new_session = false)
    ?(kickoff_prompt : string option) ?(auto_join_rooms : string option)
    ?(agent_name : string option) ?(reply_to : string option)
    ?(tmux_location : string option) ?(tmux_command : string list option)
    ?no_prompt () : int =
  (* Deprecation guard: reject crush early with banner, before unknown-client path *)
  (if client = "crush" then
     let use_color = Unix.isatty Unix.stderr in
     let yellow = if use_color then "\027[1;33m" else "" in
     let reset = if use_color then "\027[0m" else "" in
     Printf.eprintf
       "%s[DEPRECATED]%s crush is no longer a first-class c2c client.\n\
        \  `c2c start crush` is no longer available.\n\
        \  For new agents use: claude | codex | opencode | kimi\n\n%!"
       yellow reset;
     exit 1);
  if not (Stdlib.Hashtbl.mem clients client) then
    (Printf.eprintf "error: unknown client: '%s'. Choose from: %s\n%!"
       client (String.concat ", " (List.sort String.compare supported_clients));
     exit 1);

  if not (C2c_name.is_valid name) then begin
    Printf.eprintf "error: %s\n%!" (C2c_name.error_message "instance name" name);
    exit 1
  end;

  (* Guard: fail fast if already running inside a c2c agent session.
     C2C_WRAPPER_SELF is set by build_env exclusively in the wrapper process
     (passed to exec'd client via env, NOT inherited by bash subshells of the
     managed client). If session or alias is set without C2C_WRAPPER_SELF,
     we're inside a nested c2c session. *)
  (match Sys.getenv_opt "C2C_MCP_SESSION_ID",
         Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS",
         Sys.getenv_opt "C2C_WRAPPER_SELF" with
   | Some _, None, None ->
       let use_color = Unix.isatty Unix.stderr in
       let red = if use_color then "\027[1;31m" else "" in
       let reset = if use_color then "\027[0m" else "" in
       let sid_str = match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
         | Some s -> s | None -> "(unknown)" in
       Printf.eprintf
         "%sFATAL:%s refusing to start nested session.\n\
          \  You are already running inside a c2c agent session\n\
          \  (C2C_MCP_SESSION_ID=%s).\n\
          \  Hint: use 'c2c stop' to exit the current session first,\n\
          \  or 'c2c restart-self' to restart the inner client.\n%!"
         red reset sid_str;
       exit 1
   | None, Some _, None ->
       let use_color = Unix.isatty Unix.stderr in
       let red = if use_color then "\027[1;31m" else "" in
       let reset = if use_color then "\027[0m" else "" in
       let alias_str = match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
         | Some a -> a | None -> "(unknown)" in
       Printf.eprintf
         "%sFATAL:%s refusing to start nested session.\n\
          \  You are already running inside a c2c agent session\n\
          \  (C2C_MCP_AUTO_REGISTER_ALIAS=%s).\n\
          \  Hint: use 'c2c stop' to exit the current session first,\n\
          \  or 'c2c restart-self' to restart the inner client.\n%!"
         red reset alias_str;
       exit 1
   | Some _, Some _, None ->
       let use_color = Unix.isatty Unix.stderr in
       let red = if use_color then "\027[1;31m" else "" in
       let reset = if use_color then "\027[0m" else "" in
       let sid_str = match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
         | Some s -> s | None -> "(unknown)" in
       Printf.eprintf
         "%sFATAL:%s refusing to start nested session.\n\
          \  You are already running inside a c2c agent session\n\
          \  (C2C_MCP_SESSION_ID=%s).\n\
          \  Hint: use 'c2c stop' to exit the current session first,\n\
          \  or 'c2c restart-self' to restart the inner client.\n%!"
         red reset sid_str;
       exit 1
    | None, None, _ -> ()  (* no session vars → OK *)
    | Some _, None, Some _ -> ()  (* session + wrapper_self → OK (managed client) *)
    | None, Some _, Some _ -> ()  (* alias + wrapper_self → OK (managed client) *)
    | Some _, Some _, Some _ -> ());

  (* Guard: stale C2C_MCP_BROKER_ROOT.
     If the launching shell has a legacy/stale C2C_MCP_BROKER_ROOT export, the
     broker and notifier will use a different path than the canonical resolver,
     causing split-brain delivery (broker writes to canonical, notifier reads from
     stale → messages pile up, kimi never wakes, log stays 0 bytes).
     Detect by comparing the env-var value against C2c_repo_fp.resolve_broker_root_canonical ()
     (the same resolution but without consulting C2C_MCP_BROKER_ROOT). Warn and unset
     before forking so child processes inherit the canonical path. *)
  (match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
   | None -> ()
   | Some inherited ->
       let stale = String.trim inherited in
       if stale <> "" then
         let canonical = C2c_repo_fp.resolve_broker_root_canonical () in
         if stale <> canonical then begin
           let use_color = Unix.isatty Unix.stderr in
           let yellow = if use_color then "\027[1;33m" else "" in
           let reset = if use_color then "\027[0m" else "" in
           Printf.eprintf
             "%s[WARNING]%s stale C2C_MCP_BROKER_ROOT detected.\n\
              \  Current value: %s\n\
              \  Canonical path: %s\n\
              \  Your daemon may be polling the wrong broker directory.\n\
              \  To fix permanently: unset C2C_MCP_BROKER_ROOT from your shell config,\n\
              \  or run: c2c migrate-broker\n\
              \  Unsetting C2C_MCP_BROKER_ROOT for this session.\n\n%!"
             yellow reset stale canonical;
           (try Unix.putenv "C2C_MCP_BROKER_ROOT" "" with _ -> ())
         end);

  (* PTY client: run PTY loop and exit when done *)
  if client = "pty" then
    exit (run_pty_loop ~name ~extra_args ~broker_root:(broker_root ()) ());

  (* Validate --session-id. OpenCode accepts ses_* session IDs from its TUI.
     codex / codex-headless accept non-empty explicit thread/session targets. *)
  (match session_id_override with
   | None -> ()
   | Some sid when client = "opencode" ->
       if not (String.length sid >= 3 && String.sub sid 0 3 = "ses") then begin
         Printf.eprintf "error: --session-id for opencode must be a ses_* session ID (e.g. ses_abc123)\n%!";
         exit 1
       end;
       (* Pre-flight: verify the ses_* session actually exists.
          opencode silently creates a new session for unknown IDs, which
          causes a hang in the managed wake path — fail fast instead. *)
       (match Sys.command
           (Printf.sprintf "opencode session list --format json 2>/dev/null \
                            | python3 -c \"import json,sys; d=json.load(sys.stdin); \
                                          exit(0 if any(s.get('id')=='%s' for s in d) else 1)\" \
                            2>/dev/null" (String.escaped sid))
       with
       | 0 -> ()
       | _ ->
           Printf.eprintf
             "error: opencode session '%s' not found.\n\
              \  List sessions:  opencode session list\n\
             \  Omit -s to start a fresh session.\n%!"
             sid;
           exit 1)
   | Some sid when client = "codex" ->
       if String.trim sid = "" then begin
         Printf.eprintf "error: --session-id for codex must be a non-empty session id or thread name\n%!";
         exit 1
       end
   | Some sid when client = "codex-headless" ->
       if String.trim sid = "" then begin
         Printf.eprintf "error: --session-id for codex-headless must be a non-empty thread id\n%!";
         exit 1
       end
   | Some sid when client = "claude" ->
       if String.trim sid = "" then begin
         Printf.eprintf "error: --session-id for claude must be a non-empty session id\n%!";
         exit 1
       end
   | Some sid ->
       (match Uuidm.of_string sid with
        | Some _ -> ()
        | None ->
            Printf.eprintf "error: --session-id must be a valid UUID, e.g. 550e8400-e29b-41d4-a716-446655440000\n%!";
            exit 1));

  let inst_dir = instance_dir name in
  (match read_pid (outer_pid_path name) with
   | Some pid when pid_alive pid ->
       let use_color = Unix.isatty Unix.stderr in
       let red = if use_color then "\027[1;31m" else "" in
       let yellow = if use_color then "\027[33m" else "" in
       let reset = if use_color then "\027[0m" else "" in
       Printf.eprintf
         "%sERROR:%s instance %s'%s'%s is already running (pid %d).\n\
          \  Stop it first:  %sc2c stop %s%s\n\
          \  Instance dir:   %s\n%!"
         red reset yellow name reset pid
         yellow name reset inst_dir;
       exit 1
   | Some _ ->
       (* Stale pid file — process is dead. Clean up all pid files so the
          restart doesn't see phantom sidecar PIDs. *)
       Printf.eprintf
         "note: stale instance '%s' (dead process); cleaning up pid files in %s\n%!"
         name inst_dir;
       List.iter remove_pidfile
         [ outer_pid_path name; inner_pid_path name
         ; deliver_pid_path name; poker_pid_path name ]
   | None ->
       (* No pid file at all — fresh start or already cleaned up. *)
       ());

  (* Resume: inherit saved settings *)
  let existing = load_config_opt name in
  let (binary_override, alias_override, extra_args, resume_session_id, codex_resume_target, broker_root, model_override, mo) =
    match existing with
    | Some ex ->
        if ex.client <> client then
          (Printf.eprintf
             "error: instance '%s' was previously a %s instance. Cannot resume as %s. Use 'c2c stop %s' first.\n%!"
             name ex.client client name;
           exit 1);
        if new_session then
          Printf.eprintf "[c2c start] --new-session: starting fresh session for '%s' (discarding saved session %s).\n%!" name ex.resume_session_id
        else
          Printf.eprintf "[c2c start] resuming session for '%s'. Use --new-session to start fresh.\n%!" name;
        let bo = if binary_override = None then None else binary_override in
        let ao = if alias_override = None then Some ex.alias else alias_override in
        (* #471: do NOT silently inherit persisted extra_args on a plain
           re-launch. See resolve_effective_extra_args above. *)
        let ea = resolve_effective_extra_args
                   ~cli_extra_args:extra_args
                   ~persisted_extra_args:ex.extra_args in
        let mo = resolve_model_override ~model_override ~role_pmodel_override ~saved_model_override:ex.model_override in
        (* For OpenCode: prefer the ses_* session ID captured by the plugin
           in opencode-session.txt over the UUID stored in instance config.
           The plugin writes this file when it first sees a session.created
           event so that `c2c start opencode -n <name>` can resume the exact
           conversation on the next launch. *)
        let opencode_session_file = instance_dir name // "opencode-session.txt" in
        let ses_id_from_file =
          if client = "opencode" && Sys.file_exists opencode_session_file then
            (try
               let ic = open_in opencode_session_file in
               let line = input_line ic in
               close_in ic;
               let s = String.trim line in
               (* Accept only ses_* IDs — plugin guarantees this, but guard anyway. *)
               if String.length s >= 3 && String.sub s 0 3 = "ses" then Some s else None
             with _ -> None)
          else None
        in
        (* codex-headless stores the Codex bridge thread id here. It is opaque and
           intentionally not UUID-validated like Claude/Codex TUI resume ids. *)
        let rs_valid =
          if client = "codex-headless" then
            Some ex.resume_session_id
          else
            match Uuidm.of_string ex.resume_session_id with
            | Some _ -> Some ex.resume_session_id
            | None -> None
        in
        let rs =
          if new_session then begin
            (* Force fresh session — don't resume the old one *)
            (* For opencode, also remove the ses_* file so it doesn't resume *)
            if client = "opencode" then begin
              let ses_file = instance_dir name // "opencode-session.txt" in
              (try Sys.remove ses_file with _ -> ())
            end;
            Some (Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ()))
          end else
          match session_id_override with
          | Some s -> Some s
          | None ->
              (match ses_id_from_file with
               | Some v -> Some v   (* OpenCode ses_* wins over stored UUID *)
               | None ->
                   (match rs_valid with
                    | Some v -> Some v
                    | None -> Some (Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ()))))
        in
        let codex_target =
          match client, session_id_override with
          | "codex", Some sid -> Some sid
          | "codex", None -> ex.codex_resume_target
          | _, Some _ -> ex.codex_resume_target
          | _ -> None
        in
        (* If persisted broker_root is empty (#501: instance configs were
           cleaned of broker_root pinning during legacy→canonical broker
           migration), fall through to env > XDG > canonical resolver. *)
        let resolved_br = if ex.broker_root = "" then broker_root () else ex.broker_root in
        (bo, ao, ea, rs, codex_target, resolved_br, model_override, mo)
    | None ->
        let rs =
          match client, session_id_override with
          | "codex-headless", None -> ""
          | "codex-headless", Some sid -> sid
          | _, Some s -> s
          | _, None ->
            if client = "claude" then
              (match Sys.getenv_opt "CLAUDE_SESSION_ID" with
               | Some sid when claude_session_exists sid -> sid
               | _ ->
                   Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ()))
            else
              Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ())
        in
        let codex_target =
          match client, session_id_override with
          | "codex", Some sid -> Some sid
          | _ -> None
        in
        let mo = resolve_model_override ~model_override ~role_pmodel_override ~saved_model_override:None in
        (binary_override, alias_override, extra_args, Some rs, codex_target, broker_root (), model_override, mo)
  in

  (* Use same resolution order as run_outer_loop: --binary > [default_binary] > client default. *)
  let binary_to_check =
    match binary_override with
    | Some b -> b
    | None ->
      (match repo_config_default_binary client with
       | Some b -> b
       | None ->
           let client_cfg = Stdlib.Hashtbl.find clients client in
           client_cfg.binary)
  in
  (match client, find_binary binary_to_check with
   | "codex-headless", Some binary_path when not (bridge_supports_thread_id_fd binary_path) ->
       Printf.eprintf
         "error: codex-headless requires codex-turn-start-bridge with \
          --thread-id-fd support for lazy thread-id persistence\n%!";
       exit 1
   | _ -> ());

  let cfg : instance_config = {
    name; client; session_id = name;
    resume_session_id = Option.value resume_session_id ~default:name;
    codex_resume_target;
    alias = Option.value alias_override ~default:name;
    extra_args;
    created_at = (match existing with Some ex -> ex.created_at | None -> Unix.gettimeofday ());
    broker_root;
    auto_join_rooms = Option.value auto_join_rooms ~default:"swarm-lounge";
    binary_override;
    model_override;
    agent_name;
    last_launch_at = Some (Unix.gettimeofday ());
    last_exit_code = None;
    last_exit_reason = None;
  }
  in
  write_config cfg;

  if client = "tmux" then
    match tmux_location with
    | None ->
        Printf.eprintf "error: c2c start tmux requires --loc <tmux-target>\n%!";
        exit 1
    | Some loc ->
        run_tmux_loop ~name ~tmux_location:loc
          ~tmux_command:(Option.value tmux_command ~default:extra_args)
          ~broker_root ?alias_override ?auto_join_rooms ()
  else

  (* The persisted empty string sentinel means "no thread id yet" for a fresh
     headless launch and must not become `--thread-id ""` on argv. *)
  let launch_resume_session_id =
    match client, cfg.resume_session_id with
    | "codex-headless", sid when String.trim sid = "" -> None
    | _, sid -> Some sid
  in

  run_outer_loop ~name ~client ~extra_args ~broker_root
    ?binary_override ?alias_override ~session_id:cfg.session_id
    ?resume_session_id:launch_resume_session_id
    ?codex_resume_target:cfg.codex_resume_target
    ?model_override:cfg.model_override
    ~one_hr_cache ?kickoff_prompt ?auto_join_rooms
    ?agent_name ?reply_to ?no_prompt ()

(* Signal the managed inner client so the outer loop relaunches it. Designed
   to be callable by an agent running *inside* that client, so the outer
   wrapper gets a fresh process with the --resume flag and the agent picks up
   its conversation intact. Name resolution: explicit arg, else
   C2C_MCP_SESSION_ID (set by c2c start for managed clients). *)
let cmd_restart_self ?(name : string option) () : int =
  let name =
    match name with
    | Some n -> Some n
    | None -> Sys.getenv_opt "C2C_MCP_SESSION_ID"
  in
  match name with
  | None ->
      Printf.eprintf
        "error: no instance name. Pass one as an arg or run inside a \
         managed c2c-start session (C2C_MCP_SESSION_ID is set).\n%!";
      1
  | Some name ->
      (match read_pid (inner_pid_path name) with
       | None ->
           Printf.eprintf
             "error: no inner.pid for '%s' — was it started with a recent \
              c2c? Stop + start to populate.\n%!" name;
           1
       | Some pid when not (pid_alive pid) ->
           Printf.eprintf
             "error: inner pid %d for '%s' not alive (outer may be \
              relaunching).\n%!" pid name;
           1
       | Some pid when pid = Unix.getpid () ->
           Printf.eprintf "error: refusing to signal our own pid\n%!"; 1
       | Some pid ->
           Printf.printf
             "[c2c restart-self] SIGTERM pid %d for '%s' (outer will \
              relaunch)\n%!" pid name;
           (try Unix.kill pid Sys.sigterm; 0
            with Unix.Unix_error (e, _, _) ->
              Printf.eprintf "kill failed: %s\n%!" (Unix.error_message e);
              1))

let cmd_stop (name : string) : int =
  match read_pid (outer_pid_path name) with
  | Some pid when pid_alive pid ->
      (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
      let deadline = Unix.gettimeofday () +. 10.0 in
        while Unix.gettimeofday () < deadline && pid_alive pid do
          Unix.sleepf 0.1
        done;
      if pid_alive pid then
        (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
      0
  | _ ->
      Printf.eprintf "error: instance '%s' is not running.\n%!" name;
      1

let read_kickoff_prompt_opt (name : string) : string option =
  let path = instance_dir name // "kickoff-prompt.txt" in
  if Sys.file_exists path then
    try
      let ic = open_in path in
      Fun.protect ~finally:(fun () -> close_in ic)
        (fun () -> let content = really_input_string ic (in_channel_length ic) in Some content)
    with _ -> None
  else None

(** Wait for a PID to exit using kill(pid, 0) + progressive backoff.
    Returns true if the process exited within the timeout, false otherwise. *)
let wait_for_exit ~(pid : int) ~(timeout_s : float) : bool =
  let interval_s = 0.05 in
  let rec loop elapsed =
    if elapsed >= timeout_s then false
    else if not (pid_alive pid) then true
    else begin
      let sleep_time = min interval_s (timeout_s -. elapsed) in
      if sleep_time <= 0.0 then false
      else (Unix.sleepf sleep_time; loop (elapsed +. sleep_time))
    end
  in
  loop 0.0

(** Build the argv list for re-launching `c2c start` from instance config.
    Preserves all user-facing flags so the restarted session is identical. *)
let build_start_argv ~(cfg : instance_config) : string array =
  let c2c = current_c2c_command () in
  let argv = ref [ c2c; "start"; cfg.client; "-n"; cfg.name ] in
  (* --session-id *)
  argv := !argv @ [ "--session-id"; cfg.resume_session_id ];
  (* --alias *)
  if cfg.alias <> cfg.name then argv := !argv @ [ "--alias"; cfg.alias ];
  (* --bin (binary_override) *)
  (match cfg.binary_override with
   | Some b -> argv := !argv @ [ "--bin"; b ]
   | None -> ());
  (* --model (model_override) *)
  (match cfg.model_override with
   | Some m -> argv := !argv @ [ "--model"; m ]
   | None -> ());
  (* --agent (agent_name) *)
  (match cfg.agent_name with
   | Some n -> argv := !argv @ [ "--agent"; n ]
   | None -> ());
  (* --auto-join-rooms — only if non-default *)
  if cfg.auto_join_rooms <> "swarm-lounge" then
    argv := !argv @ [ "--auto-join"; cfg.auto_join_rooms ];
  (* extra_args — preserve any non-standard flags *)
  argv := !argv @ cfg.extra_args;
  Array.of_list !argv

(** [filter_env_for_restart ()] returns a copy of the current environment
    with [C2C_INSTANCE_NAME] stripped. Used by [cmd_restart] to prevent the
    re-launched [c2c start] from hitting the "cannot run from inside a c2c
    session" guard (c2c.ml:8499). *)
let filter_env_for_restart () =
  let key = "C2C_INSTANCE_NAME" in
  let env_key e = try String.sub e 0 (String.index e '=') with Not_found -> e in
  Unix.environment () |> Array.to_list
  |> List.filter (fun e -> env_key e <> key)
  |> Array.of_list

let cmd_restart ?(session_id_override : string option)
    ?(do_exec : (string array -> unit) option)
    (name : string) ~(timeout_s : float) : int =
  (* Strip C2C_INSTANCE_NAME so the re-launched c2c start doesn't hit the
     "cannot run c2c start from inside a c2c session" guard (c2c.ml:8499).
     Use execve + filtered env rather than execvp to control inheritance. *)
  let do_exec = match do_exec with
    | Some f -> f
    | None -> fun argv -> Unix.execve argv.(0) argv (filter_env_for_restart ())
  in
  let cfg = match load_config_opt name with
    | None ->
        Printf.eprintf "error: no config found for instance '%s'\n%!" name;
        exit 1
    | Some cfg -> cfg
  in
  (* Apply session-id override if given; update last_launch_at for restart *)
  let cfg =
    match session_id_override with
    | None -> { cfg with last_launch_at = Some (Unix.gettimeofday ()) }
    | Some sid ->
        let updated = match cfg.client with
          | "codex" -> { cfg with codex_resume_target = Some sid }
          | "codex-headless" -> { cfg with resume_session_id = sid }
          | "claude" | "opencode" | "kimi" | "crush" ->
              { cfg with resume_session_id = sid }
          | _ -> cfg
        in
        { updated with last_launch_at = Some (Unix.gettimeofday ()) }
  in
  write_config cfg;
  (* Hardening B: re-write expected-cwd so the new outer process's cwd
     (wherever restart was run from) is captured as the new canonical path. *)
  write_expected_cwd ~name;
  (* Kill inner — SIGTERM to whole process group for TUI clients (inner ran with
     setpgid 0 0 so PGID == inner PID; kill(-pid) kills the whole group).
     codex-headless stays in outer's PGID so use positive kill(pid). *)
  let inner_pid = read_pid (inner_pid_path name) in
  let outer_pid = read_pid (outer_pid_path name) in
  (match inner_pid with
   | Some pid when pid_alive pid ->
       let target_pid = if cfg.client = "codex-headless" then pid else -pid in
       Printf.printf "[c2c restart] signalling inner pid %d (pgid=%s) for '%s'\n%!"
         pid (if target_pid = pid then "self" else "group") name;
       (try Unix.kill target_pid Sys.sigterm
        with Unix.Unix_error (e, _, _) ->
          Printf.eprintf "warning: kill %s %d failed: %s\n%!"
            (if target_pid = pid then "inner" else "inner-group") pid (Unix.error_message e))
   | _ ->
       Printf.printf "[c2c restart] no live inner for '%s'\n%!" name);
  (* Wait for outer to exit so we don't have two instances racing on the lock.
     Use kill(pid, 0) + exponential backoff. *)
  (match outer_pid with
   | Some pid when pid_alive pid ->
       Printf.printf "[c2c restart] waiting for outer pid %d to exit (timeout %.0fs)...\n%!" pid timeout_s;
       if not (wait_for_exit ~pid ~timeout_s) then begin
         Printf.eprintf "error: outer pid %d did not exit within %.0fs.\n%!" pid timeout_s;
         Printf.eprintf "  Try 'c2c stop %s' first, then 'c2c start %s -n %s --session-id %s'.\n%!"
           name name name (match load_config_opt name with Some c -> c.resume_session_id | None -> name);
         exit 1
       end
        else Printf.printf "[c2c restart] outer exited cleanly.\n%!"
    | _ -> ());
   (* Capture orphan inbox — messages that arrived while the old outer loop
      was shutting down.  Saved to pending-replay so the MCP server can inject
      them into the new session's inbox after auto_register_startup completes. *)
   let replayed = capture_orphan_inbox_for_restart
     ~broker_root:cfg.broker_root
     ~session_id:cfg.resume_session_id
   in
   if replayed > 0 then
     Printf.printf "[c2c restart] captured %d orphan message%s for replay\n%!"
       replayed (if replayed = 1 then "" else "s");
   (* Re-launch via exec so we replace this process — preserves c2c start's
      non-looping supervisor contract (this process becomes the new outer). *)
   let argv = build_start_argv ~cfg in
  Printf.printf "[c2c restart] launching: %s\n%!" (String.concat " " (Array.to_list argv));
  do_exec argv;
  (* do_exec normally execvp's away and never returns; tests pass a no-op
     stub so the assertion path can run. Return 0 in that case. *)
  0

let cmd_reset_thread ?(do_exec : (string array -> unit) option)
    (name : string) (thread_id : string) : int =
  if String.trim thread_id = "" then begin
    Printf.eprintf "error: thread id must be non-empty\n%!";
    exit 1
  end;
  match load_config_opt name with
  | None ->
      Printf.eprintf "error: no config found for instance '%s'\n%!" name;
      exit 1
  | Some cfg ->
      (match cfg.client with
       | "codex" ->
           write_config { cfg with codex_resume_target = Some thread_id }
       | "codex-headless" ->
           write_config { cfg with resume_session_id = thread_id }
       | _ ->
           Printf.eprintf
             "error: reset-thread currently supports codex and codex-headless instances only (got %s)\n%!"
             cfg.client;
           exit 1);
      cmd_restart ?do_exec name ~timeout_s:5.0

let cmd_instances () : int =
  if not (Sys.file_exists instances_dir) then
    (Printf.printf "No c2c instances found.\n"; 0)
  else
    let entries =
      try Array.to_list (Sys.readdir instances_dir) with _ -> []
    in
    let instances =
      List.filter_map
        (fun name ->
          let full = instances_dir // name in
          if Sys.is_directory full && Sys.file_exists (full // "config.json")
          then Some name else None)
        entries
    in
    if instances = [] then
      (Printf.printf "No c2c instances found.\n"; 0)
    else
      let sorted = List.sort String.compare instances in
      Printf.printf "%-20s %-10s %-8s %-12s %s\n" "NAME" "CLIENT" "STATUS" "UPTIME" "PID";
      Printf.printf "%s\n" (String.make 65 '-');
      List.iter
        (fun name ->
          let cfg_opt = load_config_opt name in
          let client = match cfg_opt with Some c -> c.client | None -> "?" in
          let outer_pid = read_pid (outer_pid_path name) in
          let alive = match outer_pid with Some p -> pid_alive p | None -> false in
          let status = if alive then "ALIVE" else "DEAD" in
          let uptime =
            if alive then
              (try
                 let pid = Option.value outer_pid ~default:0 in
                 let stat_ic = open_in (Printf.sprintf "/proc/%d/stat" pid) in
                 Fun.protect ~finally:(fun () -> close_in stat_ic)
                   (fun () ->
                     let fields = String.split_on_char ' ' (input_line stat_ic) in
                     if List.length fields > 21 then
                       let hz = 100.0 in (* CLK_TCK, almost always 100 on Linux *)
                       let uptime_ic = open_in "/proc/uptime" in
                       Fun.protect ~finally:(fun () -> close_in uptime_ic)
                         (fun () ->
                           let boot_time = float_of_string (List.hd (String.split_on_char ' ' (input_line uptime_ic))) in
                           let start_since_boot = float_of_string (List.nth fields 21) /. hz in
                           let s = boot_time -. start_since_boot in
                           if s < 60.0 then Printf.sprintf "%.0fs" s
                           else if s < 3600.0 then Printf.sprintf "%.0fm" (s /. 60.0)
                           else Printf.sprintf "%.1fh" (s /. 3600.0))
                     else "")
               with _ -> "")
            else ""
          in
          let pid_str = match outer_pid with Some p -> string_of_int p | None -> "?" in
          Printf.printf "%-20s %-10s %-8s %-12s %s\n" name client status uptime pid_str)
        sorted;
      0
