(* c2c_inbox_hook — PostToolUse hook for c2c auto-delivery in Claude Code
 *
 * Self-regulating runtime: if the hook exits in < MIN_RUNTIME_MS, we sleep
 * the remainder to prevent Node.js ECHILD race condition (kernel reaps
 * zombie before waitpid is called on fast-exiting children).
 *
 * Env vars:
 *   C2C_MCP_SESSION_ID   — broker session id
 *   C2C_MCP_BROKER_ROOT  — absolute path to broker root dir
 *
 * Exit codes:
 *   0 — success (even if no messages)
 *   1 — error (missing env, file error, etc.)
 *)

let min_runtime_ms = 10.0

let () =
  let session_id =
    try Sys.getenv "C2C_MCP_SESSION_ID" with Not_found -> ""
  in
  let broker_root =
    try Sys.getenv "C2C_MCP_BROKER_ROOT" with Not_found -> ""
  in
  (* Fast path: if not configured, exit silently *)
  if session_id = "" || broker_root = "" then exit 0;

  let start_time = Unix.gettimeofday () in

  try
    let broker = C2c_mcp.Broker.create ~root:broker_root in
    let messages = C2c_mcp.Broker.drain_inbox broker ~session_id in

    (* Output messages in c2c event envelope format *)
    List.iter
      (fun (m : C2c_mcp.message) ->
        Printf.printf "<c2c event=\"message\" from=\"%s\" alias=\"%s\" action_after=\"continue\">%s</c2c>\n"
          m.from_alias m.to_alias m.content)
      messages;

    (* Self-regulating runtime: sleep if we finished too quickly *)
    let elapsed_ms = (Unix.gettimeofday () -. start_time) *. 1000.0 in
    if elapsed_ms < min_runtime_ms then
      let remaining_ms = min_runtime_ms -. elapsed_ms in
      ignore (Lwt_main.run (Lwt_unix.sleep (remaining_ms /. 1000.0)));

    exit 0
  with e ->
    prerr_endline (Printexc.to_string e);
    exit 1
