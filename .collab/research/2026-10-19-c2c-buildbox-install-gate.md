# Buildbox validation before c2c installation

Date: 2026-10-19. Read-only source review by a delegated researcher; recorded
by the coordinator. No SSH, builds, tests or installs ran in this review.
Source root: `/home/xertrov/src/c2c`, HEAD
`e655cd267de34c277d655a288ec2013ff3cc8fc9`.

## Why installation requires a separate gate

- `justfile:600`: `bi` aliases `install-all`.
- `justfile:562-597`: installation generates sources, compiles eight targets,
  then copies binaries under a single flock. It does not run tests.
- `justfile:406`: `just test` includes build, OCaml, Python, TS and npm tests.
- `justfile:348`: OCaml tests lack `--force`; cached success is insufficient
  when reporting the full gate. Add a forced repository-wide `@runtest`.
- `justfile:473-497`: `just check` includes generated-source, supervisor,
  build, broker-log catalogue and documented-command checks.
- `justfile:440`: `test-slice` omits MCP coverage and is not the full test
  gate; there is no `test-remote` recipe in this repository.

## Exact-source procedure

Commit the intended source/generated files; record full commit/tree. Transfer
with a Git bundle rather than a deploy-triggering push. Use an isolated clone
and a pinned worktree beneath its `.worktrees/` on x-p35 or x-tuf. Preserve
unrelated work, and do not copy stale `_build`, credentials or source-tree
dependency caches.

Record architecture, compiler, Dune/opam switch, Python, Node/npm and dependency
versions. `dune-project:1` requires Dune language 3.21; `justfile:14` provides
`setup-ocaml`. From the pinned root, with Bash `set -euo pipefail`, run and
record separate exit codes/logs outside the checkout:

```sh
just build
just check
just test
PATH="$PWD/_build/default/ocaml/cli:$PATH" \
  scripts/dune-build-locked.sh build @runtest --force
scripts/dune-build-locked.sh build -j1 ./ocaml/cli/c2c.exe ./ocaml/cli/c2c_deliver_inbox.exe ./ocaml/server/c2c_mcp_server.exe ./ocaml/server/c2c_mcp_server_inner_bin.exe ./ocaml/tools/c2c_inbox_hook.exe ./ocaml/tools/c2c_stop_hook.exe ./ocaml/tools/c2c_cold_boot_hook.exe ./ocaml/tools/c2c_post_compact_hook_bin.exe
```

The explicit target list is copied from `justfile:566`: `just build` lists
fewer executables. Retain the repository Dune wrapper; it selects the right
worktree, uses opam, serializes and bounds builds
(`scripts/dune-build-locked.sh:74,490`). A timeout or lock failure is not PASS.

Reject tracked generator drift or unexpected untracked sources. Commit fixes
and rerun on the new candidate. Record the ignored
`.opencode/package-lock.json` and resolved dependency versions as separate
evidence (`.gitignore:40`). A failing baseline, missing required test, or
unexplained skip cannot satisfy the user's all-success requirement.

Save a PASS receipt with source/toolchain identity, commands/exits, suite
results and all eight binary hashes. Only then run, where installation is
required, from the same pinned source:

```sh
C2C_VALIDATION_RECEIPT=/absolute/path/to/buildbox-pass.json C2C_SKIP_RESTART_PROMPT=1 just bi
```

The receipt option above is planned work in P9.M1.E1.T007, not an existing
guard capability. It must compare the preserved successful source/dependency
and all-eight-artifact manifest inside the install flock, after the rebuild
and before any copy. A changed generator or binary must not become the new
expected value without revalidation. Ordinary installs stay compatible;
this rollout always passes the receipt. Tests must cover mutation/refusal.

Do not bypass installation guards with `C2C_INSTALL_FORCE=1`. The prompt flag
avoids offering a restart of unrelated sessions
(`scripts/c2c-post-install-restart-prompt.sh:7`). Another host's binary need not
hash identically when its toolchain differs, but must match its own recorded
artifact; full tests are needed for unvalidated platform/dependency differences.

## Verify installed and running artifacts separately

- Compare every installed binary to its build artifact and the preserved PASS
  manifest, then recheck clean source/tree; neither mutable build output nor
  version text alone proves the tested candidate was installed.
- Check the install stamp's source SHA/hashes; supplement its incomplete
  executable coverage with the full manifest
  (`scripts/c2c-install-stamp.sh:30`).
- Check `c2c --version`, T3 help, doctor, unit paths and the actual running
  process executable hash. Installing bytes does not update an existing process
  (`scripts/c2c-install-live-holders.sh:90`).
- Start/restart only the intended connector, then run the disposable two-host
  delivery/recovery matrix. Do not restart the user's T3 server or unrelated
  managed agents.

Actual buildbox toolchains and alternative installation locations remain to be
verified. Prior read-only runtime preflight found T3 active on x-p35/x-tuf;
it did not establish a successful candidate build, tests or installation.
