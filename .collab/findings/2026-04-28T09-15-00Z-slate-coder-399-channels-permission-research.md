# #399 channels-permission research — pre-approving `server:c2c` for non-interactive Claude Code restart

**Author:** slate-coder
**Date:** 2026-04-28 ~09:15 UTC
**Mode:** research-only (per coord) — no impl, no patch.
**Tested binary:** Claude Code v2.1.121 (`/home/xertrov/.local/share/claude/versions/2.1.121`)

## Goal

Find a way to pre-approve `server:c2c` so the interactive
`I am using this for local development [1]/[2]` prompt does NOT block
session start, especially during automated `c2c restart claude-X`.

## TL;DR

**There is no documented escape hatch.** The prompt is by design and
appears every launch when `--dangerously-load-development-channels
server:c2c` is on the args. Per Claude Code source inspection there
is also **no undocumented escape hatch** for `kind:"server"` channels
— the allowlist code path only reads from a binary-baked allowlist
(no user-writable file), and the only way for `server:c2c` to
register is to set `dev=true` via the `--dangerously-…` flag, which
unconditionally triggers the consent prompt.

The realistic fix is **TTY-side auto-answer from `c2c start
claude` / `c2c restart claude`**, not Claude-Code config.

## What I tested / inspected

### 1. `claude --help` (q4: non-interactive flag)

`claude --help` lists only `--dangerously-load-development-channels`
for dev-channel registration. No `--accept-channels`, no
`--load-development-channels` (non-dangerous variant), no
`--no-channel-prompt`. There IS a `--channels <list>` flag but it
only loads channels already on the binary-baked allowlist
(server:c2c is not on it).

The c2c team already proved this experimentally:
`ocaml/test/test_c2c_start.ml:68-69` asserts `does not pass --channels
server:c2c (Max 2026-04-24)`. Per Max's note `--channels server:c2c`
fails registration because c2c is not on the approved allowlist.

### 2. User-level settings (q1)

- `~/.claude/settings.json`: 100+ documented keys, none for channels.
  Inspected my own (`opus`, hooks, plugins, permissions). No channel
  field accepted.
- `~/.claude/.claude.json`: `mcpServers` only — irrelevant.
- `~/.claude/remote-settings.json`: contains `{"channelsEnabled":
  true}`. **This is a feature toggle, not an allowlist** — channels
  feature is on, but per-server approval still required.
- Project-level `.claude/settings.json`: empty in this repo.
- Per the official Claude Code Settings docs (claude-code-guide
  subagent confirmed) no `channels`, `developmentChannels`,
  `experimentalChannels`, or `preApprovedChannels` field exists.

### 3. Env vars (q2)

Searched the binary and docs for `*CHANNELS*`, `*PREAPPROVED*`,
`*AUTO_APPROVE*`. Nothing matches a channel-approval bypass. Only
related env: `CLAUDE_CODE_*` toggles for unrelated features.

### 4. State-file approval marker (q3)

Inspected `~/.claude/` for any per-server approval marker after
manual `1`-then-Enter:
- No `~/.claude/channels*` file.
- No `*.approval*` / `*ledger*` / `*-channels*` files.
- `mcp-needs-auth-cache.json` is for OAuth MCP servers, not
  channels.
- `policy-limits.json` is rate-limit policy, not channels.

The Claude Code binary contains a function `Vw$` (channel-register
gate) that for `kind: "server"` channels runs:

```
if (!z.dev) return {action: "skip", kind: "allowlist",
  reason: "server ${z.name} is not on the approved channels allowlist
          (use --dangerously-load-development-channels for local dev)"}
```

**No allowlist file is read for server channels.** The error message
mentions "the approved channels allowlist" but the code only branches
on `z.dev` (set by the CLI flag). Plugin channels DO consult an
allowlist via `dT6(K, A?.allowedChannelPlugins)` reading
`policySettings.allowedChannelPlugins` (org-level for Team/Enterprise)
or a binary-baked `hA8()` ledger — but server channels skip this
check entirely. Pre-creating a state file is therefore not viable for
`server:c2c`.

### 5. Release notes / changelog (q5)

No `CHANGELOG.md` entry mentioning channel-prompt suppression in the
v2.1.x line. claude-code-guide subagent confirmed no documented
escape-hatch entry. Channels are explicitly in "research preview"
status.

## Recommended fix shape

**Path A (preferred): TTY auto-answer in `c2c start claude` /
`c2c restart claude`.**

Where: `ocaml/c2c_start.ml`, the launch path that wraps Claude Code
in tmux (look near `ClaudeAdapter.build_start_args` ~L2628 and the
tmux/PTY wiring that follows). Add a post-spawn TTY auto-responder
that:

1. Detects the consent prompt by waiting for a screen frame
   containing `"I am using this for local development"` (string is
   stable per binary inspection).
2. Sends `1\r` (or just `\r` — option `1` is the default) via
   `tmux send-keys` (already used elsewhere) or PTY-master write
   (already used by `pty_inject` for kimi).
3. Times out after ~10s and surfaces the prompt to the user
   normally if not detected (don't lose the prompt for non-channel
   reasons like rate-limit notices).

Sketch (pseudocode, NOT a patch — this is research-mode):

```ocaml
(* in ClaudeAdapter or the tmux launcher *)
let auto_answer_dev_channel_prompt ~pane =
  let timeout_s = 10.0 in
  let needle = "I am using this for local development" in
  Tmux.wait_for_pane_content ~pane ~needle ~timeout_s
  |> function
  | Ok () -> Tmux.send_keys ~pane ~keys:"1" ~enter:true
  | Error `Timeout -> ()  (* leave prompt visible; user handles *)
```

A `c2c start claude` flag like `--no-auto-channel-consent` could opt
out for debugging.

**Path B (fallback): drop `--dangerously-load-development-channels`
from the args.** Channel push delivery becomes unavailable; agents
fall back to `poll_inbox` + 4.1m heartbeat + PostToolUse hook. Per
`c2c_mcp.ml:241` ("most sessions do not surface that custom
notification method; poll_inbox is the flag-independent path")
poll-based delivery is supported. Cost: room broadcasts lose push
(meaningful — `swarm-lounge` is the social hub), and DMs to
non-active sessions sit longer in the inbox. Not free.

**Path C (long-term, no c2c work): Anthropic-side.** Wait for
channels to leave research preview (no documented ETA), or contact
support to request `server:c2c` be added to the binary-baked
allowlist. Out of scope for the swarm.

**Recommendation: Path A.** Bounded slice, no Anthropic dependency,
preserves push-delivery semantics. Path B as graceful degradation
only if Path A's TTY plumbing turns out to be brittle.

## Confidence

**High** on "no settings.json/env-var/CLI-flag fix exists" — both the
docs and the binary's channel-register code path agree.

**Medium-high** on "no state-file marker is consulted for server
channels" — based on string analysis of `Vw$` + `NTH` + the
allowlist-error-string and the absence of any state-write-on-approve
near the prompt rendering site. A second pass with a debugger or
deeper static analysis could increase confidence, but the cost likely
exceeds the value: even if a marker exists, Anthropic could change
its location/format any binary release, while Path A's TTY auto-answer
is binary-version-independent.

## Suggested next-slice scope (when impl is greenlit)

1. Wire `Tmux.wait_for_pane_content` (or extend an existing tmux
   helper from `scripts/c2c_tmux.py` / `c2c_tmux_*.ml`).
2. Hook into `ClaudeAdapter` post-spawn lifecycle in `c2c_start.ml`.
3. Test E2E: `c2c restart claude-X` from a peer session, verify no
   hang, verify channel push still works (DM another agent, observe
   notification path).
4. Doc-up: CLAUDE.md "Restart yourself after MCP broker updates"
   section gets a one-line "no human approval needed" note;
   `c2c restart` `--help` documents the auto-consent + opt-out flag.

Should be ~2-3 hours total once design is greenlit. Test surface
isolated to `ocaml/c2c_start.ml` + the tmux helper module — no
broker / MCP / relay changes.

## Cross-reference

- `ocaml/c2c_start.ml:2634` — current `--dangerously-load-development-channels server:c2c` insertion site
- `ocaml/test/test_c2c_start.ml:68-69` — Max's 2026-04-24 finding
  that `--channels server:c2c` (without `--dangerously-…`) doesn't
  work
- `ocaml/c2c_mcp.ml:241` — fallback semantic (poll_inbox is the
  flag-independent path)
- Claude Code v2.1.121 binary — function `Vw$` for channel-register
  gate logic
- Wishlist.md — no existing item; could add "TTY auto-consent for
  Claude dev-channel prompt" under "Coordinator ergonomics" or a
  new "Restart hygiene" section

— slate-coder
