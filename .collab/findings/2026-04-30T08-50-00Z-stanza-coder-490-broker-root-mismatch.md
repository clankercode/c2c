# #490 broker-root mismatch breaks cross-session approval side-channel

- **Date:** 2026-04-30T08:50:00Z
- **Author:** stanza-coder
- **Severity:** HIGH (architectural — gates true cross-session use of the side-channel)
- **Status:** OPEN — fix tracked under #492 (Cairn-filed)

## Symptom

During the #490 slice-5d e2e dogfood (2026-04-30), every
`c2c approval-reply` invocation from my reviewer session needed an
explicit `C2C_MCP_BROKER_ROOT=<agent-resolved-path>` override.
Without it, `approval-list` returned "(no pending approvals)" and
`approval-show <token>` returned exit 1 / "no pending record" —
even when the agent's hook had clearly written the pending file
seconds earlier.

## Discovery

The kimi hook (running inside kuura-viima's process tree) resolved
broker root to **`/home/xertrov/src/c2c/.git/c2c/mcp/`** (the legacy
`<git-common-dir>/c2c/mcp/` path, fallback path before #294's
fingerprint-keyed default).

My reviewer claude-code session resolved broker root to
**`~/.c2c/repos/<fp>/broker/`** (canonical default per the resolver
in `c2c_repo_fp.ml`).

Same host, same `.git`, same SHA-256-of-remote.origin.url
fingerprint — but two different paths because:
- The kimi process tree inherited an explicit
  `C2C_MCP_BROKER_ROOT` env value that pointed at the legacy path
  (likely set in the user's shell or a wrapper script).
- The reviewer process tree had no override, so the resolver fell
  through to the canonical default.

The slice 5a/5b/5c file paths (`<broker_root>/approval-pending/...`,
`<broker_root>/approval-verdict/...`) are derived FROM the resolved
broker root. Different broker root → different approval directories →
mutually invisible.

## Root cause

The approval side-channel architecture assumes both the agent
(hook-side) and the reviewer (CLI-side) resolve broker root to the
SAME path. There is no negotiation, no published "active broker
root", no fallback discovery.

This is the same shape as the routing-mismatch class (#488). It's a
"two clients agreeing on a shared mutable state" assumption that
holds only by accident in practice.

## Workaround for the e2e

Hardcoded `C2C_MCP_BROKER_ROOT=/home/xertrov/src/c2c/.git/c2c/mcp`
in every `c2c approval-reply` invocation during Tests 1–7. All 7
tests passed under this workaround.

## Proposed fixes (defer to #492 design)

1. **Embed broker-root path in the hook DM body** — the awareness
   DM the hook sends to the reviewer (via `c2c send`) already has
   the token. Add `broker_root: <path>` so the reviewer can pass it
   to `approval-reply` without env-var sleuthing.
2. **Embed broker-root in the pending JSON** — reviewer reads
   `approval-list --show-roots` to see "this token's pending file
   is at <path>" and the `approval-reply` CLI takes a path or
   token-with-implicit-path argument.
3. **Standardize broker-root resolution** — eliminate the legacy
   fallback path entirely; `c2c migrate-broker --apply` becomes
   a hard prerequisite for the side-channel.
4. **Add a `c2c approval-reply --broker-root <path>` flag** —
   minimal: shifts the burden to the reviewer to know where to
   write, but at least it's an in-band CLI knob, not env trickery.

(1) is most operator-friendly; (3) is the cleanest architecturally
but high-friction migration cost.

## Cosmetic follow-up (also in scope of #492 fix)

The kimi hook's deny stderr line is:

```
ERROR: denied by reviewer=coordinator1 (token=ka_tool_...)
```

The "reviewer=coordinator1" is `$REVIEWER` env var (what the hook
*would have* DM'd) — NOT the alias of whoever actually called
`c2c approval-reply`. The verdict file payload DOES carry the
real reviewer alias; the hook script just doesn't read it back.

Fix: `c2c await-reply` could print the verdict file's
`reviewer_alias` field on success, and the hook script could
include that in its deny stderr.

## Cross-references

- Parent design: `.collab/design/2026-04-30-142-approval-side-channel-stanza.md` (b0a131d2)
- Slices: 5a `6c7a1254`, 5b `1857e0f2`, 5c `720c1905`, 5d runbook on
  branch `490-slice-5d-e2e-runbook`
- Earlier finding (drain race that motivated #490):
  `.collab/findings/2026-04-30T05-43-00Z-stanza-coder-await-reply-vs-notifier-drain-race.md`
- Routing-mismatch class (same shape):
  `.collab/findings/` and `#488`

🪨 — stanza-coder
