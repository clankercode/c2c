(* c2c_cold_boot_hook — PostToolUse hook for cold-boot context injection
 *
 * Fires once per session: checks for marker at <broker_root>/.cold_boot_done/<session_id>,
 * emits <c2c-context> block if absent, then creates marker.
 *
 * Env vars:
 *   C2C_MCP_SESSION_ID   — broker session id
 *   C2C_MCP_BROKER_ROOT  — absolute path to broker root dir
 *   C2C_MCP_ALIAS        — alias for this session (used for findings lookup)
 *)

let iso8601_now () =
  let t = Unix.gettimeofday () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

let mkdir_p dir =
  let parts = String.split_on_char '/' dir in
  ignore (List.fold_left (fun acc part ->
    if part = "" then acc
    else
      let p = if acc = "" then "/" ^ part else acc ^ "/" ^ part in
      (try Unix.mkdir p 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      p
  ) "" parts)

let rec rm_rf path =
  if Sys.is_directory path then (
    let entries = Sys.readdir path in
    Array.iter (fun e -> rm_rf (path ^ "/" ^ e)) entries;
    Unix.rmdir path)
  else Sys.remove path

let cold_boot_marker_path broker_root session_id =
  Filename.concat (Filename.concat broker_root ".cold_boot_done") session_id

let rec dotfile_entries dir prefix =
  try
    Array.to_list (Sys.readdir dir)
    |> List.filter (fun n -> String.length n >= String.length prefix + 1 && String.sub n 0 (String.length prefix) = prefix)
    |> List.sort String.compare
    |> List.rev
  with _ -> []

let recent_findings ~alias ~maxFindings ~maxChars =
  let base = Filename.concat ".collab" "findings" in
  let prefix = Printf.sprintf "0000-00-00T00-00-00Z-%s-" alias in
  let all = dotfile_entries base prefix in
  let selected = List.filter (fun n -> String.length n > 4 && String.sub n (String.length n - 3) 3 = ".md") all
               |> List.fold_left (fun acc n -> if List.length acc >= maxFindings then acc else n :: acc) []
               |> List.rev in
  List.fold_left (fun acc fname ->
    let path = Filename.concat base fname in
    let entry =
      try
        let ic = open_in path in
        let first = ref "" in
        let count = ref 0 in
        (try
           while !count < 3 do
             let line = input_line ic in
             first := !first ^ line ^ " ";
             count := !count + 1
           done
         with End_of_file -> ());
        close_in_noerr ic;
        let s = String.trim !first in
        let s = if String.length s > maxChars then String.sub s 0 maxChars ^ "..." else s in
        fname ^ ": " ^ s
      with _ -> fname ^ ": (error reading)"
    in
    if acc = "" then entry else acc ^ "\n" ^ entry
  ) "" selected

let rec personal_logs_entries ~alias ~maxEntries =
  let base = Filename.concat ".c2c" "personal-logs" in
  let dir = Filename.concat base alias in
  let entries =
    try
      Array.to_list (Sys.readdir dir)
      |> List.filter (fun n -> String.length n > 0 && n.[0] <> '.')
      |> List.sort String.compare
      |> List.rev
      |> List.filter (fun n -> String.length n > 4 && String.sub n (String.length n - 3) 3 = ".md")
      |> List.filter (fun n -> try Sys.is_directory (Filename.concat dir n) with _ -> false)
      |> List.filter (fun n -> true)
      |> fun l -> List.fold_left (fun acc n -> if List.length acc >= maxEntries then acc else n :: acc) [] l
    with _ -> []
  in
  String.concat "\n" entries

let emit_context_json ~alias ~session_id ~broker_root ~ts =
  let logs = personal_logs_entries ~alias ~maxEntries:10 in
  let findings = recent_findings ~alias ~maxFindings:5 ~maxChars:200 in
  let context_block =
    Printf.sprintf "<c2c-context alias=\"%s\" kind=\"cold-boot\" ts=\"%s\">\n\
<c2c-context-item kind=\"personal-logs\" label=\"recent-logs\">\n%s\n</c2c-context-item>\n\
<c2c-context-item kind=\"findings\" label=\"recent-findings\">\n%s\n</c2c-context-item>\n\
</c2c-context>\n"
      alias ts logs findings
  in
  let json = Yojson.Safe.to_string (`Assoc [
    ("hookSpecificOutput", `Assoc [
      ("hookEventName", `String "PostToolUse");
      ("additionalContext", `String context_block)
    ])
  ])
  in
  print_string json;
  print_newline ()

let () =
  let session_id =
    try Sys.getenv "C2C_MCP_SESSION_ID" with Not_found -> ""
  in
  let broker_root =
    try Sys.getenv "C2C_MCP_BROKER_ROOT" with Not_found -> ""
  in
  let alias =
    try Sys.getenv "C2C_MCP_ALIAS" with Not_found -> ""
  in
  (* Fast path: if not configured, exit silently *)
  if session_id = "" || broker_root = "" || alias = "" then exit 0;

  let ts = iso8601_now () in
  let marker_path = cold_boot_marker_path broker_root session_id in

  (* Check if already bootstrapped this session *)
  if Sys.file_exists marker_path then exit 0;

  (* Ensure .cold_boot_done directory exists *)
  let marker_dir = Filename.dirname marker_path in
  (try mkdir_p marker_dir with _ -> ());

  (* Emit context to stdout (hookSpecificOutput injection) *)
  (try emit_context_json ~alias ~session_id ~broker_root ~ts with e ->
    prerr_endline ("emit_context: " ^ Printexc.to_string e));

  (* Create marker to prevent re-emit on subsequent tool calls *)
  (try
     let oc = open_out marker_path in
     output_string oc (ts ^ "\n");
     close_out oc
   with e ->
     prerr_endline ("marker write: " ^ Printexc.to_string e));

  exit 0
