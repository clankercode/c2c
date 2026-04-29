# 406 S3 Research: Volume UID Issue in Docker E2E Tests

**Author**: galaxy-coder
**Date**: 2026-04-29
**Branch**: slice/406-e2e-docker-mesh-s2
**Status**: Research only — no code changes

## Problem Statement

The S2 smoke test (`test_codex_headless_agent.py`) has 8 skipped tests due to a
"volumes/ + --build" infrastructure issue. Specifically:

1. **Symptom**: `docker build -f Dockerfile.agent` fails because the Docker build
   context cannot read subdirectories of `volumes/` bind mounts (owned by uid=999
   from a prior container run).
2. **Symptom**: Even after excluding `volumes/` from the build context, the
   Python deliver daemon (`c2c_deliver_inbox.py`) cannot start inside the container
   because it imports `c2c_mcp.py`, which in turn imports `c2c_registry.py`,
   `c2c_broker_gc.py`, `c2c_whoami.py`, and `claude_list_sessions.py` — none of
   which are bundled in the image.

This document analyzes both symptoms and proposes mitigation options.

---

## Root Cause Analysis

### Issue 1: Build Context Cannot Read Volume Bind Mounts

**What happens**:
- `docker-compose.agent-mesh.yml` defines named bind mounts:
  ```
  volumes/relay-a:/var/lib/c2c/relay-a-state   (uid=999 inside container)
  volumes/relay-b:/var/lib/c2c/relay-b-state   (uid=999 inside container)
  ```
- These directories are part of the repository tree on the host.
- When `docker build` runs, it scans the build context (the worktree root).
  Docker's build context includes `volumes/` as a directory, but the **contents**
  of bind-mounted subdirectories are unreadable to the build process if they are
  owned by a uid that the build user cannot access.
- Error seen:
  ```
  checking context: no permission to read from '.../volumes/relay-a/relay-server-identity.json'
  ```

**Why it happens**:
- Docker bind mounts preserve the uid/gid of the container process that created
  the files (uid=999 from the relay container).
- The Docker build runs as the current user on the host (uid=1000).
- The build daemon cannot `stat()` files owned by uid=999 if host filesystem
  permissions deny read.

**Who creates what**:
| File/Dir | Created by | UID | On host readable by build? |
|---|---|---|---|
| `volumes/relay-a/` | Host `mkdir` | 1000 (xertrov) | Yes (parent dir) |
| `volumes/relay-a/*` | relay-a container | 999 | Only if parent dir allows traversal |
| `volumes/codex-a1/` | Host `mkdir` | 1000 | Yes |
| `volumes/codex-a1/*` | codex-a1 container (not yet run) | — | N/A (empty) |

**Key insight**: The **files inside** `volumes/relay-a/` (created by the relay
container at runtime) are the problem. The parent directory `volumes/` is
readable; it's the container-owned files inside that block the build context scan.

### Issue 2: Python Deliver Daemon Has Deep OCaml-Side Import Dependencies

**What `c2c_deliver_inbox.py` needs at runtime**:

| Module | Bundled in Dockerfile.agent? | Notes |
|---|---|---|
| `c2c_poll_inbox.py` | ✅ Yes | Direct import |
| `c2c_poker.py` | ✅ Yes | Direct import |
| `c2c_mcp.py` | ✅ Yes | Direct import |
| `c2c_registry.py` | ❌ No | OCaml-adjacent broker/registry logic |
| `c2c_broker_gc.py` | ❌ No | Broker GC |
| `c2c_whoami.py` | ❌ No | Session identification |
| `claude_list_sessions.py` | ❌ No | Claude session listing |
| `c2c_poker.py` | ✅ Yes | Already bundled |

**Root cause**: `c2c_deliver_inbox.py` was designed to run on the **host** alongside
the OCaml c2c binary. It is not isolated — it imports the full OCaml-adjacent
Python broker stack (c2c_registry, c2c_mcp, etc.). The host has all these modules
in the repo root; bundling only the 4 "direct" files breaks at the second-level
imports.

**Verification**: Inside the container:
```
python3 /usr/local/bin/c2c_deliver_inbox.py --help
→ ModuleNotFoundError: No module named 'c2c_registry'
```

---

## Mitigation Options

### Option A: Exclude `volumes/` from Build Context + Host-Side Deliver Daemon

**Description**: Keep `volumes/` excluded from the Docker build context (fixes Issue 1).
Run the deliver daemon on the **host** instead of inside the agent container
(fixes Issue 2). The host's deliver daemon connects to the broker via HTTP
(reading the same `C2C_MCP_BROKER_ROOT` volume mount).

**Pros**:
- No dependency bundling needed — host has full Python stack
- Deliver daemon runs on proven host infrastructure
- Volumes issue disappears (volumes/ excluded from context)

**Cons**:
- Requires host-side deliver daemon process alongside each agent container
- Adds orchestration complexity (must start host-side daemon before container)
- The agent container cannot self-contained run the deliver daemon — couples the
  test harness to host-side setup
- For CI/untrusted environments, running host-side Python may not be desired

**Effort**: Low — already partially done (volumes/ excluded in worktree)

**Recommendation**: Best for **local development** where the host is always available.

---

### Option B: Bundle All Required Python Modules in Image

**Description**: Add all Python modules needed by `c2c_deliver_inbox.py` (including
`c2c_registry.py`, `c2c_broker_gc.py`, `c2c_whoami.py`, `claude_list_sessions.py`,
plus `c2c_relay_connector.py`, `c2c_relay_rooms.py`, and their transitive deps)
to the image via `.dockerignore` negated exceptions.

**Pros**:
- Fully self-contained container — no host-side dependencies
- Works in CI, air-gapped environments, any host

**Cons**:
- Image grows significantly (~15+ Python modules)
- Many of these modules have their own complex dependencies (sqlite3, json, etc.)
  that may not be fully portable
- Risk: some modules may have C extensions or OS-level dependencies not present
  in python:3.12-slim
- High maintenance burden: every time a new Python module is added to the OCaml
  side's import chain, Dockerfile.agent must be updated
- **Unknown**: Whether some of these modules depend on OCaml FFI or other
  host-specific paths that won't work in a container at all

**Effort**: Medium-High — need to audit all transitive imports and test in image

**Recommendation**: Not recommended unless the container must be fully self-contained
and the deliver daemon must run inside it.

---

### Option C: Use OCaml c2c-Deliver-Inbox Binary (Not Python)

**Description**: The OCaml `c2c-deliver-inbox` binary (already built by `dune build`)
is self-contained with no external Python dependencies. If we can build it inside
the Docker image (it already is — the `builder` stage produces it), we can use the
OCaml binary instead of the Python deliver daemon.

**Current state**:
- `Dockerfile.agent` already copies the OCaml binary: `COPY --from=builder /home/opam/c2c/_build/default/ocaml/cli/c2c.exe /usr/local/bin/c2c`
- The OCaml binary has a `deliver-inbox` subcommand (or equivalent)
- The `justfile` recipe `c2c-deliver-inbox` uses the **Python** shim on host:
  ```
  @just各市ocker exec -it $(cat $JUST_INSTANCE_PIDFILE) \
      /usr/bin/env bash -c "exec python3 $PWD/c2c_deliver_inbox.py"
  ```
  But the underlying `c2c deliver-inbox` OCaml command exists.

**Pros**:
- Zero additional dependencies — OCaml binary is already in the image
- Self-contained, portable, no Python import chains
- Matches what `c2c start codex` would actually use in production
- Removes the entire Python deliver daemon complexity from the container

**Cons**:
- The OCaml `c2c deliver-inbox` subcommand may have different interface/flags
  than the Python version — needs verification
- The OCaml binary may depend on shared libraries (libev, libssl, etc.) that
  are present in python:3.12-slim via the `apt-get install` step — verified ✅

**Effort**: Low-Medium — verify OCaml deliver-inbox subcommand exists and has
equivalent functionality; update compose to use it instead of Python shim

**Recommendation**: **Best long-term solution** — fully self-contained, matches
production, eliminates the Python dependency chain entirely.

---

## Ranked Recommendations

| Priority | Option | Rationale |
|---|---|---|
| 1 (do first) | **A: Host-side deliver daemon** | Quickest fix; already partially working; unblocks the smoke tests immediately |
| 2 (defer to S3/S4) | **C: OCaml binary** | Cleaner long-term solution; verify OCaml deliver-inbox subcommand works equivalently |
| 3 (avoid) | **B: Bundle all Python modules** | High maintenance burden, unknown transitive deps, fragile |

---

## Immediate Next Steps (for S3 or S4)

1. **Verify OCaml `c2c deliver-inbox` subcommand** exists and has equivalent
   functionality to `c2c_deliver_inbox.py` (poll interval, PTY injection, etc.)
2. **If C works**: Update `docker-compose.agent-mesh.yml` to run the OCaml binary
   as the deliver daemon inside the agent container; remove all Python deliver
   script bundling from `Dockerfile.agent`
3. **If C doesn't work**: Fall back to Option A (host-side daemon) and document
   the compose change needed to start the host-side daemon alongside containers
4. **If neither works**: Accept the 8 skipped tests as known infrastructure
   limitation; file a follow-up issue (#406-S?) for a proper redesign

---

## Open Questions

- Does the OCaml `c2c deliver-inbox` binary support the same `--daemon` /
  poll-interval /PTY-injection flags as the Python version?
- Can `c2c start codex-headless` run the OCaml deliver-inbox subcommand instead
  of spawning a separate daemon process?
- Are there any other OCaml-side binaries needed inside the agent container beyond
  `c2c.exe`?
