(* test_relay_activation — B300/B301: the relay is OPT-IN.

   The defect these tests lock down: on a host with NO c2c configuration at
   all, `c2c doctor` and `c2c health` contacted relay.c2c.im. `doctor` did it
   via an explicit "| None -> default_public_relay_url" fallback; `health` did
   it via a second, drifted copy of URL resolution that hardcoded the public
   URL and never read relay.json (so a private-relay host was told about the
   wrong server). A third copy in the subscribe daemon read a config path
   nothing writes.

   Two properties are asserted:

   1. RESOLUTION — Relay_activation.resolve honours flag > env > config, treats
      a bare `url` as activated (so existing installs are grandfathered), and
      returns Inactive rather than inventing a default.

   2. NO PHONE-HOME — the real `c2c` binary, run against an isolated HOME with
      no relay config, must not contact any relay. This is asserted against the
      binary rather than the function because the bug lived in the callers, not
      in resolution: a unit test of `resolve` alone would have passed
      throughout. *)

open Alcotest

let with_env k v f =
  let old = Sys.getenv_opt k in
  (match v with Some v -> Unix.putenv k v | None -> Unix.putenv k "");
  Fun.protect
    ~finally:(fun () ->
      match old with Some o -> Unix.putenv k o | None -> Unix.putenv k "")
    f

let tmpdir () =
  let d = Filename.temp_file "c2c_act" "" in
  Sys.remove d; Unix.mkdir d 0o700; d

let write path contents =
  let dir = Filename.dirname path in
  (try Unix.mkdir dir 0o700 with _ -> ());
  let oc = open_out path in
  output_string oc contents; close_out oc

(* Point config resolution at an explicit file (C2C_RELAY_CONFIG is the first
   branch of config_location) and clear the env override. *)
let with_config contents f =
  let d = tmpdir () in
  let path = Filename.concat d "relay.json" in
  (match contents with Some c -> write path c | None -> ());
  with_env "C2C_RELAY_CONFIG" (Some path) (fun () ->
    with_env "C2C_RELAY_URL" None (fun () -> f path))

let state_name = function
  | Relay_activation.Relay_inactive -> "inactive"
  | Relay_activation.Relay_disabled _ -> "disabled"
  | Relay_activation.Relay_active (u, _) -> "active:" ^ u

let t_inactive_when_nothing_configured () =
  with_config None (fun _ ->
    check string "no config -> inactive" "inactive"
      (state_name (Relay_activation.resolve ()));
    check (option string) "and no URL is invented" None
      (Relay_activation.url ()))

let t_config_url_grandfathers_existing_installs () =
  (* An existing relay.json written by `c2c relay setup` has a url and no
     `enabled` key. It must count as activated, or upgrading would silently
     disconnect every host that is currently using the relay. *)
  with_config (Some {|{"url":"https://relay.example"}|}) (fun _ ->
    check string "bare url -> active" "active:https://relay.example"
      (state_name (Relay_activation.resolve ())))

let t_enabled_false_disables () =
  with_config (Some {|{"url":"https://relay.example","enabled":false}|}) (fun _ ->
    check string "enabled:false -> disabled" "disabled"
      (state_name (Relay_activation.resolve ()));
    check (option string) "disabled yields no URL" None
      (Relay_activation.url ()))

let t_enabled_true_activates () =
  with_config (Some {|{"url":"https://relay.example","enabled":true}|}) (fun _ ->
    check string "enabled:true -> active" "active:https://relay.example"
      (state_name (Relay_activation.resolve ())))

let t_flag_beats_disabled () =
  (* `c2c relay disable` parks a URL; it must not veto an explicit override. *)
  with_config (Some {|{"url":"https://relay.example","enabled":false}|}) (fun _ ->
    check string "explicit flag wins over enabled:false"
      "active:https://flag.example"
      (state_name (Relay_activation.resolve ~flag:"https://flag.example" ())))

let t_env_beats_disabled () =
  with_config (Some {|{"url":"https://relay.example","enabled":false}|}) (fun _ ->
    with_env "C2C_RELAY_URL" (Some "https://env.example") (fun () ->
      check string "C2C_RELAY_URL wins over enabled:false"
        "active:https://env.example"
        (state_name (Relay_activation.resolve ()))))

let t_flag_beats_env () =
  with_config None (fun _ ->
    with_env "C2C_RELAY_URL" (Some "https://env.example") (fun () ->
      check string "flag > env" "active:https://flag.example"
        (state_name (Relay_activation.resolve ~flag:"https://flag.example" ()))))

let t_blank_values_do_not_activate () =
  with_config None (fun _ ->
    with_env "C2C_RELAY_URL" (Some "   ") (fun () ->
      check string "whitespace env is not activation" "inactive"
        (state_name (Relay_activation.resolve ()));
      check string "empty flag is not activation" "inactive"
        (state_name (Relay_activation.resolve ~flag:"" ()))))

(* --- the no-phone-home property, asserted against the real binary --- *)

let c2c_exe = "../cli/c2c.exe"

let run_isolated args =
  let home = tmpdir () in
  let out = Filename.concat home "out.txt" in
  (* env -i: an isolated HOME with no C2C_* inherited from the test runner. *)
  let cmd =
    Printf.sprintf
      "env -i PATH=/usr/bin HOME=%s %s %s > %s 2>&1"
      (Filename.quote home) (Filename.quote c2c_exe) args (Filename.quote out)
  in
  ignore (Sys.command cmd);
  let ic = open_in out in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic; s

let contains hay needle =
  let hl = String.length hay and nl = String.length needle in
  let rec go i = i + nl <= hl && (String.sub hay i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let t_health_does_not_phone_home () =
  let out = run_isolated "health" in
  check bool "health reports the relay as not activated" true
    (contains out "relay: not activated");
  check bool "health does not report reachability of the public relay" false
    (contains out "relay: reachable")

let t_subscribe_daemon_refuses_when_inactive () =
  let out = run_isolated "relay subscribe-daemon" in
  check bool "daemon refuses rather than defaulting to the public relay" true
    (contains out "not activated")

let () =
  run "relay_activation"
    [ ( "resolution",
        [ test_case "inactive when nothing configured" `Quick
            t_inactive_when_nothing_configured
        ; test_case "bare url grandfathers existing installs" `Quick
            t_config_url_grandfathers_existing_installs
        ; test_case "enabled:false disables" `Quick t_enabled_false_disables
        ; test_case "enabled:true activates" `Quick t_enabled_true_activates
        ; test_case "flag beats enabled:false" `Quick t_flag_beats_disabled
        ; test_case "env beats enabled:false" `Quick t_env_beats_disabled
        ; test_case "flag beats env" `Quick t_flag_beats_env
        ; test_case "blank values do not activate" `Quick
            t_blank_values_do_not_activate ] )
    ; ( "no-phone-home",
        [ test_case "c2c health makes no relay call when inactive" `Quick
            t_health_does_not_phone_home
        ; test_case "relay subscribe-daemon refuses when inactive" `Quick
            t_subscribe_daemon_refuses_when_inactive ] ) ]
