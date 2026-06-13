# Verification: `configure_claude_hook` is dead + superseded (SAFE TO DELETE)

**Date:** 2026-06-13 · **Method:** 3 independent adversarial refuters (reachability /
supersession / blast-radius), each trying to prove deletion is *unsafe*. **Result:**
none refuted — high confidence. Verifies removal item A6 / the C-list in `03`.

## Verdict: safe to delete `ocaml/cli/c2c_setup.ml:1006` `let configure_claude_hook ()`

- **Reachability:** ZERO callers. No direct call, no qualified `C2c_setup.configure_claude_hook`,
  no value/partial-application, no Cmdliner/subcommand wiring, no dune/test reference. The two
  test modules that link `c2c_setup` don't touch it. `c2c_setup` has no `.mli`, so it's
  technically module-exported, but nothing consumes it. **`git log -S` proves it was NEVER
  called as a statement in any commit** — even pre-extraction it was an orphan `let` in `c2c.ml`.
- **Supersession:** live path `c2c.ml:7003 → do_install_client (c2c_setup.ml:1590) → setup_claude
  (writes hooks inline)` is a **strict superset**: same two scripts (`c2c-inbox-check.sh`,
  `c2c-stop-deliver.sh`) from the same constants (`claude_hook_script`@933,
  `claude_stop_hook_script`@970), same `chmod 0o755`, same matcher `^(?!mcp__).*`, same
  PostToolUse + Stop registration — **plus** `CLAUDE_CONFIG_DIR`-aware (`resolve_claude_dir`),
  dry-run, content-idempotency, install-manifest, and an extra PreToolUse permission hook. The
  dead function hardcodes `~/.claude/hooks` (the inferior old behavior).
- **Blast radius:** the two shared hook-script constants stay referenced by the live path →
  deletion orphans nothing.

## Caveats for the deleter
1. **One dormant behavior is unique to the dead function:** it consolidates a legacy `".*"`
   matcher group into the canonical matcher (c2c_setup.ml ~1044-1051). Zero callers ⇒ not
   running ⇒ deleting loses no live behavior. If that consolidation is ever wanted, port that
   single branch into `setup_claude`.
2. **Fix stale docs on deletion:** the 2026-04-14 finding (which wrongly says it was wired into
   `setup_claude`) and `.collab/runbooks/511-s3-claude-pretultuse-smoke.md:124` (wrongly
   attributes PreToolUse to it).

Full refuter output: workflow `wf_535db3d4-99f` (task `wp9i5rod6`).
