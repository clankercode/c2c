(* c2c_cold_boot_hook — PostToolUse hook for cold-boot context injection
 *
 * Fires once per session: checks for marker at <broker_root>/.cold_boot_done/<session_id>,
 * emits <c2c-context> block if absent, then creates marker.
 *
 * Env vars:
 *   C2C_MCP_SESSION_ID   — broker session id
 *   C2C_MCP_BROKER_ROOT  — absolute path to broker root dir
 *)

let iso8601_now () = C2c_time.now_iso8601_utc ()

let mkdir_p = C2c_mcp.mkdir_p ~mode:0o700

let cold_boot_marker_path broker_root session_id =
  Filename.concat (Filename.concat broker_root ".cold_boot_done") session_id

(* Find repo root from C2C_REPO_ROOT env var (set by wrapper script).
   Fallback: git rev-parse --git-common-dir then strip last path component
   (returns main repo root even in worktrees). *)
let repo_root () =
  match Sys.getenv_opt "C2C_REPO_ROOT" with
  | Some dir when Sys.is_directory dir -> Some dir
  | _ ->
    let ic = Unix.open_process_in "git rev-parse --git-common-dir 2>/dev/null" in
    try
      let line = input_line ic in
      ignore (Unix.close_process_in ic);
      let parent = Filename.dirname line in
      if Sys.is_directory parent then Some parent else None
    with _ ->
      ignore (Unix.close_process_in ic);
      None

let rec dotfile_entries dir prefix =
  try
    Array.to_list (Sys.readdir dir)
    |> List.filter (fun n -> String.length n >= String.length prefix + 1 && String.sub n 0 (String.length prefix) = prefix)
    |> List.sort String.compare
    |> List.rev
  with _ -> []

let recent_findings ~alias ~maxFindings ~maxChars =
  let base = match repo_root () with
    | Some root -> Filename.concat root ".collab"
    | None -> ".collab"
  in
  let findings_dir = Filename.concat base "findings" in
  let all =
    try Array.to_list (Sys.readdir findings_dir)
    with _ -> []
  in
  let alias_prefix = Printf.sprintf "-%s-" alias in
  let alias_prefix_len = String.length alias_prefix in
  let selected =
    List.filter (fun n ->
      let len = String.length n in
      String.length n > 4
      && String.sub n (len - 3) 3 = ".md"
      && (let rec check i = if i + alias_prefix_len > len then false else if String.sub n i alias_prefix_len = alias_prefix then true else check (i + 1) in check 0))
      all
    |> List.sort String.compare
    |> List.rev
    |> fun l -> List.fold_left (fun acc n -> if List.length acc >= maxFindings then acc else n :: acc) [] l
    |> List.rev
  in
  List.fold_left (fun acc fname ->
    let path = Filename.concat findings_dir fname in
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

let personal_logs_entries ~alias ~maxEntries =
  let base =
    let repo =
      match repo_root () with
      | Some root -> root
      | None -> ""
    in
    if repo <> "" then Filename.concat repo ".c2c" else ".c2c"
  in
  let logs_dir = Filename.concat (Filename.concat base "personal-logs") alias in
  let entries =
    try
      Array.to_list (Sys.readdir logs_dir)
      |> List.filter (fun n -> String.length n > 0 && n.[0] <> '.')
      |> List.filter (fun n -> String.length n > 4 && String.sub n (String.length n - 3) 3 = ".md")
      |> List.sort String.compare
      |> List.rev
      |> fun l -> List.fold_left (fun acc n -> if List.length acc >= maxEntries then acc else n :: acc) [] l
    with _ -> []
  in
  String.concat "\n" entries

let memory_entry_descriptions ~alias ~maxEntries =
  let repo =
    match repo_root () with
    | Some root -> root
    | None -> ""
  in
  if repo = "" then ""
  else
    let mem_dir = Filename.concat (Filename.concat (Filename.concat repo ".c2c") "memory") alias in
    let entries =
      try
        Array.to_list (Sys.readdir mem_dir)
        |> List.filter (fun n -> String.length n > 3 && String.sub n (String.length n - 3) 3 = ".md")
        |> List.sort String.compare
        |> List.rev
        |> fun l -> List.fold_left (fun acc n -> if List.length acc >= maxEntries then acc else n :: acc) [] l
        |> List.rev
      with _ -> []
    in
    List.fold_left (fun acc fname ->
      let path = Filename.concat mem_dir fname in
      let entry =
        try
          let ic = open_in path in
          let lines = ref [] in
          let count = ref 0 in
          (try
             while !count < 5 do
               let line = input_line ic in
               lines := line :: !lines;
               count := !count + 1
             done
           with End_of_file -> ());
           close_in_noerr ic;
           (* Description is the first non-empty, non---- frontmatter line after name.
              We process in reverse then reverse the result so list.fold_left can
              build up acc while we traverse — this gives us "first occurrence wins"
              without needing mutable state. fragile: relies on description appearing
              after name in the frontmatter block. *)
           let desc =
             List.fold_left (fun acc line ->
              let line = String.trim line in
              if line = "---" then acc
              else if acc <> "" then acc
               else if String.length line >= 13 && String.sub line 0 13 = "description: " then
                 String.sub line 13 (String.length line - 13)
               else if String.length line >= 6 && String.sub line 0 6 = "name: " then
                 "[no description]"
              else acc
            ) "" (List.rev !lines)
          in
          let safe_name = String.sub fname 0 (String.length fname - 3) in
          if desc <> "" then safe_name ^ ": " ^ desc else ""
        with _ -> ""
      in
      if entry <> "" && acc <> "" then acc ^ "\n" ^ entry
      else if entry <> "" then entry
      else acc
    ) "" entries

let emit_context_json ~alias ~ts =
  let logs = personal_logs_entries ~alias ~maxEntries:10 in
  let findings = recent_findings ~alias ~maxFindings:5 ~maxChars:200 in
  let memory = memory_entry_descriptions ~alias ~maxEntries:5 in
  let context_block =
    Printf.sprintf "<c2c-context alias=\"%s\" kind=\"cold-boot\" ts=\"%s\">\n\
<c2c-context-item kind=\"personal-logs\" label=\"recent-logs\">\n%s\n</c2c-context-item>\n\
<c2c-context-item kind=\"findings\" label=\"recent-findings\">\n%s\n</c2c-context-item>\n\
<c2c-context-item kind=\"memory\" label=\"memory-entries\">\n%s\n</c2c-context-item>\n\
</c2c-context>\n"
      alias ts logs findings memory
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
  (* Fast path: if not configured, exit silently *)
  if session_id = "" || broker_root = "" then exit 0;

  (* Resolve alias from registry using session_id *)
  let alias =
    try
      let broker = C2c_mcp.Broker.create ~root:broker_root in
      match C2c_mcp.Broker.list_registrations broker
            |> List.find_opt (fun r -> r.C2c_mcp.session_id = session_id) with
      | Some reg -> reg.C2c_mcp.alias
      | None -> ""
    with _ -> ""
  in
  if alias = "" then exit 0;

  let ts = iso8601_now () in
  let marker_path = cold_boot_marker_path broker_root session_id in

  (* Check if already bootstrapped this session *)
  if Sys.file_exists marker_path then exit 0;

  (* Ensure .cold_boot_done directory exists *)
  let marker_dir = Filename.dirname marker_path in
  (try mkdir_p marker_dir with _ -> ());

  (* Emit context to stdout (hookSpecificOutput injection) *)
  (try emit_context_json ~alias ~ts with e ->
    prerr_endline ("emit_context: " ^ Printexc.to_string e));

  (* Create marker to prevent re-emit on subsequent tool calls *)
  (try
     let oc = open_out marker_path in
     output_string oc (ts ^ "\n");
     close_out oc
   with e ->
     prerr_endline ("marker write: " ^ Printexc.to_string e));

  exit 0
