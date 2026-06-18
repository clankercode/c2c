# npm Binary Packages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a self-contained `npm-pkgs/` implementation that can publish c2c-owned npm binary packages and expose a JS resolver for downstream packages.

**Architecture:** `npm-pkgs/c2c/` is the source meta package with a CommonJS resolver and bin wrapper. `npm-pkgs/scripts/stage-npm-packages.js` copies the meta package and supplied release binaries into `dist/npm/` platform package directories with npm `os`/`cpu` filters. Tests use Node's built-in `node:test` runner and fake binaries, avoiding repo-wide JS dependency changes.

**Tech Stack:** Node.js CommonJS, npm package metadata, Node built-in `node:test`, `child_process.spawnSync`, `fs`, `path`.

---

### Task 1: Resolver and Wrapper

**Files:**
- Create: `npm-pkgs/c2c/package.json`
- Create: `npm-pkgs/c2c/index.js`
- Create: `npm-pkgs/c2c/bin/c2c-js-wrapper.js`
- Test: `npm-pkgs/c2c/test/resolve-c2c-binary.test.js`

- [ ] **Step 1: Write failing tests**

Tests cover `C2C_BIN`, PATH lookup, ignoring the wrapper itself, platform package fallback, unsupported platform errors, and wrapper exit-code propagation.

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test npm-pkgs/c2c/test/*.test.js`

Expected: FAIL because `npm-pkgs/c2c/index.js` does not exist yet.

- [ ] **Step 3: Implement resolver and wrapper**

Expose `resolveC2cBinary(options)` and a private `_platformPackageName(platform, arch)` helper. The wrapper should spawn the resolved binary with inherited stdio and exit with the child's status or signal-derived status.

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test npm-pkgs/c2c/test/*.test.js`

Expected: PASS.

### Task 2: Staging Script and Platform Package Metadata

**Files:**
- Create: `npm-pkgs/scripts/stage-npm-packages.js`
- Test: `npm-pkgs/test/stage-npm-packages.test.js`

- [ ] **Step 1: Write failing tests**

Tests create fake release binaries and assert the staged `dist/npm/` tree contains a meta package, five platform packages, executable payload names, npm `os`/`cpu` filters, and optional dependencies matching the meta version.

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test npm-pkgs/test/*.test.js`

Expected: FAIL because the staging script does not exist yet.

- [ ] **Step 3: Implement staging script**

The script accepts `--version`, `--binary-root`, and `--out-dir`; creates `c2c`, `c2c-linux-x64`, `c2c-linux-arm64`, `c2c-darwin-x64`, `c2c-darwin-arm64`, and `c2c-win32-x64`; copies binaries from names matching each package directory; and writes package JSON.

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test npm-pkgs/test/*.test.js`

Expected: PASS.

### Task 3: Developer Entry Points and Verification

**Files:**
- Modify: `justfile`
- Create: `npm-pkgs/README.md`

- [ ] **Step 1: Add a failing command-level check**

Run: `just npm-test`

Expected: FAIL because the recipe does not exist.

- [ ] **Step 2: Add `npm-test` and `npm-stage-smoke` recipes**

`npm-test` runs both Node test suites. `npm-stage-smoke` stages packages from a caller-provided binary root and runs `npm pack --dry-run` in each staged package.

- [ ] **Step 3: Add README usage**

Document resolver order, staging input shape, dry-run packing, and publish order.

- [ ] **Step 4: Run verification**

Run: `just npm-test`, `just npm-stage-smoke /tmp/c2c-npm-fake-bin`, and `just check`.

Expected: npm tests and smoke pass; `just check` passes or any pre-existing blocker is reported with evidence.
