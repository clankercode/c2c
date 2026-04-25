# Deliver daemon "unavailable" for `c2c start codex` — root cause

**Date:** 2026-04-25T11:20:00Z
**Reporter:** stanza-coder
**Severity:** medium
**Status:** root cause found, fix proposal below

## Symptom

`c2c instances` shows `unavailable` for any `c2c start codex` instance started
without `--binary`. Example: `smoke-codex codex running unavailable (pid ...)`.

Lyra-Quill-X shows `xml_fd (pid 641257)` because it was started with
`--binary /home/xertrov/.local/bin/codex` (stored in its `config.json`).

## Root Cause

`codex_supports_xml_input_fd` in `ocaml/c2c_start.ml:2012` checks whether
`codex --help` mentions `--xml-input-fd`. The binary resolved from PATH is:

```
/home/xertrov/.bun/bin/codex   # v0.125.0   — NO --xml-input-fd
/home/xertrov/.local/bin/codex  # v0.125.0-alpha.2 — HAS --xml-input-fd
```

The stable release (0.125.0) doesn't have `--xml-input-fd`. The alpha (0.125.0-alpha.2)
does. When no `--binary` override is passed, `c2c start codex` picks up the stable
bun-installed release, the capability check fails, `Codex_xml_fd` is not set,
and the deliver mode falls to `unavailable`.

## Impact

- No deliver daemon started → no permission forwarding for codex sessions
- Also means the #194 permission forwarding fix cannot fire even when working

## Fix Options

**Option A (quickest):** Add per-client binary overrides to `.c2c/config.toml`:
```toml
[default_binary]
codex = "/home/xertrov/.local/bin/codex"
```
and have `c2c_start.ml` read this as the default binary when no `--binary` is
passed. This keeps it repo-local and doesn't require touching PATH.

**Option B:** Document that `c2c install codex` should detect and record the
best codex binary (one that supports `--xml-input-fd`), writing it to the
instance config or the repo config.

**Option C (band-aid):** Update PATH so the alpha binary is first. Not a code
fix.

## Recommended

Option A — add `[default_binary]` table to `.c2c/config.toml` and read it in
`c2c_start.ml` before falling back to `cfg.binary` (the client config's binary
name). Small config read + one optional lookup. Makes `c2c start codex` DTRT
out of the box for this machine's setup.

## Verification

After fix: `c2c start codex -n test-xy` should show `xml_fd` in `c2c instances`.
