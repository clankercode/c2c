# `c2c push-gate` — automated push-readiness watcher

**Author:** Cairn-Vigil (coordinator1) · **Created:** 2026-04-29 · **Status:** DRAFT

## Problem

The push gate to `origin/master` is manual: `coordinator1` runs `c2c
doctor` to assess, classifies queued commits, then either `git push`es
or holds. This works but has a known failure mode: **coord forgets a
relay-critical commit for hours** (sleep, compaction loop, attention
drift). The Railway deploy is the only path that puts a server-side
fix into prod, so latency here directly hurts the swarm.

We want a low-cost watcher that turns "coord glances at push state
when she remembers to" into "coord gets DM'd the moment a
relay-critical SHA lands, with the smallest sufficient context to
decide push-now vs hold". v1 is **notify only** — coord still pushes
manually.

## Existing classification rules (verbatim from `scripts/c2c-doctor.sh`)

The doctor script already implements the only classification we need.
Three buckets, computed from the path-touch set + commit subject:

1. **Server-critical** (Railway deploy needed) — files match
   `ocaml/server/|ocaml/relay\.ml|ocaml/relay_server|ocaml/server_http|^railway\.json|^Dockerfile`,
   OR commit subject matches `^(fix|feat|refactor|perf)\(relay-server\)`.
2. **Connector-only** (local `just install-all` rebuild, NO Railway
   push) — files match `ocaml/c2c_relay_connector\.ml|ocaml/relay_client`.
3. **Local-only** — everything else.

**Override:** if every touched file matches the docs-only allow-list
`^(docs/|_config\.yml|Gemfile|_layouts/|_includes/|\.collab/|\.goal-loops/|README)`,
the commit is forced to local-only regardless of subject. This kills
false positives like `docs: mark relay.c2c.im live`.

`c2c_start.ml` is intentionally **not** server-critical — Railway runs
`c2c relay serve`, not `c2c start`.

`push-gate` reuses these rules verbatim. **Slice 1 lifts them out of
the bash script into an OCaml module** (`C2c_push_gate.classify`) so
both `c2c doctor` and `c2c push-gate` share one source of truth. No
behaviour change to `doctor` in slice 1 — the bash entrypoint shells
out to the new OCaml subcommand for the classification step, or we
keep the bash and have OCaml load the same rules from a single
`.c2c/push-gate-rules.toml` (preferred — one canonical regex set).

## CLI surface

### `c2c push-gate verdict` — one-shot snapshot

Suitable for sitrep inclusion, idle-check scripts, or eyeballing.
Mirrors the JSON shape of `c2c doctor --json` but pruned to the
push-decision fields:

```
$ c2c push-gate verdict
relay-critical:  2 commits  (push WARRANTED)
connector-only:  0 commits
local-only:      7 commits
relay deployed:  4450cf56 (3h12m ago)
queue oldest:    492c052b (1h47m ago)
verdict:         PUSH  — relay-critical commit older than 30m

$ c2c push-gate verdict --json
{
  "relay_critical": [{"sha": "...", "subject": "...", "age_seconds": 6420}, ...],
  "connector_only": [...],
  "local_only":     [...],
  "deployed_sha":   "4450cf56",
  "deployed_age_seconds": 11520,
  "verdict":        "push",
  "reason":         "relay-critical commit older than 30m"
}
```

Verdict values:
- `push` — at least one relay-critical commit AND (it's >30m old OR
  any local-only is >2h old AND queue depth >5).
- `consider` — relay-critical commit exists but <30m old (let coord
  batch).
- `hold` — no relay-critical commits; local-only queue can drain on
  next opportunistic push.
- `clear` — queue empty.

Exit codes: `0` for `clear`/`hold`, `1` for `consider`, `2` for `push`
— so cron/Monitor wrappers can `if c2c push-gate verdict; then ...`.

### `c2c push-gate watch` — daemon / Monitor mode

Polls every N minutes (default 5), DMs `coordinator1` (configurable
via `--alias`) when one of three transition events fires:

1. **NEW_RELAY_CRITICAL**: a SHA appeared in the relay-critical bucket
   that was not present at last tick. DM body includes the SHA +
   subject + suggested verdict.
2. **STALE_QUEUE**: relay-critical bucket is non-empty AND its oldest
   member is ≥30m old AND we have not DM'd about this exact set of
   SHAs in the last 30m (dedup window).
3. **DEPLOYED_SHA_DRIFT**: `relay-smoke-test --quiet --json` reports
   the live `git_hash` is not an ancestor of `origin/master` (i.e.
   prod is on a SHA we no longer have, or has diverged). Surfaces
   prod-rollback / forced-push events, which historically have
   silently broken the swarm.

State persisted at `~/.c2c/push-gate/state.json`:
```
{
  "last_tick_unix": 1769876543,
  "last_notified_critical_shas": ["..."],
  "last_notified_stale_at_unix": 1769870000,
  "last_known_deployed_sha": "4450cf56"
}
```

Surface choice — **daemon vs Monitor**:

| Aspect | Background daemon (`c2c push-gate watch`) | Monitor recipe |
|---|---|---|
| Lives across restarts | Yes (systemd-user / runit) | No — tied to Claude session |
| Cost | Zero LLM tokens | ~50 input tokens per tick × cadence |
| DM path | `c2c send` from outside any session | `c2c send` from inside coord's session |
| Discovery | New surface to document | Reuses the Monitor recipe pattern coord already runs |
| Visibility | Logs at `~/.c2c/push-gate/log` | TaskList |
| Kills the spark? | No — runs even if all agents nap | Yes — dies with coord |

**Recommendation: ship `c2c push-gate watch` as a real daemon
(slice 3) AND publish a Monitor recipe (slice 4)** — daemon is
the production path, Monitor is the "I'll try it for an hour"
on-ramp. The daemon's only job is `c2c push-gate verdict --json` →
diff against state → `c2c send coordinator1`. Implementing it as a
daemon means the swarm can't sleep through a relay-critical commit
just because coord's session compacted.

Monitor recipe (publishes alongside heartbeat/sitrep in
`agent-wake-setup.md`):

```
Monitor({ description: "push-gate watch",
          command: "c2c push-gate watch --once --notify coordinator1",
          interval: "5m",
          persistent: true })
```

`--once` means "run one tick and exit"; the Monitor harness handles
cadence. The daemon mode (default, no `--once`) loops internally with
its own `--cadence-minutes`.

## Open question — auto-push?

**Recommendation for v1: NO.**

### For
- Eliminates the failure mode entirely. If a relay-critical commit
  lands and is signed by a known peer, push it.
- Coord-as-bottleneck is a real cost — Cairn has slept through
  relay-critical SHAs before.
- Railway deploys are reversible (`railway rollback`), so the blast
  radius of an erroneous push is bounded.

### Against (decisive for v1)
- **Money.** Each push triggers a ~15min Docker build. A bug in the
  classifier — or a peer landing 5 relay-critical commits in a row
  while iterating — burns real $ per build. Coord's "let me wait 10m
  and batch" is a load-bearing cost control, not a bug.
- **Coord-only push autonomy is a Max-granted authorization** (see
  `feedback_push_autonomy.md` in user memory). Granting it to a
  daemon expands the trust boundary; that's a policy call, not a
  code call.
- **Smoke-test gating is a separate problem.** Auto-push without
  auto-validate is worse than manual; auto-validate needs a green
  signal we trust, and `relay-smoke-test.sh` today is "comprehensive
  but human-readable", not a hard gate.
- **The signal we want is "wake coord", not "bypass coord".** v1
  solves the actual reported bug (forgotten pushes) without taking
  on the policy work.

If a v2 ever ships auto-push, the right shape is:
- `c2c push-gate watch --auto-push` (off by default; Max flips it on
  in his settings).
- Hard precondition: every queued commit has a signed peer-PASS DM
  (#324 rubric) referencing its SHA.
- Hard cooldown: at most one push per 20m, regardless of classifier
  state.
- Hard rollback: post-push smoke test fails ⇒ daemon DMs
  `coordinator1 + swarm-lounge` with `URGENT: prod smoke failed,
  consider railway rollback`. No automatic rollback in v2 either.

## Slice plan (3 commits, ~1 day each)

### Slice 1 — Extract classifier into OCaml (~150 LOC)
- New module `ocaml/cli/c2c_push_gate.ml`:
  - `type bucket = Relay_critical | Connector_only | Local_only`
  - `val classify : sha:string -> bucket`
  - Internal: `git diff-tree --no-commit-id -r --name-only`,
    regex-match on file list + commit subject, docs-only override.
- Tests: fixtures with synthetic SHAs covering all three buckets +
  the docs-only override (≥6 cases, one per branch).
- `scripts/c2c-doctor.sh` keeps its own bash classifier for now —
  parity test asserts both classifiers return the same buckets for
  the last 50 commits on `master`.

### Slice 2 — `c2c push-gate verdict` (~80 LOC)
- New cmdliner subcommand under top-level `push-gate` group.
- `--json` flag.
- Verdict computation, exit-code mapping, state-free.
- Tests: golden JSON for fixed git-log fixture.

### Slice 3 — `c2c push-gate watch` (~200 LOC)
- Loop / `--once` mode.
- State file `~/.c2c/push-gate/state.json` with atomic write
  (temp+rename, mirrors registry pattern).
- Three transition events; DM body via `c2c_send`.
- `relay-smoke-test --quiet --json` invocation guarded by
  `--check-relay` (off by default — network-flaky in tests).
- Tests: fake-time + fake-git fixture exercising all three events.

### Slice 4 — Wire-up + docs (~50 LOC + docs)
- Publish Monitor recipe in
  `.collab/runbooks/agent-wake-setup.md` under a new
  "Coordinator-only" subsection.
- Add `push-gate verdict` to coord's hourly sitrep template.
- `c2c install` writes a systemd-user unit (skip on macOS for v1)
  for `c2c push-gate watch` — opt-in via flag, not default.
- Update `CLAUDE.md` with one bullet pointing at the runbook.

## Out of scope for v1
- Auto-push (see policy section above).
- Multi-coord notification (DMs only `coordinator1`).
- Per-peer "your commit is blocking the deploy" DMs — would help, but
  belongs to a follow-up #issue tracking peer-feedback loops.
- Web dashboard / GUI integration — the GUI app (`project_gui_app`)
  can render `c2c push-gate verdict --json` later.
