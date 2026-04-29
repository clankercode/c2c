(** #330 S2: relay-to-relay forwarder.

    Handles the "forwarder" side of the cross-relay protocol: given a
    peer relay's identity info, POST a signed forward request to it and
    classify the response. *)

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

(** [forward_send ~identity ~self_host ~peer_url ~peer_identity_pk ~from_alias
    ~to_alias ~content ~message_id]
    signs the forward request with [identity] and POSTs it to [peer_url].

    The body shape is:
    {{ from_alias: "alice@relay-a"   (* host-tagged origin *)
       to_alias: "bob"               (* bare alias on destination relay *)
       content: <verbatim>
       message_id: <verbatim>
       via: ["relay-a"]              (* origin relay tags via list *)
    }}

    Returns [Delivered ts] on 200, [Duplicate ts] on 200 with duplicate flag,
    or an error variant on any other status / connection failure.
    5 s timeout; dead-letter on timeout / 5xx / 4xx / 401 / local error. *)
val forward_send :
  identity:Relay_identity.t ->
  self_host:string ->
  peer_url:string ->
  from_alias:string ->
  to_alias:string ->
  content:string ->
  message_id:string ->
  forward_outcome Lwt.t

(** [build_body ~self_host ~from_alias ~to_alias ~content ~message_id]
    constructs the forward-request body JSON per the wire spec.
    Exposed for unit testing. *)
val build_body :
  self_host:string -> from_alias:string -> to_alias:string ->
  content:string -> message_id:string -> Yojson.Safe.t

(** [classify_response ~status ~body] maps an HTTP response to a
    forward_outcome.  Exposed for unit testing. *)
val classify_response : status:int -> body:string -> forward_outcome
