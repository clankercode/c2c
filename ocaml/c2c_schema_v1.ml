(* C2c_schema_v1 — canonical lean v1 c2c message/event JSON schema.
   See c2c_schema_v1.mli for the full contract. Pure; yojson only. *)

let schema_version = 1

type msg_type =
  | Dm
  | Room
  | System

type delivery_state =
  | Queued
  | Queued_offline
  | Accepted
  | Delivered

type source =
  | Local
  | Relay

type from_addr =
  { alias : string
  ; host_id : string option
  ; address : string option
  }

type t =
  { schema_version : int
  ; msg_type : msg_type
  ; message_id : string option
  ; ts : float option
  ; from : from_addr
  ; to_ : string
  ; source : source option
  ; content : string
  ; in_reply_to : string option
  ; delivery_state : delivery_state option
  }

(* ---- Stable field-key contract ---- *)

let key_schema_version = "schema_version"
let key_type = "type"
let key_message_id = "message_id"
let key_ts = "ts"
let key_from = "from"
let key_from_alias = "alias"
let key_from_host_id = "host_id"
let key_from_address = "address"
let key_to = "to"
let key_source = "source"
let key_content = "content"
let key_in_reply_to = "in_reply_to"
let key_delivery = "delivery"
let key_delivery_state = "state"

let required_top_level_keys =
  [ key_schema_version; key_type; key_from; key_to; key_content ]

(* Reserved for v2 (identity attestation / trust — I003/I008). Ignored on
   parse so a v2 producer's documents pass a v1 validator unchanged. *)
let reserved_v2_from_keys = [ "identity_pk"; "verified"; "trust_tier" ]

(* Reserved top-level v2 keys (e.g. message prioritization). *)
let reserved_v2_keys = [ "priority" ]

(* ---- Enum <-> string ---- *)

let string_of_msg_type = function
  | Dm -> "dm"
  | Room -> "room"
  | System -> "system"

let msg_type_of_string = function
  | "dm" -> Some Dm
  | "room" -> Some Room
  | "system" -> Some System
  | _ -> None

let string_of_delivery_state = function
  | Queued -> "queued"
  | Queued_offline -> "queued_offline"
  | Accepted -> "accepted"
  | Delivered -> "delivered"

let delivery_state_of_string = function
  | "queued" -> Some Queued
  | "queued_offline" -> Some Queued_offline
  | "accepted" -> Some Accepted
  | "delivered" -> Some Delivered
  | _ -> None

let string_of_source = function
  | Local -> "local"
  | Relay -> "relay"

let source_of_string = function
  | "local" -> Some Local
  | "relay" -> Some Relay
  | _ -> None

(* ---- Serialize ---- *)

let serialize_from { alias; host_id; address } =
  let fields = [ (key_from_alias, `String alias) ] in
  let fields =
    match host_id with
    | Some h -> fields @ [ (key_from_host_id, `String h) ]
    | None -> fields
  in
  let fields =
    match address with
    | Some a -> fields @ [ (key_from_address, `String a) ]
    | None -> fields
  in
  `Assoc fields

let serialize (m : t) : Yojson.Safe.t =
  let fields =
    [ (key_schema_version, `Int m.schema_version)
    ; (key_type, `String (string_of_msg_type m.msg_type))
    ]
  in
  let fields =
    match m.message_id with
    | Some id -> fields @ [ (key_message_id, `String id) ]
    | None -> fields
  in
  let fields =
    match m.ts with
    | Some t -> fields @ [ (key_ts, `Float t) ]
    | None -> fields
  in
  let fields = fields @ [ (key_from, serialize_from m.from) ] in
  let fields = fields @ [ (key_to, `String m.to_) ] in
  let fields =
    match m.source with
    | Some s -> fields @ [ (key_source, `String (string_of_source s)) ]
    | None -> fields
  in
  let fields = fields @ [ (key_content, `String m.content) ] in
  let fields =
    match m.in_reply_to with
    | Some r -> fields @ [ (key_in_reply_to, `String r) ]
    | None -> fields
  in
  let fields =
    match m.delivery_state with
    | Some st ->
        fields
        @ [ ( key_delivery
            , `Assoc
                [ (key_delivery_state, `String (string_of_delivery_state st)) ] )
          ]
    | None -> fields
  in
  `Assoc fields

let to_string m = Yojson.Safe.to_string (serialize m)

let serialize_with_legacy ?(delivery_extra = []) m ~legacy =
  match serialize m with
  | `Assoc fields ->
      let fields =
        if delivery_extra = [] then fields
        else
          List.map
            (fun (k, v) ->
              if k = key_delivery then
                match v with
                | `Assoc dfields ->
                    let extra =
                      List.filter
                        (fun (dk, _) -> not (List.mem_assoc dk dfields))
                        delivery_extra
                    in
                    (k, `Assoc (dfields @ extra))
                | _ -> (k, v)
              else (k, v))
            fields
      in
      (* Dedup guarantee: skip legacy keys the v1 serialization already
         emitted, so the result never carries a duplicate JSON key. *)
      let legacy_new =
        List.filter (fun (k, _) -> not (List.mem_assoc k fields)) legacy
      in
      `Assoc (fields @ legacy_new)
  | j -> j (* unreachable: [serialize] always returns [`Assoc] *)

(* ---- Validate ---- *)

let ( let* ) = Result.bind

let assoc_opt key = function
  | `Assoc kvs -> List.assoc_opt key kvs
  | _ -> None

let require_object where json =
  match json with
  | `Assoc _ -> Ok json
  | _ -> Error (Printf.sprintf "%s: expected a JSON object" where)

let require_string ~ctx key json =
  match assoc_opt key json with
  | Some (`String s) -> Ok s
  | Some _ -> Error (Printf.sprintf "%s: field %S must be a string" ctx key)
  | None -> Error (Printf.sprintf "%s: missing required field %S" ctx key)

let optional_string ~ctx key json =
  match assoc_opt key json with
  | None -> Ok None
  | Some (`String s) -> Ok (Some s)
  | Some _ -> Error (Printf.sprintf "%s: field %S must be a string" ctx key)

let validate_from json =
  let* from_json =
    match assoc_opt key_from json with
    | Some j -> Ok j
    | None -> Error (Printf.sprintf "missing required field %S" key_from)
  in
  let* _ = require_object (Printf.sprintf "field %S" key_from) from_json in
  let* alias = require_string ~ctx:key_from key_from_alias from_json in
  let* () =
    if String.trim alias = "" then
      Error (Printf.sprintf "%s.%s must be non-empty" key_from key_from_alias)
    else Ok ()
  in
  let* host_id = optional_string ~ctx:key_from key_from_host_id from_json in
  let* address = optional_string ~ctx:key_from key_from_address from_json in
  Ok { alias; host_id; address }

let validate (json : Yojson.Safe.t) : (t, string) result =
  let* _ = require_object "document" json in
  (* schema_version: required int, must equal 1 *)
  let* sv =
    match assoc_opt key_schema_version json with
    | Some (`Int i) -> Ok i
    | Some _ ->
        Error (Printf.sprintf "field %S must be an integer" key_schema_version)
    | None ->
        Error (Printf.sprintf "missing required field %S" key_schema_version)
  in
  let* () =
    if sv = schema_version then Ok ()
    else
      Error
        (Printf.sprintf "unsupported %s %d (this validator handles v%d)"
           key_schema_version sv schema_version)
  in
  (* type: required, valid enum *)
  let* type_str = require_string ~ctx:"document" key_type json in
  let* msg_type =
    match msg_type_of_string type_str with
    | Some mt -> Ok mt
    | None -> Error (Printf.sprintf "unknown %s %S" key_type type_str)
  in
  (* from: required object with required alias *)
  let* from = validate_from json in
  (* to, content: required strings *)
  let* to_ = require_string ~ctx:"document" key_to json in
  let* content = require_string ~ctx:"document" key_content json in
  (* message_id, in_reply_to: optional strings *)
  let* message_id = optional_string ~ctx:"document" key_message_id json in
  let* in_reply_to = optional_string ~ctx:"document" key_in_reply_to json in
  (* ts: optional number (float or int) *)
  let* ts =
    match assoc_opt key_ts json with
    | None -> Ok None
    | Some (`Float f) -> Ok (Some f)
    | Some (`Int i) -> Ok (Some (float_of_int i))
    | Some _ -> Error (Printf.sprintf "field %S must be a number" key_ts)
  in
  (* source: optional, valid enum if present *)
  let* source =
    match assoc_opt key_source json with
    | None -> Ok None
    | Some (`String s) -> (
        match source_of_string s with
        | Some src -> Ok (Some src)
        | None -> Error (Printf.sprintf "unknown %s %S" key_source s))
    | Some _ -> Error (Printf.sprintf "field %S must be a string" key_source)
  in
  (* delivery.state: optional, valid enum if present *)
  let* delivery_state =
    match assoc_opt key_delivery json with
    | None -> Ok None
    | Some (`Assoc _ as dj) -> (
        match assoc_opt key_delivery_state dj with
        | None -> Ok None
        | Some (`String s) -> (
            match delivery_state_of_string s with
            | Some st -> Ok (Some st)
            | None ->
                Error
                  (Printf.sprintf "unknown %s.%s %S" key_delivery
                     key_delivery_state s))
        | Some _ ->
            Error
              (Printf.sprintf "field %S.%S must be a string" key_delivery
                 key_delivery_state))
    | Some _ -> Error (Printf.sprintf "field %S must be an object" key_delivery)
  in
  Ok
    { schema_version = sv
    ; msg_type
    ; message_id
    ; ts
    ; from
    ; to_
    ; source
    ; content
    ; in_reply_to
    ; delivery_state
    }

let of_string s =
  match Yojson.Safe.from_string s with
  | json -> validate json
  | exception (Yojson.Json_error msg) ->
      Error (Printf.sprintf "invalid JSON: %s" msg)
