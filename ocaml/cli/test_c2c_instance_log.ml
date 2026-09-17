(* test_c2c_instance_log.ml — B298 ring rotation for managed instance logs.

   Covers:
   - rotation when a pre-existing log exceeds the cap (supervisor start / child
     relaunch, the points where no writer holds the live path)
   - ring depth honored: log.KEEP exists after rotation, deeper files dropped
   - C2C_INSTANCE_LOG_MAX_BYTES / C2C_INSTANCE_LOG_KEEP parsing (invalid or
     <= 0 values fall back to the defaults)
   - rename-only rotation is safe under a writer's held fd (never truncate,
     never delete-and-recreate) and preserves file mode *)

open Alcotest

let ( // ) = Filename.concat

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base (Printf.sprintf "c2c-instance-log-%06x" (Random.bits ()))
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

let write_file path body =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      output_string oc body)

(* Setting "" is close enough to unset for these tests: the parser treats
   empty/invalid/non-positive values as "fall back to default". *)
let with_env key value f =
  let saved = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv key (Option.value saved ~default:""))
    f

let seed_oversized log =
  write_file log (String.make 200 'x')

(* --- env parsing --- *)

let test_env_defaults () =
  with_env "C2C_INSTANCE_LOG_MAX_BYTES" "" @@ fun () ->
  with_env "C2C_INSTANCE_LOG_KEEP" "" @@ fun () ->
  check int "default cap is 10 MiB" (10 * 1024 * 1024)
    (C2c_instance_log.max_bytes ());
  check int "default keep is 3" 3 (C2c_instance_log.keep ())

let test_env_overrides_parsed () =
  with_env "C2C_INSTANCE_LOG_MAX_BYTES" "4096" @@ fun () ->
  with_env "C2C_INSTANCE_LOG_KEEP" "5" @@ fun () ->
  check int "cap override" 4096 (C2c_instance_log.max_bytes ());
  check int "keep override" 5 (C2c_instance_log.keep ());
  with_env "C2C_INSTANCE_LOG_MAX_BYTES" "  2048  " @@ fun () ->
  check int "cap override is trimmed" 2048 (C2c_instance_log.max_bytes ())

let test_env_invalid_falls_back () =
  List.iter
    (fun v ->
      with_env "C2C_INSTANCE_LOG_MAX_BYTES" v @@ fun () ->
      with_env "C2C_INSTANCE_LOG_KEEP" v @@ fun () ->
      check int ("invalid cap '" ^ v ^ "' falls back") (10 * 1024 * 1024)
        (C2c_instance_log.max_bytes ());
      check int ("invalid keep '" ^ v ^ "' falls back") 3
        (C2c_instance_log.keep ()))
    [ "0"; "-3"; "abc"; "  "; "1.5" ]

(* --- rotation --- *)

let test_rotates_when_oversized () =
  with_temp_dir @@ fun dir ->
  with_env "C2C_INSTANCE_LOG_MAX_BYTES" "128" @@ fun () ->
  let log = dir // "log" in
  seed_oversized log;
  check bool "oversized detected" true (C2c_instance_log.oversized log);
  check bool "rotation fires" true (C2c_instance_log.rotate_if_oversized ~log_path:log);
  check bool "rotated copy exists" true (Sys.file_exists (log ^ ".1"));
  check bool "old content preserved" true
    (read_file (log ^ ".1") = String.make 200 'x');
  (* Rotation is rename-only: the live path is gone until the next opener
     recreates it — nothing is truncated in place. *)
  check bool "live path absent until reopened" false (Sys.file_exists log);
  check bool "no second rotation without a live file" false
    (C2c_instance_log.rotate_if_oversized ~log_path:log)

let test_no_rotation_at_or_under_cap () =
  with_temp_dir @@ fun dir ->
  with_env "C2C_INSTANCE_LOG_MAX_BYTES" "128" @@ fun () ->
  let log = dir // "log" in
  write_file log (String.make 128 'y');
  check bool "at cap is not oversized" false (C2c_instance_log.oversized log);
  check bool "no rotation at cap" false
    (C2c_instance_log.rotate_if_oversized ~log_path:log);
  check bool "content untouched" true (read_file log = String.make 128 'y');
  check bool "no rotated copy" false (Sys.file_exists (log ^ ".1"));
  check bool "missing file is not oversized" false
    (C2c_instance_log.oversized (dir // "absent"))

let test_ring_depth_honored () =
  with_temp_dir @@ fun dir ->
  with_env "C2C_INSTANCE_LOG_MAX_BYTES" "128" @@ fun () ->
  with_env "C2C_INSTANCE_LOG_KEEP" "3" @@ fun () ->
  let log = dir // "log" in
  seed_oversized log;
  write_file (log ^ ".1") "one";
  write_file (log ^ ".2") "two";
  write_file (log ^ ".3") "three";
  (* Stray from a previously deeper keep setting: rotation must drop it. *)
  write_file (log ^ ".4") "four";
  check bool "rotation fires" true (C2c_instance_log.rotate_if_oversized ~log_path:log);
  check bool "live content moved to log.1" true
    (read_file (log ^ ".1") = String.make 200 'x');
  check string "log.1 shifted to log.2" "one" (read_file (log ^ ".2"));
  check string "log.2 shifted to log.3" "two" (read_file (log ^ ".3"));
  check bool "log.KEEP exists" true (Sys.file_exists (log ^ ".3"));
  (* Depth is bounded: the overflow (old log.3) is gone, and so is the
     stray log.(KEEP+1). *)
  check bool "shifted-out log.3 content dropped" false
    (Sys.file_exists (log ^ ".4"))

let test_rotation_preserves_mode () =
  with_temp_dir @@ fun dir ->
  with_env "C2C_INSTANCE_LOG_MAX_BYTES" "128" @@ fun () ->
  let log = dir // "log" in
  seed_oversized log;
  Unix.chmod log 0o640;
  ignore (C2c_instance_log.rotate_if_oversized ~log_path:log);
  check int "rename keeps the original mode (0o640)" 0o640
    ((Unix.stat (log ^ ".1")).Unix.st_perm land 0o777)

(* The fd-safety property: a writer that already holds the log open (the
   running connector child, the supervisor's own stdio) must never see its
   file truncated, deleted-and-recreated, or its post-rotation writes lost —
   rotation is a pure rename, so the fd follows the renamed inode. *)
let test_rotation_is_safe_under_held_fd () =
  with_temp_dir @@ fun dir ->
  with_env "C2C_INSTANCE_LOG_MAX_BYTES" "128" @@ fun () ->
  let log = dir // "log" in
  seed_oversized log;
  let fd = Unix.openfile log [ Unix.O_WRONLY; Unix.O_APPEND ] 0 in
  check bool "rotation fires under held fd" true
    (C2c_instance_log.rotate_if_oversized ~log_path:log);
  let tail = "after-rotate\n" in
  ignore (Unix.write fd (Bytes.of_string tail) 0 (String.length tail));
  Unix.close fd;
  let rotated = read_file (log ^ ".1") in
  check bool "post-rotation writes land in the renamed file" true
    (String.ends_with ~suffix:tail rotated);
  check int "nothing truncated or lost" (200 + String.length tail)
    (String.length rotated);
  check bool "rotation alone does not recreate the live path" false
    (Sys.file_exists log);
  (match C2c_instance_log.open_append log with
   | Some fd2 -> Unix.close fd2
   | None -> fail "open_append must succeed after rotation");
  check bool "opener recreates the live path" true (Sys.file_exists log);
  check int "fresh live log starts empty" 0 (Unix.stat log).Unix.st_size

let test_open_append_creates_0600 () =
  with_temp_dir @@ fun dir ->
  let log = dir // "log" in
  (match C2c_instance_log.open_append log with
   | Some fd -> Unix.close fd
   | None -> fail "open_append must create the log");
  check int "created with 0o600" 0o600
    ((Unix.stat log).Unix.st_perm land 0o777)

let () =
  run "c2c instance log" [
    "env parsing", [
      test_case "defaults are 10 MiB / ring 3" `Quick test_env_defaults;
      test_case "overrides parsed (trimmed)" `Quick test_env_overrides_parsed;
      test_case "invalid values fall back to defaults" `Quick test_env_invalid_falls_back;
    ];
    "rotation", [
      test_case "rotates when pre-existing log over cap" `Quick test_rotates_when_oversized;
      test_case "no rotation at or under cap" `Quick test_no_rotation_at_or_under_cap;
      test_case "ring depth honored (log.KEEP exists, deeper dropped)" `Quick test_ring_depth_honored;
      test_case "renamed file keeps its mode" `Quick test_rotation_preserves_mode;
      test_case "rename-safe under a held fd" `Quick test_rotation_is_safe_under_held_fd;
      test_case "open_append creates 0600" `Quick test_open_append_creates_0600;
    ];
  ]
