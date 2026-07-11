open Lwt.Infix
open Relay_common
open Relay_registration_lease

module Res = Result

let json_ok ?(ok=true) ?(error_code=None) ?(error_msg=None) fields =
  let base = ("ok", `Bool ok) :: fields in
  let base =
    match error_code with Some ec -> ("error_code", `String ec) :: base | None -> base
  in
  let base =
    match error_msg with Some em -> ("error", `String em) :: base | None -> base
  in
  `Assoc base

let json_error ?(ok=false) error_code error_msg fields =
  `Assoc (("ok", `Bool ok) :: ("error_code", `String error_code) ::
          ("error", `String error_msg) :: fields)

let json_error_str error_code msg =
  json_error error_code msg []

let json_of_result = function
  | `Ok v -> json_ok [ ("result", v) ]
  | `Duplicate ts -> json_ok [ ("result", `String "duplicate"); ("ts", `Float ts) ]
  | `Error (code, msg) -> json_error code msg []

let json_of_register_result ?(receipt = `Null) (status, lease) =
  if status = "ok" then
    let fields = [ ("result", `String status); ("lease", RegistrationLease.to_json lease) ] in
    let fields = if receipt = `Null then fields else fields @ [("receipt", receipt)] in
    json_ok fields
  else
    json_error status (Printf.sprintf "alias conflict with existing lease")
      [ ("existing_lease", RegistrationLease.to_json lease) ]

let json_of_heartbeat_result (status, lease) =
  if status = "ok" then
    json_ok [ ("result", `String status); ("lease", RegistrationLease.to_json lease) ]
  else
    json_error status "unknown node" [ ("lease", RegistrationLease.to_json lease) ]

let json_of_send_result = function
  | `Ok ts -> json_ok [ ("result", `String "ok"); ("ts", `Float ts) ]
  | `Duplicate ts -> json_ok [ ("result", `String "duplicate"); ("ts", `Float ts) ]
  | `Error (code, msg) -> json_error code msg []

let json_of_send_all_result (ts, delivered, skipped) =
  json_ok [
    ("result", `String "ok");
    ("ts", `Float ts);
    ("delivered", `List (List.map (fun a -> `String a) delivered));
    ("skipped", `List (List.map (fun a -> `String a) skipped));
  ]

let json_of_send_room_result (ts, delivered, skipped) =
  json_ok [
    ("result", `String "ok");
    ("ts", `Float ts);
    ("delivered", `List (List.map (fun a -> `String a) delivered));
    ("skipped", `List (List.map (fun a -> `String a) skipped));
  ]

let json_of_room_join_result = function
  | `Ok -> json_ok [ ("result", `String "ok") ]
  | `Error (code, msg) -> json_error code msg []

let json_of_room_knock k =
  `Assoc [
    ("requester_alias", `String k.requester_alias);
    ("requester_pk", `String k.requester_pk);
    ("requested_at", `Float k.requested_at);
  ]

let json_of_gc_result (expired, pruned) =
  json_ok [
    ("expired", `List (List.map (fun a -> `String a) expired));
    ("pruned", `Int pruned);
  ]

let read_json_body body =
  Cohttp_lwt.Body.to_string body >|= fun body_str ->
  try Res.Ok (Yojson.Safe.from_string body_str)
  with Yojson.Json_error msg -> Res.Error msg

let require_field json field =
  match Yojson.Safe.Util.member field json with
  | `Null -> Res.Error (Printf.sprintf "missing required field: %s" field)
  | v -> Res.Ok (Yojson.Safe.to_string v)

let opt_field json field convert =
  match Yojson.Safe.Util.member field json with
  | `Null -> Res.Ok None
  | v ->
    try Res.Ok (Some (convert v))
    with Failure msg -> Res.Error (Printf.sprintf "invalid %s: %s" field msg)

let get_string json field =
  match Yojson.Safe.Util.member field json with
  | `String s -> s
  | _ -> ""

let get_opt_string json field =
  match Yojson.Safe.Util.member field json with
  | `String s -> Some s
  | _ -> None

let get_opt_bool json field =
  match Yojson.Safe.Util.member field json with
  | `Bool b -> Some b
  | _ -> None

let get_int json field default =
  (match Yojson.Safe.Util.member field json with
   | `Int n -> Some n
   | `Float f -> Some (int_of_float f)
   | _ -> None)
   |> Option.value ~default

let get_float json field default =
  (match Yojson.Safe.Util.member field json with
   | `Float f -> Some f
   | `Int n -> Some (float_of_int n)
   | _ -> None)
  |> Option.value ~default
