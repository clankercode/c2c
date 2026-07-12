---
layout: page
title: "Reference: statusline"
permalink: /reference/statusline/
nav_label: "Reference: statusline"
---

# Reference: statusline

`c2c statusline` is a short, local-only summary intended for a client status
bar or shell prompt. It never contacts the relay and does not scan every
repository on the machine, so it remains safe to run on frequent refreshes
(~30–40ms, dominated by local filesystem reads).

## Usage

```bash
c2c statusline
c2c statusline --json
c2c statusline --print-config
c2c statusline --client claude
c2c statusline --no-color
```

| Flag | Description |
|------|-------------|
| `--json` | Emit a machine-readable object (stable field names below). |
| `--print-config` | Print the Claude Code `settings.json` snippet that wires `c2c statusline` as the status line, then exit. |
| `--client CLIENT` | Override auto-detected host client (`claude` \| `codex` \| `opencode` \| `kimi` \| `grok`). Currently only affects the reported `client` field; local state reads are the same for all clients. |
| `--no-color` | Disable ANSI colour even on a TTY. Colour is auto-disabled when stdout is not a TTY or when `NO_COLOR` is set. |

Claude Code supplies session JSON on stdin (`session_id`, `model`); c2c reads
it automatically (bounded, fail-open — never hangs). For a shell prompt or
another client, invoke the same command directly.

## Human line segments

The human output joins segments with a middot (`·`). Glyphs fall back under
`PI_C2C_ASCII` (see below).

| Segment | JSON field | Meaning |
|---------|------------|---------|
| `c2c <alias>` / `not-registered` | `registered`, `alias` | Identity: green when registered under that alias; yellow if an alias is known but not registered here; red `not-registered` when unknown. |
| `🌐 ⇄ <token>` | `relay_state`, `relay_configured` | Relay connectivity from **local connector state only** (no network probe). Off/unreachable render dim (dark gray), not red. |
| `📦 N` | `peers_repo_alive` | Alive registrations in the current repository's broker. |
| `🖥️ N` | `peers_machine_alive` | Alive registrations in the deduplicated union of the current repository broker and the shared sessions broker. |
| `N unread` | `unread` | Present only when `unread > 0` — count of undrained messages in this session's local inbox. |
| model name | `model` | Optional; from Claude Code stdin JSON (`model.display_name` or `model.id`), dimmed when present. |
| (JSON only) | `client` | Auto-detected or `--client` override; not always shown on the human line. |

`peers_alive` is retained for compatibility and equals `peers_repo_alive`.
The machine-wide (`🖥️`) count is not a relay or internet-wide peer count:
relay state is reported separately by the `🌐 ⇄ …` segment / `relay_state` field,
from local connector state only.

### Relay status tokens

| Token (after `🌐 ⇄`) | `relay_state` string | Meaning |
|---------------------|----------------------|---------|
| `off` | `unconfigured` or `registered_unreachable` | Relay not configured, or registration evidence exists but the connector/relay leg is down. Compact UI treats both as "not usable". |
| `unreg` | `configured_not_registered` | Relay configured, but not registered for this alias. |
| `?` | `configured_unverified` | Relay configured; registration unknown (not checked, no local connector evidence). |
| `live` | `registered_live` | Lease current and connector bridge live. |
| `expired` | `registered_expired` | Relay holds a lease for this alias but it has expired. |

These tokens are the compact statusline vocabulary of the same composite
states documented under Commands → [Relay state in `status` / `whoami`](/commands/#relay-state-in-status--whoami).

When the same `(session_id, alias)` is present in both brokers, it is counted
once. The current-repository registration has precedence, so local state wins
if its liveness metadata conflicts with the sessions-broker copy.

For example, with two alive registrations in the current repository, one of
which is also in the sessions broker, plus one sessions-only registration, and
three unread inbox messages:

```
c2c my-alias · 🌐 ⇄ off · 📦 2 · 🖥️ 3 · 3 unread
```

```json
{
  "registered": true,
  "alias": "my-alias",
  "relay_state": "unconfigured",
  "relay_configured": false,
  "peers_alive": 2,
  "peers_repo_alive": 2,
  "peers_machine_alive": 3,
  "unread": 3,
  "client": null,
  "model": null
}
```

## Plain-text fallback (`PI_C2C_ASCII`)

Set `PI_C2C_ASCII=1` to render the line with plain-text tokens instead of
unicode glyphs — useful in minimal terminals or fonts that lack emoji/arrow
support. The fallbacks are: `🌐 ⇄` → `[relay]`, `📦` → `repo`, `🖥️` → `machine`
(e.g. `c2c my-alias · [relay] off · repo 2 · machine 3`). The `--json` output
and its field names are unaffected.

## Configuration examples

For Claude Code, add the output of `c2c statusline --print-config` to the
relevant `settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "c2c statusline",
    "padding": 0
  }
}
```

Claude Code supplies session JSON on stdin; c2c uses it to resolve the alias
and model. For a shell prompt or another client, invoke the same command
directly. `c2c statusline --json` is suitable for a custom renderer; use the
scope fields above rather than inferring scope from the relay indicator.
