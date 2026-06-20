# Finding: npm wrapper prefers PATH c2c over bundled package binary

## Symptom

When `@clanker-code/c2c@0.8.4` is installed, the package wrapper resolves a
system `c2c` on `PATH` before using the bundled platform package binary. If a
user already has an older system `c2c`, invoking the npm-installed `c2c` can
silently execute the older system binary instead of the requested npm version.

Observed by `cc-pi-c2c` during 0.8.4 verification: npm install of 0.8.4 ran a
system `c2c 0.8.0` when that binary appeared on `PATH`; constraining PATH to
`/usr/bin:/bin` made the wrapper use the bundled 0.8.4 binary correctly.

## Impact

Version-pinned npm installs are not deterministic when an older c2c is already
installed on PATH. Users may miss newly shipped fixes without any warning.

## Current behavior

Resolution order in the npm meta-package wrapper is effectively:

1. `C2C_BIN`
2. `resolveOnPath("c2c")`
3. bundled platform binary

## Proposed fix

Prefer the bundled platform binary over PATH:

1. `C2C_BIN` explicit override
2. bundled platform binary for current os/cpu
3. PATH fallback

Alternative: keep PATH-first but warn when the system binary version differs
from the package version. Preference from dogfooders: bundled-before-PATH.

## Status

Not a 0.8.4 blocker; fresh installs without a system `c2c` use the bundled
0.8.4 binary and passed verification. Candidate for a 0.8.5 bugfix.
