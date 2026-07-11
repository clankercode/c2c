# c2c Environment Variables Reference

**Source**: CLAUDE.md "Key Architecture Notes" env-var dictionary
**Purpose**: Complete reference for c2c environment variables — kept here to
keep CLAUDE.md lean. All values are verbatim from source; do not paraphrase.

---

## Broker / MCP Session

### `C2C_MCP_BROKER_ROOT`

Broker root resolution order (2026-07-06, #9 split-brain fix; was coord1 2026-04-26):
- `C2C_MCP_BROKER_ROOT` env var (explicit override)
- `$C2C_STATE_HOME/c2c/repos/<fp>/broker` (if `C2C_STATE_HOME` set — c2c-specific relocation escape hatch)
- `$HOME/.c2c/repos/<fp>/broker` (canonical default)

Generic `XDG_STATE_HOME` is **no longer honored** for broker-root resolution: agent harnesses (e.g. Claude Code profile-share, which exports `XDG_STATE_HOME=~/.local/state/cc-p`) repurpose it per-profile, silently fragmenting the machine-wide message bus — a Claude session landed on a private broker while codex/pi peers were on `~/.c2c`, invisible to each other. If an orphaned `$XDG_STATE_HOME/c2c/repos/<fp>/broker` with real broker data (a `registry.json`) exists, `c2c` prints a one-line stderr warning (once per process) and `c2c health` / `c2c doctor` report it (`xdg_split_brain_broker` in `--json`); run `c2c migrate-broker` to merge it (it defaults `--from` to the orphaned XDG broker when the legacy path is absent).

The fingerprint (`<fp>`) is SHA-256 of `remote.origin.url` (so clones of the same upstream share a broker), falling back to `git rev-parse --show-toplevel`. This sidesteps `.git/`-RO sandboxes permanently. Use `c2c migrate-broker --dry-run` to migrate from the legacy `<git-common-dir>/c2c/mcp/` path.

**Hook delivery falls back to canonical repo-fp resolution (hook-repo-broker slice, 2026-07-11).** The Claude/Codex delivery hooks used to derive the repo broker root *only* from `C2C_MCP_BROKER_ROOT` — which is empty for vanilla (non-managed) sessions — so they never drained the per-repo broker: peer DMs sent via `c2c send <alias>` sat undrained while the PostToolUse/Stop hook reported "no messages". Hooks now resolve via `C2c_hook_lib.resolve_hook_broker_root`: `C2C_MCP_BROKER_ROOT` (nonempty) still wins verbatim; otherwise they fall back to the same canonical repo-fingerprint broker (`$C2C_STATE_HOME|$HOME/.c2c/repos/<fp>/broker`, fp from the cwd git repo) as the CLI and the codex hook. The fallback is **existence-gated** — it returns the fp broker only when its `registry.json` already exists on disk, so a hook in a repo that never initialized c2c stays a silent no-op and never creates broker directories as a side effect. Affects `c2c_inbox_hook` (PostToolUse), `c2c_stop_hook` (Stop), and the `c2c hook post-tool` / `c2c hook stop` CLI fallbacks; `c2c hook claude` / `c2c hook codex` already resolved the repo broker correctly and are unchanged.

### `C2C_STATE_HOME`

c2c-specific state-relocation escape hatch for broker-root resolution (see order above). Only set this if you genuinely want to relocate c2c broker state; unlike `XDG_STATE_HOME` it is never exported by agent harnesses, so it cannot fragment the shared broker by accident. Setting it also suppresses the split-brain warning (deliberate relocation).

**Stale entries in `.mcp.json` files** — if `C2C_MCP_BROKER_ROOT` is hard-coded in a project's `.mcp.json` `env` block pointing at the legacy `.git/c2c/mcp` path (or at the current resolver default — same skip-when-default rule as the opencode-plugin slice), the explicit override silently re-creates the split-brain symptom even after migration. Operator-facing fix: `c2c migrate-broker --rewrite-mcp-configs` (compatible with `--dry-run`) scans the project root + `.worktrees/*/.mcp.json` and strips matching entries; operator overrides (any other value) are preserved with a `[KEEP]` log line. See #512.

### `C2C_SESSIONS_BROKER_ROOT`

Global broker root override for session-ID-addressed delivery. Used by
`c2c send --session <session_id> <message>` and the Claude PostToolUse inbox
hook. When unset, the global root is `$HOME/.c2c/sessions/broker`; generic
`XDG_STATE_HOME` is deliberately not used because agent harnesses may repurpose
it per profile and fragment peer visibility. This root is intentionally not
repo-fingerprinted: it lets the hook deliver to Claude sessions that never
configured c2c for the current repo. Tests should set this to a temp directory.

### `C2C_BROKER_SCAN_DIRS`

Colon-separated list of extra broker root directories to scan when resolving
an alias that is not found in the primary (per-repo) broker. This is the
"upstream broker" mechanism: set `C2C_BROKER_SCAN_DIRS=/path/to/upstream-broker`
and `c2c send` will fall back to those brokers for unknown local aliases.
The cross-broker fallback also scans: the sessions broker, all per-repo
brokers under `~/.c2c/repos/*/broker`, and sibling broker directories
(sharing the same parent as the primary broker). No additional federation
knob is needed — this env var plus sibling scanning covers the use case
of "elect an upstream broker for unknown alias fallback".

### `C2C_MCP_SESSION_ID`

Explicit session ID override. Set this when launching one-shot child CLI probes (kimi) to prevent inheriting `CLAUDE_SESSION_ID` / `CLAUDE_CODE_SESSION_ID` and hijacking the outer session's registration.

### Client-native session keys (read, not set, by c2c)

When `C2C_MCP_SESSION_ID` is unset, session resolution falls back to the host client's own export: `CLAUDE_SESSION_ID` (legacy Claude Code; wins when both are set) then `CLAUDE_CODE_SESSION_ID` (current Claude Code >= v2.1.x Bash-tool env), `CODEX_THREAD_ID` (codex), `C2C_OPENCODE_SESSION_ID` (opencode), `GROK_SESSION_ID` (Grok Build TUI; also injected into Grok hook processes). kimi/gemini have no native key. If none is present, the CLI additionally falls back to the per-repo `<broker_root>/default-session.json` statefile written by `c2c init` (validated against the registry; last-resort, single identity per repo, CLI-only — the MCP server never reads it).

**Client-type inference (B134).** The same ambient keys drive `inferred_client_type_from_env` / `c2c init` detect (shared): `C2C_MCP_CLIENT_TYPE` override → `CODEX_THREAD_ID` → Claude session keys → OpenCode → `GROK_SESSION_ID` → unofficial Cursor Agent markers (`CURSOR_AGENT` truthy, or `CURSOR_INVOKED_AS=cursor-agent`). Cursor labeling is **best-effort identity only** (alias prefix `cursor-`, `client: "cursor"`) — not install/hooks/MCP parity. Genuine Codex markers always win over Cursor.

### `C2C_MCP_AUTO_REGISTER_ALIAS`

Alias the broker auto-registers on startup, so you keep a stable alias across restarts without calling `register` manually. Also written by `c2c install`.

**Hook registrations win (B119).** If the session_id already has a hook auto-registration (`registered_by="claude-hook"`/`"codex-hook"`, pid=None — written by `c2c hook claude`/`c2c hook codex` on SessionStart, which also bakes that alias into the injected onboarding context), the MCP server's auto-register **adopts** that alias instead of registering this env var's value: the hook is the identity authority, the MCP server a joiner (it upgrades the row in place with its live pid/keys/metadata). If the hook row's `client_type` differs from `C2C_MCP_CLIENT_TYPE` (inherited-session-id contamination, e.g. a `kimi -p` child), the auto-register is skipped entirely rather than adopting or clobbering. Pidless rows without a hook `registered_by` marker keep the #345 post-OOM semantics (this env alias wins). The MCP `register` tool likewise reuses an existing same-session alias unless an explicit `alias` argument requests a rename.

### `C2C_TMUX_LOCATION`

Tmux target for managed sessions (set by `c2c start`). Used by the inner MCP server to include `tmux_location` in its broker registration, so `c2c list` shows which tmux pane each peer is running in and the codex wake injector can target the pane. Format: `session:window.pane` (e.g. `0:0.0`) or a raw pane id (e.g. `%5` — what `c2c hook codex` captures from `$TMUX_PANE`); both are valid `tmux send-keys -t` targets. For managed sessions this is read from the per-instance `tmux.json` file at startup and passed via this env var. Unmanaged / foreign MCP clients do not set this. The MCP `register` tool also reads `$HERDR_PANE_ID` / `$HERDR_SOCKET_PATH` as fallbacks for the analogous `herdr_pane` / `herdr_socket` registration fields.

### `C2C_MCP_AUTO_JOIN_ROOMS`

Comma-separated room IDs the broker joins on startup (e.g. `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge`). Written by `c2c install <client>` for all 5 client types. Do NOT need to call `join_room` manually if this is set. To join additional rooms on top of the default, append: `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge,my-room`.

---

## Inbox / Delivery

### `C2C_OFFLINE_MAIL_TTL_S` (B127)

Seconds a **known-but-not-alive** registration with a non-empty durable
inbox is protected from destructive `sweep`. Default `604800` (7 days).
While protected, `c2c send <alias>` still queues offline into that inbox
and `list` continues to report the peer as not alive. After the TTL,
sweep drops the registration and dead-letters remaining messages
(`dead-letter.jsonl`); re-register redelivers dead-lettered mail for the
same session_id or claimed alias. Anchor for the TTL is
`max(registered_at, newest_inbox_msg.ts)`.

### `C2C_MCP_INBOX_WATCHER_DELAY`

Float seconds the background channel-notification watcher sleeps after detecting new inbox content before draining (default 2.0, per SPEC-delivery-latency). Gives preferred delivery paths (Claude Code PostToolUse hook, Codex PTY sentinel, OpenCode plugin) time to drain first; if they win the race, `drain_inbox` returns `[]` and no channel notification is emitted. Set to `0` in integration tests to get near-immediate delivery. 2s is short enough to keep idle agents responsive (room broadcasts especially) while still giving active agents' preferred paths time to win the race.

### `C2C_POST_TOOL_NUDGE_ONLY`

Claude PostToolUse hook (both the standalone `c2c-inbox-hook-ocaml` binary and the `c2c hook post-tool` CLI fallback — they share `C2c_hook_lib.run_post_tool`). **Full message delivery is the default** (claude-full-delivery slice): the hook drains push (non-deferrable) messages from the repo + global brokers and injects the full `<c2c ...>` envelopes as `additionalContext`, with no debounce (the drain empties the inbox, so repeated fires are cheap no-ops). Set `C2C_POST_TOOL_NUDGE_ONLY=1` to restore the legacy B038 behaviour: a non-draining, 60s-debounced `c2c: N message(s) waiting` nudge line. The channel-capable skip (#387 A2) and the B042 subagent-quiet guard apply in both modes.

### `C2C_POST_TOOL_FULL_INJECT`

Legacy opt-in for full PostToolUse injection, from when the debounced nudge was the default. Still honored for backward compat and outranks `C2C_POST_TOOL_NUDGE_ONLY` when both are set — but it is now redundant: full injection is the default.

### `deferrable` (MCP send flag)

`deferrable=true` means no push (#303): the MCP `send` tool's `deferrable` flag (and the equivalent `~deferrable:true` on `Broker.enqueue_message`) marks a message as low-priority. `drain_inbox_push` filters deferrable messages out, so neither the watcher nor the PostToolUse hook will surface them. The recipient only sees them on their next explicit `poll_inbox` (or the deliver daemon's idle flush). Rooms NEVER use `deferrable` (`fan_out_room_message` hardcodes `false`), which is why room broadcasts always push. Production opter-in: `relay_nudge.ml` (intentionally — its job is "nudge a poll-late agent without pushing again"). User opt-in: `mcp__c2c__send` with `deferrable: true`. If you actually want a DM to surface promptly, omit the flag. See `.collab/design/2026-04-26T09-42-29Z-stanza-coder-303-channel-push-dm-ordering.md` for full investigation + probe data; #307b dropped `deferrable` from the send-memory handoff. **Visibility tool (#307a)**: `c2c doctor delivery-mode --alias <a> [--since 1h] [--last N]` prints a histogram of recent archived inbound messages by deferrable flag, broken down by sender. Counts measure sender INTENT (the flag at write time), not delivery actuals — see the doctor subcommand's NOTE footer.

---

## Codex wake-inject (codex-wake-inject slice)

Idle wake for codex sessions in tmux/herdr panes: a watcher (`C2c_wake_inject` — the managed codex deliver sidecar, or `c2c deliver wake-watch` for vanilla sessions) peeks the inbox and types a one-line nudge into the pane when the session is idle; the injected turn's UserPromptSubmit hook does the actual drain. The injector never drains the inbox. Wake metadata is usable only with a session binding captured by the Codex hook and revalidated immediately before injection; unbound/stale registrations are skipped without touching the inbox.

### `C2C_WAKE_IDLE_THRESHOLD_S`

Float seconds (default `90`). Tmux-backend idle gate: inject only when the broker `last_activity_ts` is at least this old. (The herdr backend uses `herdr agent get` `agent_status=idle` instead — a real busy signal.)

### `C2C_WAKE_BACKOFF_S`

Float seconds (default `120`). Minimum time between injects for the same session. Independent of the backoff, a re-inject also requires a message NEWER than the newest one seen at the last inject (per-session state under `<broker_root>/wake-inject/<session_id>.json`).

### `C2C_WAKE_POLL_S`

Float seconds (default `20`). Watch-loop periodic re-attempt cadence (also the inotify select timeout), so a message that arrived while the session was busy still gets its nudge once the session goes idle. Attempts are cheap: the injector's own gates (empty inbox, backoff, dedupe, idle) short-circuit.

### `C2C_WAKE_ENTER_DELAY_S`

Float seconds (default `0.35`). Tmux backend only: pause between typing the nudge text and sending the submit Enter. Agent TUIs paste-detect rapid input — text+Enter in the same burst is treated as a paste and the Enter becomes a newline, leaving the nudge unsubmitted in the composer (live-caught 2026-07-10; same reason the legacy pty_inject path did "bracketed paste + delay + Enter"). Skipped in fixture mode.

### `C2C_WAKE_INJECT_FIXTURE`

Test fixture gate. When set to a path, the injector records every external command it would run (one JSON line per command: `{"argv": [...], "env": {...}}`) to that file instead of executing — no tmux/herdr pane is ever touched. All wake-inject tests use this.

### `C2C_WAKE_INJECT_HERDR_STATUS`

Test-only companion to the fixture gate: the `agent_status` value the herdr idle probe reports in fixture mode (default `idle`; set `working` to test the never-inject-into-working-pane gate). Ignored outside fixture mode.

---

## CLI

### `C2C_CLI_FORCE`

Set to `1` to suppress the MCP nudge on Tier1 CLI commands (`send`, `list`, `whoami`, `poll-inbox`, `peek-inbox`). When both `C2C_MCP_SESSION_ID` and `C2C_MCP_AUTO_REGISTER_ALIAS` are set, these commands print a hint suggesting the equivalent `mcp__c2c__*` tool instead. Set `C2C_CLI_FORCE=1` to silence the hint when you genuinely need the CLI (e.g. operator scripts, non-MCP sessions).

### Metadata opt-out flags (not env vars)

`c2c register --no-metadata` and the MCP `register` tool's `include_metadata:false` set the per-registration `metadata_opt_out` consent flag. This suppresses future metadata exposure/federation (e.g. cwd, canonical alias) while still capturing `cwd` for the Hardening-B worktree-mismatch guard. Defaults to metadata-on.

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

### `C2C_REQUIRE_SIGNED_ROOM_OPS` (B114 — dev-only downgrade gate)

Server-side (relay) switch for the signed room-op / room-send requirement.
Since B114 the secure behavior is the source default: room mutations
(`/join_room`, `/leave_room`, `/set_room_visibility`, `/invite_room`,
`/uninvite_room`, `/knock_room`, `/list_room_knocks`, `/approve_room_knock`,
`/deny_room_knock`) require a body-level Ed25519 proof, and `/send_room`
requires a signed envelope; unsigned/envelope-less requests are rejected with
`unsigned_room_op`. Values:

- unset or `1` — enforce (the default; `1` is a no-op kept for compatibility).
- `0` — accept legacy unsigned room ops / envelope-less sends, honored ONLY
  when the relay has **no Bearer token configured** (dev mode). A
  token-configured (production) relay ignores `0` — there is no unsigned
  downgrade in production. Startup logs report the effective mode
  (`room ops: ...` line).

HTTP regression coverage: `tests/test_relay_signed_room_ops_gate.py`.

### `C2C_RELAY_E2E_STRICT_V2`

When truthy (`1`, `true`, `yes`, `on` — case-insensitive), the relay-e2e verifier rejects envelopes with `envelope_version < 2` before checking the signature. Default off — v1 envelopes continue to verify normally during the v1↔v2 cutover window. The flag is env-read on every verify, so ops can flip it without daemon restart. Used together with Slice B-min-version (per-peer downgrade pin): B handles once-seen-v2-stays-v2 attacks, C handles the global cutover for first-contact peers. See `.collab/design/2026-04-29-relay-crypto-crit-fix-plan-cairn.md` "Slice C — Strict-mode flip".

### `C2C_RELAY_ALLOW_UNSIGNED_INBOX` (B115)

Server-side, development-only. `/poll_inbox` and `/peek_inbox` on the OCaml
relay require a valid Ed25519 request header whose bound alias owns the
requested `node_id`/`session_id` — by default even on a tokenless relay, so a
production deploy whose token secret goes missing fails closed for inbox
reads instead of reopening the B111 read/drain primitive. Setting
`C2C_RELAY_ALLOW_UNSIGNED_INBOX=1` (also `true`/`TRUE`/`yes`) on the relay
process re-enables the legacy unauthenticated poll/peek path **only when no
Bearer token is configured**; a token-configured (prod) relay ignores this
gate entirely, so env alone can never downgrade production. Read per-request
(`inbox_owner_required` in `ocaml/relay.ml`). Used by the local/dev docker
compose harnesses (`docker-compose.yml`, `docker-compose.e2e-multi-agent.yml`)
whose agents register without Ed25519 identities. Regression coverage:
`ocaml/test/test_relay_remote_broker.ml` (`b115_inbox_owner_auth` suite).
