# Finding: GUI build fails without prior `bun install`

**Date**: 2026-05-03
**Filed by**: galaxy-coder
**Severity**: LOW (blocks `just gui-check`, not `just gui-dev`)
**Status**: FIXED — `bun install` resolves it

## Symptom

`just gui-check` (→ `bun run build` → `tsc && vite build`) failed with:
```
src/EventFeed.tsx(2,32): error TS2307: Cannot find module '@tanstack/react-virtual'
src/EventFeed.tsx(287,22): error TS7006: Parameter 'el' implicitly has an 'any' type.
src/EventFeed.tsx(379,39): error TS7006: Parameter 'virtualRow' implicitly has an 'any' type.
```

`gui-getting-started.md` listed this as a known gap with two items:
1. `@tanstack/react-virtual` not installed → run `bun install`
2. `just gui-check` fails: TS5101 baseUrl deprecation

## Root Cause

`bun install` had never been run in `gui/` after the project was cloned or after
`@tanstack/react-virtual` was added to `package.json`. The `node_modules/` directory
existed with partial dependencies, but `@tanstack/react-virtual` was absent.

The two implicit-`any` errors were **secondary effects** of the missing package: without
the library's type declarations installed, TypeScript couldn't resolve the `measureElement`
callback type or the `VirtualItem` type, causing `el` and `virtualRow` to default to `any`.

The TS5101 baseUrl note in the doc is **stale** — TypeScript 5.9.3 (installed via
`packageManager: bun@1.3.13`) does not emit TS5101 for `"baseUrl": "."` with
`"moduleResolution": "bundler"`. `tsc --noEmit` passes cleanly.

## Fix Applied

```bash
cd gui && bun install
```

Result: `just gui-check` now passes cleanly (`tsc && vite build` both succeed).

## Follow-up

- [ ] Update `gui-getting-started.md` known gaps: remove stale TS5101 note
  and mark `@tanstack/react-virtual` as installed (or document the `bun install` step
  as a required first-time setup).
- [ ] Consider adding `"preinstall": "bun install --frozen-lockfile"` to `package.json`
  or documenting `bun install` as a required first step in `gui-getting-started.md`.
  This prevents the same issue for future contributors.
