# B190 — Linux release glibc floor

## Goal

Ship official Linux c2c binaries that run on Ubuntu 22.04+ (glibc ≤ 2.35
symbols), gate that floor in CI, document runtime deps, and fail install with
a clear message on older hosts. Ubuntu 20.04 / manylinux-static deferred.

## Plan

1. Pin release Linux runners to `ubuntu-22.04` / `ubuntu-22.04-arm`.
2. `scripts/check-glibc-max.sh` + release matrix `max_glibc: 2.35`.
3. Docker smoke: floor image + libsqlite3/libgmp → `c2c --version`.
4. `docs/install.sh` preflight + post-extract verify.
5. Docs: get-started, known-issues, release-workflow, PENDING changelog.
6. Tests for check script + install floor helpers.
7. Self review-and-fix; commit on `fix/bl-b190` only (no merge / no bl done).

## Constraints

- Work only in this worktree / branch.
- No push unless needed; no `bl done`.
- MVP: lower floor via older runner + docs + CI; not full static linking.

## Log

- Investigation already confirmed: release 0.12.0 needs GLIBC_2.38; host
  build needs 2.42; 22.04 fails release; 20.04 fails both.
- Prior unmerged experiment `4228229f` on `glibc-compat-investigation`
  (ubuntu-22.04 + inline objdump). Re-implemented with shared script,
  arm64 parity, docker smoke, installer, docs, tests.
- Self-review (adversarial):
  - **FIXED:** glibc check must run *before* self-update so Ubuntu 20.04
    host-builds are not replaced by a non-starting release asset.
  - **OK:** `ubuntu-22.04-arm` is a current GHA label (runner-images README).
  - **OK:** darwin matrix entries omit `max_glibc` / `smoke_image`;
    conditionals skip cleanly.
  - **ACCEPT residual:** no doctor OCaml change — binary cannot start if
    glibc too old, so installer is the right surface.
  - **ACCEPT residual:** 20.04 / musl still local-build only.
- Tests: `test/test_check_glibc_max.sh` 9/9; `test/test_install_sh_glibc_floor.sh` 12/12.
- Host binary correctly fails `check-glibc-max.sh 2.35` (max GLIBC_2.42).
