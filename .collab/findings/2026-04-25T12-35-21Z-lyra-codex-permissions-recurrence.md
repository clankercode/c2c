# Codex permission forwarding recurrence

**Date:** 2026-04-25T12:35:21Z  
**Author:** lyra-quill  
**Scope:** Investigation only; no implementation in this slice.

## Symptom

Codex permission requests are still recurring in the wild without being forwarded
over c2c. OpenCode has a working permission-forwarding path, but managed Codex
sessions still surface approvals locally instead of routing them to supervisors
through broker messages.

## Reference: fd sideband guide

`.collab/ext-docs/codex/x-fd-sideband-guide.md` defines the intended x-thin
sideband lanes:

- `--xml-input-fd <fd>`: Codex/TUI or `codex-turn-start-bridge` reads XML user
  messages.
- `--server-request-events-fd <fd>`: bridge writes server request events.
- `--server-request-responses-fd <fd>`: bridge reads responses to server request
  events.

The guide's ownership rule is explicit: each sideband endpoint must have one
long-lived owner, and unused inherited copies must be closed after fork/dup2.
Event lanes and response lanes are separate descriptors and must not be reused.

## Current code path

Static inspection shows two separate Codex paths:

1. **Normal managed `codex`**:
   - `ocaml/c2c_start.ml` adds only `--xml-input-fd 3` when
     `codex_supports_xml_input_fd` is true.
   - Deliver daemon is launched with only `--xml-output-fd 4`.
   - No `--server-request-events-fd`, `--server-request-responses-fd`,
     `--event-fifo`, or `--response-fifo` is wired for normal `codex`.

2. **`codex-headless` bridge path**:
   - `prepare_launch_args` adds `--server-request-events-fd 6` and
     `--server-request-responses-fd 7`.
   - The bash wrapper redirects `6> "$events"` and `7<> "$responses"`.
   - `c2c_deliver_inbox.py` receives `--event-fifo` and `--response-fifo`,
     parses `permissions_approval_request`, DMs supervisors, and writes a
     `permissions_approval_response` envelope back.

So the c2c permission-forwarding implementation exists, but it is currently
subscribed only to the `codex-headless` bridge event stream. Normal interactive
Codex has no equivalent event/response subscription.

## Live probe

I launched a temporary managed interactive Codex session in tmux:

```bash
env -u C2C_MCP_SESSION_ID \
    -u C2C_MCP_AUTO_REGISTER_ALIAS \
    -u C2C_MCP_CLIENT_PID \
    -u CLAUDE_SESSION_ID \
    C2C_START_DEBUG=1 \
    c2c start codex -n lyra-perm-probe --alias lyra-perm-probe
```

The managed instance resumed the last Codex thread and produced this metadata:

```json
{
  "client": "codex",
  "binary": "/home/xertrov/.local/bin/codex",
  "args": [ "--xml-input-fd", "3", "resume", "--last" ],
  "pid": 2225738
}
```

The live child processes were:

```text
/home/xertrov/.local/bin/codex --xml-input-fd 3 resume --last
python3 /home/xertrov/src/c2c/c2c_deliver_inbox.py --client codex \
  --session-id lyra-perm-probe --loop \
  --broker-root /home/xertrov/src/c2c/.git/c2c/mcp \
  --xml-output-fd 4 --pid <codex-pid>
```

`/proc/<codex-pid>/fd` confirmed fd `3` was the XML input pipe. Fds `6` and `7`
were normal Codex runtime fds (`eventpoll`/`eventfd`), not c2c-owned sideband
event/response pipes. `/proc/<deliver-pid>/fd` showed fd `4` was the writer for
the same XML pipe. There were no instance files such as `bridge-events.fifo` or
`bridge-responses.fifo`.

I then prompted the live Codex pane to run `ls /root`. The Codex log recorded
`codex.op="exec_approval"` operations around approval-gated command handling, so
the approval machinery was active inside Codex. However, because the interactive
Codex process was not launched with server-request sideband fds, there was no
c2c event stream for `c2c_deliver_inbox.py` to read and no response fifo to write.

## Observed divergence from OpenCode

OpenCode's working path has a plugin-level integration point that receives the
permission request, opens a pending reply, sends a c2c DM to supervisors, waits
for a reply, then returns the decision to the client.

Codex's current normal interactive path only has an XML input lane. That lane can
inject inbound c2c messages into Codex, but it does not expose approval requests
back to c2c. The only implemented Codex permission-forwarding lane is the
`codex-headless` bridge path.

## Root-cause hypothesis

The recurrence is not primarily a response-schema bug anymore. The schema fixes
for `PermissionsRequestApprovalResponse` are present in `c2c_deliver_inbox.py`.
The current root cause is wiring scope:

- `permissions_approval_request` forwarding is implemented for
  `codex-headless` via `codex-turn-start-bridge`.
- Normal `c2c start codex` launches the Codex TUI directly, and the Codex TUI
  help only advertises `--xml-input-fd`; it does not expose
  `--server-request-events-fd` or `--server-request-responses-fd`.
- Therefore normal interactive Codex approval events stay inside Codex's local
  approval flow and cannot be observed by the c2c deliver daemon.

## Fix sketch

There are two plausible fix paths:

1. **Preferred if product semantics allow it:** route managed `codex` through a
   bridge/app-server mode that supports `--server-request-events-fd` and
   `--server-request-responses-fd`, while preserving interactive TUI behavior.
   This would reuse the existing c2c deliver-daemon forwarding implementation.

2. **If direct TUI must remain:** add upstream Codex support for server request
   event/response sidebands on the interactive TUI binary, analogous to
   `codex-turn-start-bridge`. Then wire normal `codex` launch the same way as
   headless:
   - create event and response FIFOs;
   - pass `--server-request-events-fd 6` and
     `--server-request-responses-fd 7`;
   - pass `--event-fifo` and `--response-fifo` to `c2c_deliver_inbox.py`;
   - ensure all fd ownership follows the sideband guide.

Do not try to infer permission prompts from TUI text. That would be brittle,
client-version-dependent, and would not provide a reliable response channel back
to Codex.

## Verification gaps

- This probe confirmed the normal managed `codex` fd topology and showed approval
  handling happening internally (`exec_approval` in the Codex log), but did not
  capture a `permissions_approval_request` JSON line because the normal TUI was
  not launched with an event lane.
- A follow-up implementation should add a failing test that normal `codex`
  launch either wires request/response sidebands or explicitly reports that
  permission forwarding is unsupported for that mode.

