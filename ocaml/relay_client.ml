[@@@warning "-16"]

open Lwt.Infix
open Relay_common

(* --- Relay_client --- *)

module Relay_client : sig
  type t

  val make : ?token:string -> ?timeout:float -> ?ca_bundle:string -> string -> t
  (** [make ?token ?timeout ?ca_bundle base_url] builds a client for an HTTP
      relay.  [base_url] is e.g. ["http://localhost:8765"] (no trailing slash).
      [ca_bundle] is a path to a PEM CA bundle for HTTPS with self-signed
      certs (e.g. Tailscale scenarios).  Defaults to env
      [C2C_RELAY_CA_BUNDLE]; omitting both uses the system trust store. *)

  val request :
    t -> meth:Cohttp.Code.meth -> path:string -> ?body:Yojson.Safe.t ->
    ?auth_override:string -> unit -> Yojson.Safe.t Lwt.t
  (** Low-level primitive: issue [meth path] with optional JSON body.
      Returns the parsed JSON response dict, reconciled with the HTTP
      status line (H7 status-honesty contract):

      - 2xx: the parsed body is returned untouched — ["ok": true] is
        possible ONLY here.
      - non-2xx with an honest ["ok": false] object body: the body passes
        through (its own [error_code]/[error] win) annotated with
        ["http_status": <code>].
      - non-2xx whose body does NOT report ["ok": false] (claims success,
        lacks [ok], or is not an object): overridden with ["ok": false,
        "error_code": "http_error_<code>", "http_status": <code>] and the
        offending body preserved under ["relay_response"] — the status
        line always wins over a dishonest body.
      - transport failure (connection refused, timeout, TLS error,
        unparseable response body): a locally-synthesized ["ok": false,
        "error_code": "connection_error", "error": <msg>,
        "transport": true]. The ["transport": true] marker distinguishes
        "could not get a coherent response" from "the relay responded
        with an error" — see [is_transport_error]. Never raises. *)

  val is_transport_error : Yojson.Safe.t -> bool
  (** True iff [json] is a client-synthesized transport failure (carries
      ["transport": true]) — i.e. the relay never produced a coherent
      HTTP/JSON response. False for every genuine relay response,
      including non-2xx / ok:false ones. Consumers that must distinguish
      "relay unreachable" from "relay responded with an error" (e.g.
      `c2c doctor --relay` relay.reachable) key off this. *)

  val is_protocol_incompatible : Yojson.Safe.t -> bool
  (** True iff [json] is (or was rewritten into) a protocol-skew error —
      [error_code = "incompatible_client"]. Distinct from transport
      failure (relay up, wire version mismatched). *)

  type protocol_compat =
    | Compatible
    | Unknown
        (** Health body has no [protocol_version] (pre-B121 relay). Not a
            hard fail — older relays stay usable until they advertise. *)
    | Client_too_old of {
        server_protocol : int;
        client_protocol : int;
        min_client : int;
        server_version : string option;
      }
    | Client_too_new of {
        server_protocol : int;
        client_protocol : int;
        server_version : string option;
      }

  val protocol_compat_of_health :
    ?client_protocol:int -> Yojson.Safe.t -> protocol_compat
  (** Parse a /health body and compare against this client's protocol
      version (default [Version.relay_protocol_version]). *)

  val upgrade_message : url:string -> protocol_compat -> string option
  (** Actionable one-line upgrade / deploy message, or [None] when the
      relay is compatible or did not advertise a protocol version. *)

  val check_health_protocol :
    t -> Yojson.Safe.t -> Yojson.Safe.t
  (** If [health_json] reports wire-incompatible protocol versions,
      rewrite into an [ok:false / incompatible_client] object with the
      upgrade text in [error]. Compatible / unknown bodies pass through. *)

  val health : t -> Yojson.Safe.t Lwt.t
  val register :
    t -> node_id:string -> session_id:string -> alias:string ->
    ?client_type:string -> ?ttl:float -> ?identity_pk:string -> ?enc_pubkey:string -> ?signed_at:float -> ?sig_b64:string -> ?opaque_host_id:string ->
    unit -> Yojson.Safe.t Lwt.t
  val register_signed :
    t -> node_id:string -> session_id:string -> alias:string ->
    ?client_type:string -> ?ttl:float -> ?opaque_host_id:string ->
    identity_pk_b64:string -> sig_b64:string -> nonce:string -> ts:string ->
    unit -> Yojson.Safe.t Lwt.t
  val heartbeat : t -> node_id:string -> session_id:string -> Yojson.Safe.t Lwt.t
  val heartbeat_signed : t -> node_id:string -> session_id:string -> auth_header:string -> Yojson.Safe.t Lwt.t
  val list_peers : t -> ?include_dead:bool -> unit -> Yojson.Safe.t Lwt.t
  val list_peers_signed : t -> ?include_dead:bool -> auth_header:string -> unit -> Yojson.Safe.t Lwt.t
  val send :
    t -> from_alias:string -> to_alias:string -> content:string ->
    ?message_id:string -> unit -> Yojson.Safe.t Lwt.t
  val send_signed :
    t -> from_alias:string -> to_alias:string -> content:string ->
    auth_header:string -> ?message_id:string -> unit -> Yojson.Safe.t Lwt.t
  val poll_inbox : t -> node_id:string -> session_id:string -> Yojson.Safe.t Lwt.t
  val poll_inbox_signed : t -> node_id:string -> session_id:string -> auth_header:string -> Yojson.Safe.t Lwt.t
  val peek_inbox : t -> node_id:string -> session_id:string -> Yojson.Safe.t Lwt.t
  val peek_inbox_signed : t -> node_id:string -> session_id:string -> auth_header:string -> Yojson.Safe.t Lwt.t
  val list_rooms : t -> Yojson.Safe.t Lwt.t
  val room_history :
    t -> room_id:string -> ?limit:int -> unit -> Yojson.Safe.t Lwt.t
  val room_history_signed :
    t -> room_id:string -> ?limit:int -> auth_header:string -> unit -> Yojson.Safe.t Lwt.t
  val join_room : t -> ?visibility:string -> alias:string -> room_id:string -> Yojson.Safe.t Lwt.t
  val join_room_signed : t -> ?visibility:string -> alias:string -> room_id:string
    -> identity_pk:string -> ts:string -> nonce:string -> sig_:string
    -> Yojson.Safe.t Lwt.t
  val leave_room : t -> alias:string -> room_id:string -> Yojson.Safe.t Lwt.t
  val leave_room_signed : t -> alias:string -> room_id:string
    -> identity_pk:string -> ts:string -> nonce:string -> sig_:string
    -> Yojson.Safe.t Lwt.t
  val send_room :
    t -> from_alias:string -> room_id:string -> content:string ->
    ?message_id:string -> unit -> Yojson.Safe.t Lwt.t
  val send_room_signed :
    t -> from_alias:string -> room_id:string -> content:string ->
    envelope:Yojson.Safe.t -> ?message_id:string -> unit ->
    Yojson.Safe.t Lwt.t
  val invite_room : t -> alias:string -> room_id:string -> invitee_pk:string -> Yojson.Safe.t Lwt.t
  val invite_room_signed : t -> alias:string -> room_id:string -> invitee_pk:string -> identity_pk:string -> ts:string -> nonce:string -> sig_:string -> Yojson.Safe.t Lwt.t
  val uninvite_room : t -> alias:string -> room_id:string -> invitee_pk:string -> Yojson.Safe.t Lwt.t
  val uninvite_room_signed : t -> alias:string -> room_id:string -> invitee_pk:string -> identity_pk:string -> ts:string -> nonce:string -> sig_:string -> Yojson.Safe.t Lwt.t
  val knock_room : t -> alias:string -> room_id:string -> requester_pk:string -> Yojson.Safe.t Lwt.t
  val knock_room_signed : t -> alias:string -> room_id:string -> identity_pk:string -> ts:string -> nonce:string -> sig_:string -> Yojson.Safe.t Lwt.t
  val list_room_knocks : t -> alias:string -> room_id:string -> Yojson.Safe.t Lwt.t
  val list_room_knocks_signed : t -> alias:string -> room_id:string -> identity_pk:string -> ts:string -> nonce:string -> sig_:string -> Yojson.Safe.t Lwt.t
  val approve_room_knock : t -> alias:string -> room_id:string -> requester_pk:string -> Yojson.Safe.t Lwt.t
  val approve_room_knock_signed : t -> alias:string -> room_id:string -> requester_pk:string -> identity_pk:string -> ts:string -> nonce:string -> sig_:string -> Yojson.Safe.t Lwt.t
  val deny_room_knock : t -> alias:string -> room_id:string -> requester_pk:string -> Yojson.Safe.t Lwt.t
  val deny_room_knock_signed : t -> alias:string -> room_id:string -> requester_pk:string -> identity_pk:string -> ts:string -> nonce:string -> sig_:string -> Yojson.Safe.t Lwt.t
  val set_room_visibility : t -> alias:string -> room_id:string -> visibility:string -> Yojson.Safe.t Lwt.t
  val set_room_visibility_signed : t -> alias:string -> room_id:string -> visibility:string
    -> identity_pk:string -> ts:string -> nonce:string -> sig_:string -> Yojson.Safe.t Lwt.t
  val set_room_history_public_signed : t -> alias:string -> room_id:string -> history_public:bool
    -> identity_pk:string -> ts:string -> nonce:string -> sig_:string -> Yojson.Safe.t Lwt.t
  val mobile_pair_prepare : t -> machine_ed25519_pubkey:string -> token:string -> Yojson.Safe.t Lwt.t
  val mobile_pair_confirm : t -> token:string -> phone_ed25519_pubkey:string -> phone_x25519_pubkey:string -> Yojson.Safe.t Lwt.t
  (** B116: revocation carries a signed owner proof (machine or phone
      Ed25519 key) — build it with [Relay_signed_ops.sign_binding_revoke].
      A bare binding ID no longer authorizes deletion. *)
  val mobile_pair_revoke :
    t -> binding_id:string -> revoke_pk:string -> ts:string ->
    nonce:string -> sig_b64:string -> Yojson.Safe.t Lwt.t
  val device_pair_init : t -> machine_ed25519_pubkey:string -> Yojson.Safe.t Lwt.t
  val device_pair_poll : t -> user_code:string -> Yojson.Safe.t Lwt.t
  val gc : t -> Yojson.Safe.t Lwt.t
  val dead_letter : t -> Yojson.Safe.t Lwt.t
end = struct

  type t = {
    base_url : string;
    token : string option;
    timeout : float;
    ca_bundle : string option;
  }

  let strip_trailing_slash s =
    let n = String.length s in
    if n > 0 && s.[n-1] = '/' then String.sub s 0 (n-1) else s

  let make ?token ?(timeout = 10.0) ?ca_bundle base_url =
    let ca_bundle = match ca_bundle with
      | Some _ -> ca_bundle
      | None ->
          match Sys.getenv_opt "C2C_RELAY_CA_BUNDLE" with
          | Some p when p <> "" -> Some p
          | _ -> None
    in
    { base_url = strip_trailing_slash base_url; token; timeout; ca_bundle }

  (* Build a custom Net.ctx from a PEM CA bundle path for self-signed certs. *)
  let net_ctx_of_bundle path =
    let pem =
      let ic = open_in path in
      let n = in_channel_length ic in
      let buf = Bytes.create n in
      really_input ic buf 0 n;
      close_in ic;
      Bytes.to_string buf
    in
    let certs = match X509.Certificate.decode_pem_multiple pem with
      | Ok cs -> cs
      | Error (`Msg m) -> failwith ("C2C_RELAY_CA_BUNDLE parse error: " ^ m)
    in
    let auth = X509.Authenticator.chain_of_trust
      ~time:(fun () -> Some (Ptime_clock.now ())) certs
    in
    Conduit_lwt_unix.init ~tls_authenticator:auth () >>= fun conduit_ctx ->
    Lwt.return (Cohttp_lwt_unix.Client.custom_ctx ~ctx:conduit_ctx ())

  (* Client-synthesized transport failure: the relay never produced a
     coherent HTTP/JSON response. [transport: true] is the marker that
     lets consumers (doctor reachable check) tell this apart from a
     genuine relay error response — see the [request] contract above. *)
  let connection_error msg =
    `Assoc [
      ("ok", `Bool false);
      ("error_code", `String "connection_error");
      ("error", `String msg);
      ("transport", `Bool true);
    ]

  let is_transport_error = function
    | `Assoc fields -> List.assoc_opt "transport" fields = Some (`Bool true)
    | _ -> false

  let is_protocol_incompatible = function
    | `Assoc fields ->
        List.assoc_opt "error_code" fields
        = Some (`String relay_err_incompatible_client)
    | _ -> false

  type protocol_compat =
    | Compatible
    | Unknown
    | Client_too_old of {
        server_protocol : int;
        client_protocol : int;
        min_client : int;
        server_version : string option;
      }
    | Client_too_new of {
        server_protocol : int;
        client_protocol : int;
        server_version : string option;
      }

  let json_int_field fields name =
    match List.assoc_opt name fields with
    | Some (`Int i) -> Some i
    | Some (`Float f) when classify_float f = FP_normal
                          || classify_float f = FP_zero ->
        let i = int_of_float f in
        if float_of_int i = f then Some i else None
    | Some (`String s) -> int_of_string_opt s
    | _ -> None

  let json_string_field fields name =
    match List.assoc_opt name fields with
    | Some (`String s) -> Some s
    | _ -> None

  let protocol_compat_of_health
      ?(client_protocol = Version.relay_protocol_version) = function
    | `Assoc fields ->
        (match json_int_field fields "protocol_version" with
         | None -> Unknown
         | Some server_protocol ->
             let min_client =
               match json_int_field fields "min_client_protocol_version" with
               | Some m -> m
               | None -> server_protocol
             in
             let server_version = json_string_field fields "version" in
             if client_protocol < min_client then
               Client_too_old {
                 server_protocol; client_protocol; min_client; server_version;
               }
             else if client_protocol > server_protocol then
               Client_too_new {
                 server_protocol; client_protocol; server_version;
               }
             else Compatible)
    | _ -> Unknown

  let upgrade_message ~url = function
    | Client_too_old {
        server_protocol; client_protocol; server_version; _
      } ->
        let sv = Option.value server_version ~default:"?" in
        Some (Printf.sprintf
          "relay %s speaks protocol v%d (server %s); this client speaks v%d \
           — upgrade c2c (git pull && just install-all) to reconnect."
          url server_protocol sv client_protocol)
    | Client_too_new {
        server_protocol; client_protocol; server_version;
      } ->
        let sv = Option.value server_version ~default:"?" in
        Some (Printf.sprintf
          "relay %s speaks protocol v%d (server %s); this client speaks v%d \
           — the relay is older than this client; wait for a relay deploy or \
           point C2C_RELAY_URL at a matching relay."
          url server_protocol sv client_protocol)
    | Compatible | Unknown -> None

  let incompatible_error ~url ~compat ?(underlying = None) () =
    match upgrade_message ~url compat with
    | None ->
        `Assoc [
          ("ok", `Bool false);
          ("error_code", `String relay_err_incompatible_client);
          ("error", `String "incompatible relay protocol");
        ]
    | Some msg ->
        let base = [
          ("ok", `Bool false);
          ("error_code", `String relay_err_incompatible_client);
          ("error", `String msg);
          ("client_protocol_version",
           `Int Version.relay_protocol_version);
        ] in
        let base =
          match compat with
          | Client_too_old {
              server_protocol; min_client; server_version; _
            } ->
              base
              @ [ ("server_protocol_version", `Int server_protocol);
                  ("min_client_protocol_version", `Int min_client) ]
              @ (match server_version with
                 | Some v -> [ ("server_version", `String v) ]
                 | None -> [])
          | Client_too_new { server_protocol; server_version; _ } ->
              base
              @ [ ("server_protocol_version", `Int server_protocol) ]
              @ (match server_version with
                 | Some v -> [ ("server_version", `String v) ]
                 | None -> [])
          | Compatible | Unknown -> base
        in
        let base =
          match underlying with
          | Some (`Assoc ufields as u) ->
              let und_code =
                match List.assoc_opt "error_code" ufields with
                | Some c -> [ ("underlying_error_code", c) ]
                | None -> []
              in
              let und_err =
                match List.assoc_opt "error" ufields with
                | Some e -> [ ("underlying_error", e) ]
                | None -> []
              in
              base @ und_code @ und_err
              @ [ ("underlying_response", u) ]
          | Some u -> base @ [ ("underlying_response", u) ]
          | None -> base
        in
        `Assoc base

  let check_health_protocol t health_json =
    match protocol_compat_of_health health_json with
    | (Client_too_old _ | Client_too_new _) as compat ->
        incompatible_error ~url:t.base_url ~compat ()
    | Compatible | Unknown -> health_json

  (* Reconcile the parsed body with the HTTP status line (H7): a non-2xx
     status can NEVER yield ok:true. An honest ok:false object body passes
     through (its own error_code wins — the fault matrix pins 401/429/500
     cells on the body's code) annotated with http_status; anything else on
     a non-2xx is overridden, preserving the body under relay_response. *)
  let reconcile_status ~status body =
    if status >= 200 && status < 300 then body
    else
      match body with
      | `Assoc fields when List.assoc_opt "ok" fields = Some (`Bool false) ->
          let fields = List.filter (fun (k, _) -> k <> "http_status") fields in
          `Assoc (fields @ [ ("http_status", `Int status) ])
      | dishonest ->
          `Assoc [
            ("ok", `Bool false);
            ("error_code", `String (Printf.sprintf "http_error_%d" status));
            ("error", `String (Printf.sprintf
              "relay answered HTTP %d but the body did not report ok:false"
              status));
            ("http_status", `Int status);
            ("relay_response", dishonest);
          ]

  let response_ok = function
    | `Assoc fields -> List.assoc_opt "ok" fields = Some (`Bool true)
    | _ -> false

  (* Strip query string for path comparisons (e.g. /list?include_dead=1). *)
  let path_without_query path =
    match String.index_opt path '?' with
    | None -> path
    | Some i -> String.sub path 0 i

  let request_raw t ~meth ~path ?body ?auth_override () =
    let uri = Uri.of_string (t.base_url ^ path) in
    let headers =
      let base = Cohttp.Header.init_with "Content-Type" "application/json" in
      (* B121: advertise client wire version so a future relay can reject
         ancient clients with a structured incompatible_client error. *)
      let base =
        Cohttp.Header.add base "X-C2C-Protocol-Version"
          (string_of_int Version.relay_protocol_version)
      in
      match auth_override with
      | Some h -> Cohttp.Header.add base "Authorization" h
      | None ->
          (match t.token with
           | Some tok -> Cohttp.Header.add base "Authorization" ("Bearer " ^ tok)
           | None -> base)
    in
    let body_str = Yojson.Safe.to_string (Option.value body ~default:(`Assoc [])) in
    let body_payload = Cohttp_lwt.Body.of_string body_str in
    Lwt.catch
      (fun () ->
        (match t.ca_bundle with
         | None -> Lwt.return_none
         | Some path -> net_ctx_of_bundle path >|= Option.some)
        >>= fun ctx_opt ->
        let call =
          Cohttp_lwt_unix.Client.call ?ctx:ctx_opt ~headers ~body:body_payload meth uri
        in
        Lwt.pick [
          call;
          (Lwt_unix.sleep t.timeout >>= fun () ->
           Lwt.fail (Failure "request_timeout"));
        ]
        >>= fun (resp, resp_body) ->
        let status = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
        Cohttp_lwt.Body.to_string resp_body >>= fun text ->
        try Lwt.return (reconcile_status ~status (Yojson.Safe.from_string text))
        with _ -> Lwt.return (connection_error "invalid_json_response"))
      (fun exn ->
        Lwt.return (connection_error (Printexc.to_string exn)))

  (* On a genuine (non-transport) relay error, opportunistically GET /health
     and rewrite the error into incompatible_client when versions skew. Skips
     the /health path itself to avoid recursion. Transport errors stay
     transport — unreachable is not "incompatible". *)
  let maybe_annotate_protocol_skew t ~path body =
    if is_transport_error body
       || response_ok body
       || is_protocol_incompatible body
       || path_without_query path = "/health"
    then Lwt.return body
    else
      request_raw t ~meth:`GET ~path:"/health" () >>= fun health_json ->
      if is_transport_error health_json then Lwt.return body
      else
        match protocol_compat_of_health health_json with
        | (Client_too_old _ | Client_too_new _) as compat ->
            Lwt.return
              (incompatible_error ~url:t.base_url ~compat
                 ~underlying:(Some body) ())
        | Compatible | Unknown -> Lwt.return body

  let request t ~meth ~path ?body ?auth_override () =
    request_raw t ~meth ~path ?body ?auth_override () >>= fun body ->
    maybe_annotate_protocol_skew t ~path body

  let post t path body = request t ~meth:`POST ~path ~body ()
  let post_auth t path body auth = request t ~meth:`POST ~path ~body ~auth_override:auth ()
  let get t path = request t ~meth:`GET ~path ()

  let post_with_pow_retry t path ~route ~actor_id body =
    let post_body body = post t path body in
    Pow_client.post_with_retry ~post:post_body ~route ~actor_id body

  let health t =
    request_raw t ~meth:`GET ~path:"/health" () >|= fun j ->
    if is_transport_error j then j else check_health_protocol t j

  (* B174: always attach a host id so /stats unique_machines / connected.machines
     can key on the real machine rather than per-session node_id (cli-<alias>).
     Callers may still override; empty falls back to local Host_id. *)
  let resolve_opaque_host_id opaque_host_id =
    if opaque_host_id <> "" then opaque_host_id
    else (try Host_id.compute_host_hash () with _ -> "")

  let register t ~node_id ~session_id ~alias
      ?(client_type = "unknown") ?(ttl = default_lease_ttl) ?(identity_pk = "")
      ?(enc_pubkey = "") ?(signed_at = 0.0) ?(sig_b64 = "") ?(opaque_host_id = "") () =
    let opaque_host_id = resolve_opaque_host_id opaque_host_id in
    let base = [
      ("node_id", `String node_id);
      ("session_id", `String session_id);
      ("alias", `String alias);
      ("client_type", `String client_type);
      (* B149: connection metadata feeding /stats connected.by_version/by_os. *)
      ("client_version", `String Version.version);
      ("client_os", `String (Relay_common.client_os ()));
      ("ttl", `Int (int_of_float ttl));
    ] in
    let fields =
      if identity_pk = "" then base
      else
        let b64 = Base64.encode_string ~pad:false
          ~alphabet:Base64.uri_safe_alphabet identity_pk
        in
        base @ [("identity_pk", `String b64)]
    in
    let fields =
      if enc_pubkey <> "" then
        fields @ [("enc_pubkey", `String enc_pubkey); ("signed_at", `Float signed_at); ("sig_b64", `String sig_b64)]
      else fields
    in
    let fields =
      if opaque_host_id <> "" then
        fields @ [("opaque_host_id", `String opaque_host_id)]
      else fields
    in
    let actor_id =
      if identity_pk = "" then "" else b64url_nopad_encode identity_pk
    in
    post_with_pow_retry t "/register" ~route:"register" ~actor_id
      (`Assoc fields)

  let register_signed t ~node_id ~session_id ~alias
      ?(client_type = "unknown") ?(ttl = default_lease_ttl)
      ?(opaque_host_id = "")
      ~identity_pk_b64 ~sig_b64 ~nonce ~ts () =
    let opaque_host_id = resolve_opaque_host_id opaque_host_id in
    let base = [
      ("node_id", `String node_id);
      ("session_id", `String session_id);
      ("alias", `String alias);
      ("client_type", `String client_type);
      (* B149: connection metadata feeding /stats connected.by_version/by_os. *)
      ("client_version", `String Version.version);
      ("client_os", `String (Relay_common.client_os ()));
      ("ttl", `Int (int_of_float ttl));
      ("identity_pk", `String identity_pk_b64);
      ("signature", `String sig_b64);
      ("nonce", `String nonce);
      ("timestamp", `String ts);
    ] in
    let body = if opaque_host_id <> "" then
      `Assoc (("opaque_host_id", `String opaque_host_id) :: base)
    else
      `Assoc base
    in
    post_with_pow_retry t "/register" ~route:"register"
      ~actor_id:identity_pk_b64 body

  let heartbeat t ~node_id ~session_id =
    let opaque_host_id = resolve_opaque_host_id "" in
    let fields = [
      ("node_id", `String node_id);
      ("session_id", `String session_id);
    ] in
    let fields =
      if opaque_host_id <> "" then
        fields @ [ ("opaque_host_id", `String opaque_host_id) ]
      else fields
    in
    post t "/heartbeat" (`Assoc fields)

  let heartbeat_signed t ~node_id ~session_id ~auth_header =
    let opaque_host_id = resolve_opaque_host_id "" in
    let fields = [
      ("node_id", `String node_id);
      ("session_id", `String session_id);
    ] in
    let fields =
      if opaque_host_id <> "" then
        fields @ [ ("opaque_host_id", `String opaque_host_id) ]
      else fields
    in
    post_auth t "/heartbeat" (`Assoc fields) auth_header

  let list_peers t ?(include_dead = false) () =
    if include_dead then get t "/list?include_dead=1" else get t "/list"

  let list_peers_signed t ?(include_dead = false) ~auth_header () =
    if include_dead then
      request t ~meth:`GET ~path:"/list?include_dead=1" ~auth_override:auth_header ()
    else
      request t ~meth:`GET ~path:"/list" ~auth_override:auth_header ()

  let poll_inbox_signed t ~node_id ~session_id ~auth_header =
    let body = `Assoc [
      ("node_id", `String node_id);
      ("session_id", `String session_id);
    ] in
    post_auth t "/poll_inbox" body auth_header

  let send t ~from_alias ~to_alias ~content ?message_id () =
    let base = [
      ("from_alias", `String from_alias);
      ("to_alias", `String to_alias);
      ("content", `String content);
    ] in
    let body = match message_id with
      | Some mid -> ("message_id", `String mid) :: base
      | None -> base
    in
    post t "/send" (`Assoc body)

  let send_signed t ~from_alias ~to_alias ~content ~auth_header ?message_id () =
    let base = [
      ("from_alias", `String from_alias);
      ("to_alias", `String to_alias);
      ("content", `String content);
    ] in
    let body = match message_id with
      | Some mid -> ("message_id", `String mid) :: base
      | None -> base
    in
    post_auth t "/send" (`Assoc body) auth_header

  let poll_inbox t ~node_id ~session_id =
    post t "/poll_inbox" (`Assoc [
      ("node_id", `String node_id);
      ("session_id", `String session_id);
    ])

  (* B096: non-destructive counterpart to [poll_inbox]. The relay's
     /peek_inbox route returns the same messages list without clearing
     the inbox, so a tail/monitor watcher (B089) can observe pending DMs
     without stealing them from the real poll-loop consumer. *)
  let peek_inbox t ~node_id ~session_id =
    post t "/peek_inbox" (`Assoc [
      ("node_id", `String node_id);
      ("session_id", `String session_id);
    ])

  let peek_inbox_signed t ~node_id ~session_id ~auth_header =
    let body = `Assoc [
      ("node_id", `String node_id);
      ("session_id", `String session_id);
    ] in
    post_auth t "/peek_inbox" body auth_header

  let list_rooms t = get t "/list_rooms"

  let room_history t ~room_id ?(limit = 50) () =
    post t "/room_history" (`Assoc [
      ("room_id", `String room_id);
      ("limit", `Int limit);
    ])

  let room_history_signed t ~room_id ?(limit = 50) ~auth_header () =
    post_auth t "/room_history"
      (`Assoc [
        ("room_id", `String room_id);
        ("limit", `Int limit);
      ])
      auth_header

  let join_room t ?visibility ~alias ~room_id =
    let fields = [
      ("alias", `String alias);
      ("room_id", `String room_id);
    ] in
    let fields =
      match visibility with
      | None -> fields
      | Some v -> ("visibility", `String v) :: fields
    in
    post t "/join_room" (`Assoc fields)

  let join_room_signed t ?visibility ~alias ~room_id ~identity_pk ~ts ~nonce ~sig_ =
    let fields = [
      ("alias", `String alias);
      ("room_id", `String room_id);
      ("identity_pk", `String identity_pk);
      ("ts", `String ts);
      ("nonce", `String nonce);
      ("sig", `String sig_);
    ] in
    let fields =
      match visibility with
      | None -> fields
      | Some v -> ("visibility", `String v) :: fields
    in
    post t "/join_room" (`Assoc fields)

  let leave_room t ~alias ~room_id =
    post t "/leave_room" (`Assoc [
      ("alias", `String alias);
      ("room_id", `String room_id);
    ])

  let leave_room_signed t ~alias ~room_id ~identity_pk ~ts ~nonce ~sig_ =
    post t "/leave_room" (`Assoc [
      ("alias", `String alias);
      ("room_id", `String room_id);
      ("identity_pk", `String identity_pk);
      ("ts", `String ts);
      ("nonce", `String nonce);
      ("sig", `String sig_);
    ])

  let send_room t ~from_alias ~room_id ~content ?message_id () =
    let base = [
      ("from_alias", `String from_alias);
      ("room_id", `String room_id);
      ("content", `String content);
    ] in
    let body = match message_id with
      | Some mid -> ("message_id", `String mid) :: base
      | None -> base
    in
    post t "/send_room" (`Assoc body)

  let send_room_signed t ~from_alias ~room_id ~content ~envelope ?message_id () =
    let base = [
      ("from_alias", `String from_alias);
      ("room_id", `String room_id);
      ("content", `String content);
      ("envelope", envelope);
    ] in
    let body = match message_id with
      | Some mid -> ("message_id", `String mid) :: base
      | None -> base
    in
    post t "/send_room" (`Assoc body)

  let invite_room t ~alias ~room_id ~invitee_pk =
    post t "/invite_room" (`Assoc [
      ("alias", `String alias);
      ("room_id", `String room_id);
      ("invitee_pk", `String invitee_pk);
    ])

  let invite_room_signed t ~alias ~room_id ~invitee_pk ~identity_pk ~ts ~nonce ~sig_ =
    post t "/invite_room" (`Assoc [
      ("alias", `String alias);
      ("room_id", `String room_id);
      ("invitee_pk", `String invitee_pk);
      ("identity_pk", `String identity_pk);
      ("ts", `String ts);
      ("nonce", `String nonce);
      ("sig", `String sig_);
    ])

  let uninvite_room t ~alias ~room_id ~invitee_pk =
    post t "/uninvite_room" (`Assoc [
      ("alias", `String alias);
      ("room_id", `String room_id);
      ("invitee_pk", `String invitee_pk);
    ])

  let uninvite_room_signed t ~alias ~room_id ~invitee_pk ~identity_pk ~ts ~nonce ~sig_ =
    post t "/uninvite_room" (`Assoc [
      ("alias", `String alias);
      ("room_id", `String room_id);
      ("invitee_pk", `String invitee_pk);
      ("identity_pk", `String identity_pk);
      ("ts", `String ts);
      ("nonce", `String nonce);
      ("sig", `String sig_);
    ])

  let knock_room t ~alias ~room_id ~requester_pk =
    post t "/knock_room" (`Assoc [
      ("alias", `String alias);
      ("room_id", `String room_id);
      ("requester_pk", `String requester_pk);
    ])

  let knock_room_signed t ~alias ~room_id ~identity_pk ~ts ~nonce ~sig_ =
    post t "/knock_room" (`Assoc [
      ("alias", `String alias);
      ("room_id", `String room_id);
      ("identity_pk", `String identity_pk);
      ("ts", `String ts);
      ("nonce", `String nonce);
      ("sig", `String sig_);
    ])

  let list_room_knocks t ~alias ~room_id =
    post t "/list_room_knocks" (`Assoc [
      ("alias", `String alias);
      ("room_id", `String room_id);
    ])

  let list_room_knocks_signed t ~alias ~room_id ~identity_pk ~ts ~nonce ~sig_ =
    post t "/list_room_knocks" (`Assoc [
      ("alias", `String alias);
      ("room_id", `String room_id);
      ("identity_pk", `String identity_pk);
      ("ts", `String ts);
      ("nonce", `String nonce);
      ("sig", `String sig_);
    ])

  let approve_room_knock t ~alias ~room_id ~requester_pk =
    post t "/approve_room_knock" (`Assoc [
      ("alias", `String alias);
      ("room_id", `String room_id);
      ("requester_pk", `String requester_pk);
    ])

  let approve_room_knock_signed t ~alias ~room_id ~requester_pk ~identity_pk ~ts ~nonce ~sig_ =
    post t "/approve_room_knock" (`Assoc [
      ("alias", `String alias);
      ("room_id", `String room_id);
      ("requester_pk", `String requester_pk);
      ("identity_pk", `String identity_pk);
      ("ts", `String ts);
      ("nonce", `String nonce);
      ("sig", `String sig_);
    ])

  let deny_room_knock t ~alias ~room_id ~requester_pk =
    post t "/deny_room_knock" (`Assoc [
      ("alias", `String alias);
      ("room_id", `String room_id);
      ("requester_pk", `String requester_pk);
    ])

  let deny_room_knock_signed t ~alias ~room_id ~requester_pk ~identity_pk ~ts ~nonce ~sig_ =
    post t "/deny_room_knock" (`Assoc [
      ("alias", `String alias);
      ("room_id", `String room_id);
      ("requester_pk", `String requester_pk);
      ("identity_pk", `String identity_pk);
      ("ts", `String ts);
      ("nonce", `String nonce);
      ("sig", `String sig_);
    ])

  (* The relay's set_room_visibility handler requires [alias] (the caller must
     be a room member) and, since B114, a body-level Ed25519 proof by default.
     Use [set_room_visibility_signed]; this unsigned form is only accepted by
     a dev-gated relay (C2C_REQUIRE_SIGNED_ROOM_OPS=0, no token) and is kept
     for tests/dev tooling. *)
  let set_room_visibility t ~alias ~room_id ~visibility =
    post t "/set_room_visibility" (`Assoc [
      ("alias", `String alias);
      ("room_id", `String room_id);
      ("visibility", `String visibility);
    ])

  let set_room_visibility_signed t ~alias ~room_id ~visibility ~identity_pk ~ts ~nonce ~sig_ =
    post t "/set_room_visibility" (`Assoc [
      ("alias", `String alias);
      ("room_id", `String room_id);
      ("visibility", `String visibility);
      ("identity_pk", `String identity_pk);
      ("ts", `String ts);
      ("nonce", `String nonce);
      ("sig", `String sig_);
    ])

  (* B117: signed set_room_history_public. The relay requires the caller be a
     room member AND a body-level Ed25519 proof whose signature covers the
     boolean. *)
  let set_room_history_public_signed t ~alias ~room_id ~history_public ~identity_pk ~ts ~nonce ~sig_ =
    post t "/set_room_history_public" (`Assoc [
      ("alias", `String alias);
      ("room_id", `String room_id);
      ("history_public", `Bool history_public);
      ("identity_pk", `String identity_pk);
      ("ts", `String ts);
      ("nonce", `String nonce);
      ("sig", `String sig_);
    ])

  let mobile_pair_prepare t ~machine_ed25519_pubkey ~token =
    post t "/mobile-pair/prepare" (`Assoc [
      ("machine_ed25519_pubkey", `String machine_ed25519_pubkey);
      ("token", `String token);
    ])

  let mobile_pair_confirm t ~token ~phone_ed25519_pubkey ~phone_x25519_pubkey =
    post t "/mobile-pair" (`Assoc [
      ("token", `String token);
      ("phone_ed25519_pubkey", `String phone_ed25519_pubkey);
      ("phone_x25519_pubkey", `String phone_x25519_pubkey);
    ])

  let mobile_pair_revoke t ~binding_id ~revoke_pk ~ts ~nonce ~sig_b64 =
    request t ~meth:`DELETE ~path:("/binding/" ^ binding_id)
      ~body:(`Assoc [
        ("revoke_pk", `String revoke_pk);
        ("ts", `String ts);
        ("nonce", `String nonce);
        ("sig", `String sig_b64);
      ]) ()

  let device_pair_init t ~machine_ed25519_pubkey =
    post t "/device-pair/init" (`Assoc [
      ("machine_ed25519_pubkey", `String machine_ed25519_pubkey);
    ])

  let device_pair_poll t ~user_code =
    request t ~meth:`GET ~path:("/device-pair/" ^ user_code) ()

  let gc t = post t "/gc" (`Assoc [])

  let dead_letter t = get t "/dead_letter"

end
