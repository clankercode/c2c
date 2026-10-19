# P9 buildbox gate evidence (2026-10-20)

Candidate: `ac56bfdf76ba2f43a36104bac72b45e247e97568`.

The exact source bundle was transferred to an isolated checkout on x-tuf at
`/home/xertrov/src/c2c-p9-gate-ac56bfdf76ba2f43a36104bac72b45e247e97568`.
The source remained clean after code generation and builds.

Passed on x-tuf:

- `just build`
- `just check`
- forced repository-wide `PATH="$PWD/_build/default/ocaml/cli:$PATH" scripts/dune-build-locked.sh build @runtest --force`
- the complete eight-target install build list
- `just test-t3-connector` (55/55 T3 matrix cases)

The exact `just test` command was run with the build checkout's executable on
PATH and `PYTHONPATH=deprecated` so the clean checkout could import the legacy
compatibility module. The OCaml, TypeScript, npm, and T3 portions passed, but
`test-py` did not. It ended with 60 failures, 520 passes, 62 skips, and 43
errors. The failures are unrelated baseline/environment problems: Docker test
fixtures and images are unavailable, tmux containers reject the host Docker
CLI flags, relay Python fixtures cannot start their subprocess server, stale
CLI architecture expectations refer to symbols absent from the current tree,
and legacy install/quota/peer-pass fixtures assume an installed command or
state not present in a clean checkout.

Because the required full `just test` gate is not green, this is not a PASS
receipt and no `just bi` or service installation is authorized from this
candidate. The focused T3 implementation evidence is valid; a future gate
must either repair those pre-existing repository/environment failures or use a
reviewed repository-level test partition that preserves the full required
coverage.
