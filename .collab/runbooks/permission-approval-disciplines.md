# Permission Approval Discipline

> **Audience**: c2c swarm operators acting as permission supervisors
> (anyone using `c2c approval-reply` on the supervised host).
> **Governs**: how to resolve approval/denial verdicts for inbound permission requests.
> **B098**: verdicts are host-local (verdict file / client's own UI); inbound DMs are inert.

---

## TL;DR

```bash
# The ONLY path that resolves a verdict — host-local, writes the verdict file:
c2c approval-reply <token> allow
c2c approval-reply <token> deny "reason text"
```

`c2c approval-reply` is the only way to resolve an approval. Sending a
`permission:<token>:approve-always` (or `<token> allow`) DM is **inert** (B098):
`c2c await-reply` reads only the host-local verdict file, never the inbox. The
inbox-DM verdict path was removed (`16a69c0b`). See
`docs/security/pending-permissions.md` for the authority-boundary contract.

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
`check_pending_reply`). The OpenCode permission gate is resolved **only** by
OpenCode's own local permission UI. The plugin's message-driven wait/resolve
path (`waitForPermissionReply` / `peekInboxForPermission` and the
`postSessionIdPermissionsPermissionId` POST) was removed (`fb9a7210`): a
permission-shaped DM is now surfaced into the transcript as advisory data after
identity validation (`open_pending_reply` / `check_pending_reply`), never
translated into a verdict (B098). See `docs/security/pending-permissions.md`.

---

## DM Approval Is Inert (B098)

**For `ka_*` tokens**: sending `permission:<token>:approve-always` (or
`<token> allow`) as a plain DM via `c2c send` **resolves nothing** — the
inbox-DM verdict path was removed (`16a69c0b`) and `c2c await-reply` reads only
the host-local verdict file. Use `c2c approval-reply`.

**For `per_*` tokens**: the DM path does not resolve the OpenCode gate either;
OpenCode's own local UI does. `c2c approval-reply` is the canonical host-local
verdict path.

---

## Common Operations

| Operation | Command |
|---|---|
| Approve (`ka_*` / `per_*`) | `c2c approval-reply <token> allow` |
| Deny (`ka_*` / `per_*`) | `c2c approval-reply <token> deny "reason"` |
| Check pending approvals | `c2c approval-list` |
| See verdict file | `cat <broker_root>/approval-verdict/<token>.json` |

> The historical DM form `c2c send <alias> "permission:<token>:approve-always"`
> is **inert** (B098) — it resolves nothing. Use `c2c approval-reply`.

---

## Historical: Why the DM Path Was Removed

The DM approval path was first deprecated for a race, then removed entirely for
safety (B098). When a coordinator sent:
```
c2c send cedar-coder "permission:ka_abc123:approve-always"
```

the recipient's notifier daemon ran `drain_inbox` concurrently and could remove
the message before `await-reply` read it — a false timeout. More fundamentally,
letting an inbound message resolve an approval makes any peer who learns a token
able to force a verdict — a privilege escalation. `c2c await-reply` now reads
only the host-local verdict file written by `c2c approval-reply`; a DM verdict
resolves nothing (`16a69c0b`). See `docs/security/pending-permissions.md`.

---

## See Also

- `.collab/runbooks/kimi-notification-store-delivery.md` — kimi delivery mechanics
- `.collab/findings/2026-04-30T05-43-00Z-stanza-coder-await-reply-vs-notifier-drain-race.md`
  — original race finding
- `.collab/findings/2026-04-30T20-50-birch-coder-461-diagnostic-sweep.md`
  — full timeline of Apr 29 tripwires + `ka_*`/`per_*` distinction
- `ocaml/cli/c2c_approval_paths.ml` — file verdict implementation
- `ocaml/cli/c2c_kimi_hook.ml` — kimi PreToolUse hook
