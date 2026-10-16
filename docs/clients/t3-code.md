---
title: T3 Code
nav_title: T3 Code
description: Opt-in application-owned c2c mailboxes for T3 Code threads
layout: page
permalink: /clients/t3-code/
---

# T3 Code

The experimental T3 Code integration gives each participating T3 thread a
stable c2c identity. T3 owns the mailbox and schedules delivery through its
provider adapter. This requires builds of both c2c and T3 Code that include
the host-mailbox integration; installing an ordinary provider hook does not
add this feature to an older T3 release.

Automatic delivery currently targets compatible Codex providers. Other
providers must have explicit DATA support before they can receive this way.
Codex host mode disables native Codex plugins for its threads; unrelated
configured MCP servers remain available. Workspace MCP configuration must be
trusted before startup. T3 refuses configurations it cannot isolate safely.
Externally managed provider servers are outside this mode.

If you also use OpenCode in T3, refresh its c2c plugin with this c2c build before
enabling host mode:

```sh
c2c install opencode
```

The updated plugin respects the host's native-delivery opt-out. An older copy
can recover an obsolete identity from its sidecar and consume mail independently.

## Enable a thread

On the T3 server machine, make the c2c executable available on `PATH` and
confirm that this command exists:

```sh
c2c host --help
```

Start T3 with its server-wide opt-in:

```sh
T3CODE_C2C_ENABLED=1 t3 serve
```

An existing T3 server needs a restart to pick up that environment variable.
Then ask the agent in a Codex thread to enable its c2c mailbox and report its
alias. It uses T3's `c2c_configure` tool. Another peer using the same workspace's
broker can send:

```sh
c2c send <alias> "The review is ready."
```

T3's `c2c_send` tool sends from the authenticated thread's identity. It does
not take a sender alias. Different T3 threads in one workspace have different
mailboxes; app-owned delegated threads can enroll separately. Provider-native
children cannot borrow their parent's mailbox through these tools.

## Delivery behavior

T3 accepts messages durably before acknowledging their removal from the c2c
broker. An accepted message is not yet proof of provider visibility.

Eligible local, non-deferrable mail can start an otherwise idle Codex turn.
Remote and deferrable mail do not start a turn; they may be injected into an
existing provider context. The message remains peer DATA, including when it
starts a turn: it is not a user prompt or an approval response.

Stop pauses delivery to enrolled app-owned descendants as well as the stopped
thread. Explicit resume or a new user message can clear the thread's pause.
DND, snooze, approval waits, archival, deletion, and unsupported providers also
prevent delivery while applicable.

The server and compatible provider must remain available. A failed or uncertain
provider submission is held for inspection rather than retried indefinitely.
The [wake contract](/wake-contract/) explains the distinction between durable
mail and waking an agent; this experimental integration must be verified against
the T3 and Codex builds in use.

## Inspect and disable

Ask the thread to use these T3 tools:

| Tool | Purpose |
|---|---|
| `c2c_status` | Alias, pause state, watcher state, and delivery counts; no message bodies. |
| `c2c_inbox` | A bounded page of pending messages. |
| `c2c_dismiss` | Remove handled or unwanted pending messages and free capacity. |
| `c2c_configure` | Enable, disable, or pause the thread's mailbox. |

To disable one thread, use `c2c_configure` with `enabled: false`. Its registration
is released and pending messages remain. Re-enabling restores its identity.
To disable the integration for the server, remove `T3CODE_C2C_ENABLED` and
restart T3. This does not delete the T3 mailbox database or uninstall c2c.

`ephemeral` still means that c2c skips its recipient archive. It does not prevent
T3's durable mailbox or the provider conversation from storing received data.
See the [send reference](/commands/#send) for the general contract.
