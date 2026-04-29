(* #330 S2: relay-to-relay forwarder.
   See relay_forwarder.mli for the public surface. *)

(** Outcome of a forward attempt. Each constructor carries the minimum
    information needed by the caller to (a) respond to the original sender
    and (b) write a dead-letter row if applicable. *)
type forward_outcome =
  | Delivered of float           (** peer accepted; ts from peer response *)
  | Duplicate of float           (** peer dedup'd; still success, no dead-letter *)
  | Peer_unreachable of string   (** connect refused / DNS fail; reason string *)
  | Peer_timeout                (** 5 s exceeded *)
  | Peer_5xx of int * string   (** status code, body excerpt *)
  | Peer_4xx of int * string   (** status code, body excerpt (propagate dest reason) *)
  | Peer_unauthorized           (** 401 — our identity not registered on peer *)
  | Local_error of string       (** signing / encoding bug; should never happen *)

(** Build the forward-request body per the wire spec.

    The [via] list is pre-populated with [self_host] by the caller
    (["relay-a"] in the normal case). *)
let build_body ~self_host ~from_alias ~to_alias ~content ~message_id =
  `Assoc [
    "from_alias", `String (Printf.sprintf "%s@%s" from_alias self_host);
    "to_alias",   `String to_alias;
    "content",    `String content;
    "message_id", `String message_id;
    "via",        `List [`String self_host];
  ]

(** Classify an HTTP response from a peer relay into a [forward_outcome].

    The response body is inspected for error codes. *)
let classify_response ~status ~body =
  let open Yojson.Safe.Util in
  let body_excerpt =
    if String.length body > 200 then String.sub body 0 200 ^ "…" else body
  in
  if status = 200 then
    (* Check for { "ok": true } or { "ok": true, "duplicate": true, "ts": … } *)
    match Yojson.Safe.from_string body with
    | exception _ -> Peer_5xx (status, body_excerpt)
    | json ->
        let ok = json |> member "ok" |> to_bool_option |> Option.value ~default:false in
        if not ok then Peer_5xx (status, body_excerpt)
        else
          let ts = json |> member "ts" |> to_number_option |> Option.value ~default:0.0 in
          let duplicate = json |> member "duplicate" |> to_bool_option |> Option.value ~default:false in
          if duplicate then Duplicate ts else Delivered ts
  else if status = 401 then Peer_unauthorized
  else if status >= 500 then Peer_5xx (status, body_excerpt)
  else Peer_4xx (status, body_excerpt)

(** [sign_forward_request ~identity ~self_host ~from_alias ~body_str]
    signs a forward request and returns the full "Authorization" header value.

    Reuses [Relay_signed_ops.sign_request] which returns the already-formatted
    header string "Ed25519 alias=<a>,ts=<t>,nonce=<n>,sig=<s>". *)
let sign_forward_request ~identity ~self_host ~from_alias ~body_str =
  let alias = Printf.sprintf "%s@%s" from_alias self_host in
  let meth = "POST" in
  let path = "/forward" in
  Relay_signed_ops.sign_request identity ~alias ~meth ~path ~body_str ()

(** Main forward function. Signs and POSTs to the peer relay.

    @param peer_url Full URL of the peer relay (e.g. "https://relay-b:9001") *)
let forward_send ~identity ~self_host ~peer_url
    ~from_alias ~to_alias ~content ~message_id =
  let body = build_body ~self_host ~from_alias ~to_alias ~content ~message_id in
  let body_str = Yojson.Safe.to_string body in
  let uri = Uri.of_string peer_url in
  let headers = Cohttp.Header.init_with "Content-Type" "application/json" in
  let auth_value = sign_forward_request ~identity ~self_host ~from_alias ~body_str in
  let headers = Cohttp.Header.add headers "Authorization" auth_value in
  let body_payload = Cohttp_lwt.Body.of_string body_str in
  Lwt.catch (fun () ->
    Lwt_unix.with_timeout 5.0 (fun () ->
      Lwt.bind (Cohttp_lwt_unix.Client.call `POST uri ~headers ~body:body_payload)
        (fun (res, body) ->
          let status = Cohttp.Code.code_of_status res.status in
          Lwt.bind (Cohttp_lwt.Body.to_string body)
            (fun body_str ->
              Lwt.return (classify_response ~status ~body:body_str))))
  ) (function
    | Lwt_unix.Timeout -> Lwt.return Peer_timeout
    | Unix.Unix_error (e, _, _) ->
        Lwt.return (Peer_unreachable (Unix.error_message e))
    | e ->
        Lwt.return (Local_error (Printexc.to_string e))
  )
