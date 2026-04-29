# Pre-Existing Test Failures (2026-04-29)

**Filed by**: jungle-coder
**Date**: 2026-04-29
**Status**: Confirmed on `master` baseline; not regressions introduced by today's slices
**umbrella for**: #154 (launch_args 81), #155 (lookup 0), #156 (get_tmux_location 0)

---

## Summary

Three tests fail on a clean `origin/master` checkout. All three have appeared in peer-PASS receipts as "orthogonal to slice-under-test, pre-existing" for 4+ consecutive reviews. This doc catalogs them with root-cause hypotheses and fix pointers so any agent can pick one up as a follow-up slice.

---

## #154 — `launch_args 81` extra_args appended verbatim (reversed)

**Test name**: `launch_args 81` in `test_c2c_start.ml`
**Assertion**: Extra args `["--foo"; "bar"; "--baz"]` appended at END of cmdline
**Received**: `["--baz"; "bar"; "--foo"]` — reversed, appearing at BEGINNING
**First noticed**: peer-PASS receipts starting ~2026-04-29 morning

### Symptom
```
Expected: `["--foo"; "bar"; "--baz"]'
Received: `["--baz"; "bar"; "--foo"]'
```

### Root Cause Hypothesis
The `cmd_reset_thread_peers` path in `prepare_launch_args` constructs the command line and appears to prepend args instead of appending them, or reverses the order when building the final argv. The fix is likely in how extra_args are folded into the command — check the direction of `List.append` or `Array.append` call at the call site that handles the `cmd_reset_thread_peers` case.

### Hypothesis: where to look
- `c2c_start.ml` — search for `extra_args` usage in `prepare_launch_args`
- Specifically the `cmd_reset_thread_peers` case: args may be reversed in the `Array.concat` or `Cmdliner.Arg` construction
- Also check `last_n` usage in `test_c2c_start.ml:launch_args` around test 79 — the reverse bug was previously noted in `last_n` reverse in test 79

### Severity
**LOW** — cosmetic ordering issue; does not affect correctness of the launched command, only the position of extra args in argv.

### Fix scope
~5-10 lines. Identify the append/prepend call and correct the order.

---

## #155 — `lookup 0` known classes return Some (coder lookup)

**Test name**: `lookup 0` in `test_role_templates.ml`
**Assertion**: `Role_templates.lookup "coder"` returns `Some` starting with `"role_template_src|---"`
**Received**: `Some "---\ndescriptio"` — returning YAML frontmatter of actual role file
**First noticed**: peer-PASS receipts starting ~2026-04-29 morning

### Symptom
```
Expected: `Some "role_template_src|---"`
Received: `Some "---\ndescriptio"`
```

### Root Cause Hypothesis
`just codegen-role-templates` regenerates `role_templates.ml` from `.c2c/roles/` files. The codegen reads `.c2c/roles/builtins/templates/*.md.tmpl` files which use literal `role_template_src|---` inline template syntax. After a recent codegen run, the templates no longer use the `{role_template_src|...}` OCaml-quoted string format — instead they read the raw YAML frontmatter from the actual role files (which start with `---`).

The `Role_templates.lookup` function then returns the raw frontmatter string instead of the inline template body.

**Key fact**: `role_templates.ml` is auto-generated from `.c2c/roles/builtins/templates/*.md.tmpl` files. The `.md.tmpl` files may have been updated or the codegen logic changed, causing the inline `{role_template_src|...}` quoting to be replaced with raw frontmatter content.

### Hypothesis: where to look
- `just codegen-role-templates` recipe in `Justfile` — what files does it read?
- `.c2c/roles/builtins/templates/` — what template files exist and what format are they in?
- `ocaml/cli/c2c_role_templates.ml` (generated file) — check if `{role_template_src|...}` quoting is preserved
- The test expects `{role_template_src|...}` format in the lookup result — if codegen changed the format, either the test or the codegen is wrong

### Severity
**MEDIUM** — `Role_templates.render` and `Role_templates.lookup` are used by the agent-file compile pipeline. If lookup returns YAML frontmatter instead of the template body, agent files would include raw frontmatter instead of the actual template.

### Fix scope
~5-10 lines. Either fix the codegen to produce correct `{role_template_src|...}` format, or update the test expectation if the format intentionally changed.

---

## #156 — `get_tmux_location 0` exits non-zero when not in tmux

**Test name**: `get_tmux_location 0` in `test_c2c_start.ml`
**Assertion**: `env -u TMUX c2c get-tmux-location` exits with code 1 (not in tmux)
**Received**: exit code 0
**First noticed**: peer-PASS receipts starting ~2026-04-29 morning

### Symptom
```bash
$ env -u TMUX c2c get-tmux-location > /dev/null 2>&1
$ echo $?
0  # expected 1
```

### Root Cause Hypothesis
**Confirmed root cause**: the tmux shim (`git-shim.sh`) wraps `c2c` when invoked as a git subcommand. When `env -u TMUX c2c get-tmux-location` is run:

1. `env -u TMUX` unsets `$TMUX` but **not** `$TMUX_PANE`
2. `TMUX_PANE` remains set from the parent shell session
3. The shim detects `get-tmux-location` as a non-git subcommand and passes it through to the real binary
4. The real `c2c get-tmux-location` checks `TMUX_PANE` and `TMUX`:
   ```ocaml
   let pane_id = Sys.getenv_opt "TMUX_PANE" in
   let tmux_set = Sys.getenv_opt "TMUX" in
   match pane_id, tmux_set with
   | None, None -> exit 1  (* this branch not reached *)
   | _ -> (* exits 0 with pane info *) ...
   ```
5. Since `TMUX_PANE` is still set (but `TMUX` is unset), the match is `(Some _, None)` → exits 0

**The shim passes through the subcommand even when `TMUX` is unset**, because `TMUX_PANE` survives in the environment.

### Hypothesis: where to look
- `git-shim.sh` — the subcommand passthrough condition. It should also check `TMUX_PANE` or pass through only when both `TMUX` and `TMUX_PANE` are set.
- Alternatively: `c2c get-tmux-location` could be fixed to also unset `TMUX_PANE` in its own environment check (defense in depth)

### Severity
**LOW** — affects only the CLI test in tmux sessions; the subcommand works correctly when invoked directly (not through the shim). The shim's passthrough is overly permissive.

### Fix scope
~3-5 lines in `git-shim.sh`. Change the passthrough condition from checking only the binary name to also verifying `TMUX` is set (not just `TMUX_PANE`).

---

## Confirmation Procedure

To verify each failure on a clean checkout:

```bash
git checkout origin/master
just test 2>&1 | grep -E "\[FAIL\]"
```

Expected output:
```
[FAIL] launch_args 81 extra args appended verbatim
[FAIL] lookup 0 known classes return Some
[FAIL] get_tmux_location 0 get_tmux_location_exits_nonzero_when_not_in_tmux
```

All three are pre-existing and orthogonal to any slice under review.
