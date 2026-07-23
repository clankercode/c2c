(* c2c_ws_connect_gate.ml — Cap concurrent in-flight WS connects (B275).
 *
 * Subscribe-daemon opens one reconnect loop per alias. Without a global
 * limit, an outage causes every alias to hammer /ws/subscribe in parallel
 * (FD/thread pressure client-side; thundering herd server-side).
 *
 * This gate only covers the connect/handshake phase — once a session is
 * established the slot is released so other aliases can connect.
 *)

open Lwt.Infix

let default_max_inflight = 8
let env_var = "C2C_RELAY_SUBSCRIBE_MAX_INFLIGHT"

(** Resolve the max in-flight connect cap.
    [env] overrides the process environment (tests). Invalid / empty /
    non-positive values fall back to [default_max_inflight]. *)
let parse_max_inflight ?env () =
  let raw =
    match env with
    | Some s -> s
    | None -> (match Sys.getenv_opt env_var with Some s -> s | None -> "")
  in
  match String.trim raw with
  | "" -> default_max_inflight
  | s ->
    (match int_of_string_opt s with
     | Some n when n >= 1 -> n
     | _ -> default_max_inflight)

type t = {
  capacity : int;
  mutable available : int;
  mutable in_flight : int;
  (* Peak in_flight observed since create — tests assert this ≤ capacity. *)
  mutable peak_in_flight : int;
  mutex : Lwt_mutex.t;
  cond : unit Lwt_condition.t;
}

let create ?max () =
  let capacity =
    match max with
    | Some m -> if m >= 1 then m else default_max_inflight
    | None -> parse_max_inflight ()
  in
  {
    capacity;
    available = capacity;
    in_flight = 0;
    peak_in_flight = 0;
    mutex = Lwt_mutex.create ();
    cond = Lwt_condition.create ();
  }

let capacity t = t.capacity
let in_flight t = t.in_flight
let peak_in_flight t = t.peak_in_flight

let acquire t =
  Lwt_mutex.lock t.mutex >>= fun () ->
  let rec loop () =
    if t.available > 0 then begin
      t.available <- t.available - 1;
      t.in_flight <- t.in_flight + 1;
      if t.in_flight > t.peak_in_flight then
        t.peak_in_flight <- t.in_flight;
      Lwt_mutex.unlock t.mutex;
      Lwt.return_unit
    end else
      (* wait re-locks mutex before returning *)
      Lwt_condition.wait ~mutex:t.mutex t.cond >>= loop
  in
  loop ()

let release t =
  Lwt_mutex.lock t.mutex >>= fun () ->
  if t.in_flight > 0 then t.in_flight <- t.in_flight - 1;
  if t.available < t.capacity then t.available <- t.available + 1;
  Lwt_condition.signal t.cond ();
  Lwt_mutex.unlock t.mutex;
  Lwt.return_unit

(** Run [f] while holding one in-flight slot. Releases on success, failure,
    or cancel ([Lwt.finalize]). *)
let with_slot t f =
  acquire t >>= fun () ->
  Lwt.finalize f (fun () -> release t)
