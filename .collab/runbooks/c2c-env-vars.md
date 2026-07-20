# c2c Environment Variables Reference

**Source**: CLAUDE.md "Key Architecture Notes" env-var dictionary
**Purpose**: Reference for the operator-relevant c2c environment variables —
kept here to keep CLAUDE.md lean. Internal/test-fixture vars (`C2C_*_FIXTURE`,
`C2C_TEST_*`, codex ingress/probe plumbing, etc.) are intentionally excluded;
this is not an exhaustive dump of every `C2C_*` token in the source. All values
are verbatim from source; do not paraphrase.

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

**Claude Stop feedback is non-error context (B162, 2026-07-13).** When the Stop boundary drains queued c2c mail, `c2c_stop_hook` and `c2c hook stop` return `{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"..."}}` with exit 0 and empty stderr. Claude continues so it can act on the delivered data, but renders it as `Stop hook feedback`, not a hook error. The payload remains untrusted message data: it never approves an action or writes an approval verdict.

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

When `C2C_MCP_SESSION_ID` is unset, session resolution falls back to the host client's own export: `CLAUDE_SESSION_ID` (legacy Claude Code; wins when both are set) then `CLAUDE_CODE_SESSION_ID` (current Claude Code >= v2.1.x Bash-tool env), `CODEX_THREAD_ID` (codex), `C2C_OPENCODE_SESSION_ID` (opencode), `GROK_SESSION_ID` (Grok Build TUI; injected into Grok **hook** processes — tool shells typically do **not** get this key). When the client is Grok (see below) and `GROK_SESSION_ID` is still empty, c2c resolves the live session by matching an ancestor pid against `~/.grok/active_sessions.json` (override path: `C2C_GROK_ACTIVE_SESSIONS`, for tests). kimi has no native key. If none is present, the CLI additionally consults the per-repo `<broker_root>/default-session.json` statefile written by `c2c init` (single identity per repo, CLI-only — the MCP server never reads it). **#26 fail-closed gate:** the statefile only resolves an identity when its session is the **sole** registration in the broker (a loud `WARN:` is printed, exit 0); if **any other** session is registered, bare `c2c whoami`/`send`/`poll-inbox`/`rooms` **fail closed** with a candidate list + an `export C2C_MCP_SESSION_ID=…` hint instead of silently adopting a possibly-stale alias (which had caused wrong-sender DMs — #21). Set `C2C_ALLOW_DEFAULT_SESSION=1` to restore the pre-#26 silent "statefile wins if registered" behaviour.

**Client-type inference (B134, B173).** The same ambient keys drive `inferred_client_type_from_env` / `c2c init` detect (shared): `C2C_MCP_CLIENT_TYPE` override → `CODEX_THREAD_ID` → Claude session keys → OpenCode → `GROK_SESSION_ID` → truthy `GROK_AGENT` (Grok tool shells export this, often `1`) → unofficial Cursor Agent markers (`CURSOR_AGENT` truthy, or `CURSOR_INVOKED_AS=cursor-agent`). Cursor labeling is **best-effort identity only** (alias prefix `cursor-`, `client: "cursor"`) — not install/hooks/MCP parity. Genuine Codex markers always win over Grok/Cursor markers.

### `C2C_ALLOW_DEFAULT_SESSION`

Opt-in escape hatch (`1`/`true`/`yes`) that restores the pre-#26 behaviour: the
per-repo `default-session.json` statefile silently resolves an identity whenever
its session is still registered, with no fail-closed-on-ambiguity check. Off by
default — leave it unset so multi-session hosts fail closed rather than
misattribute a bare `c2c whoami`/`send` to a stale alias. Only set it for a
genuine single-human-CLI workflow that relies on the old convenience.

### `C2C_MCP_AUTO_REGISTER_ALIAS`

Alias the broker auto-registers on startup, so you keep a stable alias across restarts without calling `register` manually. Also written by `c2c install`.

**Hook registrations win (B119).** If the session_id already has a hook auto-registration (`registered_by="claude-hook"`/`"codex-hook"`, pid=None — written by `c2c hook claude`/`c2c hook codex` on SessionStart, which also bakes that alias into the injected onboarding context), the MCP server's auto-register **adopts** that alias instead of registering this env var's value: the hook is the identity authority, the MCP server a joiner (it upgrades the row in place with its live pid/keys/metadata). If the hook row's `client_type` differs from `C2C_MCP_CLIENT_TYPE` (inherited-session-id contamination, e.g. a `kimi -p` child), the auto-register is skipped entirely rather than adopting or clobbering. Pidless rows without a hook `registered_by` marker keep the #345 post-OOM semantics (this env alias wins). The MCP `register` tool likewise reuses an existing same-session alias unless an explicit `alias` argument requests a rename.

### `C2C_TMUX_LOCATION`

Tmux target for managed sessions (set by `c2c start`). Used by the inner MCP server to include `tmux_location` in its broker registration, so `c2c list` shows which tmux pane each peer is running in and the codex wake injector can target the pane. Format: `session:window.pane` (e.g. `0:0.0`) or a raw pane id (e.g. `%5` — what `c2c hook codex` captures from `$TMUX_PANE`); both are valid `tmux send-keys -t` targets. For managed sessions this is read from the per-instance `tmux.json` file at startup and passed via this env var. Unmanaged / foreign MCP clients do not set this. The MCP `register` tool also reads `$HERDR_PANE_ID` / `$HERDR_SOCKET_PATH` as fallbacks for the analogous `herdr_pane` / `herdr_socket` registration fields.

### `C2C_MCP_AUTO_JOIN_ROOMS`

Comma-separated room IDs the broker joins on startup (e.g. `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge`). Written by `c2c install <client>` for all MCP-managed client installs (grok/agy are CLI-first — no MCP config — so this var does not apply to them). Do NOT need to call `join_room` manually if this is set. To join additional rooms on top of the default, append: `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge,my-room`.

### `C2C_MCP_AUTO_DRAIN_CHANNEL`

Controls whether the inner MCP server auto-drains the inbox into a
`notifications/claude/channel` push after each RPC. **Default `1` (ON) since the
#346 flip** — when unset the server treats it as enabled (`c2c_mcp_server_inner.ml`:
`None ⇒ true`). The drain only fires for clients that declare
`experimental.claude/channel` support in `initialize`; standard Claude Code does
NOT declare it, so the default has no effect there (no silent inbox drain). Values
`0`/`false`/`no`/`off` (case-insensitive) disable it. **Managed installs write `0`**
explicitly (`c2c install`/`c2c start` — `c2c_setup.ml`, `c2c_start.ml`), overriding
the default so managed clients never auto-drain. The old footgun (silent inbox
drain, messages lost) is fixed. See CLAUDE.md "Key Architecture Notes" and
`.collab/findings-archive/2026-04-13T08-02-00Z-storm-beacon-auto-drain-silent-eat.md`.

### `C2C_MCP_SCHEDULE_TIMER`

Enables the inner MCP server's built-in Lwt schedule timer, which reads
`.c2c/schedules/<alias>/*.toml` and fires due schedules as self-DMs
(`c2c_mcp_server_inner.ml`: `schedule_timer_enabled`). **Default OFF** — when unset
the timer does not run; truthy values `1`/`true`/`yes`/`on` (case-insensitive)
enable it. **Managed sessions set `1`** automatically: `c2c start` sets it in the
MCP child's env (and mirrors it into its own env, S6c) and then skips its own
stat-poll schedule-watcher thread, so there is no double-fire. Raw (non-managed)
MCP-configured sessions can opt in by exporting it before launch. See
`.collab/runbooks/agent-wake-setup.md` § Option 0b for the full mechanics.

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

`deferrable=true` means no push (#303): the MCP `send` tool's `deferrable` flag (and the equivalent `~deferrable:true` on `Broker.enqueue_message`) marks a message as low-priority. CLI parity (B232): `c2c send --deferrable` sets the same flag from the CLI, not MCP-only. `drain_inbox_push` filters deferrable messages out, so neither the watcher nor the PostToolUse hook will surface them. The recipient only sees them on their next explicit `poll_inbox` (or the deliver daemon's idle flush). Rooms NEVER use `deferrable` (`fan_out_room_message` hardcodes `false`), which is why room broadcasts always push. Production opter-in: `relay_nudge.ml` (intentionally — its job is "nudge a poll-late agent without pushing again"). User opt-in: `mcp__c2c__send` with `deferrable: true`. If you actually want a DM to surface promptly, omit the flag. See `.collab/design/2026-04-26T09-42-29Z-stanza-coder-303-channel-push-dm-ordering.md` for full investigation + probe data; #307b dropped `deferrable` from the send-memory handoff. **Visibility tool (#307a)**: `c2c doctor delivery-mode --alias <a> [--since 1h] [--last N]` prints a histogram of recent archived inbound messages by deferrable flag, broken down by sender. Counts measure sender INTENT (the flag at write time), not delivery actuals — see the doctor subcommand's NOTE footer.

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

## Codex app-server delivery + nudge (B131 / B136)

### `C2C_CODEX_FORCE_HOOKS`

Hidden operator/testing-only escape. The app-server transport is the **default
and only** managed codex path on a supported codex (B131) — there is no
`--app-server` flag and no `C2C_CODEX_APP_SERVER` gate (both removed). Setting
`C2C_CODEX_FORCE_HOOKS=1` makes a managed launch skip the app-server path
entirely and fall back to the hook delivery path
(`c2c_codex_session.ml`; only the exact value `1` triggers it). Not user-facing —
intended for operator testing of the hook fallback. Any other value (or unset)
leaves app-server as the default.

### `C2C_CODEX_SKIP_MCP_PREFLIGHT`

Operator escape for the B224 preflight. Every managed Codex launch
(`C2c_codex_session.run`, `ocaml/c2c_codex_session.ml`) validates the
machine-wide `[mcp_servers.c2c]` block in `~/.codex/config.toml` before
launching, because a stale block (a dev `opam exec -- <server_path>` whose build
path was removed, or a `c2c-mcp-server` no longer on PATH) would otherwise drop
the operator into a session whose c2c MCP handshake fails
(`MCP startup incomplete (failed: c2c)`). A **stale** block aborts the launch up
front with a repair message (`c2c install codex`) and the distinct exit code
`78` (`codex_mcp_preflight_exit_code`); a **missing** block is not the failure
mode (codex simply launches without c2c tools) and proceeds. Setting
`C2C_CODEX_SKIP_MCP_PREFLIGHT=1` (exact value `1`) launches anyway. The preflight
only runs on a real launch — a test that injects a scripted `backend` skips it.

### `C2C_CODEX_CONFIG_PATH`

Overrides the codex config path the B224 preflight reads (default
`~/.codex/config.toml`). Test seam / non-standard `CODEX_HOME`; does not affect
where `codex` itself reads its config. Empty/unset uses the default.

### `C2C_CODEX_SKIP_THREAD_PREFLIGHT`

Operator escape for the B227 resume-thread persistence preflight. A managed
Codex launch/resume with a saved thread id checks that Codex actually persisted
that thread (a rollout `…/rollout-<ts>-<thread-id>.jsonl` under the sessions
dir) before handing the frontend `codex resume <id>` — a zero-turn thread is
never saved, so resuming it hard-fails (`No saved session found`) and strands
the alias in a degraded relaunch. A known-unpersisted thread is dropped (fresh
thread, same alias) with an operator log line. The sessions root is resolved
through symlinks first (profile-share setups symlink `~/.codex` /
`~/.codex/sessions`); a missing/unresolvable root, an unreadable or otherwise
ambiguous scan, or a symlink inside the resolved tree keeps the thread
(uncertainty never discards resume context). When the thread is dropped, c2c
also clears that exact target from its managed config and mapping before any
hook-backed fallback can reload it. The scan also runs before the emergency
`C2C_CODEX_FORCE_HOOKS=1` fallback when it targets an existing alias. Setting
`C2C_CODEX_SKIP_THREAD_PREFLIGHT=1` (exact value `1`) forces the resume attempt.
Scripted-`backend` tests skip the scan unless `C2C_CODEX_SESSIONS_DIR` is set.

### `C2C_CODEX_SESSIONS_DIR`

Overrides the Codex sessions (rollout) directory the B227 thread preflight scans
(default `$CODEX_HOME/sessions`, else `~/.codex/sessions`). Test seam /
non-standard layout; does not affect where `codex` itself stores sessions.
Empty/unset uses the default.

### `C2C_CODEX_APP_SERVER_READINESS_TIMEOUT_S`

Positive finite float (seconds) for how long the managed launcher waits for
`codex app-server` to accept an authenticated WebSocket handshake before
classifying the failure as a readiness timeout (B175). Default is **90**
(`C2c_codex_app_server.default_readiness_timeout_s`). Non-positive / non-numeric
values fall back to the default. Timeout is distinct from process exit
(`server_died_before_ready`): a still-running but slow server reports
`readiness_timeout` and the operator message points at this env var plus the
app-server log path. Does not change the automatic hook-backed fallback.

### `C2C_CODEX_MANAGED`

Set to `1` by every managed Codex launch (`C2c_codex_session.run`, `ocaml/c2c_codex_session.ml`) **before** any codex child (app-server frontend/server, or the hook-fallback child) is spawned, so all of them — and the hooks they fire — inherit it. It is the load-bearing "this codex session is managed" marker for the B136 nudge: a managed app-server session otherwise resolves in the hook as vanilla (it persists `codex-session.json` rather than the legacy instance `config.json`, registers under the managed instance name not the payload thread id, and sets no `C2C_MCP_SESSION_ID`), so this env is what reliably suppresses the nudge for real `c2c new codex` sessions. Non-secret; read only by the nudge gate.

### `C2C_CODEX_APPSERVER_SESSION`

Set to the managed app-server session id (the broker session id `run_delivery_loop` registers under) by `C2c_codex_session.run_app_server` (`ocaml/c2c_codex_session.ml`) **before** `C2c_codex_app_server.start` spawns the stock frontend — `build_frontend_env` snapshots `Unix.environment ()`, so the frontend and every hook it fires inherit it. It is the load-bearing **identity** marker for B137: a real `c2c new codex` app-server session otherwise resolves in `c2c hook codex` as vanilla and self-registers a SECOND per-thread identity (dual-identity). The hook adopts this value as its identity (first, unconditionally — race-free, does not need the launcher's broker registration to have landed) so it never forks a duplicate; it then treats the session as ingress-owned and drains **nothing** (the app-server deliver loop owns arrival-time repo delivery; the global cross-repo inbox is deliberately not drained either, since doing so from the frontend hook would let a nested Codex that inherited the marker steal the parent's mail — global-inbox delivery for app-server is a follow-up for the ingress loop). It also suppresses wake-target refresh for the same reason (app-server delivers via ingress, not wake-inject). Reset to the empty string on the app-server→hook-fallback path (`Unix` has no `unsetenv`; readers trim-guard empty as unset) so a fallback launch's hook still owns its own registration/delivery. Distinct from `C2C_CODEX_MANAGED` (a boolean "is managed" marker set for BOTH app-server and hook-fallback); this carries the specific session id and is set for the app-server path only. Non-secret.

### `C2C_CODEX_INGRESS_LIVE`

Set to `1` by a managed app-server Codex session (`C2c_codex_session.run_delivery_loop`, `ocaml/c2c_codex_session.ml`) to unlock the real ingress/auto-turn WebSocket clients in the launcher process. It is exported **after** the codex frontend + app-server children are already spawned (both snapshot `Unix.environment ()` at spawn time), so it is **NOT** inherited by the codex frontend or the hooks it fires — do not rely on it as a "managed session" marker inside a hook process. The `c2c hook codex` B136 nudge treats a set `C2C_CODEX_INGRESS_LIVE` as one (belt-and-suspenders) app-server signal; the load-bearing managed marker is `C2C_CODEX_MANAGED` (above), which — unlike the thread→instance mapping, `C2C_MCP_SESSION_ID`, or the broker registration — is reliably present for a real app-server session.

### `C2C_CODEX_APPSERVER_NUDGE_EVERY`

Integer cadence (default `5`) for the `c2c hook codex` SessionStart tip that steers vanilla / hook-fallback Codex sessions toward the managed app-server path (`c2c new codex`, arrival-time delivery). The tip appears once every N **eligible** (truly-vanilla) SessionStart fires — a per-invocation counter persisted at `<broker_root>/codex-appserver-nudge.count` is incremented only on eligible fires. Non-integer values fall back to `5`; **`0` (or any value ≤ 0) disables the nudge entirely** (a clean off switch). The tip is NEVER shown in a session that already has managed/app-server delivery: suppressed when `C2C_CODEX_MANAGED` is set (the load-bearing marker — every managed codex launch), `C2C_CODEX_INGRESS_LIVE` is set, `C2C_MCP_SESSION_ID` is set (hook-fallback managed), the payload thread maps to a managed c2c instance, or the resolved registration is `client_type=codex-app-server`. It also only emits after the incremented counter is durably written (an I/O failure yields no tip), and the read-modify-write is flock-serialized so concurrent SessionStart hooks can't all emit at once. The whole path is best-effort: any error simply hides the tip and never fails the codex turn.

### `C2C_CODEX_TURN_MODEL`

Advanced/operator override for the T007 auto-turn: when set (non-empty), the
app-server auto-turn dispatcher pins `model` on the `turn/start` params
(`c2c_codex_autoturn.ml`) instead of leaving it to the thread's configured client
policy. Unset (the default) means the thread's own default model is used. Primarily
used by the live E2E to keep runs deterministic; production leaves it unset.

### `C2C_CODEX_TURN_APPROVAL_POLICY`

Advanced/operator override for the T007 auto-turn: when set (non-empty), pins
`approvalPolicy` on the auto-turn `turn/start` params (`c2c_codex_autoturn.ml`).
Unset (the default) uses the thread's configured approval policy. Same
E2E-determinism use case as `C2C_CODEX_TURN_MODEL`.

### `C2C_CODEX_PARENT_CMDLINE_PATH` (#52, tests only)

Test fixture gate for the `codex exec` detection in `c2c hook codex`. Points at
a file of NUL-separated argv standing in for `/proc/<getppid>/cmdline`, which is
what the hook reads in production to tell a one-shot `codex exec` run from an
interactive session. Unset (the default) reads the real `/proc` entry.

Background: `codex exec` fires SessionStart but never SessionEnd, so it used to
mint a permanent `codex-hook` registration per invocation. The SessionStart
payload and the hook environment are identical between the two modes, so the
parent process argv is the only available signal; the hook declines to
auto-register when — and only when — the parent is unambiguously `codex exec`.
Every ambiguous case registers as before, because a spare ghost row is a
bounded cost while a missing registration on a live session destroys mail. Be
precise about *which* row when repeating that claim: the pid-less **hook** row
this path would mint does decay under #51's activity TTL. The row `c2c send`
mints on demand (`maybe_auto_register_sender`) does **not** — it sets
`registered_by = None`, which fails `is_any_hook_registration`
(`ocaml/c2c_broker.ml`), so #51's TTL never sees it. That row is bounded by pid
liveness instead: it carries a real pid plus `pid_start_time`, so it reads Dead
as soon as the run exits — *more* mortal than the hook row, not less.

The skip has a real cost, recorded here so it is not rediscovered: an exec run
that never calls `c2c send` is now unaddressable and is never told its identity
(no onboarding text). Dispatching an exec agent and DMing it *before* it speaks
does not work; the agent must send first.

---

## Permission supervisors

### `C2C_PERMISSION_SUPERVISOR` / `C2C_SUPERVISORS`

Override the supervisor alias(es) the permission-notice path (opencode plugin,
kimi PreToolUse hook, `c2c health`) resolves. `C2C_PERMISSION_SUPERVISOR` is a
**single alias** and has the **highest priority** (default supervisor when nothing
else is configured is `coordinator1`); `C2C_SUPERVISORS` is a **comma-separated
list** consulted as the fallback when `C2C_PERMISSION_SUPERVISOR` is unset/empty
(`c2c_health_cmd.ml`, `c2c_config_cmd.ml`, `c2c_opencode_plugin_embedded.ml`). Both
override the `supervisors[]` list in `.c2c/repo.json` (#490 Slice 5e) when set.
`c2c config` prints the effective override hint
(`Override: C2C_PERMISSION_SUPERVISOR=alias or C2C_SUPERVISORS=a,b`).

---

## CLI

### `C2C_CLI_FORCE`

Set to `1` to suppress the MCP nudge on Tier1 CLI commands (`send`, `list`, `whoami`, `poll-inbox`, `peek-inbox`). When both `C2C_MCP_SESSION_ID` and `C2C_MCP_AUTO_REGISTER_ALIAS` are set, these commands print a hint suggesting the equivalent `mcp__c2c__*` tool instead. Set `C2C_CLI_FORCE=1` to silence the hint when you genuinely need the CLI (e.g. operator scripts, non-MCP sessions).

### `PI_C2C_ASCII` (statusline glyphs)

When truthy (`1` / `true` / `yes` / `on`), `c2c statusline` renders plain-text
tokens instead of unicode glyphs — useful in minimal terminals or fonts that
lack emoji/arrow support. Fallbacks: `🌐 ⇄` → `[relay]`, `📦` → `repo`,
`🖥️` → `machine` (e.g. `c2c my-alias · [relay] off · repo 2 · machine 3`).
`--json` field names are unaffected. See `docs/reference/statusline.md`.

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

### `C2C_KIMI_SERVER_PORT`

Overrides the port c2c uses to reach the local Kimi Code REST server. It is
one candidate in a precedence chain, not the whole answer (#39):

1. `C2C_KIMI_DELIVER_FIXTURE_BASE_URL` (tests only; requires
   `C2C_KIMI_DELIVER_FIXTURE=1`)
2. kimi's live server lock — `~/.kimi-code/server/lock`, or
   `~/.kimi-code/server/instances/*.json` under kimi's `multi_server` flag.
   Used only when the recorded pid is alive.
3. `C2C_KIMI_SERVER_PORT`
4. the last `"msg":"server listening"` record in
   `~/.kimi-code/server/server.log` — **only if a TCP probe says it is live**
5. default port `58627`

The log record used to sit at the top of this chain. Modern kimi-code appends
it only on a *cold* start (a warm start logs plain text: `server already
running (pid=…, port=…)`), so it aged into a permanently dead port and
silently broke 100% of Kimi delivery — and `C2C_KIMI_SERVER_PORT` could not
rescue it, because the log scrape pre-empted the fallback it fed.

### `C2C_KIMI_PROBE_TIMEOUT`

Seconds the TCP liveness probe waits when validating a candidate Kimi server
address (default `0.5`). Only the log-scraped candidate is probed; the lock
file is validated by pid-liveness instead.

### `C2C_KIMI_TMUX_COMPOSER_WAKE`

**Default: unset / off.** Primary kimi wake is REST
`POST /api/v1/sessions/{id}/prompts` via `C2c_kimi_notifier` — no tmux required.
Set to `1` only to re-enable the legacy post-deliver composer nudge that types
`[c2c] check inbox` + Enter into the managed TUI pane when it appears idle.
Left off by default because modern kimi-code often fails to submit that Enter
(extended-keys/focus), stacking unsubmitted text while the real REST turn
already ran.

---

## E2E / Relay

### Relay supervisor diagnostics (B219)

The Railway/OCI image runs `c2c relay serve` under the process-external
`c2c-relay-supervisor`. Its durable lifecycle ledger and hang captures default
to `<C2C_RELAY_PERSIST_DIR>/relay-diagnostics/` (or
`/data/relay-diagnostics/` when the persist-dir env is unset). The supervisor
never records its child argv, environment, or health URL in its text snapshots
because those may contain a relay token. The container enables bounded core
capture under its `cores/` subdirectory; only the newest two `core*` files and
ten health-failure captures are retained. Lifecycle/reaper metadata is
root-owned, while only `cores/` is writable by the de-privileged relay. Core
files contain raw process memory and must be handled as secrets.

The image owns `/data` as `root:c2c` with mode `1770`. Sticky group-write lets
the relay create and rename its own SQLite files but prevents it from replacing
the root-owned diagnostics directory entry.

The following operator overrides are read by `scripts/relay-supervisor.sh`:

- `C2C_RELAY_DIAG_DIR`: diagnostic directory override.
- `C2C_RELAY_HEALTH_URL`: loopback health endpoint; default
  `http://127.0.0.1:$PORT/health`.
- `C2C_RELAY_HEALTH_INTERVAL`: seconds between probes; default `10`.
- `C2C_RELAY_HEALTH_TIMEOUT`: per-probe curl timeout in seconds; default `5`.
- `C2C_RELAY_HEALTH_FAILURE_THRESHOLD`: consecutive failures before one
  process/cgroup snapshot is persisted; default `3`.
- `C2C_RELAY_DIAG_KEEP`: number of health-failure snapshots retained; default
  `10`.
- `C2C_RELAY_CORE_CAPTURE`: set to `1` by the container image. The relay child
  runs from the diagnostic directory with a bounded core-file limit.
- `C2C_RELAY_CORE_OWNER`: owner/group for the core-only subdirectory. The
  container image sets `c2c:c2c`; generic callers default to the persistence
  root owner.
- `C2C_RELAY_CHILD_REAPER`: internal path override for the image's tiny
  wait-status helper. The helper preserves the kernel distinction between a
  numeric exit such as 139 and termination by signal 11.

### `C2C_RELAY_INBOUND_POLICY_FILE` (B196)

Local path to the native relay connector's inbound-policy JSON. When unset or
empty, the connector reads `<broker_root>/relay-inbound-policy.json`; when that
file is absent, safe built-in limits apply (256 KiB per message, 60 messages
per sender per 60 seconds, 120 messages per recipient agent per 60 seconds, and
600 messages per connector/machine per 60 seconds). The policy also supports a
default allow/deny sender action, per-sender action overrides, and per-recipient
enable/size/rate overrides. The policy stays local and is never sent to the relay. It is reloaded
on every sync pass; sliding-window rate state is persisted and process-locked
under the broker root. A present but unreadable, malformed, or invalid policy
fails closed for relay inbound delivery while registration, heartbeat, and
outbound sync continue. See
`.collab/runbooks/cross-machine-relay-proof.md` under "Local inbound controls"
for the schema and override examples.

### `C2C_RELAY_CONNECTOR_STALE_EXIT_S` (B211, tightened B228)

Wall-clock seconds the native relay connector may go without a *progress-making*
sync pass before it declares itself wedged and exits 3 so a supervisor
(`c2c start relay-connect`) restarts it. A pass counts as progress if it fully
succeeded (`last_error = None`) or was merely rate-limited (relay reachable and
throttling — B210 backs off; restarting would not help). This is the companion
to the B181/B228 SIGALRM watchdog: the SIGALRM watchdog catches a sync pass that
*hangs* past its deadline (force-exit 3 — raising from the handler left live
PIDs wedged under nested Lwt/Cohttp), whereas this timer catches the
*completes-but-always-errors* wedge (each pass returns quickly with
`request_timeout` / `connection_error`, so the strike counter keeps resetting
and the process would otherwise stay alive indefinitely with a stale bridge).
Unset/invalid/non-positive uses the default `max(180, interval × 6)` seconds
(3 min at the default 30s poll interval) — intentionally close to the doctor
120s liveness window so a whoami `wedged` is not an 8-minute operator wait
before self-heal (B228). Unsupervised, the exit turns a silently wedged live
PID into an honest `absent`/`stale` status that `c2c whoami` /
`c2c doctor --relay` report with the `c2c restart relay-connect` remediation.
Applies to both single-broker (`run`) and machine (`start_machine`) connector
loops. On the machine service, **any** broker root that stays past the
threshold exits the whole process (supervisor restarts all roots together) —
a permanently broken secondary root can flap healthy peers every ~threshold;
prefer fixing that root or isolating it rather than lengthening the default.
Pure predicates + a forked run-loop exit covered by `test_c2c_relay_connector.ml`
("B211/B228 staleness-exit watchdog").

### `C2C_RELAY_CONNECTOR_BACKEND` (B235/B242)

Selects the relay-connect backend: `python` (legacy) vs the native OCaml
connector (`ocaml/c2c_relay_connector.ml`). Operator-facing knob for
`c2c relay connect` / `c2c start relay-connect` (`c2c_relay_cmd.ml`).

### `C2C_SUPERVISOR_STALE_THRESHOLD_S`

Supervisor stale threshold in seconds; default 300
(`ocaml/cli/c2c_opencode_plugin_embedded.ml`). Operator-tunable.

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
