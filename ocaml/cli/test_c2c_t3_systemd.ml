open Alcotest

module S = C2c_t3_systemd

let contains hay needle =
  let n = String.length needle in
  let rec loop i = i + n <= String.length hay &&
    (String.sub hay i n = needle || loop (i + 1)) in
  loop 0

let test_unit_is_explicit () =
  let text = S.unit_text ~c2c_path:"/opt/c2c/bin/c2c" ~t3_home:"/srv/t3"
      ~config_dir:"/srv/c2c/config" ~state_dir:"/srv/c2c/state" () in
  check bool "absolute c2c path" true (String.contains text '/');
  check bool "foreground service" true (contains text "t3 service --foreground");
  check bool "T3 home" true (contains text "Environment=T3CODE_HOME=/srv/t3");
  check bool "state dir" true (contains text "Environment=C2C_T3_STATE_DIR=/srv/c2c/state");
  check bool "restart policy" true (contains text "Restart=always")

let test_systemd_fixture_runner () =
  let calls = ref [] in
  let run args = calls := args :: !calls; S.Systemctl_ok in
  check bool "fixture available" true (S.systemd_user_available ~run ());
  ignore (S.install ~run ~dry_run:true ~c2c_path:"/bin/c2c" ~t3_home:"/tmp/t3"
            ~config_dir:"/tmp/config" ~state_dir:"/tmp/state" ());
  check bool "availability and install queried" true (List.length !calls >= 2)

let test_unit_quotes_paths () =
  let text = S.unit_text ~c2c_path:"/opt/c2c bin/c2c" ~t3_home:"/srv/t3 home"
      ~config_dir:"/srv/c2c config" ~state_dir:"/srv/c2c state" () in
  check bool "quoted executable" true (contains text "ExecStart=\"/opt/c2c bin/c2c\"");
  check bool "quoted home" true (contains text "Environment=T3CODE_HOME=\"/srv/t3 home\"")

let () =
  Alcotest.run "c2c_t3_systemd"
    [ ("unit", [ test_case "explicit unit paths" `Quick test_unit_is_explicit ]);
      ("fixture", [ test_case "systemd runner seam" `Quick test_systemd_fixture_runner;
                     test_case "paths are quoted" `Quick test_unit_quotes_paths ]) ]
