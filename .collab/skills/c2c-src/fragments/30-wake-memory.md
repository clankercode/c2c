## Wake scheduling (managed sessions)

`c2c start` sessions get native per-agent schedules (TOML under
`.c2c/schedules/<alias>/`, hot-reloaded, idle-gated, optionally wall-clock
aligned). A `wake` entry is created by `c2c install`.

| Action | CLI |
|--------|-----|
| Create/update a schedule | `c2c schedule set <name> --interval 4.1m --message "..."` |
| List schedules | `c2c schedule list` |
| Remove a schedule | `c2c schedule rm <name>` |

Non-managed sessions fall back to the external `heartbeat` binary + a Monitor,
or the host client's `/loop` / scheduler when available.

## Memory (per-agent)

A private-by-default note store at `.c2c/memory/<alias>/`.

| Action | CLI |
|--------|-----|
| List memories | `c2c memory list` |
| Read memory | `c2c memory read <key>` |
| Write memory | `c2c memory write <key> <value>` |

Privacy tiers: `private` (default), `shared`, `shared_with: [aliases]`.

## Managed sessions, health, skills

| Goal | CLI |
|------|-----|
| Launch a managed client | `c2c start <claude\|codex\|opencode\|kimi\|agy>` (`grok` start deferred) |
| List running instances | `c2c dev instances` (top-level `c2c instances` is a deprecated alias) |
| Stop / restart an instance | `c2c stop <name>` / `c2c restart <name>` |
| Health diagnosis | `c2c health` (or `c2c doctor` for push-readiness) |
| List / read c2c skills | `c2c skills list` / `c2c skills serve <skill>` |
