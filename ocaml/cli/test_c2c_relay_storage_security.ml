(* B266: production relay storage security. Drives the freshly-built c2c.exe;
   the command must refuse before binding a socket, so this test is hermetic. *)

open Alcotest

let c2c_binary =
  Filename.concat (Filename.dirname Sys.executable_name) "c2c.exe"

let read_all ic =
  let buffer = Buffer.create 256 in
  (try while true do Buffer.add_string buffer (input_line ic); Buffer.add_char buffer '\n' done
   with End_of_file -> ());
  Buffer.contents buffer

let run args =
  let out_r, out_w = Unix.pipe () in
  let err_r, err_w = Unix.pipe () in
  let argv = Array.of_list (c2c_binary :: args) in
  let pid = Unix.create_process c2c_binary argv Unix.stdin out_w err_w in
  Unix.close out_w; Unix.close err_w;
  let stdout = Unix.in_channel_of_descr out_r |> read_all in
  let stderr = Unix.in_channel_of_descr err_r |> read_all in
  let _, status = Unix.waitpid [] pid in
  let code = match status with Unix.WEXITED n -> n | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n in
  code, stdout, stderr

let contains hay needle =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

let test_token_memory_refused () =
  let code, stdout, stderr =
    run [ "relay"; "serve"; "--token"; "secret"; "--storage"; "memory";
          "--listen"; "127.0.0.1:1" ]
  in
  check int "exit nonzero" 1 code;
  check bool "no memory server banner" false (contains stdout "storage: memory");
  check bool "actionable durable-storage error" true
    (contains stderr "token-configured relay requires --storage sqlite")

let () =
  Alcotest.run "c2c_relay_storage_security"
    [ ("production storage",
       [ test_case "token + memory refuses before listen" `Quick
           test_token_memory_refused ]) ]
