(* test_c2c_relay_b310_enable — `c2c relay enable` URL selection.

   B310: enable used to ignore the ambient C2C_RELAY_URL (and any already-
   saved relay.json URL): `chosen = --url | public default`. An operator with
   C2C_RELAY_URL=https://private.example exported who ran `c2c relay enable`
   got the PUBLIC relay written to relay.json, and since the machine config
   then held a URL, the systemd unit booted onto relay.c2c.im while every
   shell command used the private relay — traffic silently split across two
   relays.

   Locked here through the real binary (fixture systemctl, isolated HOME):
   B300 precedence flag > env > saved config, with the public relay only as
   the last resort — including the parked-URL case, because `c2c relay
   disable` parks the URL and its own output promises `enable` restores it. *)

open Alcotest

let ( // ) = Filename.concat

let tmpdir prefix =
  let d = Filename.get_temp_dir_name () // Printf.sprintf "%s-%08x" prefix (Random.bits ()) in
  (try Unix.mkdir d 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  d

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun child -> remove_tree (path // child)) (Sys.readdir path);
    Unix.rmdir path
  end else (try Unix.unlink path with _ -> ())

let read_file_all path =
  if not (Sys.file_exists path) then ""
  else begin
    let ic = open_in_bin path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic; s
  end

let contains ~haystack ~needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec loop i =
    i + nl <= hl && (String.sub haystack i nl = needle || loop (i + 1))
  in
  nl = 0 || loop 0

let c2c_exe =
  let e = Sys.executable_name in
  let abs = if Filename.is_relative e then Sys.getcwd () // e else e in
  Filename.dirname (Filename.dirname abs) // "cli" // "c2c.exe"

let machine_relay_json home = home // ".config" // "c2c" // "relay.json"

let relay_json_field path key =
  if not (Sys.file_exists path) then None
  else
    match Yojson.Safe.from_file path with
    | `Assoc a -> List.assoc_opt key a
    | _ -> None

let relay_json_url path =
  match relay_json_field path "url" with
  | Some (`String u) -> Some u
  | _ -> None

let relay_json_enabled path =
  match relay_json_field path "enabled" with
  | Some (`Bool b) -> Some b
  | _ -> None

(* B326: enable refuses a dev _build binary when no canonical install exists.
   These tests exercise URL selection, so seed the canonical install the
   enable flow prefers. *)
let seed_canonical_binary home =
  let bin = home // ".local" // "bin" // "c2c" in
  (try Unix.mkdir (home // ".local") 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Unix.mkdir (home // ".local" // "bin") 0o755;
  let oc = open_out_bin bin in
  output_string oc "#!/bin/sh\n";
  close_out oc;
  Unix.chmod bin 0o755

let with_home f =
  let home = tmpdir "c2c-b310-enable" in
  Fun.protect ~finally:(fun () -> try remove_tree home with _ -> ())
    (fun () ->
      seed_canonical_binary home;
      f home)

(* Run `c2c relay <args>` in an isolated HOME under the systemctl fixture;
   [extra_env] rows are appended verbatim (env -i guarantees everything else
   is absent, so no duplicate-key ambiguity). Returns (exit code, output). *)
let run_enable ~home ?(extra_env = []) args =
  let out = home // "out.txt" in
  let cap = home // "systemctl.log" in
  let extra =
    String.concat ""
      (List.map
         (fun (k, v) -> Printf.sprintf " %s=%s" k (Filename.quote v))
         extra_env)
  in
  let cmd =
    Printf.sprintf
      "env -i PATH=/usr/bin HOME=%s XDG_CONFIG_HOME=%s C2C_SYSTEMCTL_FIXTURE=1 \
       C2C_SYSTEMCTL_CAPTURE_FILE=%s%s %s relay %s > %s 2>&1"
      (Filename.quote home)
      (Filename.quote (home // ".config"))
      (Filename.quote cap) extra
      (Filename.quote c2c_exe) args (Filename.quote out)
  in
  let code = Sys.command cmd in
  (code, read_file_all out)

let public_url = "https://relay.c2c.im"
let private_url = "https://private.b310.example"
let flag_url = "https://flag.b310.example"

let test_enable_honors_ambient_env_url () =
  with_home (fun home ->
    let code, out =
      run_enable ~home ~extra_env:[ "C2C_RELAY_URL", private_url ] "enable"
    in
    check bool ("enable exits 0: " ^ out) true (code = 0);
    check (option string) "env URL written, not the public relay"
      (Some private_url) (relay_json_url (machine_relay_json home));
    check bool "env URL echoed to the operator" true
      (contains ~haystack:out ~needle:private_url);
    check bool "enabled flag set" true
      (relay_json_enabled (machine_relay_json home) = Some true))

let test_enable_flag_beats_env () =
  with_home (fun home ->
    let code, out =
      run_enable ~home ~extra_env:[ "C2C_RELAY_URL", private_url ]
        (Printf.sprintf "enable --url %s" flag_url)
    in
    check bool ("enable exits 0: " ^ out) true (code = 0);
    check (option string) "explicit --url wins over env" (Some flag_url)
      (relay_json_url (machine_relay_json home)))

let test_enable_without_sources_defaults_public () =
  with_home (fun home ->
    let code, _ = run_enable ~home "enable" in
    check bool "enable exits 0" true (code = 0);
    check (option string) "no env + no config -> public default"
      (Some public_url) (relay_json_url (machine_relay_json home)))

let test_enable_restores_url_parked_by_disable () =
  with_home (fun home ->
    let code1, _ = run_enable ~home (Printf.sprintf "enable --url %s" private_url) in
    check bool "initial enable exits 0" true (code1 = 0);
    let code2, out2 = run_enable ~home "disable" in
    check bool ("disable exits 0: " ^ out2) true (code2 = 0);
    check bool "disable parks the URL (enabled:false, url kept)" true
      (relay_json_enabled (machine_relay_json home) = Some false
       && relay_json_url (machine_relay_json home) = Some private_url);
    let code3, _ = run_enable ~home "enable" in
    check bool "re-enable exits 0" true (code3 = 0);
    check (option string) "enable restores the parked URL, not the public relay"
      (Some private_url) (relay_json_url (machine_relay_json home)))

let () =
  run "c2c relay b310 enable url precedence" [
    "B310 enable URL precedence", [
      test_case "ambient C2C_RELAY_URL is written" `Quick
        test_enable_honors_ambient_env_url;
      test_case "explicit --url beats env" `Quick
        test_enable_flag_beats_env;
      test_case "no env + no config -> public default" `Quick
        test_enable_without_sources_defaults_public;
      test_case "enable restores a URL parked by disable" `Quick
        test_enable_restores_url_parked_by_disable;
    ];
  ]
