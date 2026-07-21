# B266 final evidence

Authoritative local-master tip: `ffc2529d` (`ffc2529dee6bc0eb1dbeec937ffd69a4db14d9f5`).

Key artefacts:

- `full-runtest-force.ffc2529d.log` — exact-tip forced repository run: exit 0; 162 Alcotest suites / 3442 tests; 4 custom suites / 93 tests; 166 / 3535 combined; zero hard failure markers.
- `dogfood-ffc2529d/` — exact-tip token-configured SQLite loopback health, anonymous-denial, and rollback-floor object checks.
- `security-db7bfbad-desktop.png`, `security-db7bfbad-mobile.png` — styled Jekyll render; docs product tree is unchanged at `ffc2529d`.
- `full-runtest-force.db7bfbad.log` — rejected pre-fix run that found the stale F5c `unknown_alias` fixture; retained as RED-test evidence.
- `full-runtest-force.8b700a64.log` — first green forced run after the F5c correction (`DUNE_EXIT: 0`).

Lineage: independently reviewed rollback-floor feature `da636143`; merge `db7bfbad`; F5c integration correction `8b700a64`; final backlog-only finding note `ffc2529d`.
