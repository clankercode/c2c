(* B101: npm package wrapper self-update routing. *)

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect ~finally:(fun () ->
    match old with
    | Some previous -> Unix.putenv key previous
    | None -> Unix.putenv key "") f

let test_package_manager_from_env () =
  let cases = [
    ("npm", Some C2c_self_update.Npm);
    ("pnpm", Some C2c_self_update.Pnpm);
    ("bun", Some C2c_self_update.Bun);
    ("unknown", None);
    ("  pnpm  ", Some C2c_self_update.Pnpm);
  ] in
  List.iter (fun (value, expected) ->
    Alcotest.(check (option string)) ("manager " ^ value)
      (Option.map C2c_self_update.package_manager_name expected)
      (with_env "C2C_SELF_UPDATE_PACKAGE_MANAGER" value
         (fun () -> Option.map C2c_self_update.package_manager_name
           (C2c_self_update.package_manager_from_env ())))) cases

let test_package_update_command () =
  let command, argv = C2c_self_update.package_update_command C2c_self_update.Pnpm None in
  Alcotest.(check string) "pnpm executable" "pnpm" command;
  Alcotest.(check (list string)) "pnpm latest arguments"
    ["pnpm"; "add"; "--global"; "@clanker-code/c2c@latest"] (Array.to_list argv);
  let command, argv = C2c_self_update.package_update_command C2c_self_update.Bun (Some "0.9.0") in
  Alcotest.(check string) "bun executable" "bun" command;
  Alcotest.(check (list string)) "bun pinned arguments"
    ["bun"; "add"; "--global"; "@clanker-code/c2c@0.9.0"] (Array.to_list argv)

let () =
  Alcotest.run "c2c_self_update" [
    "package-manager routing", [
      Alcotest.test_case "recognizes npm, pnpm, and bun" `Quick test_package_manager_from_env;
      Alcotest.test_case "builds safe package-manager argv" `Quick test_package_update_command;
    ];
  ]
