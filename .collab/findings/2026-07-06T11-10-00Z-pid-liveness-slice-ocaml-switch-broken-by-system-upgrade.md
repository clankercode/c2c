# System OCaml 5.4.1→5.5.0 upgrade broke the `c2c` opam switch (build down for all agents)

**Symptom.** `just build` failed in fresh worktrees two different ways depending
on ambient switch:
- `c2c` switch (the justfile-bootstrap one): dune 3.22.2 aborts parsing
  `/usr/lib/ocaml/re/dune-package` (`lang dune 3.23` — the system `ocaml-re`
  pacman package, installed 2026-07-05 21:50). Worse, the switch is
  `ocaml-system.5.4.1` but `/usr/bin/ocamlc` is now 5.5.0, so every installed
  lib (.cmi built with 5.4.1) is magic-number-incompatible anyway; opam's
  solver refused any install ("ocaml-system.5.4.1 no longer available").
- `clawq-5.1` switch (globally selected): missing `uucp`/`lambda-term`/`zed`.

**Root cause.** Host pacman upgrade on 2026-07-05 replaced system OCaml
5.4.1→5.5.0 and added `ocaml-re` with a dune-lang newer than the c2c switch's
dune. `ocaml-system` switches take their compiler from `/usr/bin`, so the
switch silently went inconsistent.

**Fix applied (2026-07-06, pid-liveness slice).**
1. `opam update`
2. `opam switch set-invariant ocaml-system --switch c2c --yes` (re-pins to 5.5.0)
3. `OPAMJOBS=2 opam upgrade --switch c2c --yes` (rebuilds all switch packages
   against 5.5.0; also pulls dune ≥3.23 so the system `re` dune-package parses)
4. Additionally installed `uucp lambda-term zed` into `clawq-5.1`, which made
   the repo build under the globally-selected switch too (this is how the
   builds in this slice ran: `opam switch show` = clawq-5.1).

**Residual risk / follow-ups.**
- Anyone with a long-running shell that cached the old opam env may still see
  stale behavior; `eval $(opam env)` or a fresh shell fixes it.
- The justfile assumes "current opam switch" is correct; consider pinning
  recipes to `--switch=c2c` (or documenting `eval $(opam env --switch=c2c
  --set-switch)`) so a foreign global switch can't silently change the
  toolchain.
- Watch for the next system OCaml bump — same failure mode will recur.

**Severity:** high (repo unbuildable until fixed), now mitigated.
