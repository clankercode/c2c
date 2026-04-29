# `c2c init` first-run UX redesign

**Date**: 2026-04-29
**Author**: cairn-vigil (coordinator1, design hat)
**Status**: design proposal — ready for swarm review
**Scope**: refresh `c2c init` so a brand-new operator (or fresh agent
session) goes from `git clone` to "live in swarm-lounge with the
right alias" in <60s, with zero head-scratching.

---

## Problem statement

`c2c init` is the first command a new user runs after cloning. It has
accumulated history: it currently configures the client MCP, registers
an alias, joins a room, optionally writes supervisor config, optionally
attaches to a relay. The flow works, but it has accumulated friction:

1. **No pre-flight feedback.** If the broker dir is unwritable, identity
   keypair generation fails silently (`Sys.command "c2c relay identity
   init 2>/dev/null"` swallows the error), or git remote is wonky, the
   user finds out 3 commands later when something deeper breaks.
2. **Auto-detection is invisible.** `detect_client ()` picks a client
   from `$PATH` order (`opencode > claude > codex > kimi > gemini`) but
   the user doesn't see the choice until after it runs. No "I detected
   X — proceed? [Y/n]" prompt. Wrong detections silently configure the
   wrong client.
3. **The "next steps" output is generic.** Current footer prints four
   commands (`list`, `send`, `poll-inbox`, `send-room`) but doesn't
   suggest a single concrete first action. New users reach for `send`
   without an addressee. The CEO dogfood (2026-04-23) hit this directly.
4. **The cross-machine path is undocumented in the success footer.** A
   user who ran `c2c init` without `--relay` is left in a local-only
   broker and doesn't know it. No mention of how to attach to the swarm.
5. **Restart requirement is unmentioned** (CEO 2026-04-23 SUGGESTION 2).
   After init configures the client MCP, the client must be restarted
   for the MCP server to load. The footer doesn't say so.
6. **Identity init runs blind.** `c2c relay identity init` is invoked
   with `2>/dev/null`; if it fails the user has no signal until they
   try to room-send and the relay rejects the unsigned request.
7. **Session ID auto-generation is lossy.** Without
   `C2C_MCP_SESSION_ID`, init generates one but doesn't tell the user
   how to reproduce it for the next shell. Restart of the same shell
   re-runs init and gets a *new* session ID, orphaning the prior alias.

Prior findings: `2026-04-23T18-40-00Z-ceo-first-time-user-dogfood.md`
(B1, B2 fixed; suggestions 1–2 still open),
`2026-04-23T19-40-00Z-ceo-get-started-dogfood.md`,
`2026-04-26T00-38-17Z-lyra-cross-machine-onboarding-gaps.md` (gap #2:
init does not configure relay attachment by default).

---

## Goals

- **<60s from `git clone` to first message in `swarm-lounge`.** Includes
  binary install (`just install-all`) but assumes that already worked.
- **Auto-detect, then confirm.** Show the user what would happen before
  it happens. Honor `--yes` / `--non-interactive` for scripts.
- **Pre-flight before commit.** Validate git remote, broker dir
  writability, identity generation, and disk space *before* writing
  anything. Fail fast with actionable error.
- **Concrete next-3-commands footer.** Replace the generic 4-command
  list with three commands wired to the user's actual just-set state:
  `c2c whoami`, `c2c send-room swarm-lounge "hi, I'm <alias>"`,
  `c2c room-history swarm-lounge`.
- **Forward-compatible with relay.** The local-broker case is the
  90% path today, but the design must leave a clean slot for
  `--relay <url>` (existing) and a future `--join-swarm` that
  defaults to the hosted relay.

---

## Refreshed flow (high level)

```
c2c init [--client X] [--alias Y] [--yes] [--relay URL] [--no-setup]
```

```
+---------------------------------------+
| 1. Pre-flight checks (read-only)      |
|    - git: remote sane / repo detected |
|    - broker: dir writable, fp resolves|
|    - identity: keypair gen works      |
|    - client: auto-detect, show choice |
|    - alias: collision check (local)   |
+---------------------------------------+
          |  on any FAIL → exit 1, actionable error
          v
+---------------------------------------+
| 2. Plan preview (interactive only)    |
|    "Will configure: opencode          |
|     Alias:  forest-otter              |
|     Broker: ~/.c2c/repos/<fp>/broker  |
|     Room:   swarm-lounge              |
|     Identity: ~/.config/c2c/id.json   |
|     [Y/n] "                           |
+---------------------------------------+
          |  --yes / --non-interactive → skip
          v
+---------------------------------------+
| 3. Execute (write phase)              |
|    - identity init (verbose on err)   |
|    - client MCP install               |
|    - register w/ broker               |
|    - join swarm-lounge                |
|    - save .c2c/repo.json (if needed)  |
|    - (--relay) attach + register      |
+---------------------------------------+
          |
          v
+---------------------------------------+
| 4. Footer: 3 commands to try next     |
|    + restart hint (if MCP newly set)  |
+---------------------------------------+
```

---

## Sample sessions

### Before (current behavior, abridged)

```
$ c2c init
[c2c register] no --alias given; auto-picked alias=forest-otter. Pass --alias NAME to override.

c2c init complete!
  session:  cli-9f3a2b
  alias:    forest-otter
  broker:   /home/x/.c2c/repos/abc123/broker
  setup:    opencode configured
  room:     joined #swarm-lounge

You're ready! Try:
  c2c list              — see peers
  c2c send ALIAS MSG    — send a message
  c2c poll-inbox        — check your inbox
  c2c send-room swarm-lounge MSG  — chat in the room
```

Pain: no preview, no restart hint, no concrete addressee, identity
init silently ran (or silently failed), no relay-attach guidance.

### After (interactive, happy path)

```
$ c2c init
c2c init — quick checks…
  ✓ git repo:   c2c-msg @ XertroV/c2c-msg
  ✓ broker:     ~/.c2c/repos/abc123…/broker (writable, fresh)
  ✓ identity:   ~/.config/c2c/identity.json (new keypair, ed25519)
  ✓ client:     opencode (auto-detected on $PATH)
  ✓ alias:      forest-otter (free in local broker)

About to configure:
  client → opencode (writes ~/.config/opencode/plugin/c2c.ts)
  alias  → forest-otter
  room   → #swarm-lounge (auto-join on every restart)

Proceed? [Y/n] y

  ✓ identity   ed25519 keypair @ ~/.config/c2c/identity.json
  ✓ client     opencode plugin installed
  ✓ register   forest-otter ↔ session cli-9f3a2b
  ✓ room       joined #swarm-lounge

Next 3 commands to try:
  1. c2c whoami                                       # confirm your identity
  2. c2c send-room swarm-lounge "hi, I'm forest-otter"  # say hello
  3. c2c room-history swarm-lounge --limit 20         # catch the vibe

⚠ Restart opencode to load the c2c MCP server:
    c2c restart opencode    # (or /exit + relaunch)

Tip: run `c2c init --relay https://relay.c2c.im` next time to also
join the cross-machine swarm. Local-only for now.
```

### After (non-interactive / script)

```
$ c2c init --yes --client codex --alias my-bot
c2c init — quick checks… ok
  identity: ~/.config/c2c/identity.json (existing)
  broker:   ~/.c2c/repos/abc123/broker
  alias:    my-bot
  client:   codex (--client)
  room:     swarm-lounge

[1/4] identity   ok
[2/4] client     codex configured
[3/4] register   my-bot ↔ codex-1730203400
[4/4] room       joined swarm-lounge

Next: c2c whoami | c2c send-room swarm-lounge "hi" | c2c room-history swarm-lounge
Restart codex to pick up MCP changes.
```

### After (failure case — broker dir unwritable)

```
$ c2c init
c2c init — quick checks…
  ✓ git repo:   c2c-msg @ XertroV/c2c-msg
  ✗ broker:     ~/.c2c/repos/abc123/broker

error: cannot create broker dir (~/.c2c/repos/abc123/broker):
       Permission denied
hint:  - check $HOME permissions
       - or set C2C_MCP_BROKER_ROOT to a writable path
       - or set XDG_STATE_HOME

(Aborted before any state was written.)
```

---

## Pre-flight checks (detail)

Each check is read-only and fast (<50ms). Cumulative budget: <300ms.

| Check | What | Failure mode | Hint |
|---|---|---|---|
| `git_repo` | `git rev-parse --show-toplevel` succeeds | not in a repo | "cd to a c2c clone, or run from any git repo" |
| `git_remote` | `git remote get-url origin` succeeds | no remote | "set `git remote add origin …` so broker fingerprint is stable across clones" — non-fatal warning |
| `broker_dir` | resolve broker root, mkdir+rm probe | EACCES / ENOSPC | suggest `C2C_MCP_BROKER_ROOT` |
| `identity` | `Relay_identity.exists ()` or generation dry-run | keypair gen errors | check `~/.config/c2c/` writable |
| `client` | auto-detect via `$PATH` + `$C2C_MCP_SESSION_ID` | no client found | list supported, suggest `--client` |
| `alias_collision` | scan local registry for case-insensitive match | collision | suggest `--alias` with a free pool word |

Pre-flight prints a checklist with `✓` or `✗`. **No state is written
until all checks pass.** This addresses CEO suggestion #1 (binary
missing → guidance) by fast-failing on missing prerequisites.

---

## Auto-detection refinement

Current logic (`detect_client ()` in `c2c.ml:4894`) probes
`$C2C_MCP_SESSION_ID` prefix first, then `$PATH` for binaries in
order `opencode > claude > codex > kimi > gemini`. Refinements:

- **Show the result before applying.** Print `client: opencode
  (auto-detected on $PATH)` in pre-flight, with the source noted
  (env var, $PATH match, or explicit flag).
- **Tie-breaker preference.** If multiple clients are on $PATH, prefer
  the one with an existing managed instance from `c2c instances`. If
  none, fall back to current order with a note that `--client` can
  override.
- **Negative confirmation in non-interactive.** When `--yes` and
  auto-detection picks something, log it loudly so script logs
  document what got configured.
- **Honor `[swarm].default_client` in `.c2c/config.toml`** as a
  per-repo override of the $PATH probe. (New config key, optional.)

---

## Footer redesign — "next 3 commands"

Replace the four-line generic list with **exactly three** numbered
commands, wired to the alias and room just configured:

```
Next 3 commands to try:
  1. c2c whoami                                        # confirm your identity
  2. c2c send-room swarm-lounge "hi, I'm <alias>"      # say hello
  3. c2c room-history swarm-lounge --limit 20          # catch the vibe
```

Plus, conditionally:

- **Restart hint** when client MCP was freshly installed (skip if
  `--no-setup`): `Restart <client> to load the c2c MCP server`.
- **Relay tip** when no `--relay` was passed: a one-liner pointing to
  `c2c init --relay https://relay.c2c.im` for the cross-machine path.
- **Memory hint** if `c2c memory list` would show prior-self entries
  for the chosen alias (returning user): `Prior-self memory found —
  run \`c2c memory list\` to read.`

---

## Implementation slices

Sketch of how to land this without a single mega-PR. Each slice is
peer-PASS-shaped (one issue, one worktree, <500 LOC diff).

### Slice 1 — Pre-flight check harness (foundation)

- New module `c2c_init_preflight.ml` with a `Check.t` record
  (`name; run; hint`) and a runner that prints the checklist and
  returns `Ok | Error of failure list` without writing state.
- Wire all 6 checks listed above. Pure-read; no side effects.
- Plumb into `init_cmd` as a step before `setup_result`.
- Tests: fixture-driven (each check has a "force fail" knob).
- **Issue scope**: ~250 LOC + tests.

### Slice 2 — Plan preview + `--yes` flag

- After pre-flight passes, render a "About to configure:" block
  showing client, alias, broker, room, identity path.
- Prompt `Proceed? [Y/n]` when stdin is a TTY and `--yes` is unset.
- `--yes` (alias `--non-interactive`) skips the prompt.
- Default Y on empty input; explicit `n` aborts cleanly with
  exit 0 (not an error — user said no).
- **Issue scope**: ~120 LOC + tests.

### Slice 3 — Footer redesign + restart hint

- Replace current 4-line footer with 3-line numbered list.
- Append restart hint when `setup_result = `Ok client`.
- Append relay tip when `relay_url = None`.
- Append memory hint when `c2c memory list <alias>` would be non-empty.
- Update JSON output schema with a `next_steps: [string]` field for
  programmatic consumers.
- **Issue scope**: ~80 LOC + tests + docs/get-started.md update.

### Slice 4 — Identity-init verbose-on-error

- Replace `Sys.command "c2c relay identity init 2>/dev/null"` with a
  proper invocation that captures stderr; if it fails, print the
  actual error and a hint (write permission to `~/.config/c2c/`).
- Pre-flight already probes this; this slice fixes the *execution*
  phase to not silently swallow the error if pre-flight passed but
  the actual gen still fails (race on disk full, etc.).
- **Issue scope**: ~60 LOC + tests.

### Slice 5 (optional) — `[swarm].default_client` config key

- Add `default_client = "opencode"` (etc.) under `[swarm]` in
  `.c2c/config.toml`, consumed by `detect_client ()`.
- Useful for repos where the team standardizes on one client.
- **Issue scope**: ~50 LOC + tests + docs.

---

## Open questions

1. **Should `c2c init` start `c2c relay connect --daemon` when
   `--relay` is passed?** Today it saves config and registers but
   leaves the connector to the user (lyra gap #5). Probably out of
   scope for this redesign — separate slice for managed connector.
2. **Should the plan preview show the *exact files* that will be
   written?** (e.g. `~/.config/opencode/plugin/c2c.ts`) Verbose but
   audit-friendly. Lean toward yes, behind `-v`.
3. **Should we add `c2c init --doctor` to re-run pre-flight without
   touching state?** Useful for "is my install healthy?" — but
   `c2c doctor` already exists. Probably leave init as a one-shot
   and point doctor users there.

---

## Acceptance criteria

A peer-PASS for the combined slice set requires:

- [ ] Fresh-clone smoke: `git clone … && just install-all && c2c init
      --yes` lands in <60s and prints all four phases (preflight,
      plan, execute, footer).
- [ ] Failure mode smoke: revoke write to `~/.c2c/`, run `c2c init`,
      get actionable error, no state written.
- [ ] Auto-detect smoke: with only one client on $PATH, run `c2c
      init`, confirm preview names that client and proceeds.
- [ ] Non-interactive smoke: `c2c init --yes --client codex --alias x`
      runs end-to-end with no prompts and exits 0.
- [ ] Existing `--no-setup`, `--supervisor`, `--relay` flags continue
      to work (regression).
- [ ] `docs/get-started.md` and `docs/index.md` updated to reflect the
      new footer and `--yes` flag (docs-up-to-date check, #324).
