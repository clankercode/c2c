# Kimi MCP Startup Masked Dune /tmp Quota Failure

## Symptom

Kimi one-shot probes failed before model work with:

```text
Failed to connect MCP servers: {'c2c': RuntimeError('Client failed to connect: Connection closed')}
```

Direct wrapper probes also failed:

```text
python3 c2c_mcp.py --help
Command exited with code 2.
-> required by loading the OCaml compiler for context "default"
-> required by _build/default/.dune/configurator
```

The Dune output did not show the underlying OS write failure.

## Discovery

A minimal Dune smoke project in `/tmp` failed while writing a tiny file:

```text
/usr/bin/bash: line 1: printf: write error: Disk quota exceeded
```

`df -h /tmp` showed `/tmp` was mostly full, and several stale temporary build
directories from April 11-12 were large:

```text
1.6G /tmp/codename-thin-game-list-52
479M /tmp/bevy-check
381M /tmp/tween-inspect
81M  /tmp/check_caps
```

After removing those stale `/tmp` build/probe directories, a Dune smoke build
worked again, `dune build ./ocaml/server/c2c_mcp_server.exe` worked, and
`python3 c2c_mcp.py --help` reached the built server instead of closing.

## Root Cause

The c2c MCP wrapper builds the OCaml server on startup. Dune needs to write its
context/configurator state. When `/tmp` was out of quota/headroom, Dune failed
while loading the compiler context and the MCP process exited before speaking
stdio JSON-RPC. Kimi reported this only as a generic MCP connection close.

## Fix Status

Mitigated live by deleting stale `/tmp` build/probe directories:

```text
/tmp/codename-thin-game-list-52
/tmp/bevy-check
/tmp/tween-inspect
/tmp/check_caps
/tmp/dbg
/tmp/attn-tool-test
/tmp/attn-test
/tmp/attn-debug
```

Recommended follow-ups:

- Add a clearer preflight or error message in `c2c_mcp.py` when the Dune build
  step fails, including stderr/stdout and a hint to check `/tmp` quota.
- Consider avoiding a build on every MCP startup when a current binary already
  exists, or make build-on-start optional for clients like Kimi that fail hard
  on MCP startup errors.
- Periodically prune stale `/tmp` harness/build directories during long swarm
  sessions.

## Severity

High for new client onboarding. Kimi and any other client that loads c2c through
MCP can appear broken even though the broker and config are fine.
