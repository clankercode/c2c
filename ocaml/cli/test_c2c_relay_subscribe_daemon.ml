(** B273: pure-function tests for subscribe-daemon reconnect policy.
    - full-jitter delay bounds
    - backoff growth / cap
    - stable-session reset (duration + keepalive)
    - non-reset on short flicker
    - daemon-level circuit breaker cool-down
*)

module D = C2c_relay_subscribe_daemon
module C = D.Reconnect_circuit

let eps = 1e-9

let test_full_jitter_bounds () =
  let base = 16.0 in
  let max_b = D.reconnect_backoff_max in
  (* Injected rand: always return 0 → min delay *)
  let d0 = D.full_jitter_delay ~base ~max_backoff:max_b ~rand:(fun _ -> 0.0) () in
  Alcotest.(check (float eps)) "rand 0 -> 0" 0.0 d0;
  (* rand = identity on the cap argument → max delay = min(base, max) *)
  let dmax =
    D.full_jitter_delay ~base ~max_backoff:max_b ~rand:(fun x -> x -. 1e-12) ()
  in
  Alcotest.(check bool) "near-cap < base" true (dmax < base);
  Alcotest.(check bool) "near-cap >= 0" true (dmax >= 0.0);
  (* Cap argument passed to rand is min(base, max) *)
  let seen = ref None in
  let _ =
    D.full_jitter_delay ~base:100.0 ~max_backoff:30.0
      ~rand:(fun x -> seen := Some x; 0.0) ()
  in
  Alcotest.(check (option (float eps))) "cap is max_backoff when base>max"
    (Some 30.0) !seen;
  let seen2 = ref None in
  let _ =
    D.full_jitter_delay ~base:8.0 ~max_backoff:30.0
      ~rand:(fun x -> seen2 := Some x; 0.0) ()
  in
  Alcotest.(check (option (float eps))) "cap is base when base<max"
    (Some 8.0) !seen2

let test_full_jitter_zero_and_negative_base () =
  let d =
    D.full_jitter_delay ~base:0.0 ~max_backoff:30.0
      ~rand:(fun _ -> failwith "rand must not be called") ()
  in
  Alcotest.(check (float eps)) "base 0 -> 0" 0.0 d;
  let dneg =
    D.full_jitter_delay ~base:(-5.0) ~max_backoff:30.0
      ~rand:(fun _ -> failwith "rand must not be called") ()
  in
  Alcotest.(check (float eps)) "negative base -> 0" 0.0 dneg

let test_grow_backoff_doubles_and_caps () =
  let g1 =
    D.grow_backoff ~base:D.reconnect_backoff_initial
      ~max_backoff:D.reconnect_backoff_max
  in
  Alcotest.(check (float eps)) "1 -> 2" 2.0 g1;
  let g2 = D.grow_backoff ~base:g1 ~max_backoff:D.reconnect_backoff_max in
  Alcotest.(check (float eps)) "2 -> 4" 4.0 g2;
  let at_cap =
    D.grow_backoff ~base:D.reconnect_backoff_max
      ~max_backoff:D.reconnect_backoff_max
  in
  Alcotest.(check (float eps)) "at cap stays cap" D.reconnect_backoff_max at_cap;
  let near =
    D.grow_backoff ~base:20.0 ~max_backoff:D.reconnect_backoff_max
  in
  Alcotest.(check (float eps)) "20*2 capped at 30" 30.0 near

let test_should_reset_on_stable_duration () =
  let reset =
    D.should_reset_backoff ~session_duration_s:45.0 ~got_keepalive:false
      ~stable_secs:45.0 ()
  in
  Alcotest.(check bool) "duration == stable_secs resets" true reset;
  let reset_over =
    D.should_reset_backoff ~session_duration_s:60.0 ~got_keepalive:false
      ~stable_secs:45.0 ()
  in
  Alcotest.(check bool) "duration > stable_secs resets" true reset_over

let test_should_reset_on_keepalive () =
  let reset =
    D.should_reset_backoff ~session_duration_s:1.0 ~got_keepalive:true
      ~stable_secs:45.0 ()
  in
  Alcotest.(check bool) "keepalive alone resets" true reset

let test_no_reset_on_short_flicker () =
  (* Multi-minute crash-loop flicker: connect for a few seconds, no keepalive. *)
  let reset =
    D.should_reset_backoff ~session_duration_s:8.0 ~got_keepalive:false
      ~stable_secs:45.0 ()
  in
  Alcotest.(check bool) "8s flicker does not reset" false reset;
  let reset_zero =
    D.should_reset_backoff ~session_duration_s:0.0 ~got_keepalive:false
      ~stable_secs:45.0 ()
  in
  Alcotest.(check bool) "zero-duration does not reset" false reset_zero;
  let reset_under =
    D.should_reset_backoff ~session_duration_s:44.9 ~got_keepalive:false
      ~stable_secs:45.0 ()
  in
  Alcotest.(check bool) "just under threshold does not reset" false reset_under

let test_flicker_keeps_growing_base () =
  (* Simulate: start at initial, fail without stable, grow repeatedly. *)
  let rec grow n base =
    if n <= 0 then base
    else
      let base' =
        D.grow_backoff ~base ~max_backoff:D.reconnect_backoff_max
      in
      grow (n - 1) base'
  in
  let after_5 = grow 5 D.reconnect_backoff_initial in
  Alcotest.(check (float eps)) "5 grows: 1->2->4->8->16->30(cap via 32)" 30.0 after_5;
  (* After each unstable end, delay is jittered from current base — never
     forced back to 1.0 without a stable session. *)
  let delay =
    D.full_jitter_delay ~base:after_5 ~max_backoff:D.reconnect_backoff_max
      ~rand:(fun x -> x *. 0.5) ()
  in
  Alcotest.(check bool) "post-flicker delay uses high base" true (delay >= 10.0);
  Alcotest.(check bool) "post-flicker delay <= max" true
    (delay <= D.reconnect_backoff_max)

let test_circuit_trips_after_threshold () =
  let c = C.create () in
  let now = 1000.0 in
  for i = 1 to C.failure_threshold - 1 do
    C.record_failure c ~now:(now +. float_of_int i *. 0.1)
  done;
  Alcotest.(check bool) "below threshold still closed" false
    (C.is_open c ~now:(now +. 1.0));
  C.record_failure c ~now:(now +. 1.0);
  Alcotest.(check bool) "at threshold circuit opens" true
    (C.is_open c ~now:(now +. 1.0));
  let rem = C.remaining_cool c ~now:(now +. 1.0) in
  Alcotest.(check bool) "cool-down roughly cool_down_s" true
    (rem > C.cool_down_s -. 0.01 && rem <= C.cool_down_s +. 0.01)

let test_circuit_expires_after_cool_down () =
  let c = C.create () in
  let now = 2000.0 in
  for i = 1 to C.failure_threshold do
    C.record_failure c ~now
  done;
  Alcotest.(check bool) "open immediately" true (C.is_open c ~now);
  let later = now +. C.cool_down_s +. 0.01 in
  Alcotest.(check bool) "closed after cool-down" false (C.is_open c ~now:later);
  Alcotest.(check (float eps)) "remaining is 0 after expiry" 0.0
    (C.remaining_cool c ~now:later)

let test_circuit_window_prunes_old_failures () =
  let c = C.create () in
  let t0 = 3000.0 in
  (* Spread failures outside the window so they never accumulate. *)
  for i = 0 to C.failure_threshold + 2 do
    C.record_failure c ~now:(t0 +. float_of_int i *. (C.window_s +. 1.0))
  done;
  let last = t0 +. float_of_int (C.failure_threshold + 2) *. (C.window_s +. 1.0) in
  Alcotest.(check bool) "spaced failures never trip" false (C.is_open c ~now:last)

let test_reconnect_wait_takes_max_of_jitter_and_circuit () =
  (* Integration-shaped: when circuit is open, wait >= circuit remaining even
     if per-alias jitter is small. *)
  let c = C.create () in
  let now = 4000.0 in
  for _ = 1 to C.failure_threshold do
    C.record_failure c ~now
  done;
  let base = D.reconnect_backoff_initial in
  let delay =
    D.full_jitter_delay ~base ~max_backoff:D.reconnect_backoff_max
      ~rand:(fun _ -> 0.1) ()
  in
  let circuit_wait = C.remaining_cool c ~now in
  let wait = Float.max delay circuit_wait in
  Alcotest.(check bool) "circuit dominates small jitter" true (wait >= 29.0);
  Alcotest.(check bool) "wait is circuit cool-down" true
    (abs_float (wait -. C.cool_down_s) < 0.01)

let () =
  Alcotest.run "c2c_relay_subscribe_daemon_b273"
    [
      ( "jitter",
        [
          Alcotest.test_case "full_jitter_bounds" `Quick test_full_jitter_bounds;
          Alcotest.test_case "full_jitter_zero_base" `Quick
            test_full_jitter_zero_and_negative_base;
        ] );
      ( "backoff",
        [
          Alcotest.test_case "grow_doubles_and_caps" `Quick
            test_grow_backoff_doubles_and_caps;
          Alcotest.test_case "reset_on_stable_duration" `Quick
            test_should_reset_on_stable_duration;
          Alcotest.test_case "reset_on_keepalive" `Quick
            test_should_reset_on_keepalive;
          Alcotest.test_case "no_reset_on_flicker" `Quick
            test_no_reset_on_short_flicker;
          Alcotest.test_case "flicker_keeps_high_base" `Quick
            test_flicker_keeps_growing_base;
        ] );
      ( "circuit",
        [
          Alcotest.test_case "trips_after_threshold" `Quick
            test_circuit_trips_after_threshold;
          Alcotest.test_case "expires_after_cool_down" `Quick
            test_circuit_expires_after_cool_down;
          Alcotest.test_case "window_prunes_old" `Quick
            test_circuit_window_prunes_old_failures;
          Alcotest.test_case "wait_max_jitter_circuit" `Quick
            test_reconnect_wait_takes_max_of_jitter_and_circuit;
        ] );
    ]
