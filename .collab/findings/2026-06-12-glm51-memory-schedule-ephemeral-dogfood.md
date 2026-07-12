# GLM-5.1 Dogfood: Memory, Schedule, Ephemeral DMs

**Date**: 2026-06-12
**Agent**: GLM-5.1 (running as opencode subagent, session via `c2c register`)
**Binary**: `c2c 0.8.0 776d17e4 2026-06-11T17:32:17Z`
**Aliases used**: `bakeoff-glm51-test`, `bakeoff-glm51-peer`
**All artifacts cleaned up.**

---

## A) Per-Agent Memory

### What worked well

- Core CRUD cycle (write, read, list, delete) works cleanly.
- Privacy tiers work correctly: `--shared` sets `shared: true`, `--shared-with` sets targeted access.
- `share`/`unshare`/`grant`/`revoke` subcommands work as expected.
- Multiline content (multiple positional args joined with `\n`) and Unicode (emoji, CJK) round-trip perfectly.
- `--type` tag is preserved and shown in both JSON and human-readable output.
- Special characters in names (`/`, spaces) are sanitized to `_` on disk — no filesystem escape.
- `--shared` cross-agent discovery lists entries from all alias dirs.
- Targeted `--shared-with coordinator1` correctly triggers notification (DM) to the recipient.
- Human-readable output is clear and well-formatted.

### Issues

#### M-1: Inconsistent session resolution — memory requires `C2C_MCP_AUTO_REGISTER_ALIAS`

- **Severity**: Sev2
- **Symptom**: `c2c memory list` (and all memory subcommands) fail with `error: set C2C_MCP_AUTO_REGISTER_ALIAS to identify the current agent` when only `C2C_MCP_SESSION_ID` is set (and the session is registered via `c2c register`). Meanwhile, `c2c whoami` resolves the alias fine with just `C2C_MCP_SESSION_ID`.
- **Command**: `C2C_MCP_SESSION_ID=X c2c memory list`
- **Root cause guess**: Memory commands resolve the alias independently from the session lookup path, using `C2C_MCP_AUTO_REGISTER_ALIAS` only rather than falling back to the registered session's alias.
- **Suggested fix**: Unify alias resolution: session lookup (via `C2C_MCP_SESSION_ID`) → registered alias → `C2C_MCP_AUTO_REGISTER_ALIAS` fallback, consistent with `whoami`.

#### M-2: Overwrite silently drops description and other metadata

- **Severity**: Sev3
- **Symptom**: Writing to an existing memory entry with `c2c memory write <name> <new-content>` overwrites the content but also clears the `description` (and `--type`, `--shared`, etc.) without warning. The original had `description: "First test note"`; after overwrite it was `null`.
- **Command**: `c2c memory write my-note "new content"` (no `--description` flag)
- **Root cause guess**: `write` is a full overwrite of the file, not a patch. Metadata fields not supplied on the CLI are reset to defaults.
- **Suggested fix**: Either (a) preserve existing metadata when not explicitly overridden, or (b) warn that overwrite will clear unspecified metadata, or (c) add a `--patch` mode.

#### M-3: Empty content accepted without warning

- **Severity**: Sev3
- **Symptom**: `c2c memory write name ""` succeeds, creating a memory entry with empty body.
- **Command**: `c2c memory write bakeoff-glm51-empty "" --json` → `{"saved":"bakeoff-glm51-empty","notified":[]}`
- **Root cause guess**: No validation on content length.
- **Suggested fix**: Consider rejecting empty content or warning. Low severity since it's not destructive.

#### M-4: Exit code 1 for not-found, but docs say 123

- **Severity**: Sev3
- **Symptom**: `c2c memory read nonexistent` returns exit code 1. The man page says 123 for operational errors.
- **Command**: `c2c memory read bakeoff-glm51-nonexistent --json; echo $?` → `RC=1`
- **Root cause guess**: "not found" may be considered a non-error by the implementation, or exit code mapping is inconsistent with docs.
- **Suggested fix**: Align exit codes with documented values (123 for "entry not found" operational error) or document that not-found returns 1.

### Health verdict

**Memory: HEALTHY** — Core functionality solid. Metadata-loss-on-overwrite is the main sharp edge. Session resolution inconsistency is a friction point for CLI users outside managed sessions.

---

## B) Native Scheduling

### What worked well

- Full lifecycle (set → show → list → disable → enable → rm) works correctly.
- `--align @1h+7m` wall-clock alignment parsed and stored correctly.
- `--no-only-when-idle` and `--idle-threshold` work as expected.
- Duplicate name (re-set) silently updates — documented behavior, works correctly.
- TOML files are human-readable and well-structured on disk.
- Human-readable output (`show`, `list`) is clear and tabular.
- `created_at`/`updated_at` timestamps are maintained correctly across updates.
- Missing `--interval` gives clear error (RC=124).

### Issues

#### S-1: Negative interval parsed as unknown flag

- **Severity**: Sev2
- **Symptom**: `c2c schedule set test --interval -5 --message "bad"` produces `c2c: unknown option -5` (RC=124). This is confusing — the user intended `-5` as a value, not a flag.
- **Command**: `c2c schedule set bakeoff-glm51-bad3 --interval -5 --message "bad" --json`
- **Output**: `Usage: c2c schedule set [OPTION]… NAME` / `c2c: unknown option -5` / `RC=124`
- **Root cause guess**: Arg parser treats `-5` as a flag. Standard CLI convention; may need `--interval=-5` syntax or explicit rejection.
- **Suggested fix**: Detect negative number after `--interval` and give a clear "interval must be positive" error rather than "unknown option".

#### S-2: "heartbeat duration" jargon in error messages

- **Severity**: Sev3
- **Symptom**: Invalid interval produces `error: --interval: invalid heartbeat duration: abc`. The word "heartbeat" is internal implementation jargon; user-facing term should be "interval".
- **Command**: `c2c schedule set test --interval abc --message "bad"`
- **Output**: `error: --interval: invalid heartbeat duration: abc`
- **Root cause guess**: Shared duration parser used for both heartbeat binary and schedule CLI, leaking internal naming.
- **Suggested fix**: Change error message to "invalid interval duration: abc".

#### S-3: Bad align spec error uses "heartbeat duration" jargon

- **Severity**: Sev3
- **Symptom**: Same jargon leak as S-2, but for `--align`.
- **Command**: `c2c schedule set test --interval 5m --align "bad-spec" --message "bad"`
- **Output**: `error: --align: invalid heartbeat duration: bad-align-spec`
- **Root cause guess**: Same shared duration parser.
- **Suggested fix**: Change to "invalid alignment spec: bad-spec".

#### S-4: Error exit codes inconsistent with docs

- **Severity**: Sev3
- **Symptom**: `--interval abc` returns RC=1 (should be 124 per docs for command-line parsing errors, or 123 for operational). Zero interval returns RC=1 too.
- **Command**: `c2c schedule set test --interval abc --message "bad"; echo $?` → `RC=1`
- **Root cause guess**: Duration parsing errors map to exit code 1 instead of the documented 123/124.
- **Suggested fix**: Use exit code 124 for invalid argument values (consistent with missing argument behavior) or document the mapping.

#### S-5: `--align ""` accepted silently, same as omitting `--align`

- **Severity**: Sev3 (very minor)
- **Symptom**: `c2c schedule set test --interval 5m --align "" --message "test"` succeeds with no alignment, same as omitting `--align` entirely. Not harmful but undocumented.
- **Command**: `c2c schedule set bakeoff-glm51-emptyalign --interval 5m --align "" --message "bad" --json`
- **Output**: `{"saved":"bakeoff-glm51-emptyalign",...}` (no align field set)
- **Root cause guess**: Empty string align is treated as "no alignment".
- **Suggested fix**: Minor — either reject empty align or document that `--align ""` is equivalent to no alignment.

### Health verdict

**Schedule: HEALTHY** — Core lifecycle works correctly. The main friction is jargon leakage in error messages and confusing negative-number handling. The `set` command's upsert semantics are well-designed.

---

## C) Ephemeral DMs

### What worked well

- `--ephemeral` flag works correctly: message delivered to inbox but **skipped from recipient's archive**.
- Verified by sending one normal + one ephemeral DM, polling inbox (both received), then checking `c2c history` — only the normal DM appeared in archive.
- Tag flags (`--fail`, `--blocking`, `--urgent`) work correctly, prepending emoji prefixes to message body.
- Mutex enforcement between tag flags is clear: `error: --fail, --blocking, and --urgent are mutually exclusive (got 2)`.
- `--from` flag correctly prevents self-send loops.
- Non-JSON send output is clean: `ok -> bakeoff-glm51-peer (from bakeoff-glm51-test)`.

### Issues

#### E-1: Send to unregistered alias succeeds silently

- **Severity**: Sev2
- **Symptom**: `c2c send nonexistent-alias "hello"` succeeds with `queued: true`. The message goes into an inbox that nobody will ever read. No warning about the alias not being registered.
- **Command**: `c2c send bakeoff-glm51-unregistered "test message" --json`
- **Output**: `{"queued":true,"ts":...,"from_alias":"bakeoff-glm51-test","to_alias":"bakeoff-glm51-unregistered"}`
- **Root cause guess**: The broker queues to a file-based inbox keyed by alias, regardless of registration status. No check for active registration.
- **Suggested fix**: Warn when sending to an unregistered alias (or at least when sending to an alias with no live session). Don't block the send, but surface the risk.

#### E-2: Ephemeral send response doesn't confirm ephemeral status

- **Severity**: Sev3
- **Symptom**: `c2c send --ephemeral` response JSON is identical to a normal send. No `"ephemeral": true` field in the response.
- **Command**: `c2c send bakeoff-glm51-peer "test" --ephemeral --json`
- **Output**: `{"queued":true,"ts":...,"from_alias":"bakeoff-glm51-test","to_alias":"bakeoff-glm51-peer"}`
- **Root cause guess**: Response object doesn't include the ephemeral flag.
- **Suggested fix**: Add `"ephemeral": true` to the JSON response when the flag is set, so the sender can confirm it was applied.

#### E-3: "hint: MCP is available" noise in CLI mode

- **Severity**: Sev3
- **Symptom**: When running `c2c send` from the CLI (not via MCP), a hint is printed: `hint: MCP is available — consider using mcp__c2c__send instead of c2c send (suppress with C2C_CLI_FORCE=1)`. This is noisy for CLI-only workflows and appears on every send invocation.
- **Command**: `c2c send bakeoff-glm51-test "test"`
- **Output**: `hint: MCP is available — consider using mcp__c2c__send instead of c2c send` before the actual result.
- **Root cause guess**: Well-intentioned hint that fires whenever the CLI detects MCP availability in the environment.
- **Suggested fix**: Only show the hint once per session (or not at all for explicit CLI invocations). Suppress by default; show only with `--verbose` or similar.

#### E-4: Empty message accepted without warning

- **Severity**: Sev3
- **Symptom**: `c2c send alias ""` succeeds, delivering an empty message.
- **Command**: `c2c send bakeoff-glm51-peer "" --json`
- **Output**: `{"queued":true,...}`
- **Root cause guess**: No validation on message body length.
- **Suggested fix**: Consider rejecting empty messages or at least warning. Low severity since accidental empty sends are rare.

### Health verdict

**Ephemeral DMs: HEALTHY** — Core ephemeral semantics work correctly (archive skip verified). Main friction is the silent send-to-unregistered and the MCP hint noise. The feature works as designed.

---

## Summary

| Feature | Issues | Sev2 | Sev3 | Health |
|---------|--------|------|------|--------|
| Memory  | 4      | 1    | 3    | HEALTHY |
| Schedule| 5      | 1    | 4    | HEALTHY |
| Ephemeral DMs | 4 | 1 | 3 | HEALTHY |
| **Total** | **13** | **3** | **10** | |

All three features are functional. The sharp edges are mostly around error messages, metadata preservation on overwrite, and CLI ergonomics (session resolution, MCP hints). No blocking bugs found.
