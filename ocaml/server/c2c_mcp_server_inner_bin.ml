(* c2c_mcp_server_inner_bin — entry point for the c2c-mcp-inner binary.
    Installed as: ~/.local/bin/c2c-mcp-inner
    Runs the same full-featured MCP server as c2c-mcp-server.
    Used by c2c mcp-inner CLI command (proxied via just).

    Slice A: this binary is installed alongside c2c-mcp-server.
    Slice B: this becomes the inner server behind the outer proxy.
 *)

let server_banner () =
  Version.banner ~role:"mcp-inner" ~git_hash:C2c_mcp.server_git_hash

(* #503: see c2c_mcp_server.ml — delegate to canonical resolver. *)
let resolve_broker_root () = C2c_repo_fp.resolve_broker_root ()

let () =
  server_banner ();
  let root = resolve_broker_root () in
  C2c_mcp_server_inner.run_inner_server ~broker_root:root
