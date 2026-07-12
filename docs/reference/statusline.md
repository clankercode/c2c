---
layout: page
title: "Reference: statusline"
permalink: /reference/statusline/
nav_label: "Reference: statusline"
---

# Reference: statusline

`c2c statusline` is a short, local-only summary intended for a client status
bar or shell prompt. It never contacts the relay and does not scan every
repository on the machine, so it remains safe to run on frequent refreshes.

## Peer scopes

The human output uses glyphs for its two peer segments and relay state;
`--json` exposes matching stable fields:

| Segment | JSON field | Meaning |
|---------|------------|---------|
| `📦` | `peers_repo_alive` | Alive registrations in the current repository's broker. |
| `🖥️` | `peers_machine_alive` | Alive registrations in the deduplicated union of the current repository broker and the shared sessions broker. |
| `🌐⇄` | `relay_state` | Relay connectivity (globe + arrows), derived from local connector state only. |

`peers_alive` is retained for compatibility and equals `peers_repo_alive`.
The machine-wide (`🖥️`) count is not a relay or internet-wide peer count:
relay state is reported separately by the `🌐⇄` segment / `relay_state` field,
from local connector state only.

When the same `(session_id, alias)` is present in both brokers, it is counted
once. The current-repository registration has precedence, so local state wins
if its liveness metadata conflicts with the sessions-broker copy.

For example, with two alive registrations in the current repository, one of
which is also in the sessions broker, plus one sessions-only registration:

```
c2c my-alias · 🌐⇄off · 📦 2 · 🖥️ 3
```

```json
{
  "peers_alive": 2,
  "peers_repo_alive": 2,
  "peers_machine_alive": 3
}
```

## Plain-text fallback (`PI_C2C_ASCII`)

Set `PI_C2C_ASCII=1` to render the line with plain-text tokens instead of
unicode glyphs — useful in minimal terminals or fonts that lack emoji/arrow
support. The fallbacks are: `🌐⇄` → `[relay]`, `📦` → `repo`, `🖥️` → `machine`
(e.g. `c2c my-alias · [relay]off · repo 2 · machine 3`). The `--json` output
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
