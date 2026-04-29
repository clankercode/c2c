# Independent Verification: kimi dual-process bug (#457)

**Verifier**: birch-coder
**Date**: 2026-04-29
**Status**: INCONCLUSIVE FROM CODE INSPECTION — root cause not confirmed in OCaml path

---

## Summary

Stanza's theory: `c2c start kimi` spawns a recursive `c2c start kimi`, creating a dual-process wedge.

**Finding from independent code walk**: The OCaml `c2c start kimi` path does NOT contain any `c2c start kimi` recursive invocation. The spawn chain is clean: `cmd_start` → fork → exec `kimi --wire ...` (NOT `c2c start kimi`). The nested session guard blocks recursive spawns via environment variable detection.

**Possibility A**: The bug was already fixed (instances `kuura-viima` and `lumi-tyyni` are not currently running; no live kimi process tree available to verify)

**Possibility B**: The root cause is in a different layer (kimi app internals, MCP client auto-start, or a race condition that manifests only under specific timing)

**Possibility C**: The bug description maps to a different symptom than "recursive c2c start kimi"

---

## Code Walk: `c2c start kimi` Path

### Entry point: `cmd_start` (c2c_start.ml:4249)

```
cmd_start ~client:"kimi" ~name → start_one_iteration
```

### Nested session guard (c2c_start.ml:4283–4331)

Three checks fire when `C2C_MCP_SESSION_ID` or `C2C_MCP_AUTO_REGISTER_ALIAS` are set WITHOUT `C2C_WRAPPER_SELF`:
- `Some _, None, None` → FATAL: refuse nested session
- `None, Some _, None` → FATAL: refuse nested session
- `Some _, Some _, None` → FATAL: refuse nested session

The wrapper process sets `C2C_WRAPPER_SELF` in `build_env` (c2c_start.ml:2288) so managed clients bypass these checks.

**This guard prevents accidental recursive `c2c start kimi` invocation from within a session.**

### Client binary resolution (c2c_start.ml:3427–3438)

For `kimi`:
- `KimiAdapter.binary = "kimi"` (c2c_start.ml:2847)
- Resolved via `find_binary "kimi"` → path to `kimi` binary
- `binary_path = "/home/xertrov/.local/bin/kimi"` (from meta.json of kuura-viima)

### Child process spawn (c2c_start.ml:3861–3915)

```ocaml
match Unix.fork () with
| 0 (* child *) →
    (* setsid, setpgid, dup fds *)
    Unix.execvpe "kimi" [|"kimi"; "--wire"; "--yolo"; "--work-dir"; ...; "--mcp-config-file"; tmp_config|] env
| p → (* parent records p, continues outer loop *)
```

**Key: The child exec's `kimi` directly — NOT `c2c start kimi`.** The `kimi` binary is the Kimi CLI, which then parses its own `--wire` flag.

### Kimi MCP config (c2c_start.ml:2419–2437)

```ocaml
build_kimi_mcp_config name br alias_override →
  `Assoc ["mcpServers", `Assoc ["c2c",
    `Assoc ["type","stdio";
            "command","python3";
            "args", `List [script_path];
            "env", `Assoc [
              "C2C_MCP_BROKER_ROOT", br;
              "C2C_MCP_SESSION_ID", name;  (* session = instance name *)
              "C2C_MCP_AUTO_REGISTER_ALIAS", alias;
              "C2C_MCP_AUTO_JOIN_ROOMS", "swarm-lounge";
              "C2C_MCP_AUTO_DRAIN_CHANNEL", "0";
            ]]]]
```

The MCP server is `python3 c2c_mcp.py`. It runs as a subprocess of `kimi` (stdio mode). The `C2C_MCP_SESSION_ID` is set to the **instance name** (e.g. `kuura-viima`), NOT to the outer session ID.

### Wire daemon (c2c_start.ml:3236–3245)

For `kimi`, `needs_wire_daemon = true` (c2c_start.ml:2849). The wire daemon is started after the child spawn:

```ocaml
(if !wire_pid = None && cfg.needs_wire_daemon then
   match start_wire_daemon ~name ~alias ~broker_root () with ...)
```

`start_wire_daemon` calls `C2c_wire_daemon.start_daemon` which forks a child that runs `while true do C2c_wire_bridge.run_once_live ...; Unix.sleepf interval done`. This is an OCaml daemon loop, NOT `kimi`.

### Sidecar processes spawned

| Sidecar | Command | Fork type |
|---|---|---|
| deliver daemon | `c2c deliver-inbox --loop ...` | `Unix.fork()` + `execvpe` |
| poker | `python3 c2c_poker.py ...` | `Unix.create_process_env` |
| wire daemon | OCaml loop in same process | `Unix.fork()` + OCaml loop |

**None of these invoke `c2c start kimi`.**

---

## What the Python MCP server (`c2c_mcp.py`) does

`c2c_mcp.py` is the MCP server for kimi. It:
1. Inherits env: `C2C_MCP_BROKER_ROOT`, `C2C_MCP_SESSION_ID=<instance-name>`, `C2C_MCP_AUTO_REGISTER_ALIAS`, etc.
2. Checks `server_is_fresh` — may run `dune build` if binary stale
3. `subprocess.run([server_path, ...args])` — the OCaml MCP server

**The Python MCP server does NOT spawn `c2c start kimi`.**

---

## Where the "dual-process" symptom COULD come from

### 1. Kimi's own MCP client spawning a `kimi` child process

Kimi's `--wire` mode starts the MCP server as a subprocess. The MCP server (`c2c_mcp.py`) runs as a child of `kimi --wire`. This is expected.

If "dual-process" means: `kimi --wire` (parent) + MCP server child — this is the NORMAL shape, not a bug.

### 2. Wire daemon run_once_live creating a new `kimi --wire` child (c2c_wire_bridge.ml:226-235)

```ocaml
let argv = [| "kimi"; "--wire"; "--yolo"; "--work-dir"; work_dir;
              "--mcp-config-file"; tmp_config |] in
Unix.create_process_env "kimi" argv (Unix.environment ())
  child_stdin_r child_stdout_w Unix.stderr
```

This creates `kimi --wire --yolo --work-dir ... --mcp-config-file <tmp>` as a subprocess of the wire daemon. This is intentional — the wire daemon polls the broker and delivers via `kimi --wire`.

But this is `kimi --wire` (not `c2c start kimi`), and it runs as a child of the wire daemon, which is itself a child of the outer `c2c start kimi` wrapper.

**Process tree would be:**
```
c2c start kimi (outer wrapper, OCaml)
  ├─ kimi --wire --yolo --mcp-config-file (managed client, exec'd)
  │   └─ c2c_mcp.py → c2c_mcp_server.exe (MCP subprocess)
  └─ wire-daemon (OCaml, fork from outer wrapper)
      └─ kimi --wire --yolo --mcp-config-file (polling delivery subprocess)
```

This is 2-level (outer + inner managed client), NOT a recursive `c2c start kimi → c2c start kimi` chain.

### 3. Session ID confusion causing registration under wrong identity

The MCP server inherits `C2C_MCP_SESSION_ID=<instance-name>` from the wrapper env. This is correct — the instance name IS the session ID.

But if `C2C_MCP_AUTO_REGISTER_ALIAS` is also set to the instance name, and the wrapper process's own registration uses the same alias... there could be an alias collision where the inner kimi registers with the same alias as the outer wrapper.

**The outer wrapper (`c2c start kimi`) does NOT register with the broker** — it only manages sidecars. Only the inner `kimi` (via its MCP server) registers. So no collision.

### 4. The meta.json PID confusion (minor)

The `meta.json` is written AFTER the fork but BEFORE the exec:
```ocaml
let pid = Unix.getpid ()  (* this is the OUTER wrapper PID, before exec *)
```

The written PID is the outer wrapper's PID, not the inner `kimi` PID. This could cause `c2c restart` to signal the wrong process if `restart-self` reads this PID.

---

## Reconciliation with stanza's live pstree finding (`b6455d8e`)

**UPDATE (2026-04-29, after coordinating with stanza)**:

Stanza's finding `b6455d8e` independently confirms and sharpens this walk. Key reconciliation:

### Mislabeling in pstree

The process tree shows:
```
└── c2c start kimi -n lumi-tyyni (3633154)
```

But this is **NOT** a `c2c start kimi` invocation — it is the wire-daemon's forked child that inherited argv from the parent (because `fork` without `execve` preserves the parent's argv). The actual running code is `C2c_wire_daemon.start_daemon`'s forever loop, NOT `c2c-start` logic. Pstree mislabels it.

This matches my static finding: there is NO `c2c start kimi` in the spawn chain.

### The actual dual-agent mechanism

The wire-daemon's `run_once_live` (c2c_wire_bridge.ml:212-275) forks a child that exec's `kimi --wire --yolo --mcp-config-file <tmp>`. This is NOT a thin relay — `kimi --wire` is a **fully agentic kimi instance** with the same tool loop as the TUI. It:

1. Registers with the broker using the **same alias** as the TUI (because `auto_register_alias` in the tmp MCP config equals the instance name)
2. Blocks on `wire_prompt wc (format_prompt ...)` (c2c_wire_bridge.ml:271) — a substantive prompt can run 30s–3min
3. During this time: **TWO live kimi agents share one alias**, both poll inbox, both can act
4. The wire-daemon kimi subprocess does the actual work (commits, peer DMs); the TUI sits idle

### Operational consequences (from stanza's finding)

- **TUI invisibility**: FG TUI never displays messages the BG agent processes
- **Latency races**: wire-daemon kimi acts on messages before TUI sees them
- **Author leak**: bridge subprocess's PATH exposes the committing agent's identity
- **Orphan-survivors on stop**: wire-daemon kimi subprocess outlives the managed session (confirmed: kuura routed a peer-PASS to cedar AFTER `c2c stop`)

### Confirmed by both walks

| Aspect | Static walk (birch) | Live pstree (stanza) |
|---|---|---|
| No recursive `c2c start kimi` | ✓ (code shows `exec kimi --wire`) | ✓ (argv-inherited fork mislabeled as `c2c start kimi`) |
| Wire-daemon spawns kimi subprocess | ✓ | ✓ |
| kimi subprocess is fully agentic | Not assessed (static only) | ✓ (live observation) |
| Dual-agent with shared alias | Structural risk identified | Confirmed with live evidence |

### Cross-reference

- This doc: `.collab/research/2026-04-29-kimi-dual-process-independent-verify-birch.md`
- Stanza's finding: `.collab/findings/2026-04-29T10-04-00Z-stanza-coder-c2c-start-kimi-spawns-double-process.md` (SHA `b6455d8e`)

---

## Files examined

| File | Relevant lines | Purpose |
|---|---|---|
| `ocaml/c2c_start.ml` | 176, 1082, 1201, 2288, 2419-2437, 2520-2527, 2841-2888, 3236-3245, 3427-3438, 3861-3915, 4074-4084, 4249-4331 | Full kimi start path |
| `ocaml/c2c_wire_bridge.ml` | 214-275 | Wire delivery: `kimi --wire` subprocess |
| `ocaml/c2c_wire_daemon.ml` | 76-127 | Wire daemon: fork + OCaml loop |
| `ocaml/c2c_poker.ml` | 14-33 | Poker sidecar |
| `c2c_mcp.py` | 280-357 | Python MCP server bootstrap |
| `ocaml/c2c_start.mli` | 69 | `needs_wire_daemon: bool` |
