(* relay_nudge.ml — idle-nudge delivery system
   Sends periodic friendly prompts to idle sessions via the broker's inbox.
   Runs as a background Lwt thread started from the MCP server main loop. *)

open C2c_mcp

let src_log = Logs.Src.create "relay_nudge" ~doc:"idle nudge scheduler"
module Log = (val Logs.src_log : Logs.LOG)

(* Default cadence knobs *)
let default_cadence_minutes = 30.0
let default_idle_minutes = 25.0
let nudge_sender_alias = "c2c-nudge"

type nudge_message = { text : string }

let load_messages ~broker_root =
  let path = Filename.concat broker_root "nudge" // "messages.json" in
  if not (Sys.file_exists path) then []
  else
    try
      let json = Yojson.Safe.from_file path in
      let open Yojson.Safe.Util in
      match json |> member "messages" with
      | `List items ->
          List.filter_map
            (function
             | `Assoc _ as msg ->
                 (match msg |> member "text" with
                  | `String t when String.trim t <> "" -> Some { text = String.trim t }
                  | _ -> None)
             | _ -> None)
            items
      | _ -> []
    with e ->
      Log.warn (fun f -> f "relay_nudge: failed to load messages from %s: %s" path (Printexc.to_string e));
      []

let random_message messages =
  match messages with
  | [] -> None
  | [m] -> Some m
  | msgs ->
      let idx = Random.int (List.length msgs) in
      Some (List.nth msgs idx)

(* [is_dnd_active session] returns true if DND is currently active for the session. *)
let is_dnd_active (reg : registration) =
  match reg.dnd with
  | false -> false
  | true ->
      match reg.dnd_until with
      | None -> true  (* manual DND, no expiry *)
      | Some until_ts ->
          let now = Unix.gettimeofday () in
          now < until_ts  (* expired if now >= until_ts *)

(* [idle_minutes_ago reg] returns how many minutes have passed since
   the session's last_activity_ts. None if no activity recorded. *)
let idle_minutes_ago (reg : registration) =
  match reg.last_activity_ts with
  | None -> None  (* session predates last_activity_ts field *)
  | Some ts ->
      let elapsed = Unix.gettimeofday () -. ts in
      if elapsed < 0.0 then None else Some (elapsed /. 60.0)

let nudge_session ~broker ~reg ~message =
  (* Send nudge to the session's inbox via the broker's enqueue *)
  let open Lwt in
  try
    Broker.enqueue_message broker
      ~from_alias:nudge_sender_alias
      ~to_alias:reg.alias
      ~content:message.text
      ~deferrable:true
      ();
    Log.info (fun f -> f "relay_nudge: sent to %s" reg.alias);
    true
  with e ->
    Log.warn (fun f -> f "relay_nudge: failed to nudge %s: %s" reg.alias (Printexc.to_string e));
    false

let nudge_tick ~broker ~cadence_minutes ~idle_minutes ~messages =
  let now = Unix.gettimeofday () in
  let idle_threshold_s = idle_minutes *. 60.0 in
  let regs = Broker.list_registrations broker in
  List.iter
    (fun (reg : registration) ->
      (* Skip non-alive sessions *)
      if not (Broker.registration_is_alive reg) then ()
      (* Skip DND sessions *)
      else if is_dnd_active reg then ()
      (* Check idle time *)
      else
        match reg.last_activity_ts with
        | None -> ()  (* no activity data yet *)
        | Some ts ->
            let idle_s = now -. ts in
            if idle_s >= idle_threshold_s then
              match random_message messages with
              | None -> ()
              | Some msg ->
                  ignore (nudge_session ~broker ~reg ~message:msg)
            else ())
    regs

let start_nudge_scheduler ~broker_root ~broker
    ?(cadence_minutes = default_cadence_minutes)
    ?(idle_minutes = default_idle_minutes)
    () =
  if idle_minutes >= cadence_minutes then
    invalid_arg
      (Printf.sprintf "relay_nudge: idle_minutes (%.0f) must be less than cadence_minutes (%.0f)"
         idle_minutes cadence_minutes);
  Log.info (fun f -> f "relay_nudge: starting (cadence=%.0fmin, idle=%.0fmin)"
              cadence_minutes idle_minutes);
  let messages = load_messages ~broker_root in
  if messages = [] then
    Log.warn (fun f -> f "relay_nudge: no messages loaded from %s/nudge/messages.json"
                 broker_root);
  let rec loop () =
    let open Lwt in
    Lwt_platform.sleep (cadence_minutes *. 60.0)
    >>= fun () ->
    nudge_tick ~broker ~cadence_minutes ~idle_minutes ~messages;
    loop ()
  in
  Lwt.async (fun () -> loop ())
