(* #native-scheduling S4: MCP handlers for schedule_set / schedule_list /
   schedule_rm. Follows the same alias-resolution + file-I/O pattern as
   [C2c_memory_handlers]. *)

open C2c_mcp_helpers
open C2c_mcp_helpers_post_broker
module Broker = C2c_broker

(* --- TOML rendering (duplicated from CLI c2c_schedule.ml to keep the
   handler self-contained; the format is trivial key=value pairs) ------- *)

let escape_toml_string s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c ->
    match c with
    | '\\' -> Buffer.add_string buf "\\\\"
    | '"'  -> Buffer.add_string buf "\\\""
    | c    -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

let render_schedule ~name ~interval_s ~align ~message ~only_when_idle
    ~idle_threshold_s ~enabled ~created_at ~updated_at () =
  let buf = Buffer.create 256 in
  Buffer.add_string buf "[schedule]\n";
  Buffer.add_string buf (Printf.sprintf "name = \"%s\"\n" (escape_toml_string name));
  Buffer.add_string buf (Printf.sprintf "interval_s = %.6g\n" interval_s);
  Buffer.add_string buf (Printf.sprintf "align = \"%s\"\n" (escape_toml_string align));
  Buffer.add_string buf (Printf.sprintf "message = \"%s\"\n" (escape_toml_string message));
  Buffer.add_string buf (Printf.sprintf "only_when_idle = %b\n" only_when_idle);
  Buffer.add_string buf (Printf.sprintf "idle_threshold_s = %.6g\n" idle_threshold_s);
  Buffer.add_string buf (Printf.sprintf "enabled = %b\n" enabled);
  Buffer.add_string buf (Printf.sprintf "created_at = \"%s\"\n" (escape_toml_string created_at));
  Buffer.add_string buf (Printf.sprintf "updated_at = \"%s\"\n" (escape_toml_string updated_at));
  Buffer.contents buf

(* --- helpers ------------------------------------------------------------- *)

let default_message = "Session heartbeat \xe2\x80\x94 pick up the next slice"

let float_member name json =
  match json |> Yojson.Safe.Util.member name with
  | `Float f -> Some f
  | `Int i -> Some (float_of_int i)
  | _ -> None

let bool_member = Json_util.bool_member

let list_toml_files dir =
  try
    Array.to_list (Sys.readdir dir)
    |> List.filter (fun n ->
        String.length n > 5
        && String.sub n (String.length n - 5) 5 = ".toml")
    |> List.sort String.compare
  with Sys_error _ -> []

(* --- schedule_set -------------------------------------------------------- *)

let handle_schedule_set ~(broker : Broker.t) ~session_id_override ~arguments =
  let name = optional_string_member "name" arguments in
  let interval_s_opt = float_member "interval_s" arguments in
  match name, interval_s_opt with
  | None, _ | Some "", _ ->
      Lwt.return (tool_err "missing required argument: name")
  | _, None ->
      Lwt.return (tool_err "missing required argument: interval_s")
  | Some name, Some interval_s ->
  match alias_for_current_session_or_argument ?session_id_override broker arguments with
  | None -> Lwt.return (missing_member_alias_result "schedule_set")
  | Some alias ->
      let message =
        match optional_string_member "message" arguments with
        | Some m -> m
        | None -> default_message
      in
      let align =
        match optional_string_member "align" arguments with
        | Some a -> a
        | None -> ""
      in
      let only_when_idle =
        match bool_member "only_when_idle" arguments with
        | Some b -> b
        | None -> true
      in
      let idle_threshold_s =
        match float_member "idle_threshold_s" arguments with
        | Some f -> f
        | None -> interval_s
      in
      let enabled =
        match bool_member "enabled" arguments with
        | Some b -> b
        | None -> true
      in
      let dir = schedule_base_dir alias in
      mkdir_p dir;
      let path = schedule_entry_path alias name in
      let now_ts = C2c_time.now_iso8601_utc () in
      (* Preserve created_at from existing file if present *)
      let created_at =
        if Sys.file_exists path then
          let existing = parse_schedule (C2c_io.read_file_opt path) in
          if existing.s_created_at <> "" then existing.s_created_at else now_ts
        else now_ts
      in
      let content = render_schedule ~name ~interval_s ~align ~message
          ~only_when_idle ~idle_threshold_s ~enabled ~created_at
          ~updated_at:now_ts ()
      in
      (try
        let oc = open_out path in
        Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
          output_string oc content);
        let result = `Assoc [
            ("saved", `String name)
          ; ("alias", `String alias)
          ; ("interval_s", `Float interval_s)
          ; ("enabled", `Bool enabled)
        ] |> Yojson.Safe.to_string in
        Lwt.return (tool_ok result)
      with exn ->
        Lwt.return (tool_err ("error writing schedule: " ^ Printexc.to_string exn)))

(* --- schedule_list ------------------------------------------------------- *)

let handle_schedule_list ~(broker : Broker.t) ~session_id_override ~arguments =
  match alias_for_current_session_or_argument ?session_id_override broker arguments with
  | None -> Lwt.return (missing_member_alias_result "schedule_list")
  | Some alias ->
      let dir = schedule_base_dir alias in
      let files = list_toml_files dir in
      let items = List.map (fun fname ->
        let path = Filename.concat dir fname in
        let e = parse_schedule (C2c_io.read_file_opt path) in
        `Assoc [
          ("file", `String fname)
        ; ("name", `String e.s_name)
        ; ("interval_s", `Float e.s_interval_s)
        ; ("align", `String e.s_align)
        ; ("message", `String e.s_message)
        ; ("only_when_idle", `Bool e.s_only_when_idle)
        ; ("idle_threshold_s", `Float e.s_idle_threshold_s)
        ; ("enabled", `Bool e.s_enabled)
        ; ("created_at", `String e.s_created_at)
        ; ("updated_at", `String e.s_updated_at)
        ])
        files
      in
      Lwt.return (tool_ok (`List items |> Yojson.Safe.to_string))

(* --- schedule_rm --------------------------------------------------------- *)

let handle_schedule_rm ~(broker : Broker.t) ~session_id_override ~arguments =
  let name = optional_string_member "name" arguments in
  match name with
  | None | Some "" ->
      Lwt.return (tool_err "missing required argument: name")
  | Some name ->
  match alias_for_current_session_or_argument ?session_id_override broker arguments with
  | None -> Lwt.return (missing_member_alias_result "schedule_rm")
  | Some alias ->
      let path = schedule_entry_path alias name in
      if not (Sys.file_exists path) then
        Lwt.return (tool_err ("schedule not found: " ^ name))
      else begin
        (try Sys.remove path with _ -> ());
        let result = `Assoc [
          ("deleted", `String name)
        ] |> Yojson.Safe.to_string in
        Lwt.return (tool_ok result)
      end
