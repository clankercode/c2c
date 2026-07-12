# Dogfood Report: c2c sessions, send/recv, PoW

**Date**: 2026-06-12
**Agent**: glm-5.1 (via OpenCode)
**Binary**: `~/.local/bin/c2c` v0.8.0 (776d17e4)
**Context**: Comprehensive CLI dogfooding, no OCaml edits, no git commit/push

---

## Area Verdicts

| Area | Verdict |
|------|---------|
| **(A) `c2c sessions`** | **Healthy — minor formatting gaps.** New command works, --json parses, live/dead states correct. Truncation in table mode and `null`/`?` liveness are the only rough edges. |
| **(B) `c2c send` / recv** | **Functional but two Sev2 silent-accept bugs.** Send/peek/poll/history pipeline is solid. Unicode, multiline, long bodies, tags all work. Ephemeral correctly excluded from archive. However, `--from` is unvalidated and nonexistent recipients are silently accepted. |
| **(C) PoW** | **No CLI surface exists.** `c2c pow` is unknown, relay serve has no PoW flags, server-info features list has no pow entry, OCaml source has zero PoW references. PoW is relay-side only with zero client visibility. |

---

## Issues

### SEV-2: `c2c send` accepts nonexistent recipient alias silently

**Symptom**: Sending to an alias that does NOT exist in the registry succeeds with
`ok -> nonexistent-alias-xyz (from bakeoff-glm51b-dogfood)`. The message is not
dead-lettered and disappears silently.

**Command + output**:
```
$ c2c send --from bakeoff-glm51b-dogfood nonexistent-alias-xyz "test"
ok -> nonexistent-alias-xyz (from bakeoff-glm51b-dogfood)

$ c2c dead-letter --json
[]
```

**Root-cause guess**: The broker's `enqueue_message` writes to an inbox file keyed by
alias. If the alias has no registration, the file may be written but never collected,
or the write is skipped without error. The CLI does not validate recipient existence
against the registry before accepting the send.

**Severity**: Sev-2 — sender gets false confirmation, message is silently lost.
Could mask operational issues in swarm coordination.

**Suggested fix**: Check recipient alias against the registry. If not found, exit 123
with `error: alias 'nonexistent-alias-xyz' is not registered`. Alternatively, warn
and require `--force` to proceed.

---

### SEV-2: `c2c send --from` is unvalidated — spoofed sender accepted

**Symptom**: Sending with `--from nonexistent-sender-xyz` (not registered) succeeds
and the recipient sees the spoofed alias in their inbox and history.

**Command + output**:
```
$ c2c send --from nonexistent-sender-xyz bakeoff-glm51b-target "test"
ok -> bakeoff-glm51b-target (from nonexistent-sender-xyz)

$ c2c poll-inbox --session-id bakeoff-glm51b-target-session-001 --json
[{"from_alias": "nonexistent-sender-xyz", "to_alias": "bakeoff-glm51b-target", "content": "test", ...}]

$ c2c history --session-id bakeoff-glm51b-target-session-001 --json
[{"from_alias": "nonexistent-sender-xyz", ...}]
```

**Root-cause guess**: The `--from` flag is passed straight through to the broker without
registry validation. The `send_alias_impersonation_guard` feature flag likely only
checks that the `from_alias` matches the session's registered alias, but the CLI's
`--from` bypasses this by constructing a synthetic envelope.

**Severity**: Sev-2 — enables alias impersonation from the CLI. Any operator can
craft messages appearing to come from any alias. Breaks audit trail integrity.

**Suggested fix**: Validate `--from ALIAS` against the registry. Reject if not
registered, or at minimum warn. The `send_alias_impersonation_guard` feature should
also cover the `--from` CLI path.

---

### SEV-3: `c2c sessions` table truncates alias column aggressively

**Symptom**: Aliases like `bakeoff-glm51b-dogfood#c2c@xsm` are truncated to
`bakeoff-glm51b-dogf…` in the table, making it hard to distinguish similar aliases.

**Command + output**:
```
$ c2c sessions
  SESSION_ID                           ALIAS                CLIENT     LIVE CWD                            ROLE
  ------------------------------------ -------------------- ---------- ---- ------------------------------ ----
  bakeoff-glm51b-dogfood-session-001   bakeoff-glm51b-dogf… ?          yes  -
  bakeoff-glm51b-target-session-001    bakeoff-glm51b-targ… ?          yes  -
```

**Root-cause guess**: Fixed-width column layout with a narrow alias column.
The `#c2c@xsm` suffix (hostname qualification) eats most of the column width.

**Severity**: Sev-3 — cosmetic but impacts usability with many similarly-prefixed aliases.

**Suggested fix**: Widen the alias column or dynamically size columns based on
content. Consider stripping the `#c2c@hostname` suffix in table mode (it's visible
in `--json`).

---

### SEV-3: `c2c sessions` shows `?` for liveness when JSON returns `null`

**Symptom**: The `mm27-roomtest` entry shows `live: null` in JSON and `?` in the
table. The meaning of `null` vs `false` is ambiguous.

**Command + output**:
```
$ c2c sessions --json | grep -A5 mm27
{"session_id": "bakeoff-mm27-session-1781199517", "alias": "mm27-roomtest#c2c@xsm",
 "client_type": null, "cwd": null, "live": null}

$ c2c sessions
  bakeoff-mm27-session-1781199517      mm27-roomtest#c2c@x… ?          ?    -
```

**Root-cause guess**: `null` likely means the registration was created without a PID
(e.g. relay registration, or a format that doesn't record `pid_start_time`). The
broker can't determine liveness without a PID. The `?` display is reasonable but
undocumented.

**Severity**: Sev-3 — tri-state liveness (yes/no/unknown) is reasonable but should
be documented in `--help` or the manpage.

**Suggested fix**: Add a brief note in `c2c sessions --help` explaining the three
liveness states. In JSON, consider `null` → `"unknown"` for clarity.

---

### SEV-3: `c2c send` without `--from` gives confusing error

**Symptom**: Running `c2c send ALIAS MSG` without `--from` from a non-session
context gives an error about `C2C_MCP_AUTO_REGISTER_ALIAS` or `C2C_MCP_SESSION_ID`
without mentioning the `--from` flag.

**Command + output**:
```
$ c2c send bakeoff-glm51b-target "no --from flag"
error: cannot determine your alias. Set C2C_MCP_AUTO_REGISTER_ALIAS or C2C_MCP_SESSION_ID.
```

**Root-cause guess**: Error message was written before `--from` was added.
The natural fix path for an operator is `--from ALIAS`, not setting env vars.

**Severity**: Sev-3 — operator friction; easy to fix.

**Suggested fix**: Append `hint: use --from ALIAS to specify a sender alias.` to
the error message.

---

### SEV-3: `c2c send` accepts empty message body

**Symptom**: `c2c send --from X Y ""` succeeds and delivers an empty message.

**Command + output**:
```
$ c2c send --from bakeoff-glm51b-dogfood bakeoff-glm51b-target ""
ok -> bakeoff-glm51b-target (from bakeoff-glm51b-dogfood)
```

**Root-cause guess**: No minimum-length validation on the message body.

**Severity**: Sev-3 — likely accidental (empty shell expansion). Could mask bugs.

**Suggested fix**: Reject empty body with `error: message body cannot be empty`.

---

### SEV-3: `registry-prune --pattern` says repeatable but isn't

**Symptom**: The help text says "Can be passed multiple times" but using `-p` or
`--pattern` more than once gives `option cannot be repeated`.

**Command + output**:
```
$ c2c registry-prune -p bakeoff-glm51b -p bakeoff-glm51 --force
c2c: option -p cannot be repeated
```

**Root-escape guess**: The OCaml argparse configuration doesn't allow repeated
string options despite the help text claiming it.

**Severity**: Sev-3 — help/behavior mismatch.

**Suggested fix**: Either fix the option to accept multiple values or update the
help text to say "single pattern".

---

### SEV-3: `c2c sessions` `client_type` always null for CLI registrations

**Symptom**: All sessions registered via `c2c register --alias X` show `client_type: null`
and `cwd: null`. Only managed sessions (via `c2c start`) populate these fields.

**Root-cause guess**: CLI `register` doesn't accept `--client-type` or `--cwd` flags.
These fields are populated only by the managed-session startup path.

**Severity**: Sev-3 — the `CLIENT` and `CWD` columns in table mode always show `?`/`-`
for CLI-registered sessions, reducing the utility of `c2c sessions`.

**Suggested fix**: Add optional `--client-type` and `--cwd` flags to `c2c register`.
At minimum, show `cli` as client_type for registrations made via the CLI.

---

### SEV-3: `c2c history` for nonexistent session shows same as empty

**Symptom**: `c2c history --session-id nonexistent-session-999` shows `(no history)`
— identical to a session that exists but has no messages.

**Command + output**:
```
$ c2c history --session-id nonexistent-session-999
(no history)
```

**Root-cause guess**: History reads from an archive file. If the file doesn't exist
(no session ever drained), it returns empty without distinguishing "no archive file"
from "archive exists but is empty".

**Severity**: Sev-3 — operator might think the session exists with no traffic when
it doesn't exist at all.

**Suggested fix**: Check if the session ID exists in the registry. If not, show
`error: no session 'nonexistent-session-999' found` or at minimum
`(no history — session may not exist)`.

---

## What Worked Well

### (A) Sessions
- Clean manpage-style help (`c2c sessions --help`)
- `--json` output is well-formed, parses cleanly
- Live/dead states correctly reflect PID liveness
- Sessions are sorted (newest first in table)
- Column alignment is neat despite truncation
- Idempotent re-registration works correctly

### (B) Send/Recv
- Full pipeline: register → send → peek → poll → history works end-to-end
- Unicode (CJK, emoji, accented chars) preserved perfectly through send→poll→history
- Multiline messages stored with `\n` in JSON, rendered correctly in plain text
- Long bodies (2000+ chars) handled without truncation
- `--fail` / `--urgent` / `--blocking` tags correctly prepend emoji prefixes
- Mutual exclusion of tags (`--fail --urgent`) properly rejected
- Ephemeral messages correctly excluded from history archive after drain
- Shell substitution warning is helpful and suggests `--no-warn-substitution`
- `--json` send output includes timestamp, from/to aliases
- `c2c history --alias X` resolves alias to session ID — convenient
- `c2c history --no-headers` for grep-friendly scripting
- `c2c history --limit N` works correctly
- Self-send correctly rejected with clear error message
- Missing arguments shows proper usage error
- Poll inbox plain format `[alias] message` is clean and readable

### (C) PoW
- (N/A — no surface to test)

---

## Area (C): PoW Observations

**Finding**: There is zero PoW surface in the current client binary (v0.8.0, 776d17e4).

Evidence:
1. `c2c pow` → `unknown command pow`
2. `c2c relay serve --help` has no `--pow*` options
3. `c2c relay status --help` has no PoW-related output
4. `c2c server-info --json` features list has no `pow` or `proof_of_work` entry
5. `grep -r 'pow\|proof.of.work\|PoW' ocaml/**/*.ml` → no results
6. `c2c health --json` has no PoW fields

**How a user would observe PoW working**: They wouldn't. If PoW is enforced
server-side on the production relay, the client has no visibility into it.
There's no `--pow` flag on `relay dm send`, no challenge-response flow, no
mint/verify command. A user hitting a PoW-enforced relay would likely get an
opaque error about rejected messages with no indication that PoW is required.

**Severity**: Sev-2 gap if PoW is meant to be client-facing. Sev-3 if it's purely
relay-internal. The AGENTS.md mention ("ENABLED on the prod relay") suggests the
client should at minimum *observe* PoW requirements.

**Suggested fix**: Add `c2c pow status` to show relay PoW config. If the relay
requires PoW for certain operations, add client-side minting with `c2c pow mint`
or automatic minting on send. At minimum, `c2c relay status` should include a
`pow.enabled` field.

---

## Test Artifacts Created/Left

- `bakeoff-glm51b-dogfood` / `bakeoff-glm51b-target`: live registrations, same PID
  as current process. Will become dead when this process exits. Can be pruned with
  `c2c registry-prune --pattern bakeoff-glm51b --force` after that.
- `bakeoff-mm27-session-1781199517`: pre-existing, `live: null`, not prunable by
  prefix (not matching `bakeoff-`).
- Target inbox archive: contains test messages. Will be cleaned up when the session
  is pruned and broker files are GC'd.

---

## Summary

| Severity | Count | Areas |
|----------|-------|-------|
| Sev-1 | 0 | — |
| Sev-2 | 2 | send (nonexistent recipient, unvalidated --from) |
| Sev-3 | 7 | sessions (3), send (3), prune (1) |

**Top priority fixes**: The two Sev-2 send bugs (nonexistent recipient silent accept,
unvalidated `--from`) should be addressed before any public-facing release. They
undermine message delivery guarantees and audit integrity respectively.
