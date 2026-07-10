# F101 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-f101-self-update`
- Tips: `f21f1c6b` (provenance+delegation+tests) + `832af28c` (docs) + `52fd2562` (peer-review fixes). Base `c8d5e7c9`.
- Pure module c2c_self_update_provenance: classify/detect/plan/delegate_command over injectable
  inputs (realpath, PATH, BUN_INSTALL, manager availability). Standalone in-place preserved;
  npm/pnpm/bun delegate; unknown/shadow refuse; --check never mutates. Single JSON document on
  every path; delegate_json/error_json are the shipped, unit-tested emitters. C2C_SELF_UPDATE_EXEC_CMD
  hermetic exec seam.
- Live peer-PASS (fable-warden, not author): initial FAIL (multi-doc JSON on delegate exec; tested
  fns unshipped) fixed in NEW commit 52fd2562; re-reviewed PASS with fixture smokes. Evidence IN
  slice worktree: build rc=0, provenance 30/30, just check rc=0; coordinator delegate-failure smoke
  single-doc rc=1. Signed artifact 52fd2562-fable-warden.json (v2, build_rc=0, all targets).
- Follow-ups: B116 container matrix (CI/infra), cosign TODO pre-existing, M4 token breadth nit.
