# Subagent opam invocation downgraded shared switch — all builds broke mid-swarm

**Symptom.** `just build` started failing repo-wide at ~20:39 AEST 2026-07-06:
`Unbound type constructor Cohttp_lwt_unix.Server.response` (ocaml/relay.ml:2426),
then after partial repair `c2c_init_cmd.ml:595` type error against old Cmdliner.
Master and every slice worktree affected simultaneously; the same trees had
built green minutes earlier.

**Root cause.** A subagent opam invocation at 20:29 mutated the ACTIVE shared
opam switch `clawq-5.1`, downgrading ~53 packages — notably cohttp 6.1.1→5.3.1
and cmdliner 2.1.0→1.3.0. The repo's code targets the 6.x/2.x APIs. A second
subagent then started `opam upgrade --switch c2c --yes` against the stale,
near-empty `c2c` switch (irrelevant to builds; killed). Neither agent reported
the opam action to the coordinator; the breakage surfaced as an apparently
unrelated compile error in a file none of the slices touched.

**Recovery (worked, keep for next time).** opam snapshots switch state before
mutating ops: `~/.opam/<switch>/.opam-switch/backup/state-<ts>.export`. The
20:28 export predated the damage; restore was:

```
OPAMJOBS=2 opam switch import --switch clawq-5.1 \
  ~/.opam/clawq-5.1/.opam-switch/backup/state-20260706102803.export --yes
```

(~2 min: packages were still in the local cache.) `just build` rc=0 after.

**Contributing confusions.**
- Two switches exist: `clawq-5.1` (active, real) and `c2c` (name suggests it's
  the repo's switch, but it's stale/near-empty). Agents that hit a build error
  plausibly reason "wrong switch, fix the c2c one" — exactly what happened.
- The justfile builds via bare `opam exec --` = ambient switch, so switch
  identity is invisible unless you go looking.

**Guardrails (proposed).**
1. Rule for CLAUDE.md / subagent prompts: **never run mutating opam commands**
   (install/upgrade/remove/switch import) — report env breakage to coordinator.
2. Remove or rename the decoy `c2c` switch, or populate it and pin the justfile
   to it explicitly (`opam exec --switch <x> --`), making builds
   switch-deterministic.
3. `c2c doctor` could pin + verify expected versions of load-bearing packages
   (cohttp, cmdliner, lwt) and flag drift with the restore recipe above.

**Severity:** high — silent, global, and it masquerades as a code bug in
whatever file the compiler reaches first; cost ~25 min of coordinator time and
stalled two fix slices.
