# kimi-as-peer-quickref v3 Delta

**Author**: fern-coder
**Date**: 2026-04-29
**Status**: Draft — wait for #158 to land before implementing
**Based on**: v2 (`.collab/runbooks/kimi-as-peer-quickref.md`, SHA `efffe26e`)
**Refs**: `#158` (kimi pre-mint unified), `#478` (auto-approve phase 2)

---

## Summary

#158 (kimi pre-mint unified) changes three things that affect the operator quickref:

1. **MCP allowlist friction eliminated** — `auto_approve_actions` is now seeded at startup
   via `state.json` pre-seeding. The Phase 2 #478 text becomes obsolete.
2. **Session ID resolution replaced** — notifier no longer parses `kimi.log`; reads from
   `~/.local/share/c2c/instances/<alias>/config.json` instead. Session IDs are
   pre-minted by `c2c start` before exec.
3. **Kickoff delivery changed** — kickoff text is no longer written to the notification store;
   it arrives as kimi's first user-turn via `--prompt` argv, naturally visible in TUI scrollback.

---

## Delta Items

### D1: "Phase 2 #478 LANDED" — auto-approve section

**Current v2 text** (§MCP allowlist prompts):
> Fix for Phase 2 (#478): the allowlist will be pre-approved via configuration so the prompt never appears.

**v3 replacement**:

> **#158 landed — auto_approve_actions seeded at startup** ✅
>
> When `c2c start kimi` launches a fresh session, `c2c-start` pre-creates the kimi
> session directory (`<KIMI_SHARE_DIR>/sessions/<workspace-hash>/<resume_session_id>/`)
> and writes two files:
>
> - `context.jsonl` — **empty** (the gatekeeper that switches kimi from `Session.create()`
>   mode to `Session.find()` mode; without it kimi ignores `state.json`)
> - `state.json` — seeded with `auto_approve_actions: ["run command", "edit file outside of working directory"]`
>
> This means the MCP allowlist prompt for `subscribe_to_notification` no longer appears on
> fresh launches. The allowlist approval is pre-seeded in kimi's own session state.
>
> **Note**: if `resume_session_id` points to an **existing** session that was NOT created
> by `c2c start`, the `state.json` seed is skipped and the allowlist prompt may still
> appear for that session. Operators should use `c2c restart` (not `c2c start` on top
> of an existing session) to ensure the seed is applied.

**Files changed**: only the runbook prose; no code changes.

---

### D2: "Two deployment modes" — add pre-mint UUID semantics

**Current v2 text**: "Managed mode — notifier-daemon path" and "Direct MCP — channel-push path"
sections describe how a kimi peer receives messages.

**v3 addition** (new subsection under each mode, or as a shared note):

> **Pre-mint session IDs (managed mode, #158)**
>
> In managed mode, the session UUID is **pre-minted by `c2c start`** before kimi-cli execs.
> It is written to `~/.local/share/c2c/instances/<alias>/config.json` as `resume_session_id`.
> The notifier reads this UUID from `config.json` — it no longer parses `kimi.log`.
>
> **Operator verification**: to confirm pre-mint is working for a given instance:
>
> ```bash
> # Check config.json has resume_session_id
> cat ~/.local/share/c2c/instances/<alias>/config.json | python3 -c \
>   "import sys,json; d=json.load(sys.stdin); print('resume_session_id:', d.get('resume_session_id', 'MISSING'))"
>
> # Check kimi session dir was seeded (context.jsonl exists)
> KIMI_SHARE="${KIMI_SHARE_DIR:-$HOME/.kimi}"
> WH=$(echo -n "$(pwd)" | md5sum | cut -d' -f1)   # or use c2c_start.workspace_hash_for_path equivalent
> ls "$KIMI_SHARE/sessions/$WH/<resume_session_id>/context.jsonl" 2>/dev/null && echo "seeded OK"
> ```
>
> If `context.jsonl` exists and is empty, the session switch to `find()` mode worked.
> If `state.json` exists with `auto_approve_actions`, the Phase 2 allowlist seed is active.

**Note**: the `workspace_hash` computation (`md5(cwd)`) matches kimi-cli's own `WorkDirMeta.sessions_dir` algorithm. Operators can alternatively find the session dir by looking at `~/.kimi/sessions/` directly.

---

### D3: Troubleshooting — stale binary from non-master worktree (Pattern 18 candidate)

**v3 addition** (new entry in Troubleshooting):

> ### Managed kimi starts but notifier can't reach it (stale worktree binary)
>
> If `c2c start kimi` succeeds (c2c binary) but the kimi TUI appears broken or the
> notifier daemon immediately fails to find the session, the kimi binary may be from a
> **non-master worktree** with a mismatched session-structure assumption.
>
> **Symptom**: notifier log shows "no active session" repeatedly despite kimi being running.
>
> **Root cause**: after switching branches or rebasing, the kimi CLI version assumptions
> may have changed. `c2c start` installs the **current git HEAD's binary**, but if the
> operator has an old kimi binary in their `PATH`, it may not be compatible with the
> session structure `c2c-start` expects.
>
> **Fix**:
> ```bash
> # Verify which kimi binary is first in PATH
> which kimi || which kimicli
>
> # Use c2c's managed binary explicitly
> c2c start kimi -n my-alias --binary /path/to/current/kimi-binary
>
> # Or ensure PATH points to the binary c2c installed
> eval "$(c2c env)"  # if such a command exists, else:
> export PATH="$(c2c prefix)/bin:$PATH"
> ```
>
> **Prevention**: always use `c2c restart` after pulling changes that affect kimi session
> handling; avoid manually launching kimi outside of `c2c start`.

> **Related**: Pattern 18 (birch researching) — documents this class of failure.

---

### D4: Remove or update kickoff-notifier race text

**Current v2**: The "Wake fire (managed mode only)" section and the "mid-turn concurrency"
section reference the notification store as kickoff delivery path.

**v3 change**: Kickoff no longer goes through the notification store. The first user-turn
of a fresh kimi session IS the kickoff text. If kimi starts and the operator doesn't
see the kickoff in scrollback, it means `--prompt` wasn't passed correctly (or kimi
started without a kickoff).

> **Kickoff arrives as first user-turn** (managed mode, #158)
>
> When `c2c start kimi` is given a `--kickoff` prompt, that text appears as kimi's
> first user message — visible immediately in the TUI scrollback, no notification store
> race. The notifier has nothing to do with kickoff delivery in #158.
>
> If the kickoff is not visible: check that `c2c start kimi` was called with the
> `--kickoff` flag and that kimi started a fresh session (not resumed).

---

## Section Ordering Recommendation

v3 should restructure the "Deployment Modes" section like this:

```
## Deployment Modes
  Managed (notifier-daemon) — channel push, no daemon
  Direct MCP — channel push, no daemon
  [NEW] Pre-mint session IDs — explains config.json + notifier UUID read
```

And add a "What Changed in #158" callout box at the top of the document pointing
operators to the delta items.

---

## Verification Checklist (for v3 author)

After #158 lands, verify before publishing v3:

- [ ] `~/.local/share/c2c/instances/<alias>/config.json` contains `resume_session_id` on fresh launch
- [ ] `~/.kimi/sessions/<wh>/<resume_session_id>/context.jsonl` is created (empty) on fresh launch
- [ ] `~/.kimi/sessions/<wh>/<resume_session_id>/state.json` contains `auto_approve_actions`
- [ ] MCP allowlist prompt does NOT appear on a fresh managed kimi launch
- [ ] `c2c room history` still works for probe detection (unchanged)
- [ ] Notifier no longer reads `kimi.log` for session ID resolution (confirmed by code inspection)
