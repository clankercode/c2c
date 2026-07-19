(* test_c2c_setup_agy — #65: the hooks.json `c2c install agy` writes must be
   parseable by agy, in agy's OWN schema.

   agy's hook file is NOT the Claude Code hook file. Its schema was established
   from the shipped binary (agy 1.1.4 / language-server 1.1.2) three ways:

   1. The vendor's hooks reference is embedded verbatim in the agy binary
      ("# Lifecycle Hooks (`hooks.json`)"). It states: top-level keys are hook
      NAMES; a spec's fields are event names; PreToolUse/PostToolUse are
      "Grouped (uses `matcher` & `hooks` wrapper)" while PreInvocation /
      PostInvocation / Stop are "Flat (list of handler objects directly)";
      a handler's only required field is `command`.
   2. Symbol inspection: the parsed type is `map[string]jsonhook.JSONHookSpec`
      and the rejection is jsonhook's "command hook must specify 'command'",
      raised under "invalid hook %q" — a per-FILE error, not per-event.
   3. A live probe (agy --print, tool call + stop, marker-writing handlers):
      SessionStart (flat), PreInvocation (flat), PostToolUse (grouped) and
      Stop (flat) ALL fired. SessionStart is supported even though the
      embedded doc omits it from its field list.

   Writing Claude's grouped shape for a flat event makes agy read the
   {"hooks": [...]} wrapper as a handler, find no `command`, and reject the
   WHOLE file. A second live probe — one valid named hook plus one old-shape
   named hook — fired NEITHER, so the malformed c2c entry also disabled every
   other tool's hooks in this shared file. *)

open Alcotest

let ( // ) = Filename.concat

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    really_input_string ic (in_channel_length ic))

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun child -> remove_tree (path // child)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path

let with_temp_home f =
  let base = Filename.get_temp_dir_name () in
  let dir = base // Printf.sprintf "c2c-setup-agy-%08x" (Random.bits ()) in
  Unix.mkdir dir 0o700;
  let prev_home = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" dir;
  Fun.protect
    ~finally:(fun () ->
      (match prev_home with Some h -> Unix.putenv "HOME" h | None -> ());
      try remove_tree dir with _ -> ())
    (fun () -> f dir)

let run_setup ~alias =
  C2c_setup.setup_agy ~output_mode:C2c_types.Json ~dry_run:false
    ~root:"/fake/broker/root" ~alias_val:alias ~alias_from_auto_gen:false

let hooks_path home = home // ".gemini" // "config" // "hooks.json"

(* ---------------------------------------------------------------------- *)
(* agy's parser rules, restated as a checker.                              *)
(* ---------------------------------------------------------------------- *)

(* Events agy parses as GROUPED (matcher + hooks wrapper). Every other valid
   event is parsed FLAT: the array items ARE the handler objects. *)
let grouped_events = [ "PreToolUse"; "PostToolUse" ]

(* The complete set of event fields a JSONHookSpec accepts. Note the absence of
   SessionEnd — agy has no such event (established while investigating #61) —
   and that Go's json decoder silently IGNORES unknown fields, so a misnamed
   event installs a handler that can never fire and never warns. *)
let known_events =
  [ "SessionStart"; "PreToolUse"; "PostToolUse"; "PreInvocation";
    "PostInvocation"; "Stop" ]

let bad fmt = Printf.ksprintf (fun msg -> Alcotest.fail msg) fmt

(* agy's handler rule — the check whose failure yields
   "command hook must specify 'command'" and rejects the file. *)
let check_handler ~where (h : Yojson.Safe.t) =
  match h with
  | `Assoc fields ->
      (match List.assoc_opt "command" fields with
       | Some (`String s) when String.trim s <> "" -> ()
       | Some (`String _) -> bad "%s: handler has an empty 'command'" where
       | Some _ -> bad "%s: handler 'command' is not a string" where
       | None ->
           bad
             "%s: command hook must specify 'command' — agy rejects the WHOLE \
              file. Keys present: [%s]"
             where (String.concat "; " (List.map fst fields)));
      (match List.assoc_opt "type" fields with
       | None | Some (`String "command") -> ()
       | Some other ->
           bad "%s: unsupported handler type %s" where (Yojson.Safe.to_string other));
      (match List.assoc_opt "timeout" fields with
       | None | Some (`Int _) -> ()
       | Some other ->
           bad "%s: 'timeout' must be an int, got %s" where
             (Yojson.Safe.to_string other))
  | other ->
      bad "%s: handler must be an object, got %s" where (Yojson.Safe.to_string other)

let check_event ~hook_name ~event (payload : Yojson.Safe.t) =
  if not (List.mem event known_events) then
    bad "hook %S: %S is not an agy hook event (known: %s)" hook_name event
      (String.concat ", " known_events);
  let items =
    match payload with
    | `List [] -> bad "hook %S: event %S has no handlers" hook_name event
    | `List l -> l
    | other ->
        bad "hook %S: event %S must be an array, got %s" hook_name event
          (Yojson.Safe.to_string other)
  in
  if List.mem event grouped_events then
    List.iteri
      (fun i item ->
        let where = Printf.sprintf "hook %S event %S group %d" hook_name event i in
        match item with
        | `Assoc fields ->
            (match List.assoc_opt "matcher" fields with
             | Some (`String _) -> ()
             | Some other ->
                 bad "%s: 'matcher' must be a string, got %s" where
                   (Yojson.Safe.to_string other)
             | None -> bad "%s: tool-event group must specify 'matcher'" where);
            (match List.assoc_opt "hooks" fields with
             | Some (`List []) -> bad "%s: 'hooks' is empty" where
             | Some (`List hs) ->
                 List.iteri
                   (fun j h ->
                     check_handler ~where:(Printf.sprintf "%s handler %d" where j) h)
                   hs
             | Some other ->
                 bad "%s: 'hooks' must be an array, got %s" where
                   (Yojson.Safe.to_string other)
             | None -> bad "%s: tool-event group must specify 'hooks'" where)
        | other ->
            bad "%s: group must be an object, got %s" where
              (Yojson.Safe.to_string other))
      items
  else
    (* Flat: a Claude-style {"hooks": [...]} wrapper lands here as a handler
       with no 'command' — the #65 parse failure, exactly. *)
    List.iteri
      (fun i item ->
        check_handler
          ~where:(Printf.sprintf "hook %S event %S handler %d" hook_name event i)
          item)
      items

let check_hooks_file (j : Yojson.Safe.t) =
  match j with
  | `Assoc named ->
      List.iter
        (fun (hook_name, spec) ->
          match spec with
          | `Assoc fields ->
              List.iter
                (fun (k, v) ->
                  match k with
                  | "enabled" -> (
                      match v with
                      | `Bool _ -> ()
                      | other ->
                          bad "hook %S: 'enabled' must be a bool, got %s" hook_name
                            (Yojson.Safe.to_string other))
                  | event -> check_event ~hook_name ~event v)
                fields
          | other ->
              bad "hook %S: spec must be an object, got %s" hook_name
                (Yojson.Safe.to_string other))
        named
  | other ->
      bad "hooks.json must be a JSON object, got %s" (Yojson.Safe.to_string other)

let c2c_spec_of json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "c2c-hooks" fields with
      | Some (`Assoc spec) -> spec
      | Some other ->
          bad "c2c-hooks must be an object, got %s" (Yojson.Safe.to_string other)
      | None -> bad "hooks.json has no c2c-hooks entry")
  | other -> bad "hooks.json must be an object, got %s" (Yojson.Safe.to_string other)

(* ---------------------------------------------------------------------- *)
(* Tests                                                                   *)
(* ---------------------------------------------------------------------- *)

let test_written_file_parses_under_agy_rules () =
  with_temp_home (fun home ->
    ignore (run_setup ~alias:"agy-fixture-aa");
    let path = hooks_path home in
    check bool "hooks.json exists" true (Sys.file_exists path);
    check_hooks_file (Yojson.Safe.from_string (read_file path)))

let test_flat_events_carry_no_claude_wrapper () =
  (* The #65 defect pinned directly: no flat event may carry a Claude-style
     {"hooks": [...]} / {"matcher": ...} group. *)
  with_temp_home (fun home ->
    ignore (run_setup ~alias:"agy-fixture-ab");
    let spec = c2c_spec_of (Yojson.Safe.from_string (read_file (hooks_path home))) in
    List.iter
      (fun (event, payload) ->
        if not (List.mem event grouped_events) then
          match payload with
          | `List items ->
              List.iter
                (fun item ->
                  match item with
                  | `Assoc kv
                    when List.mem_assoc "hooks" kv || List.mem_assoc "matcher" kv ->
                      bad
                        "event %S is FLAT in agy but was written with a \
                         Claude-style wrapper: %s"
                        event (Yojson.Safe.to_string item)
                  | _ -> ())
                items
          | _ -> ())
      spec)

let test_required_events_installed () =
  (* SessionStart = registration. PostToolUse + Stop = the mid-session activity
     anchor that #59/#51 put agy on `hook_anchor_is_activity_backed` FOR. *)
  with_temp_home (fun home ->
    ignore (run_setup ~alias:"agy-fixture-ac");
    let spec = c2c_spec_of (Yojson.Safe.from_string (read_file (hooks_path home))) in
    List.iter
      (fun ev ->
        check bool (Printf.sprintf "%s installed" ev) true (List.mem_assoc ev spec))
      [ "SessionStart"; "PostToolUse"; "Stop" ])

let test_handlers_dispatch_to_c2c_hook_agy () =
  with_temp_home (fun home ->
    ignore (run_setup ~alias:"agy-fixture-ad");
    let body = read_file (hooks_path home) in
    let contains needle =
      let hl = String.length body and nl = String.length needle in
      let rec at i = i + nl <= hl && (String.sub body i nl = needle || at (i + 1)) in
      at 0
    in
    List.iter
      (fun ev ->
        check bool
          (Printf.sprintf "dispatches c2c hook agy %s" ev)
          true
          (contains ("c2c hook agy " ^ ev)))
      [ "SessionStart"; "PostToolUse"; "Stop" ])

let test_merge_preserves_foreign_named_hooks () =
  (* The file is shared with other tools. c2c must replace only its own key —
     and must not be malformed, since one bad named hook takes every other
     hook in the file down with it (live-probe confirmed). *)
  with_temp_home (fun home ->
    let dir = home // ".gemini" // "config" in
    C2c_mcp.mkdir_p dir;
    let foreign =
      {|{"lint-checker": {"Stop": [{"command": "./lint.sh"}]},
         "c2c-hooks": {"Bogus": []}}|}
    in
    let oc = open_out (hooks_path home) in
    Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc foreign);
    ignore (run_setup ~alias:"agy-fixture-ae");
    let json = Yojson.Safe.from_string (read_file (hooks_path home)) in
    (match json with
     | `Assoc fields ->
         check bool "foreign hook preserved" true (List.mem_assoc "lint-checker" fields);
         check int "exactly one c2c-hooks entry" 1
           (List.length (List.filter (fun (k, _) -> k = "c2c-hooks") fields));
         check bool "stale c2c event replaced" false
           (List.mem_assoc "Bogus" (c2c_spec_of json))
     | other -> bad "merge must yield an object, got %s" (Yojson.Safe.to_string other));
    check_hooks_file json)

let () =
  run "c2c_setup_agy"
    [ ( "agy hooks.json schema (#65)"
      , [ test_case "written file parses under agy's rules" `Quick
            test_written_file_parses_under_agy_rules
        ; test_case "flat events carry no Claude-style wrapper" `Quick
            test_flat_events_carry_no_claude_wrapper
        ; test_case "SessionStart + PostToolUse + Stop installed" `Quick
            test_required_events_installed
        ; test_case "handlers invoke c2c hook agy <event>" `Quick
            test_handlers_dispatch_to_c2c_hook_agy
        ; test_case "merge preserves foreign named hooks" `Quick
            test_merge_preserves_foreign_named_hooks
        ] )
    ]
