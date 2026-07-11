(* dev_codex_ingress_dogfood — standalone foreground driver for the T003 tmux
   dogfood. NOT part of the public `c2c` CLI. It exercises the REAL app-server
   injection path (C2c_codex_ingress.real_client under C2C_CODEX_INGRESS_LIVE=1)
   against a live, authenticated `codex app-server` endpoint whose lifecycle +
   thread the Python orchestrator (scripts/codex-ingress-dogfood.py) owns.

   Reads its target from the environment (the launcher-provided seam):
     C2C_MCP_BROKER_ROOT      broker root (inbox source of truth)
     C2C_CODEX_INGRESS_SESSION session id (inbox key)
     C2C_CODEX_INGRESS_ENDPOINT ws://host:port
     C2C_CODEX_INGRESS_TOKEN  raw bearer token (never persisted by the adapter)
     C2C_CODEX_INGRESS_THREAD loaded thread id to inject into
     C2C_CODEX_INGRESS_LIVE=1 unlocks the real socket client
   argv[1] = number of delivery passes to run (default 1). *)

module I = C2c_codex_ingress

let getenv_exn k =
  try Sys.getenv k with Not_found -> (Printf.eprintf "missing env %s\n%!" k; exit 2)

let parse_endpoint s : C2c_codex_app_server.endpoint =
  let s = match String.length s >= 5 && String.sub s 0 5 = "ws://" with true -> String.sub s 5 (String.length s - 5) | false -> s in
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
  (* Count REAL inject calls so the dogfood shows same-message_id retries make
     ZERO further injections (deterministic one-model-visible-item evidence). *)
  let base = I.real_client () in
  let inject_calls = ref 0 in
  let client =
    { base with
      inject_items =
        (fun ~endpoint ~token ~thread_id ~message_id ~items ->
          incr inject_calls;
          base.inject_items ~endpoint ~token ~thread_id ~message_id ~items) }
  in
  let cfg =
    I.default_config ~broker_root ~session_id ~managed_identity:"dogfood-unit"
      ~endpoint ~thread_id ~token_provider:(fun () -> Some token) ~client
  in
  for p = 1 to passes do
    inject_calls := 0;
    let h = I.deliver_pass cfg in
    (* per-message ledger states from the current inbox *)
    let b = C2c_mcp.Broker.create ~root:broker_root in
    let states =
      C2c_mcp.Broker.read_inbox b ~session_id
      |> List.filter_map (fun (m : C2c_mcp.message) ->
             match m.message_id with
             | Some mid ->
                 Some
                   (`Assoc
                      [ ("message_id", `String mid);
                        ( "state",
                          `String
                            (match I.ledger_state cfg ~message_id:mid with
                             | Some s -> I.delivery_state_to_string s
                             | None -> "none") ) ])
             | None -> None)
    in
    Printf.printf "PASS %d real_inject_calls=%d health=%s states=%s\n%!" p !inject_calls
      (Yojson.Safe.to_string (I.health_to_json h))
      (Yojson.Safe.to_string (`List states))
  done
