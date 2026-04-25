(* c2c_start — OCaml port of the managed-instance lifecycle. *)

let ( // ) = Filename.concat

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
    loop ()))

(* Codex heartbeat — broker-mail-based heartbeat for codex sessions.
   Sends a heartbeat message to the session's own inbox every [interval_s] seconds.
   This keeps codex sessions alive without PTY injection. The deliver daemon
   picks up the message on its next poll and delivers it to codex.
   Unlike the PTY poker (which injects directly into the TTY), this uses
   the broker inbox like regular mail — more reliable for headless/codex sessions. *)
let start_codex_heartbeat ~(broker_root : string) ~(session_id : string)
    ~(alias : string) ~(interval_s : float) : unit =
  ignore (Thread.create (fun () ->
    let rec loop () =
      Unix.sleepf interval_s;
      (try
        let broker = C2c_mcp.Broker.create ~root:broker_root in
        let content = "Session heartbeat. Poll your C2C inbox and handle any messages." in
        C2c_mcp.Broker.enqueue_message broker ~from_alias:alias ~to_alias:alias ~content ()
      with _ -> ());
      loop ()
    in
    loop ()))

(* setpgid(2) binding — OCaml 5.x's Unix module omits this call.
   Implementation in ocaml/cli/c2c_posix_stubs.c. *)
external setpgid : int -> int -> unit = "caml_c2c_setpgid"

(* tcsetpgrp(3) binding — errors suppressed inside the stub. After the
   child forks into its own pgid, we hand it the controlling terminal
   so it's the tty's foreground process group; otherwise TUIs like
   opencode detect background-pg and exit 109. *)
external tcsetpgrp : Unix.file_descr -> int -> unit = "caml_c2c_tcsetpgrp"
external getpgrp : unit -> int = "caml_c2c_getpgrp"

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

(* ---------------------------------------------------------------------------
 * Client configurations
 * --------------------------------------------------------------------------- *)

type client_config = {
  binary : string;
  deliver_client : string;
  needs_deliver : bool;
  needs_wire_daemon : bool;   (* use OCaml wire-daemon instead of PTY deliver *)
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
      needs_deliver = false; needs_wire_daemon = false; needs_poker = false;
      poker_event = None; poker_from = None;
      extra_env = [] };
  Stdlib.Hashtbl.add clients "codex"
    { binary = "codex"; deliver_client = "codex";
      needs_deliver = true; needs_wire_daemon = false; needs_poker = false;
      poker_event = None; poker_from = None; extra_env = [] };
  (* opencode: the TypeScript c2c plugin (.opencode/plugins/c2c.ts) handles
     delivery in-process via client.session.promptAsync. Python deliver
     daemon is redundant and surfaces a noisy CAP_SYS_PTRACE banner in the
     TUI when setcap is missing. *)
  Stdlib.Hashtbl.add clients "opencode"
    { binary = "opencode"; deliver_client = "opencode";
      needs_deliver = false; needs_wire_daemon = false; needs_poker = false;
      poker_event = None; poker_from = None; extra_env = [] };
  (* kimi: Wire bridge (kimi --wire JSON-RPC) is the current delivery path.
     PTY deliver daemon is deprecated. Wire daemon polls broker and delivers
     via Wire prompt, no PTY access needed. *)
  Stdlib.Hashtbl.add clients "kimi"
    { binary = "kimi"; deliver_client = "kimi";
      needs_deliver = false; needs_wire_daemon = true; needs_poker = true;
      poker_event = Some "heartbeat"; poker_from = Some "kimi-poker";
      extra_env = [] };
  Stdlib.Hashtbl.add clients "crush"
    { binary = "crush"; deliver_client = "crush";
      needs_deliver = true; needs_wire_daemon = false; needs_poker = false;
      poker_event = None; poker_from = None; extra_env = [] };
  (* codex-headless: minimal unblocker for broker-driven XML delivery.
     We wire the bridge behind a c2c-owned stdin pipe and use the deliver daemon
     to feed that pipe. Richer operator steering / queue management remains future work. *)
  Stdlib.Hashtbl.add clients "codex-headless"
    { binary = "codex-turn-start-bridge"; deliver_client = "codex-headless";
      needs_deliver = true; needs_wire_daemon = false; needs_poker = false;
      poker_event = None; poker_from = None; extra_env = [] }

let supported_clients = Stdlib.Hashtbl.fold (fun k _ acc -> k :: acc) clients []

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

let rec mkdir_p dir =
  if Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    try Unix.mkdir dir 0o755
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let write_git_shim ~shim_bin_path ~c2c_bin_path ~real_git_path =
  let oc = open_out shim_bin_path in
  let q = Filename.quote in
  Fun.protect ~finally:(fun () -> close_out oc) @@ fun () ->
  output_string oc "#!/bin/bash\n";
  output_string oc
    "# WARNING: Recursion trap. This shim sits on PATH for managed sessions.\n";
  output_string oc
    "# If `c2c git` or any startup helper re-enters bare `git` without the\n";
  output_string oc
    "# guard below, the process chain becomes shim -> c2c git -> git -> shim\n";
  output_string oc
    "# and can fork-bomb the session. See revert a23b483 before changing this.\n";
  output_string oc "if [ \"${C2C_GIT_SHIM_ACTIVE:-}\" = \"1\" ]; then\n";
  output_string oc (Printf.sprintf "  exec %s \"$@\"\n" (q real_git_path));
  output_string oc "fi\n";
  output_string oc "export C2C_GIT_SHIM_ACTIVE=1\n";
  output_string oc (Printf.sprintf "exec %s git -- \"$@\"\n" (q c2c_bin_path))

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

let current_c2c_command () =
  let fallback =
    if Array.length Sys.argv > 0 then Sys.argv.(0) else "c2c"
  in
  let resolved =
    try Unix.readlink "/proc/self/exe"
    with Unix.Unix_error _ -> fallback
  in
  if Filename.is_relative resolved then Sys.getcwd () // resolved else resolved

let with_file_lock (path : string) (f : unit -> 'a) : 'a =
  let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT ] 0o644 in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
      (try Unix.close fd with _ -> ()))
    (fun () ->
      Unix.lockf fd Unix.F_LOCK 0;
      f ())

let write_json_file_atomic (path : string) (json : Yojson.Safe.t) : unit =
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let oc =
    open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_text ] 0o600 tmp
  in
  let cleanup_tmp () = try Unix.unlink tmp with _ -> () in
  (try
     Fun.protect
       ~finally:(fun () -> try close_out oc with _ -> ())
       (fun () -> Yojson.Safe.to_channel oc json)
   with e ->
     cleanup_tmp ();
     raise e);
  try Unix.rename tmp path
  with e ->
    cleanup_tmp ();
    raise e

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
let deaths_jsonl_path broker_root = broker_root // "deaths.jsonl"
let tmux_info_path name = instance_dir name // "tmux.json"

(* Capture tmux location if running inside a tmux session.
   Writes {session, pane_pid, pane_tty, captured_at} to tmux_info_path.
   Silently skips if $TMUX is not set or tmux commands fail. *)
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
      | Some session, Some pane_pid ->
          (try
            let pane_pid_s = String.trim pane_pid in
            let tmux_json =
              Printf.sprintf
                "{\n  \"session\": \"%s\",\n  \"pane_pid\": \"%s\",\n  \"captured_at\": %.0f\n}\n"
                (String.trim session) pane_pid_s (Unix.gettimeofday ())
            in
            let oc = open_out tmux_info_file in
            Fun.protect ~finally:(fun () -> close_out oc)
              (fun () -> output_string oc tmux_json)
          with _ -> ())
      | _ -> ()

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

let alias_words = [| "aalto"; "aimu"; "aivi"; "alder"; "alm"; "alto"; "anvi"; "arvu"; "aska"; "aster"; "auru"; "briar"; "brio"; "cedar"; "clover"; "corin"; "drift"; "eira"; "elmi"; "ember"; "fenna"; "fennel"; "ferni"; "fjord"; "glade"; "harbor"; "havu"; "hearth"; "helio"; "heron"; "hilla"; "hovi"; "ilma"; "ilmi"; "isvi"; "jara"; "jori"; "junna"; "kaari"; "kajo"; "kalla"; "karu"; "keiju"; "kelo"; "kesa"; "ketu"; "kielo"; "kiru"; "kiva"; "kivi"; "koru"; "kuura"; "laine"; "laku"; "lehto"; "leimu"; "lemu"; "linna"; "lintu"; "lumi"; "lumo"; "lyra"; "marli"; "meadow"; "meru"; "miru"; "mire"; "moro"; "muoto"; "naava"; "nallo"; "niva"; "nori"; "nova"; "nuppu"; "nyra"; "oak"; "oiva"; "olmu"; "ondu"; "orvi"; "otava"; "paju"; "palo"; "pebble"; "pihla"; "pilvi"; "puro"; "quill"; "rain"; "reed"; "revna"; "rilla"; "river"; "roan"; "roihu"; "rook"; "rowan"; "runna"; "sage"; "saima"; "sarka"; "selka"; "silo"; "sirra"; "sola"; "solmu"; "sora"; "sprig"; "starling"; "sula"; "suvi"; "taika"; "tala"; "tavi"; "tilia"; "tovi"; "tuuli"; "tyyni"; "ulma"; "usva"; "valo"; "veru"; "velu"; "vesi"; "viima"; "vireo"; "vuono"; "willow"; "yarrow"; "yola" |]

let generate_alias () =
  let () = Random.self_init () in
  let n = Array.length alias_words in
  let w1 = alias_words.(Random.int n) in
  let w2 = alias_words.(Random.int n) in
  Printf.sprintf "%s-%s" w1 w2

let default_name client =
  let suffix = generate_alias () in
  Printf.sprintf "%s-%s" client suffix

(* ---------------------------------------------------------------------------
 * Broker root
 * --------------------------------------------------------------------------- *)

let git_common_dir () =
  try
    let ic = Unix.open_process_in "git rev-parse --git-common-dir 2>/dev/null" in
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
      (fun () -> String.trim (input_line ic))
  with _ -> ""

let resolve_broker_root () =
  match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
  | Some dir when String.trim dir <> "" -> String.trim dir
  | _ ->
      let git_dir = git_common_dir () in
      if git_dir <> "" && Sys.is_directory git_dir then
        let abs_git =
          if Filename.is_relative git_dir then Sys.getcwd () // git_dir
          else git_dir
        in
        abs_git // "c2c" // "mcp"
      else instances_dir // ".." // ".." // ".." // "c2c" // "mcp"

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
  broker_root : string;
  auto_join_rooms : string;
  binary_override : string option;
  model_override : string option;
}

let write_config (cfg : instance_config) =
  let dir = instance_dir cfg.name in
  mkdir_p dir;
  let path = config_path cfg.name in
  let fields =
    [ ("name", `String cfg.name)
    ; ("client", `String cfg.client)
    ; ("session_id", `String cfg.session_id)
    ; ("resume_session_id", `String cfg.resume_session_id)
    ; ("alias", `String cfg.alias)
    ; ("extra_args", `List (List.map (fun s -> `String s) cfg.extra_args))
    ; ("created_at", `Float cfg.created_at)
    ; ("broker_root", `String cfg.broker_root)
    ; ("auto_join_rooms", `String cfg.auto_join_rooms) ]
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
    try
      let json = Yojson.Safe.from_file path in
      let a = match json with `Assoc a -> a | _ -> raise Not_found in
      let gs k = match List.assoc_opt k a with Some (`String s) -> s | _ -> raise Not_found in
      let gso k = match List.assoc_opt k a with Some (`String s) -> Some s | _ -> None in
      let gf k = match List.assoc_opt k a with Some (`Float f) -> f | Some (`Int i) -> float_of_int i | _ -> raise Not_found in
      let gl k = match List.assoc_opt k a with Some (`List l) -> List.map (function `String s -> s | _ -> raise Not_found) l | _ -> [] in
      Some { name = gs "name"; client = gs "client"; session_id = gs "session_id";
             resume_session_id = gs "resume_session_id"; codex_resume_target = gso "codex_resume_target"; alias = gs "alias";
             extra_args = gl "extra_args"; created_at = gf "created_at";
             broker_root = gs "broker_root"; auto_join_rooms = gs "auto_join_rooms";
             binary_override = gso "binary_override";
             model_override = gso "model_override" }
    with _ -> None

let load_config (name : string) : instance_config =
  match load_config_opt name with
  | Some cfg -> cfg
  | None ->
      Printf.eprintf "error: config not found for instance '%s'\n%!" name;
      exit 1

let persist_headless_thread_id ~(name : string) ~(thread_id : string) : unit =
  match load_config_opt name with
  | None -> ()
  | Some cfg ->
      write_config { cfg with resume_session_id = thread_id }

let persist_codex_resume_target ~(name : string) ~(thread_id : string) : unit =
  match load_config_opt name with
  | None -> ()
  | Some cfg ->
      write_config { cfg with codex_resume_target = Some thread_id }

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
    let base = [
    "C2C_WRAPPER_SELF", "1";  (* marks the wrapper process itself; bash subshells of the managed client don't inherit this *)
    "C2C_MCP_SESSION_ID", name;
    "C2C_INSTANCE_NAME", name;
    "C2C_MCP_AUTO_REGISTER_ALIAS", Option.value alias_override ~default:name;
    "C2C_MCP_BROKER_ROOT", br;
    "C2C_MCP_AUTO_DRAIN_CHANNEL", "0";
    (* Managed sessions opt in to experimental channel-delivery. No-op on
       clients that don't declare experimental.claude/channel in initialize,
       so harmless where unsupported. *)
    "C2C_MCP_CHANNEL_DELIVERY", "1";
    ] in
    let base = base @ auto_join_base in
    let base = base @ match reply_to_override with
      | Some r -> [ "C2C_MCP_REPLY_TO", r ]
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
  let override_keys =
    legacy_native_session_keys @ "C2C_GIT_SHIM_ACTIVE" :: List.map fst additions
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
    let shim_bin_dir = instance_dir name // "bin" in
    let existing_path =
      match Sys.getenv_opt "PATH" with
      | Some path -> path
      | None -> ""
    in
    let path_entry =
      "PATH=" ^ shim_bin_dir ^
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

let refresh_opencode_identity ~name ~alias ~broker_root ~project_dir ~instances_dir =
  let ( // ) = Filename.concat in
  let config_dir = project_dir // ".opencode" in
  (* Patch opencode.json mcp.c2c.environment with identity vars. *)
  let config_path = config_dir // "opencode.json" in
  (if Sys.file_exists config_path then
    (try
      let cfg = Yojson.Safe.from_file config_path in
      (* Do NOT write per-instance values (C2C_MCP_SESSION_ID, C2C_MCP_AUTO_REGISTER_ALIAS)
         to the shared project opencode.json — two concurrent `c2c start opencode`
         instances in the same workdir would race to write different aliases and the
         last writer would overwrite the other, causing broker session_id collisions
         (#60). build_env already sets these correctly in the process environment;
         OpenCode may override inherited env with opencode.json values, so only write
         stable shared config that is safe across all concurrent sessions. *)
      let identity_env = [
        ("C2C_MCP_BROKER_ROOT", `String broker_root);
        ("C2C_MCP_AUTO_JOIN_ROOMS", `String "swarm-lounge");
        ("C2C_MCP_AUTO_DRAIN_CHANNEL", `String "0");
        ("C2C_CLI_COMMAND", `String (current_c2c_command ()));
      ] in
      let merge_env env_obj new_pairs =
        let existing = match env_obj with `Assoc p -> p | _ -> [] in
        let keys = List.map fst new_pairs in
        (* Also strip per-instance keys that must never appear in the shared
           project config — old Python installs wrote AUTO_REGISTER_ALIAS here. *)
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
      (* Write with indentation to keep the project config human-readable. *)
      let tmp = config_path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
      (try
        let oc = open_out tmp in
        (try Yojson.Safe.pretty_to_channel oc updated; output_char oc '\n'
         with e -> close_out_noerr oc; raise e);
        close_out oc;
        Unix.rename tmp config_path
      with _ -> ())
    with _ -> ()));
  (* Update sidecar c2c-plugin.json with current identity.
     Write to per-instance path (instances/<name>/) to avoid concurrent
     instances in the same project dir from clobbering each other's identity.
     The plugin reads from the same path (with project-level fallback). *)
  let sidecar_path = instances_dir // name // "c2c-plugin.json" in
  (try
    let existing = if Sys.file_exists sidecar_path then
      (match Yojson.Safe.from_file sidecar_path with `Assoc p -> p | _ -> [])
    else []
    in
    let identity = [
      ("session_id", `String name);
      ("alias", `String alias);
      ("broker_root", `String broker_root);
    ] in
    let keys = List.map fst identity in
    let kept = List.filter (fun (k, _) -> not (List.mem k keys)) existing in
    write_json_file_atomic sidecar_path (`Assoc (kept @ identity))
  with _ -> ())

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
  let script_path =
    match repo_toplevel () with
    | "" -> "c2c_mcp.py"
    | dir -> dir // "c2c_mcp.py"
  in
  `Assoc [ "mcpServers",
    `Assoc [ "c2c",
      `Assoc [ "type", `String "stdio";
               "command", `String "python3";
               "args", `List [ `String script_path ];
               "env", `Assoc [
                 "C2C_MCP_BROKER_ROOT", `String br;
                 "C2C_MCP_SESSION_ID", `String name;
                 "C2C_MCP_AUTO_REGISTER_ALIAS", `String alias;
                 "C2C_MCP_AUTO_JOIN_ROOMS", `String "swarm-lounge";
                 "C2C_MCP_AUTO_DRAIN_CHANNEL", `String "0";
               ] ] ] ]

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
    ?(agent_name : string option)
    ?(kickoff_prompt : string option) () : string list =
  let args =
    match client with
    | "claude" ->
        (* Use --session-id <uuid> to create a brand-new session with a known id,
           or --resume <sid> to reattach an existing one. --session-id errors out
           if a session with that id already exists; --resume errors out if it
           doesn't. So probe ~/.claude/projects/*/<uuid>.jsonl to pick.
            --dangerously-load-development-channels server:c2c enables Claude Code to
            process notifications/claude/channel as <channel> tags. --channels is
            removed (Max 2026-04-24) to prevent parser confusion in cc-* wrappers. *)
        let dev_channel_args =
          [ "--dangerously-load-development-channels"; "server:c2c"
          ]
        in
        let agent_args =
          match agent_name with
          | Some name -> [ "--agent"; name ]
          | None -> []
        in
        let kickoff_args =
          match kickoff_prompt with
          | Some p when p <> "" -> [ p ]
          | _ -> []
        in
        (match resume_session_id with
         | Some sid ->
             let flag =
               if claude_session_exists sid then "--resume" else "--session-id"
             in
             [ flag; sid; "--name"; name;
             ] @ dev_channel_args @ agent_args
         | None -> [ "--name"; name ] @ dev_channel_args @ agent_args @ kickoff_args)
    | "opencode" ->
        (* OpenCode rejects UUIDs — session IDs must start with "ses". Only
           pass --session when resuming a prior OpenCode-generated ID.
           --log-level INFO writes to the log dir. Do NOT add --print-logs:
           it streams to stdout and floods the TUI. client.log symlink in
           the instance dir is the supported forensic path. *)
        let session_arg = match resume_session_id with
         | Some sid when String.length sid >= 3 && String.sub sid 0 3 = "ses" ->
             [ "--session"; sid ]
         | _ -> []
        in
        [ "--log-level"; "INFO" ] @ session_arg
    | "codex" ->
        (match codex_resume_target with
         | Some sid when String.trim sid <> "" -> [ "resume"; sid ]
         | _ ->
             (match resume_session_id with Some _ -> [ "resume"; "--last" ] | None -> []))
    | "codex-headless" ->
        [ "--stdin-format"; "xml";
          "--codex-bin"; "codex";
          (* Keep headless on approval-policy=never until the bridge exposes a
             machine-readable approval handoff. See APPROVAL_FLOW_REQ.md in the
             Codex fork. *)
          "--approval-policy"; "never" ]
        @ (match resume_session_id with
           | Some sid when String.trim sid <> "" -> [ "--thread-id"; sid ]
           | _ -> [])
        @ (match thread_id_fd with
           | Some fd -> [ "--thread-id-fd"; fd ]
           | None -> [])
    | _ -> []
  in
  let args =
    match model_override with
    | Some model when String.trim model <> "" -> args @ [ "--model"; model ]
    | _ -> args
  in
  let args =
    match client, codex_xml_input_fd with
    | "codex", Some fd -> [ "--xml-input-fd"; fd ] @ args
    | _ -> args
  in
  if client = "kimi" && not (has_explicit_kimi_mcp_config extra_args) then
    let cfg_path = kimi_mcp_config_path name in
    let dir = Filename.dirname cfg_path in
    mkdir_p dir;
    let oc = open_out cfg_path in
    Fun.protect ~finally:(fun () -> close_out oc)
      (fun () ->
        Yojson.Safe.pretty_to_channel oc (build_kimi_mcp_config name broker_root alias_override);
        output_string oc "\n");
    "--mcp-config-file" :: cfg_path :: (args @ extra_args)
  else
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
  (* Prefer the installed sidecar entrypoint so managed sessions launched in
     arbitrary target repos still find delivery tooling. Fall back to the
     repo-local Python script for in-repo development. *)
  match find_binary "c2c-deliver-inbox" with
  | Some binary_path -> Some (binary_path, [])
  | None ->
      match resolve_repo_root ~broker_root with
      | "" -> None
      | dir ->
          let p = dir // "c2c_deliver_inbox.py" in
          if Sys.file_exists p then Some ("python3", [ p ]) else None

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
  |> add_if Kimi_wire (client = "kimi")
  |> add_if Codex_xml_fd (client = "codex" && codex_supports_xml_input_fd binary_path)
  |> add_if Codex_headless_thread_id_fd
       (client = "codex-headless" && bridge_supports_thread_id_fd binary_path)
  |> List.rev

let parse_rfc3339_utc s =
  match Ptime.of_rfc3339 s with
  | Ok (t, _, _) -> Some (Ptime.to_float_s t)
  | Error _ -> None

let opencode_statefile_path (name : string) : string =
  instance_dir name // "oc-plugin-state.json"

let assoc_opt name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let string_member name json =
  match assoc_opt name json with
  | Some (`String value) -> Some value
  | _ -> None

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
  | "kimi" ->
      if has C2c_capability.Kimi_wire then "wire" else "poll_only"
  | "codex" ->
      if has C2c_capability.Codex_xml_fd then "xml_fd"
      else if has C2c_capability.Pty_inject then "pty_notify"
      else "unavailable"
  | "codex-headless" ->
      if has C2c_capability.Codex_headless_thread_id_fd then "xml_fifo"
      else "unavailable"
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
            C2c_mcp.Broker.append_archive broker ~session_id:name ~messages;
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

let wire_bridge_script_path ~(broker_root : string) : string option =
  match resolve_repo_root ~broker_root with
  | "" -> None
  | dir ->
      let p = dir // "c2c_kimi_wire_bridge.py" in
      if Sys.file_exists p then Some p else None

(* ---------------------------------------------------------------------------
 * Sidecar daemon spawning
 * --------------------------------------------------------------------------- *)

let start_deliver_daemon ~(name : string) ~(client : string)
    ~(broker_root : string) ?(child_pid_opt : int option)
    ?command_override
    ?(xml_output_fd : string option) ?(xml_output_path : string option) () : int option =
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
        @ (match child_pid_opt with None -> [] | Some p -> [ "--pid"; string_of_int p ])
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

let start_wire_daemon ~(name : string) ~(alias : string)
    ~(broker_root : string) () : int option =
  let command = "kimi" in
  let work_dir = Sys.getcwd () in
  let interval = 5.0 in
  let (_status, _action) =
    C2c_wire_daemon.start_daemon
      ~session_id:name ~alias ~broker_root ~command ~work_dir ~interval
  in
  _status.C2c_wire_daemon.pid

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
    ?(agent_name : string option) ?(reply_to : string option) () : int =
  let session_id = Option.value session_id ~default:name in
  let cfg =
    try Stdlib.Hashtbl.find clients client
    with Not_found ->
      Printf.eprintf "error: unknown client '%s'\n%!" client; exit 1
  in
  let binary = Option.value binary_override ~default:cfg.binary in
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
         Sidecar children (deliver, poker, wire) are started with their own
         process groups; they will eventually become zombies until the outer
         process itself exits, which is acceptable — the outer loop is short-lived. *)

      let inst_dir = instance_dir name in
      mkdir_p inst_dir;
      capture_and_write_tmux_location name;
      if repo_config_git_attribution () then begin
        let shim_bin_dir = inst_dir // "bin" in
        mkdir_p shim_bin_dir;
        let shim_bin_path = shim_bin_dir // "git" in
        let c2c_bin_path = current_c2c_command () in
        let real_git_path = Git_helpers.find_real_git () in
        (* WARNING: this shim is intentionally dangerous-looking because it is.
           It lives on PATH inside managed sessions and can recurse into
           `c2c git` catastrophically if either the env guard or the baked
           real-git fallback is removed. The previous unguarded version caused
           a fork bomb and was reverted in a23b483. Keep the warning block in
           the generated shim and update the tmux dogfood coverage if this
           behavior changes. *)
        write_git_shim ~shim_bin_path ~c2c_bin_path ~real_git_path;
        (try Unix.chmod shim_bin_path 0o755 with _ -> ());
      end;
      (* Registry precheck: human-readable "alias alive" error before flock. *)
      check_registry_alias_alive ~broker_root ~name;
      (* Exclusive instance lock: prevents two concurrent starts for the same
         name; kernel releases on exit so no stale-lock cleanup needed.
         _lock_fd must stay in scope to hold the lock for the outer lifetime. *)
      let _lock_fd = acquire_instance_lock ~name in

      let deliver_pid = ref None in
      let poker_pid = ref None in
      let wire_pid = ref None in
      (* Inner child PID — set after fork so the SIGTERM handler can kill it. *)
      let inner_child_pid = ref None in

      let stop_sidecar pid_opt =
        match pid_opt with
        | None -> ()
        | Some p ->
            (try Unix.kill p Sys.sigterm with Unix.Unix_error _ -> ());
            for _ = 1 to 30 do
              if not (pid_alive p) then () else Unix.sleepf 0.1
            done;
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
        stop_sidecar !wire_pid;
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

      (* Build env *)
      let env = build_env ~broker_root_override:(Some broker_root)
          ~auto_join_rooms_override:auto_join_rooms ~client:(Some client)
          ~reply_to_override:reply_to
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
      (* When launching opencode with a kickoff prompt, signal the c2c plugin
         to proactively create a session and deliver the prompt if the TUI
         never fires session.created on its own (e.g. under tmux/non-interactive
         stdin). Use a per-instance path so concurrent launches don't clobber
         each other's kickoff. See #64. *)
      let kickoff_inst_path = inst_dir // "kickoff-prompt.txt" in
      let env =
        if client = "opencode" && Option.is_some kickoff_prompt then
          Array.append env [|
            "C2C_AUTO_KICKOFF=1";
            Printf.sprintf "C2C_KICKOFF_PROMPT_PATH=%s" kickoff_inst_path;
          |]
        else env
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

      (* Launch args *)
      (* cc- wrappers (cc-mm, cc-w, etc.) are profile launchers designed to be called
         directly without extra args. They handle their own session/profile management.
         For these, we invoke them directly so they start an interactive session. *)
      let launch_args =
        let codex_xml_input_fd =
          if client = "codex" && codex_supports_xml_input_fd binary_path then Some "3"
          else None
        in
        let thread_id_fd =
          if client = "codex-headless" then Some "5" else None
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
      let cmd =
        match client, headless_xml_fifo, thread_id_handoff_path_opt with
        | "codex-headless", Some fifo_path, Some handoff_path ->
            [ "/bin/bash"; "-lc";
              "bridge=\"$1\"; fifo=\"$2\"; handoff=\"$3\"; shift 3; \
               exec \"$bridge\" \"$@\" < \"$fifo\" 5> \"$handoff\"";
              "c2c-codex-headless";
              binary_path;
              fifo_path;
              handoff_path ]
            @ launch_args
        | _ -> binary_path :: launch_args
      in

      (* Debug: print full cmd before fork when C2C_START_DEBUG set. Intentional
         verbosity — this costs one line per launch and is invaluable when
         diagnosing "why did claude/cc-mm reject the channel flags?" bugs. *)
      (match Sys.getenv_opt "C2C_START_DEBUG" with
       | Some v when v <> "" && v <> "0" ->
         Printf.eprintf "[c2c-start/debug] exec: %s\n%!"
           (String.concat " " (List.map Filename.quote cmd))
       | _ -> ());

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
              if stdin_is_tty then begin
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
          refresh_opencode_identity ~name ~alias ~broker_root ~project_dir ~instances_dir
        end
      end);

      (* Write kickoff prompt to the per-instance path set above in C2C_KICKOFF_PROMPT_PATH.
         Using inst_dir isolates concurrent launches so they can't clobber each other. *)
      (match kickoff_prompt with
       | Some prompt when client = "opencode" ->
           (try
             let oc = open_out kickoff_inst_path in
             Fun.protect ~finally:(fun () -> close_out oc)
               (fun () -> output_string oc prompt)
           with _ -> ())
       | _ -> ());

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
         loop sets SIGCHLD=SIG_IGN at line 488 to auto-reap its own
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
                (try Unix.close outer_stderr_fd with _ -> ());
                (try Unix.execvpe (List.hd cmd) (Array.of_list cmd) env
                 with e ->
                   Printf.eprintf "exec %s failed: %s\n%!" binary_path (Printexc.to_string e);
                   exit 127)
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
             begin
               match
                 start_deliver_daemon
                   ~name
                   ~client
                   ~broker_root
                   ?child_pid_opt:(Some pid)
                   ?xml_output_fd:(Option.map fst xml_output_fd)
                   ?xml_output_path
                   ()
               with
               | Some p ->
                   deliver_pid := Some p;
                   write_pid (deliver_pid_path name) p
               | None ->
                   (match xml_output_fd with
                    | Some _ ->
                        (match
                           start_deliver_daemon ~name ~client ~broker_root ?child_pid_opt:(Some pid) ()
                         with
                         | Some p ->
                             deliver_pid := Some p;
                             write_pid (deliver_pid_path name) p
                         | None -> ())
                    | None -> ());
               match xml_output_fd with
               | Some (_, fd4) -> (try Unix.close fd4 with _ -> ())
               | None -> ()
             end);
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
          (* Start wire-daemon (Kimi Wire bridge delivery, replaces PTY deliver). *)
          (if !wire_pid = None && cfg.needs_wire_daemon then begin
             let alias = Option.value alias_override ~default:name in
             match start_wire_daemon ~name ~alias ~broker_root () with
             | Some p -> wire_pid := Some p
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
          (* Start codex heartbeat — broker-mail-based heartbeat every 4 minutes.
             Codex has no PTY poker, so without this the session can go stale.
             Uses Broker.enqueue_message (like mail) so the deliver daemon picks it up. *)
          (if client = "codex" then
             start_codex_heartbeat ~broker_root ~session_id:name
               ~alias:effective_alias ~interval_s:240.0);
          pid
        with Unix.Unix_error (Unix.EINTR, _, _) -> 0
      in

      let exit_code =
        if child_pid_opt = 0 then 130
        else
          (try
             let rec wait_for_child () =
               match Unix.waitpid [ Unix.WUNTRACED ] child_pid_opt with
               | _, Unix.WSIGNALED n -> 128 + n
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
               | _, Unix.WEXITED n -> n
               | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_for_child ()
             in
             let code = wait_for_child () in
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
             code
           with _ -> 1)
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

      (* Record structured death on non-zero exit *)
      if exit_code <> 0 then
        record_death ~broker_root ~name ~client ~exit_code ~duration_s:elapsed ~inst_dir;

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

let cmd_start ~(client : string) ~(name : string) ~(extra_args : string list)
    ?(binary_override : string option) ?(alias_override : string option)
    ?(session_id_override : string option) ?(model_override : string option)
    ?(one_hr_cache = false)
    ?(kickoff_prompt : string option) ?(auto_join_rooms : string option)
    ?(agent_name : string option) ?(reply_to : string option) () : int =
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
  let (binary_override, alias_override, extra_args, resume_session_id, codex_resume_target, broker_root, model_override) =
    match existing with
    | Some ex ->
        if ex.client <> client then
          (Printf.eprintf
             "error: instance '%s' was previously a %s instance. Cannot resume as %s. Use 'c2c stop %s' first.\n%!"
             name ex.client client name;
           exit 1);
        let bo = if binary_override = None then None else binary_override in
        let ao = if alias_override = None then Some ex.alias else alias_override in
        let ea = if extra_args = [] then ex.extra_args else extra_args in
        let mo = match model_override with Some _ -> model_override | None -> ex.model_override in
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
          | _, _ -> ex.codex_resume_target
        in
        (bo, ao, ea, rs, codex_target, ex.broker_root, mo)
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
        (binary_override, alias_override, extra_args, Some rs, codex_target, broker_root (), model_override)
  in

  let binary_to_check =
    match binary_override with
    | Some b -> b
    | None ->
        let client_cfg = Stdlib.Hashtbl.find clients client in
        client_cfg.binary
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
  }
  in
  write_config cfg;

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
    ?agent_name ?reply_to ()

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

let cmd_restart ?(session_id_override : string option) (name : string) : int =
  match load_config_opt name with
  | None ->
      Printf.eprintf "error: no config found for instance '%s'\n%!" name;
      exit 1
  | Some cfg ->
      let cfg =
        match session_id_override with
        | None -> cfg
        | Some sid ->
            let updated =
              match cfg.client with
              | "codex" -> { cfg with codex_resume_target = Some sid }
              | "codex-headless" -> { cfg with resume_session_id = sid }
              | "claude" | "opencode" | "kimi" | "crush" ->
                  { cfg with resume_session_id = sid }
              | _ -> cfg
            in
            write_config updated;
            updated
      in
      ignore (cmd_stop name);
      let kickoff_prompt = read_kickoff_prompt_opt name in
      run_outer_loop ~name ~client:cfg.client ~extra_args:cfg.extra_args
        ~broker_root:cfg.broker_root
        ?binary_override:cfg.binary_override
        ?alias_override:(Some cfg.alias)
        ?resume_session_id:(Some cfg.resume_session_id)
        ?codex_resume_target:cfg.codex_resume_target
        ?model_override:cfg.model_override
        ?kickoff_prompt ()

let cmd_reset_thread (name : string) (thread_id : string) : int =
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
      cmd_restart name

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
