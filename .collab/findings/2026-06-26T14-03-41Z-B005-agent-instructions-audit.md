# B005 — Agent working-instructions + wake/delivery audit

**Bug:** B005 "confirm claude has good working instructions (monitor), also
codex (tool hooks?) or autostart in tmux"
**Type:** AUDIT (evidence + safe doc fixes + recommendations; no feature builds).
**Worktree:** `.worktrees/B005-agent-instr-audit` (branch `bug/B005-agent-instr-audit`).
All file:line refs are against this worktree's tree (≈ local master HEAD `2b8827c0`).

---

## TL;DR

- **Claude managed wake DOES work end-to-end** — not via an in-transcript
  Monitor, but via native scheduling delivered over the dev-channel push.
  The mental model in the bug title ("monitor") is the *fallback*, not the
  managed path.
- **Codex has no native tool hooks** (confirmed). Delivery is c2c's own
  sideband: a forked `c2c-deliver-inbox` daemon (inotify-preferred) + a
  codex heartbeat gated on the daemon starting. Kickoff is an XML pipe write.
- **tmux has NO declarative autostart / supervisor** — only imperative
  manual helpers (`launch`, `restart`, `wait-alive`). Confirmed.
- One genuine CLAUDE.md drift fixed (native-scheduling bullet attributed
  firing to the wrong thread for managed sessions).
- Three improve-half decisions need Max's steer (below). The most concrete
  is a **duplicate-wake**: the claude role onboarding preamble tells managed
  agents to arm a `heartbeat 4.1m` Monitor *on top of* the native 4.1m
  `wake.toml` — violating CLAUDE.md's own "dedupe before arming" rule.

---

## 1. Claude managed-session working instructions

### 1a. What intro a claude session receives

`default_kickoff_prompt` (`ocaml/cli/c2c.ml:9395`) renders
`C2c_start.swarm_config_restart_intro ()` →
`C2c_start.builtin_swarm_restart_intro` (`ocaml/c2c_start.ml:675`).
The builtin intro covers: reply via c2c_send, poll inbox *once*, `c2c list`,
post in lounge, "Read CLAUDE.md". It carries **no continuous wake / stay-alive
guidance and no Monitor instruction.**

Kickoff resolution (`ocaml/cli/c2c.ml:9733-9932`) has two families:

- **Role-based** (explicit `--agent`, or auto-inferred `.c2c/roles/<name>.md`
  / client-native role file): for `client = "claude"` the kickoff is a
  **5-step `onboarding_preamble`** (`c2c.ml:9773-9788` and the duplicate at
  `9850-9865`), NOT the builtin intro. Step 5 is: *"Arm a heartbeat Monitor:
  use Monitor tool with command `heartbeat 4.1m "<wake message>"`,
  persistent:true."*
- **No-role / render-fail fallthrough** (`c2c.ml:9883-9932`): kickoff =
  explicit `--kickoff-prompt` text, else (`--auto` → builtin intro), else
  (interactive role selected → builtin intro), else **`None`**.

So: a **plain `c2c start claude` with no role and no `--auto`** that declines
the interactive role prompt gets **no intro at all**; if it picks a role it
gets the builtin intro (no wake guidance). Only the *role-based* path gives
claude the Monitor-arming preamble.

### 1b. Does the managed claude session actually get woken? — YES (verified)

The bug title's "(monitor)" implies the wake is an in-transcript Monitor. For
**managed** claude that is not how it works; the real path is:

1. `c2c install claude` auto-creates `wake.toml`
   (`ensure_default_wake_schedule`, `ocaml/cli/c2c_setup.ml:1561-1598`, called
   at `:1652-1653`): `interval_s=246` (4.1m), `only_when_idle=true`,
   `idle_threshold_s=246`.
2. `c2c start claude` launches the binary with
   `--dangerously-load-development-channels server:c2c`
   (**unconditional** in `ClaudeAdapter.build_start_args`,
   `ocaml/c2c_start.ml:3534-3535`).
3. Managed env (`ocaml/c2c_start.ml:2967-3008`): `C2C_MCP_AUTO_DRAIN_CHANNEL=0`
   (no silent drain), `C2C_MCP_CHANNEL_DELIVERY=1`, and for claude
   `C2C_MCP_FORCE_CAPABILITIES=claude_channel` — *"force claude_channel
   capability so channel-push works without requiring the client to advertise
   experimental.claude/channel in its initialize request."* Plus
   `C2C_MCP_SCHEDULE_TIMER=1`.
4. Firing: the **inner MCP server's Lwt schedule timer** (S6c) reads
   `.c2c/schedules/<alias>/*.toml` and fires due schedules as **self-DMs**
   (`enqueue_heartbeat` → `Broker.enqueue_message ~from_alias:alias
   ~to_alias:alias`, `ocaml/c2c_schedule_fire.ml:23-26`). The parent
   `c2c start` **skips** its own `start_schedule_watcher` thread when
   `mcp_schedule_timer_active ()` (i.e. `C2C_MCP_SCHEDULE_TIMER=1`, the managed
   default) — `ocaml/c2c_start.ml:5044-5056` — so there is no double-fire.
5. The self-DM is channel-pushed to claude (which is running with the
   dev-channels flag), surfacing it into the transcript and waking the agent.

**Conclusion:** managed claude wake works *by design* without any
in-transcript Monitor. The Monitor/heartbeat path is the **non-managed**
fallback (raw `claude` not started via `c2c start`), per
`.collab/runbooks/agent-wake-setup.md` Options 0/0b/2 — which the runbook
documents accurately.

### 1c. PASS / GAP for claude

- PASS: managed wake delivery is real and de-duplicated at the
  scheduler level; the runbook (`agent-wake-setup.md`) is accurate.
- PASS: idle-gating (`should_fire_heartbeat`, `ocaml/c2c_start.ml:302-311`)
  skips ticks when the agent was active within `idle_threshold_s`.
- GAP (duplicate wake): role onboarding preamble step 5 arms a `heartbeat
  4.1m` Monitor **in addition to** the native 4.1m `wake.toml`. For a managed
  session that is two wake cadences at the same interval — exactly what
  CLAUDE.md "Dedupe before arming" warns against. (`c2c.ml:9781-9783`,
  `9858-9860` vs `c2c_setup.ml:1574`.)
- GAP (no-intro plain start): plain `c2c start claude` with no role / no
  `--auto` can hand the agent **no intro**, so it relies entirely on the
  first wake self-DM (whose body is self-describing) + the agent reading
  CLAUDE.md. Acceptable but not robust.
- DRIFT (fixed in this branch): CLAUDE.md "Native scheduling (S1-S5)" bullet
  attributed firing to "a stat-poll watcher thread in `c2c start`" — but for
  managed sessions (the only sessions it applies to) that thread is skipped
  in favour of the inner MCP Lwt timer (S6c).

---

## 2. Codex — "(tool hooks?)"

**Codex has no native tool hooks.** The "start-hooks" written by
`setup_codex` are c2c's *own* shell hooks, not codex tool hooks. Delivery is
c2c's sideband machinery:

- **Deliver daemon:** `c2c start codex` forks `c2c-deliver-inbox`
  (`start_deliver_daemon`, `ocaml/c2c_start.ml:4017-4066`, called
  `:4914`) with `--xml-output-fd <fd4>` and `--inotify` (the latter when
  `inotifywait_available ()`, `ocaml/c2c_start.ml:3380-3382, 4025`). The
  daemon's stdout/stderr are duped to `/dev/null` (`:4049-4052`).
- **inotify is real:** `c2c-deliver-inbox` uses `inotifywait -m -e
  close_write,modify` (`ocaml/cli/c2c_deliver_inbox.ml:198`) with a polling
  fallback. So CLAUDE.md's "inotify-based inbox watcher (`c2c-deliver-inbox`)"
  is **accurate** (do not "fix" it).
- **XML sideband:** when delivery goes through the xml path,
  `C2c_pty_inject.xml_deliver_loop_daemon` writes
  `<message type="user" queue="AfterAnyItem">…</message>` frames to fd4
  (`ocaml/cli/c2c_deliver_inbox.ml:578-588`).
- **Kickoff:** delivered as an XML pipe write in the launch loop (not an
  adapter argv) — codex adapter `deliver_kickoff` is a no-op
  (`ocaml/c2c_start.ml:3612-3617`).
- **Capability/deliver-mode:** `xml_fd` vs `pty_notify` vs `unavailable`
  resolved by probing `--xml-input-fd` in the binary's help
  (`codex_supports_xml_input_fd`, `ocaml/c2c_start.ml:~3414`); matches the
  CLAUDE.md "two codex binaries" gotcha.
- **Heartbeat:** `should_start_codex_heartbeat = codex_heartbeat_enabled &&
  deliver_started` (`ocaml/c2c_start.ml:203-205`); interval
  `codex_heartbeat_interval_s = 240.0` (`:180`); enqueued as a self-DM
  (`enqueue_codex_heartbeat`, `:313-314`). If the deliver daemon fails to
  start, the heartbeat is silently suppressed.

### 2a. NOTED RISK (out of B005 scope — separate codex-delivery investigation)

On a host where `inotifywait` is present (it is here: `/usr/bin/inotifywait`),
`start_deliver_daemon` passes **both** `--inotify` and `--xml-output-fd` for
codex. The dispatch in `c2c_deliver_inbox.ml:556-589` is
`if use_inotify then run_inotify_loop … else (match xml_output_fd …)`. For a
non-"generic" client (codex) the inotify branch is `run_inotify_loop`
(`:570`), which calls `deliver_new_messages` — and that function only
`Printf.printf`s a log line to **stdout** (`:158`), i.e. to `/dev/null` for
the codex daemon; it never writes XML frames to fd4. The fd4 xml writer
(`xml_deliver_loop_daemon`) lives only in the `else` branch. So *as read*, the
`--inotify` flag appears to shadow the xml sideband for codex when inotifywait
is available. **This is UNVERIFIED at runtime** (I did not spawn codex, per
repo rules) and may be mitigated by the separate `setup_codex` pre-deliver
start-hook (`c2c deliver watch --xml-fd`) running as a second daemon. Flagging
for a dedicated codex-delivery investigation — **not** a B005 instruction
concern, and explicitly not fixed here (code change needing a decision).

---

## 3. tmux — "autostart in tmux?"

**No declarative autostart / supervisor exists.** `scripts/c2c_tmux.py`
(subcommands: list, peek, peek-all, capture, send, send-raw, enter, keys,
exec, follow, unfollow, grep, grep-echild, restart, layout, whoami, launch,
wait-alive, stop) is a set of **imperative one-shot helpers**:

- `launch` runs `c2c start <client> …` once in a pane via `tmux send-keys`,
  returns immediately (`scripts/c2c_tmux.py:335-409`).
- `wait-alive` polls `c2c list --json` until the alias is `alive`
  (`:412-434`).
- `restart` sends `/exit`, waits for the shell prompt, relaunches once
  (`:559-599`).

There is **no respawn loop, no manifest, no supervisor, no systemd/cron** —
`c2c start` itself "Exits when client exits (does NOT loop)" (CLAUDE.md). The
`c2c start tmux --loc <target>` mode is a **delivery helper** (polls broker,
types messages into an existing pane via `tmux send-keys`), not an autostart
(`ocaml/c2c_start.ml:~2804-2884`). `c2c agent run --pane`
(`ocaml/cli/c2c_agent.ml:556-647`) launches a tmux window running `c2c start …
--kickoff-prompt-file …` **fire-once**, no keep-alive. If an agent exits it
stays dead until a human re-launches.

---

## Safe fixes applied in this branch

1. CLAUDE.md "Native scheduling" bullet: corrected the firing mechanism for
   managed sessions (inner MCP Lwt schedule timer, S6c) and demoted the
   `c2c start` stat-poll watcher thread to its actual role (fallback when
   `C2C_MCP_SCHEDULE_TIMER` is disabled). Matches `c2c_start.ml:5044-5056`
   and `agent-wake-setup.md` Option 0b.

Deliberately **not** touched (need a product decision / out of scope):
the onboarding-preamble Monitor step, `builtin_swarm_restart_intro` content,
the `--auto` / `--kickoff-prompt` "OpenCode only" help text (the flags do
flow a kickoff to claude via positional argv — `c2c.ml:3218-3224` — so the
"OpenCode only" label is arguably stale, but changing it may contradict
intended behaviour), and the codex inotify/xml dispatch (§2a).

---

## IMPROVE-HALF decisions for Max

**(a) Should the kickoff intro carry wake/monitor guidance, and should
non-`--auto` plain starts get an intro?**
Recommendation: for managed claude, native scheduling already wakes the
agent, so the role preamble's "Arm a heartbeat Monitor" step (4.1m) is
redundant with the native 4.1m `wake.toml` — **drop it for managed sessions**
(or gate it on "no native wake schedule present") to honour dedupe-before-arming.
Separately, give plain `c2c start claude` a minimal always-on intro
(at least the builtin `swarm_restart_intro`) so a no-role start is never
intro-less.

**(b) Is codex's xml-fd delivery + 240s heartbeat an acceptable on-task
nudge, or do you want a different mechanism?**
Recommendation: the design is sound (push-like sideband + idle-gated
self-DM), but two rough edges: heartbeat is silently suppressed if the
deliver daemon fails to start, and the inotify/xml dispatch ordering (§2a)
needs a runtime check. Worth a small dedicated codex-delivery hardening pass.

**(c) Do you want a real tmux autostart/supervisor, or is the manual
`launch`/`restart` helper sufficient?**
Recommendation: today the swarm cannot self-heal a crashed pane — a human
must re-launch. If "as long as one of you is still running, you can keep each
other alive" is to be literal, a lightweight declarative supervisor
(manifest of {alias, client, role} + a respawn loop) is the missing piece.
This is a real feature, not a doc fix — needs sign-off before building.
