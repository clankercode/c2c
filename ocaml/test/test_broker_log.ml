(* test_broker_log.ml — #61 size-based rotation for <broker_root>/broker.log.

   Covers:
   - rotation at the configured byte threshold
   - the ring shifts correctly through multiple rotations and stays bounded
   - concurrent writers (forked subprocesses) cannot tear or skip rotation;
     total event count + JSON-parse-success on every recovered line. *)

open Alcotest

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base (Printf.sprintf "c2c-broker-log-%06x" (Random.bits ()))
  in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) |> ignore)
    (fun () -> f dir)

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let buf = Buffer.create 256 in
      (try
         while true do
           Buffer.add_channel buf ic 4096
         done
       with End_of_file -> ());
      Buffer.contents buf)

let count_lines s =
  let n = ref 0 in
  String.iter (fun c -> if c = '\n' then incr n) s;
  !n

let with_env_int name value f =
  let prev = Sys.getenv_opt name in
  Unix.putenv name (string_of_int value);
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | None ->
        (* OCaml's Unix has no unsetenv pre-4.13; setting empty string is
           close enough for these tests since broker_log treats <=0 as
           "fall back to default". *)
        Unix.putenv name ""
      | Some v -> Unix.putenv name v)
    f

let make_event i =
  `Assoc
    [ ("ts", `Float (float_of_int i))
    ; ("event", `String "test_event")
    ; ("seq", `Int i)
    ; ("payload", `String (String.make 200 'x'))
    ]

(* AC1: cross the cap once → live log resets, .1 carries the older content. *)
let test_rotates_at_threshold () =
  with_temp_dir (fun dir ->
      with_env_int "C2C_BROKER_LOG_MAX_BYTES" 4096 (fun () ->
          with_env_int "C2C_BROKER_LOG_KEEP" 5 (fun () ->
              (* Each event is ~250 bytes; 30 of them is ~7.5 KB, well over
                 4 KB cap → at least one rotation must happen. *)
              for i = 1 to 30 do
                Broker_log.append_json ~broker_root:dir ~json:(make_event i)
              done;
              let live = Filename.concat dir "broker.log" in
              let r1 = Filename.concat dir "broker.log.1" in
              check bool "live log exists" true (Sys.file_exists live);
              check bool "broker.log.1 exists" true (Sys.file_exists r1);
              (* Live log must be under the cap (it was reset on rotation
                 and only the post-rotation events remain). *)
              let live_size = (Unix.stat live).Unix.st_size in
              check bool "live log under cap after rotation"
                true (live_size < 4096);
              (* Across live + .1 we should still see all 30 sequence
                 numbers — no events lost during rotation. *)
              let live_body = read_file live in
              let r1_body = read_file r1 in
              let combined = r1_body ^ live_body in
              let total_lines = count_lines combined in
              check int "no events lost across rotation" 30 total_lines)))

(* AC2: drive enough rotations to fill the ring and exercise the shift. *)
let test_ring_shifts_correctly () =
  with_temp_dir (fun dir ->
      with_env_int "C2C_BROKER_LOG_MAX_BYTES" 1024 (fun () ->
          with_env_int "C2C_BROKER_LOG_KEEP" 3 (fun () ->
              (* Each event is ~250B; 1KB cap means each rotation after
                 ~4 events. 60 events is plenty to fill the ring multiple
                 times over. *)
              for i = 1 to 60 do
                Broker_log.append_json ~broker_root:dir ~json:(make_event i)
              done;
              (* With KEEP=3, broker.log.{1,2,3} should exist; .4 should
                 NOT exist (got dropped). *)
              let p n = Filename.concat dir ("broker.log." ^ string_of_int n) in
              check bool "broker.log.1 exists" true (Sys.file_exists (p 1));
              check bool "broker.log.2 exists" true (Sys.file_exists (p 2));
              check bool "broker.log.3 exists" true (Sys.file_exists (p 3));
              check bool "broker.log.4 does NOT exist (ring bounded)"
                false (Sys.file_exists (p 4));
              (* Newest content lives in .1; oldest surviving in .3. The
                 ring shift means ts/seq in .1 must be greater than in .3. *)
              let extract_first_seq path =
                let body = read_file path in
                let line = List.hd (String.split_on_char '\n' body) in
                let json = Yojson.Safe.from_string line in
                match json with
                | `Assoc fields ->
                  (match List.assoc_opt "seq" fields with
                   | Some (`Int n) -> n
                   | _ -> -1)
                | _ -> -1
              in
              let seq1 = extract_first_seq (p 1) in
              let seq3 = extract_first_seq (p 3) in
              check bool "ring ordering: .1 newer than .3" true (seq1 > seq3))))

(* AC3: concurrent writers via fork must produce a coherent log:
   total event count adds up, every line is parseable JSON. *)
let test_concurrent_writers_no_corruption () =
  with_temp_dir (fun dir ->
      with_env_int "C2C_BROKER_LOG_MAX_BYTES" 8192 (fun () ->
          with_env_int "C2C_BROKER_LOG_KEEP" 5 (fun () ->
              let n_per_writer = 100 in
              let fork_writer tag =
                match Unix.fork () with
                | 0 ->
                  (* Child: emit n_per_writer events tagged with our id. *)
                  for i = 1 to n_per_writer do
                    let json =
                      `Assoc
                        [ ("ts", `Float (Unix.gettimeofday ()))
                        ; ("event", `String "concurrent")
                        ; ("writer", `String tag)
                        ; ("seq", `Int i)
                        ; ("payload", `String (String.make 100 'y'))
                        ]
                    in
                    Broker_log.append_json ~broker_root:dir ~json
                  done;
                  exit 0
                | pid -> pid
              in
              let p1 = fork_writer "w1" in
              let p2 = fork_writer "w2" in
              let _ = Unix.waitpid [] p1 in
              let _ = Unix.waitpid [] p2 in
              (* Collect every log file (live + ring) and parse each line. *)
              let all_files =
                Sys.readdir dir
                |> Array.to_list
                |> List.filter (fun n ->
                    n = "broker.log"
                    || (String.length n > String.length "broker.log."
                        && String.sub n 0 (String.length "broker.log.")
                           = "broker.log."
                        && n <> "broker.log.lock"))
                |> List.map (Filename.concat dir)
              in
              let total = ref 0 in
              let parse_failures = ref 0 in
              List.iter
                (fun path ->
                  let body = read_file path in
                  String.split_on_char '\n' body
                  |> List.iter (fun line ->
                      if line = "" then ()
                      else begin
                        incr total;
                        match Yojson.Safe.from_string line with
                        | exception _ -> incr parse_failures
                        | _ -> ()
                      end))
                all_files;
              check int "no torn / unparseable lines" 0 !parse_failures;
              check int "total events == 2 * n_per_writer"
                (2 * n_per_writer) !total)))

let () =
  Alcotest.run
    "broker_log"
    [ ( "rotation"
      , [ test_case "rotates at threshold" `Quick test_rotates_at_threshold
        ; test_case "ring shifts correctly" `Quick test_ring_shifts_correctly
        ; test_case "concurrent writers no corruption" `Quick
            test_concurrent_writers_no_corruption
        ] )
    ]
