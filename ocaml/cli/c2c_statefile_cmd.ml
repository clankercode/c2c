(* c2c_statefile_cmd - statefile, debug statefile, and plugin plumbing commands. *)

open C2c_cli_helpers
open Cmdliner.Term.Syntax
open C2c_types

(* --- c2c statefile --------------------------------------------------------- *)
(* Read or tail the oc-plugin state snapshot written by stream-write-statefile.
   Path resolution order (same as the sink):
     1. --instance NAME  → ~/.local/share/c2c/instances/<NAME>/oc-plugin-state.json
     2. $C2C_INSTANCE_NAME
     3. ~/.local/share/c2c/oc-plugin-state.json (fallback) *)

let statefile_cmd =
  let open Cmdliner in
  let tail_flag =
    Arg.(value & flag & info ["tail"; "t"] ~doc:"Watch for updates; print each new snapshot as it arrives (like tail -f).")
  in
  let instance_arg =
    Arg.(value & opt (some string) None & info ["instance"; "i"] ~docv:"NAME"
           ~doc:"Instance name (same as C2C_INSTANCE_NAME). Selects the per-instance statefile.")
  in
  let json_flag =
    Arg.(value & flag & info ["json"] ~doc:"Pretty-print the JSON payload (default: compact single line).")
  in
  Term.(const (fun tail instance json_pretty () ->
    let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp" in
    let base_dir = Filename.concat home ".local/share/c2c" in
    let name =
      match instance with
      | Some n when String.trim n <> "" -> Some (String.trim n)
      | _ -> (match Sys.getenv_opt "C2C_INSTANCE_NAME" with
              | Some n when String.trim n <> "" -> Some (String.trim n)
              | _ -> None)
    in
    let statefile =
      match name with
      | Some n -> Filename.concat (Filename.concat (Filename.concat base_dir "instances") n) "oc-plugin-state.json"
      | None   -> Filename.concat base_dir "oc-plugin-state.json"
    in
    let format_json raw =
      if json_pretty then
        match (try Some (Yojson.Safe.from_string raw) with _ -> None) with
        | Some j -> Yojson.Safe.pretty_to_string j
        | None   -> raw
      else
        match (try Some (Yojson.Safe.from_string raw) with _ -> None) with
        | Some j -> Yojson.Safe.to_string j
        | None   -> raw
    in
    let print_file () =
      match (try Some (In_channel.input_all (open_in statefile)) with _ -> None) with
      | None     -> Printf.eprintf "statefile not found: %s\n%!" statefile; exit 1
      | Some raw -> print_string (format_json (String.trim raw)); print_newline ()
    in
    if not tail then
      print_file ()
    else begin
      (* Tail mode: poll the file and print on change.
         We use mtime polling (inotifywait not always available). *)
      let last_mtime = ref 0.0 in
      let last_content = ref "" in
      Printf.eprintf "Watching %s (Ctrl-C to stop)\n%!" statefile;
      while true do
        (try
          let st = Unix.stat statefile in
          let mt = st.Unix.st_mtime in
          if mt <> !last_mtime then begin
            last_mtime := mt;
            let raw =
              try String.trim (In_channel.input_all (open_in statefile))
              with _ -> ""
            in
            if raw <> "" && raw <> !last_content then begin
              last_content := raw;
              print_string (format_json raw);
              print_newline ();
              flush stdout
            end
          end
        with _ -> ());
        Unix.sleepf 0.25
      done
    end) $ tail_flag $ instance_arg $ json_flag $ Term.const ())

let statefile_top =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "statefile"
       ~doc:"Read or watch the OpenCode plugin state snapshot."
       ~man:[ `S "DESCRIPTION";
              `P "Reads the JSON state snapshot written by the c2c OpenCode plugin \
                  ($(b,.opencode/plugins/c2c.ts)) via $(b,c2c oc-plugin stream-write-statefile).";
              `P "Without $(b,--tail), prints the current snapshot and exits.";
              `P "With $(b,--tail), watches the file and prints each new snapshot as the \
                  plugin updates it (approximately every agent step).";
              `P "Use $(b,--instance NAME) or $(b,C2C_INSTANCE_NAME) to select the \
                  per-instance statefile (written by managed sessions started with \
                  $(b,c2c start opencode))."; ])
    statefile_cmd

(* --- debug: statefile debug log -------------------------------------------- *)

let debug_statefile_log_cmd =
  let open Cmdliner in
  let instance_arg =
    Arg.(value & opt (some string) None & info ["instance"; "i"] ~docv:"NAME"
           ~doc:"Instance name. Selects the per-instance debug log.")
  in
  let limit_arg =
    Arg.(value & opt int 50 & info ["limit"; "n"] ~docv:"N"
           ~doc:"Maximum number of entries to print (default: 50).")
  in
  let checkpoint_filter_arg =
    Arg.(value & opt (some string) None & info ["checkpoint"; "c"] ~docv:"NAME"
           ~doc:"Only show entries for a specific named checkpoint.")
  in
  Term.(const (fun instance limit checkpoint_filter () ->
    let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp" in
    let base_dir = Filename.concat home ".local/share/c2c" in
    let name =
      match instance with
      | Some n when String.trim n <> "" -> Some (String.trim n)
      | _ -> (match Sys.getenv_opt "C2C_INSTANCE_NAME" with
              | Some n when String.trim n <> "" -> Some (String.trim n)
              | _ -> None)
    in
    let log_path =
      match name with
      | Some n -> Filename.concat (Filename.concat base_dir "instances") n // "statefile-debug.jsonl"
      | None   -> Filename.concat base_dir "statefile-debug.jsonl"
    in
    if not (Sys.file_exists log_path) then
      (Printf.eprintf "debug log not found: %s\n%!" log_path; exit 1)
    else ();
    (try
      let ic = open_in log_path in
      let lines = ref [] in
      (try while true do lines := input_line ic :: !lines done with End_of_file -> ());
      close_in ic;
      let all_rev = !lines in
      let filtered =
        match checkpoint_filter with
        | Some cf ->
            List.filter (fun line ->
              match Yojson.Safe.from_string line with
              | `Assoc fields ->
                  (match List.assoc_opt "checkpoint" fields with
                   | Some (`String cp) -> cp = cf
                   | _ -> false)
              | _ -> false) all_rev
        | None -> all_rev
      in
      let to_print =
        let rec take n lst = match n with 0 -> [] | _ -> match lst with [] -> [] | h :: t -> h :: take (n-1) t in
        List.rev (take limit (List.rev filtered))
      in
      List.iter (fun l ->
        match Yojson.Safe.from_string l with
        | `Assoc fields ->
            let ts = match List.assoc_opt "ts" fields with Some (`String s) -> s | _ -> "?" in
            let event = match List.assoc_opt "event" fields with Some (`String e) -> e | _ -> "?" in
            let cp = match List.assoc_opt "checkpoint" fields with Some (`String c) when c <> "" -> " [" ^ c ^ "]" | _ -> "" in
            Printf.printf "%s  %s%s\n%!" ts event cp
        | _ -> print_endline l) to_print;
      (match checkpoint_filter with
       | Some checkpoint when List.length to_print = 0 ->
           Printf.eprintf "no entries found for checkpoint %S\n%!" checkpoint
       | _ -> ())
    with e -> prerr_endline (Printexc.to_string e); exit 1)
  ) $ instance_arg $ limit_arg $ checkpoint_filter_arg $ Term.const ())

let debug_statefile_checkpoint_cmd =
  let open Cmdliner in
  let instance_arg =
    Arg.(value & opt (some string) None & info ["instance"; "i"] ~docv:"NAME"
           ~doc:"Instance name. Selects the per-instance debug log.")
  in
  Term.(const (fun instance checkpoint_name () ->
    if String.trim checkpoint_name = "" then
      (Printf.eprintf "error: checkpoint name cannot be empty\n%!"; exit 1);
    let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp" in
    let base_dir = Filename.concat home ".local/share/c2c" in
    let name =
      match instance with
      | Some n when String.trim n <> "" -> Some (String.trim n)
      | _ -> (match Sys.getenv_opt "C2C_INSTANCE_NAME" with
              | Some n when String.trim n <> "" -> Some (String.trim n)
              | _ -> None)
    in
    let log_path =
      match name with
      | Some n -> Filename.concat (Filename.concat base_dir "instances") n // "statefile-debug.jsonl"
      | None   -> Filename.concat base_dir "statefile-debug.jsonl"
    in
    let now = C2c_time.iso8601_utc_ms (Unix.gettimeofday ())
    in
    let entry =
      `Assoc
        [ ("ts", `String now)
        ; ("event", `String "named.checkpoint")
        ; ("checkpoint", `String (String.trim checkpoint_name))
        ; ("state", `Null)
        ]
      |> Yojson.Safe.to_string
    in
    try
      let oc = open_out_gen [ Open_wronly; Open_creat; Open_append ] 0o644 log_path in
      output_string oc entry;
      output_char oc '\n';
      close_out oc;
      Printf.printf "checkpoint '%s' written at %s\n%!" (String.trim checkpoint_name) now
    with e -> prerr_endline (Printexc.to_string e); exit 1
  ) $ instance_arg
    $ Arg.(required & pos 0 (some string) None
         & info [] ~docv:"NAME"
             ~doc:"Checkpoint name (e.g. 'pre-compact', 'post-compact').")
    $ Term.const ())

let debug_group =
  let open Cmdliner in
  Cmd.group (Cmd.info "debug" ~doc:"Debug tools for c2c statefile and broker.")
    [ Cmd.v (Cmd.info "statefile-log" ~doc:"Print the high-resolution statefile debug log (JSONL).")
        debug_statefile_log_cmd
    ; Cmd.v (Cmd.info "statefile-checkpoint" ~doc:"Create a named checkpoint entry in the statefile debug log.")
        debug_statefile_checkpoint_cmd
    ]

(* --- subcommand group: oc-plugin ------------------------------------------ *)
(* Sink commands for the OpenCode TypeScript plugin (c2c.ts).
   The plugin pipes state snapshots via stdin; these commands persist them
   at discoverable paths so external tools (GUI observer, c2c status, etc.)
   can read current OpenCode agent state without querying the plugin directly. *)

let oc_plugin_stream_write_statefile_cmd =
  Cmdliner.Term.(const (fun () ->
    (* Statefile path:
       - $C2C_INSTANCE_NAME set  → ~/.local/share/c2c/instances/<name>/oc-plugin-state.json
       - else                    → ~/.local/share/c2c/oc-plugin-state.json          *)
    let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp" in
    let base_dir = Filename.concat home ".local/share/c2c" in
    let mkdir_p dir = C2c_mcp.mkdir_p ~mode:0o700 dir in
    let statefile =
      match Sys.getenv_opt "C2C_INSTANCE_NAME" with
      | Some name when String.trim name <> "" ->
          let inst_dir = Filename.concat (Filename.concat base_dir "instances") (String.trim name) in
          mkdir_p inst_dir;
          Filename.concat inst_dir "oc-plugin-state.json"
      | _ ->
          mkdir_p base_dir;
          Filename.concat base_dir "oc-plugin-state.json"
    in
    (* Atomic write helper *)
    let write_json j =
      let payload = Yojson.Safe.to_string j in
      let tmp = statefile ^ ".tmp" in
      (try
        let oc = open_out tmp in
        output_string oc payload;
        output_char oc '\n';
        close_out oc;
        Unix.rename tmp statefile
      with _ -> ())
    in
    (* Read existing statefile JSON (for patch merging). *)
    let read_existing () =
      try
        let ic = open_in statefile in
        let raw = In_channel.input_all ic in
        close_in ic;
        (match Yojson.Safe.from_string (String.trim raw) with
         | `Assoc _ as j -> Some j
         | _ -> None)
      with _ -> None
    in
    (* Deep-merge patch into existing state.snapshot envelope.
       Only top-level `state` fields are patched; nested merging is one level deep. *)
    let apply_patch existing_env patch_fields =
      match existing_env with
      | `Assoc env_fields ->
          let existing_state =
            match List.assoc_opt "state" env_fields with
            | Some (`Assoc sf) -> sf
            | _ -> []
          in
          (* Merge: for each field in patch, if both are Assoc, merge one level deep *)
          let merged_state = List.fold_left (fun acc (k, v) ->
            let existing_v = List.assoc_opt k acc in
            let merged_v = match existing_v, v with
              | Some (`Assoc old_fields), `Assoc new_fields ->
                  (* One level deep merge *)
                  let merged = List.fold_left (fun a (kk, vv) ->
                    (kk, vv) :: List.filter (fun (x, _) -> x <> kk) a
                  ) old_fields new_fields in
                  `Assoc merged
              | _ -> v
            in
            (k, merged_v) :: List.filter (fun (x, _) -> x <> k) acc
          ) existing_state patch_fields in
          `Assoc (List.map (fun (k, v) ->
            if k = "state" then (k, `Assoc merged_state) else (k, v)
          ) env_fields)
      | _ -> existing_env
    in
    (* Persistent loop: read one JSON line per iteration until EOF. *)
    (try
      while true do
        let line = input_line stdin in
        let trimmed = String.trim line in
        if trimmed <> "" then begin
          match (try Some (Yojson.Safe.from_string trimmed) with _ -> None) with
          | None -> () (* malformed line — silently skip *)
          | Some (`Assoc fields as j) ->
              let event_type =
                match List.assoc_opt "event" fields with
                | Some (`String s) -> s
                | _ -> ""
              in
              (match event_type with
               | "state.snapshot" -> write_json j
               | "state.patch" ->
                   let patch_fields =
                     match List.assoc_opt "patch" fields with
                     | Some (`Assoc pf) -> pf
                     | _ -> []
                   in
                   if patch_fields = [] then ()
                   else begin
                     let merged = match read_existing () with
                       | Some existing -> apply_patch existing patch_fields
                       | None -> j (* no existing state — write patch as-is *)
                     in
                     write_json merged
                   end
               | _ -> () (* unknown event type — ignore *)
              )
          | Some _ -> () (* not an object — ignore *)
        end
      done
    with End_of_file | Sys_error _ -> ())) $ Cmdliner.Term.const ())

(* Multi-key variant used by clients that multiplex several logical identities
   through one long-lived c2c child.  The routing key is deliberately a
   conservative filesystem component; it is removed before the unchanged
   state.snapshot envelope is persisted. *)
let valid_statefile_instance_key key =
  let length = String.length key in
  let valid_first = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' -> true
    | _ -> false
  in
  let valid_rest = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
    | _ -> false
  in
  length >= 1 && length <= 128
  && key <> "." && key <> ".."
  && valid_first key.[0]
  && String.for_all valid_rest key

let oc_plugin_stream_write_statefiles_cmd =
  Cmdliner.Term.(const (fun () ->
    let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp" in
    let instances_dir = Filename.concat home ".local/share/c2c/instances" in
    let write_snapshot key snapshot =
      let instance_dir = Filename.concat instances_dir key in
      C2c_mcp.mkdir_p ~mode:0o700 instance_dir;
      let statefile = Filename.concat instance_dir "oc-plugin-state.json" in
      let tmp, oc =
        Filename.open_temp_file ~temp_dir:instance_dir
          ~mode:[Open_wronly; Open_creat; Open_excl; Open_binary]
          ~perms:0o600 "oc-plugin-state.json." ".tmp"
      in
      try
        Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
          output_string oc (Yojson.Safe.to_string snapshot);
          output_char oc '\n');
        Unix.rename tmp statefile
      with _ ->
        close_out_noerr oc;
        (try Sys.remove tmp with _ -> ())
    in
    let process_line line =
      let trimmed = String.trim line in
      if trimmed <> "" then
        match (try Some (Yojson.Safe.from_string trimmed) with _ -> None) with
        | Some (`Assoc fields) ->
            (match List.assoc_opt "instance_key" fields,
                   List.assoc_opt "event" fields,
                   List.assoc_opt "ts" fields,
                   List.assoc_opt "state" fields with
             | Some (`String key), Some (`String "state.snapshot"),
               Some (`String ts), Some (`Assoc _)
                 when valid_statefile_instance_key key && String.trim ts <> "" ->
                 let snapshot =
                   `Assoc (List.filter (fun (name, _) -> name <> "instance_key") fields)
                 in
                 write_snapshot key snapshot
             | _ -> ())
        | _ -> ()
    in
    try while true do process_line (input_line stdin) done
    with End_of_file | Sys_error _ -> ()) $ Cmdliner.Term.const ())

let oc_plugin_message_json (msg : C2c_mcp.message) =
  `Assoc
    [ ("from_alias", `String msg.from_alias)
    ; ("to_alias", `String msg.to_alias)
    ; ("content", `String msg.content)
    ]

let oc_plugin_drain_inbox_to_spool_cmd =
  let open Cmdliner in
  let spool_path_arg =
    Arg.(required & opt (some string) None & info [ "spool-path" ] ~docv:"PATH"
      ~doc:"Path to the durable OpenCode plugin spool JSON file.")
  in
  let broker_root_arg =
    Arg.(value & opt (some string) None & info [ "broker-root" ] ~docv:"DIR"
      ~doc:"Broker root override. Defaults to C2C_MCP_BROKER_ROOT or repo-local broker root.")
  in
  let session_id_arg =
    Arg.(value & opt (some string) None & info [ "session-id" ] ~docv:"ID"
      ~doc:"Session ID override. Defaults to C2C_MCP_SESSION_ID / alias-resolved inbox session.")
  in
  let+ spool_path = spool_path_arg
  and+ broker_root_opt = broker_root_arg
  and+ session_id_opt = session_id_arg
  and+ json = json_flag in
  let output_mode = if json then Json else Human in
  let broker_root =
    match broker_root_opt with
    | Some root when String.trim root <> "" -> String.trim root
    | _ -> resolve_broker_root ()
  in
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let session_id =
    match session_id_opt with
    | Some sid when String.trim sid <> "" -> String.trim sid
    | _ -> resolve_session_id_for_inbox broker
  in
  let spool = C2c_wire_bridge.spool_of_path spool_path in
  let inbox_path = broker_root // (session_id ^ ".inbox.json") in
  let handle_error msg =
    Printf.eprintf "error: %s\n%!" msg;
    (match output_mode with
     | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])
     | Human -> ());
    exit 1
  in
  try
    let pending =
      let queued = C2c_wire_bridge.spool_read spool in
      C2c_mcp.Broker.with_inbox_lock broker ~session_id (fun () ->
        let fresh = C2c_mcp.Broker.read_inbox broker ~session_id in
        match fresh with
        | [] -> queued
        | _ ->
            let combined = queued @ fresh in
            C2c_wire_bridge.spool_write spool combined;
            C2c_mcp.Broker.append_archive ~drained_by:"oc_plugin" broker ~session_id ~messages:fresh;
            C2c_setup.json_write_file inbox_path (`List []);
            combined)
    in
    match output_mode with
    | Json ->
        print_json (`Assoc
          [ ("ok", `Bool true)
          ; ("session_id", `String session_id)
          ; ("spool_path", `String spool_path)
          ; ("count", `Int (List.length pending))
          ; ("messages", `List (List.map oc_plugin_message_json pending))
          ])
    | Human ->
        Printf.printf "staged %d OpenCode message(s) into %s\n"
          (List.length pending) spool_path
  with exn ->
    handle_error (Printexc.to_string exn)

let oc_plugin_group =
  Cmdliner.Cmd.group
     (Cmdliner.Cmd.info "oc-plugin"
        ~doc:"OpenCode plugin sink commands (called by the OpenCode c2c plugin).")
    [ Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "stream-write-statefile"
           ~doc:"Read a JSON state snapshot from stdin and write it atomically \
                 to the instance statefile. Path: \
                 ~/.local/share/c2c/instances/NAME/oc-plugin-state.json when \
                 C2C_INSTANCE_NAME is set, else ~/.local/share/c2c/oc-plugin-state.json.")
        oc_plugin_stream_write_statefile_cmd
    ; Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "stream-write-statefiles"
           ~doc:"Read identity-keyed JSON state snapshots from stdin and fan them out atomically to unchanged per-instance statefiles. Each line is a complete state.snapshot object with a safe top-level instance_key.")
        oc_plugin_stream_write_statefiles_cmd
    ; Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "drain-inbox-to-spool"
           ~doc:"Drain broker inbox messages into the OpenCode spool file before delivery.")
        oc_plugin_drain_inbox_to_spool_cmd
    ]

(* --- subcommand group: cc-plugin ------------------------------------------ *)
(* Claude Code plugin sink commands. The PostToolUse inbox hook writes
   statefile state automatically; this group exposes the write path for
   future hooks or scripts that need to emit explicit state (e.g. idle signal). *)

let cc_plugin_write_statefile_cmd =
  Cmdliner.Term.(const (fun () ->
    (* Same path logic as oc-plugin: prefer $C2C_INSTANCE_NAME, else base dir. *)
    let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp" in
    let base_dir = Filename.concat home ".local/share/c2c" in
    let mkdir_p dir = C2c_mcp.mkdir_p ~mode:0o700 dir in
    let statefile =
      match Sys.getenv_opt "C2C_INSTANCE_NAME" with
      | Some name when String.trim name <> "" ->
          let inst_dir = Filename.concat (Filename.concat base_dir "instances") (String.trim name) in
          mkdir_p inst_dir;
          Filename.concat inst_dir "oc-plugin-state.json"
      | _ ->
          mkdir_p base_dir;
          Filename.concat base_dir "oc-plugin-state.json"
    in
    let line = try input_line stdin with End_of_file -> "" in
    if String.trim line = "" then ()
    else begin
      let json = try Some (Yojson.Safe.from_string line) with _ -> None in
      match json with
      | None -> ()
      | Some j ->
          let payload = Yojson.Safe.to_string j in
          let tmp = statefile ^ ".tmp" in
          (try
            let oc = open_out tmp in
            output_string oc payload;
            output_char oc '\n';
            close_out oc;
            Unix.rename tmp statefile
          with _ -> ())
    end) $ Cmdliner.Term.const ())

let cc_plugin_group =
  Cmdliner.Cmd.group
     (Cmdliner.Cmd.info "cc-plugin"
        ~doc:"Claude Code plugin sink commands (called by the PostToolUse hook, \
              PreCompact/PostCompact hooks, and any Claude Code statefile emitters).")
    [ Cmdliner.Cmd.v
         (Cmdliner.Cmd.info "write-statefile"
            ~doc:"Write a JSON state snapshot received on stdin atomically \
                  to the instance statefile (same path as oc-plugin). Called by \
                  hooks or scripts that need to emit explicit Claude Code state.")
        cc_plugin_write_statefile_cmd ]
