(* Shared schedule-fire helpers.
   Extracted from c2c_start.ml so both the managed-session heartbeat loop
   (c2c_start) and the MCP server schedule timer (S6b) can reuse
   idle-gating and heartbeat-enqueue logic without duplicating it. *)

let agent_is_idle ~(now : float) ~(idle_threshold_s : float)
    ~(last_activity_ts : float option) : bool =
  match last_activity_ts with
  | None -> true
  (* No activity recorded => treat as idle (fire heartbeat to surface state). *)
  | Some ts -> now -. ts >= idle_threshold_s

let last_activity_ts_for_alias ~(broker_root : string) ~(alias : string)
    : float option =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  match
    C2c_mcp.Broker.list_registrations broker
    |> List.find_opt (fun (r : C2c_mcp.registration) -> r.alias = alias)
  with
  | Some reg -> reg.last_activity_ts
  | None -> None

let enqueue_heartbeat ~(broker_root : string) ~(alias : string)
    ~(content : string) : unit =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  C2c_mcp.Broker.enqueue_message broker ~from_alias:alias ~to_alias:alias
    ~content ()

let should_fire ~(broker_root : string) ~(alias : string)
    (entry : C2c_mcp.schedule_entry) : bool =
  if not entry.s_only_when_idle then true
  else
    let now = Unix.gettimeofday () in
    let last_activity_ts = last_activity_ts_for_alias ~broker_root ~alias in
    agent_is_idle ~now ~idle_threshold_s:entry.s_idle_threshold_s
      ~last_activity_ts
