(* c2c_relay_pins_cmd - relay TOFU pin operator command assembly.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open Cmdliner.Term.Syntax

let relay_pins_delete_cmd =
  let open Cmdliner in
  let alias_flag =
    Arg.(required & pos 0 (some string) None & info []
           ~docv:"ALIAS" ~doc:"Target alias whose pins to delete.")
  in
  let ed25519_flag =
    Arg.(value & flag & info ["ed25519"]
           ~doc:"Delete the Ed25519 pin for the alias.")
  in
  let x25519_flag =
    Arg.(value & flag & info ["x25519"]
           ~doc:"Delete the X25519 pin for the alias.")
  in
  let min_version_flag =
    Arg.(value & flag & info ["min-version"]
           ~doc:"Delete the min-observed-envelope-version pin for the alias.")
  in
  let all_flag =
    Arg.(value & flag & info ["all"]
           ~doc:"Delete all three pin types for the alias (default if no axis flag is given).")
  in
  let+ alias = alias_flag
  and+ delete_ed25519 = ed25519_flag
  and+ delete_x25519 = x25519_flag
  and+ delete_min_version = min_version_flag
  and+ delete_all = all_flag in
  let axes =
    if delete_all || (not delete_ed25519 && not delete_x25519 && not delete_min_version) then
      ["ed25519"; "x25519"; "min_observed_envelope_version"]
    else
      (if delete_ed25519 then ["ed25519"] else [])
      @ (if delete_x25519 then ["x25519"] else [])
      @ (if delete_min_version then ["min_observed_envelope_version"] else [])
  in
  if axes = [] then
    (Printf.eprintf "Error: no pin axis specified. Use --all or at least one of --ed25519, --x25519, --min-version.\n%!";
     exit 1);
  let broker_root = C2c_utils.resolve_broker_root () in
  ignore (C2c_mcp.Broker.create ~root:broker_root);
  C2c_mcp.Broker.relay_pin_delete ~broker_root ~alias ~axes;
  let axes_str = String.concat ", " axes in
  Printf.printf "Deleted %s pins for alias %s.\n" axes_str alias;
  Printf.printf "Audit event written to broker.log.\n";
  exit 0

let relay_pins_delete : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "delete"
       ~doc:"Delete one or more TOFU pins for an alias.")
    relay_pins_delete_cmd

let relay_pins_rotate_cmd =
  let open Cmdliner in
  let alias_flag =
    Arg.(required & pos 0 (some string) None & info []
           ~docv:"ALIAS" ~doc:"Target alias whose pins to rotate.")
  in
  let+ alias = alias_flag in
  let broker_root = C2c_utils.resolve_broker_root () in
  ignore (C2c_mcp.Broker.create ~root:broker_root);
  let epoch = C2c_mcp.Broker.relay_pin_rotate ~broker_root ~alias in
  Printf.printf "Rotated all pins for alias %s (rotation_epoch=%d).\n" alias epoch;
  Printf.printf "Next first-contact from this alias will be logged as expected (TOFU first-seen).\n";
  Printf.printf "Audit event written to broker.log.\n";
  exit 0

let relay_pins_rotate : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "rotate"
       ~doc:"Rotate all TOFU pins for an alias (clears keys and bumps rotation epoch).")
    relay_pins_rotate_cmd

let relay_pins_list_cmd : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "list"
       ~doc:"List all pinned aliases and their key fingerprints + min-observed-envelope-version. Alias for relay-pin-status.")
    C2c_doctor_cmd.relay_pin_status_cmd

let relay_pins : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.group
    ~default:C2c_doctor_cmd.relay_pin_status_cmd
    (Cmdliner.Cmd.info "relay-pins"
       ~doc:"Inspect and manage broker TOFU pins (relay_pins.json).")
    [ relay_pins_list_cmd; C2c_doctor_cmd.relay_pin_status; relay_pins_delete; relay_pins_rotate ]
