# B192: the `c2c-session` skill is real, Grok-specific, and intentional

**Status:** resolved (investigation; no code change needed)
**Severity:** none — working as designed
**Task:** B192 ("c2c-session skill; where is it referenced and do we need it? grok
likes to call it. not sure if it's a real skill or how it's injected into the client.")

## Symptom / question

Grok sessions frequently invoke a skill named `c2c-session`. It was unclear
whether this was a real skill, a hallucinated name, or something injected.

## Answer

It is a **real, generated, per-session identity skill for Grok**, and we need it.

- **Why it exists:** Grok Build has no `additionalContext` injection path
  (unlike Claude hooks), so the only way to put the session's live alias +
  session id in front of the model at session start is to write it into a
  skill whose *description* carries the identity.
- **How it's injected:** `c2c install grok` writes the SessionStart/SessionEnd
  hook config `~/.grok/hooks/c2c-session.json` → the hook runs `c2c hook grok`
  → which auto-registers the session (`registered_by=grok-hook`), refreshes the
  `/c2c` skill, and **rewrites `~/.grok/skills/c2c-session/SKILL.md`** with the
  live alias/session id. See `ocaml/cli/c2c_hook_cmd.ml:1308` (doc string) and
  `ocaml/cli/c2c_setup.ml` (`grok_session_skill_dir` ~line 108, skill body
  ~line 130, hooks json ~line 1910).
- **Grok "liking to call it" is intended:** the description surfaces the alias
  in Grok's skill list; invoking it loads the short onboarding body (load
  `/c2c`, arm `Monitor` with `c2c monitor`, prefer CLI sends). The body
  self-heals: "trust `c2c whoami` if this drifts."
- **Lifecycle is fully tracked:** `c2c uninstall grok` removes
  `~/.grok/skills/c2c-session/` and `~/.grok/hooks/c2c-session.json`
  (`ocaml/cli/c2c_uninstall.ml:446-447`); `c2c health` checks the hook file
  (`ocaml/cli/c2c_health_cmd.ml:220`). Tests: `test_c2c_setup_grok.ml`,
  `test_c2c_hook_grok.ml`.
- **Docs already cover it:** `docs/client-delivery.md` (§Grok),
  `docs/clients/feature-matrix.md`, `docs/commands.md` (install/uninstall
  rows), `docs/llms-grok-install.txt`.

## Name-collision footnote (the confusing part)

Three distinct artifacts share the `c2c-session` string; only the first is the
Grok skill:

| Artifact | Client | What it is |
|---|---|---|
| `~/.grok/skills/c2c-session/SKILL.md` | Grok | generated identity skill (this finding) |
| `~/.grok/hooks/c2c-session.json` | Grok | hook config that regenerates the skill |
| `~/.claude/hooks/c2c-session-hook.sh` | Claude | unrelated SessionStart/SessionEnd hook script |

## Conclusion

No bug, no removal. Keep as-is. If future confusion recurs, the only candidate
improvement is renaming the Claude hook script to reduce the name collision —
not worth the churn now.
