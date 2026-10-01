(* Hermetic checks for the authenticated loopback and private Unix WebSocket
   transport used by Codex ingress and gated turns. *)

open Alcotest

module T = C2c_codex_transport

let ( // ) = Filename.concat

let with_temp_dir f =
  let dir = Filename.get_temp_dir_name () // Printf.sprintf "c2c-codex-transport-%08x" (Random.bits ()) in
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f dir)

let write_all fd s =
  let rec loop off =
    if off = String.length s then ()
    else
      let n = Unix.write_substring fd s off (String.length s - off) in
      if n <= 0 then failwith "short write" else loop (off + n)
  in
  loop 0

let read_until_headers fd =
  let b = Buffer.create 256 in
  let one = Bytes.create 1 in
  let rec loop () =
    let n = Unix.read fd one 0 1 in
    if n <= 0 then failwith "server saw incomplete websocket handshake";
    Buffer.add_char b (Bytes.get one 0);
    let s = Buffer.contents b in
    let len = String.length s in
    if len >= 4 && String.sub s (len - 4) 4 = "\r\n\r\n" then s else loop ()
  in
  loop ()

let read_exact fd n =
  let b = Bytes.create n in
  let rec loop off =
    if off = n then ()
    else
      let got = Unix.read fd b off (n - off) in
      if got <= 0 then failwith "server saw incomplete websocket frame"
      else loop (off + got)
  in
  loop 0;
  Bytes.unsafe_to_string b

let discard_one_client_frame fd =
  let header = read_exact fd 2 in
  let b1 = Char.code header.[1] in
  let len0 = b1 land 0x7f in
  let len =
    if len0 < 126 then len0
    else if len0 = 126 then
      let e = read_exact fd 2 in
      (Char.code e.[0] lsl 8) lor Char.code e.[1]
    else failwith "test frame unexpectedly uses 64-bit length"
  in
  let _mask = read_exact fd 4 in
  ignore (read_exact fd len)

let server_frame payload =
  let len = String.length payload in
  if len >= 126 then failwith "test response too large";
  String.init (2 + len) (fun i ->
      if i = 0 then Char.chr 0x81
      else if i = 1 then Char.chr len
      else payload.[i - 2])

let test_private_unix_rpc () =
  with_temp_dir @@ fun dir ->
  let path = dir // "daemon.sock" in
  let listener = Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind listener (Unix.ADDR_UNIX path);
  Unix.listen listener 1;
  Unix.chmod path 0o600;
  let child = Unix.fork () in
  if child = 0 then begin
    try
      let fd, _ = Unix.accept listener in
      ignore (read_until_headers fd);
      write_all fd
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n";
      discard_one_client_frame fd;
      write_all fd (server_frame "{\"id\":1,\"result\":{\"ok\":true}}\n");
      Unix.close fd;
      Unix.close listener;
      Unix._exit 0
    with _ -> Unix._exit 1
  end;
  Unix.close listener;
  let ep = { C2c_codex_app_server.transport = "unix"; host = path; port = 0 } in
  let fd = T.ws_connect ep ~token:"" ~timeout:2.0 in
  let response = T.rpc_call fd ~meth:"initialize" ~params:(`Assoc []) in
  Unix.close fd;
  let _, status = Unix.waitpid [] child in
  check bool "server completed" true (status = Unix.WEXITED 0);
  check bool "rpc result returned" true
    (match response with
     | `Assoc fields -> List.mem_assoc "result" fields
     | _ -> false)

let test_unix_socket_requires_private_mode () =
  with_temp_dir @@ fun dir ->
  let path = dir // "daemon.sock" in
  let listener = Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind listener (Unix.ADDR_UNIX path);
  Unix.listen listener 1;
  Unix.chmod path 0o666;
  let ep = { C2c_codex_app_server.transport = "unix"; host = path; port = 0 } in
  check_raises "public socket refused"
    (Invalid_argument "daemon socket and parent must be private to this UID")
    (fun () -> ignore (T.ws_connect ep ~token:"" ~timeout:0.1));
  Unix.close listener

let () =
  run "c2c_codex_transport"
    [ ( "unix",
        [ test_case "private Unix websocket RPC" `Quick test_private_unix_rpc
        ; test_case "public Unix socket refused" `Quick test_unix_socket_requires_private_mode ] ) ]
