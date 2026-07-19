module PP = Pow_policy

let test_cost_of_route () =
  Alcotest.(check int) "register cost" 10 (PP.cost_of_route "register");
  Alcotest.(check int) "send cost" 1 (PP.cost_of_route "send");
  Alcotest.(check int) "send_all cost" 1 (PP.cost_of_route "send_all");
  Alcotest.(check int) "send_room cost" 1 (PP.cost_of_route "send_room");
  Alcotest.(check int) "room-send cost" 1 (PP.cost_of_route "room-send");
  Alcotest.(check int) "poll cost" 0 (PP.cost_of_route "poll");
  Alcotest.(check int) "peek cost" 0 (PP.cost_of_route "peek");
  Alcotest.(check int) "heartbeat cost" 0 (PP.cost_of_route "heartbeat");
  Alcotest.(check int) "unknown cost" 0 (PP.cost_of_route "unknown")

let test_required_difficulty_grace_and_steps () =
  Alcotest.(check int) "under grace" 0
    (PP.required_difficulty ~accumulated_cost:19.0);
  Alcotest.(check int) "at grace" 0
    (PP.required_difficulty ~accumulated_cost:20.0);
  Alcotest.(check int) "first bucket starts above grace" 4
    (PP.required_difficulty ~accumulated_cost:20.1);
  Alcotest.(check int) "end of first bucket" 4
    (PP.required_difficulty ~accumulated_cost:30.0);
  Alcotest.(check int) "second bucket" 8
    (PP.required_difficulty ~accumulated_cost:30.1)

let test_required_difficulty_cap () =
  Alcotest.(check int) "difficulty capped at d_max" PP.d_max
    (PP.required_difficulty ~accumulated_cost:1000.0)

(* Pin d_max: it is the worst-case mint CPU a routine request ever pays.
   Bumping it is a CPU regression and must be a deliberate edit, not a drift.
   2^12 = ~4096 hashes keeps routine requests at low-ms while still deterring
   floods in aggregate.

   #71: the old headroom check here was [d_max <= 16], which was slack
   inherited from a [Pow.max_mint_iterations] of 2^24 and would have permitted
   a d_max that fails ~13% of honest mints. Derive it from the actual budget
   instead: a legitimate actor must have a >= 32x margin over 2^d_max, so
   P(mint finds no nonce) ~= e^-32 rather than the e^-1 = 37% a mean-sized
   budget would give (iterations-to-hit is geometric, not fixed). The mirror
   of this assertion lives in test_pow.ml on purpose — whichever of the two
   constants an author edits, a test in that file's own suite fires. *)
let test_d_max_bounds_mint_cpu () =
  Alcotest.(check int) "d_max pinned at 12 (low-ms worst-case mint)" 12 PP.d_max;
  Alcotest.(check bool)
    "d_max leaves >= 32x mint margin under Pow.max_mint_iterations" true
    ((1 lsl PP.d_max) * 32 <= Pow.max_mint_iterations)

let test_accumulator_records_decays_and_reads_difficulty () =
  let acc = PP.create () in
  Alcotest.(check int) "fresh actor needs no PoW" 0
    (PP.required_difficulty_for_actor acc ~actor_id:"actor" ~now:0.0);
  ignore (PP.record_route acc ~actor_id:"actor" ~route:"register" ~now:0.0);
  ignore (PP.record_route acc ~actor_id:"actor" ~route:"register" ~now:0.0);
  Alcotest.(check int) "grace after two registers" 0
    (PP.required_difficulty_for_actor acc ~actor_id:"actor" ~now:0.0);
  ignore (PP.record_route acc ~actor_id:"actor" ~route:"send" ~now:0.0);
  Alcotest.(check int) "one point over grace enters first bucket" 4
    (PP.required_difficulty_for_actor acc ~actor_id:"actor" ~now:0.0);
  Alcotest.(check int) "full window decay clears actor" 0
    (PP.required_difficulty_for_actor acc ~actor_id:"actor" ~now:PP.window_s)

let test_reads_do_not_extend_decay_window () =
  let acc = PP.create () in
  ignore (PP.record_cost acc ~actor_id:"actor" ~cost:100 ~now:0.0);
  Alcotest.(check int) "half-window read observes decayed difficulty" 12
    (PP.required_difficulty_for_actor acc ~actor_id:"actor"
       ~now:(PP.window_s /. 2.0));
  Alcotest.(check int) "full-window read still clears from original write" 0
    (PP.required_difficulty_for_actor acc ~actor_id:"actor" ~now:PP.window_s)

let () =
  Alcotest.run "pow_policy"
    [
      ( "policy",
        [
          Alcotest.test_case "cost_of_route" `Quick test_cost_of_route;
          Alcotest.test_case "required difficulty grace and steps" `Quick
            test_required_difficulty_grace_and_steps;
          Alcotest.test_case "required difficulty cap" `Quick
            test_required_difficulty_cap;
          Alcotest.test_case "d_max bounds mint cpu" `Quick
            test_d_max_bounds_mint_cpu;
          Alcotest.test_case "accumulator records and decays" `Quick
            test_accumulator_records_decays_and_reads_difficulty;
          Alcotest.test_case "reads do not extend decay window" `Quick
            test_reads_do_not_extend_decay_window;
        ] );
    ]
