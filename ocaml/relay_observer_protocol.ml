(* S6: Parse observer WebSocket messages *)

let parse_observer_ws_msg (raw : string) : [`Reconnect of float * string option | `Ping | `Unknown] =
  try
    let json = Yojson.Safe.from_string raw in
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "type" fields with
       | Some (`String "reconnect") ->
         (match List.assoc_opt "since_ts" fields with
          | Some (`Float ts) ->
            let sig_b64 = List.assoc_opt "sig" fields |> Option.map (function `String s -> s | _ -> "") in
            `Reconnect (ts, sig_b64)
          | Some (`Int i) ->
            let sig_b64 = List.assoc_opt "sig" fields |> Option.map (function `String s -> s | _ -> "") in
            `Reconnect (float_of_int i, sig_b64)
          | _ -> `Unknown)
       | Some (`String "ping") -> `Ping
       | _ -> `Unknown)
    | _ -> `Unknown
  with Yojson.Json_error _ -> `Unknown
