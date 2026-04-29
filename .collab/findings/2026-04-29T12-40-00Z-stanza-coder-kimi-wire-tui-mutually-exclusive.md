# O1 probe verdict: kimi `--wire` and TUI are mutually exclusive UI modes

- **Date:** 2026-04-29 12:40 UTC
- **Filed by:** stanza-coder
- **Severity:** BLOCKER for #142 Phase A (kimi permission forwarding)
- **Probe origin:** Phase 3 design `.collab/design/2026-04-29T12-36-11Z-stanza-coder-kimi-permission-forwarding-phase3.md` flagged this as O1
- **Greenlit by:** coordinator1 2026-04-29 22:40 AEST as a drive-by ~20min slice

## Verdict

**`kimi --wire` and the kimi shell-UI cannot run in the same process.** They are
distinct values of an enum, conflict-checked at flag-handling time, with an
explicit `BadParameter` if both are requested.

This means the Phase A design as currently sketched — one kimi process gives
both the operator-facing TUI **and** the wire-protocol JSON-RPC permission IPC —
**does not work against unmodified kimi-cli.**

## Source pointers

`/home/xertrov/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/cli/__init__.py`:

- **Line 50:** `UIMode = Literal["shell", "print", "acp", "wire"]` — UI modes are mutually exclusive by construction (single enum-typed variable).
- **Lines 244-249:** `--wire` is a `bool` flag that sets `wire_mode`.
- **Lines 435-460:** explicit conflict-set check — `{--print, --acp, --wire}` enforced as at most one. `BadParameter` raised if more than one is active.
- **Lines 469-475:** `ui` variable is single-valued: `shell` (default) → `print` → `acp` → `wire`. If `wire_mode` is true, `ui = "wire"`.
- **Lines 674-677:** `case "wire": await instance.run_wire_stdio()` — separate UI run path; does not invoke the shell-UI render loop.

## Why coexistence isn't a footgun-fixable thing

The TUI agent's `ApprovalRuntime` (`approval_runtime/runtime.py`) is per-process
state. Spawning a second `kimi --wire` process to listen for approvals does NOT
help: the second process has its own ApprovalRuntime, sees its own (different)
agent's tool-calls, and has zero visibility into the TUI process's pending
approvals. The wire-server-as-side-channel concept inherently requires the
**same process** to expose both the rendering UI and the JSON-RPC IPC.

## Phase A — implications

Phase A as written (one wire-bridge daemon subscribing to one TUI session's
approvals via `--wire` JSON-RPC) is **blocked on an upstream change**.
Two paths forward:

### Option U1: Upstream feature ask
File an issue against kimi-cli (https://github.com/MoonshotAI/Kimi-K2 or
wherever kimi-cli lives) requesting:

> Expose the `wire/server.py` JSON-RPC IPC (specifically `ApprovalRequest`
> broadcast + `ApprovalResponse` ingest) as a side-channel available alongside
> the shell-UI mode, not as a replacement for it. Could be flagged behind
> `--wire-side-channel` or `--expose-approval-ipc <socket-path>`.

This is the architecturally clean path. The wire-server already exists; it just
needs decoupling from the UI-mode enum.

### Option U2: kimi-cli local fork
Patch our local kimi-cli install to run `wire/server.py` alongside `shell`
mode. ~50-100 LoC patch. Maintainable as long as we track upstream releases.

Trade-off: every kimi-cli upgrade requires re-applying the patch. Acceptable
short-term if upstream is slow; risky long-term.

### Option U3: Defer Phase A; ship Phase 0
Stay on `--afk` (auto-approve-everything) for unattended kimi work. Do NOT ship
permission forwarding until upstream allows the side-channel. Trade-off:
unattended kimi can do unreviewed dangerous ops indefinitely.

## Recommendation

**Pursue Option U1 first** — file the upstream feature ask. It's a small,
well-scoped request with a clear architectural justification. Time-box the
upstream response: if no engagement within ~2 weeks, fall back to Option U2
(local fork).

Phase B (`kimi-approvals` room + `c2c kimi-approve` CLI) can be designed in
parallel — it doesn't depend on the IPC mechanism, only on the swarm-side
surface. Phase C (signed verdicts) likewise.

## What this changes about #142

Update task #142 description:
- Phase A blocked on upstream change (Option U1) or local-fork (Option U2).
- File new task: **#145 — file upstream feature ask** (kimi-cli wire side-channel).
- Phase B + C designs can proceed in parallel.

## Cross-references

- Phase 3 design: `.collab/design/2026-04-29T12-36-11Z-stanza-coder-kimi-permission-forwarding-phase3.md` (defines O1 + O2)
- Phase 1 root-cause finding: `.collab/findings/2026-04-29T10-04-00Z-stanza-coder-c2c-start-kimi-spawns-double-process.md` (where the dual-agent bug originated — the same `--wire` mode that blocked TUI delivery is now blocking permission IPC for the same architectural reason: it's a UI-mode swap, not a side-channel)
- O2 status: cleared by `b4ac6b93` (jungle #461) + `3274e5d9` (birch docs) per coord1 routing 2026-04-29 22:40 AEST.

🪨🌬️ — stanza-coder
