# DRAFT: Scheduled agent runs (maintenance bots)

**Status:** draft / blocked — scope decision pending input from Max + future-self
**Originator:** Max (2026-04-25)
**Coordinator:** coordinator1

## Motivation

The swarm has lots of repetitive maintenance work that nobody owns
right now:

- Security audits (dep scans, secret scans, deserialization-foot-guns,
  shell injection sweeps)
- Refactor hunts (duplication detection, dead-code, abstraction-fit
  reviews, naming consistency)
- Code-quality scans (cyclomatic complexity outliers, untested public
  surface, missing docs on tier-1 commands)
- Doc drift (CLAUDE.md vs reality, runbook freshness, deprecated paths
  still referenced)
- Sitrep / activity audits (which agents underperformed targets, which
  conventions are sliding)

Today this only happens when somebody noticed during their slice. We
want it scheduled — bots that wake on cron, do their pass, and either
file findings (`.collab/findings/`), open backlog items
(`.collab/design/DRAFT-*.md`), or DM coordinator with a short
summary.

## Open scope question (BLOCKER)

**Does this live inside c2c, or as a sibling project / external integration?**

Pros of in-c2c:
- We already have agent registration, MCP, message archive, alias allocation.
  Scheduled agents can register as peers like any other and use existing
  delivery + room infrastructure.
- The `c2c stats` work + the layered-heartbeat config already provide
  scheduling primitives. A `[scheduled_agents]` table in `.c2c/config.toml`
  is a natural extension.

Pros of external:
- Different release cadence — security/audit bots want to update fast and
  independently of c2c CLI releases.
- Different audience — not every c2c user wants a scheduled-agents framework.
- Cleaner separation of concerns; c2c stays "messaging broker", maintenance
  framework can be opinionated about how audits run.

Pros of "integrate with existing tool":
- We don't have to build a scheduler. Cron / systemd timers / GitHub
  Actions / Renovate-style bots are mature.
- Could leverage existing code-review-agent products (probably exist).

Decision deferred. Needs another round with Max + brainstorm.

## Sketch (if it lives in c2c)

```toml
# .c2c/config.toml
[scheduled_agents.security-audit]
schedule = "0 4 * * *"           # cron
client = "claude"
prompt_file = ".c2c/scheduled/security-audit.md"
output_dir = ".collab/findings/scheduled/security-audit/"
on_finding = "dm-coord"           # also: "open-issue", "post-room"

[scheduled_agents.refactor-hunt]
schedule = "0 6 * * 1"           # weekly Monday morning
...
```

Each scheduled run:
1. Spawn a fresh managed session via `c2c start <client> --scheduled <name>`.
2. Inject the prompt file as the initial input.
3. Agent does its pass, writes outputs to `output_dir`, exits.
4. Coordinator (or a watcher) scoops outputs at the next sitrep.

## Sketch (if it lives external)

Probably wraps an existing scheduler (cron, GitHub Actions). c2c just
gets a `c2c message-on-completion <alias> <result-summary>` so the
scheduled bot can hand its findings into the swarm.

## Wishlist (helpful tooling — track separately)

This blocked idea also surfaces a meta-need: we should track tools
that *would* help the swarm, to inform future build/integrate
decisions. See `.collab/wishlist.md` (to be created).

## Action items

- [ ] Brainstorm with Max: in-c2c vs external vs integrate, which feels right?
- [ ] Survey existing tools: are there mature scheduled-agent-run frameworks
      that already do this? (Probably worth checking before building.)
- [ ] If green-lit in-c2c: design pass for `[scheduled_agents]` config schema
      + integration with `c2c start` + output-routing convention.
- [ ] Track in wishlist: what specific audit-types do we want first?

## See also

- `.collab/wishlist.md` — what would help the swarm (companion to this draft)
- `c2c start --help` — existing managed-session launcher
- `.c2c/roles/` — existing per-role frontmatter convention
