(* Shared WebSocket transport for Codex app-server endpoints. *)

exception Ws_refused
exception Ws_closed
exception Ws_unauthorized
exception Ws_http of int

val ws_connect :
  C2c_codex_app_server.endpoint ->
  token:string ->
  timeout:float ->
  Unix.file_descr

val rpc_call :
  Unix.file_descr ->
  meth:string ->
  params:Yojson.Safe.t ->
  Yojson.Safe.t
