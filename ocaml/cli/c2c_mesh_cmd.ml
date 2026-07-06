(* c2c_mesh_cmd - relay mesh inspection commands.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open Cmdliner.Term.Syntax
open C2c_cli_helpers

let mesh_status_cmd : unit Cmdliner.Term.t =
  let open Cmdliner in
  let relay_url_flag =
    Arg.(value & opt (some string) None & info ["relay-url"] ~docv:"URL"
           ~doc:"Relay HTTP URL. Defaults to C2C_RELAY_URL env var.")
  in
  let include_dead =
    Arg.(value & flag & info ["include-dead"; "a"]
           ~doc:"Include reserved offline aliases in the peer list.")
  in
  let json_flag =
    Arg.(value & flag & info ["json"]
           ~doc:"Output raw JSON instead of a human-readable table.")
  in
  let+ relay_url = relay_url_flag
  and+ include_dead = include_dead
  and+ as_json = json_flag in
  match C2c_relay_cmd.resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "%s%!" C2c_relay_cmd.relay_url_required_error;
      exit 1
  | Some url ->
      let client = Relay.Relay_client.make url in
      (* Fetch peers - signed if identity exists and --include-dead not set. *)
      let alias_source = match env_auto_alias () with
        | Some a -> Relay_client_hints.Explicit a
        | None -> Relay_client_hints.Anon_fallback
      in
      let signing_alias = match alias_source with
        | Relay_client_hints.Explicit a -> a
        | Relay_client_hints.Anon_fallback -> "anon"
      in
      let peers_result = (
        match Relay_identity.load (), include_dead with
        | Ok id, false ->
            let auth = Relay_signed_ops.sign_request id ~alias:signing_alias
              ~meth:"GET" ~path:"/list" ~body_str:"" () in
            Lwt_main.run (Relay.Relay_client.list_peers_signed client ~auth_header:auth ())
        | _ ->
            Lwt_main.run (Relay.Relay_client.list_peers client ~include_dead ())
      ) in
      (* Surface a fix-it hint (stderr) when /list was rejected for a missing
         alias→identity binding — the table below would otherwise just render
         zero peers with no explanation. *)
      (match Relay_client_hints.hint_for_response ~alias_source peers_result with
       | Some hint -> Printf.eprintf "%s%!" hint
       | None -> ());
      (* Fetch rooms. *)
      let rooms_result = Lwt_main.run (Relay.Relay_client.list_rooms client) in
      if as_json then begin
        let now_ts = Unix.gettimeofday () in
        let format_time t =
          let tm = Unix.gmtime t in
          Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
            (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
            tm.tm_hour tm.tm_min tm.tm_sec
        in
        (* Relay token status: signed when identity exists and include_dead not requested. *)
        let relay_token_status = match Relay_identity.load (), include_dead with
          | Ok _, false -> "signed"
          | Ok _, true -> "unsigned" (* signed auth excluded dead peers *)
          | Error _, _ -> "unsigned"
        in
        let peers_raw = (match peers_result with
          | `Assoc fields ->
              (match List.assoc_opt "peers" fields with
               | Some (`List ps) -> ps
               | _ -> [])
          | _ -> []) in
        let alive_peers = List.filter (fun p ->
          match p with `Assoc fs ->
            (match List.assoc_opt "alive" fs with Some (`Bool a) -> a | _ -> false)
          | _ -> false) peers_raw in
        let dead_peers = List.filter (fun p ->
          match p with `Assoc fs ->
            (match List.assoc_opt "alive" fs with Some (`Bool a) -> not a | _ -> false)
          | _ -> false) peers_raw in
        let peers_json = `List (List.map (fun p ->
          match p with `Assoc fs ->
            let alive = match List.assoc_opt "alive" fs with Some (`Bool a) -> a | _ -> false in
            let last_seen = match List.assoc_opt "last_seen" fs with Some (`Float t) -> t | _ -> 0.0 in
            let ttl = match List.assoc_opt "ttl" fs with Some (`Float t) -> t | _ -> 0.0 in
            let ttl_remaining = if alive then max 0.0 (last_seen +. ttl -. now_ts) else 0.0 in
            let extra = [
              ("last_seen_iso8601", `String (format_time last_seen));
              ("ttl_remaining_seconds", `Float ttl_remaining);
            ] in
            `Assoc (fs @ extra)
          | _ -> p) peers_raw) in
        let rooms_raw = (match rooms_result with
          | `Assoc fields ->
              (match List.assoc_opt "rooms" fields with
               | Some (`List rs) -> rs
               | _ -> [])
          | _ -> []) in
        let rooms_json = `List (List.map (fun r ->
          match r with `Assoc fs ->
            let member_count = match List.assoc_opt "member_count" fs with
              | Some (`Int n) -> `Int n
              | _ -> `Int 0
            in
            `Assoc (fs @ [("member_count_int", member_count)])
          | _ -> r) rooms_raw) in
        let kv = [
          ("ok", `Bool true);
          ("relay_url", `String url);
          ("relay_token_status", `String relay_token_status);
          ("queried_at_iso8601", `String (format_time now_ts));
          ("peers_count", `Int (List.length peers_raw));
          ("alive_count", `Int (List.length alive_peers));
          ("dead_count", `Int (List.length dead_peers));
          ("peers", peers_json);
          ("rooms_count", `Int (List.length rooms_raw));
          ("rooms", rooms_json);
        ] in
        print_endline (Yojson.Safe.to_string (`Assoc kv));
        exit 0
      end;
      (* Human-readable output. *)
      let peers = (match peers_result with
        | `Assoc fields ->
            (match List.assoc_opt "peers" fields with
             | Some (`List ps) -> ps
             | _ -> [])
        | _ -> []) in
      let alive_peers = List.filter (fun p ->
        match p with `Assoc fs ->
          (match List.assoc_opt "alive" fs with Some (`Bool a) -> a | _ -> false)
        | _ -> false) peers in
      let dead_peers = List.filter (fun p ->
        match p with `Assoc fs ->
          (match List.assoc_opt "alive" fs with Some (`Bool a) -> not a | _ -> false)
        | _ -> false) peers in
      let format_time t =
        let tm = Unix.gmtime t in
        Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
          (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
          tm.tm_hour tm.tm_min tm.tm_sec
      in
      let print_peer p =
        match p with
        | `Assoc fs ->
            let alias = match List.assoc_opt "alias" fs with Some (`String s) -> s | _ -> "?" in
            let session_id = match List.assoc_opt "session_id" fs with
              | Some (`String s) -> if String.length s >= 12 then String.sub s 0 12 else s
              | _ -> "?" in
            let client_type = match List.assoc_opt "client_type" fs with Some (`String s) -> s | _ -> "?" in
            let last_seen = match List.assoc_opt "last_seen" fs with Some (`Float t) -> format_time t | _ -> "?" in
            let ttl = match List.assoc_opt "ttl" fs with Some (`Float t) -> Printf.sprintf "%.0fs" t | _ -> "?" in
            let alive = match List.assoc_opt "alive" fs with Some (`Bool a) -> a | _ -> false in
            Printf.printf "  %-18s %-14s %-10s %-22s %-6s  %s\n"
              alias session_id client_type last_seen ttl (if alive then "ALIVE" else "DEAD")
        | _ -> ()
      in
      let rooms = (match rooms_result with
        | `Assoc fields ->
            (match List.assoc_opt "rooms" fields with
             | Some (`List rs) -> rs
             | _ -> [])
        | _ -> []) in
      let total_rooms = List.length rooms in
      Printf.printf "c2c mesh status — relay=%s\n\n" url;
      let dead_count = List.length dead_peers in
      let dead_suffix = if dead_count > 0 then Printf.sprintf ", %d reserved offline" dead_count else "" in
      let hint_suffix =
        if dead_count > 0 && not include_dead then "; use --include-dead to show reserved offline aliases"
        else if dead_count = 0 && include_dead then "; (no reserved offline aliases)"
        else ""
      in
      Printf.printf "Peers (%d alive%s%s):\n"
        (List.length alive_peers) dead_suffix hint_suffix;
      if not include_dead && dead_peers <> [] then
        Printf.printf "  (omitting %d reserved offline aliases; use --include-dead to show)\n"
          (List.length dead_peers);
      Printf.printf "  %-18s %-14s %-10s %-22s %-6s  %s\n"
        "ALIAS" "SESSION_ID" "TYPE" "LAST_SEEN" "TTL" "STATUS";
      Printf.printf "  %s\n"
        (String.make 82 '-');
      List.iter print_peer (if include_dead then peers else alive_peers);
      Printf.printf "\nRooms on relay (%d):\n" total_rooms;
      if rooms = [] then
        Printf.printf "  (none)\n"
      else
        List.iter (fun r ->
          match r with
          | `Assoc fs ->
              let room_id = match List.assoc_opt "room_id" fs with Some (`String s) -> s | _ -> "?" in
              let member_count = match List.assoc_opt "member_count" fs with Some (`Int n) -> n | _ -> 0 in
              Printf.printf "  %-24s  (%d members)\n" room_id member_count
          | _ -> ()) rooms;
      exit 0

let mesh_status = Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "status"
       ~doc:"Show peer topology of a remote relay in human-readable format.")
    mesh_status_cmd

let mesh_group =
  Cmdliner.Cmd.group
    ~default:mesh_status_cmd
    (Cmdliner.Cmd.info "mesh"
       ~doc:"Inspect the peer mesh connected to a remote relay."
       ~man:[ `S "DESCRIPTION"
            ; `P "Reports who is connected to a relay and which rooms exist."
            ; `P "Use $(b,c2c mesh status --relay-url URL) to see peers and rooms on a relay."
            ; `P "This is a read-only diagnostic command — it does not modify any state."
            ])
    [ mesh_status ]
