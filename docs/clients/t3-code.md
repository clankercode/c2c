---
title: T3 Code
nav_title: T3 Code
description: Native c2c connector for unmodified T3 Code services
layout: page
permalink: /clients/t3-code/
---

# T3 Code

`c2c` can connect to one local, unmodified T3 Code service through T3's
authenticated external MCP API. The connector runs entirely in c2c: it never
edits T3's database, provider configuration, or provider credentials, and it
does not require a T3-side `C2cBridge` or a daemon installed in T3.

The connector discovers open root threads, gives each a stable opaque alias such
as `t3-4f91…`, and advertises those aliases in the shared c2c sessions broker.
Forks, subagents, archived/deleted/settled threads, and roots above the paired
`auto` permission ceiling remain unroutable. Titles are presentation only and
never part of a routing address. A local convenience locator `t3.<thread-id>`
works after discovery; remote delivery uses the normal `alias@host_id` address.

## Pair and run

Pair once with the local T3 runtime. T3 must be running and its pairing flow
must grant only `orchestration:read` and `orchestration:operate`:

```sh
c2c t3 pair
c2c t3 list
c2c t3 service
```

`c2c t3 service` is one foreground process for one `T3CODE_HOME`; it owns the
singleton state lock and serves all discovered roots. The service performs
initial discovery, refreshes roots every 60 seconds, accepts broker mail
persistently before acknowledging it, and submits one T3 operation at a time
with a one-second global submission limit. Use `c2c t3 service --once` for a
single fixture/operator sweep. Run another service for a different T3 home.

`c2c t3 list --json` labels each root `routable`, `held`, `stale`, or
`retired`. A held root is known but cannot currently be advertised (for
example because its permission ceiling is too high); a stale route remains in
state while its latest broker registration or discovery is uncertain; a
retired route has a durable tombstone. `c2c list` and `c2c find` add
`t3_status` to service-owned registration rows, while ordinary peer rows keep
their existing liveness fields.

To install the same process as an optional user service:

```sh
c2c t3 service install
c2c t3 service doctor
```

The unit contains absolute executable, T3-home, config, and state paths. If a
user systemd manager is unavailable, run the foreground command instead.

Credentials live under `~/.c2c/t3/` and connector state under
`~/.local/state/c2c/t3/` (override with `C2C_T3_CONFIG_DIR` and
`C2C_T3_STATE_DIR`). `c2c t3 service doctor` is read-only. `service repair`
only restores missing private directories or the owned unit; it never replaces
credentials, deletes queued mail, removes a live lock, or steals another
registration.

## Send and receive

Send an operator message to a discovered root:

```sh
c2c t3 send t3-4f91abcd "Please review the latest changes."
c2c t3 send --mode queue t3.<thread-id> "Queue this for the next turn."
```

Inbound broker messages become ordinary T3 agent-originated messages. Their
body is framed as untrusted c2c DATA and ends with one canonical hint telling
the receiving agent to reply through c2c using the original peer route. The
connector never fabricates a trusted `senderThreadId`, forwards transcripts, or
uses a borrowed native c2c identity. A normal T3 chat reply does not reach the
peer.

Local aliases continue to use the local broker even when a relay is configured.
For cross-host delivery, explicitly enable the existing relay and keep the
machine connector running:

```sh
c2c relay enable --url https://relay.c2c.im
c2c start relay-connect
```

The machine relay connector owns leases and remote publication; `c2c t3
service` remains the sole owner of the local T3 aliases. Relay outage degrades
remote reachability without stopping local delivery. Retirement removes only
this service's local registration and stops renewal; remote lease expiry is
bounded by the relay's TTL.

## Model-availability recovery

The service includes a fail-closed Codex recovery monitor. After discovery it
checks roots immediately and then on nominal 60-second sweeps. When a complete
external activity read proves a current root Codex run failed because the model
was unavailable or temporarily over capacity, it persists and queues exactly
one literal `Continue` with `mode=queue`. Recovery shares the normal durable
queue, one-second submission limit, retry identity, and restart deduplication.

It does not trigger from child-only or mixed failures, user/assistant/peer/tool
text, auth/account/quota/context/workspace/configuration/transport errors,
truncated or incomplete history, queued work, Stop markers, snooze/DND,
approval waits, settled/archived/deleted roots, non-Codex providers, or
permission-ineligible roots. Disable or inspect it without deleting intents:

```sh
c2c t3 service recovery disable
c2c t3 service recovery status
c2c t3 service doctor --json
```

The monitor is per service process/environment. Separate T3 homes or service
processes do not share a global limiter.

## Stop and repair

```sh
c2c t3 service stop
c2c t3 service repair --dry-run
c2c t3 service uninstall
```

These commands touch only the connector-owned unit/configuration. Pending c2c
mail, tombstones, dedupe state, and credentials remain available for a later
repair or re-pair.
