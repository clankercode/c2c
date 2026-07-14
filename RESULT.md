# RESULT — B190 glibc floor for Linux releases

**Branch:** `fix/bl-b190`  
**Worktree:** `/home/xertrov/src/c2c/.worktrees/bl-b190`  
**Status:** implemented + self-reviewed; **not** merged; **not** `bl done`

## Problem

Official `c2c` Linux binaries (v0.12.0 built on GHA `ubuntu-latest`) require
**GLIBC_2.38**, so they fail on Ubuntu **20.04** and **22.04**. Host-built
binaries on rolling distros can require **GLIBC_2.42** and fail even on
Ubuntu 24.04. Dynamic deps: `libsqlite3`, `libgmp`.

## Fix (MVP)

| Item | Change |
|------|--------|
| Release runners | `linux-x64` → `ubuntu-22.04`; `linux-arm64` → `ubuntu-22.04-arm` |
| GLIBC ceiling | matrix `max_glibc: '2.35'` + `scripts/check-glibc-max.sh` on all shipped ELFs |
| Docker smoke | `ubuntu:22.04` / `arm64v8/ubuntu:22.04` + `libsqlite3-0` `libgmp10` → `/c2c --version` |
| Installer | `docs/install.sh` preflights host glibc ≥ 2.35 (and musl) **before** self-update; verifies extracted binary before install |
| Docs | get-started system requirements; known-issues section; release-workflow policy; changelog Unreleased + PENDING |
| Tests | `test/test_check_glibc_max.sh`, `test/test_install_sh_glibc_floor.sh` |

## Residual (documented, not solved)

- Ubuntu 20.04 (glibc 2.31) and musl still need **local source builds**.
- No manylinux / fully-static artifact yet.
- Host `just install-all` still inherits builder glibc (warn in docs).
- Doctor OCaml path N/A when loader cannot start the binary; installer is the user-facing gate.

## Verification

```text
./test/test_check_glibc_max.sh          → 9 passed
./test/test_install_sh_glibc_floor.sh   → 12 passed
sh -n / bash -n docs/install.sh         → ok
./scripts/check-glibc-max.sh 2.35 ~/.local/bin/c2c → rc=1 (host needs 2.42; script works)
```

Full release compile on ubuntu-22.04 is gated to GHA release workflow (not run locally).

## Commits / SHAs

| Ref | SHA |
|-----|-----|
| Fix commit | `8c735d6c151f5eedc36ec2d165fcd69091c0ba1b` |
| Short | `8c735d6c` |
| Branch tip | `fix/bl-b190` @ `8c735d6c` |
| Parent (claim base) | `0e2559d7` |

```text
8c735d6c fix(B190): lower Linux release glibc floor to 2.35 (Ubuntu 22.04)
```

## Review

- **pirfl:** `.pirfl/B190-glibc-floor.md`
- **review-and-fix:** self-pass on AC (runner pin, ceiling script, smoke step,
  installer messaging, docs, tests). External gpt-5.5 peer review not invoked
  in this subagent session (no peer harness); treat self-PASS as author
  review only, not coordinator peer-PASS.
