# Feature C (embed-plugins): CWD-relative dev-detection → non-hermetic binary-only test

- **UTC:** 2026-06-13 ~01:10
- **Alias:** claude (orchestrator), validating ccc/@kimi Feature C impl
- **Severity:** MEDIUM (feature works; test is false-green-prone + minor prod robustness bug)
- **Status:** found by orchestrator validation; handed to different-model review-and-fix

## Symptom
`test_install_opencode_binary_only_writes_embedded` (ocaml/cli/test_c2c_opencode_plugin_embedded.ml)
FAILS when run via `dune exec ... test_c2c_opencode_plugin_embedded.exe` from the worktree root
("binary-only install writes a regular file, not a symlink" → got a symlink), but PASSES when the
agent ran it (likely under `dune runtest`, sandbox CWD `_build/default/ocaml/cli/`).

## Root cause
`c2c_setup.ml:727`: `let canonical_plugin = "data" // "opencode-plugin" // "c2c.ts"` — a RELATIVE
path. Dev-vs-binary detection at `:751` is `Sys.file_exists canonical_plugin` resolved against the
c2c **process CWD**, not the repo root or binary location. The binary-only test invokes the real
worktree `c2c.exe`; whether `./data/opencode-plugin/c2c.ts` exists depends entirely on CWD:
- CWD = worktree root  → exists → symlink branch → test FAILS
- CWD = `_build/...` sandbox → absent → embed branch → test PASSES

So the test does NOT hermetically exercise the binary-only/embedded path; it flips on CWD.

## Secondary (latent prod) bug
A developer running `c2c install opencode` from any directory other than the repo root gets the
EMBEDDED blob instead of a symlink (loses live-edit tracking of data/opencode-plugin/c2c.ts).
Safe degradation (embed always works) but surprising. Detection should resolve canonical_plugin
from the repo root / binary location, not CWD.

## Fix direction (for reviewer)
1. Make the binary-only test genuinely isolate the embedded path — e.g. run a c2c binary that
   cannot resolve the repo data file (chdir the install invocation to a repo-less temp dir, OR an
   explicit test-only force-embed env override, OR copy c2c.exe out of the tree). The test MUST
   fail if the embed path regresses AND pass deterministically regardless of harness CWD.
2. (Recommended) Resolve canonical_plugin from repo root so the dev-symlink path is CWD-independent.
3. Re-verify the anti-false-green sync-gate test still holds.

## Note
The feature's actual headline behavior (repo-less binary-only install → embed) is correct; this is
a test-quality + detection-robustness defect, not a broken feature. But it FAILS the peer-PASS
test-coverage bar (Max: good coverage required) until the test is hermetic.
