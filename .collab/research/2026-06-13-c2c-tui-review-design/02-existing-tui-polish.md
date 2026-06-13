# 02 — Existing "TUI" Surfaces: Review, Polish, Overhaul

**Scope:** A prioritized review + remediation plan for the two surfaces the
operator thinks of as c2c's "interactive tooling": **(A) the role-designer
wizard** (`c2c agent new` / `agent refine` + the role-designer persona) and
**(B) the tmux operator tooling** (`scripts/c2c_tmux.py` + four shell helpers +
legacy `c2c-swarm.sh`). Companion to `01-*` (data substrate) and the new-browser
design. **Research/design only — nothing here is implemented.**

**The headline:** neither surface is a TUI. (A) is a numbered-menu readline loop
that hands off to a *separate LLM session in a tmux pane*; (B) is pane-scrollback
scraping. The new browser (designed elsewhere in this campaign) subsumes the
*read* half of (B) wholesale. This doc says, concretely, what to **cut**, what
to **keep as a separate write/drive tool**, and how to fix the role wizard's two
real defects without waiting on the browser.

Grounding spot-checks performed before writing (all confirmed):
- `role_designer_embedded` appears in `ocaml/cli/dune:3` `(modules …)` and
  **nowhere else** in `ocaml/` or `justfile` → compiled-in **dead code**.
- `agent refine` hard-errors on a missing on-disk role file at
  `c2c_agent.ml:404` and `:703` (`error: role file not found`) — **no fallback**
  to the embedded copy that is sitting in the binary.
- `c2c_tmux.py` registers 13 subcommands (`c2c_tmux.py:456–515`); `follow`,
  `unfollow`, `grep`, `grep-echild`, `peek-all`, `restart` exist **only** in
  `c2c-swarm.sh:242–251`.

---

## Part A — The role-designer "wizard"

### A.0 What it actually is (correcting the operator's mental model)

There is no curses/ANSI form. "The wizard" is two unrelated things glued by a
`printf` hint:

1. **`c2c agent new`** with no flags on a TTY → a sequential numbered-menu
   readline loop (`agent_new_interactive`, `c2c_agent.ml:126–203`) built on
   hand-rolled `prompt_nonempty` / `prompt_choice` / `prompt_multi_select`
   (`c2c_agent.ml:13–50`). One-shot prompts, recursion-on-bad-input, no cursor
   nav, no back-button, no live validation. Writes a `.c2c/roles/<NAME>.md`
   skeleton, then prints `next: c2c agent refine <name>` (`c2c_agent.ml:378`).

2. **`c2c agent refine <name>`** (`agent_refine_term`, `c2c_agent.ml:664–750`) →
   reads the on-disk draft, builds a kickoff prompt, and **spawns a full coding
   CLI** (Claude/OpenCode/Codex/Kimi) in a *new tmux window* running the
   `role-designer` persona (`run_ephemeral_agent ~role:"role-designer"
   ~mode:Pane`, `c2c_agent.ml:390–660`). The "wizard UI" is a free-form chat with
   that spawned LLM, which edits the file in place and calls `stop_self`.

The `role-designer` persona itself is `.c2c/roles/role-designer.md` (its source
of truth is `.c2c/roles/builtins/role-designer.md`, codegen'd into
`role_designer_embedded.ml`). It is a **system prompt**, not a UI.

### A.1 Usability problems (severity-ordered)

| # | Problem | Evidence | Sev |
|---|---------|----------|-----|
| A1 | **Dead embedded persona + brittle hard-error.** `agent refine` errors out if `.c2c/roles/role-designer.md` is deleted, even though a byte-identical copy is compiled into the binary and never consulted. | `c2c_agent.ml:404,703`; `role_designer_embedded.ml`; `dune:3` only ref | **High** |
| A2 | **`refine` hard-requires `$TMUX`** and silently assumes a coding CLI is installed. From a plain shell: `error: --mode pane requires running inside tmux` (`c2c_agent.ml:596–600`), no fallback. | `c2c_agent.ml:596–600` | **High** |
| A3 | **No back-button / no edit-prior-answer.** Every prompt in `agent new` is one-shot; a typo in field 2 means restart the whole loop. | `prompt_*` recursion model, `c2c_agent.ml:21–50` | Med |
| A4 | **No validation beyond range checks.** Description = any non-empty string; alias words can collide with **live registered peers** (the 128-word pool footgun); the real `.md`-suffix bug recorded in `tundra-coder.md:2`. | `c2c_agent.ml:13–50`; `tundra-coder.md` | Med |
| A5 | **Poor discovery.** No `c2c wizard` / `c2c agent wizard`. Operator must *already know* the `new → refine` chain; the two-phase design lives only in a doc-string ("Phase 2 of the agent wizard", `c2c_agent.ml:833`). | — | Med |
| A6 | **Refine babysitting.** Each refine is a whole managed session with a 1800s idle watchdog the operator must mind; nothing chains `new`→`refine` automatically. | `run_ephemeral_agent` watchdog, `c2c_agent.ml:390–660` | Low |

### A.2 Recommendations — opinionated

**Stance: do the two cheap correctness fixes now (A1, A2). Do NOT build a
curses form for `agent new` — fold role authoring into the new browser as a
form tab later. Cut nothing yet; the line-based loop is fine as a fallback.**

| Action | What | Effort | Risk | Verdict |
|--------|------|--------|------|---------|
| **REFACTOR (A1)** | Make `run_ephemeral_agent` fall back to `Role_designer_embedded.content` when `.c2c/roles/role-designer.md` is absent (write it to a temp/cache path, or pass inline). This *uses* the dead module the codegen already maintains — self-heals a deleted/renamed persona and kills the latent footgun. | **S** | Low | **DO NOW** |
| **POLISH (A2)** | When `refine` is invoked outside `$TMUX`, don't `exit 1`. Print the exact `tmux new-window …` command to run, OR (better) offer the in-process line-based interview using the persona's question set (it's already specified verbatim — see A.3). | **M** | Low | **DO NOW** |
| **POLISH (A4)** | In `agent_new_interactive`: (a) warn (not block) on alias collision against `c2c list --json` live peers; (b) strip the stray `.md` suffix on `include` entries (`tundra-coder.md` bug); (c) re-validate role-class against `Role_templates`. | **S** | Low | DO NOW |
| **POLISH (A5)** | Register a thin `c2c agent wizard` alias that runs `new` then auto-chains `refine` on the just-created name, with `--help` describing both phases. Pure discoverability; no new logic. | **S** | Low | Nice-to-have |
| **DEFER → browser (A3)** | The "edit a prior answer / see field state" need is exactly a form. **Do not** build an OCaml curses form for it. Add a **role-authoring tab** to the new Python/Textual browser, rendering the persona's question set as a real form against `C2c_role.parse_file` + `render_role_for_client`. | **L** | Med | LATER, in browser |
| **KEEP** | The `agent refine` → spawned-LLM path. Free-form LLM authoring is genuinely good for *content*; only the *missing-file* and *no-tmux* edges are broken. Don't replace the LLM with a form — augment. | — | — | KEEP |

**Do NOT do:** rewrite `agent new` as a Bubble-Tea/Notty form. There is no TUI
lib in deps (`ocaml/cli/dune:4` = `cmdliner yojson logs unix str lwt.unix
cohttp-lwt-unix`), the line loop works as a fallback, and the *real* form lives
in the browser. Building an OCaml curses form here is duplicated effort against a
TUI-poor ecosystem.

### A.3 What the new browser reuses (so A3 lands cheaply later)

The role-authoring tab needs **no new parsing or question design** — it's all
specified:

- **Interview question set** (purpose / scope / collaboration / failure-modes /
  dogfood / escalation / client-compat / theme): `role_designer_embedded.ml:25–44`
  — drop straight into a Textual form.
- **Role-file YAML shape** + #413 onboarding boilerplate:
  `role_designer_embedded.ml:51–69`.
- **Read/render plumbing:** `C2c_role.parse_file`, `C2c_role.canonical_roles_dir ()`,
  `C2c_commands.render_role_for_client role ~client ~name`,
  `C2c_commands.agent_file_path`. The Python browser shells out to
  `c2c roles compile <name> --client all` to write `.opencode/agents/<name>.md`
  etc.
- **Theme list** (`c2c_agent.ml:150–156`) + `Banner.print_banner ?theme_name` for
  visual identity.

So the browser's "new role" tab is: render the 8-question form → write
`.c2c/roles/<NAME>.md` (or shell `c2c agent new --non-interactive` with the
answers) → offer a "hand off to role-designer LLM" button that shells
`c2c agent refine <name>`. The LLM-refine path **stays** as the content-authoring
escalation; the form just removes the no-back-button friction for the skeleton.

---

## Part B — tmux operator tooling

### B.0 The structural insight (drives every recommendation below)

**Everything in this toolchain is pane-scrollback-driven.** To see what an agent
received or sent, you scrape its terminal text (`peek`/`capture`/`grep`), which
is lossy (scrollback window), ANSI-polluted (needs `sed` stripping,
`c2c-swarm.sh:160,197`), and conflates broker traffic with the agent's own
reasoning text. There is **no command anywhere** in this tooling that shows an
agent's actual inbox/outbox or room membership from the broker.

The new browser reads the broker directly (`registry.json`, `archive/*.jsonl`,
`rooms/<id>/history.jsonl` — see `01-*`). That makes the **read half** of this
tooling obsolete and strictly worse than the browser. The **write/drive half**
(typing into real PTYs: `send`/`keys`/`enter`/`exec`/`launch`/`stop`/`restart`)
is irreducible — you cannot drive a live coding-CLI's TTY by reading broker
files.

**The clean split:**

```
                 ┌─────────────────────────────────────┐
   READ surface  │  NEW BROWSER  (Python/Textual)       │
   (subsume)     │  registry • DMs • rooms • events      │  reads broker JSON
                 │  list · history · inbox · rooms · log │  (lossless, parseable)
                 └─────────────────────────────────────┘
                 ┌─────────────────────────────────────┐
   WRITE surface │  c2c_tmux.py  (keep, consolidate)    │  drives real PTYs
   (keep)        │  send·keys·enter·exec·launch·stop    │  (extended-keys toggle,
                 │  + restart·follow  (ported in)       │   /proc TUI-guard)
                 └─────────────────────────────────────┘
```

The browser can offer a "jump to / send to this agent" affordance, but it
**shells out to `c2c_tmux.py send`** for the actual keystroke — it does not
reimplement the extended-keys toggle. One source of truth per concern.

### B.1 Usability problems (severity-ordered)

| # | Problem | Evidence | Sev |
|---|---------|----------|-----|
| B1 | **No broker-backed view of messages anywhere.** To see what an agent received you scrape scrollback — lossy, ANSI-laden, conflated with reasoning. Rooms (a first-class topology) are *invisible* to every tmux command. | whole toolchain; `01-*` data model | **High** |
| B2 | **Two overlapping tools, diverged feature sets, BOTH "canonical."** `c2c_tmux.py` (modern: launch/wait-alive/stop/cache) vs `c2c-swarm.sh` (legacy but UNIQUELY has restart/follow/grep/grep-echild/peek-all). CLAUDE.md lists both as canonical harnesses. The py docstring claims it consolidates the bash one but **silently dropped 6 verbs**. | `c2c_tmux.py:456–515` vs `c2c-swarm.sh:242–251` | **High** |
| B3 | **`restart` lives only in bash.** The single most operationally valuable swarm verb (sends `/exit`, handles the "Background work is running" confirm dialog, relaunches in place) is `c2c-swarm.sh:181–218` only. | `c2c-swarm.sh:181–218` | **High** |
| B4 | **Identity = process-tree scraping, not registry.** Resolves alias→pane by regex-matching the literal `c2c start <client> -n <alias>` argv (`c2c_tmux.py:78,114–126`). Breaks for any pane not launched via that exact incantation; the alias cache can point at a reused pane. | `c2c_tmux.py:78,114–126` | Med |
| B5 | **No grep/follow in the modern tool.** Cross-agent search (which CLAUDE.md calls "the entire point of c2c") and live pane-tail are bash-only. | `c2c-swarm.sh:138–179` | Med |
| B6 | **`launch` silently steals an idle pane.** Default reuses any idle fish/bash/zsh pane in the active window (`c2c_tmux.py:376`) — can grab the pane the operator was about to use; heuristic is implicit. | `c2c_tmux.py:306,376` | Med |
| B7 | **Extended-keys toggle triplicated.** The correctness-critical "submit to a TUI pane" incantation is copy-pasted in `c2c-tmux-enter.sh`, `c2c-tmux-exec.sh`, `tui-snapshot.sh`. Drift risk on a documented-correctness workaround. | three files | Low |
| B8 | **No idle/last-activity hint in `list`.** `c2c-swarm.sh`'s list showed the last scrollback line; the py rewrite dropped it. Operator can't tell stuck-vs-working at a glance. | `c2c_tmux.py list` | Low |

### B.2 Recommendations — opinionated

**Stance: ONE write tool (`c2c_tmux.py`). Port the 3 high-value verbs the rewrite
dropped (restart, grep, follow). DELETE `c2c-swarm.sh` after the port. Let the
browser SUBSUME the read verbs and eventually shed them from `c2c_tmux.py`. Fix
identity to be registry-first. Make `launch` non-stealing. Factor the toggle.**

| Action | What | Effort | Risk | Verdict |
|--------|------|--------|------|---------|
| **REFACTOR (B3/B5/B2) — port-then-delete** | Port `restart`, `grep`, `follow`/`unfollow` from `c2c-swarm.sh` into `c2c_tmux.py`. The **load-bearing** part of `restart` is the "Background work is running" confirm-dialog handling (`c2c-swarm.sh:181–218`) — do NOT lose it. Then **DELETE `c2c-swarm.sh`** and strike it from CLAUDE.md's canonical-harness list. | **M** | Med (restart dialog logic is fiddly) | **DO** |
| **REFACTOR (B4)** | Make identity resolution **registry-first**: read `c2c list --json` for alias→pid, match pids against pane child pids; fall back to argv-scraping only when the registry has no pid (foreign/legacy clients). Agents not launched via the exact incantation then resolve. | **M** | Low | **DO** |
| **POLISH (B6)** | `launch`: require `--reuse` to grab an idle pane, OR at minimum **print which pane it's grabbing before launching** so it can't silently steal the operator's pane. Default to split. | **S** | Low | DO |
| **REFACTOR (B7)** | Factor the extended-keys-off Enter toggle into ONE helper (`scripts/_c2c_tmux_enter_lib.sh` or fold into `c2c_tmux.py`'s `_send_enter`), have `c2c-tmux-exec.sh` and `tui-snapshot.sh` source it. One source of truth for a documented correctness incantation. | **S** | Low | DO |
| **POLISH (B8)** | Re-add per-agent last-activity to `list`: read broker `last_activity_ts` from `registry.json` (better than the old scrollback-line heuristic). "alive · idle 2m" at a glance. | **S** | Low | Nice |
| **DEFER → browser (B1)** | `peek`/`capture`/`grep` over scrollback are a *fallback* for "what is on this agent's screen." The **authoritative** "what did this agent send/receive / what's in swarm-lounge" view is the browser reading broker JSON. Don't add an `inbox`/`rooms` reader to `c2c_tmux.py` — that's the browser's job. | — | — | BROWSER OWNS |

### B.3 KEEP / SUBSUME / CUT ledger (the opinionated bit)

**KEEP in `c2c_tmux.py` (the canonical WRITE/DRIVE tool):**
- `send` / `enter` / `keys` — PTY keystroke injection, with the live-vs-cached
  refusal (`c2c_tmux.py:237,251,271`) preserved. Browser delegates here.
- `exec` — `/proc`-walk foreground-TUI guard + `KNOWN_TUIS` classify
  (`c2c-tmux-exec.sh:93`). Irreducible safety gate for "run a command in this
  agent's shell."
- `launch` / `wait-alive` / `stop` — lifecycle. (Plus `restart`, ported in.)
- `layout` — exact-grid (`tmux-layout.sh`), useful for a deterministic
  monitoring window and a future "wall of agents."
- `whoami` — caller self-identification.

**SUBSUME into the browser (then shed from `c2c_tmux.py`):**
- `peek` / `capture` — broker JSON is the lossless replacement for message
  content. (Keep a thin `peek` as a fallback "show me the literal screen" — but
  it's no longer the primary way to see traffic.)
- `grep` (once ported) — the browser's cross-agent message search over
  `archive/*.jsonl` is lossless vs ANSI-grep over scrollback. `grep` in the
  write tool becomes a niche "grep the literal terminal" fallback.
- `list`'s roster — the browser's left pane (registry + tristate liveness + DND +
  compacting) is the richer roster. `c2c_tmux.py list` stays minimal (which pane
  is which alias) for the write tool's own use.

**CUT outright:**
- **`c2c-swarm.sh`** — entirely, after porting restart/grep/follow. It's a
  documented footgun to advertise two canonical harnesses (B2). Also remove the
  CLAUDE.md "Development Rules" line that lists it.
- **`peek-all` / `grep-echild`** — do NOT port. "All agents at once" and
  "across the swarm" are exactly the browser's whole-swarm live view; porting
  them into the write tool re-creates the scrollback-scraping anti-pattern the
  browser exists to retire.

**KEEP as-is, separate (test harnesses, not operator verbs):**
- `tui-snapshot.sh` — deterministic WxH render + scripted-keys + `capture-pane`.
  **This is the agent-readable visual-regression harness the new browser uses**
  (pairs with `ultra-tui-iteration`). Not an operator command; leave it.
- `tmux-layout.sh` — exact-grid layout primitive. Keep; `c2c_tmux.py layout`
  already wraps it.

### B.4 Migration sequencing (low-risk order)

1. **B7** factor the toggle (no behavior change; de-risks everything after).
2. **B3 restart** port — the highest-value miss; test the confirm-dialog path in
   a tmux pane per CLAUDE.md dev rules (`scripts/*`, not ad-hoc spawns).
3. **B5 grep + follow** port.
4. **DELETE `c2c-swarm.sh`** + strike from CLAUDE.md (atomic with #2/#3 so no
   capability gap).
5. **B4 registry-first identity**, **B6 launch non-stealing**, **B8 list idle
   hint** — independent polish, any order.
6. *After the browser ships:* shed `peek`/`capture`/`grep` from `c2c_tmux.py` to
   thin fallbacks; the browser is the canonical READ surface.

---

## Cross-cutting: language choice for the role-form tab (A3)

Carry the campaign's recommendation: **Python/Textual**, reusing the workflow TUI
skeleton (`~/.llm-general/ai-coding/codex/skills/workflow/scripts/workflow_tui*.py`).
The role-authoring tab is just another tab in that browser — pure-render form +
shell-out to `c2c roles compile` / `c2c agent refine`. **No OCaml curses form.**
The only OCaml work in this whole doc is A1 (embedded-fallback, S) and A2/A4
(refine no-tmux fallback + new-validation, S/M) — small, isolated, and worth
doing independent of the browser.

---

## Effort roll-up

| Item | Effort | Owner-language | Gate |
|------|--------|----------------|------|
| A1 embedded persona fallback | S | OCaml | independent |
| A2 refine no-tmux fallback | M | OCaml | independent |
| A4 new-validation (collision/.md/role-class) | S | OCaml | independent |
| A5 `c2c agent wizard` alias | S | OCaml | nice-to-have |
| A3 role-form tab | L | Python (browser) | after browser |
| B7 factor toggle | S | shell/py | independent, do first |
| B3 port restart | M | Python | before deleting swarm.sh |
| B5 port grep+follow | M | Python | before deleting swarm.sh |
| Delete `c2c-swarm.sh` | S | — | after B3/B5 |
| B4 registry-first identity | M | Python | independent |
| B6 launch non-stealing | S | Python | independent |
| B8 list idle hint | S | Python | independent |
