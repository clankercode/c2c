# c2c Release Checklist

Use this as a terse review aid after reading `.collab/runbooks/release-workflow.md`.

- Worktree clean; release source SHA named.
- Coordinator approved any push/tag/deploy action.
- `ocaml/version.ml`, tag, changelog, release notes, and npm package metadata use the same version.
- `python3 tools/ci/release.py validate --version X.Y.Z` passes.
- Codegen dirty check passes after role and OpenCode plugin generation.
- `just check` passes from a clean enough worktree.
- GitHub Release workflow builds Linux x64, Linux arm64, macOS x64, and macOS arm64.
- Release assets include binary tarballs, `SHA256SUMS`, npm package tarball, and `release-manifest.json`.
- npm packages dry-run before publish; platform packages publish before meta package.
- Railway deploy is treated separately from artifact release.
- Post-deploy smoke uses the released/live binary path and validates `/health.git_hash`.
