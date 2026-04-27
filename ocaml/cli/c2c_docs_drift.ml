(* c2c_docs_drift.ml — `c2c doctor docs-drift` implementation.

   Audits CLAUDE.md (and optionally other docs) for stale claims:
   - repo paths in code spans that no longer exist
   - `c2c <subcommand>` references for commands not registered at top level
   - GitHub URLs pointing at the wrong org (canonical: XertroV/c2c-msg)
   - bare deprecated Python script references shown without a "DEPRECATED"
     qualifier nearby

   Conservative on purpose: high-signal claims that are cheap to verify
   statically. Reports drift as warnings; --warn-only exits 0 even when
   findings exist (used by `c2c doctor` summary output). *)

open Cmdliner.Term.Syntax

let ( // ) = Filename.concat

type finding = {
  kind : string;     (* "path" | "command" | "url" | "py-script" *)
  source : string;   (* doc path, relative to repo *)
  line : int;
  claim : string;
  message : string;
}

(* ------------------------------------------------------------------------ *)
(* Token utilities                                                          *)
(* ------------------------------------------------------------------------ *)

let strip_punct s =
  let s = String.trim s in
  let n = String.length s in
  let rec drop_right i =
    if i = 0 then 0
    else
      let c = s.[i - 1] in
      if c = '.' || c = ',' || c = ')' || c = ';' || c = ':' || c = '\'' || c = '"' then drop_right (i - 1)
      else i
  in
  let n' = drop_right n in
  if n' = n then s else String.sub s 0 n'

let is_placeholder s =
  String.contains s '<' || String.contains s '>' || String.contains s '$' || String.contains s '*'

let path_prefixes = [ ".collab/"; ".c2c/"; "docs/"; "scripts/"; "ocaml/"; "./" ]
let path_suffixes = [ ".md"; ".py"; ".sh"; ".ml"; ".mli"; ".ts"; ".tsx"; ".json"; ".toml"; ".yml"; ".yaml" ]

let starts_with ~prefix s =
  let lp = String.length prefix in
  String.length s >= lp && String.sub s 0 lp = prefix

let ends_with ~suffix s =
  let ls = String.length suffix and l = String.length s in
  l >= ls && String.sub s (l - ls) ls = suffix

let any pred xs = List.exists pred xs

let looks_repo_path raw =
  let t = strip_punct raw in
  if t = "" || is_placeholder t then false
  else if starts_with ~prefix:"~" t || starts_with ~prefix:"/" t
       || starts_with ~prefix:"http://" t || starts_with ~prefix:"https://" t
  then false
  else if any (fun p -> starts_with ~prefix:p t) path_prefixes then true
  else
    (* Bare scripts (no slash) ending in .py or .sh — pull-request flag for
       "is this a real repo path?" Bare other-suffix tokens are usually
       illustrative prose, not paths. *)
    let no_slash = not (String.contains t '/') in
    no_slash && (ends_with ~suffix:".py" t || ends_with ~suffix:".sh" t)
  [@@warning "-26"]

let normalize_repo_path raw =
  let t = strip_punct raw in
  if starts_with ~prefix:"./" t then String.sub t 2 (String.length t - 2)
  else t

let _ = path_suffixes  (* reserved for future expansion *)

(* ------------------------------------------------------------------------ *)
(* Code-span extraction                                                     *)
(* ------------------------------------------------------------------------ *)

(* Lines that explicitly mark themselves as deprecated/legacy/archived
   are exempt from the deprecated-Python-script and command-not-registered
   checks — those scripts belong in such sections. *)
let line_is_deprecated_marker s =
  let s = String.uppercase_ascii s in
  let contains needle =
    let nlen = String.length needle in
    let slen = String.length s in
    let found = ref false in
    let i = ref 0 in
    while not !found && !i + nlen <= slen do
      if String.sub s !i nlen = needle then found := true
      else incr i
    done;
    !found
  in
  contains "DEPRECATED" || contains "LEGACY" || contains "ARCHIVED"

(* Yields (lineno, claim, deprecated_context) triples for every
   backtick-delimited code span and for the first whitespace-token of
   every fenced code block line. The third element is true if the line
   contains a "DEPRECATED"/"LEGACY"/"ARCHIVED" marker — used to skip
   over-eager checks on intentional deprecation documentation. *)
let iter_code_claims path =
  let ic = open_in path in
  let acc = ref [] in
  let in_fence = ref false in
  let lineno = ref 0 in
  Fun.protect
    ~finally:(fun () -> try close_in ic with _ -> ())
    (fun () ->
       try
         while true do
           let line = input_line ic in
           incr lineno;
           let stripped = String.trim line in
           let dep = line_is_deprecated_marker line in
           if starts_with ~prefix:"```" stripped then in_fence := not !in_fence
           else begin
             (* Inline backtick spans `like this` *)
             let n = String.length line in
             let i = ref 0 in
             while !i < n do
               if line.[!i] = '`' then begin
                 let start = !i + 1 in
                 let j = ref start in
                 while !j < n && line.[!j] <> '`' && line.[!j] <> '\n' do incr j done;
                 if !j < n && line.[!j] = '`' then begin
                   acc := (!lineno, String.sub line start (!j - start), dep) :: !acc;
                   i := !j + 1
                 end else
                   i := n
               end else
                 incr i
             done;
             (* Fenced-block first word *)
             if !in_fence && stripped <> "" then begin
               match String.index_opt stripped ' ' with
               | None -> acc := (!lineno, stripped, dep) :: !acc
               | Some k -> acc := (!lineno, String.sub stripped 0 k, dep) :: !acc
             end
           end
         done; assert false
       with End_of_file -> ());
  List.rev !acc

(* ------------------------------------------------------------------------ *)
(* Top-level c2c command set, via `c2c commands`                            *)
(* ------------------------------------------------------------------------ *)

module SS = Set.Make (String)

let extract_top_level_commands () =
  (* Parse `c2c commands` output. Format: "  <name>    <description>".
     Section headers start with "==". Lines without a 2-space indent are
     ignored. *)
  let cmd = "c2c commands 2>/dev/null" in
  let ic = Unix.open_process_in cmd in
  let names = ref SS.empty in
  (try
     while true do
       let line = input_line ic in
       let n = String.length line in
       if n >= 4 && line.[0] = ' ' && line.[1] = ' ' && line.[2] <> ' ' && line.[2] <> '=' then begin
         let trimmed = String.trim line in
         match String.index_opt trimmed ' ' with
         | None -> ()
         | Some i ->
             let name = String.sub trimmed 0 i in
             if name <> "" && not (String.contains name '=') then
               names := SS.add name !names
       end
     done
   with End_of_file -> ());
  ignore (Unix.close_process_in ic);
  !names

(* Hard-coded fallback for environments where `c2c commands` doesn't run
   (e.g. tests, CI without binary on PATH). Keep in rough sync with the
   `all_cmds` list in c2c.ml. *)
let fallback_commands = SS.of_list [
  "list"; "whoami"; "poll-inbox"; "peek-inbox"; "send"; "send-all";
  "rooms"; "my-rooms"; "history"; "dead-letter"; "tail-log"; "health";
  "status"; "verify"; "prune-rooms"; "instances"; "doctor"; "stats";
  "set-compact"; "clear-compact"; "open-pending-reply"; "check-pending-reply";
  "start"; "stop"; "restart"; "install"; "init"; "register"; "sweep";
  "sweep-dryrun"; "refresh-peer"; "broker-gc"; "monitor"; "screen";
  "wire-daemon"; "deliver-inbox"; "agent"; "roles"; "config"; "repo";
  "memory"; "peer-pass"; "worktree"; "sticker"; "sitrep"; "room";
  "relay"; "skills"; "gui"; "mcp"; "serve"; "hook"; "inject";
  "restart-self"; "reset-thread"; "diag"; "commands"; "completion";
  "debug"; "cc-plugin"; "oc-plugin"; "supervisor"; "statefile";
  "get-tmux-location"; "help";
]

(* ------------------------------------------------------------------------ *)
(* Specific drift checks                                                    *)
(* ------------------------------------------------------------------------ *)

(* `c2c <subcommand>` extraction inside a single claim *)
let c2c_command_re = Str.regexp "\\(^\\| \\)c2c +\\([a-z][a-z0-9_/-]*\\)"

let extract_c2c_commands claim =
  let acc = ref [] in
  let pos = ref 0 in
  let len = String.length claim in
  (try
     while !pos < len do
       let i = Str.search_forward c2c_command_re claim !pos in
       let name = Str.matched_group 2 claim in
       acc := name :: !acc;
       pos := i + String.length (Str.matched_string claim)
     done
   with Not_found -> ());
  List.rev !acc

(* GitHub org check: `github.com/<org>/<repo>`. Canonical org is XertroV. *)
let github_re = Str.regexp "github\\.com/\\([A-Za-z0-9._-]+\\)/\\([A-Za-z0-9._-]+\\)"

let check_github_url claim =
  let acc = ref [] in
  let pos = ref 0 in
  let len = String.length claim in
  (try
     while !pos < len do
       let i = Str.search_forward github_re claim !pos in
       let org = Str.matched_group 1 claim in
       let repo = Str.matched_group 2 claim in
       if String.lowercase_ascii org <> "xertrov" then
         acc := Printf.sprintf "github.com/%s/%s" org repo :: !acc;
       pos := i + String.length (Str.matched_string claim)
     done
   with Not_found -> ());
  List.rev !acc

(* Deprecated-Python-script check: bare `c2c_<word>.py` script reference.
   We only flag it as drift if the name is in our known-deprecated list. *)
let deprecated_py_scripts = SS.of_list [
  "c2c_send.py"; "c2c_list.py"; "c2c_whoami.py"; "c2c_register.py";
  "c2c_verify.py"; "c2c_history.py"; "c2c_health.py"; "c2c_install.py";
  "c2c_cli.py"; "c2c_start.py"; "c2c_mcp.py"; "c2c_broker_gc.py";
  "c2c_sweep_dryrun.py"; "c2c_refresh_peer.py"; "c2c_configure_claude_code.py";
  "c2c_configure_codex.py"; "c2c_configure_opencode.py";
  "c2c_configure_kimi.py"; "c2c_configure_crush.py";
  "c2c_kimi_wire_bridge.py"; "c2c_wire_daemon.py";
  "c2c_opencode_wake_daemon.py"; "c2c_kimi_wake_daemon.py";
  "c2c_claude_wake_daemon.py"; "c2c_crush_wake_daemon.py"; "c2c_poker.py";
  "c2c_inject.py"; "c2c_pts_inject.py"; "relay.py"; "c2c_relay.py";
  "c2c_auto_relay.py";
]

(* ------------------------------------------------------------------------ *)
(* Audit driver                                                             *)
(* ------------------------------------------------------------------------ *)

let audit ~repo ~docs =
  (* Union live (`c2c commands`) with the hard-coded fallback. `c2c commands`
     filters out Tier 3 (install/init/monitor are hidden), so neither set
     alone is complete; the union keeps both lists honest. *)
  let commands =
    let live = extract_top_level_commands () in
    SS.union live fallback_commands
  in
  let findings = ref [] in
  let seen : (string * string * int, unit) Hashtbl.t = Hashtbl.create 64 in
  let push f =
    let k = (f.kind, f.claim, f.line) in
    if not (Hashtbl.mem seen k) then begin
      Hashtbl.add seen k ();
      findings := f :: !findings
    end
  in
  List.iter (fun doc ->
      let abs = if Filename.is_relative doc then repo // doc else doc in
      let rel =
        try
          let rl = String.length repo in
          let al = String.length abs in
          if al >= rl && String.sub abs 0 rl = repo then
            String.sub abs (rl + 1) (al - rl - 1)
          else doc
        with _ -> doc
      in
      if not (Sys.file_exists abs) then
        push { kind = "doc"; source = doc; line = 0; claim = doc; message = "document is missing" }
      else
        let claims = iter_code_claims abs in
        List.iter (fun (line, claim, dep) ->
            (* path checks: always run; missing files are drift regardless
               of whether the line is labelled deprecated. *)
            String.split_on_char ' ' claim
            |> List.iter (fun raw ->
                if looks_repo_path raw then begin
                  let p = normalize_repo_path raw in
                  if not (Sys.file_exists (repo // p)) then
                    push { kind = "path"; source = rel; line; claim = p;
                           message = "repo path does not exist" }
                end);
            (* c2c command checks: skip on deprecated-context lines. *)
            if not dep then
              extract_c2c_commands claim
              |> List.iter (fun cmd ->
                  let head = match String.index_opt cmd '/' with
                    | None -> cmd | Some i -> String.sub cmd 0 i
                  in
                  if head <> "" && not (is_placeholder head) && not (SS.mem head commands) then
                    push { kind = "command"; source = rel; line;
                           claim = "c2c " ^ head;
                           message = "top-level c2c command is not registered" });
            (* github URL checks: always run. *)
            check_github_url claim
            |> List.iter (fun url ->
                push { kind = "url"; source = rel; line; claim = url;
                       message = "github org is not the canonical XertroV/c2c-msg" });
            (* Deprecated Python script checks: only flag in non-deprecated
               context. `.collab/runbooks/python-scripts-deprecated.md`
               (link-out target from CLAUDE.md as of #320) legitimately
               documents these as deprecated — that's the exemption. *)
            if not dep then
              String.split_on_char ' ' claim
              |> List.iter (fun raw ->
                  let t = strip_punct raw in
                  if SS.mem t deprecated_py_scripts then
                    push { kind = "py-script"; source = rel; line; claim = t;
                           message = "deprecated Python script — prefer OCaml subcommand" });
          ) claims)
    docs;
  List.rev !findings

(* ------------------------------------------------------------------------ *)
(* Output                                                                   *)
(* ------------------------------------------------------------------------ *)

let render_human findings =
  let n = List.length findings in
  Printf.printf "docs-drift: %d drift finding(s)\n" n;
  if findings <> [] then begin
    print_endline "";
    print_endline "Documentation claims that appear stale:";
    List.iter (fun f ->
        Printf.printf "  - %s:%d: %s — %s\n" f.source f.line f.claim f.message)
      findings;
    print_endline "";
    print_endline "Note: this is a static docs drift audit, not a full documentation review."
  end

let render_summary findings =
  let n = List.length findings in
  Printf.printf "docs-drift: %d drift finding(s)\n" n;
  if findings <> [] then begin
    let parts = List.map (fun f ->
        Printf.sprintf "%s:%d %s (%s)" f.source f.line f.claim f.message) findings
    in
    print_endline ("drift: " ^ String.concat "; " parts)
  end

let render_json findings =
  let arr = `List (List.map (fun f ->
      `Assoc [
        ("kind", `String f.kind);
        ("source", `String f.source);
        ("line", `Int f.line);
        ("claim", `String f.claim);
        ("message", `String f.message);
      ]) findings)
  in
  print_endline (Yojson.Safe.pretty_to_string arr)

(* ------------------------------------------------------------------------ *)
(* Cmdliner wiring                                                          *)
(* ------------------------------------------------------------------------ *)

let resolve_repo () =
  match Git_helpers.git_repo_toplevel () with
  | Some r -> r
  | None ->
      Printf.eprintf "error: must run from inside the c2c git repo.\n%!";
      exit 1

let docs_drift_cmd =
  let doc_args =
    Cmdliner.Arg.(value & opt_all string [] & info [ "doc" ] ~docv:"PATH"
      ~doc:"Doc to audit, repo-relative. Repeatable. Defaults to CLAUDE.md.")
  in
  let summary =
    Cmdliner.Arg.(value & flag & info [ "summary" ]
      ~doc:"Compact one-line output suitable for `c2c doctor` rollup.")
  in
  let json =
    Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Output JSON findings.")
  in
  let warn_only =
    Cmdliner.Arg.(value & flag & info [ "warn-only" ]
      ~doc:"Exit 0 even when drift exists (warning-only mode).")
  in
  let+ doc_args = doc_args
  and+ summary = summary
  and+ json = json
  and+ warn_only = warn_only in
  let repo = resolve_repo () in
  let docs = match doc_args with [] -> [ "CLAUDE.md" ] | xs -> xs in
  (* Gracefully no-op if the default CLAUDE.md doesn't exist in this repo. *)
  if doc_args = [] && not (Sys.file_exists (repo // "CLAUDE.md")) then begin
    print_endline "docs-drift: skipped (CLAUDE.md not found)";
    exit 0
  end;
  let findings = audit ~repo ~docs in
  if json then render_json findings
  else if summary then render_summary findings
  else render_human findings;
  if warn_only then exit 0
  else exit (if findings = [] then 0 else 1)
