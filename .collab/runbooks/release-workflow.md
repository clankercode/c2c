# c2c Release Workflow

Release work has two separate decisions:

1. Publish versioned artifacts from a tag.
2. Deploy a relay/site change to production.

Do not let the artifact release workflow bypass coordinator push policy. A
normal merge to `master` is not a release. A release is a version tag or an
explicit `workflow_dispatch` run.

## Source Of Truth

- CLI version: `ocaml/version.ml`
- Public release notes: `docs/changelog.md`
- Release helper: `tools/ci/release.py`
- GitHub release workflow: `.github/workflows/release.yml`
- npm package design: `.collab/design/2026-06-18-npm-binary-packages-for-c2c.md`

The Dune build embeds `C2C_BUILD_GIT_SHA` and `C2C_BUILD_DATE` through the
existing version rules in `ocaml/dune`.

## Prepare

1. Start from the coordinator-approved release SHA.
2. Ensure `git status --short` is clean.
3. Update `ocaml/version.ml`.
4. Add a top-level `## X.Y.Z` entry to `docs/changelog.md`.
5. Validate locally:

```bash
python3 tools/ci/release.py validate --version X.Y.Z
just codegen-role-designer
just codegen-role-templates
just codegen-opencode-plugin
git diff --exit-code -- .c2c ocaml data
just check
```

Commit version/changelog/generated-file updates before tagging.

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

Signed tags are not required for normal c2c releases. If coordinator1
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

## What CI Builds

The release workflow starts with the shared `ci-gate`; no validate, build,
package, release-upload, or npm publish step runs until that gate passes.

The release workflow builds native c2c binary bundles for:

- `linux-x64`
- `linux-arm64`
- `darwin-x64`
- `darwin-arm64`

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

Artifact release is not the same as deploy. Only deploy when coordinator1
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
