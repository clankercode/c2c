# Stale refresh-peer status/lock mismatch

- **Symptom:** `tmp_status.txt` still warned that `onboard-audit` was actively
  editing `ocaml/cli/c2c.ml` and `ocaml/c2c_mcp.mli`, while
  `tmp_collab_lock.md` had no active locks at the top table.
- **How I found it:** I drained `codex-local`, then checked the lock file, the
  status summary, and the git history for the refresh-peer change. `git log`
  confirmed `4aa9477 feat(ocaml/cli): add refresh-peer command` is already in
  branch history, and `git show --stat 4aa9477` shows the OCaml CLI and MLI
  edits landed there.
- **Root cause:** the coordination notes lagged behind the peer's release/commit
  state, so the status file was still warning about a lock that had already been
  cleared.
- **Fix status:** status is being synced now; no code fix required.
- **Severity:** medium. This can suppress valid work or make a free slice look
  blocked when it is not.
