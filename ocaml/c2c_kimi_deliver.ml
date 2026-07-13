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

let server_base_url () =
  match fixture_enabled (), Sys.getenv_opt "C2C_KIMI_DELIVER_FIXTURE_BASE_URL" with
  | true, Some u when String.trim u <> "" -> Some (String.trim u)
  | _ ->
      (match server_listening_url () with
       | Some url -> Some url
       | None -> Some (Printf.sprintf "http://127.0.0.1:%s" (default_port ())))

let session_index_path () = kimi_code_home () // "session_index.jsonl"

let parse_session_index_line line =
  try
    let json = Yojson.Safe.from_string line in
    let open Yojson.Safe.Util in
    let sid = json |> member "sessionId" |> to_string in
    let workdir = json |> member "workDir" |> to_string in
    let updated_at = json |> member "updated_at" |> to_string in
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
      let sorted =
        List.sort (fun (_, _, a) (_, _, b) -> String.compare b a) matching
      in
      Some (let (sid, _, _) = List.hd sorted in sid)

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
