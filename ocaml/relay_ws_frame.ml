(* WebSocket frame handling — RFC 6455.
   Server-side only. Supports text/binary frames, close, ping, pong.
   HTTP handshake is handled separately (cohttp upgrade path).
   Ref: https://www.rfc-editor.org/rfc/rfc6455 *)

open Lwt.Infix

(* Opcodes *)
let opcode_continuation = 0x0
let opcode_text         = 0x1
let opcode_binary       = 0x2
let opcode_close        = 0x8
let opcode_ping         = 0x9
let opcode_pong         = 0xA

type frame = {
  opcode  : int;
  fin     : bool;
  payload : string;
}

type client_message = [
  | `Text of string
  | `Binary of string
  | `Close of int * string
  | `Ping
]

(* Unmask client payload. Key is 4 bytes. *)
let xor_bytes ~(key:string) ~(data:string) =
  let n = String.length data in
  let r = Bytes.create n in
  for i = 0 to n - 1 do
    let k = Char.code key.[i mod 4] in
    let d = Char.code data.[i] in
    Bytes.set_uint8 r i (d lxor k)
  done;
  Bytes.to_string r

(* Read exactly n bytes from an Lwt_io.input_channel. *)
let rec read_exactly (ic:Lwt_io.input_channel) buf off n =
  if n = 0 then Lwt.return ()
  else
    Lwt_io.read_into ic buf off n >>= fun m ->
    if m = 0 then Lwt.fail End_of_file
    else if m < n then read_exactly ic buf (off + m) (n - m)
    else Lwt.return ()

(* Read one WebSocket frame. Returns None on EOF. *)
let read_frame (ic:Lwt_io.input_channel) =
  let header = Bytes.create 14 in
  read_exactly ic header 0 2 >>= fun () ->
  let b0 = Bytes.get_uint8 header 0 in
  let b1 = Bytes.get_uint8 header 1 in
  let fin    = (b0 lsr 7) = 1 in
  let opcode = b0 land 0x0F in
  let masked = (b1 lsr 7) = 1 in
  let len0   = b1 land 0x7F in
  let payload_len =
    if len0 < 126 then Lwt.return len0
    else if len0 = 126 then
      let ext = Bytes.create 2 in
      read_exactly ic ext 0 2 >>= fun () ->
      Lwt.return (((Bytes.get_uint8 ext 0 lsl 8) lor (Bytes.get_uint8 ext 1)) |> fun n -> n)
    else
      Lwt.return 0  (* 64-bit not needed for v1 — fallback *)
  in
  payload_len >>= fun payload_len ->
  let mask_key =
    if masked then
      let m = Bytes.create 4 in
      read_exactly ic m 0 4 >|= fun () ->
      Some (Bytes.unsafe_to_string m)
    else Lwt.return None
  in
  mask_key >>= fun mask_opt ->
  let payload_buf = Bytes.create payload_len in
  read_exactly ic payload_buf 0 payload_len >>= fun () ->
  let payload =
    match mask_opt with
    | None -> Bytes.unsafe_to_string payload_buf
    | Some k -> xor_bytes ~key:k ~data:(Bytes.unsafe_to_string payload_buf)
  in
  Lwt.return { opcode; fin; payload }

(* Write one WebSocket frame. Server sends unmasked (RFC 6455 §5.1). *)
let write_frame ~(opcode:int) ~(payload:string) (oc:Lwt_io.output_channel) =
  let len = String.length payload in
  let header_len, len_code =
    if len < 126 then 2, len
    else if len < 65536 then 4, 126
    else 10, 127
  in
  let buf = Bytes.create (header_len + len) in
  Bytes.set_uint8 buf 0 (0x80 lor opcode);
  Bytes.set_uint8 buf 1 len_code;
  (if len < 126 then ()
   else if len < 65536 then
     (Bytes.set_uint8 buf 2 (len lsr 8);
      Bytes.set_uint8 buf 3 (len land 0xFF))
   else ());
  Bytes.unsafe_blit_string payload 0 buf header_len len;
  Lwt_io.write oc (Bytes.unsafe_to_string buf) >|= fun () -> ()

let write_text    oc = write_frame ~opcode:opcode_text    ~payload:"" oc
let write_binary oc = write_frame ~opcode:opcode_binary  ~payload:"" oc
let write_close  oc = write_frame ~opcode:opcode_close  ~payload:"" oc
let write_pong   oc = write_frame ~opcode:opcode_pong   ~payload:"" oc
let write_ping oc   = write_frame ~opcode:opcode_ping   ~payload:"" oc

let parse_message f =
  match f.opcode with
  | n when n = opcode_text   -> Some (`Text f.payload)
  | n when n = opcode_binary -> Some (`Binary f.payload)
  | n when n = opcode_close ->
      let code, reason =
        if String.length f.payload >= 2 then
          let c = (Char.code f.payload.[0] lsl 8) lor Char.code f.payload.[1] in
          c, String.sub f.payload 2 (String.length f.payload - 2)
        else 1000, ""
      in
      Some (`Close (code, reason))
  | n when n = opcode_ping -> Some (`Ping)
  | _ -> None

(* Build HTTP 101 Switching Protocols response. *)
let make_handshake_response (key:string) =
  let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" in
  let combined = key ^ guid in
  let hash = Digestif.SHA1.to_raw_string (Digestif.SHA1.digest_string combined) in
  let accept = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet hash in
  Printf.sprintf
    "HTTP/1.1 101 Switching Protocols\r\n\
     Upgrade: websocket\r\n\
     Connection: Upgrade\r\n\
     Sec-WebSocket-Accept: %s\r\n\
     \r\n"
    accept

(* Server-side session from a bidirectional file descriptor. *)
module Session = struct
  type t = {
    ic : Lwt_io.input_channel;
    oc : Lwt_io.output_channel;
    mutable closed : bool;
  }

  let of_fd (fd:Lwt_unix.file_descr) =
    let ic = Lwt_io.of_fd ~mode:Lwt_io.Input fd in
    let oc = Lwt_io.of_fd ~mode:Lwt_io.Output fd in
    { ic; oc; closed = false }

  let send_text t msg =
    if t.closed then Lwt.return ()
    else write_frame ~opcode:opcode_text ~payload:msg t.oc

  let send_binary t b =
    if t.closed then Lwt.return ()
    else write_frame ~opcode:opcode_binary ~payload:b t.oc

  let close_with ?(code=1000) ?(reason="") () t =
    if t.closed then Lwt.return ()
    else (
      t.closed <- true;
      let payload = Printf.sprintf "%04X%s" code reason in
      write_frame ~opcode:opcode_close ~payload t.oc >>= fun () ->
      Lwt_io.close t.ic >>= fun () ->
      Lwt_io.close t.oc
    )

  let recv t =
    if t.closed then Lwt.return None
    else
      read_frame t.ic >>= fun f ->
      match parse_message f with
      | Some (`Ping) ->
          write_pong t.oc >|= fun () ->
          Some (`Ping)
      | Some m -> Lwt.return (Some m)
      | None -> Lwt.return None
end