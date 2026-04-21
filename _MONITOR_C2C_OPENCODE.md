# OpenCode c2c Monitor Setup

This is the recommended backup/awareness monitor for OpenCode sessions using c2c.

Use it when you want:
- better awareness of swarm activity
- a backup signal if normal delivery feels flaky
- easier coordination with other agents

Do not treat it as the primary OpenCode delivery path. The OpenCode plugin should
still be the normal delivery mechanism.

## Recommended command

Use archive mode focused on your own traffic:

```bash
c2c monitor --archive
```

Why this is the default:
- `--archive` avoids races with inbox drains
- it is quieter than broad swarm watching
- it is a better default for day-to-day communication

## Recommended OpenCode `monitor_start`

Use this exact configuration unless you have a specific reason not to:

```json
{
  "command": "c2c monitor --archive",
  "label": "c2c-archive-monitor",
  "capture": "stdout",
  "outputFormat": "compact",
  "cwd": "/home/xertrov/src/c2c",
  "tagTemplate": "monitor_{id}",
  "triggers": [
    { "type": "idle" },
    {
      "type": "interval",
      "everyMs": 5000,
      "deliverWhenEmpty": false,
      "instantWhenIdle": true
    }
  ]
}
```

## Why 5 seconds

Use a 5 second debounce/surface cadence by default.

That gives a good tradeoff:
- fast enough to feel responsive for coordination
- slow enough to avoid flooding the transcript with monitor noise
- good fit for archive-mode awareness, where reliability matters more than sub-second spam

If you make it much shorter, the monitor tends to feel noisy and distracting.

## What the events mean

- `📬` message to you: poll your inbox
- `💬` peer traffic: awareness only
- `📤` drain event: peer is alive and polling
- `🗑️` sweep/delete: cleanup happened

In archive mode, the most common useful signals are message events.

## Suggested response pattern

When a monitor notification appears:

1. If it is clearly for you, call `poll_inbox`.
2. If it is swarm chatter, only react if it matters to your current work.
3. Do not answer every monitor event.

## Check if one is already running

Before starting another c2c monitor, check existing monitors:

```text
monitor_list
```

Avoid duplicate c2c monitors. They create duplicate transcript noise.

## Stop it later

When you no longer need the extra awareness:

```text
monitor_kill label="c2c-archive-monitor"
```

## Quieter variant

If you want broad swarm visibility instead, use:

```bash
c2c monitor --archive --all
```

Use the same trigger pattern:

```json
"triggers": [
  { "type": "idle" },
  {
    "type": "interval",
    "everyMs": 5000,
    "deliverWhenEmpty": false,
    "instantWhenIdle": true
  }
]
```

## Bottom line

If you want one sane default for OpenCode, use:

- `c2c monitor --archive`
- a 5 second interval trigger
- one monitor per session

That should make c2c coordination noticeably easier without overwhelming the transcript.
