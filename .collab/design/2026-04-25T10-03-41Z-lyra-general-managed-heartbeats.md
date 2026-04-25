# General Managed Heartbeats

**Author:** lyra-quill  
**Date:** 2026-04-25T10:03:41Z  
**Status:** design-ready-for-implementation  
**Base:** Codex heartbeat transport merged by coordinator at `b53a010` + `384e9ee` from original `5bfb1a7` + `b417e1f`.

## Goal

Generalize the proven Codex broker-inbox heartbeat into a configurable managed-session heartbeat system for coding CLIs. A heartbeat is a normal c2c inbox message sent from an agent alias to itself, so delivery follows the same client-specific inbound path as ordinary c2c traffic.

This replaces one hard-coded Codex timer with named heartbeat specs that can be configured globally, overridden by role files, and extended per agent.

## Requirements

- Default heartbeat for managed coding CLIs: every 4 minutes with a configurable default message.
- Role-level override from `.c2c/roles/*.md`.
- Multiple named heartbeats per agent, each with a stable ID.
- Selective disable by stable ID.
- Optional command output attached to a heartbeat.
- Coordinator-style heartbeats can run at different cadences:
  - hourly sitrep heartbeat.
  - 20-minute idle-team check heartbeat.
  - 15-minute quota heartbeat with command output.
- Wall-clock aligned schedules must be possible for sitrep-style heartbeats (`@1h+7m` semantics).
- Command execution is security-sensitive and must not be arbitrary by default.

## Config Layering

Resolution order is last-wins:

1. Built-in defaults.
2. `.c2c/config.toml` global defaults and named heartbeat specs.
3. Role file overrides from `.c2c/roles/<agent>.md`.
4. Per-agent override file, reserved for follow-up: `.c2c/agents/<name>/heartbeat.toml` or instance config extension.

The first implementation covers layers 1-3 in OCaml. Layer 4 is represented in the resolver API shape but not wired to a persisted file unless implementation time allows; the stable-ID model makes that addition straightforward.

## Schema

Global config:

```toml
[heartbeat]
enabled = true
interval = "4m"
message = "Session heartbeat. Poll your C2C inbox and handle any messages."
clients = ["claude", "codex", "opencode", "kimi", "crush"]
command_timeout = "30s"

[heartbeat.sitrep]
enabled = true
schedule = "@1h+7m"
message = "Sitrep heartbeat: gather swarm state and post the hourly status."
role_classes = ["coordinator"]

[heartbeat.idle_check]
interval = "20m"
message = "Idle-team check: find quiet or blocked agents and route work."
role_classes = ["coordinator"]

[heartbeat.quota]
interval = "15m"
message = "Quota report heartbeat."
command = "c2c quota"
role_classes = ["coordinator"]
```

Role frontmatter:

```yaml
c2c:
  heartbeat:
    message: "Role-specific default heartbeat."
    interval: 4m
  heartbeats:
    sitrep:
      schedule: "@1h+7m"
      message: "Coordinator sitrep."
    quota:
      interval: 15m
      command: "c2c quota"
```

Stable IDs are `default` for the base heartbeat and table names for named heartbeats (`sitrep`, `idle_check`, `quota`). Setting `enabled = false` for an ID disables that heartbeat at that layer.

## Command Execution Policy

Initial command heartbeats use an allowlist, not arbitrary shell by default:

- `c2c quota`
- `c2c history`
- `c2c list`
- `c2c doctor`
- `c2c instances`

Commands outside the allowlist are skipped and the heartbeat message includes a short warning. This prevents role/config files from becoming a generic shell execution channel. A future explicit opt-in can broaden this if needed.

Command output is appended to the message body with a stable header:

```text
<configured heartbeat message>

[heartbeat:quota command output]
...
```

## Scheduling

Two schedule forms are supported:

- Relative interval: `4m`, `20m`, `1h`, `240s`.
- Wall-clock aligned interval: `@1h+7m`, meaning the next fire occurs at the next hour plus 7 minutes, then repeats hourly.

The scheduler computes the first sleep per spec:

- Interval specs sleep `interval_s` from launch before first send.
- Aligned specs compute the next wall-clock boundary strictly after `now`.

Tests cover parsing and next-fire calculation; live 4-minute timing is not practical in unit tests.

## Runtime Hook

The scheduler hooks in `C2c_start.run_outer_loop` after client delivery sidecars are started, at the same point where the Codex-specific heartbeat currently starts.

Transport remains `Broker.enqueue_message ~from_alias:alias ~to_alias:alias`, which is the proven path from the Codex heartbeat slice.

Default client policy:

- Included by default: `claude`, `codex`, `opencode`, `kimi`, `crush`.
- Excluded by default: `codex-headless`.
- Codex normal TUI requires `deliver_pid` present, preserving the reviewed safety gate.
- `codex-headless` can only be enabled by explicitly naming it in a spec’s `clients` list.

This gives Max the broad managed-CLI feature while preserving the `b417e1f` safety lessons.

## Tests

Add focused OCaml tests for:

- Duration parser: `45s`, `4m`, `2h`, invalid input.
- Global config reader: `[heartbeat]` and `[heartbeat.<id>]`.
- Role parser: `c2c.heartbeat.*` and `c2c.heartbeats.<id>.*`.
- Resolver layering: built-in default -> config -> role override, named heartbeat merge, selective disable.
- Client gates: default managed CLIs included, `codex-headless` excluded unless explicit, normal Codex requires deliver daemon.
- Command rendering: allowed command output appended, disallowed command skipped.
- Wall-clock next-fire calculation for `@1h+7m`.
- Broker inbox enqueue path remains from alias to same alias and non-deferrable.

## Open Follow-up

- Persisted per-agent override file is designed but may land as a follow-up if the first slice is large enough already.
- GUI should later expose heartbeats as named toggles by stable ID.
