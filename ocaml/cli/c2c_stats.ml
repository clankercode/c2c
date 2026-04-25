(* c2c_stats.ml — swarm statistics command implementation *)

type agent_stats =
  { alias : string
  ; session_id : string
  ; live : bool
  ; registered_at : float option
  ; role : string option
  ; msgs_sent : int
  ; msgs_received : int
  }

(** Parse a duration string like "1h", "30m", "7d", "24h" into seconds.
    Returns None on failure. *)
let parse_duration s =
  let s = String.trim s in
  let n = String.length s in
  if n < 2 then None
  else
    let suffix = String.get s (n - 1) in
    let num_str = String.sub s 0 (n - 1) in
    match int_of_string_opt num_str with
    | None -> None
    | Some v ->
        (match suffix with
         | 'm' -> Some (float_of_int (v * 60))
         | 'h' -> Some (float_of_int (v * 3600))
         | 'd' -> Some (float_of_int (v * 86400))
         | _ -> None)

(** Scan all archive files and count sent/received messages.
    sent_counts:      from_alias -> count
    received_counts:  session_id -> count  (file-based session_id)
*)
let scan_archives ~archive_dir ~cutoff =
  let sent : (string, int) Hashtbl.t = Hashtbl.create 32 in
  let received : (string, int) Hashtbl.t = Hashtbl.create 32 in
  let files =
    try Array.to_list (Sys.readdir archive_dir) with Sys_error _ -> []
  in
  List.iter
    (fun fname ->
      (* Only process .jsonl files, skip .lock and others *)
      if not (Filename.check_suffix fname ".jsonl") then ()
      else
        let session_id = Filename.chop_suffix fname ".jsonl" in
        let path = Filename.concat archive_dir fname in
        (try
           let ic = open_in path in
           Fun.protect
             ~finally:(fun () -> (try close_in ic with _ -> ()))
             (fun () ->
               (try
                  while true do
                    let line = input_line ic in
                    let line = String.trim line in
                    if line <> "" then
                      (try
                         let json = Yojson.Safe.from_string line in
                         let open Yojson.Safe.Util in
                         let drained_at =
                           match json |> member "drained_at" with
                           | `Float f -> f
                           | `Int i -> float_of_int i
                           | _ -> 0.0
                         in
                         let from_alias =
                           (try json |> member "from_alias" |> to_string
                            with _ -> "")
                         in
                         (* Apply time filter *)
                         if cutoff = None || drained_at >= (match cutoff with Some c -> c | None -> 0.0) then begin
                           (* Skip system events *)
                           if from_alias <> "c2c-system" && from_alias <> "" then begin
                             (* Count sent by from_alias *)
                             let prev = try Hashtbl.find sent from_alias with Not_found -> 0 in
                             Hashtbl.replace sent from_alias (prev + 1);
                             (* Count received by the archive file's session_id *)
                             let prev2 = try Hashtbl.find received session_id with Not_found -> 0 in
                             Hashtbl.replace received session_id (prev2 + 1)
                           end
                         end
                       with _ -> ())
                  done
                with End_of_file -> ()))
         with Sys_error _ -> ()))
    files;
  (sent, received)

let fmt_time ts =
  let t = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d"
    (1900 + t.tm_year) (1 + t.tm_mon) t.tm_mday t.tm_hour t.tm_min

let run ~root ~json ~alias_filter ~since_str =
  let broker = C2c_mcp.Broker.create ~root in
  let cutoff =
    match since_str with
    | None -> None
    | Some s ->
        (match parse_duration s with
         | Some secs -> Some (Unix.gettimeofday () -. secs)
         | None ->
             Printf.eprintf "warning: could not parse --since %S; ignoring\n%!" s;
             None)
  in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let archive_dir = Filename.concat root "archive" in
  let sent_counts, recv_counts = scan_archives ~archive_dir ~cutoff in
  (* Build per-agent stats *)
  let stats =
    List.filter_map
      (fun (reg : C2c_mcp.registration) ->
        match alias_filter with
        | Some a when a <> reg.alias -> None
        | _ ->
            let live =
              match C2c_mcp.Broker.registration_liveness_state reg with
              | C2c_mcp.Broker.Alive -> true
              | C2c_mcp.Broker.Unknown -> true   (* treat unknown as live *)
              | C2c_mcp.Broker.Dead -> false
            in
            let msgs_sent =
              try Hashtbl.find sent_counts reg.alias with Not_found -> 0
            in
            let msgs_received =
              try Hashtbl.find recv_counts reg.session_id with Not_found -> 0
            in
            Some { alias = reg.alias
                 ; session_id = reg.session_id
                 ; live
                 ; registered_at = reg.registered_at
                 ; role = reg.role
                 ; msgs_sent
                 ; msgs_received })
      regs
  in
  (* Sort: live first, then by alias *)
  let stats =
    List.sort
      (fun a b ->
        match (a.live, b.live) with
        | (true, false) -> -1
        | (false, true) -> 1
        | _ -> String.compare a.alias b.alias)
      stats
  in
  if json then begin
    let arr =
      `List
        (List.map
           (fun s ->
             `Assoc
               [ ("alias", `String s.alias)
               ; ("session_id", `String s.session_id)
               ; ("live", `Bool s.live)
               ; ("registered_at",
                  match s.registered_at with
                  | Some ts -> `Float ts
                  | None -> `Null)
               ; ("role",
                  match s.role with
                  | Some r -> `String r
                  | None -> `Null)
               ; ("msgs_sent", `Int s.msgs_sent)
               ; ("msgs_received", `Int s.msgs_received)
               ])
           stats)
    in
    print_string (Yojson.Safe.pretty_to_string arr);
    print_newline ()
  end else begin
    let now = Unix.gettimeofday () in
    let now_str = fmt_time now in
    let window_str =
      match since_str with
      | None -> "all time"
      | Some s -> "last " ^ s
    in
    Printf.printf "## Swarm stats — %s UTC (window: %s)\n\n" now_str window_str;
    Printf.printf "| alias | live | msgs in | msgs out | registered | role |\n";
    Printf.printf "|---|---|---|---|---|---|\n";
    List.iter
      (fun s ->
        let live_str = if s.live then "\xe2\x9c\x93" else "\xe2\x80\x93" in
        let reg_str =
          match s.registered_at with
          | Some ts -> fmt_time ts
          | None -> ""
        in
        let role_str = match s.role with Some r -> r | None -> "" in
        Printf.printf "| %s | %s | %d | %d | %s | %s |\n"
          s.alias live_str s.msgs_received s.msgs_sent reg_str role_str)
      stats;
    if stats = [] then
      Printf.printf "(no registrations found)\n"
  end
