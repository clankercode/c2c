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
  degraded : bool;
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

let is_terminal = function
  | Ep.Sv_running -> false
  | Ep.Sv_frontend_exited | Ep.Sv_server_died | Ep.Sv_offline -> true

let run (d : deps) : outcome =
  d.register ();
  Fun.protect ~finally:(fun () -> try d.deregister () with _ -> ()) (fun () ->
      let start = d.now () in
      let thread = ref None in
      let passes = ref 0 in
      let last_discover = ref neg_infinity in
      (* Attempt frontend-thread discovery, throttled to [discover_interval_s]
         while we still have none. One `thread/loaded/list` socket per interval
         is cheap and self-heals if the operator opens a thread late. *)
      let maybe_discover () =
        if !thread = None && d.now () -. !last_discover >= d.discover_interval_s
        then begin
          last_discover := d.now ();
          match List.rev (try d.discover_threads () with _ -> []) with
          | tid :: _ when String.trim tid <> "" -> thread := Some tid
          | _ -> ()
        end
      in
      let mk_outcome final =
        { final; thread_id = !thread; passes = !passes; degraded = !thread = None }
      in
      let rec loop () =
        let step = try d.supervise_step () with _ -> Ep.Sv_offline in
        if is_terminal step then mk_outcome step
        else begin
          (* Sv_running: (re)discover the thread if needed, then drive one pass. *)
          maybe_discover ();
          (match !thread with
           | Some tid ->
               let cfg = build_autoturn_config d ~thread_id:tid in
               (* deliver_pass never raises for a delivery/protocol error — it
                  records the reason and returns a pass_outcome. Guard anyway so
                  a bug can never wedge the supervisor. *)
               (match (try Some (Autoturn.deliver_pass cfg) with _ -> None) with
                | Some po -> incr passes; (try d.on_pass po with _ -> ())
                | None -> ())
           | None -> ());
          if d.now () -. start >= d.max_wall_s then mk_outcome Ep.Sv_offline
          else (d.sleep d.poll_interval_s; loop ())
        end
      in
      loop ())
