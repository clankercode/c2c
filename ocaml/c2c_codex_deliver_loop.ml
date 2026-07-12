(* c2c_codex_deliver_loop — see .mli for the full contract.

   Relocates the standalone T007 dogfood driver into the managed
   `c2c start codex` supervisor: register -> (discover thread + drive
   ingress/auto-turn while attached) -> deregister, bound to the app-server
   unit's lifetime. Drives T003/T007 verbatim — no gate reimplemented here. *)

module Ep = C2c_codex_app_server
module Ingress = C2c_codex_ingress
module Autoturn = C2c_codex_autoturn

type deps = {
  broker_root : string;
  session_id : string;
  managed_identity : string;
  endpoint : Ep.endpoint;
  token_provider : unit -> string option;
  inject_client : Ingress.client;
  turn_client : Autoturn.turn_client;
  discover_threads : unit -> string list;
  supervise_step : unit -> Ep.supervise_result;
  session_active : unit -> bool;
  is_dnd : unit -> bool;
  register : unit -> unit;
  deregister : unit -> unit;
  on_pass : Autoturn.pass_outcome -> unit;
  on_degraded : bool -> unit;
  on_thread_discovered : string -> unit;
  restart_requested : thread_id:string -> string option;
  global_broker_root : string option;
  on_global_pass : Ingress.health -> unit;
  now : unit -> float;
  sleep : float -> unit;
  poll_interval_s : float;
  discover_interval_s : float;
  max_wall_s : float;
}

type outcome = {
  final : Ep.supervise_result;
  thread_id : string option;
  passes : int;
  global_passes : int;
  degraded : bool;
  restart_executable : string option;
}

let build_autoturn_config (d : deps) ~(thread_id : string) : Autoturn.config =
  let ingress_cfg =
    Ingress.default_config
      ~broker_root:d.broker_root
      ~session_id:d.session_id
      ~managed_identity:d.managed_identity
      ~endpoint:d.endpoint
      ~thread_id
      ~token_provider:d.token_provider
      ~client:d.inject_client
  in
  Autoturn.default_config
    ~ingress_cfg
    ~turn_client:d.turn_client
    ~session_active:d.session_active
    ~is_dnd:d.is_dnd

(* B141: plain T003 ingress config for the machine-wide cross-repo sessions
   broker — same session key, same attached thread, same client/token; only
   the broker root differs (so the ingress ledger, which lives under the
   broker root, is naturally separate). Deliberately NOT wrapped in the T007
   auto-turn: the sanctioned message-can-start-a-turn effect covers repo-local
   broker mail only, so cross-repo mail is inject-only (model-visible on the
   next turn) — fail-closed. *)
let build_global_ingress_config (d : deps) ~(thread_id : string) :
    Ingress.config option =
  match d.global_broker_root with
  | None -> None
  | Some root ->
      Some
        (Ingress.default_config
           ~broker_root:root
           ~session_id:d.session_id
           ~managed_identity:d.managed_identity
           ~endpoint:d.endpoint
           ~thread_id
           ~token_provider:d.token_provider
           ~client:d.inject_client)

(* Same stat the codex hook / kimi notifier use — the global pass only runs
   when this session's cross-repo inbox file already exists, so an idle
   session never creates broker artifacts in the sessions root. *)
let global_inbox_exists ~root ~session_id =
  Sys.file_exists (Filename.concat root (session_id ^ ".inbox.json"))

let is_terminal = function
  | Ep.Sv_running -> false
  | Ep.Sv_frontend_exited | Ep.Sv_server_died | Ep.Sv_offline -> true

let run (d : deps) : outcome =
  d.register ();
  let report_degraded b = try d.on_degraded b with _ -> () in
  (* Registered but no frontend thread discovered yet — nothing actually
     delivers until a thread loads. Persist the degraded signal immediately so
     the doctor/health (which read persisted state) never overclaim LIVE
     app-server delivery during the discovery window, nor for a session that
     never loads a thread. Flipped to [false] the moment a thread is found. *)
  report_degraded true;
  Fun.protect ~finally:(fun () -> try d.deregister () with _ -> ()) (fun () ->
      let start = d.now () in
      let thread = ref None in
      let passes = ref 0 in
      let global_passes = ref 0 in
      let last_discover = ref neg_infinity in
      (* Attempt frontend-thread discovery, throttled to [discover_interval_s]
         while we still have none. One `thread/loaded/list` socket per interval
         is cheap and self-heals if the operator opens a thread late. *)
      let maybe_discover () =
        if !thread = None && d.now () -. !last_discover >= d.discover_interval_s
        then begin
          last_discover := d.now ();
          match List.rev (try d.discover_threads () with _ -> []) with
          | tid :: _ when String.trim tid <> "" ->
              (* First thread discovered — the loop can now inject/deliver. This
                 None -> Some transition fires exactly once (the [!thread = None]
                 guard above), so [on_degraded false] is emitted once, on the
                 healthy transition. *)
              thread := Some tid;
              (try d.on_thread_discovered tid with _ -> ());
              report_degraded false
          | _ -> ()
        end
      in
      let mk_outcome ?restart_executable final =
        { final; thread_id = !thread; passes = !passes;
          global_passes = !global_passes; degraded = !thread = None;
          restart_executable }
      in
      (* B141: deliver the session's GLOBAL (cross-repo sessions-broker) inbox
         too. This runs in the LAUNCHER's supervision process against the
         thread it discovered itself, so — unlike the frontend hook, which
         B137 made identity-only — a nested codex that inherited the
         C2C_CODEX_APPSERVER_SESSION env marker can never see or steal this
         mail. Inject-only (no auto-turn), and gated on the same
         session-active/DND checks the T007 pass applies before injecting. *)
      let run_global_pass ~thread_id =
        match d.global_broker_root with
        | Some root
          when global_inbox_exists ~root ~session_id:d.session_id
               && (try d.session_active () with _ -> false)
               && not (try d.is_dnd () with _ -> true) -> (
            match build_global_ingress_config d ~thread_id with
            | Some gcfg -> (
                match (try Some (Ingress.deliver_pass gcfg) with _ -> None) with
                | Some gh ->
                    incr global_passes;
                    (try d.on_global_pass gh with _ -> ())
                | None -> ())
            | None -> ())
        | _ -> ()
      in
      let rec loop () =
        let step = try d.supervise_step () with _ -> Ep.Sv_offline in
        if is_terminal step then mk_outcome step
        else begin
          (* Sv_running: (re)discover the thread if needed, then drive one pass. *)
          maybe_discover ();
          (match !thread with
           | Some tid ->
               (match (try d.restart_requested ~thread_id:tid with _ -> None) with
               | Some executable ->
                 mk_outcome ~restart_executable:executable Ep.Sv_offline
               | None -> begin
               let cfg = build_autoturn_config d ~thread_id:tid in
               (* deliver_pass never raises for a delivery/protocol error — it
                  records the reason and returns a pass_outcome. Guard anyway so
                  a bug can never wedge the supervisor. *)
               (match (try Some (Autoturn.deliver_pass cfg) with _ -> None) with
                | Some po -> incr passes; (try d.on_pass po with _ -> ())
                | None -> ());
               run_global_pass ~thread_id:tid;
               if d.now () -. start >= d.max_wall_s then mk_outcome Ep.Sv_offline
               else (d.sleep d.poll_interval_s; loop ())
               end)
           | None ->
               if d.now () -. start >= d.max_wall_s then mk_outcome Ep.Sv_offline
               else (d.sleep d.poll_interval_s; loop ()))
        end
      in
      loop ())
