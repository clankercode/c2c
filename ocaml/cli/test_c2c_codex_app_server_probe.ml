(* test_c2c_codex_app_server_probe — fixture-gated regression guard for the
   Codex app-server remote-TUI / passive-injection safety invariants
   (backlog P1.M1.E1.T001).

   Default (env C2C_CODEX_APPSERVER_PROBE unset/!=1): the test SKIPS the live
   probe and passes — so `just test`/`just check` stay green everywhere,
   including hosts without the codex binary (repo test-fixture convention:
   external effects gated behind an env var).

   Gated ON (C2C_CODEX_APPSERVER_PROBE=1): shell out to
   scripts/codex-app-server-probe.py --boundary, parse its JSON verdict, and
   assert the invariants the c2c app-server-backed Codex path (T002/T003/T007)
   depends on:
     - thread/inject_items is accepted and starts NO turn;
     - inject/turn methods are distinct in the installed schema;
     - NO machine-readable composer/draft signal exists (blocker flag);
     - a bare loopback listener grants unauthenticated same-UID access, while
       --ws-auth capability-token rejects an unauthenticated client (401).

   Rerun against a future codex version to detect protocol/boundary drift:
     C2C_CODEX_APPSERVER_PROBE=1 dune exec ocaml/cli/test_c2c_codex_app_server_probe.exe
*)

open Alcotest

let gate_on () =
  match Sys.getenv_opt "C2C_CODEX_APPSERVER_PROBE" with
  | Some "1" -> true
  | _ -> false

(* Resolve the probe script: explicit env override, else walk a few ancestors
   of the CWD looking for scripts/codex-app-server-probe.py. *)
let find_script () =
  match Sys.getenv_opt "C2C_APPSERVER_PROBE_SCRIPT" with
  | Some p when Sys.file_exists p -> Some p
  | _ ->
    let rel = Filename.concat "scripts" "codex-app-server-probe.py" in
    let rec up dir depth =
      if depth < 0 then None
      else
        let cand = Filename.concat dir rel in
        if Sys.file_exists cand then Some cand
        else up (Filename.dirname dir) (depth - 1)
    in
    up (Sys.getcwd ()) 8

let read_all ic =
  let buf = Buffer.create 4096 in
  (try
     while true do
       Buffer.add_channel buf ic 4096
     done
   with End_of_file -> ());
  Buffer.contents buf

(* Run the probe, return its parsed JSON verdict (last JSON object on stdout). *)
let run_probe script =
  let cmd = Printf.sprintf "python3 %s --boundary 2>/dev/null"
      (Filename.quote script) in
  let ic = Unix.open_process_in cmd in
  let out = read_all ic in
  let _ = Unix.close_process_in ic in
  (* The probe prints one pretty-printed JSON object; parse the whole thing. *)
  try Some (Yojson.Safe.from_string out) with _ -> None

let member = Yojson.Safe.Util.member
let to_bool_opt j = match j with `Bool b -> Some b | _ -> None

let bool_at json path =
  let rec go j = function
    | [] -> to_bool_opt j
    | k :: rest -> go (member k j) rest
  in
  go json path

let test_probe_invariants () =
  if not (gate_on ()) then
    (* Documented skip — keeps default `just test` green without codex. *)
    check bool "skipped (set C2C_CODEX_APPSERVER_PROBE=1 to run live probe)" true true
  else begin
    let script =
      match find_script () with
      | Some s -> s
      | None -> failwith "codex-app-server-probe.py not found (set C2C_APPSERVER_PROBE_SCRIPT)"
    in
    match run_probe script with
    | None -> failwith "probe produced no parseable JSON verdict"
    | Some j ->
      check (option bool) "overall probe ok" (Some true) (bool_at j [ "ok" ]);
      check (option bool) "inject accepted" (Some true)
        (bool_at j [ "stdio"; "inject_accepted" ]);
      check (option bool) "inject starts no turn" (Some false)
        (bool_at j [ "stdio"; "turn_started_after_inject" ]);
      check (option bool) "no composer/draft signal (auto-wake blocker)" (Some false)
        (bool_at j [ "composer_signal"; "present" ]);
      check (option bool) "schema invariants hold" (Some true)
        (bool_at j [ "schema"; "ok" ]);
      check (option bool) "control boundary invariants hold" (Some true)
        (bool_at j [ "boundary"; "ok" ])
  end

let () =
  run "codex-app-server-probe"
    [ ("t001", [ test_case "app-server injection + boundary invariants" `Slow test_probe_invariants ]) ]
