# c2c Environment Variables Reference

**Source**: CLAUDE.md "Key Architecture Notes" env-var dictionary
**Purpose**: Complete reference for c2c environment variables — kept here to
keep CLAUDE.md lean. All values are verbatim from source; do not paraphrase.

---

## Broker / MCP Session

### `C2C_MCP_BROKER_ROOT`

Broker root resolution order (coord1 2026-04-26):
- `C2C_MCP_BROKER_ROOT` env var (explicit override)
- `$XDG_STATE_HOME/c2c/repos/<fp>/broker` (if set)
- `$HOME/.c2c/repos/<fp>/broker` (canonical default)

The fingerprint (`<fp>`) is SHA-256 of `remote.origin.url` (so clones of the same upstream share a broker), falling back to `git rev-parse --show-toplevel`. This sidesteps `.git/`-RO sandboxes permanently. Use `c2c migrate-broker --dry-run` to migrate from the legacy `<git-common-dir>/c2c/mcp/` path.

**Stale entries in `.mcp.json` files** — if `C2C_MCP_BROKER_ROOT` is hard-coded in a project's `.mcp.json` `env` block pointing at the legacy `.git/c2c/mcp` path (or at the current resolver default — same skip-when-default rule as the opencode-plugin slice), the explicit override silently re-creates the split-brain symptom even after migration. Operator-facing fix: `c2c migrate-broker --rewrite-mcp-configs` (compatible with `--dry-run`) scans the project root + `.worktrees/*/.mcp.json` and strips matching entries; operator overrides (any other value) are preserved with a `[KEEP]` log line. See #512.

### `C2C_MCP_SESSION_ID`

Explicit session ID override. Set this when launching one-shot child CLI probes (kimi) to prevent inheriting `CLAUDE_SESSION_ID` and hijacking the outer session's registration.

### `C2C_MCP_AUTO_REGISTER_ALIAS`

Alias the broker auto-registers on startup, so you keep a stable alias across restarts without calling `register` manually. Also written by `c2c install`.

### `C2C_TMUX_LOCATION`

Tmux `session:window.pane` target for managed sessions (set by `c2c start`). Used by the inner MCP server to include `tmux_location` in its broker registration, so `c2c list` shows which tmux pane each peer is running in. Format: `session:window.pane` (e.g. `0:0.0`). For managed sessions this is read from the per-instance `tmux.json` file at startup and passed via this env var. Unmanaged / foreign MCP clients do not set this.

### `C2C_MCP_AUTO_JOIN_ROOMS`

Comma-separated room IDs the broker joins on startup (e.g. `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge`). Written by `c2c install <client>` for all 5 client types. Do NOT need to call `join_room` manually if this is set. To join additional rooms on top of the default, append: `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge,my-room`.

---

## Inbox / Delivery

### `C2C_MCP_INBOX_WATCHER_DELAY`

Float seconds the background channel-notification watcher sleeps after detecting new inbox content before draining (default 2.0, per SPEC-delivery-latency). Gives preferred delivery paths (Claude Code PostToolUse hook, Codex PTY sentinel, OpenCode plugin) time to drain first; if they win the race, `drain_inbox` returns `[]` and no channel notification is emitted. Set to `0` in integration tests to get near-immediate delivery. 2s is short enough to keep idle agents responsive (room broadcasts especially) while still giving active agents' preferred paths time to win the race.

### `deferrable` (MCP send flag)

`deferrable=true` means no push (#303): the MCP `send` tool's `deferrable` flag (and the equivalent `~deferrable:true` on `Broker.enqueue_message`) marks a message as low-priority. `drain_inbox_push` filters deferrable messages out, so neither the watcher nor the PostToolUse hook will surface them. The recipient only sees them on their next explicit `poll_inbox` (or the deliver daemon's idle flush). Rooms NEVER use `deferrable` (`fan_out_room_message` hardcodes `false`), which is why room broadcasts always push. Production opter-in: `relay_nudge.ml` (intentionally — its job is "nudge a poll-late agent without pushing again"). User opt-in: `mcp__c2c__send` with `deferrable: true`. If you actually want a DM to surface promptly, omit the flag. See `.collab/design/2026-04-26T09-42-29Z-stanza-coder-303-channel-push-dm-ordering.md` for full investigation + probe data; #307b dropped `deferrable` from the send-memory handoff. **Visibility tool (#307a)**: `c2c doctor delivery-mode --alias <a> [--since 1h] [--last N]` prints a histogram of recent archived inbound messages by deferrable flag, broken down by sender. Counts measure sender INTENT (the flag at write time), not delivery actuals — see the doctor subcommand's NOTE footer.

---

## CLI

### `C2C_CLI_FORCE`

Set to `1` to suppress the MCP nudge on Tier1 CLI commands (`send`, `list`, `whoami`, `poll-inbox`, `peek-inbox`). When both `C2C_MCP_SESSION_ID` and `C2C_MCP_AUTO_REGISTER_ALIAS` are set, these commands print a hint suggesting the equivalent `mcp__c2c__*` tool instead. Set `C2C_CLI_FORCE=1` to silence the hint when you genuinely need the CLI (e.g. operator scripts, non-MCP sessions).

---

## Nudge Scheduler

### `C2C_NUDGE_CADENCE_MINUTES`

How often the broker nudge scheduler wakes to check for idle sessions (default 30). Must be greater than `C2C_NUDGE_IDLE_MINUTES`.

### `C2C_NUDGE_IDLE_MINUTES`

How long a session must be idle before receiving a nudge (default 25). Must be less than `C2C_NUDGE_CADENCE_MINUTES`.

---

## Kimi PreToolUse approval hook (#142)

### `C2C_KIMI_APPROVAL_REVIEWER` — DEPRECATED (#502)

Single-reviewer alias for the kimi PreToolUse approval hook (default
`coordinator1`). **Deprecated** as of #502, planned removal next cycle —
the canonical approval path is the `supervisors[]` list in
`.c2c/repo.json` (#490 Slice 5e), which generalizes the single-reviewer
fallback to a list and integrates with the broker-side
`open-pending-reply` / `approval-reply` machinery (see
`docs/security/pending-permissions.md`).

When set, the hook script emits a stderr deprecation warning on every
invocation. Set `C2C_KIMI_APPROVAL_REVIEWER_SILENCE_DEPRECATION=1` to
suppress (e.g. CI environments where the noise drowns useful output)
without removing the override itself — that escape hatch will go away
together with the env var when the deprecation completes.

### `C2C_KIMI_APPROVAL_REVIEWER_SILENCE_DEPRECATION`

Truthy values suppress the #502 deprecation warning on the kimi-approval
hook. Same removal cycle as the parent env var.

### `C2C_KIMI_APPROVAL_TIMEOUT`

Seconds the hook will block on `c2c await-reply` before falling closed
(default 120). Not deprecated; tunable independently.

---

## E2E / Relay

### `C2C_RELAY_E2E_STRICT_V2`

When truthy (`1`, `true`, `yes`, `on` — case-insensitive), the relay-e2e verifier rejects envelopes with `envelope_version < 2` before checking the signature. Default off — v1 envelopes continue to verify normally during the v1↔v2 cutover window. The flag is env-read on every verify, so ops can flip it without daemon restart. Used together with Slice B-min-version (per-peer downgrade pin): B handles once-seen-v2-stays-v2 attacks, C handles the global cutover for first-contact peers. See `.collab/design/2026-04-29-relay-crypto-crit-fix-plan-cairn.md` "Slice C — Strict-mode flip".
