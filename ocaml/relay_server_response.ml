let respond_json ?(headers = []) ~status body =
  let body_str = Yojson.Safe.to_string body in
  let headers = ("Content-Type", "application/json") :: headers in
  Cohttp_lwt_unix.Server.respond_string
    ~status
    ~headers:(Cohttp.Header.of_list headers)
    ~body:body_str
    ()

let respond_ok ?(headers = []) body = respond_json ~headers ~status:`OK body
let respond_bad_request ?(headers = []) body = respond_json ~headers ~status:`Bad_request body
let respond_unauthorized ?(headers = []) body = respond_json ~headers ~status:`Unauthorized body
let respond_too_many_requests ?(headers = []) body = respond_json ~headers ~status:`Too_many_requests body
let respond_service_unavailable ?(headers = []) body = respond_json ~headers ~status:`Service_unavailable body
let respond_not_found ?(headers = []) body = respond_json ~headers ~status:`Not_found body
let respond_conflict ?(headers = []) body = respond_json ~headers ~status:`Conflict body
let respond_internal_error ?(headers = []) body = respond_json ~headers ~status:`Internal_server_error body
let respond_bad_gateway ?(headers = []) body = respond_json ~headers ~status:`Bad_gateway body
let respond_gateway_timeout ?(headers = []) body = respond_json ~headers ~status:`Gateway_timeout body

let respond_html ?(status = `OK) body =
  Cohttp_lwt_unix.Server.respond_string
    ~status
    ~headers:(Cohttp.Header.of_list [("Content-Type", "text/html; charset=utf-8")])
    ~body
    ()
