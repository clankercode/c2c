(* dev_codex_app_server_dogfood — foreground driver for the codex app-server
   launcher primitive (T002 tmux dogfood). NOT part of the public `c2c` CLI.

   Run INSIDE a tmux pane so the `codex --remote` frontend inherits the pane
   tty. It launches one authenticated app-server + one stock remote frontend as
   a single managed unit, prints SANITIZED lifecycle/state/pid evidence (never
   the token), supervises until the frontend exits (or a max wall-clock), then
   stops+reaps the whole unit.

   Env:
     C2C_DOGFOOD_CWD        working dir for the codex session   (default: cwd)
     C2C_DOGFOOD_STATE_DIR  instance dir for persisted state    (default: mkdtemp)
     C2C_DOGFOOD_MAX_S      max seconds to supervise before auto-stop (default: 60)
     CODEX_BIN              codex binary                         (default: codex) *)

module A = C2c_codex_app_server

let getenv_def k d = match Sys.getenv_opt k with Some v when String.trim v <> "" -> v | _ -> d
let now () = Unix.gettimeofday ()

(* The `codex --remote` frontend takes over the pane (alternate screen), so also
   mirror every log line to a file the harness can read for evidence. *)
let log_file = ref None
let log fmt =
  Printf.ksprintf
    (fun s ->
      let line = Printf.sprintf "[dogfood %.3f] %s\n" (now ()) s in
      print_string line; flush stdout;
      match !log_file with
      | Some oc -> output_string oc line; flush oc
      | None -> ())
    fmt

let mkdtemp () =
  let base = Filename.get_temp_dir_name () in
  let d = Filename.concat base (Printf.sprintf "c2c-t002-dogfood-%08x" (Random.bits ())) in
  Unix.mkdir d 0o700;
  d

let pid_str = function Some p -> string_of_int p | None -> "-"

let () =
  Random.self_init ();
  let cwd = getenv_def "C2C_DOGFOOD_CWD" (Sys.getcwd ()) in
  let state_dir = match Sys.getenv_opt "C2C_DOGFOOD_STATE_DIR" with
    | Some d when String.trim d <> "" -> d | _ -> mkdtemp () in
  let max_s = try float_of_string (getenv_def "C2C_DOGFOOD_MAX_S" "60") with _ -> 60.0 in
  let codex_bin = getenv_def "CODEX_BIN" "codex" in
  (try log_file := Some (open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o600
                           (Filename.concat state_dir "dogfood.log"))
   with _ -> ());
  let cfg =
    { (A.default_config ~instance_name:"dogfood" ~instance_dir:state_dir ~cwd) with
      A.codex_bin; readiness_timeout_s = 30.0 }
  in
  log "starting unit: codex_bin=%s cwd=%s state_dir=%s" codex_bin cwd state_dir;
  match A.start cfg with
  | Error d ->
      log "FAILED: %s" (Yojson.Safe.to_string (A.diagnostic_to_json d));
      exit 1
  | Ok h ->
      let p = A.persisted_of h in
      log "state=%s endpoint=%s server_pid=%s frontend_pid=%s token_env=%s sha256=%s..."
        (A.state_to_string (A.current_state h))
        (A.endpoint_uri (A.endpoint_of h))
        (pid_str p.A.server_pid) (pid_str p.A.frontend_pid)
        (A.token_env_var_of h)
        (String.sub (A.token_sha256_of h) 0 12);
      (* Install SIGTERM/SIGINT -> stop so a killed pane still reaps children. *)
      let stop_and_exit _ = log "signal -> stop"; A.stop h; exit 0 in
      Sys.set_signal Sys.sigterm (Sys.Signal_handle stop_and_exit);
      Sys.set_signal Sys.sigint (Sys.Signal_handle stop_and_exit);
      let deadline = now () +. max_s in
      let rec loop () =
        match A.supervise_step h with
        | A.Sv_running ->
            if now () > deadline then (log "max wall-clock reached -> stop"; A.stop h;
                                       log "final state=%s" (A.state_to_string (A.current_state h)))
            else (Unix.sleepf 0.5; loop ())
        | A.Sv_frontend_exited -> log "frontend exited -> server stopped; state=%s"
                                    (A.state_to_string (A.current_state h))
        | A.Sv_server_died -> log "app-server died -> unit torn down; state=%s"
                                (A.state_to_string (A.current_state h))
        | A.Sv_offline -> log "offline"
      in
      loop ();
      log "done"
