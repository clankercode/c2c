# c2c Release Workflow

Release work has two separate decisions:

1. Publish versioned artifacts from a tag.
2. Deploy a relay/site change to production.

Do not let the artifact release workflow bypass deploy caution: pushing
`master` / production tags has real cost. A normal merge to `master` is not
a release. A release is a version tag or an explicit `workflow_dispatch` run.

## Sequence At A Glance

Once the operator has approved the release, the order is:

1. **Bump the version** — `ocaml/version.ml` + `docs/changelog.md`
   (`## X.Y.Z`) + regenerated files (see Prepare).
2. **Commit** the version/changelog/generated-file changes.
3. **Build locally and confirm it all works** — `just check` **and**
   `just test-ocaml` (the ci-gate *runs* the OCaml suite; `just check` only
   *builds* it). Do not proceed on a red local build — it will just fail CI
   ~15 min later. See Prepare for the full validation block.
4. **Push** — push the branch/commit, then push the version tag
   (`git push origin vX.Y.Z`). The tag push is what triggers the release CI.
5. **Babysit the release with the `watch-gh-populate-release` skill** — it
   watches the release CI to green, fixes/re-runs on failure, waits for the
   GitHub Release to appear, populates the release page from the changelog,
   and confirms the npm packages publish successfully. See "Watch + Populate
   The Release" below.

## Source Of Truth

- CLI version: `ocaml/version.ml`
- Public release notes: `docs/changelog.md`
- Release helper: `tools/ci/release.py`
- GitHub release workflow: `.github/workflows/release.yml`
- npm package design: `.collab/design/2026-06-18-npm-binary-packages-for-c2c.md`

The Dune build embeds `C2C_BUILD_GIT_SHA` and `C2C_BUILD_DATE` through the
existing version rules in `ocaml/dune`.

## Prepare

1. Start from the operator-approved release SHA.
2. Ensure `git status --short` is clean.
3. Update `ocaml/version.ml`.
4. Add a top-level `## X.Y.Z` entry to `docs/changelog.md`.
5. Validate locally:

```bash
python3 tools/ci/release.py validate --version X.Y.Z
just codegen-role-designer
just codegen-role-templates
just codegen-opencode-plugin
just codegen-changelog        # bumping version.ml requires a matching `## vX.Y.Z` in data/changelog/CHANGELOG.md
                              # ALSO: fold any staged entries from data/changelog/PENDING.md under the new
                              # heading (they must not land in CHANGELOG.md pre-release — a heading newer
                              # than Version.version makes every deployed binary print a bogus update notice)
git diff --exit-code -- .c2c ocaml data
just check
just test-ocaml              # REQUIRED — `just check` only *builds* the OCaml tests; the release
                             # ci-gate *runs* them. A release-sensitive runtime failure (e.g. a
                             # changelog auto-show test that hardcoded the new version as a
                             # "future/not-embedded" sentinel) will pass `just check` and then fail
                             # the ci-gate. Run the suite locally before tagging to avoid a
                             # ~15-min failed CI round-trip. See
                             # .collab/findings/2026-07-12T03-52-00Z-*-changelog-test-version-landmine.md
```

Commit version/changelog/generated-file updates before tagging.

If the ci-gate fails *after* you already pushed the tag but *before* anything
published (verify: `gh release view vX.Y.Z` = not found and `npm view <pkg>
version` still shows the old version), it is safe to fix, move the tag to the
corrected commit (`git tag -d vX.Y.Z; git push origin :refs/tags/vX.Y.Z;
git tag -a vX.Y.Z -m ...; git push origin vX.Y.Z`), and let it re-run. Do NOT
move a tag once a GitHub Release or npm package exists for it.

## Tag

Default:

```bash
git tag -a vX.Y.Z -m "c2c X.Y.Z"
git push origin vX.Y.Z
```

A tag push is the normal artifact-release path. It runs the mandatory
`ci-gate`, validates the changelog/version, builds release assets, creates or
updates the GitHub Release, dry-run packs every npm package, and publishes npm
packages through Trusted Publishing.

Signed tags are not required for normal c2c releases. If the operator
explicitly requests a signed tag for a particular release, use
`git tag -s vX.Y.Z`; otherwise use the unsigned annotated tag form above.

Manual draft path:

```text
GitHub Actions -> Release -> Run workflow -> version=X.Y.Z, draft=true
```

Manual `workflow_dispatch` runs do not publish npm packages unless
`publish_npm=true` is set. Use that flag only when intentionally publishing
npm from a manual release run; the workflow still runs the same dry-run pack
checks first.

## Watch + Populate The Release

After the tag push, do not walk away — babysit the release with the
`watch-gh-populate-release` skill. It drives the whole post-push loop:

1. **Watch the release CI to green** — `gh run list --workflow=release.yml`,
   `gh run watch <run-id>`. On failure, inspect (`gh run view <run-id>
   --log-failed`), fix, re-run (`gh workflow run release.yml -f tag=vX.Y.Z`
   — but heed the tag-move rules in Prepare once a Release/npm artifact
   exists), and watch again. Do not declare the release done while the run
   is `in_progress` or its conclusion is not `success`.
2. **Wait for the GitHub Release to exist** and verify its assets
   (see "Verify Release Assets" below).
3. **Populate / refresh the release notes** from the `## X.Y.Z` section of
   the changelog so the GitHub Release page carries the full changelog.
4. **Confirm npm published** — check the release CI's npm-publish jobs
   succeeded and that `npm view @clanker-code/c2c version` (and the platform
   packages) shows `X.Y.Z`. A failed/silent npm publish is a release defect,
   not "done".

The skill's steps are tuned for a generic repo; the c2c-specifics
(`release.yml`, `docs/changelog.md` as the notes source, the
`@clanker-code/c2c` meta package + platform packages, Trusted Publishing) are
documented in the sections below — cross-check against them as you go.

## What CI Builds

The release workflow starts with the shared `ci-gate`; no validate, build,
package, release-upload, or npm publish step runs until that gate passes.

The release workflow builds native c2c binary bundles for:

- `linux-x64` — built on **`ubuntu-22.04`** (glibc 2.35 floor; B190)
- `linux-arm64` — built on **`ubuntu-22.04-arm`** (same floor)
- `darwin-x64`
- `darwin-arm64`

**Linux glibc policy (B190):** do not build release Linux assets on
`ubuntu-latest` / 24.04+. That embeds `GLIBC_2.38+` and breaks Ubuntu 22.04.
The build matrix sets `max_glibc: '2.35'` and runs
`scripts/check-glibc-max.sh` on every shipped ELF; a Docker smoke on
`ubuntu:22.04` (with `libsqlite3-0` + `libgmp10`) runs `c2c --version`.
Ubuntu 20.04 (glibc 2.31) remains below the official floor until a
manylinux/static artifact exists — document that, do not silently raise
the ceiling.

**Runtime shared libraries (Linux):** `libsqlite3`, `libgmp` (dynamic).

The `darwin-x64` lane runs on GitHub's `macos-15-intel` runner. Do not use
`macos-13`; that runner image is retired and may leave release jobs stuck in
queue.

Each tarball includes the local install binary family:

- `c2c`
- `c2c-deliver-inbox`
- `c2c-mcp-server`
- `c2c-mcp-inner`
- `c2c-inbox-hook-ocaml`
- `c2c-cold-boot-hook`
- `c2c-post-compact-hook`

Native Windows artifacts are intentionally deferred for now: the current
OCaml dependency set includes `hacl-star`, whose opam availability excludes
Windows on the hosted `ocaml/setup-ocaml` compiler.

`cc-quota` is intentionally excluded from release tarballs because it depends
on operator-local Claude tooling and is not portable c2c runtime surface.

The workflow also stages npm platform packages and the `@clanker-code/c2c`
meta package. Every package is dry-run packed first, and platform packages
publish before the meta package. A tag push publishes npm packages
automatically through Trusted Publishing after the dry-run checks. A manual
`workflow_dispatch` run publishes npm only when `publish_npm=true` is set.

npm publishing uses Trusted Publishing with GitHub Actions OIDC. Configure
each npm package on npmjs.com with:

- GitHub owner/repository for this repo;
- workflow filename `release.yml`;
- optional environment `npm-publish` if we add a GitHub environment gate;
- allowed action `npm publish`.

The first version of each package may need a one-time manual/token bootstrap
before npm lets CI-owned trusted publishing take over.

`actions/setup-node` writes an `_authToken=${NODE_AUTH_TOKEN}` npmrc entry when
`registry-url` is set. For tokenless Trusted Publishing, remove that line before
`npm publish`; otherwise npm can attempt classic token auth and fail with a
misleading `E404` instead of using OIDC.

## Verify Release Assets

Check the GitHub Release contains:

- platform tarballs;
- `SHA256SUMS`;
- `release-manifest.json`;
- `c2c-X.Y.Z-npm-packages.tar.gz`;
- release notes extracted from `docs/changelog.md`.

The manifest must name the expected source SHA. `SHA256SUMS` must cover every
uploaded tarball.

## Deploy

Artifact release is not the same as deploy. Only deploy when the operator
decides the change needs to be live.

After a deploy, verify:

```bash
./scripts/relay-smoke-test.sh
```

Also compare the live relay `/health` fields (`version`, `git_hash`,
`auth_mode`) to the released artifact and expected production mode.

## Failure Modes

- `vX.Y.Z` tag while `ocaml/version.ml` still says the old version.
- Empty or missing changelog section.
- Generated embedded OpenCode plugin or role-template files are stale.
- Release workflow runs from an ordinary branch push.
- npm meta package is published before platform packages.
- Railway deploy config drifts from the Docker runtime command.
- Post-deploy smoke uses an older local `c2c` binary.
