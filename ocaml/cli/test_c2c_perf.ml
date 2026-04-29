(* test_c2c_perf.ml — startup-cost regression guard for `c2c --version`.

   Slate's #429 follow-up suggestion: the lazy-init fix dropped wall-clock
   from ~1700ms to ~8ms (200x). This test prevents silent regrowth — any
   future change that re-introduces eager work at module-load (a shell-out,
   a self-SHA, an unconditional broker.list_registrations on a hot path)
   would push the median wall-clock back over the threshold and fail here.

   Threshold: 200ms. Current local baseline ~8ms; trivial-binary OCaml
   floor ~2ms. 200ms is 25x our current and 8x faster than the regressed
   1700ms behavior — generous enough to absorb CI noise (cold disk cache,
   loaded runner) without losing the ability to catch a real regression.

   Methodology: 5 wall-clock-timed runs, take the median. Single-run timing
   is too noisy; mean is too sensitive to outliers. Median of 5 is stable
   under transient IO/scheduler hiccups. *)

let n_runs = 5
let threshold_ms = 200.0

(* dune test stanza copies/symlinks c2c.exe into the test's run directory
   via (deps c2c.exe), so a relative invocation works. *)
let c2c_binary = "./c2c.exe"

let measure_ms () =
  let t0 = Unix.gettimeofday () in
  let rc = Sys.command (c2c_binary ^ " --version > /dev/null 2>&1") in
  let t1 = Unix.gettimeofday () in
  if rc <> 0 then
    Alcotest.failf "%s --version returned non-zero exit code %d" c2c_binary rc;
  (t1 -. t0) *. 1000.0

let median arr =
  let copy = Array.copy arr in
  Array.sort compare copy;
  copy.(Array.length copy / 2)

let test_version_startup_under_threshold () =
  (* Warmup: prime any first-run filesystem cache effects so the measured
     runs are steady-state. *)
  let _ = measure_ms () in
  let runs = Array.init n_runs (fun _ -> measure_ms ()) in
  let med = median runs in
  let max_run = Array.fold_left Float.max neg_infinity runs in
  let min_run = Array.fold_left Float.min infinity runs in
  Printf.printf
    "[perf] c2c --version: median=%.1fms min=%.1fms max=%.1fms (n=%d, threshold=%.0fms)\n"
    med min_run max_run n_runs threshold_ms;
  Alcotest.(check bool)
    (Printf.sprintf
       "median %.1fms must be under %.0fms threshold (regression guard for #429 lazy-init)"
       med threshold_ms)
    true
    (med < threshold_ms)

let () =
  Alcotest.run "c2c_perf" [
    "startup", [
      Alcotest.test_case
        "c2c --version median-of-5 < 200ms"
        `Quick
        test_version_startup_under_threshold;
    ]
  ]
