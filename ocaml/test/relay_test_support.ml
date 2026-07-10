(* Relay_test_support — F5a (friction-cn): the ONE shared loopback HTTP
   fault-injection harness for relay-facing test suites.
   Rows B075/B082-B086/B192/B236; C024/C056.

   WHAT THIS IS: a deterministic, dependency-light (unix + yojson) scripted
   HTTP server for tests. It serves CANNED responses and injected faults on
   a kernel-assigned loopback port. It is NOT a relay implementation and
   must never grow relay semantics ("no competing relay" — F5a spec): no
   registration state, no inbox, no PoW. Suites that need REAL relay
   behavior use Relay_test_support_real, which serves the production
   Relay.Relay_server(Relay.InMemoryRelay) callback in-process.

   EXTRACT-VS-FRESH DECISION (F5a): generalized fresh from the H6
   hand-rolled fake relay in test_c2c_list_relay.ml (bound-before-fork
   loopback socket, forked child server, SIGKILL+waitpid stop) — that
   fixture is migrated onto this module as the proof of reusability. The
   fork-based shape is load-bearing: several suites drive the c2c BINARY
   as a subprocess client, so the server cannot live on an in-process Lwt
   loop (the parent blocks in waitpid while the client runs; a same-process
   Lwt server would never be scheduled). A forked child serves regardless
   of what the parent is doing.

   DETERMINISM / LIFECYCLE GUARANTEES:
   - The listening socket is bound + listening BEFORE the fork: no
     accept-readiness race, ever. The kernel assigns the port (bind :0),
     so no port-collision flakes across parallel test binaries.
   - [stop] is idempotent (guarded by a ref), SIGKILLs the child and
     reaps it with waitpid — no orphaned processes, no zombies.
   - [with_server] is the bracket form; it always stops the child and
     removes the capture file, even when the test body raises.
   - No sleeps-as-sync anywhere. [delay_s] on a response is a scripted
     FAULT (for client-timeout tests), not synchronization.

   FAULT MODES (per scripted response):
   - arbitrary status codes (200/401/429/500/503/...)
   - response sequencing per route (e.g. 429 then 200; last repeats)
   - [delay_s]: child sleeps before responding (client-timeout tests)
   - [truncate_body_at]: full headers with the REAL Content-Length, but
     only a prefix of the body is sent before close (truncated JSON)
   - [close_without_response]: read the request, close with zero bytes
   - malformed JSON: [malformed_json_response] (valid HTTP, invalid body)
   - connection refused: [closed_port] (bind, read port, close)

   REQUEST CAPTURE: the child appends one JSON line per request (method,
   path, lowercased headers, body) to a temp file and fsyncs BEFORE
   writing the response — once the client has a response, the capture
   line is durably visible to the parent via [requests]. *)

(* ---------------------------------------------------------------------- *)
(* Scripted responses                                                      *)
(* ---------------------------------------------------------------------- *)

type response = {
  status : int;
  content_type : string;
  extra_headers : (string * string) list;
  resp_body : string;
  delay_s : float;
  truncate_body_at : int option;
  close_without_response : bool;
}

let response ?(status = 200) ?(content_type = "application/json")
    ?(extra_headers = []) ?(delay_s = 0.0) ?truncate_body_at
    ?(close_without_response = false) body =
  { status; content_type; extra_headers; resp_body = body; delay_s;
    truncate_body_at; close_without_response }

(* Valid HTTP envelope, body that no JSON parser accepts. *)
let malformed_json_response ?(status = 200) () =
  response ~status {|{"ok": tru|}

let default_response =
  response ~status:404 {|{"ok":false,"error":"relay_test_support: no route"}|}

type route = {
  meth : string option; (* uppercased; None matches every method *)
  route_path : string;  (* exact match against the query-stripped path *)
  responses : response array; (* served in order; the last one repeats *)
}

let route ?meth ~path responses =
  if responses = [] then
    invalid_arg "Relay_test_support.route: needs at least one response";
  { meth = Option.map String.uppercase_ascii meth;
    route_path = path;
    responses = Array.of_list responses }

(* ---------------------------------------------------------------------- *)
(* Request capture                                                         *)
(* ---------------------------------------------------------------------- *)

type captured_request = {
  meth_ : string;
  path : string;
  headers : (string * string) list; (* keys lowercased *)
  body : string;
}

let header req name = List.assoc_opt (String.lowercase_ascii name) req.headers

(* ---------------------------------------------------------------------- *)
(* Small shared helpers                                                    *)
(* ---------------------------------------------------------------------- *)

let find_substring haystack needle =
  let nl = String.length needle and hl = String.length haystack in
  if nl = 0 then Some 0
  else
    let rec go i =
      if i + nl > hl then None
      else if String.sub haystack i nl = needle then Some i
      else go (i + 1)
    in
    go 0

let ignore_sigpipe =
  lazy
    (if not Sys.win32 then
       try Sys.set_signal Sys.sigpipe Sys.Signal_ignore with _ -> ())

let reason_for = function
  | 200 -> "OK" | 201 -> "Created" | 204 -> "No Content"
  | 400 -> "Bad Request" | 401 -> "Unauthorized" | 403 -> "Forbidden"
  | 404 -> "Not Found" | 408 -> "Request Timeout" | 409 -> "Conflict"
  | 429 -> "Too Many Requests" | 500 -> "Internal Server Error"
  | 502 -> "Bad Gateway" | 503 -> "Service Unavailable"
  | 504 -> "Gateway Timeout" | _ -> "Status"

let path_of_target target =
  match String.index_opt target '?' with
  | Some i -> String.sub target 0 i
  | None -> target

(* ---------------------------------------------------------------------- *)
(* Child: request reading + serving                                        *)
(* ---------------------------------------------------------------------- *)

(* Bounded best-effort HTTP/1.1 request read: headers until \r\n\r\n
   (64 KiB cap, 10s recv timeout) + Content-Length body bytes. Returns
   None when nothing parseable arrived. *)
let read_request client =
  (try Unix.setsockopt_float client Unix.SO_RCVTIMEO 10.0 with _ -> ());
  let buf = Bytes.create 4096 in
  let acc = Buffer.create 512 in
  let rec until_headers () =
    match find_substring (Buffer.contents acc) "\r\n\r\n" with
    | Some i -> Some i
    | None ->
        if Buffer.length acc > 65536 then None
        else (
          match Unix.read client buf 0 4096 with
          | 0 -> None
          | n ->
              Buffer.add_subbytes acc buf 0 n;
              until_headers ()
          | exception _ -> None)
  in
  match until_headers () with
  | None -> None
  | Some hdr_end -> (
      let raw = Buffer.contents acc in
      let head = String.sub raw 0 hdr_end in
      let strip_cr l =
        let n = String.length l in
        if n > 0 && l.[n - 1] = '\r' then String.sub l 0 (n - 1) else l
      in
      let lines = String.split_on_char '\n' head |> List.map strip_cr in
      match lines with
      | [] -> None
      | reqline :: header_lines -> (
          match String.split_on_char ' ' reqline with
          | meth :: target :: _ ->
              let headers =
                List.filter_map
                  (fun l ->
                    match String.index_opt l ':' with
                    | Some i ->
                        let k =
                          String.lowercase_ascii
                            (String.trim (String.sub l 0 i))
                        in
                        let v =
                          String.trim
                            (String.sub l (i + 1) (String.length l - i - 1))
                        in
                        Some (k, v)
                    | None -> None)
                  header_lines
              in
              let content_length =
                match List.assoc_opt "content-length" headers with
                | Some v -> (
                    match int_of_string_opt (String.trim v) with
                    | Some n when n >= 0 -> n
                    | _ -> 0)
                | None -> 0
              in
              let body_start = hdr_end + 4 in
              let have = String.length raw - body_start in
              let body_buf = Buffer.create (max content_length 16) in
              if have > 0 then
                Buffer.add_string body_buf
                  (String.sub raw body_start (min have content_length));
              let rec fill () =
                let missing = content_length - Buffer.length body_buf in
                if missing <= 0 then ()
                else
                  match Unix.read client buf 0 (min 4096 missing) with
                  | 0 -> ()
                  | n ->
                      Buffer.add_subbytes body_buf buf 0 n;
                      fill ()
                  | exception _ -> ()
              in
              fill ();
              Some
                ( String.uppercase_ascii meth,
                  target,
                  headers,
                  Buffer.contents body_buf )
          | _ -> None))

let append_capture ~capture_path line =
  match
    Unix.openfile capture_path [ Unix.O_WRONLY; Unix.O_APPEND; Unix.O_CREAT ]
      0o600
  with
  | exception _ -> ()
  | fd ->
      Fun.protect
        ~finally:(fun () -> try Unix.close fd with _ -> ())
        (fun () ->
          (try ignore (Unix.write_substring fd line 0 (String.length line))
           with _ -> ());
          try Unix.fsync fd with _ -> ())

let wire_response r =
  let b = Buffer.create (String.length r.resp_body + 256) in
  Buffer.add_string b
    (Printf.sprintf "HTTP/1.1 %d %s\r\n" r.status (reason_for r.status));
  Buffer.add_string b (Printf.sprintf "Content-Type: %s\r\n" r.content_type);
  (* Content-Length always advertises the FULL body: truncation cuts the
     wire short of the promise, which is exactly the fault under test. *)
  Buffer.add_string b
    (Printf.sprintf "Content-Length: %d\r\n" (String.length r.resp_body));
  List.iter
    (fun (k, v) -> Buffer.add_string b (Printf.sprintf "%s: %s\r\n" k v))
    r.extra_headers;
  Buffer.add_string b "Connection: close\r\n\r\n";
  (match r.truncate_body_at with
   | Some n when n < String.length r.resp_body ->
       Buffer.add_string b (String.sub r.resp_body 0 (max n 0))
   | _ -> Buffer.add_string b r.resp_body);
  Buffer.contents b

let write_all fd s =
  let len = String.length s in
  let rec go off =
    if off >= len then ()
    else
      match Unix.write_substring fd s off (len - off) with
      | 0 -> ()
      | n -> go (off + n)
      | exception _ -> ()
  in
  go 0

(* nth scripted response for a route: served in order, last one repeats *)
let route_response route idx =
  let n = Array.length route.responses in
  route.responses.(min idx (n - 1))

let handle_client client ~routes ~counters ~default ~capture_path =
  match read_request client with
  | None -> ()
  | Some (meth, target, headers, body) ->
      let path = path_of_target target in
      let line =
        Yojson.Safe.to_string
          (`Assoc
            [ ("method", `String meth);
              ("path", `String path);
              ("headers",
               `Assoc (List.map (fun (k, v) -> (k, `String v)) headers));
              ("body", `String body);
            ])
        ^ "\n"
      in
      append_capture ~capture_path line;
      let resp =
        let matched = ref None in
        Array.iteri
          (fun i r ->
            if !matched = None
               && (match r.meth with None -> true | Some m -> m = meth)
               && r.route_path = path
            then matched := Some i)
          routes;
        match !matched with
        | None -> default
        | Some i ->
            let idx = counters.(i) in
            counters.(i) <- idx + 1;
            route_response routes.(i) idx
      in
      if resp.close_without_response then ()
      else begin
        if resp.delay_s > 0.0 then Unix.sleepf resp.delay_s;
        write_all client (wire_response resp)
      end

let serve_forever sock ~routes ~default ~capture_path =
  (try Sys.set_signal Sys.sigpipe Sys.Signal_ignore with _ -> ());
  let routes = Array.of_list routes in
  let counters = Array.make (Array.length routes) 0 in
  let rec loop () =
    (match Unix.accept sock with
     | client, _ ->
         (try handle_client client ~routes ~counters ~default ~capture_path
          with _ -> ());
         (try Unix.close client with _ -> ())
     | exception _ -> ());
    loop ()
  in
  loop ()

(* ---------------------------------------------------------------------- *)
(* Lifecycle                                                               *)
(* ---------------------------------------------------------------------- *)

type t = {
  port : int;
  pid : int;
  capture_path : string;
  stopped : bool ref;
}

let start ?(routes = []) ?(default = default_response) () =
  Lazy.force ignore_sigpipe;
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt sock Unix.SO_REUSEADDR true;
  Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen sock 16;
  let port =
    match Unix.getsockname sock with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> failwith "Relay_test_support.start: expected INET socket"
  in
  let capture_path = Filename.temp_file "c2c-relay-test-support-" ".ndjson" in
  match Unix.fork () with
  | 0 ->
      (* Child: serve until the parent kills us. [Unix._exit] skips
         at_exit handlers inherited from the test harness. *)
      (try serve_forever sock ~routes ~default ~capture_path with _ -> ());
      Unix._exit 0
  | pid ->
      Unix.close sock;
      { port; pid; capture_path; stopped = ref false }

let stop t =
  if not !(t.stopped) then begin
    t.stopped := true;
    (try Unix.kill t.pid Sys.sigkill with _ -> ());
    try ignore (Unix.waitpid [] t.pid) with _ -> ()
  end

let url t = Printf.sprintf "http://127.0.0.1:%d" t.port

let with_server ?routes ?default f =
  let t = start ?routes ?default () in
  Fun.protect
    ~finally:(fun () ->
      stop t;
      try Sys.remove t.capture_path with _ -> ())
    (fun () -> f t)

(* A loopback port with nothing listening: bind, read the port, close.
   Connections to it are refused (connection-refused fault helper). *)
let closed_port () =
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> try Unix.close sock with _ -> ())
    (fun () ->
      Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname sock with
      | Unix.ADDR_INET (_, p) -> p
      | _ -> failwith "Relay_test_support.closed_port: expected INET socket")

let requests t =
  match open_in_bin t.capture_path with
  | exception _ -> []
  | ic ->
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
          let rec loop acc =
            match input_line ic with
            | exception End_of_file -> List.rev acc
            | line when String.trim line = "" -> loop acc
            | line -> (
                match Yojson.Safe.from_string line with
                | exception _ -> loop acc
                | `Assoc fields ->
                    let str k =
                      match List.assoc_opt k fields with
                      | Some (`String s) -> s
                      | _ -> ""
                    in
                    let headers =
                      match List.assoc_opt "headers" fields with
                      | Some (`Assoc hs) ->
                          List.filter_map
                            (fun (k, v) ->
                              match v with
                              | `String s -> Some (k, s)
                              | _ -> None)
                            hs
                      | _ -> []
                    in
                    loop
                      ({ meth_ = str "method"; path = str "path"; headers;
                         body = str "body" }
                       :: acc)
                | _ -> loop acc)
          in
          loop [])

(* ---------------------------------------------------------------------- *)
(* Blocking loopback HTTP client (for self-tests and fault assertions)     *)
(* ---------------------------------------------------------------------- *)

type http_response = {
  code : int;
  reason : string;
  resp_headers : (string * string) list; (* keys lowercased *)
  body_text : string;
  body_complete : bool; (* body length matches Content-Length *)
}

type http_result =
  | Http of http_response
  | Refused        (* connect refused (nothing listening) *)
  | Timeout        (* no (parseable) response within timeout_s *)
  | No_response    (* connection accepted, closed with zero bytes *)
  | Bad_response of string (* bytes arrived but are not HTTP *)

let parse_response raw : http_response option =
  match find_substring raw "\r\n\r\n" with
  | None -> None
  | Some i -> (
      let head = String.sub raw 0 i in
      let body = String.sub raw (i + 4) (String.length raw - i - 4) in
      let strip_cr l =
        let n = String.length l in
        if n > 0 && l.[n - 1] = '\r' then String.sub l 0 (n - 1) else l
      in
      let lines = String.split_on_char '\n' head |> List.map strip_cr in
      match lines with
      | [] -> None
      | status_line :: header_lines -> (
          match String.split_on_char ' ' status_line with
          | _http :: code_s :: rest -> (
              match int_of_string_opt code_s with
              | None -> None
              | Some code ->
                  let headers =
                    List.filter_map
                      (fun l ->
                        match String.index_opt l ':' with
                        | Some j ->
                            Some
                              ( String.lowercase_ascii
                                  (String.trim (String.sub l 0 j)),
                                String.trim
                                  (String.sub l (j + 1)
                                     (String.length l - j - 1)) )
                        | None -> None)
                      header_lines
                  in
                  let body_complete =
                    match List.assoc_opt "content-length" headers with
                    | Some v -> (
                        match int_of_string_opt (String.trim v) with
                        | Some n -> String.length body = n
                        | None -> true)
                    | None -> true
                  in
                  Some
                    { code;
                      reason = String.concat " " rest;
                      resp_headers = headers;
                      body_text = body;
                      body_complete })
          | _ -> None))

let http_request ?(meth = "GET") ?(headers = []) ?body ?(timeout_s = 5.0)
    ~port ~path () =
  Lazy.force ignore_sigpipe;
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> try Unix.close sock with _ -> ())
    (fun () ->
      (try Unix.setsockopt_float sock Unix.SO_RCVTIMEO timeout_s
       with _ -> ());
      (try Unix.setsockopt_float sock Unix.SO_SNDTIMEO timeout_s
       with _ -> ());
      match
        Unix.connect sock (Unix.ADDR_INET (Unix.inet_addr_loopback, port))
      with
      | exception Unix.Unix_error (Unix.ECONNREFUSED, _, _) -> Refused
      | exception
          Unix.Unix_error
            ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.ETIMEDOUT), _, _) ->
          Timeout
      | () ->
          let b = Buffer.create 256 in
          Buffer.add_string b (Printf.sprintf "%s %s HTTP/1.1\r\n" meth path);
          Buffer.add_string b (Printf.sprintf "Host: 127.0.0.1:%d\r\n" port);
          Buffer.add_string b "Connection: close\r\n";
          List.iter
            (fun (k, v) ->
              Buffer.add_string b (Printf.sprintf "%s: %s\r\n" k v))
            headers;
          (match body with
           | Some payload ->
               Buffer.add_string b
                 (Printf.sprintf "Content-Length: %d\r\n\r\n%s"
                    (String.length payload) payload)
           | None -> Buffer.add_string b "\r\n");
          (* Server may close before/while we write (close-without-response
             faults): swallow and still try to read what came back. *)
          (try write_all sock (Buffer.contents b) with _ -> ());
          let buf = Bytes.create 4096 in
          let acc = Buffer.create 1024 in
          let rec recv () =
            match Unix.read sock buf 0 4096 with
            | 0 -> `Eof
            | n ->
                Buffer.add_subbytes acc buf 0 n;
                recv ()
            | exception
                Unix.Unix_error
                  ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.ETIMEDOUT), _, _)
              ->
                `Timeout
            | exception Unix.Unix_error (Unix.ECONNRESET, _, _) -> `Eof
            | exception _ -> `Eof
          in
          let outcome = recv () in
          let raw = Buffer.contents acc in
          (match outcome, raw with
           | `Timeout, raw -> (
               (* a complete-enough response may have landed just before
                  the deadline; only report Timeout when unparseable *)
               match parse_response raw with
               | Some r -> Http r
               | None -> Timeout)
           | `Eof, "" -> No_response
           | `Eof, raw -> (
               match parse_response raw with
               | Some r -> Http r
               | None -> Bad_response raw)))
