(* Shared app-server WebSocket transport for authenticated loopback and
   same-UID Unix daemon connections. *)

exception Ws_refused
exception Ws_closed
exception Ws_unauthorized
exception Ws_http of int

let ws_read_exactly fd n =
  let buf = Bytes.create n in
  let rec loop off =
    if off >= n then ()
    else
      let r = Unix.read fd buf off (n - off) in
      if r <= 0 then raise Ws_closed else loop (off + r)
  in
  loop 0;
  Bytes.unsafe_to_string buf

let ws_write_all fd s =
  let len = String.length s in
  let rec loop off =
    if off >= len then ()
    else
      let w = Unix.write_substring fd s off (len - off) in
      if w <= 0 then raise Ws_closed else loop (off + w)
  in
  loop 0

(* Mask + write a single text frame (client → server, MASK bit required). *)
let ws_send_text fd (payload : string) =
  let len = String.length payload in
  let b = Buffer.create (len + 8) in
  Buffer.add_char b (Char.chr 0x81) (* FIN + text *);
  let mask_flag = 0x80 in
  if len < 126 then Buffer.add_char b (Char.chr (mask_flag lor len))
  else if len < 65536 then begin
    Buffer.add_char b (Char.chr (mask_flag lor 126));
    Buffer.add_char b (Char.chr ((len lsr 8) land 0xff));
    Buffer.add_char b (Char.chr (len land 0xff))
  end
  else begin
    Buffer.add_char b (Char.chr (mask_flag lor 127));
    for i = 7 downto 0 do Buffer.add_char b (Char.chr ((len lsr (i * 8)) land 0xff)) done
  end;
  let key = Bytes.create 4 in
  for i = 0 to 3 do Bytes.set key i (Char.chr (Random.int 256)) done;
  Buffer.add_bytes b key;
  for i = 0 to len - 1 do
    let c = Char.code payload.[i] lxor Char.code (Bytes.get key (i land 3)) in
    Buffer.add_char b (Char.chr c)
  done;
  ws_write_all fd (Buffer.contents b)

(* Read one server frame; returns (opcode, payload). Server frames are unmasked. *)
let ws_read_frame fd =
  let h = ws_read_exactly fd 2 in
  let b0 = Char.code h.[0] and b1 = Char.code h.[1] in
  let opcode = b0 land 0x0f in
  let masked = (b1 land 0x80) <> 0 in
  let len0 = b1 land 0x7f in
  let len =
    if len0 < 126 then len0
    else if len0 = 126 then (
      let e = ws_read_exactly fd 2 in
      (Char.code e.[0] lsl 8) lor Char.code e.[1])
    else (
      let e = ws_read_exactly fd 8 in
      let v = ref 0 in
      for i = 0 to 7 do v := (!v lsl 8) lor Char.code e.[i] done;
      !v)
  in
  let mask = if masked then ws_read_exactly fd 4 else "" in
  let payload = if len > 0 then ws_read_exactly fd len else "" in
  let payload =
    if masked then
      String.init len (fun i -> Char.chr (Char.code payload.[i] lxor Char.code mask.[i land 3]))
    else payload
  in
  (opcode, payload)

(* Read one full text message, replying to pings, honoring close. *)
let ws_recv_text fd =
  let rec loop () =
    let opcode, payload = ws_read_frame fd in
    match opcode with
    | 0x1 | 0x2 -> payload
    | 0x8 -> raise Ws_closed
    | 0x9 ->
        (* ping → pong (unmasked reply is fine; server tolerates) *)
        let b = Buffer.create 8 in
        Buffer.add_char b (Char.chr 0x8a);
        Buffer.add_char b (Char.chr (0x80 lor String.length payload));
        Buffer.add_string b "\x00\x00\x00\x00";
        Buffer.add_string b payload;
        (try ws_write_all fd (Buffer.contents b) with _ -> ());
        loop ()
    | _ -> loop ()
  in
  loop ()

let private_unix_socket path =
  if Filename.is_relative path then invalid_arg "daemon socket must be absolute";
  let path = Unix.realpath path in
  let st = Unix.stat path and parent = Unix.stat (Filename.dirname path) in
  let uid = Unix.getuid () in
  if st.Unix.st_kind <> Unix.S_SOCK || st.st_uid <> uid || st.st_perm land 0o077 <> 0
     || parent.st_kind <> Unix.S_DIR || parent.st_uid <> uid
     || parent.st_perm land 0o077 <> 0 then
    invalid_arg "daemon socket and parent must be private to this UID";
  path

let ws_connect (ep : C2c_codex_app_server.endpoint) ~token ~timeout =
  let domain, addr, host, auth =
    match ep.transport with
    | "unix" ->
        let path = private_unix_socket ep.host in
        Unix.PF_UNIX, Unix.ADDR_UNIX path, "localhost", ""
    | "ws" ->
        if ep.host <> "127.0.0.1" || ep.port < 1 || ep.port > 65535
           || token = "" || String.contains token '\r' || String.contains token '\n' then
          invalid_arg "private app-server requires loopback and bearer token";
        Unix.PF_INET, Unix.ADDR_INET (Unix.inet_addr_loopback, ep.port),
        Printf.sprintf "%s:%d" ep.host ep.port, "Authorization: Bearer " ^ token ^ "\r\n"
    | _ -> invalid_arg "unsupported app-server transport"
  in
  let fd = Unix.socket ~cloexec:true domain Unix.SOCK_STREAM 0 in
  (try
     Unix.setsockopt_float fd Unix.SO_RCVTIMEO timeout;
     Unix.setsockopt_float fd Unix.SO_SNDTIMEO timeout;
     (try Unix.connect fd addr
      with Unix.Unix_error ((Unix.ECONNREFUSED | Unix.ECONNRESET), _, _) -> raise Ws_refused);
     let req =
       Printf.sprintf
         "GET / HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
          Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\
          %s\r\n"
         host auth
     in
     ws_write_all fd req;
     (* read HTTP response headers up to \r\n\r\n *)
     let buf = Buffer.create 512 in
     let one = Bytes.create 1 in
     let rec rd () =
       let n = Unix.read fd one 0 1 in
       if n <= 0 then ()
       else begin
         Buffer.add_char buf (Bytes.get one 0);
         if Buffer.length buf > 16384 then raise (Ws_http 0);
         let s = Buffer.contents buf in
         let l = String.length s in
         if l >= 4 && String.sub s (l - 4) 4 = "\r\n\r\n" then () else rd ()
       end
     in
     rd ();
     let resp = Buffer.contents buf in
     let status_line = match String.index_opt resp '\r' with Some i -> String.sub resp 0 i | None -> resp in
     (match String.split_on_char ' ' status_line with
      | _ :: code :: _ -> (
          match int_of_string_opt (String.trim code) with
          | Some 101 -> ()
          | Some (401 | 403) -> raise Ws_unauthorized
          | Some c -> raise (Ws_http c)
          | None -> raise (Ws_http 0))
      | _ -> raise (Ws_http 0));
     fd
   with e -> (try Unix.close fd with _ -> ()); raise e)

let next_rpc_id = ref 0
let rpc_id () = incr next_rpc_id; !next_rpc_id

(* Send a JSON-RPC request and read the response whose id matches, skipping
   notifications. Newline-delimited JSON in a text frame. *)
let rpc_call fd ~meth ~params =
  let id = rpc_id () in
  let req = `Assoc [ ("id", `Int id); ("method", `String meth); ("params", params) ] in
  ws_send_text fd (Yojson.Safe.to_string req ^ "\n");
  let rec await () =
    let raw = ws_recv_text fd in
    (* a frame may carry one or more newline-delimited messages *)
    let lines = String.split_on_char '\n' raw |> List.filter (fun s -> String.trim s <> "") in
    let matched =
      List.find_opt
        (fun line ->
          match Yojson.Safe.from_string line with
          | `Assoc l -> List.assoc_opt "id" l = Some (`Int id)
          | _ -> false
          | exception _ -> false)
        lines
    in
    match matched with Some line -> Yojson.Safe.from_string line | None -> await ()
  in
  await ()
