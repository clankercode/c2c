# D1 Stage 3 Findings: Banner Rendering — 2026-05-03

## Claim: "banner.ml never invoked"

**Verdict: OUTDATED / STALE — Banner IS invoked and working in `origin/master`.**

The audit file `.collab/research/2026-05-03-comprehensive-project-audit.md` line 117 states:
> `banner.ml never invoked`

This was written during the audit sweep but does not match current reality.

---

## Evidence

### 1. Banner.ml exists and compiles

`ocaml/Banner.ml` — 143 lines, themed ASCII-art banners with 11 themes
(exp33-gilded, ffx-yuna, lotr-forge, er-ranni, etc.).

### 2. Four live call sites in `origin/master`

```
ocaml/cli/c2c.ml:8852          Banner.print_banner ?theme_name:theme
                              ~subtitle (Printf.sprintf "c2c start --agent %s" agent_name)

ocaml/cli/c2c_agent.ml:345     Banner.print_banner ?theme_name:theme
                              ~subtitle:("agent new  |  " ^ name) "c2c agent"

ocaml/cli/c2c_agent.ml:873    Banner.print_banner
                              ~subtitle:("roles compile  |  " ^ subtitle) "c2c roles"

ocaml/cli/c2c_agent.ml:980    Banner.print_banner
                              ~subtitle:("roles compile  |  " ^ subtitle) "c2c roles"
```

### 3. Live functional verification

```bash
$ c2c agent new test-banner-check
+========================================================+
|  c2c agent                                             |
|    agent new  |  test-banner-check                     |
+========================================================+
|  c2c peer-to-peer messaging for AI agents              |
|    2026-05-02 17:37:35 UTC UTC                         |
+========================================================+

  created: /home/xertrov/src/c2c/.c2c/roles/test-banner-check.md
```

Banner output confirmed for `c2c agent new` ✓
Banner output confirmed for `c2c roles compile --dry-run cedar-coder` ✓
Theme-based coloring works ✓

### 4. Banner wired for `c2c start --agent` too

At `c2c.ml:8852`, when launching with `--agent`, the banner uses the role's
`opencode.theme` field (e.g. `tokyo-night` for cedar-coder).

---

## Root Cause of the Stale Claim

The audit was likely written when an auditor checked a worktree that was based
on an older commit (pre-b748257), or the audit file was not updated after
b748257 landed (Apr 22).

Banner.ml was added in commit `b7482571` (Max, 2026-04-22):
> feat(roles): wire c2c_role.ml into c2c start --agent, add Banner.ml with 11 themes

The audit file's last update is `c708a44c` (May 03 sitrep), but the D1 Stage 3
line was apparently never refreshed to reflect that the code had already shipped.

---

## Recommendation

**Update the audit file** to mark D1 Stage 3 as ✅ DONE rather than ❌ "never invoked".

The audit file needs a correction:
```
- **Stage 3** (Banner rendering) — ❌ banner.ml never invoked
+ **Stage 3** (Banner rendering) — ✅ WORKS (`b7482571`, Max 2026-04-22)
```

---

## Remaining D1 Gaps (legitimate)

| Stage | Status | Notes |
|-------|--------|-------|
| Stage 1 — Parser fidelity | ❌ | Arrays dropped in rendering (`todo-role-gen-test.txt:67`) |
| Stage 2 — Template quality | ❌ | Sparse template (`todo-role-gen-test.txt:86`) |
| **Stage 3 — Banner rendering** | **✅ DONE** | **Already works** |
| Stage 4 — E2E OpenCode launch | 🟡 | Mechanism exists, untested |
| Stage 5 — E2E Claude Code launch | ❌ | No `c2c start claude --agent` wiring yet |
| Stage 6 — Role migration | 🟡 | 4/9 seeded, 6 test artifacts need cleanup |
| Stage 7 — Human polish | ❌ | Awaiting Max sign-off |
| Stage 8 — Codex/Kimi renderers | ❌ | Post-MVP |

---

## Files to Update

- `.collab/research/2026-05-03-comprehensive-project-audit.md` line 117 — fix Stage 3 status
- Optionally: `.worktrees/audit-update/` if that worktree is still active
