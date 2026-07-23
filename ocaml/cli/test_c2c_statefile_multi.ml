open Alcotest

let c2c_binary =
  Filename.concat (Filename.dirname Sys.executable_name) "c2c.exe"

let write_all fd payload =
  let bytes = Bytes.of_string payload in
  let rec loop offset =
    if offset < Bytes.length bytes then
      let written = Unix.write fd bytes offset (Bytes.length bytes - offset) in
      loop (offset + written)
  in
  loop 0

let run_with_input ~home args input =
  let in_r, in_w = Unix.pipe () in
  let out_r, out_w = Unix.pipe () in
  let err_r, err_w = Unix.pipe () in
  List.iter Unix.set_close_on_exec [in_w; out_r; err_r];
  let argv = Array.of_list (c2c_binary :: args) in
  let env =
    Unix.environment ()
    |> Array.to_list
    |> List.filter (fun item -> not (String.starts_with ~prefix:"HOME=" item))
    |> fun items -> Array.of_list (("HOME=" ^ home) :: items)
  in
  let pid = Unix.create_process_env c2c_binary argv env in_r out_w err_w in
  Unix.close in_r; Unix.close out_w; Unix.close err_w;
  write_all in_w input;
  Unix.close in_w;
  let read_all fd =
    let ic = Unix.in_channel_of_descr fd in
    let body = In_channel.input_all ic in
    close_in ic;
    body
  in
  let stdout = read_all out_r in
  let stderr = read_all err_r in
  let _, status = Unix.waitpid [] pid in
  let code = match status with
    | Unix.WEXITED n -> n
    | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n
  in
  code, stdout, stderr

let with_temp_home f =
  let path = Filename.temp_file "c2c-statefile-multi-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote path)))
    (fun () -> f path)

let statefile home key =
  Filename.concat home (".local/share/c2c/instances/" ^ key ^ "/oc-plugin-state.json")

let read_json path = Yojson.Safe.from_file path

let snapshot key state =
  Printf.sprintf
    {|{"instance_key":"%s","event":"state.snapshot","ts":"2026-07-23T10:00:00Z","state":{"status":"%s"}}|}
    key state

let snapshot_with_key_json key_json state =
  Printf.sprintf
    {|{"instance_key":%s,"event":"state.snapshot","ts":"2026-07-23T10:00:00Z","state":{"status":"%s"}}|}
    key_json state

let test_interleaved_keys_and_schema () =
  with_temp_home @@ fun home ->
  let input = String.concat "\n"
      [ snapshot "pi-aaaaaaaaaaaaaaaaaaaa" "working";
        snapshot "pi-bbbbbbbbbbbbbbbbbbbb" "idle";
        snapshot "pi-aaaaaaaaaaaaaaaaaaaa" "done"; "" ]
  in
  let code, _, stderr =
    run_with_input ~home ["oc-plugin"; "stream-write-statefiles"] input
  in
  check int "command succeeds" 0 code;
  check string "no diagnostics" "" stderr;
  let first = read_json (statefile home "pi-aaaaaaaaaaaaaaaaaaaa") in
  let second = read_json (statefile home "pi-bbbbbbbbbbbbbbbbbbbb") in
  check (option string) "first updated" (Some "done")
    Yojson.Safe.Util.(first |> member "state" |> member "status" |> to_string_option);
  check (option string) "second retained" (Some "idle")
    Yojson.Safe.Util.(second |> member "state" |> member "status" |> to_string_option);
  check bool "routing key not persisted" false
    Yojson.Safe.Util.(first |> member "instance_key" <> `Null)

let test_rejects_invalid_lines_and_continues () =
  with_temp_home @@ fun home ->
  let overlong = "a" ^ String.make 128 'b' in
  let input = String.concat "\n"
      [ snapshot "../escape" "bad";
        snapshot "." "bad";
        snapshot ".." "bad";
        snapshot "-leading" "bad";
        snapshot overlong "bad";
        snapshot_with_key_json "42" "bad";
        {|{"instance_key":"pi-missingstate","event":"state.snapshot","ts":"2026-07-23T10:00:00Z"}|};
        {|{"instance_key":"pi-nullstate","event":"state.snapshot","ts":"2026-07-23T10:00:00Z","state":null}|};
        {|{"instance_key":"pi-missingts","event":"state.snapshot","state":{}}|};
        {|{"instance_key":"pi-numberts","event":"state.snapshot","ts":42,"state":{}}|};
        "not-json";
        snapshot "valid.name_with-dash" "safe"; "" ]
  in
  let code, _, _ =
    run_with_input ~home ["oc-plugin"; "stream-write-statefiles"] input
  in
  check int "command succeeds despite rejected lines" 0 code;
  List.iter (fun key ->
    check bool ("rejected key absent: " ^ key) false (Sys.file_exists (statefile home key)))
    ["."; ".."; "-leading"; overlong; "pi-missingstate"; "pi-nullstate";
     "pi-missingts"; "pi-numberts"];
  check bool "traversal target absent" false
    (Sys.file_exists (Filename.concat home ".local/share/c2c/escape/oc-plugin-state.json"));
  check bool "later safe snapshot written" true
    (Sys.file_exists (statefile home "valid.name_with-dash"))

let test_legacy_one_key_command_unchanged () =
  with_temp_home @@ fun home ->
  let key = "pi-legacy00000000000000" in
  let input = {|{"event":"state.snapshot","ts":"2026-07-23T10:00:00Z","state":{"status":"legacy"}}|} ^ "\n" in
  let previous = Sys.getenv_opt "C2C_INSTANCE_NAME" in
  Unix.putenv "C2C_INSTANCE_NAME" key;
  let code, _, _ =
    Fun.protect
      ~finally:(fun () -> match previous with Some value -> Unix.putenv "C2C_INSTANCE_NAME" value | None -> Unix.putenv "C2C_INSTANCE_NAME" "")
      (fun () -> run_with_input ~home ["oc-plugin"; "stream-write-statefile"] input)
  in
  check int "legacy command succeeds" 0 code;
  let stored = read_json (statefile home key) in
  check (option string) "legacy schema readable" (Some "legacy")
    Yojson.Safe.Util.(stored |> member "state" |> member "status" |> to_string_option)

let () =
  Alcotest.run "c2c_statefile_multi"
    [ "stream-write-statefiles",
      [ test_case "interleaved keys preserve schema" `Quick test_interleaved_keys_and_schema;
        test_case "invalid lines rejected and stream continues" `Quick test_rejects_invalid_lines_and_continues;
        test_case "legacy one-key command remains compatible" `Quick test_legacy_one_key_command_unchanged ] ]
