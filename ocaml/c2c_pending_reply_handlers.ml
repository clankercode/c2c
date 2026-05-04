(* #450 Slice 4: Pending-reply cluster hoisted out of [c2c_mcp.ml]'s
   [handle_tool_call]. Each pending-permission tool branch is now a
   top-level function here; [handle_tool_call] dispatches one-line into
   the corresponding [C2c_pending_reply_handlers.X] entrypoint.

   Mechanical move — no behavior change. The bodies are byte-for-byte
   identical to the original arms with free locals lifted into named
   parameters ([broker], [session_id_override], [arguments]). *)

open C2c_mcp_helpers
open C2c_mcp_helpers_post_broker
module Broker = C2c_broker

let open_pending_reply ~broker ~session_id_override ~arguments =
  let perm_id = string_member "perm_id" arguments in
  let kind_str = string_member "kind" arguments in
  let kind = pending_kind_of_string kind_str in
  let supervisors =
    let open Yojson.Safe.Util in
    match arguments |> member "supervisors" with
    | `List items ->
        List.filter_map
          (fun item -> match item with `String s -> Some s | _ -> None)
          items
    | _ -> []
  in
  with_session_lwt ~session_id_override broker arguments (fun ~session_id ->
  (* [#432 Slice B / Finding 4-B1] reject unregistered callers.
     Previously the handler set requester_alias="" on miss and
     wrote the entry anyway, which (a) is meaningless audit data
     and (b) creates a small attack surface where an unregistered
     caller writes pending state for empty-alias namespacing. The
     CLI surface already rejects unregistered callers; the MCP
     path now mirrors. *)
  (match List.find_opt (fun r -> r.session_id = session_id)
           (Broker.list_registrations broker) with
    | None ->
        Lwt.return (tool_err "open_pending_reply requires the calling session to be registered first (call mcp__c2c__register before opening a pending reply)")
   | Some reg ->
  let alias = reg.alias in
  let ttl_seconds =
    match Sys.getenv_opt "C2C_PERMISSION_TTL" with
    | Some v ->
        (try float_of_string v with _ -> default_permission_ttl_s)
    | None -> default_permission_ttl_s
  in
  let now = Unix.gettimeofday () in
  let pending : pending_permission =
    { perm_id; kind; requester_session_id = session_id
    ; requester_alias = alias; supervisors
    ; created_at = now; expires_at = now +. ttl_seconds
    ; fallthrough_fired_at = []; resolved_at = None; verdict = None }
  in
  (try
     Broker.open_pending_permission broker pending;
     (* [#432 Slice D] decision audit log: emit a pending_open entry
        right after the broker write succeeds. Hashed perm_id +
        session_id; plaintext alias/supervisors. Best-effort write;
        failures are swallowed inside log_pending_open. *)
     log_pending_open
       ~broker_root:(Broker.root broker)
       ~perm_id
       ~kind:(pending_kind_to_string kind)
       ~requester_session_id:session_id
       ~requester_alias:alias
       ~supervisors
       ~ttl_seconds
       ~ts:now;
     let content =
       `Assoc
         [ ("ok", `Bool true)
         ; ("perm_id", `String perm_id)
         ; ("kind", `String (pending_kind_to_string kind))
         ; ("ttl_seconds", `Float ttl_seconds)
         ; ("expires_at", `Float pending.expires_at)
         ]
       |> Yojson.Safe.to_string
     in
     Lwt.return (tool_ok content)
   with Broker.Pending_capacity_exceeded which ->
     (* [#432 Slice C] capacity-exceeded — log + reject with a
        specific error so the caller distinguishes "your bucket is
        full" from generic auth failures. *)
     let kind_str, log_msg = match which with
       | `Per_alias a ->
           Printf.sprintf "per-alias cap reached for alias %S" a,
           Printf.sprintf "[pending-cap] reject open_pending_reply: per_alias cap reached alias=%S" a
       | `Global ->
           Printf.sprintf "global pending-permissions cap reached",
           "[pending-cap] reject open_pending_reply: global cap reached"
     in
     let path = Filename.concat (Broker.root broker) "broker.log" in
     let line =
       `Assoc
         [ ("ts", `Float (Unix.gettimeofday ()))
         ; ("event", `String "pending_cap_reject")
         ; ("note", `String log_msg)
         ]
       |> Yojson.Safe.to_string
     in
     C2c_io.append_jsonl path line;
     Lwt.return (tool_err (Printf.sprintf
       "open_pending_reply rejected: %s. Wait for in-flight entries to expire (default TTL 600s) or coordinate with the holder."
       kind_str)))))

let check_pending_reply ~broker ~session_id_override ~arguments =
  let perm_id = string_member "perm_id" arguments in
  (* [#432 Slice B / Finding 4-B2] derive reply_from_alias from the
     calling session's registration, NOT from request arguments.
     Previously: any agent who knew a perm_id (UUID, but visible in
     broker.log) plus any supervisor's alias could call this and
     get back the requester's session_id (info disclosure). Now the
     broker enforces that the calling session is itself the supervisor.
     The legacy [reply_from_alias] argument is silently ignored if
     provided. The schema (with DEPRECATED marker) is now the
     migration channel. *)
  with_session_lwt ~session_id_override broker arguments (fun ~session_id ->
  let reply_from_alias =
    match List.find_opt (fun r -> r.session_id = session_id)
            (Broker.list_registrations broker) with
    | Some reg -> reg.alias
    | None -> ""
  in
  let now_ts = Unix.gettimeofday () in
  if reply_from_alias = "" then
    Lwt.return (tool_err "check_pending_reply requires the calling session to be registered first")
  else
  (match Broker.find_pending_permission broker perm_id with
  | None ->
      (* Distinguish expired vs unknown for the audit log: scan the
         unfiltered persisted list. find_pending_permission returns
         None for both expired and absent — but the audit story
         ("did this perm_id ever exist?") differs. *)
      let outcome =
        let all = Broker.load_pending_permissions broker in
        if List.exists (fun p -> p.perm_id = perm_id) all
        then "expired" else "unknown_perm"
      in
      log_pending_check
        ~broker_root:(Broker.root broker) ~perm_id ~outcome ~reply_from_alias
        ~ts:now_ts ();
      let err_msg = match outcome with
        | "expired" -> "permission ID expired"
        | _ -> "unknown permission ID"
      in
      let content =
        `Assoc
          [ ("valid", `Bool false)
          ; ("requester_session_id", `Null)
          ; ("error", `String err_msg)
          ]
        |> Yojson.Safe.to_string
      in
      Lwt.return (tool_ok content)
  | Some pending ->
      if List.mem reply_from_alias pending.supervisors then begin
        (* slice/coord-backup-fallthrough: first valid reply wins.
           Stamp resolved_at so the fallthrough scheduler stops
           firing later tiers for this entry. Idempotent — a later
           supervisor calling check_pending_reply still gets
           valid=true (we don't gate the response on resolved_at);
           only the broker-side fallthrough scheduler uses this
           flag. *)
        let _ : bool =
          Broker.mark_pending_resolved broker ~perm_id ~ts:now_ts ()
        in
        log_pending_check
          ~broker_root:(Broker.root broker) ~perm_id ~outcome:"valid"
          ~reply_from_alias
          ~kind:(pending_kind_to_string pending.kind)
          ~requester_alias:pending.requester_alias
          ~requester_session_id:pending.requester_session_id
          ~supervisors:pending.supervisors
          ~ts:now_ts ();
        let content =
          `Assoc
            [ ("valid", `Bool true)
            ; ("requester_session_id", `String pending.requester_session_id)
            ; ("error", `Null)
            ]
          |> Yojson.Safe.to_string
        in
        Lwt.return (tool_ok content)
      end else begin
        log_pending_check
          ~broker_root:(Broker.root broker)
          ~perm_id ~outcome:"invalid_non_supervisor"
          ~reply_from_alias
          ~kind:(pending_kind_to_string pending.kind)
          ~requester_alias:pending.requester_alias
          ~requester_session_id:pending.requester_session_id
          ~supervisors:pending.supervisors
          ~ts:now_ts ();
        let content =
          `Assoc
            [ ("valid", `Bool false)
            ; ("requester_session_id", `Null)
            ; ("error", `String ("reply from non-supervisor: " ^ reply_from_alias))
            ]
        |> Yojson.Safe.to_string
        in
        Lwt.return (tool_ok content)
      end))
