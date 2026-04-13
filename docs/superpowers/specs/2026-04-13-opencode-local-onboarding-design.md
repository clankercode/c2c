# Repo-Local OpenCode Onboarding Design

Date: 2026-04-13

## Goal

Make OpenCode a first-class `c2c` peer for this repository without touching
global OpenCode config yet.

The onboarding must be local to `/home/xertrov/src/c2c-msg`, use the proven
polling-based receive path, and be safe to test without disrupting unrelated
OpenCode sessions in other projects.

## Approved Scope

This slice is limited to repo-local onboarding via `./.opencode/`.

Included:

- repo-local OpenCode config/artifacts under `./.opencode/`
- a repo-local way to expose the `c2c` MCP server to OpenCode
- a minimal OpenCode launcher/restart flow analogous to Codex where needed
- a local proof that OpenCode can:
  - see the `c2c` MCP server
  - register a stable session id / alias on the broker
  - send through `c2c`
  - receive through `poll_inbox`

Excluded:

- editing `~/.config/opencode/opencode.json`
- changing global OpenCode defaults for unrelated repos
- solving transcript push delivery for OpenCode
- broad product work like rooms, broadcast UX, or self-configuration across all clients

## Constraints

- Do not modify global OpenCode config during this slice.
- Keep the OpenCode session identity stable and repo-specific.
- Use the existing broker root shared by this repo.
- Prefer the already-proven polling path over any experimental push path.
- Reuse existing `c2c` behavior where possible instead of inventing OpenCode-only protocol behavior.

## Recommended Approach

Use a repo-local OpenCode config root in `./.opencode/` that defines a local
`c2c` MCP server entry pointing at `python3 /home/xertrov/src/c2c-msg/c2c_mcp.py`
with repo-specific environment variables:

- `C2C_MCP_BROKER_ROOT=/home/xertrov/src/c2c-msg/.git/c2c/mcp`
- `C2C_MCP_SESSION_ID=opencode-local`
- `C2C_MCP_AUTO_DRAIN_CHANNEL=0`

Then add a minimal launcher pair that starts OpenCode against that repo-local
config and gives it a kickoff prompt aligned with the existing Codex flow:

- orient to `tmp_status.txt` and `tmp_collab_lock.md`
- register or confirm its alias
- poll inbox immediately
- continue on the active goal

This is preferred over a config-only or launcher-only slice because it gives a
repeatable, repo-scoped path to a real working OpenCode peer without risking
cross-project config fallout.

## Architecture

### 1. Repo-local OpenCode config

Add `./.opencode/` as the repo-owned OpenCode surface for this project.

The local config should contain only the minimum necessary to run `c2c` in this
repo. It should not mirror the full global `opencode.json`; instead, it should
be a small repo-scoped config that OpenCode can run against explicitly.

The `c2c` MCP stanza should be local/stdin-based and point at `c2c_mcp.py`
using the same broker root as Claude and Codex.

### 2. Stable OpenCode identity

OpenCode should use a fixed broker session id for this repo-local peer:

- session id: `opencode-local`

Alias registration should still happen through normal `c2c register` or MCP
`register`, but the broker session id must stay stable so other peers can route
to it consistently.

### 3. Launcher surface

Add a minimal launcher flow analogous to Codex, but only as much as needed for
OpenCode's actual execution model.

Expected shape:

- inner launcher: assembles env, cwd, local config path, and kickoff prompt
- outer launcher: restart loop if OpenCode exits quickly or is intentionally restarted
- optional restart-self helper if the OpenCode process model needs it for unattended recovery

If OpenCode's actual CLI model does not benefit from an outer loop in the first
slice, keep the launcher simpler and defer restart-self until after the first
live proof.

### 4. Polling receive path

Receiving should use the polling path from the start.

OpenCode should either:

- call `mcp__c2c__poll_inbox` if the MCP tools are exposed inside OpenCode, or
- fall back to `./c2c-poll-inbox --session-id opencode-local --json` if the host
  MCP surface is missing or temporarily broken.

The local onboarding is only successful if at least one of those receive paths
works in practice for a real OpenCode session.

## Data Flow

1. Launch OpenCode through the repo-local launcher.
2. OpenCode starts with repo-local config rooted in `./.opencode/`.
3. OpenCode sees the local `c2c` MCP server.
4. The server registers/uses `opencode-local` against the shared broker.
5. Another peer sends to the OpenCode alias.
6. OpenCode drains via MCP `poll_inbox` or `c2c-poll-inbox` fallback.
7. OpenCode replies through the same broker/send path.

## Failure Handling

### MCP config not recognized by OpenCode

Fail fast and verify the exact repo-local config shape OpenCode expects.
Do not fall back to editing global config in this slice.

### OpenCode cannot see MCP tools

Use `c2c-poll-inbox` as the local recovery path so inbound receive remains
possible while MCP exposure is debugged.

### OpenCode session identity missing or unstable

Treat this as a blocker. Stable routing requires `opencode-local` to persist.

### OpenCode launches but cannot prove round trip

Log the exact failing stage:

- config discovery
- tool exposure
- register
- send
- receive
- reply

Do not broaden to global config until the repo-local failure is understood.

## Verification Plan

### Automated

- add/extend launcher dry-run tests for the OpenCode launcher surface
- verify the launcher injects:
  - repo-local config path
  - `C2C_MCP_BROKER_ROOT`
  - `C2C_MCP_SESSION_ID=opencode-local`
  - `C2C_MCP_AUTO_DRAIN_CHANNEL=0`

### Live proof

Successful proof for this slice is:

1. OpenCode started using repo-local `./.opencode/` config
2. OpenCode confirms `c2c` MCP presence or uses the local polling fallback
3. OpenCode registers on broker as `opencode-local`
4. another peer sends a message to the OpenCode alias
5. OpenCode receives it
6. OpenCode sends a reply back
7. another peer receives the reply

This proof can be narrow and manual; one successful round trip is enough for the
slice.

## Expected Files

- `./.opencode/...` repo-local OpenCode config/artifacts
- `run-opencode-inst` and possibly `run-opencode-inst-outer`
- tests in `tests/test_c2c_cli.py`
- status/update artifacts in `.collab/updates/`

## Risks

- OpenCode may require a different local config layout than assumed.
- OpenCode may expose MCP tools differently from Claude/Codex.
- A launcher loop may be unnecessary or mismatched to OpenCode's process model.

These are acceptable for this slice because the work is explicitly scoped to
repo-local onboarding and verification, not global rollout.

## Decision

Proceed with repo-local OpenCode onboarding in `./.opencode/` first.

Only after a successful local proof should we consider promoting the `c2c` MCP
entry into `~/.config/opencode/opencode.json` for broader use.
