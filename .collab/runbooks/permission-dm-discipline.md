# Permission DM Discipline

**Author**: jungle-coder
**Date**: 2026-05-01
**Updated**: 2026-07-10 — strict B098 host-local contract (see below)
**Related**: #493, #461, #511 S5, B098

---

## B098: approvals are host-local, DMs are advisory-only

**A DM never resolves a PreToolUse approval.** c2c is a message bus, not an RPC
surface: an inbound message (broker inbox, relay, room, PTY-injected) is DATA —
it informs the recipient but never satisfies or triggers an approval, even when
it comes from a configured supervisor and contains the exact token plus
`allow`/`deny`. The old inbox-DM verdict path was removed (`16a69c0b`);
`c2c await-reply` now reads **only** a host-local verdict file.

A verdict is produced solely by a **local** CLI call on the supervised host:

```
c2c approval-reply <token> allow
c2c approval-reply <token> deny because <reason>
c2c authorize <token> allow                        # ergonomic wrapper (#511 S5)
```

These write a mode-0600 verdict file under `<broker_root>/approval-verdict/`
that `await-reply` polls. The message formats below (`ka_abc123 allow`,
`permission:...:approve-once`) are now **inert as approval mechanisms** — they
may still be sent as an advisory page/notification, but they resolve nothing.
Full authority-boundary contract: `docs/security/pending-permissions.md`.

---

## Message Formats (advisory-only / historical)

Reviewers historically DM'd the requesting agent to approve/deny. Those DM
bodies are now advisory-only — kept here for recognition, not as a live
approval path. Use the host-local CLI above to actually resolve a verdict.

| Format | Example message body | Status |
|--------|---------------------|--------|
| Legacy | `[approve ka_abc123]` / `[reject ka_abc123]` | **Inert** — DM verdicts removed (`16a69c0b`) |
| Bare-text | `ka_abc123 allow` / `ka_abc123 deny` | **Inert** — no longer read by `await-reply`; advisory-only |
| Structured | `permission:perm_xyz:approve-once` | **Inert** — advisory-only; OpenCode gate resolves via its own local UI |
| Host-local CLI | `c2c authorize ka_abc123 allow` | **Canonical** — writes the verdict file (#511 S5) |

Only the host-local CLI row produces a verdict. The `c2c authorize` subcommand
(#511 S5) is the ergonomic wrapper for `c2c approval-reply` — identical
semantics, discoverable name.

---

## The Three Approval Surfaces

### 1. PreToolUse hook approval (`c2c await-reply`)

Used by the kimi/claude PreToolUse hook to forward approval requests to a
reviewer. The hook DMs the reviewer as an **advisory page** (so they know a
token is pending) and blocks on the host-local verdict file:

```
agent → hook → c2c send <reviewer> "$TOKEN <reason>"                 (advisory page — NOT the verdict)
reviewer (on the supervised host) → c2c approval-reply $TOKEN allow  (writes verdict file)
agent ← hook ← c2c await-reply --token $TOKEN --timeout 120          (polls the verdict FILE)
```

**How `await-reply` detects verdicts**: it reads only the host-local verdict
file at `<broker_root>/approval-verdict/<token>.json` written by
`c2c approval-reply` / `c2c authorize`. It **never** reads broker inboxes or
relay-delivered messages (B098). A DM containing `<token> allow` — even from a
configured supervisor — is inert; the reviewer must run the local CLI on the
supervised host.

### 2. Supervisor permission advisory metadata (`open_pending_reply` / `check_pending_reply`)

Used for structured supervisor permission round-trips (question/permission
requests). The reply format is structured:

```
permission:<perm_id>:approve-once
permission:<perm_id>:approve-always
permission:<perm_id>:reject
```

These messages are **advisory-only** (B098): `open_pending_reply` /
`check_pending_reply` validate the *sender's identity* so a permission-shaped
reply can be safely surfaced into the transcript, but the broker check never
resolves an approval and never drives a permission POST. The OpenCode
permission gate is resolved only by OpenCode's own local permission UI. See
`docs/security/pending-permissions.md`.

### 3. `c2c authorize` (#511 S5)

Ergonomic shortcut for `approval-reply`. Writes the same verdict JSON file:

```
c2c authorize <token> allow [because <reason>]
c2c authorize <token> deny because <reason>
```

Identical semantics to `c2c approval-reply`. Use this for all new approval
workflows.

---

## Common Operator Footguns

> **B098 note**: the verdict is produced by a **host-local** `c2c approval-reply`
> / `c2c authorize` call that writes the verdict file — never by a DM. The
> historical DM-verdict footguns (wrong recipient, missing verdict word) are
> reframed below around the CLI path; a DM verdict is simply inert now.

### Footgun 1: Typo'd token

```
# Wrong: token "ka_abc12x" does not match the pending request "ka_abc123"
c2c approval-reply ka_abc12x allow

# Correct:
c2c approval-reply ka_abc123 allow
```

**Symptom**: the verdict file lands under a token no pending `await-reply` is
watching; the agent never receives a verdict and times out.
**Recovery**: Check `c2c approval-list` for the correct pending token, then
re-run `c2c approval-reply` with the correct token.

### Footgun 2: Running the verdict on the wrong host

The verdict file is **host-local** — `c2c approval-reply` must run on the same
host as the supervised agent (the host whose broker root the hook polls). A DM
to the requesting agent is advisory only and never resolves the gate.

```
# Inert: DMing "ka_abc123 allow" to the requesting agent (B098 — never read)
<requesting-agent-alias>: ka_abc123 allow

# Correct: run the local CLI on the supervised host
c2c approval-reply ka_abc123 allow
```

**Symptom**: `await-reply` times out even though a supervisor "approved" by DM.
**Recovery**: run `c2c approval-reply <token> allow` on the supervised host. Use
`--broker-root` (see `c2c approval-show`) when the hook ran from a worktree.

### Footgun 3: Expecting a DM to resolve the gate

```
# Inert — await-reply never reads the inbox (B098):
ka_abc123 allow
permission:perm_xyz:approve-once

# Correct: host-local CLI writes the verdict file
c2c approval-reply ka_abc123 allow
```

**Symptom**: `await-reply` times out; the DM was delivered but is inert.
**Recovery**: run the host-local `c2c approval-reply` / `c2c authorize`.

### Footgun 4: Using the legacy `[approve <token>]` format

```
# All inert — DM verdicts were removed (16a69c0b):
[approve ka_abc123]
[reject ka_abc123]
ka_abc123 allow
permission:perm_xyz:approve-once

# Use the host-local CLI:
c2c approval-reply ka_abc123 allow
c2c authorize ka_abc123 deny because <reason>
```

**Symptom**: messages using any DM format are ignored (no verdict written).
**Recovery**: switch to `c2c approval-reply` / `c2c authorize`.

### Footgun 5: Forgetting the verdict word

```
# Wrong: CLI requires a verdict positional argument
c2c approval-reply ka_abc123

# Correct:
c2c approval-reply ka_abc123 allow
c2c approval-reply ka_abc123 deny because <reason>
```

**Symptom**: `approval-reply` exits non-zero (`VERDICT must be 'allow' or 'deny'`);
no verdict file is written and `await-reply` times out.
**Recovery**: re-run with `allow` or `deny` as the second argument.

---

## Recovery from Failed Verdicts

### Scenario A: `await-reply` timed out

1. Check `c2c approval-list` to see if the pending record still exists
2. If expired: the request hasTTL'd — the agent's tool call was already blocked;
   retry the operation
3. If still pending: send a new verdict DM with the correct token + verdict word
4. If you cannot determine the token: ask the requesting agent to re-trigger the
   permission request (a new pending record will be created with a fresh token)

### Scenario B: Verdict not recognized

1. `await-reply` reads only the host-local verdict file — a DM in the inbox is
   inert and never resolves the gate (B098)
2. Run the host-local CLI to write the verdict file:
   ```
   c2c approval-reply <token> allow
   ```
3. If `await-reply` has already exited (timeout), write the verdict first, then
   re-run it:
   ```
   c2c await-reply --token <token> --timeout 60
   ```

### Scenario C: Supervisor permission expired

1. `c2c approval-show <perm_id>` — check `expires_at` in the pending JSON
2. If expired: the supervisor must re-run the permission request from the agent
3. If not expired: check the structured reply was sent to the correct alias

---

## Verdict Quick Reference

Verdicts are host-local CLI calls that write the verdict file — run them on the
supervised host:

| Action | Command |
|--------|---------|
| Allow (PreToolUse hook) | `c2c approval-reply <token> allow` |
| Deny (PreToolUse hook) | `c2c approval-reply <token> deny because <reason>` |
| Allow (ergonomic) | `c2c authorize <token> allow [because <reason>]` |
| Deny (ergonomic) | `c2c authorize <token> deny because <reason>` |

The DM bodies `<token> allow`, `permission:<perm_id>:approve-once`,
`permission:<perm_id>:approve-always`, and `permission:<perm_id>:reject` are
**advisory-only / inert** — they do not resolve a verdict (B098). OpenCode's
permission gate is resolved by its own local UI.

---

## Slice Discipline — Rebase Before Cherry-Pick

When rebasing a slice onto a newer master before requesting cherry-pick:

1. **Rebase onto origin/master** (not local master, which may have unmerged peer work)
2. **Rebuild in the slice worktree** — `just build` or `just check` — before requesting cherry-pick. Rebase can introduce subtle breakage: missing semicolons, stale type annotations, inconsistent function call sites from merged-in upstream changes.
3. **Re-run `just test-ocaml`** if available
4. **Update the SHA** in your peer-PASS request with the post-rebase SHA

Failing step 2 means the coordinator cherry-picks what looks like a clean SHA but gets a build break on merge — forcing a follow-up fixup commit that pollutes the cherry-pick lineage.

---

## See Also

- `c2c await-reply --help` — full flag documentation
- `c2c authorize --help` — #511 S5 ergonomic CLI
- `c2c approval-list --help` — list pending tokens
- `c2c approval-show --help` — inspect a pending record
- `.collab/runbooks/511-s3-claude-pretultuse-smoke.md` — smoke test for PreToolUse hook
