# Peer-review partial-build gap — #162 merge

- When: 2026-04-25 ~01:50 UTC+10 (during coordinator-pass merge of #162)
- Who: coordinator1 (fix); test-agent (peer-review gap); jungle-coder (original author)
- Severity: Medium — would have broken deploy if pushed unfixed
- Status: Fixed at 546995f

## Symptom

After merging `nudge-v3` into local master at `a18a36f`, building the full
binary set failed:

```
File "ocaml/server/c2c_mcp_server.ml", line 297, characters 2-13:
297 |   Relay_nudge.start_nudge_scheduler ~broker_root:root ~broker ();
        ^^^^^^^^^^^
Error: Unbound module Relay_nudge
```

`c2c.exe` built fine. Only `c2c_mcp_server.exe` (and anything else linking
`c2c_mcp`) failed.

## Root cause

`nudge-v3` branch added a new file `ocaml/relay_nudge.ml` but did not add
`Relay_nudge` to the `(modules ...)` list of the `c2c_mcp` library in
`ocaml/dune`. The file existed but was not part of the library, so the
server's `Relay_nudge.start_nudge_scheduler` reference was unresolved.

## Why peer-review didn't catch it

test-agent's peer-PASS on `caab0b1` built only `c2c.exe`. That target does
not import `Relay_nudge` (only the server does), so the link error never
surfaced in the reviewer's build. The reviewer reported "build OK" which
was technically true for the one target they built, but "build OK" is
ambiguous at the slice level.

## Fix

One-line addition to `ocaml/dune` at commit 546995f adding `Relay_nudge`
to the `c2c_mcp` library's `(modules ...)`.

## Lesson / design signal

This directly validates task #172 (structured peer-PASS artifact). A
signed review record should include:

- `targets_built: [c2c.exe, c2c_mcp_server.exe, c2c_inbox_hook.exe]`
- `targets_tested: [c2c tests, mcp tests, ...]`
- Criteria with explicit scope per criterion

Without that structure, a reviewer saying "build OK" is underspecified.
The coordinator-pass then re-does the full build and only catches the gap
if they happen to be thorough.

For jungle (original author): when adding an .ml file, registering it in
the appropriate dune `(modules ...)` list should be part of the same
commit. The build-success signal from one target doesn't cover it when
the module is imported elsewhere.

## Cross-links

- #162 (idle-nudge) — the slice
- #172 (signed peer-PASS) — the structural fix
- #171 (git-workflow surfacing) — adjacent; a pre-merge hook that runs
  `just install-all` (which builds all binaries) would have caught this
  structurally
