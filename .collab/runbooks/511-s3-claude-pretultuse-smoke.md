# Claude Code PreToolUse Hook — Smoke Test Runbook

**Slice**: #511 Slice 3
**Date**: 2026-05-01
**Author**: cedar-coder

---

## What This Tests

`c2c install claude` registers a PreToolUse hook entry pointing to
`~/.local/bin/c2c-kimi-approval-hook.sh` in `~/.claude/settings.json`. The
hook script itself is installed by `c2c install kimi`. When the operator edits
the matcher to opt in, a matching tool call fires the hook, which forwards the
request to the first live authorizer in the `authorizers[]` chain via c2c DM.

---

## Prerequisites

- `c2c install claude` has been run
- `c2c install kimi` has been run (installs `~/.local/bin/c2c-kimi-approval-hook.sh`)
- At least one live authorizer in `~/.c2c/repo.json`'s `authorizers[]` list
  (default: `coordinator1`)
- Claude Code session running with the installed c2c broker

---

## Step 1 — Verify Registration

```bash
# Check that the PreToolUse entry exists in settings.json
jq '.hooks.PreToolUse[] | select(.matcher == "__C2C_PREAUTH_DISABLED__")' \
  ~/.claude/settings.json
```

Expected output:
```json
{
  "matcher": "__C2C_PREAUTH_DISABLED__",
  "hooks": [
    {
      "type": "command",
      "command": "/home/<user>/.local/bin/c2c-kimi-approval-hook.sh"
    }
  ]
}
```

If absent, re-run `c2c install claude`.

---

## Step 2 — Opt In

Edit `~/.claude/settings.json` and change the `matcher` from
`"__C2C_PREAUTH_DISABLED__"` to something that matches `Shell`, e.g.:

```json
"matcher": "Shell"
```

Claude Code must be restarted for matcher changes to take effect.

---

## Step 3 — Trigger the Hook

From within the Claude Code session, run any shell command, e.g.:

```
/shell echo "smoke test"
```

Or trigger the permission prompt on a destructive call:

```
/shell rm -rf /
```

---

## Step 4 — Verify DM Arrives

Check the inbox of the first live authorizer (e.g. `coordinator1`):

```bash
# From the authorizer's session:
c2c poll_inbox
```

Expected: a DM from the calling agent containing the approval request with a
`token:` field. The authorizer can then:

```bash
c2c approval-reply <token> allow   # or deny
```

---

## Step 5 — Verify Hook Exit Code

If the authorizer approves within the timeout, the hook exits `0` and the
tool call proceeds. If denied or timeout, the hook exits `2` and Claude Code
shows the rejection reason.

---

## Troubleshooting

**Hook not firing**: Is the matcher `"__C2C_PREAUTH_DISABLED__"`? It must be
changed to a regex that matches the tool you want to forward (e.g. `"Shell"`).

**No DM received**: Is the authorizer live? Check `c2c list --json` to confirm
the authorizer is registered and not DnD.

**Hook script missing**: `~/.local/bin/c2c-kimi-approval-hook.sh` must exist.
Run `c2c install kimi` to install it.

---

## Relevant Files

- `ocaml/cli/c2c_setup.ml` — `configure_claude_hook` (~line 718): PreToolUse registration
- `ocaml/cli/c2c_kimi_hook.ml` — embedded hook script (`c2c-kimi-approval-hook.sh`)
- `.c2c/repo.json` — `authorizers[]` list
