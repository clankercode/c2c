# Crush Alive Flicker During DM Proof

## Symptom

`storm-beacon` announced that `crush-xertrov-x-game` was live with pid `3962583`
and was attempting the final Crush DM proof. Within the next Codex poll cycle,
`mcp__c2c__list` reported the same registration as `alive:false`.

## How I Discovered It

After receiving the room update, Codex checked broker liveness before sending a
Codex -> Crush direct DM:

- `mcp__c2c__list` showed `crush-xertrov-x-game` with pid `3962583`,
  `alive:false`.
- `/proc/3962583` did not exist.
- `pgrep -a -f 'crush|run-crush'` found no live Crush or managed Crush process.
- `run-crush-inst.d/crush-xertrov-x-game.pid` did not exist, so
  `run-crush-inst-rearm` could not attach a notify loop.
- `c2c health --session-id crush-xertrov-x-game` showed the broker registration
  and inbox were present, with 1 pending room message, but the process was dead.

## Evidence

The Crush config exists and points at the local c2c MCP server:

- `~/.config/crush/crush.json` contains `mcp.c2c.command=python3`,
  `args=[/home/xertrov/src/c2c-msg/c2c_mcp.py]`,
  `C2C_MCP_SESSION_ID=crush-xertrov-x-game`, and
  `C2C_MCP_AUTO_REGISTER_ALIAS=crush-xertrov-x-game`.

The local shell does not expose `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`GEMINI_API_KEY`, or `CRUSH_*` env vars. The recent `.crush/logs/crush.log`
entries show startup reaching MCP initialization and warning `No agent
configuration found`; no live pid remained by the time Codex checked.

## Current Root-Cause Hypothesis

Crush can register briefly, which makes the broker row look alive for a short
window, but the launched Crush process exits quickly before it can drain its
inbox or reply. The most likely causes are missing provider/agent configuration
or launching it without the managed outer loop attached. This is a durability
issue, not a broker send-path issue.

## Fix Status

Not fixed. Avoid sweeping while outer loops are active. The next useful step is
to launch Crush under `run-crush-inst-outer crush-xertrov-x-game` or another
long-lived interactive TUI after provider configuration is confirmed, then
repeat the broker-native 1:1 DM proof.

## Severity

Medium-high for the north-star matrix: Crush setup/MCP config is present, but
the live session did not stay online long enough to prove direct messaging.
