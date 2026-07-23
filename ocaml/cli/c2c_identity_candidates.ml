(* c2c_identity_candidates.ml — shared identity-resolution helpers.

   These are the small, dependency-light primitives that the CLI identity
   fail-closed surface (`c2c_cli_helpers`, #26) and the `c2c doctor hooks`
   Grok identity-drift detector (#23) BOTH rely on, so that the two surfaces
   present the SAME candidate list and read the SAME statefile identity.

   Kept in their own module (depending only on the `c2c_mcp` library and
   Yojson) so a consumer can reuse them WITHOUT dragging in the heavy CLI
   command modules that `c2c_cli_helpers` also references. *)

(* The CLI's persisted last-resort identity file, one per broker root. *)
let session_statefile_path ~broker_root =
  Filename.concat broker_root "default-session.json"

(** Full default-session.json payload (B284): callers that must refuse
    foreign-client sticky reuse need [client] / [alias], not only [session_id]. *)
type session_statefile_info =
  { session_id : string
  ; alias : string option
  ; client : string option
  }

let read_session_statefile_info ~broker_root =
  let path = session_statefile_path ~broker_root in
  if not (Sys.file_exists path) then None
  else
    match (try Some (Yojson.Safe.from_file path) with _ -> None) with
    | Some (`Assoc fields) ->
        (match List.assoc_opt "session_id" fields with
         | Some (`String sid) when String.trim sid <> "" ->
             let alias =
               match List.assoc_opt "alias" fields with
               | Some (`String a) when String.trim a <> "" ->
                   Some (String.trim a)
               | _ -> None
             in
             let client =
               match List.assoc_opt "client" fields with
               | Some (`String c) when String.trim c <> "" ->
                   Some (String.trim c)
               | _ -> None
             in
             Some { session_id = String.trim sid; alias; client }
         | _ -> None)
    | _ -> None

let read_session_statefile ~broker_root =
  match read_session_statefile_info ~broker_root with
  | Some info -> Some info.session_id
  | None -> None

(* Enumerate broker registrations as identity candidates: (alias, session_id,
   client, registered_by, liveness). Used to fail closed with an actionable
   list when identity resolution is ambiguous or absent; the doctor Grok
   detector reuses this same shape. Best-effort — [] on any broker error. *)
let candidate_registrations ~broker_root :
    (string * string * string * string * string) list =
  try
    let broker = C2c_mcp.Broker.create ~root:broker_root in
    List.map
      (fun (r : C2c_mcp.registration) ->
        let client = Option.value r.client_type ~default:"?" in
        let registered_by = Option.value r.registered_by ~default:"?" in
        let liveness =
          match C2c_mcp.Broker.registration_liveness_state r with
          | C2c_mcp.Broker.Alive -> "alive"
          | C2c_mcp.Broker.Dead -> "dead"
          | C2c_mcp.Broker.Unknown -> "unknown"
        in
        (r.alias, r.session_id, client, registered_by, liveness))
      (C2c_mcp.Broker.list_registrations broker)
  with _ -> []

let render_candidate_registration (alias, sid, client, registered_by, liveness) =
  Printf.sprintf "%s  session_id=%s  client=%s  registered_by=%s  (%s)" alias sid
    client registered_by liveness
