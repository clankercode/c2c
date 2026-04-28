(* c2c_rooms.ml — Phase 3 extraction from c2c.ml (lines 2156–2654)
   All room command definitions and group assemblies. *)

open Cmdliner.Term.Syntax
open C2c_mcp
open C2c_utils
open C2c_types

let json_flag =
  Cmdliner.Arg.(value & flag & info [ "json"; "j" ] ~doc:"Output machine-readable JSON.")

let print_json json =
  Yojson.Safe.pretty_to_channel stdout json;
  print_newline ()

let resolve_broker_root () = C2c_utils.resolve_broker_root ()

let env_auto_alias_rooms () =
  match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
  | Some v when String.trim v <> "" -> Some (String.trim v)
  | _ -> None

let resolve_alias_with_broker ?(override : string option) broker =
  let open C2c_mcp in
  match override with
  | Some a when String.trim a <> "" -> String.trim a
  | _ ->
      match Broker.list_registrations broker |> List.find_opt (fun r -> r.session_id = Option.value (C2c_mcp.session_id_from_env ()) ~default:"") with
      | Some r -> r.alias
      | None ->
          match env_auto_alias_rooms () with
          | Some a -> a
          | None ->
              Printf.eprintf "error: cannot determine alias. Set C2C_MCP_AUTO_REGISTER_ALIAS or C2C_MCP_SESSION_ID.\n%!";
              exit 1

let resolve_session_id_for_inbox _broker =
  match C2c_mcp.session_id_from_env () with
  | Some s -> s
  | None ->
      Printf.eprintf "error: C2C_MCP_SESSION_ID is required\n%!";
      exit 1

let rooms_send_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID.")
  in
  let message =
    Cmdliner.Arg.(non_empty & pos_right 0 string [] & info [] ~docv:"MSG" ~doc:"Message body (remaining args joined with spaces).")
  in
  let from_override =
    Cmdliner.Arg.(value & opt (some string) None & info [ "from"; "F" ] ~docv:"ALIAS" ~doc:"Override sender alias. Useful for operators/tests running outside an agent session.")
  in
  let no_warn_substitution =
    Cmdliner.Arg.(value & flag & info [ "no-warn-substitution" ]
      ~doc:"Suppress the shell-substitution warning.")
  in
  let+ json = json_flag
  and+ room_id = room_id
  and+ message = message
  and+ from_override = from_override
  and+ no_warn_substitution = no_warn_substitution in
  let broker = Broker.create ~root:(resolve_broker_root ()) in
  let from_alias = resolve_alias_with_broker ?override:from_override broker in
  let content = String.concat " " message in
  (* Class E: warn when message body looks like an un-expanded shell
     substitution pattern that the shell failed to expand. *)
  let _ =
    if (not no_warn_substitution) && likes_shell_substitution content
    then Printf.eprintf
      "warning: message body appears to contain a shell substitution pattern \
       (e.g. $(...) or `...`).\n\
       If this was intended literally, re-send with --no-warn-substitution.\n\
       To avoid this, quote the pattern: '$(date)' or escape the $.\n%!"
    else ()
  in
  let output_mode = if json then Json else Human in
  (try
     let result =
       Broker.send_room broker ~from_alias ~room_id ~content
     in
     match output_mode with
     | Json ->
         print_json
           (`Assoc
             [ ( "delivered_to",
                 `List
                   (List.map (fun a -> `String a) result.sr_delivered_to) )
             ; ( "skipped",
                 `List (List.map (fun a -> `String a) result.sr_skipped) )
             ; ("ts", `Float result.sr_ts)
             ])
     | Human ->
         Printf.printf "Sent to room %s (%d delivered, %d skipped)\n"
           room_id
           (List.length result.sr_delivered_to)
           (List.length result.sr_skipped)
   with Invalid_argument msg ->
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

let rooms_join_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID.")
  in
  let history_limit =
    Cmdliner.Arg.(value & opt int 20 & info [ "history-limit" ] ~docv:"N"
      ~doc:"Recent messages to show after joining (default 20, max 200, 0 to skip).")
  in
  let alias_flag =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS"
      ~doc:"Your alias (overrides registry lookup). Required when C2C_MCP_SESSION_ID is unset.")
  in
  let+ json = json_flag
  and+ room_id = room_id
  and+ history_limit = history_limit
  and+ alias_opt = alias_flag in
  let broker = Broker.create ~root:(resolve_broker_root ()) in
  let alias = Option.value alias_opt ~default:(resolve_alias_with_broker broker) in
  let session_id = resolve_session_id_for_inbox broker in
  let output_mode = if json then Json else Human in
  (try
     let members =
       Broker.join_room broker ~room_id ~alias ~session_id
     in
     let backfill =
       if history_limit <= 0 then []
       else Broker.read_room_history broker ~room_id
              ~limit:(min history_limit 200) ()
     in
     match output_mode with
     | Json ->
         print_json
           (`Assoc
             [ ("room_id", `String room_id)
             ; ("members", `List (List.map (fun (m : room_member) ->
                   `Assoc [("alias", `String m.rm_alias); ("session_id", `String m.rm_session_id)])
                 members))
             ; ("history", `List (List.map (fun (m : room_message) ->
                   `Assoc [("ts", `Float m.rm_ts); ("from_alias", `String m.rm_from_alias);
                           ("content", `String m.rm_content)])
                 backfill))
             ])
     | Human ->
         Printf.printf "Joined room %s (%d members)\n" room_id (List.length members);
         List.iter (fun (m : room_member) -> Printf.printf "  %s\n" m.rm_alias) members;
         if backfill <> [] then begin
           Printf.printf "\nRecent history (%d msgs):\n" (List.length backfill);
           List.iter (fun (m : room_message) ->
             let t = Unix.gmtime m.rm_ts in
             Printf.printf "[%02d:%02d] <%s> %s\n"
               t.tm_hour t.tm_min m.rm_from_alias m.rm_content) backfill
         end
   with Invalid_argument msg ->
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

let rooms_leave_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID.")
  in
  let alias_flag =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS"
      ~doc:"Your alias (overrides registry lookup). Required when C2C_MCP_SESSION_ID is unset.")
  in
  let+ json = json_flag
  and+ room_id = room_id
  and+ alias_opt = alias_flag in
  let broker = Broker.create ~root:(resolve_broker_root ()) in
  let alias = Option.value alias_opt ~default:(resolve_alias_with_broker broker) in
  let output_mode = if json then Json else Human in
  (try
     let members =
       Broker.leave_room broker ~room_id ~alias
     in
     match output_mode with
     | Json ->
         print_json
           (`Assoc
             [ ("room_id", `String room_id)
             ; ( "members",
                 `List
                   (List.map
                      (fun (m : room_member) ->
                        `Assoc
                          [ ("alias", `String m.rm_alias)
                          ; ("session_id", `String m.rm_session_id)
                          ])
                      members))
             ])
     | Human ->
         Printf.printf "Left room %s (%d members remaining)\n" room_id
           (List.length members)
   with Invalid_argument msg ->
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

let rooms_delete_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID to delete (must have zero members).")
  in
  let force_flag =
    Cmdliner.Arg.(value & flag & info [ "force" ] ~doc:"Bypass legacy-room creator check (only honored when meta has no recorded creator).")
  in
  let+ json = json_flag
  and+ room_id = room_id
  and+ force = force_flag in
  let broker = Broker.create ~root:(resolve_broker_root ()) in
  let output_mode = if json then Json else Human in
  let caller_alias = resolve_alias_with_broker broker in
  (try
     Broker.delete_room broker ~room_id ~caller_alias ~force ();
     match output_mode with
     | Json ->
         print_json
           (`Assoc [ ("room_id", `String room_id); ("deleted", `Bool true) ])
     | Human ->
         Printf.printf "Deleted room %s\n" room_id
   with Invalid_argument msg ->
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

let rooms_list_cmd =
  let+ json = json_flag in
  let broker = Broker.create ~root:(resolve_broker_root ()) in
  let rooms = Broker.list_rooms broker in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`List
          (List.map
             (fun (r : Broker.room_info) ->
               let alive_members =
                 List.filter_map
                   (fun (m : Broker.room_member_info) ->
                      if m.rmi_alive <> Some false then Some (`String m.rmi_alias)
                      else None)
                   r.ri_member_details
               in
               `Assoc
                 [ ("room_id", `String r.ri_room_id)
                 ; ("member_count", `Int r.ri_member_count)
                 ; ("alive_count", `Int r.ri_alive_member_count)
                 ; ("members",
                     `List (List.map (fun a -> `String a) r.ri_members))
                 ; ("alive_members", `List alive_members)
                 ; ( "visibility",
                     `String
                       (match r.ri_visibility with
                       | Public -> "public"
                       | Invite_only -> "invite_only"))
                 ])
             rooms))
  | Human ->
      if rooms = [] then
        Printf.printf "No rooms.\n"
      else
        List.iter
          (fun (r : Broker.room_info) ->
            let vis =
              match r.ri_visibility with
              | Public -> ""
              | Invite_only -> " [invite-only]"
            in
            let alive = if r.ri_alive_member_count > 0 then
              Printf.sprintf ", %d alive" r.ri_alive_member_count
            else "" in
            Printf.printf "%s (%d members%s)%s\n" r.ri_room_id
              r.ri_member_count alive vis)
          rooms

let parse_since_str s =
  let s = String.trim s in
  let len = String.length s in
  if len = 0 then 0.0
  else
    let last = s.[len - 1] in
    let num_part = String.sub s 0 (len - 1) in
    match last with
    | 'h' -> (try Unix.gettimeofday () -. float_of_string num_part *. 3600. with _ -> 0.0)
    | 'd' -> (try Unix.gettimeofday () -. float_of_string num_part *. 86400. with _ -> 0.0)
    | 'm' when len > 1 && s.[len-2] >= '0' && s.[len-2] <= '9' ->
        (try Unix.gettimeofday () -. float_of_string num_part *. 60. with _ -> 0.0)
    | _ -> (try float_of_string s with _ ->
        try
          Scanf.sscanf s "%d-%d-%dT%d:%d:%d"
            (fun yr mo dy hr mi se ->
               let t = { Unix.tm_year = yr - 1900; tm_mon = mo - 1; tm_mday = dy;
                         tm_hour = hr; tm_min = mi; tm_sec = se;
                         tm_wday = 0; tm_yday = 0; tm_isdst = false } in
               fst (Unix.mktime t))
        with _ -> 0.0)

let rooms_history_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID.")
  in
  let limit =
    Cmdliner.Arg.(value & opt int 50 & info [ "limit"; "l" ] ~docv:"N" ~doc:"Max messages to return.")
  in
  let since =
    Cmdliner.Arg.(value & opt (some string) None & info [ "since" ] ~docv:"SINCE"
      ~doc:"Return only messages at or after this time. Accepts: Unix timestamp (float), relative (1h, 24h, 7d, 30m), or ISO 8601 (2026-04-20T18:00:00Z).")
  in
  let+ json = json_flag
  and+ room_id = room_id
  and+ limit = limit
  and+ since = since in
  let since_ts = match since with None -> 0.0 | Some s -> parse_since_str s in
  let broker = Broker.create ~root:(resolve_broker_root ()) in
  let output_mode = if json then Json else Human in
  (try
     let messages =
       Broker.read_room_history broker ~room_id ~limit ~since:since_ts ()
     in
     match output_mode with
     | Json ->
         print_json
           (`List
             (List.map
                (fun (m : room_message) ->
                  `Assoc
                    [ ("ts", `Float m.rm_ts)
                    ; ("from_alias", `String m.rm_from_alias)
                    ; ("content", `String m.rm_content)
                    ])
                messages))
     | Human ->
         if messages = [] then
           Printf.printf "(no history)\n"
         else
           List.iter
             (fun (m : room_message) ->
               let time =
                 let t = Unix.gmtime m.rm_ts in
                 Printf.sprintf "%04d-%02d-%02d %02d:%02d"
                   (1900 + t.tm_year) (1 + t.tm_mon) t.tm_mday t.tm_hour t.tm_min
               in
               Printf.printf "[%s] <%s> %s\n" time m.rm_from_alias m.rm_content)
             messages
   with Invalid_argument msg ->
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

let rooms_invite_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID.")
  in
  let invitee =
    Cmdliner.Arg.(required & pos 1 (some string) None & info [] ~docv:"ALIAS" ~doc:"Alias to invite.")
  in
  let+ json = json_flag
  and+ room_id = room_id
  and+ invitee = invitee in
  let broker = Broker.create ~root:(resolve_broker_root ()) in
  let from_alias = resolve_alias_with_broker broker in
  let output_mode = if json then Json else Human in
  (try
     Broker.send_room_invite broker ~room_id ~from_alias
       ~invitee_alias:invitee;
     match output_mode with
     | Json ->
         print_json
           (`Assoc
             [ ("ok", `Bool true)
             ; ("room_id", `String room_id)
             ; ("invitee_alias", `String invitee)
             ])
     | Human ->
         Printf.printf "Invited %s to room %s\n" invitee room_id
   with Invalid_argument msg ->
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

let rooms_members_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID.")
  in
  let+ json = json_flag
  and+ room_id = room_id in
  let broker = Broker.create ~root:(resolve_broker_root ()) in
  let output_mode = if json then Json else Human in
  (try
     let members = Broker.read_room_members broker ~room_id in
     match output_mode with
     | Json ->
         print_json
           (`List
             (List.map
                (fun (m : room_member) ->
                  `Assoc
                    [ ("alias", `String m.rm_alias)
                    ; ("session_id", `String m.rm_session_id)
                    ; ("joined_at", `Float m.C2c_mcp.joined_at)
                    ])
                members))
     | Human ->
         if members = [] then
           Printf.printf "No members in room %s.\n" room_id
         else
           List.iter
             (fun (m : room_member) ->
               if m.rm_alias = m.rm_session_id then
                 Printf.printf "  %s\n" m.rm_alias
               else
                 Printf.printf "  %s (%s)\n" m.rm_alias m.rm_session_id)
             members
   with Invalid_argument msg ->
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

let rooms_visibility_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID.")
  in
  let visibility =
    Cmdliner.Arg.(value & opt (some string) None & info [ "set"; "s" ] ~docv:"VIS" ~doc:"Visibility: public or invite_only.")
  in
  let+ json = json_flag
  and+ room_id = room_id
  and+ vis_opt = visibility in
  let broker = Broker.create ~root:(resolve_broker_root ()) in
  let from_alias = resolve_alias_with_broker broker in
  let output_mode = if json then Json else Human in
  (try
     (match vis_opt with
      | Some vis_str ->
          let vis =
            match String.lowercase_ascii vis_str with
            | "public" -> Public
            | "invite_only" | "invite-only" -> Invite_only
            | _ ->
                Printf.eprintf "error: unknown visibility '%s'. Use 'public' or 'invite_only'.\n%!" vis_str;
                exit 1
          in
          Broker.set_room_visibility broker ~room_id ~from_alias ~visibility:vis;
          (match output_mode with
           | Json -> print_json (`Assoc [ ("ok", `Bool true); ("visibility", `String vis_str) ])
           | Human -> Printf.printf "Room %s visibility set to %s\n" room_id vis_str)
      | None ->
          let meta = Broker.load_room_meta broker ~room_id in
          let vis_str =
            match meta.visibility with
            | Public -> "public"
            | Invite_only -> "invite_only"
          in
          (match output_mode with
           | Json ->
               print_json
                 (`Assoc
                   [ ("room_id", `String room_id)
                   ; ("visibility", `String vis_str)
                   ; ( "invited_members",
                       `List (List.map (fun a -> `String a) meta.invited_members))
                   ])
           | Human ->
               Printf.printf "Room %s: %s\n" room_id vis_str;
               if meta.invited_members <> [] then
                 Printf.printf "  invited: %s\n"
                   (String.concat ", " meta.invited_members)))
   with Invalid_argument msg ->
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

let rooms_tail_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID.")
  in
  let follow =
    Cmdliner.Arg.(value & flag & info [ "follow"; "f" ] ~doc:"Follow: print new messages as they arrive (like tail -f). Default: true.")
  in
  let no_follow =
    Cmdliner.Arg.(value & flag & info [ "no-follow"; "n" ] ~doc:"Print last N lines and exit (disables follow).")
  in
  let lines =
    Cmdliner.Arg.(value & opt int 20 & info [ "lines"; "l" ] ~docv:"N" ~doc:"Number of historical lines to show before following.")
  in
  let since =
    Cmdliner.Arg.(value & opt (some string) None & info [ "since" ] ~docv:"SINCE"
      ~doc:"Show only messages since this time (same format as room history --since).")
  in
  let+ room_id = room_id
  and+ follow = follow
  and+ no_follow = no_follow
  and+ lines = lines
  and+ since = since in
  let since_ts = match since with None -> 0.0 | Some s -> parse_since_str s in
  let do_follow = (not no_follow) || follow in
  let broker = Broker.create ~root:(resolve_broker_root ()) in
  let path = Broker.room_history_path broker ~room_id in
  if not (Sys.file_exists path) && not do_follow then begin
    Printf.eprintf "room %s has no history\n%!" room_id; exit 0
  end;
  let format_msg line =
    try
      let json = Yojson.Safe.from_string line in
      let open Yojson.Safe.Util in
      let ts = json |> member "ts" |> to_number in
      if ts < since_ts then ()
      else begin
        let from_alias = json |> member "from_alias" |> to_string in
        let content = json |> member "content" |> to_string in
        let t = Unix.gmtime ts in
        Printf.printf "[%02d:%02d:%02d] %s: %s\n%!" t.tm_hour t.tm_min t.tm_sec from_alias content
      end
    with _ -> ()
  in
  if Sys.file_exists path then begin
    let messages = Broker.read_room_history broker ~room_id ~limit:lines ~since:since_ts () in
    List.iter (fun (m : room_message) ->
      let t = Unix.gmtime m.rm_ts in
      Printf.printf "[%02d:%02d:%02d] %s: %s\n%!" t.tm_hour t.tm_min t.tm_sec m.rm_from_alias m.rm_content
    ) messages
  end;
  if not do_follow then ()
  else begin
    let size = ref (try (Unix.stat path).Unix.st_size with Unix.Unix_error _ -> 0) in
    while true do
      Unix.sleepf 0.5;
      let new_size = try (Unix.stat path).Unix.st_size with Unix.Unix_error _ -> 0 in
      if new_size > !size then begin
        let ic = open_in path in
        (try Unix.lseek (Unix.descr_of_in_channel ic) !size Unix.SEEK_SET |> ignore
         with _ -> ());
        (try while true do format_msg (input_line ic) done
         with End_of_file -> close_in_noerr ic);
        size := new_size
      end
    done
  end

let rooms_list = Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List all rooms.") rooms_list_cmd
let rooms_join = Cmdliner.Cmd.v (Cmdliner.Cmd.info "join" ~doc:"Join a room.") rooms_join_cmd
let rooms_leave = Cmdliner.Cmd.v (Cmdliner.Cmd.info "leave" ~doc:"Leave a room.") rooms_leave_cmd
let rooms_delete = Cmdliner.Cmd.v (Cmdliner.Cmd.info "delete" ~doc:"Delete an empty room.") rooms_delete_cmd
let rooms_send = Cmdliner.Cmd.v (Cmdliner.Cmd.info "send" ~doc:"Send a message to a room.") rooms_send_cmd
let rooms_history = Cmdliner.Cmd.v (Cmdliner.Cmd.info "history" ~doc:"Show room message history.") rooms_history_cmd
let rooms_tail = Cmdliner.Cmd.v (Cmdliner.Cmd.info "tail" ~doc:"Tail room history; follow new messages as they arrive.") rooms_tail_cmd
let rooms_invite = Cmdliner.Cmd.v (Cmdliner.Cmd.info "invite" ~doc:"Invite an alias to a room.") rooms_invite_cmd
let rooms_members = Cmdliner.Cmd.v (Cmdliner.Cmd.info "members" ~doc:"List room members.") rooms_members_cmd
let rooms_visibility = Cmdliner.Cmd.v (Cmdliner.Cmd.info "visibility" ~doc:"Get or set room visibility (public or invite_only).") rooms_visibility_cmd

let rooms_group =
  Cmdliner.Cmd.group
    ~default:rooms_list_cmd
    (Cmdliner.Cmd.info "rooms" ~doc:"Manage persistent N:N rooms.")
    [ rooms_list; rooms_join; rooms_leave; rooms_delete; rooms_send; rooms_history; rooms_tail; rooms_invite; rooms_members; rooms_visibility ]

let room_group =
  Cmdliner.Cmd.group
    ~default:rooms_list_cmd
    (Cmdliner.Cmd.info "room" ~doc:"Alias for rooms.")
    [ rooms_list; rooms_join; rooms_leave; rooms_send; rooms_history; rooms_tail; rooms_invite; rooms_members; rooms_visibility ]
