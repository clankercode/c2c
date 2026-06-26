(* test_c2c_list_glyphs.ml — integration tests for `c2c list-glyphs`.

   Verifies:
   (a) `c2c list-glyphs` exits 0 and stdout parses as JSON;
   (b) the JSON has the expected top-level keys and the exact glyph chars
       for a sample of each group, incl. the NEW routes.unknown.glyph "◌";
   (c) it ALSO exits 0 with C2C_MCP_SESSION_ID set (proves the command is
       always-runnable in an agent session — the hard constraint);
   (d) `c2c commands` output does NOT contain "list-glyphs", but
       `c2c commands --dev` DOES.

   Resolves the freshly-built binary relative to the test executable (both
   live in _build/default/ocaml/cli), avoiding a stale ~/.local/bin/c2c. *)

open Alcotest

let ( // ) = Filename.concat

let c2c_binary =
  let dir = Filename.dirname Sys.executable_name in
  let candidate = dir // "c2c.exe" in
  if Sys.file_exists candidate then candidate else "c2c"

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) @@ fun () ->
  really_input_string ic (in_channel_length ic)

(* Run the c2c binary with optional extra env vars; capture stdout + rc.
   We always neutralise inherited session/instance env first, then layer
   the caller's overrides on top (so a test can deliberately set
   C2C_MCP_SESSION_ID to emulate an agent session). *)
let run_c2c ?(env = []) args =
  let out_file =
    Filename.get_temp_dir_name ()
    // Printf.sprintf "c2c-glyphs-test-%d-%06x" (Unix.getpid ()) (Random.bits ())
  in
  let base_env =
    [ "C2C_CLI_FORCE=1"
    ; "C2C_MCP_SESSION_ID="
    ; "CLAUDE_SESSION_ID="
    ; "C2C_MCP_AUTO_REGISTER_ALIAS="
    ; "C2C_INSTANCE_NAME="
    ]
  in
  let env_list =
    base_env @ List.map (fun (k, v) -> k ^ "=" ^ v) env @ [ "PATH=" ^ Sys.getenv "PATH" ]
  in
  let env_str = String.concat " " env_list in
  let args_str = String.concat " " (List.map Filename.quote args) in
  let cmd =
    (* Group the binary invocation and the exit-marker echo so BOTH land in
       out_file (the redirect must wrap the whole group, not just env). *)
    Printf.sprintf "{ env %s %s %s; echo exit:$?; } >%s 2>/dev/null" env_str
      (Filename.quote c2c_binary) args_str (Filename.quote out_file)
  in
  let _ = Sys.command cmd in
  let raw = try read_file out_file with _ -> "" in
  (try Sys.remove out_file with _ -> ());
  (* Split off the trailing "exit:N" marker line we appended. *)
  let rc, stdout =
    let marker = "exit:" in
    let mlen = String.length marker in
    let n = String.length raw in
    let idx = ref (-1) in
    for i = 0 to n - mlen do
      if String.sub raw i mlen = marker then idx := i
    done;
    if !idx >= 0 then
      let after = String.trim (String.sub raw (!idx + mlen) (n - !idx - mlen)) in
      let rc = try int_of_string after with _ -> -1 in
      let cut = if !idx > 0 && raw.[!idx - 1] = '\n' then !idx - 1 else !idx in
      (rc, String.sub raw 0 cut)
    else (-1, raw)
  in
  (rc, stdout)

let string_contains haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= hay_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

(* JSON navigation helpers *)
let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let glyph_char json path =
  (* path is a list of nested keys ending at a glyph-entry; return its
     "glyph" string. *)
  let rec descend j = function
    | [] -> j
    | k :: rest -> (match member k j with Some j' -> descend j' rest | None -> `Null)
  in
  match member "glyph" (descend json path) with Some (`String s) -> s | _ -> "<missing>"

(* ---------------------------------------------------------------- *)

let test_runs_and_parses () =
  let rc, out = run_c2c [ "list-glyphs" ] in
  check int "list-glyphs exits 0" 0 rc;
  let json = try Some (Yojson.Safe.from_string out) with _ -> None in
  check bool "stdout parses as JSON" true (Option.is_some json)

let test_top_level_keys_and_glyphs () =
  let _, out = run_c2c [ "list-glyphs" ] in
  let json = Yojson.Safe.from_string out in
  let expected_keys =
    [ "schema_version"; "description"; "ascii_fallback"; "colors"; "container"
    ; "actions"; "directions"; "routes"; "liveness"; "subagent_registration"
    ; "message_sources"; "notes" ]
  in
  List.iter
    (fun k -> check bool (Printf.sprintf "top-level key %s present" k) true
        (Option.is_some (member k json)))
    expected_keys;
  (* schema_version = 1 *)
  check bool "schema_version = 1" true (member "schema_version" json = Some (`Int 1));
  (* exact glyph chars — a sample from each group *)
  check string "container.line_marker glyph" "⧓" (glyph_char json [ "container"; "line_marker" ]);
  check string "directions.incoming glyph" "▼" (glyph_char json [ "directions"; "incoming" ]);
  check string "directions.outgoing glyph" "▲" (glyph_char json [ "directions"; "outgoing" ]);
  check string "directions.broadcast glyph" "✶" (glyph_char json [ "directions"; "broadcast" ]);
  check string "directions.arrows.incoming glyph" "←" (glyph_char json [ "directions"; "arrows"; "incoming" ]);
  check string "routes.local glyph" "⌂" (glyph_char json [ "routes"; "local" ]);
  check string "routes.sessions glyph" "◎" (glyph_char json [ "routes"; "sessions" ]);
  check string "routes.relay glyph" "⇄" (glyph_char json [ "routes"; "relay" ]);
  check string "routes.unknown glyph (NEW)" "◌" (glyph_char json [ "routes"; "unknown" ]);
  check string "liveness.alive glyph" "●" (glyph_char json [ "liveness"; "alive" ]);
  check string "liveness.dead glyph" "○" (glyph_char json [ "liveness"; "dead" ]);
  check string "subagent.fork glyph" "↳" (glyph_char json [ "subagent_registration"; "fork" ]);
  check string "subagent.bullet glyph" "›" (glyph_char json [ "subagent_registration"; "bullet" ])

let test_runnable_in_agent_session () =
  (* The hard constraint: pi-c2c invokes c2c with the host session env,
     which may set a session-id var flipping is_agent_session true. The
     command MUST still run. *)
  let rc, out = run_c2c ~env:[ ("C2C_MCP_SESSION_ID", "probe-xyz") ] [ "list-glyphs" ] in
  check int "list-glyphs exits 0 with C2C_MCP_SESSION_ID set" 0 rc;
  let json = try Some (Yojson.Safe.from_string out) with _ -> None in
  check bool "agent-session stdout parses as JSON" true (Option.is_some json)

let test_compact_flag () =
  let rc, out = run_c2c [ "list-glyphs"; "--compact" ] in
  check int "list-glyphs --compact exits 0" 0 rc;
  let json = try Some (Yojson.Safe.from_string out) with _ -> None in
  check bool "compact stdout parses as JSON" true (Option.is_some json);
  (* compact output is single-line (no embedded newline before the trailing one) *)
  let trimmed = String.trim out in
  check bool "compact output is single-line" true (not (String.contains trimmed '\n'))

let test_commands_hides_without_dev () =
  let _, out = run_c2c [ "commands" ] in
  check bool "`c2c commands` omits list-glyphs" false (string_contains out "list-glyphs")

let test_commands_dev_shows () =
  let _, out = run_c2c [ "commands"; "--dev" ] in
  check bool "`c2c commands --dev` includes list-glyphs" true (string_contains out "list-glyphs")

(* ---------------------------------------------------------------- *)

let () =
  run "c2c_list_glyphs"
    [ ( "registry",
        [ test_case "list-glyphs runs and parses as JSON" `Quick test_runs_and_parses
        ; test_case "top-level keys + exact glyph chars" `Quick test_top_level_keys_and_glyphs
        ; test_case "--compact emits single-line JSON" `Quick test_compact_flag
        ] )
    ; ( "always_runnable",
        [ test_case "exits 0 in an agent session" `Quick test_runnable_in_agent_session
        ] )
    ; ( "help_hiding",
        [ test_case "c2c commands hides list-glyphs by default" `Quick test_commands_hides_without_dev
        ; test_case "c2c commands --dev reveals list-glyphs" `Quick test_commands_dev_shows
        ] )
    ]
