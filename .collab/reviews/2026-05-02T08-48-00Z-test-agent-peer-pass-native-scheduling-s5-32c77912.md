# Peer-PASS: native scheduling S5 — migration docs (32c77912)

**reviewer**: test-agent
**commit**: 32c7791206877f52b2681a33a700785e56789866
**author**: stanza-coder
**branch**: slice/native-scheduling-s5
**worktree**: .worktrees/native-scheduling-s5/
**scope**: 10 files, +180/-42 (pure documentation)

## Verdict: PASS

---

## Diff Review

### Pattern across all role files (8 files)

Each role file gets a restructured "Wake scheduling" section with two tiers:

1. **Managed sessions (`c2c start`)** — native scheduling first, with exact `c2c schedule set` verbatim commands
2. **Non-managed sessions** — Monitor + heartbeat binary fallback, verbatim recipe preserved with TaskList dedupe note

**Verbatim recipes verified correct:**
- `c2c schedule set wake --interval 4.1m --message "wake — poll inbox, advance work" --only-when-idle` ✅
- `c2c schedule set sitrep --interval 1h --align @1h+7m --message "sitrep tick"` ✅ (coordinator roles only)
- `c2c schedule list` ✅ (check existing)
- `c2c schedule rm wake` ✅ (remove)

**Cadence correct**: 4.1m off-minute (stays under 5-min cache TTL per CLAUDE.md note preserved verbatim) ✅

### agent-wake-setup.md

New "Option 0: Native scheduling (managed sessions) — preferred" added before existing Option 1/2/3.

**New Option 0 coverage:**
- What it is: `c2c schedule set` → `.c2c/schedules/<alias>/` TOML → hot-reloaded every 10s by `c2c start`
- When to use: managed sessions (`c2c start`), zero-config, persists across restarts
- MCP tools: `schedule_set`, `schedule_list`, `schedule_rm` ✅
- Flags: `--only-when-idle`, `--align @1h+7m` ✅
- Tradeoffs: ✓ zero ongoing cost, ✓ survives compaction, ✓ hot-reloaded within 10s, ✓ automatic dedup; ✗ managed sessions only ✅
- Option table updated: "Any role via `c2c start`" gets Option 0 (native scheduling) ✅

### CLAUDE.md

- Section renamed: "Agent wake-up + Monitor setup" → "Agent wake-up + scheduling" ✅
- Native scheduling section added before Monitor recipe ✅
- Old Monitor verbatim recipe preserved unchanged ✅
- Dedupe note updated: "One schedule/Monitor per cadence per session" ✅
- CLAUDE.md cross-ref updated: "Agent wake-up + Monitor setup" → "Agent wake-up + scheduling" ✅

---

## Key Correctness Checks

1. **Verbatim copy-paste discipline**: all `c2c schedule set` commands are exact, not paraphrased. Interval `4.1m` not simplified to "every 4 minutes" ✅
2. **Cadence**: 4.1m off-minute preserved from original heartbeat recipe (keeps prompt cache warm) ✅
3. **Option ordering**: native scheduling listed first (preferred), Monitor fallback second ✅
4. **No removal of Monitor fallback**: non-managed sessions still covered ✅
5. **Dedup distinction**: "native scheduling handles dedup automatically" noted; TaskList dedupe still recommended for Monitor fallback ✅
6. **CLAUDE.md verbatim block preserved**: Monitor recipe in CLAUDE.md is unchanged verbatim ✅

---

## Summary

Correct migration of all role files and runbooks from Monitor+heartbeat as default to native `c2c schedule set` as preferred for managed sessions. All verbatim recipes are exact. Monitor fallback preserved for non-managed sessions. No code changes — pure documentation.
