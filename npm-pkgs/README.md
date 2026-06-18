# c2c npm packages

This directory owns the npm packaging surface for c2c binaries.

`npm-pkgs/c2c` is the source meta package for `@clanker-code/c2c`. It exposes:

- `resolveC2cBinary()` from `index.js`;
- the `c2c` bin wrapper at `bin/c2c-js-wrapper.js`.

Resolution order is:

1. `C2C_BIN`, failing if it is not executable;
2. system `c2c` on `PATH`, unless that path is the npm wrapper itself;
3. installed platform package matching `process.platform` and `process.arch`;
4. actionable error that names the unsupported or missing package path.

Platform packages are generated at release time. They are not committed with
real binaries in this source tree.

## Stage packages

Create a release binary root shaped like this:

```text
release-bin/
  c2c-linux-x64/c2c
  c2c-linux-arm64/c2c
  c2c-darwin-x64/c2c
  c2c-darwin-arm64/c2c
  c2c-win32-x64/c2c.exe
```

Then stage npm package directories:

```sh
node npm-pkgs/scripts/stage-npm-packages.js \
  --version 0.8.0 \
  --binary-root release-bin \
  --out-dir dist/npm
```

The generated `dist/npm` tree contains:

```text
dist/npm/c2c
dist/npm/c2c-linux-x64
dist/npm/c2c-linux-arm64
dist/npm/c2c-darwin-x64
dist/npm/c2c-darwin-arm64
dist/npm/c2c-win32-x64
```

Run `npm pack --dry-run` in every generated package before publishing. Publish
platform packages first; publish `@clanker-code/c2c` only after all platform
package publishes succeed for the same version.
