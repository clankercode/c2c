(* test_c2c_broker_canonical_alias_deprecation.ml — slice 3 tests for the
   opaque_host_id design (.collab/design/2026-06-17-c2c-opaque-host-id.md).

   Verifies that the C2C_DEPRECATE_CANONICAL_ALIAS env var gates whether
   the local broker's canonical_alias keeps its old leaky form
   (<alias>#<repo>@<host>) or the new opaque form (<alias>#<host_id>).

   Coverage:
   1. Default (flag unset): canonical_alias is "<alias>#<repo>@<host>".
   2. Flag set: canonical_alias is "<alias>#<host_id>".
   3. The helper function compute_canonical_alias produces both forms.
   4. Re-registration on an existing root picks up the flag at create time.
*)

open Alcotest
open C2c_mcp

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base (Printf.sprintf "c2c-ca-dep-%08x" (Random.bits ())) in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) |> ignore)
    (fun () -> f dir)

let set_env_flag () = Unix.putenv "C2C_DEPRECATE_CANONICAL_ALIAS" "1"
let clear_env_flag () =
  Unix.putenv "C2C_DEPRECATE_CANONICAL_ALIAS" ""

let test_default_canonical_alias_is_leaky () =
  with_temp_dir (fun dir ->
      clear_env_flag ();
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a" ~alias:"storm-ember"
        ~pid:None ~pid_start_time:None ();
      let reg = List.hd (C2c_mcp.Broker.list_registrations broker) in
      match reg.canonical_alias with
      | None -> fail "expected canonical_alias to be set"
      | Some ca ->
        check bool "contains repo slug" true (String.contains ca '#');
        check bool "contains hostname" true (String.contains ca '@');
        check bool "does not contain host_id (12 hex)" false
          (String.length ca > 14 &&
           let suffix = String.sub ca (String.length ca - 12) 12 in
           String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) suffix))

let test_deprecated_canonical_alias_is_opaque () =
  with_temp_dir (fun dir ->
      set_env_flag ();
      Fun.protect
        ~finally:clear_env_flag
        (fun () ->
           let broker = C2c_mcp.Broker.create ~root:dir in
           C2c_mcp.Broker.register broker ~session_id:"session-a" ~alias:"storm-ember"
             ~pid:None ~pid_start_time:None ();
           let reg = List.hd (C2c_mcp.Broker.list_registrations broker) in
           let host_id = Host_id.compute_host_hash () in
           let expected = Printf.sprintf "storm-ember#%s" host_id in
           match reg.canonical_alias with
           | None -> fail "expected canonical_alias to be set"
           | Some ca -> check string "opaque canonical_alias" expected ca;
             check bool "no '@' in opaque form" false (String.contains ca '@')))

let test_compute_canonical_alias_both_forms () =
  let leaky = C2c_mcp.Broker.compute_canonical_alias
      ~alias:"pi-c01ea5" ~broker_root:"/tmp/repo/.git/c2c/mcp" () in
  check string "leaky form" "pi-c01ea5#repo@xsm" leaky;
  let opaque = C2c_mcp.Broker.compute_canonical_alias
      ~deprecate_canonical_alias:true ~alias:"pi-c01ea5" ~broker_root:"/tmp/repo/.git/c2c/mcp" () in
  let host_id = Host_id.compute_host_hash () in
  check string "opaque form" (Printf.sprintf "pi-c01ea5#%s" host_id) opaque

let test_flag_is_read_at_create_time () =
  with_temp_dir (fun dir ->
      clear_env_flag ();
      let broker1 = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker1 ~session_id:"session-a" ~alias:"storm-ember"
        ~pid:None ~pid_start_time:None ();
      set_env_flag ();
      Fun.protect
        ~finally:clear_env_flag
        (fun () ->
           let broker2 = C2c_mcp.Broker.create ~root:dir in
           C2c_mcp.Broker.register broker2 ~session_id:"session-b" ~alias:"storm-storm"
             ~pid:None ~pid_start_time:None ();
           let regs = C2c_mcp.Broker.list_registrations broker2 in
           let a = List.find (fun r -> r.alias = "storm-ember") regs in
           let b = List.find (fun r -> r.alias = "storm-storm") regs in
           check bool "old reg still leaky" true
             (Option.fold ~none:false ~some:(fun s -> String.contains s '@') a.canonical_alias);
           check bool "new reg is opaque" true
             (Option.fold ~none:false ~some:(fun s -> not (String.contains s '@')) b.canonical_alias)))

let () =
  run "Test_c2c_broker_canonical_alias_deprecation"
    [ "canonical_alias forms", [
        test_case "default keeps leaky repo@host form" `Quick
          test_default_canonical_alias_is_leaky;
        test_case "C2C_DEPRECATE_CANONICAL_ALIAS=1 uses opaque host id" `Quick
          test_deprecated_canonical_alias_is_opaque;
        test_case "compute_canonical_alias helper produces both forms" `Quick
          test_compute_canonical_alias_both_forms;
        test_case "flag is read at broker create time" `Quick
          test_flag_is_read_at_create_time;
      ] ]
