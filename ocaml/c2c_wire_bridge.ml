(** Message envelope formatting and crash-safe spool I/O.

    Originally the kimi wire-bridge module; the kimi-specific wire JSON-RPC
    client and daemon code was removed in the kimi-wire-bridge-cleanup slice
    (kimi delivery now uses C2c_kimi_notifier).  The envelope formatter and
    spool functions remain because they are used by the OpenCode plugin
    drain path (oc-plugin), c2c_start.ml tmux_message_payload, and tests. *)

(* ---------------------------------------------------------------------------
 * Message envelope (centralised via C2c_mcp.format_c2c_envelope)
 * --------------------------------------------------------------------------- *)

let format_envelope ?(sender_role : string option) ?ts (msg : C2c_mcp.message) =
  let tag = C2c_mcp.extract_tag_from_content msg.content in
  C2c_mcp.format_c2c_envelope
    ~from_alias:msg.from_alias
    ~to_alias:msg.to_alias
    ?tag
    ?role:sender_role
    ?reply_via:msg.reply_via
    ?ts
    ~content:msg.content
    ()

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
              else Some C2c_mcp.{ from_alias; to_alias; content; deferrable = false; reply_via = None; enc_status = None; ts = 0.0; ephemeral = false; message_id = None })
            items
      | _ -> []
      | exception _ -> []

let spool_write sp messages =
  let dir = Filename.dirname sp.path in
  (try ignore (Sys.readdir dir)
   with Sys_error _ -> C2c_io.mkdir_p dir);
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
