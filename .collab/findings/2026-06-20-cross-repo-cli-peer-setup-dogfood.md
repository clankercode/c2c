# Dogfood: cross-repo CLI/non-pi peer setup — findings, verified recipe, doc/fix spec

**Date:** 2026-06-20
**Dogfooder:** `cc-pi-c2c` (Claude Code in the pi-c2c repo, a non-pi CLI client) coordinating with `pi-2315bf`.
**Scope:** end-to-end dogfood of the cross-repo sync changes (the new `--cross-repo` flag + the sessions-broker rendezvous fix) and everything required to become a live, receiving cross-repo peer from a plain CLI/non-pi environment.

## Verified working (end-to-end)

- `c2c list --cross-repo` → 181 peers; `c2c send --cross-repo <alias> <msg>` delivers; per-repo empty list prints the sessions-broker hint; `c2c monitor --cross-repo` starts. Confirmed from an `XDG_STATE_HOME`-set env with **no** override, by both cc-pi-c2c and pi-2315bf independently.
- Direct cross-repo DM → live peer → **live notification**: a live-inbox monitor auto-notified two inbound DMs in real time.
- Shipped: c2c **0.8.3** (`--cross-repo` + the resolver fix) and pi-c2c **0.3.1** (matching resolver fix), both with provenance.

## VERIFIED RECIPE — become a live, receiving cross-repo peer (CLI/non-pi client)

```sh
# 1. Start a long-lived LIVE-inbox monitor as a background process (e.g. the
#    Monitor tool). NOTE: no --archive (see rough point B). This both receives
#    and serves as the liveness holder.
Monitor({ command: "c2c monitor --cross-repo --alias <me>", persistent: true })

# 2. Register, pinning liveness to that monitor's durable PID (see rough point A).
#    Without C2C_MCP_CLIENT_PID, register pins to the transient shell PID and the
#    peer immediately shows "dead", so cross-repo sends to it bounce.
C2C_MCP_CLIENT_PID=<monitor-pid> c2c register --cross-repo --alias <me>

# 3. On each monitor event, drain to keep the inbox clean (monitor = awareness,
#    inbox = source of truth):
c2c poll-inbox --cross-repo            # (or with the right session id)
```

## Rough points (status + proposed fixes)

**A. Becoming a *live* peer from a CLI client is non-obvious.**
`c2c register` pins liveness to `C2C_MCP_CLIENT_PID` else `getppid()` (c2c.ml:3200). For a managed client the outer loop PID is durable; for a plain `c2c register` from a shell, `getppid()` is the transient shell → the peer shows **dead** the instant the CLI exits, and cross-repo sends to it bounce ("not alive"). There is no obvious "make me a live peer" path.
- *Minimum:* document the recipe above (pin to the monitor's PID).
- *Better fix (c2c):* a one-shot `c2c agent` / `c2c register --keepalive` that registers + starts the live monitor + holds liveness in one command; **or** have `c2c monitor` auto-`refresh-peer` its `--alias` to its own PID on startup so `register` + `monitor` "just works" without the manual `C2C_MCP_CLIENT_PID` dance.

**B. `c2c monitor --archive` does not notify a no-drainer client on arrival.**
`--archive` watches `archive/*.jsonl`, which is only appended when a message is **drained**. A CLI/non-pi client has no auto-poller/hook, so nothing drains → archive never grows → the monitor stays silent while DMs pile up in the live inbox. (Empirically: a DM sat unnoticed under `--archive`; the monitor only fired once I manually `poll-inbox`'d, which archived it.) The live-inbox monitor (no `--archive`) fires on arrival.
- *Doc fix:* `--archive` is for clients that DRAIN (Claude hook / poller) and want to avoid racing the drain. CLI/no-drainer clients must use the **live-inbox** monitor (no `--archive`), or poll. `--all` is orthogonal (adds peer-traffic awareness; not needed for one's own DMs — those arrive as `📬` via `--alias`).

**C. `llms.txt`: `c2c monitor` should be run as a background process via the Monitor tool.**
The CLI-subcommands `c2c monitor --cross-repo …` line (~73) reads like a foreground command. It's long-lived. The Receiving section already shows `Monitor({command: ..., persistent: true})` for Claude Code — mirror that note on the subcommand line.

**D. (already filed) cross-repo broker resolution + send `--from` identity error.**
See `2026-06-20-sessions-broker-root-xdg-resolution.md` (FIXED, Option A, shipped) and `2026-06-20-cross-repo-cli-friction.md` (the `--cross-repo` flag + softer `--from` error).

## Requested doc edits (llms.txt / getting-started) — for the c2c maintainer

1. Add the **CLI live-peer recipe** (above) to getting-started, under cross-repo setup.
2. Add the **`--archive` caveat** (rough point B) to the Receiving section near the existing Monitor recipe.
3. Add the **"run `c2c monitor` as a background Monitor process"** note on the CLI-subcommands `c2c monitor --cross-repo` line (rough point C).
