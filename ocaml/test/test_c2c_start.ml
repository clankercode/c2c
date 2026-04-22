open Alcotest

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base
      (Printf.sprintf "c2c-start-test-%d-%d" (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) |> ignore)
    (fun () -> f dir)

let with_cwd dir f =
  let prev = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Unix.chdir prev)
    (fun () ->
      Unix.chdir dir;
      f ())

let rec has_adjacent_pair left right = function
  | a :: b :: _ when a = left && b = right -> true
  | _ :: tl -> has_adjacent_pair left right tl
  | [] -> false

let test_prepare_launch_args_claude_uses_development_channel_flag () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  let args =
    C2c_start.prepare_launch_args ~name:"claude-proof" ~client:"claude"
      ~extra_args:[] ~broker_root:"/tmp/broker" ()
  in
  check bool "uses development channel flag" true
    (List.mem "--dangerously-load-development-channels" args);
  check bool "passes local server through dev channel flag" true
    (has_adjacent_pair "--dangerously-load-development-channels" "server:c2c" args);
  check bool "does not pass local server through --channels" false
    (has_adjacent_pair "--channels" "server:c2c" args)

let test_prepare_launch_args_claude_ignores_enable_channels_config () =
  with_temp_dir @@ fun dir ->
  let c2c_dir = Filename.concat dir ".c2c" in
  Unix.mkdir c2c_dir 0o755;
  let config_path = Filename.concat c2c_dir "config.toml" in
  let oc = open_out config_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      output_string oc "enable_channels = true\n");
  with_cwd dir @@ fun () ->
  let args =
    C2c_start.prepare_launch_args ~name:"claude-proof" ~client:"claude"
      ~extra_args:[] ~broker_root:"/tmp/broker" ()
  in
  check bool "still uses development channel flag" true
    (List.mem "--dangerously-load-development-channels" args);
  check bool "passes local server through dev channel flag" true
    (has_adjacent_pair "--dangerously-load-development-channels" "server:c2c" args);
  check bool "does not add tagged server channel opt-in" false
    (has_adjacent_pair "--channels" "server:c2c" args);
  check bool "does not add untagged channel name" false
    (has_adjacent_pair "--channels" "c2c" args)

let () =
  Random.self_init ();
  Alcotest.run "c2c_start"
    [ ( "launch_args",
        [ ( "prepare_launch_args_claude_uses_development_channel_flag",
            `Quick, test_prepare_launch_args_claude_uses_development_channel_flag )
        ; ( "prepare_launch_args_claude_ignores_enable_channels_config",
            `Quick, test_prepare_launch_args_claude_ignores_enable_channels_config )
        ] ) ]
