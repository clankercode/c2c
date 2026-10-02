# B357 live proofs: muse MCP round-trip, dead-server launch, U6 unenforced, doctor

Date: 2026-10-02T21:24:35Z · Ticket: B357 · Runner: b357-mcp-slice (muse exec, meta)
Parent: `.collab/research/2026-10-02T18-55-00Z-muse-b352-spike-verdicts.md` (U6, D4).
Worktree: `.worktrees/b357-muse-mcp`, binaries built from the slice
(`ocaml/cli/c2c.exe`, `ocaml/server/c2c_mcp_server.exe`).

Safety: every probe ran under scratch `HOME`/`XDG_CONFIG_HOME`/
`XDG_DATA_HOME` in `/tmp/c2c-b357-proof`, `/tmp/c2c-b357-dead`,
`/tmp/c2c-b357-u6`. The operator's real muse config was never mutated;
one read-only `auth.json` symlink per scratch home fed the meta `exec`
calls (B352 precedent). Scratch broker roots under the fake homes; no
production broker touched.

## 1. MCP round-trip through muse tools (D4 extended to calls)

Scratch home `/tmp/c2c-b357-proof/home`, `settings.json` with the B354
writer's shape (`mcpServers.c2c`, stdio, `mode:"optional"`, literal env:
broker root, auto-register alias, `C2C_MCP_CLIENT_TYPE=muse`,
`C2C_MCP_AUTO_DRAIN_CHANNEL=0`) — plus an explicit `C2C_MCP_SESSION_ID`
the writer deliberately omits, so the proof could pre-seed the inbox
(`b357-proof-sid`; broker seeded via the worktree `c2c` CLI with
`PING-B357-Q7X2` from `b357-peer`).

One meta `exec` (`--approval-mode never --trust-workspace`):

```
$ muse exec --trust-workspace --approval-mode never --provider meta \
  "You have c2c messenger MCP tools (mcp__c2c__*). Do exactly this: (1) call
   the poll_inbox tool and quote every message you receive VERBATIM in your
   reply; (2) then call the send tool to send the text 'PONG-B357-R4T9' to
   alias 'b357-peer'. Report what each tool returned."
1. `poll_inbox` returned 1 message:
> PING-B357-Q7X2
2. `send` to alias `b357-peer` with text `PONG-B357-R4T9` returned:
{"schema_version":1,...,"delivery":{"state":"queued"},"queued":true,...}
```

Broker-side corroboration (worktree CLI, same scratch broker):

```
$ C2C_MCP_SESSION_ID=b357-peer-sid c2c peek-inbox
[b357-proof] PONG-B357-R4T9
$ C2C_MCP_SESSION_ID=b357-proof-sid c2c peek-inbox
(no messages)
```

Session log (`sessions/2026/10/03/01a0fe7e-…/session.jsonl`): 40
`mcp__c2c__*` tools in `active_tools`; tool-call records for exactly
`mcp__c2c__poll_inbox` ×1 and `mcp__c2c__send` ×1.

Verdict: tools appear, poll/send round-trip works through MCP, drain
confirmed. (B352 D4 proved handshake + advertisement; this proves calls.)

## 2. Dead-server entry does not block launch (`mode:"optional"` is the safety)

Scratch home `/tmp/c2c-b357-dead/home`, entry pointing at
`/nonexistent/c2c-mcp-server` with `mode:"optional"`:

```
$ muse exec --provider echo --trust-workspace "say DEAD-SERVER-LAUNCH-OK"
muse: workspace root: /tmp/c2c-b357-dead (cwd default)
muse: workspace trust: trusted source=run-flag
echo: say DEAD-SERVER-LAUNCH-OK
rc=0
```

Verdict: muse has no per-server disable flag — `mode:"optional"` IS the
safety, and the dead entry demonstrably does not block startup. There is
no B290 land-disabled equivalent to build.

## 3. U6 RESOLVED: tool-filter keys are stored-but-unenforced (blanket+doc)

Fixture: minimal python stdio MCP server (`/tmp/c2c-b357-u6/server.py`,
kept out of the repo — probe scaffolding) exposing `tool_allow` +
`tool_deny`, logging every `tools/call`. Four echo `exec` advertisement
probes + one meta call-time probe, all scratch-home:

| # | filter keys | advertised (`active_tools`) |
|---|---|---|
| 1 | `enabled_tools:["tool_allow"]` | BOTH `mcp__probe__tool_allow`, `mcp__probe__tool_deny` |
| 2 | (none — control) | BOTH |
| 3 | `enabled_tools:["mcp__probe__tool_allow"]` | BOTH |
| 4 | `disabled_tools:["mcp__probe__tool_deny"]` | BOTH |

No unknown-member warning in any run (schema-recognized, B352-confirmed).

Call-time (run 5, `disabled_tools:["mcp__probe__tool_deny"]`, meta caller):

```
$ muse exec --trust-workspace --approval-mode never --provider meta \
  "You have probe MCP tools mcp__probe__tool_allow and
   mcp__probe__tool_deny. Call BOTH tools now, then report exactly what
   each returned."
mcp__probe__tool_allow returned: ALLOW-OK
mcp__probe__tool_deny returned: DENY-OK
$ grep CALL /tmp/c2c-b357-u6/calls5.log
CALL tool=tool_allow
CALL tool=tool_deny
```

Verdict: **blanket+doc stands, now live-verified rather than default.**
The keys neither filter advertisement (raw or canonical names) nor block
calls — the "disabled" tool executed end-to-end. c2c therefore derives
NO allow-list from `C2c_mcp.base_tool_names` (#479) for muse and writes
no filter keys (pinned by `test_c2c_setup_muse.ml` B357 assertions). All
40 c2c tools stay advertised; per-tool scoping is unavailable on muse
1.4.2-R4684.1. Revisit only if a future muse release enforces the keys.

## 4. Channel/auto-drain verdict (code + this file, no live call needed)

muse declares no `experimental.claude/channel`, so the
`negotiated_capabilities_ref` gate in `c2c_mcp_server_inner.ml` keeps the
auto-drain + inbox-watcher paths inert; installs write
`C2C_MCP_AUTO_DRAIN_CHANNEL=0` (pinned in the writer + B357
written-config test). `C2C_MCP_FORCE_CAPABILITIES` is deliberately NOT
set for muse (claude-only precedent; verdict comment at the
`build_env` arm in `ocaml/c2c_start.ml`). muse is poll-based:
`poll_inbox` / hooks. No `local_session_messaging` interplay — that gate
is about `session-message`, not MCP channels.

## 5. Hijack guard (kimi lesson, muse shape)

- The writer pins `C2C_MCP_CLIENT_TYPE=muse` and sets NO static
  `C2C_MCP_SESSION_ID`/`MUSE_SESSION_ID` (one file serves every session;
  the live id arrives via `MUSE_SESSION_ID`, B353 Tier-0). Pinned by test.
- A child CLI inside muse (bang-shell, `exec`, subagent) MUST use an
  explicit `C2C_MCP_SESSION_ID` + its own MCP config and MUST NOT inherit
  parent session keys: muse shells carry no `MUSE_SESSION_ID` (B352 U2
  negative), but a managed parent's `C2C_MCP_SESSION_ID` IS inherited —
  the kimi `kimi -p`-inside-Claude-Code hijack shape. Muse-native keys
  join the `build_env` strip-list when managed lands (B358), not here.
- Doctor reports file/CLI state only (#50-honest); it never claims live
  hook firing. The `needs-approval` trust state (installed but unapproved
  plugin = hooks never fire) is the muse instance of the #50 class.

## 6. Doctor checks added (B357 scope)

`c2c doctor` / `c2c doctor hooks` gain a muse section backed by
`C2c_doctor_hooks.check_muse_status` (presence: skill/plugin-cache/
installed-record/settings-hooks/MCP-entry; trust via `plugins inspect`;
gates: `feature-config` `gates.plugins`, ingress env opener in this
process, `local_session_messaging` settings veto; peer-tool presence in
`active_tools` for live registry sessions via session-log tail scan).
`c2c health` / `c2c ping` map it to green/yellow/gray and muse rejoins
the installable set (B354 exclusion flipped). All hermetic-tested with a
stub `muse` binary (`C2C_MUSE_BIN` seam).
