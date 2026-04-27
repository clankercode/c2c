(* c2c_mcp_server — standalone MCP server binary entry point.
    Thin shim that calls run_inner_server from c2c_mcp_server_inner.

    Installed as: ~/.local/bin/c2c-mcp-server
    Used by: c2c install (writes this path into client MCP configs)

    Slice A: this is the binary installed as c2c-mcp-inner alongside.
    Slice B: this becomes the outer proxy; the inner refactors behind run_inner_server.
 *)

let ( // ) = Filename.concat

let server_banner () =
  Version.banner ~role:"mcp-server" ~git_hash:C2c_mcp.server_git_hash

let xdg_state_home () =
  match Sys.getenv_opt "XDG_STATE_HOME" with
  | Some v when String.trim v <> "" -> String.trim v
  | _ ->
      (match Sys.getenv_opt "HOME" with
       | Some h when String.trim h <> "" -> String.trim h // ".local" // "state"
       | _ -> "/tmp")

let resolve_broker_root () =
  let abs_path p = if Filename.is_relative p then Sys.getcwd () // p else p in
  match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
  | Some dir -> abs_path dir
  | None -> (
      match Git_helpers.git_common_dir () with
      | Some git_dir -> abs_path git_dir // "c2c" // "mcp"
      | None -> xdg_state_home () // "c2c" // "default" // "mcp")

let () =
  server_banner ();
  let root = resolve_broker_root () in
  C2c_mcp_server_inner.run_inner_server ~broker_root:root
