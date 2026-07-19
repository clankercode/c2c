(* c2c_kimi_deliver.ml — deliver c2c messages into Kimi Code via its local REST server.

   Talks to the Kimi Code local server started by `kimi server run`:
     POST /api/v1/sessions/{session_id}/prompts
   Auth via the bearer token in ~/.kimi-code/server.token.

   External HTTP interactions are gated by C2C_KIMI_DELIVER_FIXTURE=1.
   When that gate is set, the optional C2C_KIMI_DELIVER_FIXTURE_BASE_URL and
   C2C_KIMI_DELIVER_FIXTURE_TOKEN overrides let tests point the module at a
   mock server without touching real Kimi state. *)

let home () =
  match Sys.getenv_opt "HOME" with Some h -> h | None -> "/tmp"

let ( // ) = Filename.concat

let kimi_code_home () =
  match Sys.getenv_opt "KIMI_CODE_HOME" with
  | Some d when d <> "" -> d
  | _ -> home () // ".kimi-code"

let server_token_path () = kimi_code_home () // "server.token"

let fixture_enabled () =
  match Sys.getenv_opt "C2C_KIMI_DELIVER_FIXTURE" with
  | Some "1" -> true
  | _ -> false

let read_server_token () =
  match fixture_enabled (), Sys.getenv_opt "C2C_KIMI_DELIVER_FIXTURE_TOKEN" with
  | true, Some t when String.trim t <> "" -> Some (String.trim t)
  | _ ->
      let path = server_token_path () in
      if not (Sys.file_exists path) then None
      else
        try
          let ic = open_in path in
          Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
            Some (String.trim (input_line ic)))
        with _ -> None

let default_port () =
  match Sys.getenv_opt "C2C_KIMI_SERVER_PORT" with
  | Some p when p <> "" -> p
  | _ -> "58627"

let server_log_path () = kimi_code_home () // "server" // "server.log"

let server_listening_url () =
  let path = server_log_path () in
  if not (Sys.file_exists path) then None
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in ic)
      (fun () ->
         let rec scan last =
           match input_line ic with
           | line ->
               let last' =
                 try
                   let json = Yojson.Safe.from_string line in
                   let open Yojson.Safe.Util in
                   match json |> member "msg" |> to_string_option with
                   | Some "server listening" ->
                       (match json |> member "address" |> to_string_option with
                        | Some _ as addr -> addr
                        | None -> last)
                   | _ -> last
                 with _ -> last
               in
               scan last'
           | exception End_of_file -> last
         in
         scan None)

(* ─── Live-server discovery (#39) ────────────────────────────────────────── *)

(* Kimi Code's single-instance lock: <kimi home>/server/lock, JSON of the shape
     {"pid":721503,"started_at":"2026-07-19T08:50:28.865Z",
      "host":"127.0.0.1","port":58627,"host_version":"…","entry":"…"}
   It is created with O_EXCL when a server binds, its `port` is rewritten via
   updatePort(), and it is unlinked on clean shutdown. A lock whose recorded
   pid is dead is stale (kimi itself treats it as takeable), so a pid-liveness
   probe is the authoritative "is this the running server?" check. *)
let server_lock_path () = kimi_code_home () // "server" // "lock"

(* With kimi's experimental `multi_server` flag the exclusive lock is replaced
   by one self-describing file per instance under server/instances/. Same idea,
   different shape: {"server_id":…,"pid":…,"host":…,"port":…,
   "started_at":<ms>,"heartbeat_at":<ms>}. Stale entries are swept lazily by
   kimi, so we pid-check here too. *)
let server_instances_dir () = kimi_code_home () // "server" // "instances"

let pid_alive pid =
  if pid <= 0 then false
  else
    try Unix.kill pid 0; true with
    | Unix.Unix_error (Unix.ESRCH, _, _) -> false
    | Unix.Unix_error (Unix.EPERM, _, _) -> true
    | _ -> true

let read_file_opt path =
  if not (Sys.file_exists path) then None
  else
    try
      let ic = open_in_bin path in
      Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        Some (really_input_string ic (in_channel_length ic)))
    with _ -> None

(* Extract (pid, host, port) from a lock/instance JSON blob. Returns None on
   anything malformed — callers fall through to the next candidate rather than
   raising, so a corrupt lock can never break delivery. *)
let parse_lock_json raw =
  try
    let json = Yojson.Safe.from_string raw in
    let open Yojson.Safe.Util in
    let pid = json |> member "pid" |> to_int_option in
    let port = json |> member "port" |> to_int_option in
    let host =
      match json |> member "host" |> to_string_option with
      | Some h when String.trim h <> "" -> String.trim h
      | _ -> "127.0.0.1"
    in
    match pid, port with
    | Some pid, Some port when port > 0 -> Some (pid, host, port)
    | _ -> None
  with _ -> None

let url_of_host_port host port =
  (* An IPv6 literal needs brackets in a URL authority. *)
  let host = if String.contains host ':' then "[" ^ host ^ "]" else host in
  Printf.sprintf "http://%s:%d" host port

let lock_file_url () =
  match read_file_opt (server_lock_path ()) with
  | None -> None
  | Some raw ->
      (match parse_lock_json raw with
       | Some (pid, host, port) when pid_alive pid -> Some (url_of_host_port host port)
       | _ -> None)

let instance_registry_url () =
  let dir = server_instances_dir () in
  match (try Some (Sys.readdir dir) with _ -> None) with
  | None -> None
  | Some names ->
      let live =
        Array.to_list names
        |> List.filter (fun n -> Filename.check_suffix n ".json")
        |> List.filter_map (fun n ->
               match read_file_opt (dir // n) with
               | None -> None
               | Some raw ->
                   (match parse_lock_json raw with
                    | Some (pid, host, port) when pid_alive pid -> Some (host, port)
                    | _ -> None))
      in
      (match live with
       | [] -> None
       | (host, port) :: _ -> Some (url_of_host_port host port))

let live_lock_url () =
  match lock_file_url () with
  | Some url -> Some url
  | None -> instance_registry_url ()

(* Cheap TCP liveness probe for an http://host:port base URL. Used only for
   candidates we do not otherwise trust (the historical log scrape), so that a
   dead address is skipped instead of being retried forever. *)
let probe_timeout () =
  match Sys.getenv_opt "C2C_KIMI_PROBE_TIMEOUT" with
  | Some s -> (match float_of_string_opt s with Some f when f > 0.0 -> f | _ -> 0.5)
  | None -> 0.5

let host_port_of_url url =
  match String.index_opt url ':' with
  | None -> None
  | Some _ ->
      let rest =
        match String.index_opt url '/' with
        | Some i when i + 1 < String.length url && url.[i + 1] = '/' ->
            String.sub url (i + 2) (String.length url - i - 2)
        | _ -> url
      in
      let authority =
        match String.index_opt rest '/' with
        | Some i -> String.sub rest 0 i
        | None -> rest
      in
      (match String.rindex_opt authority ':' with
       | None -> None
       | Some i ->
           let host = String.sub authority 0 i in
           let port_s = String.sub authority (i + 1) (String.length authority - i - 1) in
           let host =
             let n = String.length host in
             if n >= 2 && host.[0] = '[' && host.[n - 1] = ']' then String.sub host 1 (n - 2)
             else host
           in
           (match int_of_string_opt port_s with
            | Some p when p > 0 && host <> "" -> Some (host, p)
            | _ -> None))

let address_is_live url =
  match host_port_of_url url with
  | None -> false
  | Some (host, port) ->
      let addrs =
        try
          Unix.getaddrinfo host (string_of_int port)
            [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
        with _ -> []
      in
      let timeout = probe_timeout () in
      let try_addr ai =
        let fd = Unix.socket ai.Unix.ai_family ai.Unix.ai_socktype 0 in
        Fun.protect
          ~finally:(fun () -> try Unix.close fd with _ -> ())
          (fun () ->
            try
              Unix.set_nonblock fd;
              (try Unix.connect fd ai.Unix.ai_addr with
               | Unix.Unix_error (Unix.EINPROGRESS, _, _) -> ());
              (match Unix.select [] [ fd ] [] timeout with
               | _, [ _ ], _ -> Unix.getsockopt_error fd = None
               | _ -> false)
            with _ -> false)
      in
      List.exists try_addr addrs

(* Resolution precedence (#39):
     0. fixture override               — tests only, gated by C2C_KIMI_DELIVER_FIXTURE
     1. live lock / instance registry  — ground truth for the process actually
                                         listening right now; pid-liveness checked
     2. $C2C_KIMI_SERVER_PORT          — explicit operator intent
     3. server.log "server listening"  — historical and append-only; modern
                                         kimi only writes it on a COLD start, so
                                         it ages into a dead port. Usable only
                                         after a liveness probe.
     4. default port 58627
   The log used to sit at the TOP of this list, which is what broke delivery
   permanently on hosts whose server had warm-started onto a different port. *)
let server_base_url () =
  match fixture_enabled (), Sys.getenv_opt "C2C_KIMI_DELIVER_FIXTURE_BASE_URL" with
  | true, Some u when String.trim u <> "" -> Some (String.trim u)
  | _ ->
      let env_port =
        match Sys.getenv_opt "C2C_KIMI_SERVER_PORT" with
        | Some p when p <> "" -> Some (Printf.sprintf "http://127.0.0.1:%s" p)
        | _ -> None
      in
      let probed_log () =
        match server_listening_url () with
        | Some url when address_is_live url -> Some url
        | _ -> None
      in
      (match live_lock_url () with
       | Some url -> Some url
       | None ->
           (match env_port with
            | Some url -> Some url
            | None ->
                (match probed_log () with
                 | Some url -> Some url
                 | None ->
                     Some (Printf.sprintf "http://127.0.0.1:%s" (default_port ())))))

let session_index_path () = kimi_code_home () // "session_index.jsonl"

let parse_session_index_line line =
  try
    let json = Yojson.Safe.from_string line in
    let open Yojson.Safe.Util in
    let sid = json |> member "sessionId" |> to_string in
    let workdir = json |> member "workDir" |> to_string in
    let updated_at =
      match json |> member "updated_at" |> to_string_option with
      | Some s -> s
      | None -> ""
    in
    Some (sid, workdir, updated_at)
  with _ -> None

let read_session_index () =
  let path = session_index_path () in
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in ic)
      (fun () ->
         let rec loop acc =
           match input_line ic with
           | line ->
               (match parse_session_index_line line with
                | Some triple -> loop (triple :: acc)
                | None -> loop acc)
           | exception End_of_file -> acc
         in
         loop [])

let session_id_for_workdir ~workdir =
  let entries = read_session_index () in
  let matching = List.filter (fun (_, wd, _) -> wd = workdir) entries in
  match matching with
  | [] -> None
  | _ ->
      (* Prefer entries with a non-empty updated_at timestamp (most recent
         first).  If none have timestamps, fall back to the last appended
         entry — session_index.jsonl is append-only, so the last match is
         the most recently created session for this workdir. *)
      let with_ts, without_ts =
        List.partition (fun (_, _, ts) -> ts <> "") matching
      in
      let sorted_with_ts =
        List.sort (fun (_, _, a) (_, _, b) -> String.compare b a) with_ts
      in
      let candidate =
        match sorted_with_ts with
        | (sid, _, _) :: _ -> sid
        | [] ->
            (* matching is non-empty; take the head of the reversed list,
               which corresponds to the last line in the JSONL file. *)
            let (sid, _, _) = List.hd without_ts in
            sid
      in
      Some candidate

let session_dir_for_session_id ~session_id =
  let path = session_index_path () in
  if not (Sys.file_exists path) then None
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in ic)
      (fun () ->
         let rec scan () =
           match input_line ic with
           | line ->
               (try
                  let json = Yojson.Safe.from_string line in
                  let open Yojson.Safe.Util in
                  let sid = json |> member "sessionId" |> to_string in
                  if sid = session_id then
                    json |> member "sessionDir" |> to_string_option
                  else scan ()
                with _ -> scan ())
           | exception End_of_file -> None
         in
         scan ())

open Lwt.Infix

let submit_prompt ~session_id ~body =
  match server_base_url (), read_server_token () with
  | None, _ -> Error "no server base url"
  | _, None -> Error "no server token"
  | Some base, Some token ->
      let url = Printf.sprintf "%s/api/v1/sessions/%s/prompts" base session_id in
      let uri = Uri.of_string url in
      let headers =
        Cohttp.Header.of_list
          [ "Authorization", "Bearer " ^ token
          ; "Content-Type", "application/json" ]
      in
      let body_json =
        `Assoc
          [ ("content",
             `List [ `Assoc [("type", `String "text"); ("text", `String body)] ]) ]
      in
      let payload = Yojson.Safe.to_string body_json in
      let req_body = Cohttp_lwt.Body.of_string payload in
      try
        Lwt_main.run (
          Cohttp_lwt_unix.Client.post ~headers ~body:req_body uri
          >>= fun (resp, resp_body) ->
          let http_code = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
          Cohttp_lwt.Body.to_string resp_body
          >>= fun body_text ->
          let result =
            match Yojson.Safe.from_string body_text with
            | exception _ ->
                Error (Printf.sprintf "non-JSON response (HTTP %d): %s" http_code body_text)
            | json ->
                let open Yojson.Safe.Util in
                let code = json |> member "code" |> to_int_option in
                let msg =
                  match json |> member "msg" |> to_string_option with
                  | Some s -> s
                  | None -> "(no message)"
                in
                match code with
                | None | Some 0 -> Ok http_code
                | Some n -> Error (Printf.sprintf "kimi server error %d: %s" n msg)
          in
          Lwt.return result
        )
      with exn -> Error (Printexc.to_string exn)

let message_envelope ~msg =
  Printf.sprintf "<c2c event=\"message\" from=\"%s\" to=\"%s\">%s</c2c>"
    (C2c_mcp.xml_escape msg.C2c_mcp.from_alias)
    (C2c_mcp.xml_escape msg.C2c_mcp.to_alias)
    (C2c_mcp.xml_escape msg.C2c_mcp.content)

let deliver_message ~session_id ~msg =
  match submit_prompt ~session_id ~body:(message_envelope ~msg) with
  | Ok 200 -> Ok ()
  | Ok code -> Error (Printf.sprintf "unexpected HTTP %d" code)
  | Error e -> Error e
