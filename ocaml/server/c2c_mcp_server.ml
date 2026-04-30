(* c2c_mcp_server — standalone MCP server binary entry point.
    Thin shim that calls run_inner_server from c2c_mcp_server_inner.

    Installed as: ~/.local/bin/c2c-mcp-server
    Used by: c2c install (writes this path into client MCP configs)

    Slice A: this is the binary installed as c2c-mcp-inner alongside.
    Slice B: this becomes the outer proxy; the inner refactors behind run_inner_server.
 *)

let server_banner () =
  Version.banner ~role:"mcp-server" ~git_hash:C2c_mcp.server_git_hash

(* #503: delegate to canonical resolver in C2c_repo_fp.
   Previously this had its own resolver that fell back to legacy
   `<git-common-dir>/c2c/mcp` when env was unset, causing split-brain
   after migration: stanza launched with C2C_MCP_BROKER_ROOT correctly
   resolved canonical, but agents whose env didn't propagate fell
   through to legacy and silently wrote to a different broker. *)
let resolve_broker_root () = C2c_repo_fp.resolve_broker_root ()

let () =
  server_banner ();
  let root = resolve_broker_root () in
  C2c_mcp_server_inner.run_inner_server ~broker_root:root
