# #423 — TUI role-creation flow produces inadequate role file

**Author:** cairn-vigil (coordinator1)
**Date:** 2026-04-29
**Status:** design / proposing fix
**Related:** #413 (canonical onboarding boilerplate), #378 (jungle's onboarding feedback), #390 (auto_join convention), cedar-coder.md (manually-rescued exemplar)

---

## Symptom

`cedar-coder` was created via `c2c start <client>` and the resulting
role file lacked first-5-turns guidance, peer-PASS rule, heartbeat
Monitor recipe, and `just --list` pointer. Cairn manually rewrote it
from the slate-coder template before cedar joined the swarm.

## Two distinct code paths — both broken

There is no single "TUI role-creation flow." There are **two** entry
points and both produce sub-canonical files:

### Path A — `c2c start <client>` cold start (no role file)

`ocaml/cli/c2c.ml:6307` `prompt_for_role`:

```
[c2c start] No role file found for alias 'cedar-coder'.
  What is this agent's role? (e.g. coder, planner, coordinator — press Enter to skip)
  > coder
```

Then `write_role` (`c2c.ml:6288`) emits a 4-line frontmatter +
**literal user-typed string** as the body:

```yaml
---
description:
role: subagent
---
coder
```

That's it. No template lookup. No `role_class:`. No
`auto_join_rooms`. No #413 boilerplate. Word "coder" becomes the
entire system prompt body.

### Path B — `c2c agent new` interactive

`ocaml/cli/c2c_agent.ml:126` `agent_new_interactive` is more
substantial — prompts for description, role type, compatible
clients, theme, snippets (from `.c2c/snippets/`), auto_join_rooms.
But the body it writes (`c2c_agent.ml:278-300`) is:

```
You are a <name> agent.
Your responsibilities:
- TODO: list primary responsibilities
- TODO: add more as needed
```

Snippet include is opt-in (user must remember to pick `monitors-setup`,
`c2c-basics`, `recovery`); none of the four snippets together cover
the full #413 boilerplate (no first-5-turns, no peer-PASS rule, no
`just --list` block). And `prompt_for_role` (Path A) doesn't even
plumb to `agent_new_interactive` — totally separate code paths.

## Root cause

#413 landed canonical boilerplate **as documentation in
`role-designer.md`** (the meta-agent's prompt — `role_designer_embedded.ml:76-124`).
That tells the role-DESIGNER agent what to write, but neither
`prompt_for_role` nor `agent_new_interactive` consult it when
generating files programmatically. The boilerplate exists only as
prose instructions to a downstream LLM, not as substitutable
template strings the CLI can emit.

Symptom: anyone who hits cold-start (Path A) or skips snippet-pick
in Path B gets a stub. Slate/Cedar/Stanza only look canonical
because Cairn hand-authored them.

## Three fixes ordered by impact

### A. CLI always emits canonical template, fills role-class blanks  ★ recommended

Bake the #413 boilerplate into a `coder.md.tmpl` /
`coordinator.md.tmpl` / `subagent.md.tmpl` set under
`.c2c/roles/builtins/templates/` (or embedded via codegen like
`role_designer_embedded.ml`). Both Path A and Path B select a
template by `role_class`, substitute `{alias}`, `{role_class}`,
`{peers}`, and write the result. User-supplied prose appended in a
"Custom notes" section if Path B's interactive mode collected any.

**Pros:** every new agent boots with first-5-turns + peer-PASS +
heartbeat verbatim. Self-fixes Path A (which today gives 4 lines).
Templates can be peer-reviewed once and inherited forever.

**Cons:** a real templating decision (string substitution vs.
include-snippet composition). Need a dedupe story when role file
already exists and we're regenerating.

### B. Show diff vs. canonical & ask "expand?"

After Path A/B writes its stub, diff it against the closest
canonical template (e.g. `slate-coder.md` for `role_class: coder`)
and prompt: "Your role file is 4 lines vs. canonical 89. Expand
with #413 boilerplate? [Y/n]".

**Pros:** preserves user-supplied content; opt-in.
**Cons:** diff UX in TTY is awkward; non-interactive cold-start
(`c2c start` from a script) can't answer Y; deferred friction.

### C. Drop TUI; add `c2c start --role-template coder` flag

Replace the cold-start prompt with a hard error: "no role file for
alias X; create one with `c2c agent new <name> --template coder`".
Path A becomes a redirect.

**Pros:** simplest code; one obvious path.
**Cons:** breaks the gentle onboarding ramp Max designed (a fresh
agent who runs `c2c start claude` shouldn't hit a wall). Loses the
TTY interview affordance. Doesn't fix Path B's stub-body problem.

## Recommendation: **Fix A**

Fix A subsumes the wins of B and C: Path A becomes useful by
default, Path B inherits the same template engine, the role-designer
meta-agent prompt (#413) becomes the source-of-truth that the CLI
**also** consults — collapsing the two-source drift.

## Implementation slice (~120 LOC, one worktree)

**Files:**

1. `.c2c/roles/builtins/templates/coder.md.tmpl` — new file. Body
   copied verbatim from `slate-coder.md` lines 24-227, with `{alias}`
   placeholder where `slate-coder` appears literally and a
   `{display_name_hint}` placeholder for the `Slate is the easy
   default` paragraph. ~200 lines of markdown.
2. `.c2c/roles/builtins/templates/coordinator.md.tmpl` — derived
   from `coordinator1.md` with placeholders. ~150 lines.
3. `.c2c/roles/builtins/templates/subagent.md.tmpl` — leaner, no
   peer-PASS section but keeps first-5-turns + heartbeat. ~60
   lines.
4. `ocaml/cli/role_templates_embedded.ml` — new, codegen'd by `just
   codegen-role-templates` (mirrors `role_designer_embedded.ml`
   pattern). Exposes `let templates : (string * string) list`
   keyed by role_class.
5. `ocaml/cli/c2c.ml:6307` `prompt_for_role` — replace body
   construction:
   ```ocaml
   let role_class = String.trim line in   (* "coder" / "planner" / ... *)
   let body = Role_templates_embedded.render
                ~role_class ~alias ~display_name_hint:"" in
   ...{ role with role_class = Some role_class; body; ... }
   ```
   Set `c2c_auto_join_rooms = ["swarm-lounge"; "onboarding"]` when
   role_class matches a known peer class (#390). ~25 LOC delta.
6. `ocaml/cli/c2c_agent.ml:278-300` — replace the inline `tmpl`
   sprintf with `Role_templates_embedded.render`. Snippet include
   stays as additive composition. ~20 LOC delta.
7. `justfile` — add `codegen-role-templates` recipe. ~5 LOC.
8. `ocaml/cli/test_c2c_onboarding.ml` — extend with two cases:
   (a) Path A cold-start with role_class="coder" produces a body
   containing literal "First 5 turns", "Self-review-via-skill is
   NOT a peer-PASS", and the verbatim `Monitor({ description:
   "heartbeat tick"...` block; (b) Path B `agent new --role coder
   -d "..."` does the same. ~40 LOC.

**Sequencing (one worktree, 4 commits):**

1. Land template files + codegen recipe + embedded module (no
   wiring yet — green build).
2. Wire Path A (`prompt_for_role`) + onboarding test (a). Install,
   dogfood by deleting a test role file and running `c2c start`
   against a fake alias.
3. Wire Path B (`agent_new_interactive`) + onboarding test (b).
4. peer-PASS DM to a real swarm peer, then coord cherry-pick.

**Out of scope for this slice:**

- Migrating existing minimal role files (cedar already manually
  rescued; others can be re-rescued one-by-one).
- Localising templates — keep English-only.
- `c2c agent refine` integration (separate slice once template
  engine is stable).

## Verification

After install:

```
rm -rf /tmp/c2c-test-role && mkdir /tmp/c2c-test-role
cd /tmp/c2c-test-role && git init && git remote add origin <url>
c2c agent new test-coder --role coder -d "test slice" --no-interactive
grep -c "First 5 turns" .c2c/roles/test-coder.md   # expect 1
grep -c "Self-review-via-skill is NOT a peer-PASS" .c2c/roles/test-coder.md   # expect 1
grep -c "heartbeat tick" .c2c/roles/test-coder.md   # expect ≥1
```

Same shape for Path A via `printf "coder\n" | c2c start claude
--name foo --alias foo-coder` (wrapped in `expect` or feed via
heredoc).

## Open question

Should the role-designer meta-agent (`role_designer_embedded.ml`)
also call into `Role_templates_embedded.render` so the LLM-authored
flow and the CLI-emitted flow share one canonical template body?
Probably yes, but that's a follow-up — the meta-agent currently
generates per-role custom prose, and collapsing it to template-fill
would change its character. Park for #423b.

---

— cairn-vigil
