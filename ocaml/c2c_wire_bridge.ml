(** Kimi Wire bridge: deliver c2c broker messages via kimi --wire JSON-RPC.

    Equivalent to Python c2c_kimi_wire_bridge.py.
    Envelope format and spool semantics must match the Python implementation. *)

let ( // ) = Filename.concat

let home () = Sys.getenv "HOME"

let default_spool_dir broker_root =
  Filename.dirname broker_root // "kimi-wire"

let default_spool_path broker_root session_id =
  default_spool_dir broker_root // (session_id ^ ".spool.json")

(* ---------------------------------------------------------------------------
 * Message envelope (must match Python format_c2c_envelope)
 * --------------------------------------------------------------------------- *)

let xml_escape s =
  let buf = Buffer.create (String.length s) in
  String.iter (function
    | '&' -> Buffer.add_string buf "&amp;"
    | '<' -> Buffer.add_string buf "&lt;"
    | '>' -> Buffer.add_string buf "&gt;"
    | '"' -> Buffer.add_string buf "&quot;"
    | '\'' -> Buffer.add_string buf "&#39;"
    | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

let format_envelope ?(sender_role : string option) (msg : C2c_mcp.message) =
  let reply_via = xml_escape (Option.value msg.reply_via ~default:"c2c_send") in
  let role_attr = match sender_role with
    | Some r -> Printf.sprintf " role=\"%s\"" (xml_escape r)
    | None -> ""
  in
  Printf.sprintf
    "<c2c event=\"message\" from=\"%s\" alias=\"%s\" source=\"broker\" reply_via=\"%s\" action_after=\"continue\"%s>\n%s\n</c2c>"
    (xml_escape msg.from_alias)
    (xml_escape msg.to_alias)
    reply_via
    role_attr
    msg.content

let format_prompt
    ?(role_lookup : string -> string option = fun _ -> None)
    (messages : C2c_mcp.message list) =
  String.concat "\n\n"
    (List.map (fun msg ->
      let sender_role = role_lookup msg.C2c_mcp.from_alias in
      format_envelope ?sender_role msg) messages)

(* ---------------------------------------------------------------------------
 * Spool: write before deliver, clear after ACK (crash-safe)
 * Serialises as JSON array of {from_alias, to_alias, content} objects.
 * --------------------------------------------------------------------------- *)

type spool = { path : string }

let spool_of_path path = { path }

let spool_read sp =
  if not (Sys.file_exists sp.path) then []
  else
    let ic = open_in sp.path in
    let raw =
      Fun.protect ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
           let buf = Buffer.create 256 in
           (try while true do Buffer.add_channel buf ic 4096 done
            with End_of_file -> ());
           String.trim (Buffer.contents buf))
    in
    if raw = "" then []
    else
      match Yojson.Safe.from_string raw with
      | `List items ->
          List.filter_map (fun item ->
              let str k =
                match Yojson.Safe.Util.(item |> member k) with
                | `String s -> s | _ -> ""
              in
              let from_alias = str "from_alias" in
              let to_alias   = str "to_alias" in
              let content    = str "content" in
              if from_alias = "" && content = "" then None
              else Some C2c_mcp.{ from_alias; to_alias; content; deferrable = false; reply_via = None; enc_status = None; ts = 0.0; ephemeral = false })
            items
      | _ -> []
      | exception _ -> []

let spool_write sp messages =
  let dir = Filename.dirname sp.path in
  (try ignore (Sys.readdir dir)
   with Sys_error _ ->
     let rec mkdir_p d =
       if not (Sys.file_exists d) then begin
         mkdir_p (Filename.dirname d);
         (try Unix.mkdir d 0o755
          with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
       end
     in
     mkdir_p dir);
  let (tmp, oc) = Filename.open_temp_file ~temp_dir:dir "spool" ".tmp" in
  Fun.protect
    ~finally:(fun () -> (try Sys.remove tmp with _ -> ()))
    (fun () ->
       let items =
         List.map (fun (m : C2c_mcp.message) ->
             `Assoc
               [ ("from_alias", `String m.from_alias)
               ; ("to_alias",   `String m.to_alias)
               ; ("content",    `String m.content)
               ])
           messages
       in
       Yojson.Safe.to_channel oc (`List items);
       output_char oc '\n';
       flush oc;
       Unix.fsync (Unix.descr_of_out_channel oc);
       close_out oc;
       Unix.rename tmp sp.path)

let spool_clear sp = spool_write sp []

let spool_append sp new_msgs =
  spool_write sp (spool_read sp @ new_msgs)

(* ---------------------------------------------------------------------------
 * MCP config JSON for kimi --wire subprocess (matches build_kimi_mcp_config)
 * --------------------------------------------------------------------------- *)

let build_mcp_config ~broker_root ~session_id ~alias ~mcp_server_bin =
  `Assoc
    [ ( "mcpServers"
      , `Assoc
          [ ( "c2c"
            , `Assoc
                [ ("type",    `String "stdio")
                ; ("command", `String mcp_server_bin)
                ; ( "env"
                  , `Assoc
                      [ ("C2C_MCP_BROKER_ROOT",        `String broker_root)
                      ; ("C2C_MCP_SESSION_ID",          `String session_id)
                      ; ("C2C_MCP_AUTO_REGISTER_ALIAS", `String alias)
                      ; ("C2C_MCP_CLIENT_PID",          `String (string_of_int (Unix.getpid ())))
                      ; ("C2C_MCP_AUTO_JOIN_ROOMS",     `String "swarm-lounge")
                      ; ("C2C_MCP_AUTO_DRAIN_CHANNEL",  `String "0")
                      ])
                ])
            ])
      ]

(* ---------------------------------------------------------------------------
 * Wire JSON-RPC 2.0 client (matches WireClient in Python)
 * --------------------------------------------------------------------------- *)

type wire_client =
  { ic : in_channel
  ; oc : out_channel
  ; mutable next_id : int
  }

let wire_create ic oc = { ic; oc; next_id = 1 }

let wire_request wc method_ params =
  let id = string_of_int wc.next_id in
  wc.next_id <- wc.next_id + 1;
  let req =
    `Assoc
      [ ("jsonrpc", `String "2.0")
      ; ("method",  `String method_)
      ; ("id",      `String id)
      ; ("params",  params)
      ]
  in
  output_string wc.oc (Yojson.Safe.to_string req);
  output_char wc.oc '\n';
  flush wc.oc;
  let rec loop () =
    let line = input_line wc.ic in
    let msg = Yojson.Safe.from_string (String.trim line) in
    let msg_id =
      match Yojson.Safe.Util.(msg |> member "id") with
      | `String s -> s | _ -> ""
    in
    if msg_id = id then
      match Yojson.Safe.Util.(msg |> member "error") with
      | `Null -> Yojson.Safe.Util.(msg |> member "result")
      | err   -> failwith ("wire error: " ^ Yojson.Safe.to_string err)
    else loop ()
  in
  loop ()

let wire_initialize wc =
  let params =
    `Assoc
      [ ("protocol_version", `String "1.9")
      ; ("client",
         `Assoc [ ("name", `String "c2c-wire-bridge"); ("version", `String "0") ])
      ; ("capabilities", `Assoc [ ("supports_question", `Bool false) ])
      ]
  in
  ignore (wire_request wc "initialize" params)

let wire_prompt wc user_input =
  ignore (wire_request wc "prompt" (`Assoc [ ("user_input", `String user_input) ]))

(* ---------------------------------------------------------------------------
 * Delivery (matches deliver_once / run_once_live in Python)
 * --------------------------------------------------------------------------- *)

let find_mcp_server_bin () =
  let candidates =
    [ home () // ".local" // "bin" // "c2c-mcp-server"
    ; "_build/default/ocaml/server/c2c_mcp_server.exe"
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some p -> p
  | None   -> "c2c-mcp-server"

(** Drain broker inbox, write to spool (crash-safe), return pending messages. *)
let drain_to_spool ~broker ~session_id ~spool =
  let queued = spool_read spool in
  if queued <> [] then queued
  else begin
    let fresh = C2c_mcp.Broker.drain_inbox ~drained_by:"wire_bridge" broker ~session_id in
    if fresh <> [] then spool_append spool fresh;
    spool_read spool
  end

(** Start a `kimi --wire` subprocess, deliver pending messages, return count.
    Temp MCP config is written and cleaned up automatically. *)
let run_once_live ~broker_root ~session_id ~alias ~command ~work_dir =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let spool  = spool_of_path (default_spool_path broker_root session_id) in
  let mcp_bin = find_mcp_server_bin () in
  let config  = build_mcp_config ~broker_root ~session_id ~alias ~mcp_server_bin:mcp_bin in
  let (tmp_config, oc_cfg) = Filename.open_temp_file "c2c-kimi-wire-" ".json" in
  Fun.protect
    ~finally:(fun () -> (try Sys.remove tmp_config with _ -> ()))
    (fun () ->
       output_string oc_cfg (Yojson.Safe.to_string config);
       close_out oc_cfg;
       let argv =
         [| command; "--wire"; "--yolo"
          ; "--work-dir"; work_dir
          ; "--mcp-config-file"; tmp_config |]
       in
       let (child_stdin_r, child_stdin_w)   = Unix.pipe () in
       let (child_stdout_r, child_stdout_w) = Unix.pipe () in
       let pid =
         Unix.create_process_env
           command argv (Unix.environment ())
           child_stdin_r child_stdout_w Unix.stderr
       in
       Unix.close child_stdin_r;
       Unix.close child_stdout_w;
       let ic = Unix.in_channel_of_descr child_stdout_r in
       let oc = Unix.out_channel_of_descr child_stdin_w in
        Fun.protect
          ~finally:(fun () ->
             (try close_in_noerr ic  with _ -> ());
             (try close_out_noerr oc with _ -> ());
              (try
                 let deadline = Unix.gettimeofday () +. 15. in
                 let rec wait_loop () =
                   if Unix.gettimeofday () >= deadline then
                     (try (Unix.kill pid Sys.sigkill; ignore (Unix.waitpid [] pid)) with _ -> ())
                   else
                     match Unix.waitpid [Unix.WNOHANG] pid with
                     | 0, _ -> Unix.sleepf 0.5; wait_loop ()
                     | _, _ -> ()
                 in wait_loop ()
               with _ -> ()))
          (fun () ->
             let wc = wire_create ic oc in
             wire_initialize wc;
             let messages = drain_to_spool ~broker ~session_id ~spool in
             if messages = [] then 0
             else begin
               let role_lookup (from_alias : string) : string option =
                 match C2c_mcp.Broker.list_registrations broker with
                 | [] -> None
                 | regs ->
                     (try
                       let reg = List.find (fun r -> r.C2c_mcp.alias = from_alias) regs in
                       reg.C2c_mcp.role
                     with Not_found -> None)
               in
               wire_prompt wc (format_prompt ~role_lookup messages);
               let n = List.length messages in
               spool_clear spool;
               n
             end))
