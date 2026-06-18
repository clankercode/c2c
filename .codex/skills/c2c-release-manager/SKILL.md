---
name: c2c-release-manager
description: Manage c2c releases, version bumps, changelog entries, GitHub Actions release builds, generated binary/npm artifacts, and post-release verification. Use when preparing a new c2c version, cutting a tag, troubleshooting release CI, staging npm binary packages, or deciding whether a release/deploy is ready.
---

# C2C Release Manager

## Overview

Use this skill to move c2c from local commits to a validated release without
bypassing the swarm's push gate. It coordinates version/changelog truth,
generated artifacts, GitHub Release assets, npm binary package staging, and
post-release smoke checks.

## First Reads

Before acting, read the current repo state:

- `.collab/runbooks/release-workflow.md`
- `.collab/design/2026-06-18-npm-binary-packages-for-c2c.md`
- `ocaml/version.ml`
- `docs/changelog.md`
- `.github/workflows/release.yml`
- `tools/ci/release.py`

Also check `git status --short` and `git log --oneline --decorate -5` so the
release source SHA and any dirty state are explicit.

## Prepare A Version

1. Confirm coordinator approval before pushing tags or deploying.
2. Update `ocaml/version.ml`.
3. Add a top-level `## X.Y.Z` section to `docs/changelog.md`.
4. Run:

```bash
python3 tools/ci/release.py validate --version X.Y.Z
just codegen-role-designer
just codegen-role-templates
just codegen-opencode-plugin
git diff --exit-code -- .c2c ocaml data
just check
```

If generated files change, commit them with the source change. Do not cut a
release from a dirty worktree unless the dirty state is intentionally recorded
in a handoff and the release is stopped before tagging.

## Cut A Release

Preferred path:

```bash
git tag -s vX.Y.Z
git push origin vX.Y.Z
```

If signing is unavailable, do not silently downgrade; ask coordinator1 which
tag policy to use. The release workflow also supports manual dispatch with a
version input for dry runs and draft releases.

The release workflow builds Linux x64, Linux arm64, macOS x64, and macOS arm64
artifact bundles. It stages npm platform packages plus the
`@clanker-code/c2c` meta package, dry-runs every package, and publishes npm
only on manual dispatch with `publish_npm=true`. npm publishing uses Trusted
Publishing with GitHub Actions OIDC, so configure each npm package on npmjs.com
for workflow `release.yml`; the first publish for each package may need a
one-time bootstrap before trusted publishing can take over.

## Verify Outputs

For GitHub Release assets, verify:

- tag matches `ocaml/version.ml`;
- `release-manifest.json` names the expected SHA;
- `SHA256SUMS` covers every tarball;
- each tarball contains `c2c`, `c2c-mcp-server`, `c2c-mcp-inner`,
  `c2c-deliver-inbox`, and hooks;
- each tarball excludes operator-local helpers such as `cc-quota`;
- npm package dry-runs ran before any publish;
- the meta npm package was published after all platform packages.

For deploys, keep artifact release and Railway deploy as separate decisions.
After any deploy, compare live `/health.git_hash` with the released SHA and run:

```bash
./scripts/relay-smoke-test.sh
```

## Failure Modes

Stop and fix before release if any of these appear:

- tag/version/changelog mismatch;
- stale generated embedded plugin or role-template files;
- `_build` cache hides a missing target;
- release workflow runs from a branch push instead of a version tag or manual dispatch;
- npm meta package would publish before platform packages;
- Railway command/config has drifted from Docker runtime assumptions;
- docs/changelog claim behavior not present in the binary.

Keep the final handoff concrete: version, tag, SHA, artifacts, checksums,
workflow run, npm decision, deploy decision, smoke results, and rollback note.
