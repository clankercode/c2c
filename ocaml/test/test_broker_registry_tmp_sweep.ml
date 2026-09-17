(* test_broker_registry_tmp_sweep.ml — B299: orphaned registry.json.tmp.<pid>
   atomic-write temps are swept after each successful registry save.

   Covers:
   - dead-pid temp with fresh mtime is swept
   - alive-pid temp with mtime older than 1h is swept
   - alive-pid temp with fresh mtime is KEPT (in-flight-writer guard)
   - non-digit lookalikes / other files' temps / registry.json untouched
   - forked concurrent writers: registry stays coherent, seeded temps
     resolve per the guards, no writer temp leaks *)

open Alcotest

let tmp_prefix = "registry.json.tmp."

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base (Printf.sprintf "c2c-b299-sweep-%06x" (Random.bits ()))
  in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) |> ignore)
    (fun () -> f dir)

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let buf = Buffer.create 256 in
      (try
         while true do
           Buffer.add_channel buf ic 4096
         done
       with End_of_file -> ());
      Buffer.contents buf)

let seed path =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      output_string oc "{}")

(* mtime past the sweep's 1h horizon *)
let backdate path =
  let old = Unix.gettimeofday () -. 7200.0 in
  Unix.utimes path old old

let tmp_name pid = tmp_prefix ^ string_of_int pid

(* a genuinely dead pid: fork, exit, reap *)
let dead_pid () =
  match Unix.fork () with
  | 0 -> exit 0
  | pid ->
    let (_ : int * Unix.process_status) = Unix.waitpid [] pid in
    pid

(* a distinct pid that stays alive until reaped *)
let alive_pid () =
  match Unix.fork () with
  | 0 ->
    (try Unix.sleep 300 with _ -> ());
    exit 0
  | pid -> pid

let reap pid =
  (try Unix.kill pid Sys.sigkill with _ -> ());
  (try ignore (Unix.waitpid [] pid) with _ -> ())

let registry_tmps dir =
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun n ->
         String.starts_with ~prefix:tmp_prefix n
         && String.length n > String.length tmp_prefix)

(* dead pid, fresh mtime: the pid arm must do the unlink *)
let test_dead_pid_temp_swept () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let dead_tmp = Filename.concat dir (tmp_name (dead_pid ())) in
      seed dead_tmp;
      C2c_mcp.Broker.save_registrations broker [];
      check bool "dead-pid temp swept" false (Sys.file_exists dead_tmp);
      let reg = Filename.concat dir "registry.json" in
      check bool "registry.json written" true (Sys.file_exists reg);
      let parses_empty () =
        match Yojson.Safe.from_string (read_file reg) with
        | `List [] -> true
        | _ -> false
      in
      check bool "registry.json parses to []" true (parses_empty ()))

(* alive pid, mtime past the 1h horizon: the age arm must do the unlink *)
let test_stale_alive_temp_swept () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let pid = alive_pid () in
      Fun.protect ~finally:(fun () -> reap pid) (fun () ->
          let stale = Filename.concat dir (tmp_name pid) in
          seed stale;
          backdate stale;
          C2c_mcp.Broker.save_registrations broker [];
          check bool "stale mtime temp of alive pid swept" false
            (Sys.file_exists stale)))

(* alive pid, fresh mtime: must survive the sweep. Also: non-digit
   suffixes, other files' temps, and registry.json itself stay put. *)
let test_alive_fresh_temp_kept_and_lookalikes_untouched () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"b299-keep-s"
        ~alias:"b299-keep-a" ~pid:None ~pid_start_time:None ();
      let pid = alive_pid () in
      Fun.protect ~finally:(fun () -> reap pid) (fun () ->
          let keep = Filename.concat dir (tmp_name pid) in
          seed keep;
          let lookalikes =
            [ "registry.json.tmp." (* empty pid *)
            ; "registry.json.tmp.abc" (* non-digit *)
            ; "registry.json.tmp.12x" (* trailing junk *)
            ; "registry.json.tmp.-5" (* sign: not <digits> *)
            ; "registry.json.tmp.1e3" (* not <digits> *)
            ; "other.json.tmp.7" (* a different writer's temp *)
            ]
          in
          List.iter (fun n -> seed (Filename.concat dir n)) lookalikes;
          C2c_mcp.Broker.save_registrations broker
            (C2c_mcp.Broker.list_registrations broker);
          check bool "alive+fresh temp kept" true (Sys.file_exists keep);
          List.iter
            (fun n ->
              check bool ("lookalike untouched: " ^ n) true
                (Sys.file_exists (Filename.concat dir n)))
            lookalikes;
          check int "registry row survived the sweep-enabled save" 1
            (List.length (C2c_mcp.Broker.list_registrations broker))))

(* forked concurrent writers must not be disturbed by (or disturb) the
   sweep: registry keeps every row, seeded temps resolve per the guards,
   and no writer temp leaks. *)
let test_concurrent_writers_coherent_and_temps_resolved () =
  with_temp_dir (fun dir ->
      let dead_tmp = Filename.concat dir (tmp_name (dead_pid ())) in
      seed dead_tmp;
      let stale_pid = alive_pid () in
      let keep_pid = alive_pid () in
      Fun.protect ~finally:(fun () -> reap stale_pid) (fun () ->
      Fun.protect ~finally:(fun () -> reap keep_pid) (fun () ->
          let stale = Filename.concat dir (tmp_name stale_pid) in
          seed stale;
          backdate stale;
          let keep = Filename.concat dir (tmp_name keep_pid) in
          seed keep;
          let n_writes = 15 in
          let fork_writer tag =
            match Unix.fork () with
            | 0 ->
              (try
                 for i = 1 to n_writes do
                   let broker = C2c_mcp.Broker.create ~root:dir in
                   C2c_mcp.Broker.register broker
                     ~session_id:(tag ^ "-" ^ string_of_int i)
                     ~alias:(tag ^ "-a" ^ string_of_int i)
                     ~pid:None ~pid_start_time:None ()
                 done
               with _ -> exit 1);
              exit 0
            | pid -> pid
          in
          let p1 = fork_writer "b299w1" in
          let p2 = fork_writer "b299w2" in
          let status_ok = function
            | Unix.WEXITED 0 -> true
            | _ -> false
          in
          let (_, s1) = Unix.waitpid [] p1 in
          let (_, s2) = Unix.waitpid [] p2 in
          check bool "writer 1 exited cleanly" true (status_ok s1);
          check bool "writer 2 exited cleanly" true (status_ok s2);
          let rows =
            C2c_mcp.Broker.list_registrations (C2c_mcp.Broker.create ~root:dir)
          in
          check int "all concurrent rows present" (2 * n_writes)
            (List.length rows);
          check bool "dead-pid temp swept by a concurrent writer" false
            (Sys.file_exists dead_tmp);
          check bool "stale alive-pid temp swept" false (Sys.file_exists stale);
          check bool "alive+fresh temp kept" true (Sys.file_exists keep);
          let left = registry_tmps dir in
          check int "exactly one registry temp remains" 1 (List.length left);
          check string "remaining temp is the alive one" (tmp_name keep_pid)
            (List.hd left);
          (* once its pid dies, the next save takes it too *)
          reap keep_pid;
          C2c_mcp.Broker.save_registrations
            (C2c_mcp.Broker.create ~root:dir) [];
          check bool "temp swept once pid died" false (Sys.file_exists keep))))

let () =
  Alcotest.run
    "broker_registry_tmp_sweep"
    [ ( "sweep"
      , [ test_case "dead-pid temp swept" `Quick test_dead_pid_temp_swept
        ; test_case "stale mtime temp of alive pid swept" `Quick
            test_stale_alive_temp_swept
        ; test_case "alive+fresh temp kept, lookalikes untouched" `Quick
            test_alive_fresh_temp_kept_and_lookalikes_untouched
        ; test_case "concurrent writers coherent, temps resolved" `Quick
            test_concurrent_writers_coherent_and_temps_resolved
        ] )
    ]
