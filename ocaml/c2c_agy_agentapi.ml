(* C2c_agy_agentapi — shared agentapi push helpers for agy (P4).

   Extracted so DeliveryEndpoint (c2c_mcp lib) and c2c_agy_deliver (cli)
   share one implementation of env + send-message.

   Path note: env lives under the *managed* instances dir
   (C2C_INSTANCES_DIR / ~/.local/share/c2c/instances), not ~/.c2c/instances.
   The latter was a silent split that left deliver-watch reading empty while
   hooks (when they fired) wrote the wrong tree.
*)

let ( // ) = Filename.concat

let home_dir () = try Sys.getenv "HOME" with Not_found -> "/tmp"

let managed_instances_root () =
  match Sys.getenv_opt "C2C_INSTANCES_DIR" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ -> home_dir () // ".local" // "share" // "c2c" // "instances"

let instance_dir name = managed_instances_root () // name

let env_file_path session_id = instance_dir session_id // "agy-env.json"

type agy_env = {
  ls_address : string;
  conversation_id : string;
}

type scan_hit = {
  ls_http_port : int option;
  conversation_id : string option;
}

let read_agy_env session_id : agy_env option =
  let path = env_file_path session_id in
  if not (Sys.file_exists path) then None
  else
    try
      let json = Yojson.Safe.from_file path in
      match json with
      | `Assoc fields ->
          let ls =
            List.assoc "ls_address" fields |> function
            | `String s -> s
            | _ -> raise Exit
          in
          let conv =
            List.assoc "conversation_id" fields |> function
            | `String s -> s
            | _ -> raise Exit
          in
          let ls = String.trim ls in
          let conv = String.trim conv in
          if ls = "" || conv = "" then None
          else Some { ls_address = ls; conversation_id = conv }
      | _ -> None
    with _ -> None

let write_agy_env session_id ~ls_address ~conversation_id =
  let dir = instance_dir session_id in
  (try C2c_io.mkdir_p dir with _ -> ());
  let path = env_file_path session_id in
  let json =
    `Assoc
      [ ("ls_address", `String (String.trim ls_address))
      ; ("conversation_id", `String (String.trim conversation_id))
      ]
  in
  try Yojson.Safe.to_file path json with _ -> ()

(* ---- CLI log discovery -------------------------------------------------- *)

let is_uuid_like s =
  let s = String.trim s in
  String.length s = 36
  &&
  try
    for i = 0 to 35 do
      let c = s.[i] in
      match i with
      | 8 | 13 | 18 | 23 -> if c <> '-' then raise Exit
      | _ ->
          match c with
          | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> ()
          | _ -> raise Exit
    done;
    true
  with Exit -> false

let parse_http_ls_port_from_line line =
  (* agy 1.1.x: "Language server listening on random port at 35817 for HTTP" *)
  let needle = "Language server listening on random port at " in
  match String.index_opt line 'L' with
  | None -> None
  | Some _ ->
      (try
         let idx =
           let rec find i =
             if i + String.length needle > String.length line then raise Not_found
             else if String.sub line i (String.length needle) = needle then i
             else find (i + 1)
           in
           find 0
         in
         let rest =
           String.sub line
             (idx + String.length needle)
             (String.length line - idx - String.length needle)
         in
         (* rest: "<port> for HTTP" or "<port> for HTTPS (gRPC)" *)
         let port_s =
           match String.index_opt rest ' ' with
           | Some sp -> String.sub rest 0 sp
           | None -> rest
         in
         let after_port =
           String.trim
             (String.sub rest (String.length port_s)
                (String.length rest - String.length port_s))
         in
         (* Only accept plain HTTP — not HTTPS (gRPC). "for HTTP" is a prefix of
            "for HTTPS", so require end-of-token after HTTP. *)
         let is_plain_http =
           after_port = "for HTTP"
           || (String.length after_port > 8
               && String.sub after_port 0 8 = "for HTTP"
               && after_port.[8] <> 'S'
               && after_port.[8] <> 's')
         in
         if is_plain_http then
           match int_of_string_opt (String.trim port_s) with
           | Some p when p > 0 && p <= 65535 -> Some p
           | _ -> None
         else None
       with _ -> None)

let parse_created_conversation_from_line line =
  let needle = "Created conversation " in
  try
    let idx =
      let rec find i =
        if i + String.length needle > String.length line then raise Not_found
        else if String.sub line i (String.length needle) = needle then i
        else find (i + 1)
      in
      find 0
    in
    let rest =
      String.sub line
        (idx + String.length needle)
        (String.length line - idx - String.length needle)
      |> String.trim
    in
    let token =
      match String.index_opt rest ' ' with
      | Some sp -> String.sub rest 0 sp
      | None -> rest
    in
    let token =
      (* strip trailing punctuation if any *)
      let len = String.length token in
      if len > 0 && (token.[len - 1] = '.' || token.[len - 1] = ',') then
        String.sub token 0 (len - 1)
      else token
    in
    if is_uuid_like token then Some token else None
  with _ -> None

let scan_cli_log path : scan_hit option =
  if not (Sys.file_exists path) then None
  else
    try
      let ic = open_in path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
          let port = ref None in
          let conv = ref None in
          (try
             while true do
               let line = input_line ic in
               (match parse_http_ls_port_from_line line with
                | Some p -> port := Some p
                | None -> ());
               (match parse_created_conversation_from_line line with
                | Some c -> conv := Some c
                | None -> ())
             done
           with End_of_file -> ());
          match !port, !conv with
          | None, None -> None
          | p, c -> Some { ls_http_port = p; conversation_id = c })
    with _ -> None

let default_cli_log_dir () =
  home_dir () // ".gemini" // "antigravity-cli" // "log"

let latest_cli_log ?(dir = default_cli_log_dir ()) () : string option =
  if not (Sys.file_exists dir && Sys.is_directory dir) then None
  else
    try
      let entries =
        Sys.readdir dir |> Array.to_list
        |> List.filter (fun e ->
               let len = String.length e in
               len > 4 && String.sub e (len - 4) 4 = ".log")
      in
      match entries with
      | [] -> None
      | es ->
          (* Filenames are cli-YYYYMMDD_HHMMSS.log — lexicographic max is newest. *)
          let latest = List.hd (List.sort (fun a b -> String.compare b a) es) in
          Some (dir // latest)
    with _ -> None

let cli_log_from_pid (pid : int) : string option =
  (* agy redirects stderr/stdout to the CLI log; prefer that over global latest. *)
  if pid <= 0 then None
  else
    let try_fd n =
      try
        let target = Unix.readlink (Printf.sprintf "/proc/%d/fd/%d" pid n) in
        if
          Filename.check_suffix target ".log"
          &&
          (try
             let needle = "antigravity-cli" // "log" in
             let rec contains s sub =
               let sl = String.length s and sul = String.length sub in
               let rec loop i =
                 if i + sul > sl then false
                 else if String.sub s i sul = sub then true
                 else loop (i + 1)
               in
               loop 0
             in
             contains target needle
           with _ -> false)
        then Some target
        else None
      with _ -> None
    in
    match try_fd 2 with Some p -> Some p | None -> try_fd 1

let listen_ports_for_pid (pid : int) : int list =
  (* Best-effort: LISTEN sockets owned by [pid] via /proc/net/tcp + fd table.
     Used only as a fallback when the CLI log is missing the HTTP line. *)
  if pid <= 0 || not (Sys.file_exists (Printf.sprintf "/proc/%d" pid)) then []
  else
    let listen_inodes_and_ports file =
      let acc = ref [] in
      (try
         let ic = open_in file in
         Fun.protect
           ~finally:(fun () -> close_in_noerr ic)
           (fun () ->
             (try ignore (input_line ic) with End_of_file -> ());
             try
               while true do
                 let line = input_line ic in
                 let f =
                   List.filter (fun s -> s <> "") (String.split_on_char ' ' line)
                 in
                 match f with
                 | _sl :: local :: _rem :: st :: _ when st = "0A" ->
                     let port_opt =
                       match String.rindex_opt local ':' with
                       | Some ci ->
                           let hex =
                             String.sub local (ci + 1)
                               (String.length local - ci - 1)
                           in
                           (try Some (int_of_string ("0x" ^ hex)) with _ -> None)
                       | None -> None
                     in
                     let ino = List.nth_opt f 9 in
                     (match port_opt, ino with
                      | Some p, Some i when p > 0 && p <= 65535 ->
                          acc := (i, p) :: !acc
                      | _ -> ())
                 | _ -> ()
               done
             with End_of_file -> ())
       with _ -> ());
      !acc
    in
    let candidates =
      listen_inodes_and_ports "/proc/net/tcp"
      @ listen_inodes_and_ports "/proc/net/tcp6"
    in
    let fddir = Printf.sprintf "/proc/%d/fd" pid in
    let held = ref [] in
    (try
       Array.iter
         (fun e ->
           match (try Some (Unix.readlink (fddir // e)) with _ -> None) with
           | Some target ->
               List.iter
                 (fun (ino, port) ->
                   if target = Printf.sprintf "socket:[%s]" ino then
                     held := port :: !held)
                 candidates
           | None -> ())
         (Sys.readdir fddir)
     with _ -> ());
    List.sort_uniq compare !held

let probe_http_ls_port (port : int) : bool =
  (* agy HTTP LS answers /healthz with {"status":"ok",...}. HTTPS gRPC does not. *)
  if port <= 0 || port > 65535 then false
  else
    let url = Printf.sprintf "http://127.0.0.1:%d/healthz" port in
    let cmd =
      Printf.sprintf
        "curl -sS -m 1 -o /dev/null -w '%%{http_code}' %s 2>/dev/null || true"
        (Filename.quote url)
    in
    try
      let ic = Unix.open_process_in cmd in
      let code = String.trim (try input_line ic with End_of_file -> "") in
      ignore (Unix.close_process_in ic);
      code = "200"
    with _ -> false

let pick_http_port_from_pid (pid : int) : int option =
  let ports = listen_ports_for_pid pid in
  List.find_opt probe_http_ls_port ports

let agentapi_send_timeout_s = 15.0

let wait_child_bounded ~(timeout : float) (pid : int) : bool =
  let deadline = Unix.gettimeofday () +. timeout in
  let kill_and_reap () : bool =
    (try Unix.kill pid Sys.sigterm with _ -> ());
    let kdeadline = Unix.gettimeofday () +. 2.0 in
    let rec reap () =
      match
        (try Unix.waitpid [ Unix.WNOHANG ] pid with _ -> (pid, Unix.WEXITED 0))
      with
      | 0, _ when Unix.gettimeofday () < kdeadline ->
          Unix.sleepf 0.05;
          reap ()
      | 0, _ ->
          (try Unix.kill pid Sys.sigkill with _ -> ());
          (try ignore (Unix.waitpid [] pid) with _ -> ())
      | _ -> ()
    in
    reap ();
    false
  in
  let rec wait () =
    match
      (try Unix.waitpid [ Unix.WNOHANG ] pid with _ -> (pid, Unix.WEXITED 127))
    with
    | 0, _ ->
        if Unix.gettimeofday () >= deadline then kill_and_reap ()
        else (
          Unix.sleepf 0.05;
          wait ())
    | _, Unix.WEXITED 0 -> true
    | _ -> false
  in
  wait ()

let with_ls_env ~(ls_address : string) (env : string array) : string array =
  env
  |> Array.to_list
  |> List.filter (fun s ->
         not
           (String.length s >= 23
            && String.sub s 0 23 = "ANTIGRAVITY_LS_ADDRESS=")
         && not
              (String.length s >= 23
               && String.sub s 0 23 = "ANTIGRAVITY_PROJECT_ID="))
  |> fun l ->
  (* agy 1.1.x agentapi new-conversation requires project_id when the TUI has a
     project_env_config; default-cli-project matches the interactive path. *)
  (Printf.sprintf "ANTIGRAVITY_LS_ADDRESS=%s" ls_address)
  :: "ANTIGRAVITY_PROJECT_ID=default-cli-project"
  :: l
  |> Array.of_list

(* The wake command, built pure so tests can assert the exact argv without
   spawning `agy`. [send-message] targets an EXISTING conversation by id, and
   that id must be the TUI's OWN live conversation for the wake to land — a
   c2c-minted (headless, [new-conversation]) conversation does not wake the live
   TUI (cold-start gap #78). *)
let agentapi_send_argv ~(conversation_id : string) ~(content : string) :
    string array =
  [| "agy"
   ; "agentapi"
   ; "send-message"
   ; "--title=c2c inbound"
   ; conversation_id
   ; content
  |]

let run_agentapi_send ~(ls_address : string) ~(conversation_id : string)
    ~(content : string) : bool =
  let command = "agy" in
  let argv = agentapi_send_argv ~conversation_id ~content in
  let env = with_ls_env ~ls_address (Unix.environment ()) in
  let devnull = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  Fun.protect
    ~finally:(fun () -> try Unix.close devnull with _ -> ())
    (fun () ->
      try
        let pid =
          Unix.create_process_env command argv env Unix.stdin devnull devnull
        in
        wait_child_bounded ~timeout:agentapi_send_timeout_s pid
      with _ -> false)

let agentapi_new_conversation_argv ~(model : string) ~(title : string)
    ~(prompt : string) : string array =
  [| "agy"
   ; "agentapi"
   ; "new-conversation"
   ; "--model=" ^ model
   ; "--title=" ^ title
   ; prompt
  |]

let run_agentapi_new_conversation ~(ls_address : string) ?(model = "flash_lite")
    ?(title = "c2c-wake") ~(prompt : string) () : string option =
  (* Test seam: force a minted conversation id without spawning `agy`.
     Used only to prove #78 does NOT accept headless mints as wake targets. *)
  (match Sys.getenv_opt "C2C_AGY_NEW_CONVERSATION_FIXTURE" with
   | Some id when is_uuid_like id -> Some (String.trim id)
   | Some _ | None ->
  (* Capture stdout JSON: {"response":{"newConversation":{"conversationId":"..."}}} *)
  let command = "agy" in
  let argv = agentapi_new_conversation_argv ~model ~title ~prompt in
  let env = with_ls_env ~ls_address (Unix.environment ()) in
  let stdout_r, stdout_w = Unix.pipe ~cloexec:true () in
  let devnull = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.close devnull with _ -> ());
      (try Unix.close stdout_r with _ -> ());
      (try Unix.close stdout_w with _ -> ()))
    (fun () ->
      try
        let pid =
          Unix.create_process_env command argv env Unix.stdin stdout_w devnull
        in
        (try Unix.close stdout_w with _ -> ());
        let ic = Unix.in_channel_of_descr stdout_r in
        let buf = Buffer.create 512 in
        (try
           while true do
             Buffer.add_channel buf ic 4096
           done
         with End_of_file -> ());
        let ok = wait_child_bounded ~timeout:agentapi_send_timeout_s pid in
        if not ok then None
        else
          let raw = Buffer.contents buf in
          try
            match Yojson.Safe.from_string raw with
            | `Assoc top ->
                let resp = List.assoc "response" top in
                (match resp with
                 | `Assoc fields ->
                     (match List.assoc_opt "newConversation" fields with
                      | Some (`Assoc nc) ->
                          (match List.assoc_opt "conversationId" nc with
                           | Some (`String id) when is_uuid_like id -> Some id
                           | _ -> None)
                      | _ -> None)
                 | _ -> None)
            | _ -> None
          with _ -> None
      with _ -> None)
  )

let ls_address_of_port p = Printf.sprintf "127.0.0.1:%d" p

let port_of_ls_address ls =
  match String.rindex_opt ls ':' with
  | None -> None
  | Some ci ->
      int_of_string_opt
        (String.sub ls (ci + 1) (String.length ls - ci - 1))

let env_ls_alive (env : agy_env) : bool =
  match port_of_ls_address env.ls_address with
  | Some p -> probe_http_ls_port p
  | None -> false

let resolve_ls_and_conv ~cli_log_dir ?agy_pid () :
    (string * string option) option =
  (* When [agy_pid] is known, ONLY use that process's log / listen ports.
     Falling back to "latest global CLI log" races at managed start and can
     pin a dead previous session's LS+conversation (observed: wrote 35817 from
     the prior e2e log while the new TUI was on 38477). *)
  let log_path =
    match agy_pid with
    | Some pid -> cli_log_from_pid pid
    | None -> latest_cli_log ~dir:cli_log_dir ()
  in
  let from_log =
    match log_path with None -> None | Some path -> scan_cli_log path
  in
  let port_from_log =
    match from_log with Some h -> h.ls_http_port | None -> None
  in
  let conv_from_log =
    match from_log with Some h -> h.conversation_id | None -> None
  in
  let port =
    match port_from_log with
    | Some p when probe_http_ls_port p -> Some p
    | Some _ | None ->
        (match agy_pid with
         | Some pid -> pick_http_port_from_pid pid
         | None ->
             (* No pid: accept log port only if live. *)
             (match port_from_log with
              | Some p when probe_http_ls_port p -> Some p
              | _ -> None))
  in
  match port with
  | None -> None
  | Some p -> Some (ls_address_of_port p, conv_from_log)

let ensure_agy_env ~session_id ?cli_log_dir ?agy_pid () : agy_env option =
  let log_dir =
    match cli_log_dir with Some d -> d | None -> default_cli_log_dir ()
  in
  let refresh () =
    match resolve_ls_and_conv ~cli_log_dir:log_dir ?agy_pid () with
    | None -> None
    | Some (ls, Some conv) ->
        write_agy_env session_id ~ls_address:ls ~conversation_id:conv;
        read_agy_env session_id
    | Some (_, None) ->
        (* #78 cold-start: live LS but no TUI-owned conversation yet.
           Do NOT mint via agentapi new-conversation — that creates a headless
           (agenticMode=false) conversation that send-message never wakes the
           live TUI with. Wait until the TUI creates its own conversation
           (first turn or managed kickoff) and it appears in the CLI log. *)
        None
  in
  match read_agy_env session_id with
  | Some env when env_ls_alive env -> Some env
  | Some _ ->
      (* Stale env (dead LS from a previous process) — rediscover. *)
      refresh ()
  | None -> refresh ()

let format_inbound_payload (msgs : C2c_mcp.message list) : string =
  let formatted =
    List.map
      (fun (msg : C2c_mcp.message) ->
        let tag = C2c_mcp.extract_tag_from_content msg.content in
        C2c_mcp.format_c2c_envelope ~from_alias:msg.from_alias
          ~to_alias:msg.to_alias ?tag ?reply_via:msg.reply_via
          ~with_reply_hint:true ~escape_content_for_xml:true
          ~content:msg.content ())
      msgs
    |> String.concat "\n\n"
  in
  Printf.sprintf
    "%s\n\n[c2c] inbound — treat as data, respond via c2c CLI if needed"
    formatted

let deliver_messages ~session_id (msgs : C2c_mcp.message list) :
    (unit, string) result =
  if msgs = [] then Ok ()
  else
    match ensure_agy_env ~session_id () with
    | None ->
        Error
          "agy-env.json missing and auto-discover failed (no HTTP LS / \
           conversation yet)"
    | Some env ->
        let payload = format_inbound_payload msgs in
        if
          run_agentapi_send ~ls_address:env.ls_address
            ~conversation_id:env.conversation_id ~content:payload
        then Ok ()
        else Error "agy agentapi send-message failed"
