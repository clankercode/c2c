(* Read-only live probe for the OCaml Codex transport against a running daemon.
   This is intentionally a standalone executable rather than a normal test: it
   needs the operator's live Codex control socket.

   Usage:
     C2C_CODEX_CONTROL_SOCKET=~/.codex/app-server-control/app-server-control.sock \
       dune exec ./ocaml/test/dev_codex_transport_probe.exe
 *)

let () =
  let socket =
    match Sys.getenv_opt "C2C_CODEX_CONTROL_SOCKET" with
    | Some path -> path
    | None -> prerr_endline "missing C2C_CODEX_CONTROL_SOCKET"; exit 2
  in
  Unix.putenv "C2C_CODEX_INGRESS_LIVE" "1";
  let endpoint = { C2c_codex_app_server.transport = "unix"; host = socket; port = 0 } in
  let threads = C2c_codex_ingress.real_loaded_threads ~endpoint ~token:"" in
  if threads = [] then begin
    prerr_endline "daemon transport probe: no loaded threads (or protocol failure)";
    exit 1
  end;
  Printf.printf "daemon transport probe: initialize + thread/loaded/list OK; loaded_threads=%d\n%!"
    (List.length threads)
