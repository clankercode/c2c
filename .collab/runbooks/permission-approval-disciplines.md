# Permission Approval Discipline

> **Audience**: c2c swarm operators acting as permission supervisors
> (anyone using `c2c approval-reply` or the legacy `c2c send` path).
> **Governs**: how to send approval/denial verdicts for inbound permission requests.

---

## TL;DR

```bash
# Canonical for ka_* tokens (kimi PreToolUse):
c2c approval-reply <token> allow
c2c approval-reply <token> deny "reason text"

# Legacy (deprecated for ka_* — races notifier drain):
c2c send <alias> "permission:<token>:approve-always"
```

Always use `c2c approval-reply` for `ka_*` tokens. The legacy `c2c send` DM path
is deprecated for `ka_*` because it races the recipient's notifier drain.

---

## Token Types

### `ka_*` — kimi PreToolUse tokens

Tokens minted by the kimi PreToolUse hook (`c2c_kimi_hook.ml`). The hook calls
`c2c await-reply --token <token>` which polls the verdict file first:

```
c2c approval-reply <token> allow
  → writes <broker_root>/approval-verdict/<token>.json
  → kimi hook's await-reply finds it, exits 0 with "allow"
```

**Why file over DM**: the notifier daemon drains the inbox concurrently with
`await-reply` reading it. If the DM arrives and the notifier drains before
`await-reply` reads, the verdict is lost. The file write is serialized and
does not race the drain.

### `per_*` — OpenCode MCP permission tokens

Tokens from the OpenCode MCP permission system (`open_pending_reply` /
`check_pending_reply`). Approval via:

```
c2c approval-reply <token> allow
```

This also works for `per_*` — the verdict file is format-agnostic. Additionally,
OpenCode's `peekInboxForPermission` now checks both the broker inbox AND the spool
file (see #495), so the legacy DM path is less racy than before — but file
verdict is still preferred.

---

## Deprecation Warning

**For `ka_*` tokens**: sending `permission:<token>:approve-always` as a plain
DM via `c2c send` is **deprecated**. It works when the notifier is idle, but
races the notifier drain when the recipient is active. Use `c2c approval-reply`.

**For `per_*` tokens**: the DM path still works but the file path is cleaner.
`c2c approval-reply` is canonical for both token types going forward.

---

## Common Operations

| Operation | Command |
|---|---|
| Approve (`ka_*` / `per_*`) | `c2c approval-reply <token> allow` |
| Deny (`ka_*` / `per_*`) | `c2c approval-reply <token> deny "reason"` |
| Legacy approve (deprecated for `ka_*`) | `c2c send <alias> "permission:<token>:approve-always"` |
| Check pending approvals | `c2c approval-list` |
| See verdict file | `cat <broker_root>/approval-verdict/<token>.json` |

---

## Race Condition: Legacy DM Path

When a coordinator sends:
```
c2c send cedar-coder "permission:ka_abc123:approve-always"
```

The recipient's notifier daemon runs `drain_inbox` concurrently. If the notifier
wins the race, the message is removed from the inbox before `await-reply` reads
it, causing a false timeout.

The file path (`c2c approval-reply`) writes a file that `await-reply` polls
directly — no race, no false timeout.

---

## See Also

- `.collab/runbooks/kimi-notification-store-delivery.md` — kimi delivery mechanics
- `.collab/findings/2026-04-30T05-43-00Z-stanza-coder-await-reply-vs-notifier-drain-race.md`
  — original race finding
- `.collab/findings/2026-04-30T20-50-birch-coder-461-diagnostic-sweep.md`
  — full timeline of Apr 29 tripwires + `ka_*`/`per_*` distinction
- `ocaml/cli/c2c_approval_paths.ml` — file verdict implementation
- `ocaml/cli/c2c_kimi_hook.ml` — kimi PreToolUse hook
