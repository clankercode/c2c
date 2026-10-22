# Independent Hermes distribution integration review

Reviewed `25e2b25eae23ca2846023322220248bb00ede7cf` against `d51e3bbd1d1a1cdb245ce5600f6405d4c7895eb3` on 2026-10-23.

## Findings fixed

- Checker used universal-newline text input for the embed but bytes for canonical files: identical CRLF distributions failed, and mixed LF/CRLF could falsely compare equal. Decode raw bytes instead; regression executes under `python3 -O`.
- Source inventory allowed only `.py`, `.yaml`, `.md`, silently omitting future runtime assets such as JSON. Inventory all regular files except Python bytecode/cache artifacts; add omitted-JSON regression.
- Existing ordering regression covered `just check` only. Also pin CI's read-only gate before `just build`.

Both checker regressions failed against the original committed checker in an isolated scratch copy (exactly two test failures), then passed against the fixed checker. No working-tree rollback or stash was used.

## Verification

- Focused distribution, justfile, native/runtime, styling/host and monitor suites: 79 tests run, 8 skipped, successful.
- `just check-hermes-distribution codegen-changelog-check` passed; distribution recipe ran its two tests successfully.
- `git diff --check` passed.
- Reviewed source/embed ownership, selected-ACK/DATA guidance and CI ordering. No runtime sender added; Telegram silence remains companion-owned.
- OCaml payload changes remain documentation/comments only, already built/tested by the originating worker; no additional full build or full repository check performed.
- AGENTS.md untouched; no approval-denial retry, push, release, install or live activation.
