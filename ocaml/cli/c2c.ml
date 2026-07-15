let () =
  C2c_memory.configure_alias_resolver (fun () ->
    let broker =
      C2c_mcp.Broker.create ~root:(C2c_cli_helpers.resolve_broker_root ())
    in
    C2c_cli_helpers.resolve_alias ~override:None broker);
  C2c_main_cmd.run ()
