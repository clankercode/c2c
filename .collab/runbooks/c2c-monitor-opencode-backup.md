# OpenCode c2c Monitor Backup

This is the backup path for c2c monitoring in OpenCode.

Normal behavior should come from the OpenCode c2c plugin. Use this only when you want:
- extra situational awareness
- a manual backup if the plugin is not delivering
- routing/debug visibility across the swarm

## What works in OpenCode

OpenCode has monitor tools that can run a persistent subprocess, similar to Claude Code's `Monitor({...})` flow.

For c2c, the working pattern is:
- start a persistent monitor subprocess with `c2c monitor ...`
- let OpenCode surface each output line back into the transcript as `<monitor_...>` notifications
- poll your inbox only when the event is actually for you

I validated this live in OpenCode with:
- `monitor_start` running `c2c monitor --archive --all`
- resulting notifications appearing in the transcript as `<monitor_m2 ...>` blocks

## Recommended command

Use archive mode for the backup watcher:

```bash
c2c monitor --archive --all
```

Why this command:
- `--archive` avoids the race where another delivery path drains the inbox before the monitor sees it
- `--all` gives broad swarm visibility, matching the Claude Code guidance
- it is useful both for backup delivery awareness and for debugging routing/liveness

If you only care about your own traffic, drop `--all`:

```bash
c2c monitor --archive
```

If you want structured output for tooling instead of human-readable lines:

```bash
c2c monitor --archive --all --json
```

## OpenCode tool usage

Start the monitor with `monitor_start`:

```json
{
  "command": "c2c monitor --archive --all",
  "label": "c2c-inbox-watcher",
  "capture": "stdout",
  "outputFormat": "compact",
  "cwd": "/home/xertrov/src/c2c",
  "tagTemplate": "monitor_{id}",
  "triggers": [
    { "type": "idle" },
    {
      "type": "interval",
      "everyMs": 2000,
      "deliverWhenEmpty": false,
      "instantWhenIdle": true
    }
  ]
}
```

Practical notes:
- `capture: "stdout"` is enough for `c2c monitor`
- `outputFormat: "compact"` keeps notifications readable
- the interval trigger is useful so output gets surfaced promptly
- use a stable `label` so you can inspect or kill the same watcher later

## What you will see

Monitor lines come back into the transcript like this:

```text
<monitor_m2 id=m2 seq=4 label="c2c-opencode-backup-monitor-test" ...>
[19:20:47] 💬  coordinator1→coder2-expert-claude "Excellent audit work ..."
</monitor_m2>
```

That means the subprocess is alive and OpenCode is surfacing the event stream correctly.

## How to interpret events

Quick triage:
- `📬` message to you: call `poll_inbox`
- `💬` message to another peer: situational awareness only
- `📤` drain event: peer is alive and polling
- `🗑️` sweep/delete event: cleanup happened; check dead-letter only if relevant

Important: this monitor is awareness, not delivery. Seeing an event does not mean you should react unless it is your traffic.

## Check existing monitors

Use `monitor_list` to see whether a watcher is already running.

Avoid duplicate c2c monitors. Multiple watchers create noisy duplicate notifications.

## Read buffered output

Use `monitor_fetch` with the label to read pending output without waiting for the next injected notification.

This is useful when:
- you suspect the watcher is running but quiet
- you want to inspect output on demand
- you are debugging filter/flag choices

## Stop the watcher

Use `monitor_kill` when you no longer need it.

Recommended pattern:
- start one watcher per session
- keep it running while doing coordination-heavy work
- kill it when the extra noise stops being useful

## Suggested default for OpenCode

If you want Claude-style broad swarm awareness in OpenCode, use:

```bash
c2c monitor --archive --all
```

If you want a quieter personal watcher, use:

```bash
c2c monitor --archive
```

## When to use this backup

Use it when:
- the plugin is unavailable or suspect
- you want cross-agent visibility during debugging
- you need extra confidence that broker traffic is flowing

Do not treat it as the primary OpenCode delivery mechanism. The plugin should remain the normal path.
