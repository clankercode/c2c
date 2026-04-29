# Kimi-cli hooks: permission/approval interception feasibility

- **Date**: 2026-04-30
- **Author**: stanza-coder
- **Scope**: research-only — no code changes
- **Source**: `/home/xertrov/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/`
  (kimi-cli installed via `uv tool`, version per `~/.kimi/latest_version.txt`)

## TL;DR

- **Kimi-cli has a Claude-Code-style hook subsystem** at `kimi_cli/hooks/` with
  13 lifecycle events. `PreToolUse` fires synchronously **before** the tool
  body runs and **before** the approval runtime is consulted, exactly the
  point we need.
- **Hooks can BLOCK and return a verdict**: shell exit code `2` blocks
  with the stderr as reason; exit `0` with JSON `{"hookSpecificOutput":
  {"permissionDecision": "deny", "permissionDecisionReason": "..."}}`
  also blocks. Hook timeout is configurable up to **600s**, fail-open on
  timeout/error.
- **There is NO `permissionDecision: "allow"` short-circuit** —
  returning allow only lets the tool proceed to its own approval flow.
  This means c2c MUST run kimi in `--yolo` (or `--afk`) so kimi's
  internal approval auto-passes; the hook becomes the *sole* gate.
- **Working pattern**: c2c registers a single `PreToolUse` shell hook
  with `matcher = ""` (all tools); the hook script reads JSON on stdin,
  DMs the operator over c2c with the tool_name + args, blocks waiting
  for verdict, exits `2` (deny) or `0` (allow). Round-trip latency
  bounded by `timeout` (max 600s).
- **There is NO `kimi hooks` subcommand** — the spec lives entirely in
  `~/.kimi/config.toml`. The `kimi --help` output the task referenced
  was actually gemini-cli's. No CLI mgmt surface to integrate with.
- **Verdict — hooks are sufficient**. We do not need an upstream
  `--expose-approval-ipc` feature ask; this can ship today against the
  installed kimi-cli with config-file edits + a small shell script.

## Hook events (full table)

Source: `kimi_cli/hooks/config.py:5` and `kimi_cli/hooks/events.py`.

| Event name           | When it fires                                           | Sync/Async   | Can block? | Notes |
|----------------------|---------------------------------------------------------|--------------|------------|-------|
| `PreToolUse`         | Before each tool's `__call__`, before approval runtime  | **sync, awaited** | **YES** | Our target. `matcher_value=tool_name`. |
| `PostToolUse`        | After successful tool execution                         | fire-and-forget | no  | Telemetry only. |
| `PostToolUseFailure` | After tool raises                                       | fire-and-forget | no  | |
| `UserPromptSubmit`   | When user submits a prompt                              | sync          | yes (limits prompt) | |
| `Stop`               | When agent loop stops normally                          | sync          | yes        | |
| `StopFailure`        | When agent loop errors                                  | sync          | yes        | |
| `SessionStart`       | Session begin                                           | sync          | yes        | |
| `SessionEnd`         | Session end                                             | sync          | n/a        | |
| `SubagentStart`      | Subagent dispatched                                     | sync          | yes        | |
| `SubagentStop`       | Subagent returns                                        | sync          | n/a        | |
| `PreCompact`         | Before context compaction                               | sync          | yes        | |
| `PostCompact`        | After context compaction                                | sync          | n/a        | |
| `Notification`       | Notification sink emit                                  | sync          | n/a        | |

The PreToolUse fire site (verbatim from `kimi_cli/soul/toolset.py:163`):

```python
# --- PreToolUse ---
from kimi_cli.hooks import events

results = await self._hook_engine.trigger(
    "PreToolUse",
    matcher_value=tool_call.function.name,
    input_data=events.pre_tool_use(
        session_id=_get_session_id(),
        cwd=str(Path.cwd()),
        tool_name=tool_call.function.name,
        tool_input=tool_input_dict,
        tool_call_id=tool_call.id,
    ),
)
for result in results:
    if result.action == "block":
        return ToolResult(
            tool_call_id=tool_call.id,
            return_value=ToolError(
                message=result.reason or "Blocked by PreToolUse hook",
                brief="Hook blocked",
            ),
        )

# --- Execute tool ---
ret = await tool.call(arguments)
```

`tool.call(arguments)` is what dispatches into e.g. `MCPTool.__call__`,
which is where `self._runtime.approval.request(...)` gets invoked
(`kimi_cli/soul/toolset.py:586-588`). So the order is:

```
PreToolUse hook → tool.__call__ → ApprovalRuntime.create_request → wait_for_response → ... tool body
```

A blocking PreToolUse returns a `ToolError("Blocked by PreToolUse hook")`
to the agent and the approval runtime is **never invoked**.

## Why we still need `--yolo`

The runner's contract for hook output (`kimi_cli/hooks/runner.py:60-87`):

| Hook output                                                  | Engine action |
|--------------------------------------------------------------|---------------|
| Exit `2`                                                     | `block`, reason = stderr |
| Exit `0` + JSON with `hookSpecificOutput.permissionDecision == "deny"` | `block`, reason = `permissionDecisionReason` |
| Exit `0` + anything else (including JSON with `"allow"`)     | `allow` — falls through to tool body |
| Exit `0` + non-JSON stdout                                   | `allow` |
| Timeout / subprocess exception                               | `allow` (fail-open) |

There is **no path** for a hook to *bypass* the in-tool approval
prompt. So if kimi is in interactive mode (no yolo), every tool that
calls `runtime.approval.request(...)` will still pop the approval
modal AFTER the hook says allow. Two options:

1. **Run kimi with `--yolo`** (or persisted `afk`). `Approval.request()`
   short-circuits at `is_auto_approve()` (`kimi_cli/soul/approval.py:185`)
   and returns `approved=True` immediately. The PreToolUse hook is then
   the *only* gate, and the c2c-DMed operator is the *only* approver.
2. **Patch kimi-cli** to honor `permissionDecision: "allow"` (one-line
   change in `runner.py`). This is the upstream feature ask. Cleaner
   long-term but optional.

For shipping today, option 1 is sufficient. The cost is that any tool
the hook explicitly *allows* can no longer also surface an in-kimi
approval modal — but that's by design when c2c is the approval surface.

## Hook contract (mechanics)

| Field         | Value |
|---------------|-------|
| Config location | `~/.kimi/config.toml` (override via `KIMI_SHARE_DIR`) |
| Schema | `[[hooks]]` array of `HookDef` (`kimi_cli/hooks/config.py:24`) |
| Hook fields | `event` (required, one of the 13), `command` (shell, required), `matcher` (regex, default `""` = all), `timeout` (1-600s, default 30) |
| Stdin payload | JSON; for PreToolUse: `{hook_event_name, session_id, cwd, tool_name, tool_input, tool_call_id}` |
| Stdout protocol | optional JSON `{hookSpecificOutput: {permissionDecision: "deny", permissionDecisionReason: "..."}}` |
| Block via exit | exit code `2`; stderr becomes reason |
| Allow | any non-2 exit (default `0`) |
| Timeout | engine fails open (allow) |
| CWD | `cwd` param of `HookEngine` (the kimi process's cwd at startup) |
| Multiple hooks | If two hooks match the same event, ANY block wins (`kimi_cli/hooks/engine.py:312`) |
| Dedup | Hooks with identical `command` strings deduped per event (`engine.py:217`) |
| Telemetry | `track("hook_triggered", event_type=..., action=block|allow)` always — does NOT fail-open |

There is also a **wire-side hook subscription** path
(`WireHookSubscription` in `engine.py:27`, `HookRequest`/`HookResponse`
in `wire/types.py:526-579`). A wire-attached client (kimi's IDE-style
external controller) can subscribe to hook events at `initialize` time
and get `HookRequest`s pushed instead of running shell commands. Same
allow/block semantics, same per-subscription timeout. **This is a
second viable interception path for c2c** if we ever want to attach
over kimi's wire protocol instead of via shell hook — but the shell
hook is simpler to ship.

## Working example (config + script)

`~/.kimi/config.toml` snippet:

```toml
[[hooks]]
event   = "PreToolUse"
matcher = ""              # all tools
command = "exec /home/xertrov/.local/bin/c2c-kimi-approval-hook"
timeout = 300             # operator has 5 min to respond before fail-open
```

`/home/xertrov/.local/bin/c2c-kimi-approval-hook` (sketch):

```bash
#!/usr/bin/env bash
# Reads PreToolUse JSON on stdin; DMs the operator via c2c; blocks
# until reply or timeout; exits 2 (deny) or 0 (allow).
set -euo pipefail

payload="$(cat)"
tool_name="$(jq -r .tool_name <<<"$payload")"
tool_input="$(jq -c .tool_input <<<"$payload")"
session_id="$(jq -r .session_id <<<"$payload")"
call_id="$(jq -r .tool_call_id <<<"$payload")"

# Fast-path allowlist (avoid round-tripping safe tools)
case "$tool_name" in
  Read|Glob|Grep|TaskList|Monitor) exit 0 ;;
esac

# Synthesize a unique reply token, DM operator, wait for reply.
token="approval-${session_id}-${call_id}"
body="$(printf 'KIMI APPROVAL REQUEST\ntool: %s\nargs: %s\nreply ALLOW or DENY (token=%s)' \
  "$tool_name" "$tool_input" "$token")"

c2c send coordinator1 "$body" >/dev/null

# Block until coordinator replies with the token.
verdict="$(c2c await-reply --token "$token" --timeout 280)"
case "$verdict" in
  ALLOW) exit 0 ;;
  DENY)
    echo "denied by remote operator" >&2
    exit 2
    ;;
  *)
    echo "no verdict (timeout) — failing open" >&2
    exit 0
    ;;
esac
```

`c2c await-reply --token <T> --timeout <S>` is a c2c subcommand we'd
need to add (it's already 90% there — the broker has reply-tracking
plumbing for `mcp__c2c__check_pending_reply` /
`mcp__c2c__open_pending_reply`; we just need a CLI wrapper that blocks).

Operator workflow on the receiving side: c2c DM arrives carrying tool
+ args + token. Operator replies `c2c send <kimi-alias> "ALLOW
token=approval-..."`. The hook script unblocks, exits 0, kimi runs the
tool. (The exact reply-protocol shape is a slice-design detail — could
be free-text matched against the token, or an opt-in MCP tool.)

Launch kimi with:

```bash
kimi --yolo  # so internal approval auto-passes; the hook is the gate
```

## Comparison: hooks vs upstream `--expose-approval-ipc` feature ask

| Dimension | Hooks (this design) | Upstream `--expose-approval-ipc` |
|-----------|---------------------|----------------------------------|
| Architecture cleanliness | Single PreToolUse interception point; reuses existing kimi extension surface | New IPC channel, new CLI flag, new protocol |
| Upstream dependency | None — works against installed kimi-cli today | Requires accepted PR + version bump + every kimi user upgrades |
| Code in c2c | Shell script (~30 LOC) + one config snippet written by `c2c install kimi` | New IPC client + lifecycle mgmt |
| Delivery latency | One `c2c send` + one operator reply + script wakeup; ~1-2s overhead per call beyond operator decision time | Similar — IPC call instead of shell exec |
| Audit trail | Every approval is a c2c DM in the room/archive — already searchable, already replicated | Need to design a separate audit surface |
| Portability | Same hook config shape would work for any client with PreToolUse hooks (Claude Code uses the IDENTICAL JSON protocol — `permissionDecision: deny`, `hookSpecificOutput`) | kimi-only |
| Risk surface | Hook timeout is bounded (≤600s), fail-open by default — if c2c broker is down, kimi keeps working in yolo | IPC stall could hang kimi |
| Limitation | Requires `--yolo` (no in-kimi modal fallback) | Native — kimi's modal stays available as fallback |
| Granularity | Per-tool via `matcher` regex; multiple hooks compose via "any-block-wins" | Whatever the IPC surface exposes |

The portability point is significant: **the same shell script works
on Claude Code** (it uses the same JSON-on-stdin / exit-2 / `permissionDecision: deny`
protocol). One c2c-approval-hook script, two clients. Codex would need a
separate path (it has its own approval IPC), but the kimi+claude
overlap is a free win.

## Recommendations

1. **Skip the upstream feature ask**. Implement the hook-based approach.
2. **Slice 1 — script + install**: write `c2c-kimi-approval-hook`,
   add a `c2c await-reply` CLI subcommand (or reuse the existing
   pending-reply MCP plumbing as a shell-callable surface), make
   `c2c install kimi` write the `[[hooks]]` block into
   `~/.kimi/config.toml`.
3. **Slice 2 — yolo enforcement**: `c2c start kimi` should pass
   `--yolo` automatically (or warn loudly if launched without it,
   since approval will then double-prompt).
4. **Slice 3 — Claude Code reuse**: same script, written into
   `~/.claude/settings.json` `hooks.PreToolUse[]`. Cross-client
   approval forwarding for free.
5. **Optional follow-up — wire-side path**: if c2c grows a kimi-wire
   client (which would bring full structured event streaming), migrate
   from shell-hook to wire `HookRequest` subscription. Same semantics,
   no subprocess-per-tool overhead.
6. **Document the `--yolo` requirement loud and clear** — operators
   need to understand kimi's local auth is delegated to remote
   c2c-relayed approval. That's a real security model shift and
   belongs in a runbook, not just a README footnote.

## Files referenced

- `/home/xertrov/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/hooks/config.py` (HookDef, event enum)
- `/home/xertrov/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/hooks/engine.py` (HookEngine, wire subs, aggregation)
- `/home/xertrov/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/hooks/runner.py` (subprocess runner, exit-code protocol)
- `/home/xertrov/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/hooks/events.py` (per-event payload builders)
- `/home/xertrov/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/soul/toolset.py:163-186` (PreToolUse fire site)
- `/home/xertrov/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/soul/approval.py:151-220` (Approval.request flow; auto-approve short-circuit at line 185)
- `/home/xertrov/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/approval_runtime/runtime.py` (ApprovalRuntime.create_request — the "after" point)
- `/home/xertrov/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/wire/types.py:526-579` (HookRequest/Response wire protocol — alternative path)
- `/home/xertrov/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/config.py:241` (`hooks: list[HookDef]` config field)
- `/home/xertrov/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/share.py` (config dir = `$KIMI_SHARE_DIR` or `~/.kimi`)
- `~/.kimi/config.toml` (current installed config — already has `hooks = []` field present)
