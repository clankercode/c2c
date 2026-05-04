(* c2c_post_compact_hook — PostCompact hook for Claude Code.
 *
 * Compaction is NOT a session restart: same C2C_MCP_SESSION_ID, same
 * broker registration, the cold-boot marker is already set, so the
 * cold-boot hook (c2c_cold_boot_hook) no-ops post-compact. That left a
 * gap — the agent woke up from compaction with only the conversation
 * summary + role-file injection, no structured pointer to in-flight
 * work / recent findings / fresh shared memory / personal-log state.
 *
 * #317 fixes that gap. This module is invoked by Claude Code's
 * PostCompact hook (via scripts/c2c-postcompact.sh, through the
 * c2c-post-compact-hook binary). It emits a
 * <c2c-context kind="post-compact"> block via additionalContext, with
 * priority-ordered content:
 *
 *   1. Operational reflex reminder (always present) — the things motor
 *      memory drops on compact, especially the channel-tag-reply trap
 *      filed 2026-04-26 (.collab/findings/...-channel-tag-reply-illusion.md).
 *   2. Active worktree slices owned by alias.
 *   3. Recent findings filed by self (first paragraph, not just title).
 *   4. Recent self-written memory + fresh shared_with_me.
 *   5. Most-recent personal-log entry (filename + first paragraph).
 *
 * Idempotent within a single PostCompact event: emits one block per
 * fire, no marker — Claude Code only fires PostCompact once per
 * compaction. We DO NOT use the cold-boot marker; that would conflate
 * the two lifecycle events.
 *
 * #349b: this file is the *library* form — pure-ish functions only,
 * no top-level effects. The companion `c2c_post_compact_hook_bin.ml`
 * holds the original `let () = ...` entry that resolves env vars +
 * broker registration, calls into here, and writes to stdout.
 *)

let context_budget_chars = 4096
let reminder_budget_chars = 700      (* verbatim, ceiling *)
let slices_budget_chars = 600
let findings_budget_chars = 900
let memory_budget_chars = 700
let logs_budget_chars = 700
(* sections sum to 3600; remaining ~500 is for tags + alias + ts framing. *)

let iso8601_now () = C2c_time.now_iso8601_utc ()

let truncate_to s n =
  if String.length s <= n then s
  else (String.sub s 0 (max 0 (n - 3))) ^ "..."

(* Find repo root from C2C_REPO_ROOT env var (set by wrapper script).
   Fallback: git rev-parse --git-common-dir then strip last path
   component (returns main repo root even in worktrees). Same shape as
   the cold-boot hook so behavior matches. *)
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

(* Operational reflex reminder. Verbatim — survives compact-time
   summarization that records facts but loses motor memory. The
   channel-tag-reply trap is the load-bearing example: it bit
   stanza-coder on 2026-04-26 and gets re-bit by every post-compact
   agent on first inbound DM unless something explicit reminds them. *)
let operational_reflex_reminder () =
  "- Inbound `<c2c source=\"c2c\" ...>` tags are READ-ONLY. Reply via\n\
  \  `mcp__c2c__send` (or `c2c send <alias> <body>`) — typing into your\n\
  \  transcript does NOT route to the sender.\n\
   - Run `git branch --show-current` + `git log --oneline -5` to ground\n\
  \  yourself if uncertain about working-tree state.\n\
   - Run `c2c memory list --shared-with-me` to surface inbound shared\n\
  \  memory entries from peers.\n\
   - Heartbeat ticks are work triggers, not heartbeats to ack."

(* Discover active worktree slices owned by `alias`. We scan
   `.worktrees/` for subdirs whose branch contains the alias's slice
   prefix (`slice/`, `fix/`, etc., matching the alias by name in the
   worktree path is the simplest signal). For each, report branch +
   last commit subject. *)
let active_slices ~alias ~repo =
  let worktrees_dir = Filename.concat repo ".worktrees" in
  let entries =
    try Array.to_list (Sys.readdir worktrees_dir)
    with _ -> []
  in
  let entries = List.sort String.compare entries in
  let rows =
    List.filter_map (fun name ->
      let path = Filename.concat worktrees_dir name in
      if not (try Sys.is_directory path with _ -> false) then None
      else
        let cmd =
          Printf.sprintf
            "git -C %s log -1 --pretty=format:'%%h %%s' 2>/dev/null"
            (Filename.quote path)
        in
        let ic = Unix.open_process_in cmd in
        let line = try input_line ic with _ -> "" in
        ignore (Unix.close_process_in ic);
        if line = "" then None
        else Some (Printf.sprintf "%s — %s" name (truncate_to line 90))
    ) entries
  in
  (* Sort with alias-matched rows first, so the agent's own slices
     don't get truncation-dropped when the section's 600-char budget
     overflows on a busy swarm with many concurrent worktrees. We keep
     all rows (peer slices are useful situational awareness), but the
     ordering means truncation eats peer slices first, not own. *)
  let alias_match s =
    let alen = String.length alias in
    let slen = String.length s in
    if alen = 0 then false
    else
      let rec scan i =
        if i + alen > slen then false
        else if String.sub s i alen = alias then true
        else scan (i + 1)
      in scan 0
  in
  let own, peer = List.partition alias_match rows in
  truncate_to (String.concat "\n" (own @ peer)) slices_budget_chars

(* First *content* paragraph of a markdown file: skip leading blank
   lines and pure-header lines (starting with `#`), then accumulate the
   first run of non-blank lines into a paragraph. Bounded by max_chars.
   This avoids returning just the title for files whose first paragraph
   is `# Title` followed by blank line. *)
let first_paragraph ~max_chars path =
  let is_header line =
    let t = String.trim line in
    String.length t > 0 && t.[0] = '#'
  in
  try
    let ic = open_in path in
    let buf = Buffer.create 256 in
    let in_para = ref false in
    let stopped = ref false in
    (try
       while not !stopped do
         let line = input_line ic in
         let trimmed = String.trim line in
         if trimmed = "" then begin
           if !in_para then stopped := true
         end else if (not !in_para) && is_header line then begin
           (* Skip leading header line(s); keep looking for content. *)
           ()
         end else begin
           in_para := true;
           if Buffer.length buf > 0 then Buffer.add_char buf ' ';
           Buffer.add_string buf trimmed;
           if Buffer.length buf >= max_chars then stopped := true
         end
       done
     with End_of_file -> ());
    close_in_noerr ic;
    truncate_to (Buffer.contents buf) max_chars
  with _ -> ""

(* Recent findings filed by `alias`. Same matching as cold-boot
   (filename contains `-<alias>-`), but report filename + first
   paragraph (not first 3 lines truncated to 200 chars). *)
let recent_findings ~alias ~repo ~max_findings ~per_finding_chars =
  let findings_dir = Filename.concat (Filename.concat repo ".collab") "findings" in
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
      && (let rec check i =
            if i + alias_prefix_len > len then false
            else if String.sub n i alias_prefix_len = alias_prefix then true
            else check (i + 1)
          in check 0))
      all
    |> List.sort String.compare
    |> List.rev
    |> fun l -> List.fold_left
         (fun acc n -> if List.length acc >= max_findings then acc else n :: acc)
         [] l
    |> List.rev
  in
  let rows =
    List.map (fun fname ->
      let path = Filename.concat findings_dir fname in
      let snippet = first_paragraph ~max_chars:per_finding_chars path in
      Printf.sprintf "%s\n  %s" fname snippet
    ) selected
  in
  truncate_to (String.concat "\n" rows) findings_budget_chars

(* Most-recent personal-log: filename + first-paragraph snippet.
   Sort by mtime descending so timestamped logs (`YYYY-MM-DD-...md`) and
   non-date-prefixed companions (`feedback_*.md` etc.) both order
   correctly by recency. *)
let recent_log_entry ~alias ~repo =
  let logs_dir =
    Filename.concat
      (Filename.concat (Filename.concat repo ".c2c") "personal-logs")
      alias
  in
  let entries =
    try
      Array.to_list (Sys.readdir logs_dir)
      |> List.filter (fun n ->
           String.length n > 0 && n.[0] <> '.'
           && String.length n > 4
           && String.sub n (String.length n - 3) 3 = ".md")
    with _ -> []
  in
  let with_mtime =
    List.filter_map (fun n ->
      let path = Filename.concat logs_dir n in
      try Some (n, (Unix.stat path).Unix.st_mtime)
      with _ -> None
    ) entries
  in
  let sorted =
    List.sort (fun (_, m1) (_, m2) -> compare m2 m1) with_mtime
  in
  match sorted with
  | [] -> ""
  | (fname, _) :: _ ->
    let path = Filename.concat logs_dir fname in
    let snippet = first_paragraph ~max_chars:logs_budget_chars path in
    truncate_to (Printf.sprintf "%s\n  %s" fname snippet) logs_budget_chars

(* Recent memory entries (descriptions). Reuses cold-boot's pattern
   except we report to a tighter budget. We also surface
   shared_with_me entries by walking ALL aliases' memory dirs and
   filtering on shared_with frontmatter. *)
let memory_descriptions ~alias ~repo ~max_entries =
  let memory_root =
    Filename.concat (Filename.concat repo ".c2c") "memory"
  in
  let read_desc path =
    try
      let ic = open_in path in
      let lines = ref [] in
      let count = ref 0 in
      (try
         while !count < 8 do
           lines := (input_line ic) :: !lines;
           count := !count + 1
         done
       with End_of_file -> ());
      close_in_noerr ic;
      List.fold_left (fun acc line ->
        let line = String.trim line in
        if line = "---" then acc
        else if acc <> "" then acc
        else if String.length line >= 13
             && String.sub line 0 13 = "description: "
        then String.sub line 13 (String.length line - 13)
        else acc
      ) "" (List.rev !lines)
    with _ -> ""
  in
  (* Own memory entries. *)
  let own_dir = Filename.concat memory_root alias in
  let own_entries =
    try
      Array.to_list (Sys.readdir own_dir)
      |> List.filter (fun n ->
           String.length n > 3
           && String.sub n (String.length n - 3) 3 = ".md")
      |> List.sort String.compare
      |> List.rev
      |> fun l -> List.fold_left
           (fun acc n -> if List.length acc >= max_entries then acc else n :: acc)
           [] l
      |> List.rev
    with _ -> []
  in
  let own_rows =
    List.map (fun fname ->
      let path = Filename.concat own_dir fname in
      let safe = String.sub fname 0 (String.length fname - 3) in
      let desc = read_desc path in
      if desc <> "" then Printf.sprintf "(own) %s: %s" safe desc
      else Printf.sprintf "(own) %s" safe
    ) own_entries
  in
  (* shared_with_me: walk other aliases' dirs, find files whose
     frontmatter `shared_with` includes our alias. Cheap scan, capped
     at 3 entries to avoid blowup. *)
  let other_aliases =
    try
      Array.to_list (Sys.readdir memory_root)
      |> List.filter (fun n -> n <> alias && (try Sys.is_directory (Filename.concat memory_root n) with _ -> false))
    with _ -> []
  in
  let shared_with_me =
    List.fold_left (fun acc other ->
      let other_dir = Filename.concat memory_root other in
      let files =
        try Array.to_list (Sys.readdir other_dir)
            |> List.filter (fun n ->
                 String.length n > 3
                 && String.sub n (String.length n - 3) 3 = ".md")
        with _ -> []
      in
      List.fold_left (fun acc fname ->
        if List.length acc >= 3 then acc
        else
          let path = Filename.concat other_dir fname in
          (* Cheap: read first ~12 lines, look for `shared_with` containing alias. *)
          let frontmatter =
            try
              let ic = open_in path in
              let buf = Buffer.create 256 in
              (try for _ = 1 to 12 do
                  Buffer.add_string buf (input_line ic);
                  Buffer.add_char buf '\n'
                done with End_of_file -> ());
              close_in_noerr ic;
              Buffer.contents buf
            with _ -> ""
          in
          let needle = alias in
          let nlen = String.length needle in
          (* Will be tightened to scope-by-shared_with-line below. *)
          let contains_alias_in s =
            let slen = String.length s in
            let rec scan i =
              if i + nlen > slen then false
              else if String.sub s i nlen = needle then true
              else scan (i + 1)
            in scan 0
          in
          (* Scope the alias check to the line that starts with
             `shared_with` to avoid false positives where the alias
             appears in a `description:` or other field that mentions
             us in passing. *)
          let shared_with_line =
            let lines = String.split_on_char '\n' frontmatter in
            List.find_opt (fun l ->
              let t =
                let s = l in
                let n = String.length s in
                let i = ref 0 in
                while !i < n && (s.[!i] = ' ' || s.[!i] = '\t') do
                  incr i
                done;
                if !i >= n then "" else String.sub s !i (n - !i)
              in
              String.length t >= 11 && String.sub t 0 11 = "shared_with"
            ) lines
          in
          let has_shared_with = shared_with_line <> None in
          let alias_in_share_line =
            match shared_with_line with
            | Some line -> contains_alias_in line
            | None -> false
          in
          if has_shared_with && alias_in_share_line then
            let safe = String.sub fname 0 (String.length fname - 3) in
            let desc = read_desc path in
            let row =
              if desc <> "" then
                Printf.sprintf "(from %s) %s: %s" other safe desc
              else
                Printf.sprintf "(from %s) %s" other safe
            in
            row :: acc
          else acc
      ) acc files
    ) [] other_aliases
    |> List.rev
  in
  truncate_to
    (String.concat "\n" (own_rows @ shared_with_me))
    memory_budget_chars

(* Args bundles the inputs to the pure-ish payload builder so callers
   (the binary, tests, future callers) can assemble inputs without
   sharing global env state. *)
module Args = struct
  type t = {
    alias : string;
    repo : string;
    ts : string;
  }

  let make ~alias ~repo ~ts = { alias; repo; ts }
end

(* Build the inner <c2c-context> block for the given Args. Pure-ish:
   reads the filesystem under repo, but no env / no stdout / no exit.
   Returns the same string the binary emits as additionalContext. *)
let format_context_block (args : Args.t) =
  let { Args.alias; repo; ts } = args in
  let reminder =
    truncate_to (operational_reflex_reminder ()) reminder_budget_chars
  in
  let slices = active_slices ~alias ~repo in
  let findings = recent_findings ~alias ~repo ~max_findings:5 ~per_finding_chars:300 in
  let memory = memory_descriptions ~alias ~repo ~max_entries:5 in
  let logs = recent_log_entry ~alias ~repo in
  let context_block =
    Printf.sprintf
      "<c2c-context alias=\"%s\" kind=\"post-compact\" ts=\"%s\">\n\
       <c2c-context-item kind=\"reflex\" label=\"operational-reflex-reminder\">\n%s\n</c2c-context-item>\n\
       <c2c-context-item kind=\"slices\" label=\"active-worktree-slices\">\n%s\n</c2c-context-item>\n\
       <c2c-context-item kind=\"findings\" label=\"recent-findings\">\n%s\n</c2c-context-item>\n\
       <c2c-context-item kind=\"memory\" label=\"memory-entries\">\n%s\n</c2c-context-item>\n\
       <c2c-context-item kind=\"personal-log\" label=\"most-recent-log\">\n%s\n</c2c-context-item>\n\
       </c2c-context>\n"
      alias ts reminder slices findings memory logs
  in
  truncate_to context_block context_budget_chars

(* Wrap the context block in the PostCompact hookSpecificOutput
   envelope and return the JSON string the binary writes to stdout. *)
let format_post_compact_payload (args : Args.t) =
  let context_block = format_context_block args in
  Yojson.Safe.to_string (`Assoc [
    ("hookSpecificOutput", `Assoc [
      ("hookEventName", `String "PostCompact");
      ("additionalContext", `String context_block)
    ])
  ])

let emit_context_json ~alias ~ts ~repo =
  let payload =
    format_post_compact_payload (Args.make ~alias ~repo ~ts)
  in
  print_string payload;
  print_newline ()
