# Push-Gate Audit — 24 Local Commits Ahead of origin/master

**Auditor:** fern-coder
**Date:** 2026-05-02
**Commits ahead:** 24 (`origin/master..HEAD`)
**Coord call:** coordinator1 (Cairn-Vigil) — will DM Max with verdict + push call

---

## Summary

| Verdict | Count | Commit SHAs |
|---------|-------|-------------|
| **NEEDS RAILWAY DEPLOY (urgent)** | 1 | `71227db5` |
| **Needs Railway deploy (Phase 2 defenses)** | 2 | `6519cd7b`, `ae4d69ad` (Phase 2A + 2B) |
| Revert (cleanup) | 1 | `bcc67021` |
| **Local-sufficient** | 20 | all others |

**23 of 24 commits are local-sufficient.** Only #613 (catastrophic spike emergency fix) needs immediate Railway deploy. Phase 2A/2B are recommended for the same push to close the defense-in-depth gap, but are not relay-blocking on their own.

---

## Commit Classification

### 🔴 NEEDS RAILWAY DEPLOY — URGENT

| SHA | Author | Subject | Rationale |
|-----|--------|---------|-----------|
| `71227db5` | stanza | `fix: find_real_git content-checks candidates to prevent shim self-exec recursion` | **Root cause fix.** The catastrophic spike was caused by agents generating recursive git-shim spawn chains. Until this is in the deployed binary, agents can re-trigger the amplification loop. This is the single commit that stops the bleeding. |
| `ae4d69ad` | birch | `feat: memoize repo_fingerprint in c2c_repo_fp.ml (Phase 2B)` | Phase 2B — eliminates the hot-path git shell-out that fuels the spike. Recommended for same push as #613 to close the primary blast-radius path. |
| `6519cd7b` | birch | `feat: git-spawn circuit-breaker (Phase 2A)` | Phase 2A — limits blast radius if a loop resumes. Recommended for same push as #613+#2B. Defensive net. |

**Note on Phase 2A/2B:** These are defense-in-depth, not root-cause fixes. `ae4d69ad` (Phase 2B) and `6519cd7b` (Phase 2A) are on local branches, not yet on origin/master or in this commit range. Confirm with coordinator1 whether they have been pushed separately or are included in this batch.

---

### 🟡 REVERT (cleanup before re-land)

| SHA | Author | Subject | Rationale |
|-----|--------|---------|-----------|
| `bcc67021` | coordinator1 | `Revert "feat(#611): cache MAIN_TREE in git-shim + C2C_PROBE_GIT_INVOCATIONS telemetry"` | Reverts cedar's #611 feat commit (`6086858e`) which introduced a `git-pre-reset` shim regression (backslash-escaped quotes in bash command substitution → `unbound variable` under `set -euo pipefail`). Cedar is reworking #611 off-stage. This revert must land before the re-land to avoid re-introducing the regression. Local-sufficient — coord already pushed this. |

---

### 🟢 LOCAL-SUFFICIENT (20 commits)

These touches are client-side only, docs, design docs, or local cleanup. They do not affect the relay server binary or require Railway deployment.

| SHA | Author | Subject | Rationale |
|-----|--------|---------|-----------|
| `9e1f9d33` | fern | `doc: §5 heightened review for shim-modifying slices + cedar #611 regression addendum` | Docs only |
| `8d349be6` | fern | `docs(#611-trio): catastrophic-spike retrospective writeup (fern)` | Docs only |
| `395fc0ef` | cedar | `docs: commit spike audit finding to worktree tree` | Docs only |
| `792ad55b` | coordinator1 | `chore(coord): mark #613 git-shim self-exec fix as SHIPPED in todo.txt` | Local coordination only |
| `a806f547` | coordinator1 | `chore(coord): backlog entries for #613/#614/#615` | Local coordination only |
| `b081974a` | jungle | `feat(#598): c2c restart strips C2C_INSTANCE_NAME on relaunch` | OCaml `c2c_start.ml` — affects `c2c restart` behavior locally on agents; does not affect relay server binary. Local `just install-all` sufficient. |
| `fa3533f8` | birch | `fix: pty_deliver_loop_daemon poll_interval non-optional` | OCaml `c2c_pty_inject.ml` + `c2c_deliver_inbox.ml` — PTY delivery client-side; does not touch relay server code. Local `just install-all` sufficient. |
| `c4113e9a` | birch | `feat(c2c_start): wire --pty-master-fd through start_deliver_daemon` | OCaml `c2c_start.ml` — PTY fd wiring for PTY delivery daemon; client-side. Local `just install-all` sufficient. |
| `d33753ce` | stanza | `cleanup(#602): remove duplicate mkdir_p_mode wrappers` | OCaml relay files (`relay_enc.ml`, `relay_identity.ml`) — cleanup only, no behavioral change. Does not require Railway deploy. |
| `3b1f2688` | coordinator1 | `chore(coord): catastrophic-spike finding + 03:07 sitrep + c2c-list-g idea` | Docs + coordination notes |
| `1f5aed5c` | stanza | `fix(#603): add flush+fsync to write_json_file_atomic in c2c_start.ml` | OCaml `c2c_start.ml` — agent-side state-file write hardening; `c2c_broker.ml`'s copy already had this. Client-side; local `just install-all` sufficient. |
| `61f15517` | cedar | `cleanup(#558): remove dead submit_delay code from deliver-inbox` | OCaml `c2c_deliver_inbox.ml` — dead code removal; client-side. Local sufficient. |
| `8fe78dae` | cedar | `fix(#591): revert \`stash\` allowlist — bypassed destructive stash subcommands` | OCaml kimi hook — `git stash` subcommands are destructive; revert to safer allowlist. Client-side (kimi only). |
| `64c78d69` | stanza | `feat(#590): kimi notifier — statefile-based idle detection` | OCaml `c2c_kimi_notifier.ml` — kimi idle detection via wire.jsonl mtime; client-side kimi notifier. Local `just install-all` sufficient for kimi agents. |
| `7b3e29d1` | cedar | `fix(#591): kimi hook git allowlist — \`stash list\` → \`stash\` + sync scripts/ mirror` | OCaml kimi hook — allowlist fix; client-side kimi only. |
| `b52de6ba` | willow | `feat(#592 S1): add docs/clients/e2e-checklist.md` | Docs only |
| `ec2160e0` | fern | `feat(#593): deprecate crush client` | OCaml `c2c_start.ml` + docs — crush client deprecation; client-side + docs. Local sufficient. |
| `1a1d8ef4` | cedar | `feat(#587): kimi PreToolUse hook safe-pattern allowlist` | OCaml kimi hook — client-side kimi only. |
| `559b770a` | Max | `design: drop crush from e2e checklist scope (Max directive 2026-05-01)` | Design doc only |
| `45eb11cd` | stanza | `design: kimi notifier idle-detection via wire.jsonl mtime + stuck-wake guard` | Design doc only |
| `6086858e` | cedar | `feat(#611): cache MAIN_TREE in git-shim + C2C_PROBE_GIT_INVOCATIONS telemetry` | **Already reverted** by `bcc67021`. Was OCaml + shell; ceded to local-sufficient classification given the revert. |

---

## Key Observations

### 1. The catastrophic spike was an agent-side amplification, not a relay-code bug

The relay server itself was functioning correctly — it was overwhelmed by volume from many agents each generating recursive git-shim spawn chains. The fix is a change to the `find_real_git` function in the `c2c` binary that every agent runs. A Railway deploy propagates the fixed binary to agents via `c2c install`, which stops the spike at the source.

### 2. Phase 2A + 2B are the right complement to #613

- Phase 2A (circuit-breaker): limits blast radius if a loop resumes
- Phase 2B (memoization): eliminates the hot-path git shell-out that fuels the spike

Both are in this local commit batch (on branches, pending push). Confirm with coordinator1 whether they need to be cherry-picked or if they are already on a separate push track.

### 3. 20 of 24 are client-side or docs

The majority of this commit batch is OCaml changes to client-side components (`c2c_start.ml`, kimi notifier, PTY delivery, kimi hook) or documentation. These do not require Railway deploy; `just install-all` propagates them to local agents.

### 4. `d33753ce` (relay_enc.ml + relay_identity.ml cleanup) is local-sufficient

Even though it touches relay files, it is a pure cleanup (2 insertions, 6 deletions) with zero behavioral change. Railway deploy not needed.

---

## Recommended Push Call

**Immediate push:**
- `71227db5` (#613 emergency fix) — stops the spike at the source

**Recommended same push:**
- `ae4d69ad` (Phase 2B memoization)
- `6519cd7b` (Phase 2A circuit-breaker)
- `bcc67021` (revert of broken #611 feat — must land before cedar re-lands #611 properly)

**Can wait for next scheduled push:**
- All remaining 20 local-sufficient commits

---

*Audit by fern-coder. Classifications are best-effort based on file paths and commit messages. Coordinator1 makes the final push call and DM's Max.*
