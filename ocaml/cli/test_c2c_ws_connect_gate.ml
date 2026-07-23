(* B275: cap concurrent in-flight /ws/subscribe connects (subscribe-daemon). *)

open Lwt.Infix
open Alcotest

let test_parse_max_inflight () =
  check int "default when unset" 8 (C2c_ws_connect_gate.parse_max_inflight ~env:"" ());
  check int "default when garbage" 8
    (C2c_ws_connect_gate.parse_max_inflight ~env:"nope" ());
  check int "default when zero" 8 (C2c_ws_connect_gate.parse_max_inflight ~env:"0" ());
  check int "default when negative" 8
    (C2c_ws_connect_gate.parse_max_inflight ~env:"-3" ());
  check int "honours positive" 4 (C2c_ws_connect_gate.parse_max_inflight ~env:"4" ());
  check int "trims whitespace" 6
    (C2c_ws_connect_gate.parse_max_inflight ~env:"  6  " ());
  check int "default constant" C2c_ws_connect_gate.default_max_inflight
    (C2c_ws_connect_gate.parse_max_inflight ~env:"" ())

let test_create_capacity () =
  let g = C2c_ws_connect_gate.create ~max:3 () in
  check int "capacity" 3 (C2c_ws_connect_gate.capacity g);
  check int "in_flight starts at 0" 0 (C2c_ws_connect_gate.in_flight g);
  let g_default = C2c_ws_connect_gate.create ~max:0 () in
  check int "invalid max falls back to default" C2c_ws_connect_gate.default_max_inflight
    (C2c_ws_connect_gate.capacity g_default)

(** Simulate N aliases racing a hung peer: each holds a slot for [hold_s]
    (like a TCP connect that never completes handshake). Peak in-flight must
    never exceed the cap, and every worker must eventually complete. *)
let test_peak_never_exceeds_cap () =
  let cap = 3 in
  let n_aliases = 20 in
  let hold_s = 0.05 in
  let gate = C2c_ws_connect_gate.create ~max:cap () in
  let finished = ref 0 in
  let worker _i =
    C2c_ws_connect_gate.with_slot gate (fun () ->
        (* Observe mid-hold; pure race detector is peak_in_flight. *)
        let cur = C2c_ws_connect_gate.in_flight gate in
        if cur > cap then
          failwith (Printf.sprintf "in_flight %d > cap %d" cur cap);
        Lwt_unix.sleep hold_s >>= fun () ->
        incr finished;
        Lwt.return_unit)
  in
  Lwt_main.run (
    List.init n_aliases worker |> Lwt.join
  );
  check int "all workers finished" n_aliases !finished;
  check bool "peak ≤ cap"
    true
    (C2c_ws_connect_gate.peak_in_flight gate <= cap);
  check int "peak equals cap under load" cap (C2c_ws_connect_gate.peak_in_flight gate);
  check int "in_flight returns to 0" 0 (C2c_ws_connect_gate.in_flight gate)

let test_release_on_failure () =
  let gate = C2c_ws_connect_gate.create ~max:1 () in
  let saw_fail = ref false in
  Lwt_main.run (
    Lwt.catch
      (fun () ->
         C2c_ws_connect_gate.with_slot gate (fun () ->
             Lwt.fail_with "boom")
         >>= fun () -> Lwt.return_unit)
      (fun _ -> saw_fail := true; Lwt.return_unit)
    >>= fun () ->
    (* Slot must be free for the next acquirer. *)
    C2c_ws_connect_gate.with_slot gate (fun () ->
        check int "in_flight after prior failure" 1
          (C2c_ws_connect_gate.in_flight gate);
        Lwt.return_unit)
  );
  check bool "failure propagated" true !saw_fail;
  check int "in_flight after recovery" 0 (C2c_ws_connect_gate.in_flight gate)

let test_release_on_cancel () =
  (* Lwt.catch does NOT catch Lwt.Canceled — use try_bind / state probe. *)
  let gate = C2c_ws_connect_gate.create ~max:1 () in
  Lwt_main.run (
    let p =
      C2c_ws_connect_gate.with_slot gate (fun () ->
          Lwt_unix.sleep 10.0)
    in
    (* Let acquire complete and enter the long sleep (hung peer). *)
    Lwt_unix.sleep 0.02 >>= fun () ->
    check int "held during work" 1 (C2c_ws_connect_gate.in_flight gate);
    Lwt.cancel p;
    (* Give finalize's release a turn; do not bind on [p] via Lwt.catch. *)
    Lwt_unix.sleep 0.05 >>= fun () ->
    check int "released after cancel" 0 (C2c_ws_connect_gate.in_flight gate);
    (match Lwt.state p with
     | Lwt.Fail Lwt.Canceled -> ()
     | Lwt.Fail exn ->
       failwith ("expected Canceled, got " ^ Printexc.to_string exn)
     | Lwt.Return _ -> failwith "expected Canceled, got Return"
     | Lwt.Sleep -> failwith "expected Canceled, still Sleep");
    (* Another waiter can proceed — proves the slot was freed. *)
    C2c_ws_connect_gate.with_slot gate (fun () -> Lwt.return_unit)
  )

let test_serializes_beyond_cap () =
  (* cap=1 → workers run strictly one at a time (order preserved by queue). *)
  let gate = C2c_ws_connect_gate.create ~max:1 () in
  let order = ref [] in
  let worker i =
    C2c_ws_connect_gate.with_slot gate (fun () ->
        order := i :: !order;
        Lwt_unix.sleep 0.02 >>= fun () ->
        Lwt.return_unit)
  in
  Lwt_main.run (Lwt.join [ worker 1; worker 2; worker 3 ]);
  check int "peak is 1" 1 (C2c_ws_connect_gate.peak_in_flight gate);
  check int "three completions" 3 (List.length !order)

let () =
  run "c2c_ws_connect_gate"
    [
      ( "parse",
        [ test_case "parse_max_inflight" `Quick test_parse_max_inflight;
          test_case "create capacity" `Quick test_create_capacity ] );
      ( "concurrency",
        [ test_case "peak never exceeds cap (N hung peers)" `Quick
            test_peak_never_exceeds_cap;
          test_case "release on failure" `Quick test_release_on_failure;
          test_case "release on cancel" `Quick test_release_on_cancel;
          test_case "serializes beyond cap" `Quick test_serializes_beyond_cap ] );
    ]
