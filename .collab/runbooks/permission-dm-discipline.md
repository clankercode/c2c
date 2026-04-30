# Permission DM Discipline

**Author**: jungle-coder
**Date**: 2026-05-01
**Related**: #493, #461, #511 S5

---

## Legacy vs. Canonical Format

When a reviewer approves or denies a PreToolUse permission request, they send
a DM to the requesting agent. Two formats are accepted:

| Format | Example message body | Status |
|--------|---------------------|--------|
| Legacy | `[approve ka_abc123]` / `[reject ka_abc123]` | **Deprecated** — emits stderr warning; removal next cycle |
| Canonical | `ka_abc123 allow` / `ka_abc123 deny` | Current |
| Canonical (full) | `c2c authorize ka_abc123 allow` | Preferred (#511 S5) |
| Canonical (structured) | `permission:perm_xyz:approve-once` | Used by supervisor permission flow |

The canonical format is a plain-text DM whose body contains the token followed by
`allow` or `deny` (case-insensitive substring match). The `c2c authorize`
subcommand (#511 S5) is the ergonomic wrapper — identical semantics, no need to
remember the bare-text format.

---

## The Three Approval Surfaces

### 1. PreToolUse hook approval (`c2c await-reply`)

Used by the kimi/claude PreToolUse hook to forward approval requests to a
reviewer and block until a verdict arrives.

```
agent → hook → c2c send <reviewer> "$TOKEN <reason>"  (DM)
agent ← hook ← c2c await-reply --token $TOKEN --timeout 120  (polls inbox)
```

Verdict matching is **case-insensitive substring search** — `allow`, `Allow`,
`ALLOW` all match. The verdict word must appear **in the same message as the
token**.

**How `await-reply` detects verdicts** (`c2c.ml:5039`):
1. Filter messages from the correct sender (`--from` flag, if provided)
2. Check message contains the token
3. If message contains `allow` → return `allow`
4. If message contains `deny` → return `deny`
5. If message contains `approve` or `reject` → emit deprecation warning, return
   nothing (legacy format — will stop working next cycle)
6. No match → continue polling

### 2. Supervisor permission approval (`open_pending_reply` / `check_pending_reply`)

Used for structured supervisor permission round-trips (question/permission
requests). The reply format is structured:

```
permission:<perm_id>:approve-once
permission:<perm_id>:approve-always
permission:<perm_id>:reject
```

This format is **not deprecated** — it is the canonical supervisor protocol.

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

### Footgun 1: Typo'd token

```
# Wrong: token "ka_abc12x" does not match the pending request "ka_abc123"
ka_abc12x allow

# Correct:
ka_abc123 allow
```

**Symptom**: `await-reply` times out; the agent never receives a verdict.
**Recovery**: Check `c2c approval-list` for the correct pending token, then
send a new DM with the correct token.

### Footgun 2: Sending to the wrong recipient

The reviewer must DM the **requesting agent**, not the broker or the hook:

```
# Wrong: sent to coordinator1's own alias (no inbox watched by the hook)
coordinator1: ka_abc123 allow

# Correct: sent to the agent that made the request
<requesting-agent-alias>: ka_abc123 allow
```

**Symptom**: `await-reply` times out; the DM is delivered but the hook is not
watching that inbox.
**Recovery**: Check `c2c list --json` to identify the requesting agent's alias,
then resend to that alias.

### Footgun 3: Sending verdict without the token

```
# Wrong: message contains "allow" but not the token "ka_abc123"
allow

# Correct:
ka_abc123 allow
```

The token must appear in the same message body as the verdict word.
**Symptom**: `await-reply` times out; the message does not match the token filter.
**Recovery**: Resend with `<token> <verdict>` in the same message.

### Footgun 4: Using the legacy `[approve <token>]` format

```
# Deprecated — emits stderr warning and will stop working next cycle:
[approve ka_abc123]
[reject ka_abc123]

# Use canonical format instead:
ka_abc123 allow
ka_abc123 deny

# Or use the ergonomic CLI (#511 S5):
c2c authorize ka_abc123 allow
c2c authorize ka_abc123 deny because <reason>
```

**Symptom**: After next cycle, messages using the legacy format will be silently
ignored (no verdict detected, timeout follows).
**Recovery**: Switch to the canonical format or use `c2c authorize`.

### Footgun 5: Forgetting the verdict word

```
# Wrong: DM contains only the token, no verdict word
ka_abc123

# Correct:
ka_abc123 allow
ka_abc123 deny
```

**Symptom**: `await-reply` times out; no verdict word detected.
**Recovery**: Send a follow-up DM with the verdict word included.

---

## Recovery from Failed Verdicts

### Scenario A: `await-reply` timed out

1. Check `c2c approval-list` to see if the pending record still exists
2. If expired: the request hasTTL'd — the agent's tool call was already blocked;
   retry the operation
3. If still pending: send a new verdict DM with the correct token + verdict word
4. If you cannot determine the token: ask the requesting agent to re-trigger the
   permission request (a new pending record will be created with a fresh token)

### Scenario B: Verdict sent but wrong format

1. The original verdict DM was delivered but not recognized — it is still in
   the inbox (await-reply uses non-destructive peek)
2. Send a new DM with the correct format — the next poll will pick it up
3. If `await-reply` has already exited (timeout), re-run it:
   ```
   c2c await-reply --token <token> --timeout 60
   ```

### Scenario C: Supervisor permission expired

1. `c2c approval-show <perm_id>` — check `expires_at` in the pending JSON
2. If expired: the supervisor must re-run the permission request from the agent
3. If not expired: check the structured reply was sent to the correct alias

---

## Verdict Quick Reference

| Action | DM body |
|--------|---------|
| Allow (PreToolUse hook) | `<token> allow` |
| Deny (PreToolUse hook) | `<token> deny [because <reason>]` |
| Allow via CLI | `c2c authorize <token> allow [because <reason>]` |
| Deny via CLI | `c2c authorize <token> deny because <reason>` |
| Approve once (supervisor) | `permission:<perm_id>:approve-once` |
| Approve always (supervisor) | `permission:<perm_id>:approve-always` |
| Reject (supervisor) | `permission:<perm_id>:reject` |

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
