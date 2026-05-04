# Kimi Notification-Store Delivery

> **Canonical mechanism for delivering c2c DMs to managed `c2c start kimi` sessions.**
> Replaces the now-removed kimi wire-bridge (which spawned a fully-agentic
> `kimi --wire --yolo` subprocess per delivery — see finding `b6455d8e`).
> The wire-bridge code (`c2c_wire_daemon.ml`, kimi-specific parts of
> `c2c_wire_bridge.ml`, `Kimi_wire` capability, `c2c wire-daemon` CLI group)
> was deleted in the kimi-wire-bridge-cleanup slice.

## TL;DR

When `c2c start kimi -n <alias>` is the launcher, c2c starts a small
**kimi-notifier daemon** alongside the kimi TUI process. The daemon polls the
broker for incoming DMs every 2 seconds and pushes each one into kimi-cli's
native notification subsystem by writing JSON files to the kimi session's
notification directory.

- **Operator** sees a toast in the kimi TUI within ~3 seconds of any DM
  arriving (kimi's shell-sink watcher is continuous + idle-capable).
- **Agent** sees a `<notification>...</notification>` user-turn injection
  in its conversation context at the next agent turn boundary; the notifier
  sends a tmux `send-keys` wake-prompt when the pane appears idle so this
  happens promptly.
- **No subprocess.** No JSON-RPC. No dual agent. No PATH leaks.

## Architecture

```
broker DM for kimi alias K
    │
    ▼
┌──────────────────────────────────────────────────────────────┐
│ kimi-notifier daemon (forked + setsid'd from c2c start kimi) │
│  - polls broker every 2.0s                                   │
│  - drains inbox for alias K                                  │
│  - resolves K's kimi TUI session-id from kimi.log            │
│  - writes event.json + delivery.json under                   │
│    <KIMI_SHARE_DIR>/sessions/<wh>/<sid>/notifications/<id>/  │
│  - tmux send-keys wakes K's pane if idle (Sys.getenv         │
│    "TMUX_PANE")                                              │
└──────────────────────────────────────────────────────────────┘
    │
    ▼
kimi-cli's NotificationManager (in-process, per-session)
    │
    ├── shell-sink watcher (continuous async, 1s poll)
    │       → toast in TUI: "[c2c-dm] c2c DM from <sender>"
    │
    └── llm-sink (drained at agent turn boundary)
            → injects <notification>...</notification> as
              user-turn message into agent context
```

### Storage layout

Notification store lives inside the kimi session directory:

```
~/.kimi/                                  ← KIMI_SHARE_DIR (overridable)
└── sessions/
    └── <md5(work_dir_path)>/             ← workspace hash
        └── <session-id>/                 ← e.g. 3f29c085-cda5-49c8-...
            ├── context.jsonl
            └── notifications/            ← created on first DM
                └── <12-char-hex-id>/
                    ├── event.json        ← NotificationEvent
                    └── delivery.json    ← NotificationDelivery (sink states)
```

`<md5(work_dir_path)>` is computed verbatim against kimi-cli's
`metadata.py:WorkDirMeta.sessions_dir` (`md5(self.path.encode("utf-8"))
.hexdigest()`). For the c2c repo at `/home/xertrov/src/c2c`, the hash is
`f331b46a50c55c2ba466a5fcfa980fc2`.

### NotificationEvent schema

```json
{
  "version": 1,
  "id": "<12-char-hex>",
  "category": "agent",
  "type": "c2c-dm",
  "source_kind": "<sender-alias>",
  "source_id": "<sender-alias>",
  "title": "c2c DM from <sender-alias>",
  "body": "<DM body>",
  "severity": "info",
  "created_at": <epoch-seconds>,
  "payload": {},
  "targets": ["llm", "shell"],
  "dedupe_key": "<same-as-id>"
}
```

### Notification ID

Deterministic 12-char hex hash of `from_alias|ts|content`:

```ocaml
let key = Printf.sprintf "%s|%.6f|%s" from_alias ts content in
String.sub (Digest.to_hex (Digest.string key)) 0 12
```

This means a c2c retry of the same broker message produces the same
notification id, and kimi de-dupes via the `dedupe_key` field. Safe to
write-and-retry.

### Session-ID discovery (anchor)

The notifier resolves the kimi TUI's active session-id by parsing
`~/.kimi/logs/kimi.log` for the **most recent** line matching:

```
<ts> | INFO | kimi_cli.cli:_run:<lineno> |  - Created new session: <UUID>
```

Regex (in `c2c_kimi_notifier.ml`):

```ocaml
let session_line_re =
  Str.regexp ".*Created new session: \\([0-9a-fA-F-]+\\)"
```

**If kimi-cli updates the log line format**, this regex needs updating in
lockstep. The constant + this runbook anchor are the two synchronization
points; check both when bumping kimi-cli versions.

## Operator commands

### Start a kimi session

```bash
c2c start kimi -n <alias>
```

That's it. The notifier daemon spawns automatically. The wire-daemon CLI
group has been removed entirely (kimi-wire-bridge-cleanup slice); only the
notification-store notifier is used for kimi delivery.

### Stop a kimi session

```bash
c2c stop <alias>
```

This SIGTERMs the kimi TUI and the notifier daemon. The notifier's pidfile
at `~/.local/share/c2c/kimi-notifiers/<alias>.pid` is removed.

### Inspect notifier daemon state

```bash
ls /home/xertrov/.local/share/c2c/kimi-notifiers/
# <alias>.pid + <alias>.log

cat /home/xertrov/.local/share/c2c/kimi-notifiers/<alias>.log
# [kimi-notifier] delivered N message(s)
# [kimi-notifier] error: <exn>   (errors logged but don't kill the daemon)
```

### Inspect a session's notification queue

```bash
ls ~/.kimi/sessions/<wh>/<sid>/notifications/
# 0c8a44b2  4d3f1e10  ...     (per-notification dirs)

cat ~/.kimi/sessions/<wh>/<sid>/notifications/<id>/event.json | jq .
cat ~/.kimi/sessions/<wh>/<sid>/notifications/<id>/delivery.json | jq .

# Sink statuses to look for:
#   shell: pending → claimed → acked    (within ~3s, idle-capable)
#   llm:   pending → claimed → acked    (drains at next agent turn)
```

## Troubleshooting

### "No kimi session-id resolved" in notifier log

The notifier couldn't find a recent `Created new session` line in
`~/.kimi/logs/kimi.log`. Check:

- Is kimi actually running? (`pgrep -af "Kimi Code"`)
- Is `~/.kimi/logs/kimi.log` writable + non-empty?
- Did kimi-cli change its log format? Compare the regex in
  `c2c_kimi_notifier.ml` against current kimi-cli output.

Messages are still archived broker-side, but the agent never sees them
until the session-id can be resolved.

### Toast doesn't appear in TUI

- Confirm shell-sink watcher is running. Check kimi-cli's startup log for
  `Starting Wire server on stdio` (yes, kimi internal naming, unrelated
  to the deprecated c2c wire-bridge).
- Confirm the notification was actually written: `ls
  ~/.kimi/sessions/<wh>/<sid>/notifications/`.
- If the dir is empty, the notifier didn't write — check
  `~/.local/share/c2c/kimi-notifiers/<alias>.log` for write errors.

### Agent doesn't see the message at idle

The LLM-sink only drains at agent turn boundaries. The notifier sends a
tmux send-keys wake-prompt (`[c2c] check inbox` Enter) when the pane
appears idle (no `Thinking…` / `Tool:` / `permission` markers in the last
8 lines). If wake fails:

- Confirm `TMUX_PANE` was set in the env when `c2c start kimi` ran (the
  notifier inherits this; if absent, no wake-trigger fires — toasts still
  surface via shell-sink).
- Inspect `tmux capture-pane -t <pane> -p | tail -8` manually; the
  heuristic falls *open* (assumes idle on capture failure) so absence of
  wake usually means the heuristic detected a busy marker.
- If the kimi pane was scrolled into copy-mode by the operator, the pane
  is "stuck" until they exit copy-mode; this is a known operational
  gotcha not addressed by the wake heuristic.

### Operator typing collides with wake-prompt

If the operator is typing in the kimi pane when the notifier wakes,
the strings concatenate. Mitigation in v1: rare in practice (agent
panes are de-facto agent-owned). v2 may add a "wait for empty input"
gate — track in todo-ideas.txt.

### Recovery: notifier stuck on stale broker_root env

**Symptom**

- Notifier log at `~/.local/share/c2c/kimi-notifiers/<alias>.log` is empty or shows no deliveries.
- Kimi pane appears idle; DMs sent to the alias never surface as toasts or agent-turn injections.
- DMs are visible in the canonical broker inbox (check with `mcp__c2c__peek_inbox` or `c2c inbox <alias>`) but are not being drained.

**Diagnosis**

The notifier process may be polling a stale broker root because `C2C_MCP_BROKER_ROOT` was set to a legacy path (e.g. `.git/c2c/mcp/`) before the canonical default (`$HOME/.c2c/repos/<fp>/broker`) took effect. The notifier was likely launched from a shell that inherited the stale env.

Verify by inspecting the notifier's environment:

```bash
# Find the notifier pid
cat ~/.local/share/c2c/kimi-notifiers/<alias>.pid
# Or: pgrep -af "kimi-notifier.*<alias>"

# Check the broker root it is using
xargs -0 -n1 < /proc/<notifier-pid>/environ | grep C2C_MCP_BROKER_ROOT
```

If the path points to a non-canonical or non-existent broker directory, the notifier is polling into the void.

**Recovery sequence**

1. **Unset the stale env** in your current shell:
   ```bash
   unset C2C_MCP_BROKER_ROOT
   ```
2. **Stop the orphaned session**:
   ```bash
   c2c stop <alias>
   ```
   This SIGTERMs both the kimi TUI and the stale notifier.
3. **Restart from a clean shell**:
   ```bash
   c2c start kimi -n <alias>
   ```
   The new notifier inherits the canonical broker root and resumes draining.
4. **Verify**: send a test DM to the alias and confirm it surfaces within ~3 seconds.

**Prevention**

Three mitigations shipped in #581 reduce the likelihood of future stale-env orphans:

- **S1** (`16b50044`) — `c2c start` warns + clears env when `C2C_MCP_BROKER_ROOT` points to a non-canonical path, so child daemons inherit the canonical default.
- **S2** (`e4eee870`) — `c2c-kimi-notif` logs a startup banner with alias/session_id/broker_root/inbox path; 0-byte log files for live daemons are now impossible.
- **S3** (`3b528406`) — `c2c migrate-broker --suggest-shell-export` prints the `unset C2C_MCP_BROKER_ROOT` line + `grep` helpers operators can run against their shell rc files to clean up stale exports.

Root-cause finding: `36e9dfd7` (stale env propagation into c2c-kimi-notif during bring-up).

## Implementation pointers

- Module: `ocaml/c2c_kimi_notifier.ml` + `.mli`
- Tests: `ocaml/test/test_c2c_kimi_notifier.ml`
- Probe research: `.collab/research/2026-04-29T10-27-00Z-stanza-coder-
  kimi-notification-store-push-validated.md`
- Root-cause finding: `.collab/findings/2026-04-29T10-04-00Z-stanza-
  coder-c2c-start-kimi-spawns-double-process.md`

## Safe-pattern allowlist (#587, #142 Path B)

The kimi PreToolUse approval hook (`c2c-kimi-approval-hook.sh`) filters
read-only commands before forwarding to a reviewer. Safe commands exit 0
immediately without a DM round-trip; everything else triggers a
reviewer DM and awaits a verdict.

**Why**: Without the allowlist, every `Shell` tool call fires the hook
and floods the reviewer with DMs — even completely benign commands like
`cat`, `ls`, `git status`. The allowlist makes the hook cheap for the
common 90% case.

**Policy** (embedded in `scripts/c2c-kimi-approval-hook.sh`):

```bash
# Safe commands — exit 0 immediately, no DM
case "$first" in
  cat|ls|pwd|head|tail|wc|file|stat|which|whereis|type|env|printenv|\
  echo|printf|true|false|test|\[)
    return 0 ;;
  grep|rg|ag|find|fd|tree|du|df|free|uptime|date|hostname|whoami|id|\
  ps|pgrep|pidof|lsof|jobs|history|column|sort|uniq|cut|paste|tr|sed|awk|\
  jq|yq|xq|tomlq)
    return 0 ;;
  git)
    # Only read-only git subcommands
    case "$sub" in
      status|log|diff|show|branch|tag|remote|config|rev-parse|\
      rev-list|describe|blame|reflog|ls-files|ls-tree|fetch|\
      shortlog|count|status|-h|--help)
        return 0 ;;
    esac ;;
esac
# Unsafe → falls through to reviewer DM path
```

**Test coverage**: `scripts/test-c2c-kimi-approval-hook.sh` has 14 test
cases covering all major safe commands (`cat`, `ls`, `grep`, `git status`,
`git log`, `pwd`) and unsafe commands that must forward (`rm`, `git push`,
`curl|bash`).

**Key files**:
- `scripts/c2c-kimi-approval-hook.sh` — live script (source of truth)
- `ocaml/cli/c2c_kimi_hook.ml` — embedded copy, deployed by `c2c install kimi`
- `scripts/test-c2c-kimi-approval-hook.sh` — shell-level unit tests

## See also

- `.collab/runbooks/agent-wake-setup.md` — heartbeat + monitor recipes
  (different domain — these wake the *Claude* agent, not kimi)
- `docs/MSG_IO_METHODS.md` (post-update) — public-facing summary of all
  delivery methods
- `docs/client-delivery.md` (post-update) — per-client delivery diagrams
