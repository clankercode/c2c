(* c2c_codex_deliver_loop — lifecycle-bound supervisor loop that drives the
   proven T003 passive-ingress ({!C2c_codex_ingress}) + T007 auto-turn
   ({!C2c_codex_autoturn}) pipeline against a LIVE app-server-managed Codex
   session (P1.M1.E1 / B131).

   This is the production DRIVER the standalone dogfood harness
   (`dev_codex_autoturn_dogfood` / `scripts/codex-autoturn-*.py`) proved out,
   relocated INTO `c2c start codex`'s managed supervision. It does NOT
   reimplement any gate: provenance / DND / thread-status serialization / B098
   approval isolation all live in T003/T007; this module only DRIVES them with
   the live session's config and binds their lifetime to the attached session.

   Contract:
   - START ON ATTACH. {!run} registers the session's alias into the broker (so
     peers can route to it) and then, while the app-server unit is [Running],
     discovers the frontend's LOADED thread (`thread/loaded/list`) and runs a
     {!C2c_codex_autoturn.deliver_pass} each poll. A pass with an empty inbox +
     no active batch opens NO socket (T003/T007 are self-gating), so the idle
     cadence is cheap.
   - STOP ON EXIT. The loop returns as soon as {!C2c_codex_app_server.supervise_step}
     reports a terminal state (frontend exit / server death / offline). The
     broker registration is torn down in a [Fun.protect] finally — no orphaned
     loop, no leaked registration. The caller ({!C2c_codex_session}) then reaps
     the app-server unit.
   - FAIL-SAFE. If the frontend never loads a thread within the discovery
     window the loop keeps SUPERVISING (so the session stays alive and the
     app-server is still reaped on exit) but marks the outcome [degraded] — the
     caller surfaces a diagnosable state. It never crashes the session.

   Every field of {!deps} is an injected seam so the loop is unit-testable with
   NO live socket, NO real broker, and NO real signals — mirroring the T003/T007
   test style. Production wires the seams to the real clients + broker in
   {!C2c_codex_session}. *)

module Ep = C2c_codex_app_server

type deps = {
  broker_root : string;
  session_id : string;         (** broker inbox key (== managed instance name) *)
  managed_identity : string;   (** stable ledger identity (the routing alias) *)
  endpoint : Ep.endpoint;
  token_provider : unit -> string option;
      (** pulls the raw bearer token from launcher memory per-use *)
  inject_client : C2c_codex_ingress.client;
  turn_client : C2c_codex_autoturn.turn_client;
  discover_threads : unit -> string list;
      (** `thread/loaded/list` seam — the frontend's loaded thread(s), most-recent
          last. [[]] until the frontend has loaded one (or on error). *)
  supervise_step : unit -> Ep.supervise_result;
      (** one nonblocking app-server supervision step (wraps the live handle) *)
  session_active : unit -> bool;   (** app-server unit is [Running] *)
  is_dnd : unit -> bool;           (** broker DND for this alias *)
  register : unit -> unit;         (** publish the routable broker registration *)
  deregister : unit -> unit;       (** tear the registration down (idempotent) *)
  on_pass : C2c_codex_autoturn.pass_outcome -> unit;
      (** structured metrics/log sink — contains NO body/credential/composer *)
  on_degraded : bool -> unit;
      (** best-effort persisted-health sink for the degraded (no-thread) signal.
          Fired [true] at loop start (registered but no frontend thread
          discovered yet, so nothing actually delivers) and [false] the moment a
          thread is first discovered (healthy). Lets the caller persist the
          signal where `c2c doctor`/`c2c health` (which read persisted state) can
          see it, so they don't overclaim LIVE app-server delivery for a session
          whose deliver loop is degraded. Best-effort — the loop swallows any
          exception it raises and never lets it wedge supervision. *)
  on_thread_discovered : string -> unit;
      (** Fired exactly once for the first authoritative loaded thread. *)
  restart_requested : thread_id:string -> string option;
      (** Checked between passes. Production returns [true] only after the
          app-server thread is authoritatively Idle, or an explicit force. *)
  global_broker_root : string option;
      (** B141 (B137 follow-up): root of the machine-wide cross-repo sessions
          broker (canonically [~/.c2c/sessions/broker]). When [Some root] and
          this session's global inbox file already exists there, each running
          poll ALSO runs a plain {!C2c_codex_ingress.deliver_pass} against that
          inbox (same session key, same discovered thread), so cross-repo mail
          reaches the attached thread's model-visible history at arrival time.
          Inject-only — the T007 auto-turn stays scoped to repo-local broker
          mail, so cross-repo mail can never start a turn (fail-closed), and
          the pass respects the same session-active/DND gates. Delivering here
          (the launcher's supervision process, keyed to the thread it
          discovered) rather than in the frontend hook is what keeps the B137
          nested-codex theft vector closed: a nested codex inheriting the env
          marker never sees this path. [None] disables global delivery
          (sessions-broker root unresolvable). *)
  on_global_pass : C2c_codex_ingress.health -> unit;
      (** structured metrics/log sink for each global-inbox ingress pass —
          contains NO message content and NO credential (ingress health only).
          Best-effort: exceptions are swallowed. *)
  now : unit -> float;
  sleep : float -> unit;
  poll_interval_s : float;         (** main supervise+deliver cadence *)
  discover_interval_s : float;     (** min gap between `thread/loaded/list` probes *)
  max_wall_s : float;              (** [infinity] in prod; bounded in tests *)
}

type outcome = {
  final : Ep.supervise_result;   (** terminal supervision result on loop exit *)
  thread_id : string option;     (** the thread the loop drove, if discovered *)
  passes : int;                  (** number of deliver passes run *)
  global_passes : int;           (** B141: global (cross-repo) ingress passes run *)
  degraded : bool;               (** true iff no thread was ever discovered *)
  restart_executable : string option;
      (** validated executable path when launcher should stop and re-exec *)
}

(** Build the autoturn config the loop drives, for a discovered [thread_id].
    Reuses {!deps.inject_client}/{!deps.turn_client}/gates verbatim — no gate is
    reimplemented. Exposed for tests. *)
val build_autoturn_config : deps -> thread_id:string -> C2c_codex_autoturn.config

(** B141: build the plain ingress config for the global cross-repo inbox pass
    ([None] when {!deps.global_broker_root} is [None]). Same session key,
    thread, endpoint, and client as the repo pass; only the broker root — and
    therefore the ingress ledger — differs. Exposed for tests. *)
val build_global_ingress_config :
  deps -> thread_id:string -> C2c_codex_ingress.config option

(** Run the lifecycle-bound loop. Registers, drives ingress+auto-turn while
    attached, deregisters on exit. Blocking until a terminal supervision result
    (or [max_wall_s]). Never raises for a delivery/discovery error — those
    degrade to continued supervision. *)
val run : deps -> outcome
