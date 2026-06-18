# npm binary packages for c2c

**Date**: 2026-06-18.

**Status**: design sketch for packaging c2c binaries as platform-specific npm
packages so downstream npm packages such as `pi-c2c` can be one-step installs
without carrying every binary in their own tarballs. System `c2c` binaries
still take precedence when present.

## Problem

`pi-c2c` currently shells out to `c2c`. That keeps the extension small and
tracks the real CLI behavior, but it means `pi install npm:pi-c2c` is not
actually sufficient on a fresh machine: the user also needs a compatible
`c2c` binary on `PATH`.

Bundling every platform binary directly into `pi-c2c` would work, but it is
the wrong ownership boundary:

- every install downloads all platforms;
- `pi-c2c` would need to own c2c release artifact production;
- other future JS/npm clients would duplicate the same binary packaging.

Bundling only one platform binary directly into `pi-c2c` is also not enough:
the npm tarball is platform-agnostic, so the package cannot know which binary
to include at publish time.

## Decision

Do not put c2c binaries in the `pi-c2c` tarball. Publish c2c-owned npm binary
packages and let npm install the one matching platform package.

Use one tiny meta package plus platform packages:

```text
@clanker-code/c2c
@clanker-code/c2c-linux-x64
@clanker-code/c2c-linux-arm64
@clanker-code/c2c-darwin-x64
@clanker-code/c2c-darwin-arm64
```

The platform packages contain exactly one executable payload plus package
metadata. The `@clanker-code/c2c` package exposes a small resolver/bin wrapper
that chooses:

1. explicit `C2C_BIN`;
2. system `c2c` on `PATH`;
3. installed matching platform package;
4. clear error with install guidance.

Downstream packages such as `pi-c2c` depend on the `@clanker-code/c2c` meta
package and call its resolver. They should not declare the platform packages
themselves unless there is a strong reason to bypass the meta package. This
centralizes binary selection, version reporting, and future platform additions
in the c2c repo.

## npm platform package mechanics

Each platform package should set npm platform filters so incompatible packages
are skipped instead of installed:

```json
{
  "name": "@clanker-code/c2c-linux-x64",
  "version": "X.Y.Z",
  "os": ["linux"],
  "cpu": ["x64"],
  "files": ["bin/c2c"],
  "bin": {
    "c2c": "bin/c2c"
  }
}
```

macOS uses `os: ["darwin"]`. Windows packages should use `bin/c2c.exe` and
`os: ["win32"]` once native Windows binaries are supported.

The meta package `@clanker-code/c2c` can declare platform packages as optional
dependencies:

```json
{
  "name": "@clanker-code/c2c",
  "version": "X.Y.Z",
  "bin": {
    "c2c": "bin/c2c-js-wrapper.js"
  },
  "optionalDependencies": {
    "@clanker-code/c2c-linux-x64": "X.Y.Z",
    "@clanker-code/c2c-linux-arm64": "X.Y.Z",
    "@clanker-code/c2c-darwin-x64": "X.Y.Z",
    "@clanker-code/c2c-darwin-arm64": "X.Y.Z"
  }
}
```

This is the same broad pattern used by packages that ship native tooling:
install the one package the user names, let npm pick the compatible optional
package, and keep unsupported platforms as a runtime error instead of a broken
install.

## Versioning

All c2c npm packages for a release share the same version as the c2c CLI
release. The meta package and platform packages are published together.

For `pi-c2c`, use a dependency on the meta package after the initial package
stabilizes, for example:

```json
{
  "dependencies": {
    "@clanker-code/c2c": "^X.Y.Z"
  }
}
```

If c2c CLI compatibility is tighter than semver, `pi-c2c` can pin exact
versions and bump deliberately.

## Resolver behavior

The resolver should not shadow a user's installed binary unless asked.

Resolution order:

1. If `C2C_BIN` is set, use it and fail if it cannot execute.
2. If `c2c` exists on `PATH` and is not the npm wrapper currently resolving
   itself, use it.
3. Resolve the matching platform package for `process.platform` and
   `process.arch`.
4. Throw an error that names the current platform and suggests either
   installing c2c system-wide or using `C2C_BIN`.

The resolver should provide an API and a CLI wrapper:

```ts
resolveC2cBinary(): string
```

`pi-c2c` can then replace its current `process.env.C2C_BIN ?? "c2c"` default
with `process.env.C2C_BIN ?? resolveC2cBinary()`.

## Build and publish flow

The c2c release process should produce platform binaries first, then package
them into npm package directories.

Recommended generated tree:

```text
dist/npm/
  c2c/
    package.json
    bin/c2c-js-wrapper.js
    index.js
  c2c-linux-x64/
    package.json
    bin/c2c
  c2c-linux-arm64/
    package.json
    bin/c2c
  c2c-darwin-x64/
    package.json
    bin/c2c
  c2c-darwin-arm64/
    package.json
    bin/c2c
```

The publish command should dry-run every package, then publish platform
packages before the meta package. If any platform publish fails, do not publish
the meta package for that version.

## pi-c2c integration

Once the c2c npm packages exist:

- add `@clanker-code/c2c` as a dependency of `pi-c2c`;
- import c2c's resolver directly;
- keep `C2C_BIN` as the highest-priority override;
- update README from "requires c2c on PATH" to "uses system c2c when present,
  otherwise falls back to the npm-provided platform binary";
- add unit tests for resolution order and unsupported platform errors;
- add a package dry-run check that confirms `@clanker-code/c2c` is in
  dependencies and no raw c2c executable is accidentally included in the
  `pi-c2c` tarball.

## Open questions

- Package namespace: keep the meta package and every platform package under
  `@clanker-code`: `@clanker-code/c2c`,
  `@clanker-code/c2c-linux-x64`, etc. This gives up the shorter `npm install
  c2c` form but keeps ownership and naming consistent.
- Initial platform set: Linux x64 and Linux arm64 are enough for `pi-c2c`'s
  likely first users. macOS arm64 is useful soon after. Windows can wait until
  the CLI release process already builds it.
- Artifact signing/checksums: npm integrity protects package transit, but c2c
  release artifacts may still want separate checksums/signatures for parity
  with non-npm installs.

## Acceptance checks

- `npm install @clanker-code/c2c` installs exactly one matching platform
  package on supported platforms.
- `npx @clanker-code/c2c --version` works without a system `c2c` binary.
- `C2C_BIN=/custom/c2c npx @clanker-code/c2c --version` uses the custom
  binary.
- `pi install npm:pi-c2c` can run c2c operations on a fresh supported machine
  without a separate c2c install.
- Unsupported platforms fail with an actionable message, not a stack trace.
