let normalize_relay_alias ~alias ~opaque_host_id =
  let alias_name, alias_host_id = C2c_name.split_opaque_host_id alias in
  let opaque_host_id =
    match opaque_host_id with
    | Some _ -> opaque_host_id
    | None -> alias_host_id
  in
  (alias_name, opaque_host_id)

let alias_matches_display ~query alias =
  let display, _ = normalize_relay_alias ~alias ~opaque_host_id:None in
  display = query
