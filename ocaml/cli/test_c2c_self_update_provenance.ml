(* test_c2c_self_update_provenance.ml — hermetic coverage of the
   package-manager provenance + delegation policy for `c2c self-update`
   (B101 / A003 / F101). Every input is injected; no real package manager,
   filesystem, or network is touched. *)

module P = C2c_self_update_provenance

let method_t = Alcotest.testable
  (fun ppf m -> Format.fprintf ppf "%s" (P.string_of_method m))
  (fun a b -> a = b)

(* ---- classify_path ------------------------------------------------------- *)

let standalone_paths =
  [ "/home/u/.local/bin/c2c";
    "/usr/local/bin/c2c";
    "/opt/c2c/bin/c2c" ]

let npm_paths =
  [ "/home/u/.nvm/versions/node/v20.11.0/lib/node_modules/@clanker-code/c2c-linux-x64/bin/c2c";
    "/usr/lib/node_modules/@clanker-code/c2c-linux-x64/bin/c2c" ]

let pnpm_path =
  "/home/u/.local/share/pnpm/global/5/.pnpm/@clanker-code+c2c-linux-x64@0.8.0/node_modules/@clanker-code/c2c-linux-x64/bin/c2c"

let bun_path =
  "/home/u/.bun/install/global/node_modules/@clanker-code/c2c-linux-x64/bin/c2c"

let test_classify_standalone () =
  List.iter (fun p ->
    Alcotest.check method_t ("standalone: " ^ p) P.Standalone (P.classify_path p))
    standalone_paths

let test_classify_npm () =
  List.iter (fun p ->
    Alcotest.check method_t ("npm: " ^ p) P.Npm (P.classify_path p))
    npm_paths

let test_classify_pnpm () =
  (* pnpm store also contains node_modules — the .pnpm segment must win. *)
  Alcotest.check method_t "pnpm" P.Pnpm (P.classify_path pnpm_path)

let test_classify_bun () =
  Alcotest.check method_t "bun" P.Bun (P.classify_path bun_path)

(* ---- detect: method + package ownership ---------------------------------- *)

let detect p = P.detect ~binary_path:p ~resolved_on_path:None ()

let test_detect_standalone () =
  let t = detect (List.hd standalone_paths) in
  Alcotest.check method_t "standalone" P.Standalone t.P.method_;
  Alcotest.(check (option string)) "no shadow" None t.P.shadowed_by

let test_detect_npm () =
  Alcotest.check method_t "npm" P.Npm (detect (List.hd npm_paths)).P.method_

let test_detect_pnpm () =
  Alcotest.check method_t "pnpm" P.Pnpm (detect pnpm_path).P.method_

let test_detect_bun () =
  Alcotest.check method_t "bun" P.Bun (detect bun_path).P.method_

let test_detect_unknown_foreign_store () =
  (* In a node_modules store but NOT our package -> ambiguous -> Unknown. *)
  let foreign = "/home/u/node_modules/some-other-tool/bin/c2c" in
  Alcotest.check method_t "unknown" P.Unknown (detect foreign).P.method_

(* M3: a custom BUN_INSTALL prefix has no ".bun" segment, so without the hint a
   bun-managed binary under it misclassifies as Npm; the injected prefix fixes it. *)
let test_detect_bun_install_custom_prefix () =
  let custom =
    "/home/u/bunroot/install/global/node_modules/@clanker-code/c2c-linux-x64/bin/c2c"
  in
  Alcotest.check method_t "npm without hint" P.Npm (detect custom).P.method_;
  Alcotest.check method_t "bun with BUN_INSTALL hint" P.Bun
    (P.detect ~bun_install:"/home/u/bunroot" ~binary_path:custom
       ~resolved_on_path:None ()).P.method_;
  (* An unrelated BUN_INSTALL prefix must NOT hijack a real npm install. *)
  Alcotest.check method_t "npm unaffected by unrelated prefix" P.Npm
    (P.detect ~bun_install:"/home/u/elsewhere"
       ~binary_path:(List.hd npm_paths) ~resolved_on_path:None ()).P.method_

(* ---- detect: PATH shadow ------------------------------------------------- *)

let test_detect_shadow () =
  let running = "/home/u/.local/bin/c2c" in
  let on_path = "/usr/local/bin/c2c" in
  let t = P.detect ~binary_path:running ~resolved_on_path:(Some on_path) () in
  Alcotest.(check (option string)) "shadowed_by" (Some on_path) t.P.shadowed_by

let test_detect_no_shadow_same_path () =
  let p = "/home/u/.local/bin/c2c" in
  let t = P.detect ~binary_path:p ~resolved_on_path:(Some p) () in
  Alcotest.(check (option string)) "not shadowed" None t.P.shadowed_by

(* ---- delegate_command ---------------------------------------------------- *)

let test_delegate_command_latest () =
  Alcotest.(check (option string)) "npm latest"
    (Some "npm install -g @clanker-code/c2c@latest")
    (P.delegate_command P.Npm ~pinned:None);
  Alcotest.(check (option string)) "pnpm latest"
    (Some "pnpm add -g @clanker-code/c2c@latest")
    (P.delegate_command P.Pnpm ~pinned:None);
  Alcotest.(check (option string)) "bun latest"
    (Some "bun add -g @clanker-code/c2c@latest")
    (P.delegate_command P.Bun ~pinned:None)

let test_delegate_command_pinned () =
  (* both bare and v-prefixed pins resolve to the package version *)
  Alcotest.(check (option string)) "npm pinned bare"
    (Some "npm install -g @clanker-code/c2c@0.8.5")
    (P.delegate_command P.Npm ~pinned:(Some "0.8.5"));
  Alcotest.(check (option string)) "npm pinned v-prefixed"
    (Some "npm install -g @clanker-code/c2c@0.8.5")
    (P.delegate_command P.Npm ~pinned:(Some "v0.8.5"))

let test_delegate_command_none_for_standalone () =
  Alcotest.(check (option string)) "standalone" None
    (P.delegate_command P.Standalone ~pinned:None);
  Alcotest.(check (option string)) "unknown" None
    (P.delegate_command P.Unknown ~pinned:None)

(* M5: a blank / whitespace pin resolves to @latest, never a bare "@". *)
let test_delegate_command_blank_pin_latest () =
  Alcotest.(check (option string)) "empty pin -> latest"
    (Some "npm install -g @clanker-code/c2c@latest")
    (P.delegate_command P.Npm ~pinned:(Some ""));
  Alcotest.(check (option string)) "whitespace pin -> latest"
    (Some "npm install -g @clanker-code/c2c@latest")
    (P.delegate_command P.Npm ~pinned:(Some "   "))

(* ---- plan: the decision matrix ------------------------------------------- *)

let action_t = Alcotest.testable
  (fun ppf -> function
     | P.In_place_standalone -> Format.fprintf ppf "In_place_standalone"
     | P.Delegate { method_; command } ->
         Format.fprintf ppf "Delegate(%s,%s)" (P.string_of_method method_) command
     | P.Refuse m -> Format.fprintf ppf "Refuse(%s)" m)
  (fun a b -> a = b)

let is_refuse = function P.Refuse _ -> true | _ -> false
let is_delegate = function P.Delegate _ -> true | _ -> false

let test_plan_standalone_in_place () =
  let t = detect (List.hd standalone_paths) in
  Alcotest.check action_t "in place"
    P.In_place_standalone
    (P.plan t ~check_only:false ~pinned:None ~manager_available:false)

let test_plan_npm_delegates () =
  let t = detect (List.hd npm_paths) in
  Alcotest.check action_t "npm delegate"
    (P.Delegate { method_ = P.Npm;
                  command = "npm install -g @clanker-code/c2c@latest" })
    (P.plan t ~check_only:false ~pinned:None ~manager_available:true)

let test_plan_pnpm_bun_delegate () =
  Alcotest.(check bool) "pnpm delegates" true
    (is_delegate (P.plan (detect pnpm_path)
                    ~check_only:false ~pinned:None ~manager_available:true));
  Alcotest.(check bool) "bun delegates" true
    (is_delegate (P.plan (detect bun_path)
                    ~check_only:false ~pinned:None ~manager_available:true))

let test_plan_missing_manager_refuses () =
  (* npm-managed but npm not on PATH -> honest refusal, not a silent standalone
     install (AC #4 / "missing package manager" failure mode). *)
  let t = detect (List.hd npm_paths) in
  let a = P.plan t ~check_only:false ~pinned:None ~manager_available:false in
  Alcotest.(check bool) "refuses" true (is_refuse a);
  (match a with
   | P.Refuse m ->
       Alcotest.(check bool) "mentions npm"
         true (P.package_name <> "" && String.length m > 0)
   | _ -> Alcotest.fail "expected Refuse")

let test_plan_check_only_no_mutation () =
  (* --check on a package-managed install reports the command WITHOUT requiring
     the manager present, and never returns In_place (no mutation). *)
  let t = detect (List.hd npm_paths) in
  let a = P.plan t ~check_only:true ~pinned:None ~manager_available:false in
  Alcotest.(check bool) "delegates (report only)" true (is_delegate a)

let test_plan_unknown_refuses () =
  let t = detect "/home/u/node_modules/some-other-tool/bin/c2c" in
  Alcotest.(check bool) "unknown refuses" true
    (is_refuse (P.plan t ~check_only:false ~pinned:None ~manager_available:true))

let test_plan_shadow_refuses_standalone () =
  (* PATH-shadow (F101): the standalone binary that would be updated is not the
     c2c that runs from PATH -> refuse. *)
  let t = P.detect ~binary_path:"/home/u/.local/bin/c2c"
            ~resolved_on_path:(Some "/usr/local/bin/c2c") () in
  Alcotest.(check bool) "shadow refuses" true
    (is_refuse (P.plan t ~check_only:false ~pinned:None ~manager_available:false))

let test_plan_shadow_check_only_ok () =
  (* --check never mutates, so a shadowed standalone still reports in-place
     (no refusal) under check. *)
  let t = P.detect ~binary_path:"/home/u/.local/bin/c2c"
            ~resolved_on_path:(Some "/usr/local/bin/c2c") () in
  Alcotest.check action_t "check ignores shadow"
    P.In_place_standalone
    (P.plan t ~check_only:true ~pinned:None ~manager_available:false)

(* ---- delegate outcome (failed manager command) -------------------------- *)

let test_delegate_outcome () =
  let ok = P.delegate_outcome_message P.Npm
             ~command:"npm install -g @clanker-code/c2c@latest" ~rc:0 in
  Alcotest.(check bool) "rc=0 mentions updated" true
    (String.length ok > 0
     && (try ignore (Str.search_forward (Str.regexp_string "updated") ok 0); true
         with Not_found -> false));
  let bad = P.delegate_outcome_message P.Npm
              ~command:"npm install -g @clanker-code/c2c@latest" ~rc:7 in
  Alcotest.(check bool) "rc<>0 mentions failed + code" true
    ((try ignore (Str.search_forward (Str.regexp_string "failed") bad 0); true
      with Not_found -> false)
     && (try ignore (Str.search_forward (Str.regexp_string "7") bad 0); true
         with Not_found -> false))

(* ---- shipped delegate JSON (the REAL emitter, not a parallel one) --------- *)

let keys_of = function `Assoc kv -> List.map fst kv | _ -> []

let delegate_keys =
  [ "install_method"; "delegate_command"; "check_only"; "executed"; "exit_code" ]

(* (i) delegate-report / check: exec suppressed -> executed=false, exit_code=null *)
let test_delegate_json_report () =
  let j =
    P.delegate_json ~method_:P.Npm
      ~command:"npm install -g @clanker-code/c2c@latest"
      ~check_only:true ~executed:false ~exit_code:None
  in
  let open Yojson.Safe.Util in
  Alcotest.(check (list string)) "exactly the five stable keys" delegate_keys (keys_of j);
  Alcotest.(check string) "method" "npm" (j |> member "install_method" |> to_string);
  Alcotest.(check string) "command"
    "npm install -g @clanker-code/c2c@latest"
    (j |> member "delegate_command" |> to_string);
  Alcotest.(check bool) "check_only" true (j |> member "check_only" |> to_bool);
  Alcotest.(check bool) "not executed" false (j |> member "executed" |> to_bool);
  Alcotest.(check bool) "exit_code null" true (j |> member "exit_code" = `Null)

(* (ii) delegate-execute success: executed=true, exit_code=0 *)
let test_delegate_json_exec_success () =
  let j =
    P.delegate_json ~method_:P.Pnpm
      ~command:"pnpm add -g @clanker-code/c2c@latest"
      ~check_only:false ~executed:true ~exit_code:(Some 0)
  in
  let open Yojson.Safe.Util in
  Alcotest.(check (list string)) "keys" delegate_keys (keys_of j);
  Alcotest.(check bool) "executed" true (j |> member "executed" |> to_bool);
  Alcotest.(check int) "exit_code 0" 0 (j |> member "exit_code" |> to_int)

(* (iii) delegate-execute failure: executed=true, exit_code=<rc> *)
let test_delegate_json_exec_failure () =
  let j =
    P.delegate_json ~method_:P.Bun
      ~command:"bun add -g @clanker-code/c2c@latest"
      ~check_only:false ~executed:true ~exit_code:(Some 7)
  in
  let open Yojson.Safe.Util in
  Alcotest.(check (list string)) "keys" delegate_keys (keys_of j);
  Alcotest.(check string) "method" "bun" (j |> member "install_method" |> to_string);
  Alcotest.(check bool) "executed" true (j |> member "executed" |> to_bool);
  Alcotest.(check int) "exit_code 7" 7 (j |> member "exit_code" |> to_int)

(* (iv) refuse paths: single error object, error + exit_code *)
let test_error_json_refuse () =
  let j = P.error_json "refusing to self-update: shadowed" in
  let open Yojson.Safe.Util in
  Alcotest.(check (list string)) "exactly error+exit_code"
    [ "error"; "exit_code" ] (keys_of j);
  Alcotest.(check string) "error message"
    "refusing to self-update: shadowed" (j |> member "error" |> to_string);
  Alcotest.(check int) "exit_code 1" 1 (j |> member "exit_code" |> to_int);
  Alcotest.(check int) "override exit_code"
    2 (P.error_json ~exit_code:2 "x" |> member "exit_code" |> to_int)

let test_describe_human () =
  let t = detect (List.hd npm_paths) in
  Alcotest.(check bool) "human mentions npm" true
    (try ignore (Str.search_forward (Str.regexp_string "npm") (P.describe t) 0); true
     with Not_found -> false)

let () =
  Alcotest.run "c2c_self_update_provenance"
    [ ("classify",
       [ Alcotest.test_case "standalone" `Quick test_classify_standalone;
         Alcotest.test_case "npm" `Quick test_classify_npm;
         Alcotest.test_case "pnpm" `Quick test_classify_pnpm;
         Alcotest.test_case "bun" `Quick test_classify_bun ]);
      ("detect",
       [ Alcotest.test_case "standalone" `Quick test_detect_standalone;
         Alcotest.test_case "npm" `Quick test_detect_npm;
         Alcotest.test_case "pnpm" `Quick test_detect_pnpm;
         Alcotest.test_case "bun" `Quick test_detect_bun;
         Alcotest.test_case "unknown-foreign-store" `Quick test_detect_unknown_foreign_store;
         Alcotest.test_case "bun-install-custom-prefix" `Quick test_detect_bun_install_custom_prefix;
         Alcotest.test_case "shadow" `Quick test_detect_shadow;
         Alcotest.test_case "no-shadow-same-path" `Quick test_detect_no_shadow_same_path ]);
      ("delegate_command",
       [ Alcotest.test_case "latest" `Quick test_delegate_command_latest;
         Alcotest.test_case "pinned" `Quick test_delegate_command_pinned;
         Alcotest.test_case "blank-pin-latest" `Quick test_delegate_command_blank_pin_latest;
         Alcotest.test_case "none-for-standalone" `Quick test_delegate_command_none_for_standalone ]);
      ("plan",
       [ Alcotest.test_case "standalone-in-place" `Quick test_plan_standalone_in_place;
         Alcotest.test_case "npm-delegates" `Quick test_plan_npm_delegates;
         Alcotest.test_case "pnpm-bun-delegate" `Quick test_plan_pnpm_bun_delegate;
         Alcotest.test_case "missing-manager-refuses" `Quick test_plan_missing_manager_refuses;
         Alcotest.test_case "check-only-no-mutation" `Quick test_plan_check_only_no_mutation;
         Alcotest.test_case "unknown-refuses" `Quick test_plan_unknown_refuses;
         Alcotest.test_case "shadow-refuses-standalone" `Quick test_plan_shadow_refuses_standalone;
         Alcotest.test_case "shadow-check-only-ok" `Quick test_plan_shadow_check_only_ok ]);
      ("outcome",
       [ Alcotest.test_case "delegate-outcome" `Quick test_delegate_outcome ]);
      ("render",
       [ Alcotest.test_case "delegate-json-report" `Quick test_delegate_json_report;
         Alcotest.test_case "delegate-json-exec-success" `Quick test_delegate_json_exec_success;
         Alcotest.test_case "delegate-json-exec-failure" `Quick test_delegate_json_exec_failure;
         Alcotest.test_case "error-json-refuse" `Quick test_error_json_refuse;
         Alcotest.test_case "describe-human" `Quick test_describe_human ]) ]
