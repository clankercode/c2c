(* c2c_stats.ml — swarm statistics command implementation *)

type token_data =
  { tokens_in : int option
  ; tokens_out : int option
  ; cost_usd : float option
  ; token_source : string option
  }

type agent_stats =
  { alias : string
  ; session_id : string
  ; live : bool
  ; registered_at : float option
  ; last_activity : float option
  ; role : string option
  ; msgs_sent : int
  ; msgs_received : int
  ; compaction_count : int
  ; token_data : token_data
  }

let empty_token_data =
  { tokens_in = None; tokens_out = None; cost_usd = None; token_source = None }

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

(** Read and parse a JSON file, returning None on error. *)
let read_json_file path =
  try
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> (try close_in ic with _ -> ()))
      (fun () -> Some (Yojson.Safe.from_channel ic))
  with Sys_error _ -> None

(** Scan sl_out subdirectories for one whose input.json has a matching
    session_name (alias). This is the fallback when the c2c session_id is
    the alias name rather than the actual Claude session UUID. *)
let find_sl_out_uuid_by_alias ~alias =
  let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/home/xertrov" in
  let sl_out_dir = Filename.concat home ".claude/sl_out" in
  let dirs =
    try Array.to_list (Sys.readdir sl_out_dir) with Sys_error _ -> []
  in
  List.fold_left
    (fun result dir ->
      match result with
      | Some _ -> result
      | None ->
          let input_path = Filename.concat sl_out_dir (Filename.concat dir "input.json") in
          match read_json_file input_path with
          | None -> None
          | Some json ->
              let open Yojson.Safe.Util in
              (try
                 let name = json |> member "session_name" |> to_string in
                 if name = alias then Some dir else None
               with _ -> None))
    None
    dirs

(** Extract token data from Claude Code's sl_out session file.
    Path: ~/.claude/sl_out/<session_id>/input.json
    Tries direct UUID lookup first, then falls back to alias-based scan.
    Returns tokens_in, tokens_out, cost_usd, and source tag. *)
let get_claude_code_tokens ~session_id =
  let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/home/xertrov" in
  let try_path uuid =
    let sl_out_path = Filename.concat home (Printf.sprintf ".claude/sl_out/%s/input.json" uuid) in
    read_json_file sl_out_path
  in
  (* Try direct UUID lookup first *)
  match try_path session_id with
  | Some json ->
      let open Yojson.Safe.Util in
      (try
         let context_window = json |> member "context_window" in
         let tokens_in = context_window |> member "total_input_tokens" |> to_int_option in
         let tokens_out = context_window |> member "total_output_tokens" |> to_int_option in
         let cost = json |> member "cost" in
         let cost_usd = cost |> member "total_cost_usd" |> to_float_option in
         { tokens_in; tokens_out; cost_usd; token_source = Some "claude-code" }
       with _ -> empty_token_data)
  | None ->
      (* Fallback: scan by alias (c2c session_id is often the alias name) *)
      match find_sl_out_uuid_by_alias ~alias:session_id with
      | None -> empty_token_data
      | Some uuid ->
          (match try_path uuid with
           | Some json ->
               let open Yojson.Safe.Util in
               (try
                  let context_window = json |> member "context_window" in
                  let tokens_in = context_window |> member "total_input_tokens" |> to_int_option in
                  let tokens_out = context_window |> member "total_output_tokens" |> to_int_option in
                  let cost = json |> member "cost" in
                  let cost_usd = cost |> member "total_cost_usd" |> to_float_option in
                  { tokens_in; tokens_out; cost_usd; token_source = Some "claude-code" }
                with _ -> empty_token_data)
           | None -> empty_token_data)

(** Extract token data from Codex's SQLite database.
    Path: ~/.codex/state_5.sqlite  (threads table)
    Uses sqlite3 CLI to query. Returns total_tokens (as combined), cost N/A.
    Note: sqlite3 CLI closes the pipe on exit; we use Fun.protect with a
    unit-returning finally to satisfy OCaml 5.4's return-type inference. *)
let get_codex_tokens ~session_id =
  let codex_db =
    let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/home/xertrov" in
    Filename.concat home ".codex/state_5.sqlite"
  in
  if not (Sys.file_exists codex_db) then empty_token_data
  else
    let query = Printf.sprintf "SELECT tokens_used FROM threads WHERE id = '%s' LIMIT 1;" session_id in
    let cmd = Printf.sprintf "sqlite3 %s \"%s\"" (Filename.quote codex_db) query in
    try
      let chan = Unix.open_process_in cmd in
      Fun.protect
        ~finally:(fun () -> (try close_in chan with _ -> ()))
        (fun () ->
          let line = try input_line chan with End_of_file -> "" in
          let line = String.trim line in
          if line = "" || line = "tokens_used" then empty_token_data
          else
            match int_of_string_opt line with
            | Some tokens ->
                { tokens_in = Some tokens; tokens_out = None; cost_usd = None; token_source = Some "codex" }
            | None -> empty_token_data)
    with Sys_error _ -> empty_token_data

(** Try to get token data for a session from any available source.
    Claude Code sessions store data in ~/.claude/sl_out/<session_id>/input.json
    Codex sessions store data in ~/.codex/state_5.sqlite threads table
    OpenCode: not available, return empty.
    We try Claude Code first (most common), then Codex. *)
let get_token_data ~session_id =
  (* Try Claude Code first *)
  let data = get_claude_code_tokens ~session_id in
  if data.token_source <> None then data
  else
    (* Try Codex *)
    let data = get_codex_tokens ~session_id in
    if data.token_source <> None then data
    else empty_token_data

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

let fmt_token = function
  | None -> "N/A"
  | Some n -> string_of_int n

let fmt_cost = function
  | None -> "N/A"
  | Some c -> Printf.sprintf "$%.2f" c

let sitrep_marker_start = "<!-- c2c-stats:start -->"
let sitrep_marker_end = "<!-- c2c-stats:end -->"

let sitrep_path ~repo_root ~now =
  let t = Unix.gmtime now in
  Filename.concat repo_root
    (Printf.sprintf ".sitreps/%04d/%02d/%02d/%02d.md"
       (1900 + t.tm_year) (1 + t.tm_mon) t.tm_mday t.tm_hour)

let sitrep_stub ~now =
  let t = Unix.gmtime now in
  Printf.sprintf "# Sitrep — %04d-%02d-%02d %02d:00 UTC\n\n"
    (1900 + t.tm_year) (1 + t.tm_mon) t.tm_mday t.tm_hour

let rec mkdir_p path =
  if path = "" || path = Filename.dirname path then ()
  else if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) @@ fun () ->
  really_input_string ic (in_channel_length ic)

let write_file path content =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) @@ fun () ->
  output_string oc content

let find_sub ~needle haystack =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    if needle_len = 0 then Some 0
    else if i + needle_len > hay_len then None
    else if String.sub haystack i needle_len = needle then Some i
    else loop (i + 1)
  in
  loop 0

let replace_sitrep_stats_block ~content ~block =
  match find_sub ~needle:sitrep_marker_start content, find_sub ~needle:sitrep_marker_end content with
  | Some start_idx, Some end_idx when start_idx <= end_idx ->
      let end_idx = end_idx + String.length sitrep_marker_end in
      let prefix = String.sub content 0 start_idx in
      let suffix = String.sub content end_idx (String.length content - end_idx) in
      Ok (prefix ^ block ^ suffix)
  | None, None ->
      let sep =
        if content = "" then ""
        else if Filename.check_suffix content "\n\n" then ""
        else if Filename.check_suffix content "\n" then "\n"
        else "\n\n"
      in
      Ok (content ^ sep ^ block)
  | _ ->
      Error "existing sitrep has incomplete c2c stats markers"

let append_stats_to_sitrep ~repo_root ~now ~stats_markdown =
  let path = sitrep_path ~repo_root ~now in
  let block =
    sitrep_marker_start ^ "\n" ^ String.trim stats_markdown ^ "\n" ^ sitrep_marker_end ^ "\n"
  in
  try
    mkdir_p (Filename.dirname path);
    let content =
      if Sys.file_exists path then read_file path else sitrep_stub ~now
    in
    match replace_sitrep_stats_block ~content ~block with
    | Error _ as err -> err
    | Ok updated ->
        write_file path updated;
        Ok path
  with
  | Sys_error msg | Unix.Unix_error (_, msg, _) ->
      Error msg

let render_markdown ~stats ~since_str ~now =
  let buf = Buffer.create 4096 in
  let now_str = fmt_time now in
  let window_str =
    match since_str with
    | None -> "all time"
    | Some s -> "last " ^ s
  in
  Printf.bprintf buf "## Swarm stats — %s UTC (window: %s)\n\n" now_str window_str;
  Printf.bprintf buf "| alias | live | msgs in | msgs out | compactions | tokens in | tokens out | cost | registered | last seen | role |\n";
  Printf.bprintf buf "|---|---|---|---|---|---|---|---|---|---|---|\n";
  List.iter
    (fun s ->
      let live_str = if s.live then "\xe2\x9c\x93" else "\xe2\x80\x93" in
      let reg_str =
        match s.registered_at with
        | Some ts -> fmt_time ts
        | None -> ""
      in
      let last_seen_str =
        match s.last_activity with
        | Some ts -> fmt_time ts
        | None -> "never"
      in
      let role_str = match s.role with Some r -> r | None -> "" in
      Printf.bprintf buf "| %s | %s | %d | %d | %d | %s | %s | %s | %s | %s | %s |\n"
        s.alias live_str s.msgs_received s.msgs_sent s.compaction_count
        (fmt_token s.token_data.tokens_in)
        (fmt_token s.token_data.tokens_out)
        (fmt_cost s.token_data.cost_usd)
        reg_str last_seen_str role_str)
    stats;
  if stats = [] then
    Printf.bprintf buf "(no registrations found)\n";
  Buffer.contents buf

let render_json ~stats =
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
             ; ("last_activity_ts",
                match s.last_activity with
                | Some ts -> `Float ts
                | None -> `Null)
             ; ("role",
                match s.role with
                | Some r -> `String r
                | None -> `Null)
             ; ("msgs_sent", `Int s.msgs_sent)
             ; ("msgs_received", `Int s.msgs_received)
             ; ("compaction_count", `Int s.compaction_count)
             ; ("tokens_in",
                match s.token_data.tokens_in with
                | Some n -> `Int n
                | None -> `Null)
             ; ("tokens_out",
                match s.token_data.tokens_out with
                | Some n -> `Int n
                | None -> `Null)
             ; ("cost_usd",
                match s.token_data.cost_usd with
                | Some c -> `Float c
                | None -> `Null)
             ; ("token_source",
                match s.token_data.token_source with
                | Some src -> `String src
                | None -> `Null)
             ])
         stats)
  in
  Yojson.Safe.pretty_to_string arr ^ "\n"

let repo_root_for_sitrep () =
  match Git_helpers.git_repo_toplevel () with
  | Some root -> root
  | None -> Sys.getcwd ()

let run ~root ~json ~alias_filter ~since_str ~append_sitrep =
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
            let token_data = get_token_data ~session_id:reg.session_id in
            Some { alias = reg.alias
                 ; session_id = reg.session_id
                 ; live
                 ; registered_at = reg.registered_at
                 ; last_activity = reg.last_activity_ts
                 ; role = reg.role
                 ; msgs_sent
                 ; msgs_received
                 ; compaction_count = reg.compaction_count
                 ; token_data })
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
  let now = Unix.gettimeofday () in
  let markdown = lazy (render_markdown ~stats ~since_str ~now) in
  if json then
    print_string (render_json ~stats)
  else
    print_string (Lazy.force markdown);
  if append_sitrep then
    match append_stats_to_sitrep
            ~repo_root:(repo_root_for_sitrep ())
            ~now
            ~stats_markdown:(Lazy.force markdown) with
    | Ok path -> Printf.eprintf "appended swarm stats to %s\n%!" path
    | Error msg ->
        Printf.eprintf "error: could not append swarm stats to sitrep: %s\n%!" msg;
        exit 1

(* --- history runner: longitudinal per-day rollup --------------------------- *)

type bucket_grain = Hourly | Daily | Weekly

let parse_bucket = function
  | "hour" | "hourly" -> Some Hourly
  | "day" | "daily" -> Some Daily
  | "week" | "weekly" -> Some Weekly
  | _ -> None

let bucket_key grain ts =
  let t = Unix.gmtime ts in
  match grain with
  | Hourly ->
      Printf.sprintf "%04d-%02d-%02dT%02d"
        (1900 + t.tm_year) (1 + t.tm_mon) t.tm_mday t.tm_hour
  | Daily ->
      Printf.sprintf "%04d-%02d-%02d"
        (1900 + t.tm_year) (1 + t.tm_mon) t.tm_mday
  | Weekly ->
      (* Snap to Monday in UTC. tm_wday: 0=Sun..6=Sat. *)
      let days_since_monday = (t.tm_wday + 6) mod 7 in
      let monday_ts = ts -. (float_of_int days_since_monday *. 86400.0) in
      let mt = Unix.gmtime monday_ts in
      Printf.sprintf "%04d-%02d-%02d (week)"
        (1900 + mt.tm_year) (1 + mt.tm_mon) mt.tm_mday

(** Bucket archive messages by [grain]. Returns (bucket_key, alias, kind) -> count
    where kind is `Sent | `Recv. The session_id -> alias map is provided
    externally so we can attribute received-counts. *)
let scan_archives_by_day ~archive_dir ~session_to_alias ~cutoff ?(grain = Daily) () =
  let counts : (string * string * [ `Sent | `Recv ], int) Hashtbl.t = Hashtbl.create 256 in
  let bump key =
    let prev = try Hashtbl.find counts key with Not_found -> 0 in
    Hashtbl.replace counts key (prev + 1)
  in
  let day_of ts = bucket_key grain ts in
  let files =
    try Array.to_list (Sys.readdir archive_dir) with Sys_error _ -> []
  in
  List.iter (fun fname ->
    if not (Filename.check_suffix fname ".jsonl") then ()
    else
      let session_id = Filename.chop_suffix fname ".jsonl" in
      let recv_alias =
        try Some (Hashtbl.find session_to_alias session_id) with Not_found -> None
      in
      let path = Filename.concat archive_dir fname in
      try
        let ic = open_in path in
        Fun.protect ~finally:(fun () -> try close_in ic with _ -> ()) (fun () ->
          try
            while true do
              let line = String.trim (input_line ic) in
              if line <> "" then
                try
                  let json = Yojson.Safe.from_string line in
                  let open Yojson.Safe.Util in
                  let drained_at =
                    match json |> member "drained_at" with
                    | `Float f -> f
                    | `Int i -> float_of_int i
                    | _ -> 0.0
                  in
                  let from_alias =
                    try json |> member "from_alias" |> to_string with _ -> ""
                  in
                  let after_cutoff = match cutoff with
                    | None -> true
                    | Some c -> drained_at >= c
                  in
                  if after_cutoff && from_alias <> "" && from_alias <> "c2c-system"
                     && drained_at > 0.0 then begin
                    let day = day_of drained_at in
                    bump (day, from_alias, `Sent);
                    match recv_alias with
                    | Some ra -> bump (day, ra, `Recv)
                    | None -> ()
                  end
                with _ -> ()
            done
          with End_of_file -> ())
      with Sys_error _ -> ())
    files;
  counts

let run_history ~root ~json ~markdown ~csv ~compact ~alias_filter ~days ?(grain = Daily) ?(top = None) () =
   let broker = C2c_mcp.Broker.create ~root in
   let regs = C2c_mcp.Broker.list_registrations broker in
   let session_to_alias = Hashtbl.create 32 in
   List.iter (fun (reg : C2c_mcp.registration) ->
     Hashtbl.replace session_to_alias reg.session_id reg.alias) regs;
   let cutoff =
     if days <= 0 then None
     else Some (Unix.gettimeofday () -. (float_of_int days *. 86400.0))
   in
   let archive_dir = Filename.concat root "archive" in
   let counts = scan_archives_by_day ~archive_dir ~session_to_alias ~cutoff ~grain () in
   (* Aggregate to (day, alias) -> {sent; recv} *)
   let agg : (string * string, int * int) Hashtbl.t = Hashtbl.create 64 in
   Hashtbl.iter (fun (day, alias, kind) n ->
     let (s, r) = try Hashtbl.find agg (day, alias) with Not_found -> (0, 0) in
     let v = match kind with
       | `Sent -> (s + n, r)
       | `Recv -> (s, r + n)
     in
     Hashtbl.replace agg (day, alias) v) counts;
   (* Build sorted rows. *)
   let rows =
     Hashtbl.fold (fun (day, alias) (s, r) acc ->
       match alias_filter with
       | Some a when a <> alias -> acc
       | _ -> (day, alias, s, r) :: acc) agg []
     |> List.sort (fun (d1, a1, _, _) (d2, a2, _, _) ->
         match String.compare d1 d2 with 0 -> String.compare a1 a2 | c -> c)
   in
   (* Apply --top N filter: keep top-N aliases per bucket (by msgs_out + msgs_in). *)
   let rows = match top with
     | None -> rows
     | Some n when n <= 0 -> rows
     | Some n ->
         let by_day = Hashtbl.create 16 in
         List.iter (fun ((d, _, _, _) as row) ->
           let prev = try Hashtbl.find by_day d with Not_found -> [] in
           Hashtbl.replace by_day d (row :: prev)) rows;
         let kept =
           Hashtbl.fold (fun _ entries acc ->
             let sorted = List.sort
               (fun (_, _, s1, r1) (_, _, s2, r2) -> compare (s2 + r2) (s1 + r1))
               entries
             in
             let rec take k = function
               | [] -> []
               | _ when k = 0 -> []
               | x :: xs -> x :: take (k - 1) xs
             in
             take n sorted @ acc) by_day []
         in
         List.sort (fun (d1, a1, _, _) (d2, a2, _, _) ->
           match String.compare d1 d2 with 0 -> String.compare a1 a2 | c -> c) kept
   in
    if json then begin
      let arr = `List (List.map (fun (day, alias, sent, recv) ->
        `Assoc [ ("day", `String day); ("alias", `String alias);
                 ("msgs_out", `Int sent); ("msgs_in", `Int recv) ]) rows) in
      let json_str = if compact then Yojson.Safe.to_string arr
                     else Yojson.Safe.pretty_to_string arr in
      print_string json_str;
      print_newline ()
   end else if markdown then begin
     let by_day = Hashtbl.create 16 in
     List.iter (fun (day, alias, sent, recv) ->
       let existing = try Hashtbl.find by_day day with Not_found -> [] in
       Hashtbl.replace by_day day ((alias, sent, recv) :: existing)) rows;
     let days_sorted = Hashtbl.fold (fun d _ acc -> d :: acc) by_day [] |> List.sort String.compare in
     List.iter (fun day ->
       let entries = try Hashtbl.find by_day day with Not_found -> [] in
       let entries = List.sort (fun (a, _, _) (b, _, _) -> String.compare a b) entries in
       let day_total_out = List.fold_left (fun s (_, o, _) -> s + o) 0 entries in
       let day_total_in = List.fold_left (fun s (_, _, i) -> s + i) 0 entries in
       Printf.printf "### %s\n\n" day;
       Printf.printf "| alias | msgs out | msgs in |\n";
       Printf.printf "|-------|-----------|--------|\n";
       List.iter (fun (alias, sent, recv) ->
         Printf.printf "| %s | %d | %d |\n" alias sent recv) entries;
       Printf.printf "| **total** | **%d** | **%d** |\n\n" day_total_out day_total_in) days_sorted
   end else begin
     print_string "day,alias,msgs_out,msgs_in\n";
     List.iter (fun (day, alias, sent, recv) ->
       Printf.printf "%s,%s,%d,%d\n" day alias sent recv) rows
   end