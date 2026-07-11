(* dev_codex_autoturn_dogfood — standalone foreground driver for the T007 tmux
   dogfood. NOT part of the public `c2c` CLI. Runs the REAL auto-turn dispatcher
   (C2c_codex_autoturn with real inject + real turn clients, under
   C2C_CODEX_INGRESS_LIVE=1) against a live authenticated `codex app-server`
   whose lifecycle + thread the Python orchestrator
   (scripts/codex-autoturn-e2e.py) owns.

   Reads its target from the environment (the launcher-provided seam):
     C2C_MCP_BROKER_ROOT       broker root (inbox source of truth)
     C2C_CODEX_INGRESS_SESSION session id (inbox key)
     C2C_CODEX_INGRESS_ENDPOINT ws://host:port
     C2C_CODEX_INGRESS_TOKEN   raw bearer token (never persisted by the adapter)
     C2C_CODEX_INGRESS_THREAD  loaded thread id
     C2C_CODEX_INGRESS_LIVE=1  unlocks the real socket clients
     C2C_CODEX_TURN_MODEL / C2C_CODEX_TURN_APPROVAL_POLICY (optional pins)
   argv[1] = number of dispatcher passes to run (default 1).

   Prints one JSON line per pass: the pass_outcome (queued reason, turn id,
   batch key + ordered message ids, completed/reconciled batch, counts) — NEVER
   message bodies or credentials. *)

module A = C2c_codex_autoturn
module I = C2c_codex_ingress

let getenv_exn k =
  try Sys.getenv k with Not_found -> (Printf.eprintf "missing env %s\n%!" k; exit 2)

let parse_endpoint s : C2c_codex_app_server.endpoint =
  let s = if String.length s >= 5 && String.sub s 0 5 = "ws://" then String.sub s 5 (String.length s - 5) else s in
  match String.split_on_char ':' s with
  | [ host; port ] -> { transport = "ws"; host; port = int_of_string port }
  | _ -> failwith ("bad endpoint: " ^ s)

let () =
  let passes = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 1 in
  let broker_root = getenv_exn "C2C_MCP_BROKER_ROOT" in
  let session_id = getenv_exn "C2C_CODEX_INGRESS_SESSION" in
  let endpoint = parse_endpoint (getenv_exn "C2C_CODEX_INGRESS_ENDPOINT") in
  let thread_id = getenv_exn "C2C_CODEX_INGRESS_THREAD" in
  let token = getenv_exn "C2C_CODEX_INGRESS_TOKEN" in
  let inject_client = I.real_client () in
  let ingress_cfg =
    I.default_config ~broker_root ~session_id ~managed_identity:"autoturn-dogfood"
      ~endpoint ~thread_id ~token_provider:(fun () -> Some token) ~client:inject_client
  in
  let turn_client = A.real_turn_client () in
  let cfg =
    A.default_config ~ingress_cfg ~turn_client
      ~session_active:(fun () -> true) ~is_dnd:(fun () -> false)
  in
  for p = 1 to passes do
    let o = A.deliver_pass cfg in
    Printf.printf "PASS %d %s\n%!" p (Yojson.Safe.to_string (A.pass_outcome_to_json o))
  done
