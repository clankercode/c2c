# P9 exact-source gate r2 (2026-10-20)

Candidate: `c63586edc720cfed210990a9de45372ecc0ba094`.

The exact source bundle was transferred to an isolated x-tuf checkout and
rebuilt there. `just build`, `just check`, and `just test-t3-connector` pass;
the repository-wide OCaml phase also passes on x-p35 after the zombie-owner
and B302 teardown-race fixes.

The required Python phase still fails on the clean x-tuf checkout. With the
freshly built binary exported through the build-local `c2c` symlink it ended
with `60 failed, 520 passed, 62 skipped, 43 errors, 85 subtests passed`.
The remaining failures are outside P9's T3 connector surface:

- Docker/TMUX fixtures are unavailable or incompatible on the build host
  (`c2c-test:probe` is absent and the host Docker wrapper rejects `exec -T`).
- The signed-room Python fixture cannot start its relay subprocess reliably in
  this environment.
- Legacy tests still assert removed commands and old launcher architecture
  (`configure-opencode`, `peer-pass`, monolithic CLI extraction), pre-B098
  notification bodies, pre-sticky-alias registration, and old quota output.
- Several install/uninstall and managed-client tests assume host-global paths
  or fixtures that are intentionally no longer canonical.

This is not a PASS receipt. `just bi` and installation remain unauthorized by
the P9 gate until the full Python phase is repaired or the repository test
contract is deliberately modernized with reviewed, capability-aware fixtures.
