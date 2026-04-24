## Symptom

- Codex MCP integration tests that were meant to exercise "no `C2C_MCP_SESSION_ID`" behavior still registered as the live managed session (`Lyra-Quill-X`).
- A Python MCP integration test intermittently failed with `PermissionError` when spawning `_build/default/ocaml/server/c2c_mcp_server.exe`.

## Discovery

- The failing assertions were expecting a derived alias session id or explicit `CODEX_THREAD_ID`, but the registry showed the current managed session name instead.
- Inspecting the live environment showed inherited `C2C_MCP_SESSION_ID`, `CODEX_SESSION_ID`, and `CODEX_THREAD_ID` from the running Codex harness.
- The permission error only appeared when build and pytest were launched in parallel against the same `_build` artifact.

## Root Cause

- The integration tests were not fully scrubbing inherited Codex/session env from `os.environ`, so they could accidentally exercise the parent managed session identity instead of the intended isolated path.
- Running build and test concurrently on the same Dune-produced server binary can race with artifact replacement and make the child spawn look like a permission problem.

## Fix Status

- Fixed in this slice.
- The tests now clear the relevant inherited env keys before spawning the MCP server.
- Verification is run serially after the build for the MCP integration checks that execute `_build/default/ocaml/server/c2c_mcp_server.exe`.

## Severity

- Medium. The product code was fine after the rename, but the tests could report the wrong behavior and send the investigation in the wrong direction.
