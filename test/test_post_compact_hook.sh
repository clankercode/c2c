#!/usr/bin/env bash
# Smoke test for ocaml/tools/c2c_post_compact_hook (slice #317).
#
# Builds a fixture tree with .collab/findings, .c2c/personal-logs/<alias>,
# .c2c/memory/<alias>, and .worktrees/<slice>, then runs the binary with
# the fixture as C2C_REPO_ROOT and verifies the emitted JSON contains
# the expected structure + sections.
#
# Skips silently if the binary hasn't been built yet.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO_ROOT/_build/default/ocaml/tools/c2c_post_compact_hook.exe"

if [ ! -x "$BIN" ]; then
  echo "skip: binary not built ($BIN). Run 'just build' first." >&2
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ALIAS="test-stanza"

# Fixture: .collab/findings with two files, one matching alias.
mkdir -p "$WORK/.collab/findings"
cat > "$WORK/.collab/findings/2026-04-26T10-00-00Z-test-stanza-foo.md" <<'EOF'
# Foo finding title

This is the first content paragraph of the foo finding. It should
be surfaced in the post-compact context block.
EOF
cat > "$WORK/.collab/findings/2026-04-26T11-00-00Z-test-stanza-bar.md" <<'EOF'
# Bar finding title

Second finding content.
EOF
cat > "$WORK/.collab/findings/2026-04-25T00-00-00Z-someone-else-baz.md" <<'EOF'
# Should not appear (different alias)
EOF

# Fixture: .c2c/personal-logs/<alias>/ with two log entries.
mkdir -p "$WORK/.c2c/personal-logs/$ALIAS"
cat > "$WORK/.c2c/personal-logs/$ALIAS/2026-04-25-old.md" <<'EOF'
# Old log

Old content.
EOF
cat > "$WORK/.c2c/personal-logs/$ALIAS/2026-04-26-new.md" <<'EOF'
# New log title

This is the most-recent log's first content paragraph.
EOF
# Touch the new one to be more recent
touch -d '1 hour ago' "$WORK/.c2c/personal-logs/$ALIAS/2026-04-25-old.md"
touch              "$WORK/.c2c/personal-logs/$ALIAS/2026-04-26-new.md"

# Fixture: .c2c/memory/<alias>/ with a private + a shared_with entry.
mkdir -p "$WORK/.c2c/memory/$ALIAS"
cat > "$WORK/.c2c/memory/$ALIAS/own-note.md" <<'EOF'
---
name: own-note
description: Private memo for self.
shared: false
---
Body.
EOF

# Fixture: .c2c/memory/peer/ with a shared_with entry pointing at us.
mkdir -p "$WORK/.c2c/memory/peer-alias"
cat > "$WORK/.c2c/memory/peer-alias/peer-note.md" <<EOF
---
name: peer-note
description: Note shared with $ALIAS by peer-alias.
shared_with: [$ALIAS]
---
Body.
EOF

# Fixture: .worktrees/<slice>/ with a real git commit so log -1 works.
mkdir -p "$WORK/.worktrees"
git -C "$WORK" init -q -b master
git -C "$WORK" config user.email t@t
git -C "$WORK" config user.name t
echo readme > "$WORK/README"; git -C "$WORK" add README; git -C "$WORK" commit -q -m readme
git -C "$WORK" worktree add -q -b "slice/test-active" "$WORK/.worktrees/test-active" 2>/dev/null
( cd "$WORK/.worktrees/test-active" && \
    echo wip > w && git add w && \
    git commit -q -m "feat(test): active slice marker" )

# Run the binary against the fixture. Use a fake broker_root so alias
# resolution falls back to "" which would short-circuit. To force the
# emit path we also run with a stub broker so the binary can resolve
# alias. Simpler: skip the broker check by hand-stubbing the env...
# Actually the binary requires a broker. Build a minimal broker root
# with the registry containing the test alias.
BROKER="$WORK/broker"
mkdir -p "$BROKER"
# Registry format: hand-rolled YAML, see ocaml/c2c_mcp.ml. Use the
# simplest possible single-entry form.
SESSION="test-session-id"
cat > "$BROKER/registry.json" <<EOF
[{"session_id":"$SESSION","alias":"$ALIAS","pid":1,"registered_at":1700000000.0}]
EOF

OUT=$( C2C_MCP_SESSION_ID="$SESSION" \
       C2C_MCP_BROKER_ROOT="$BROKER" \
       C2C_REPO_ROOT="$WORK" \
       "$BIN" 2>&1 )

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL $1" >&2; [ "$#" -gt 1 ] && echo "       $2" >&2; }

# The registry stub matches the broker's JSON format; binary should
# produce a hookSpecificOutput JSON envelope. If it doesn't, that's
# a real failure (was previously a vacuous-pass fallback — removed in
# self-review followups so future regressions can't hide here).
if [ -z "$OUT" ]; then
  echo "FAIL: binary exited silently — registry stub mismatch?" >&2
  exit 1
fi

# Required: top-level JSON shape.
echo "$OUT" | grep -q '"hookEventName": *"PostCompact"' \
  && ok "emits PostCompact hookEventName" \
  || fail "missing hookEventName=PostCompact" "$OUT"

echo "$OUT" | grep -q "<c2c-context " \
  && ok "emits c2c-context envelope" \
  || fail "missing c2c-context envelope"

echo "$OUT" | grep -q "kind=\\\\\"post-compact\\\\\"" \
  && ok "envelope kind=post-compact" \
  || fail "envelope kind not post-compact"

# Each section present.
for section in "operational-reflex-reminder" "active-worktree-slices" \
               "recent-findings" "memory-entries" "most-recent-log"; do
  echo "$OUT" | grep -q "label=\\\\\"$section\\\\\"" \
    && ok "section: $section" \
    || fail "missing section: $section"
done

# Operational reflex reminder content (channel-tag-reply trap).
echo "$OUT" | grep -q "READ-ONLY" \
  && ok "reflex: channel-tag READ-ONLY warning present" \
  || fail "reflex missing READ-ONLY warning"

# Findings: filtered to alias prefix.
echo "$OUT" | grep -q "test-stanza-foo.md" \
  && ok "findings: alias-matched file appears" \
  || fail "findings: alias-matched file missing"
echo "$OUT" | grep -q "someone-else-baz.md" \
  && fail "findings: non-matching alias leaked" \
  || ok "findings: non-matching alias correctly excluded"

# Memory: own + shared_with_me.
echo "$OUT" | grep -q "own-note" \
  && ok "memory: own entry" \
  || fail "memory: own entry missing"
echo "$OUT" | grep -q "(from peer-alias)" \
  && ok "memory: shared_with_me visible" \
  || fail "memory: shared_with_me missing"

# Personal-log: most-recent by mtime.
echo "$OUT" | grep -q "2026-04-26-new.md" \
  && ok "personal-log: newest by mtime selected" \
  || fail "personal-log: wrong file selected"

# Charcount: under 4 KB hard ceiling.
SIZE=$(echo "$OUT" | python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())["hookSpecificOutput"]["additionalContext"]))' 2>/dev/null || echo "0")
if [ "$SIZE" -gt 0 ] && [ "$SIZE" -le 4096 ]; then
  ok "context block size ($SIZE) within 4 KB ceiling"
else
  fail "context size ($SIZE) exceeds 4 KB ceiling"
fi

# --- Additional cases (self-review followups) ---

# Case 16: shared_with_me false-positive scoping. A peer entry whose
# `description:` mentions our alias in passing but does NOT have us in
# `shared_with` should NOT be reported as shared-with-me.
mkdir -p "$WORK/.c2c/memory/peer-bystander"
cat > "$WORK/.c2c/memory/peer-bystander/innocent.md" <<EOF
---
name: innocent
description: A note about $ALIAS but not actually shared with them.
shared: false
shared_with: [someone-else]
---
Body.
EOF
OUT2=$( C2C_MCP_SESSION_ID="$SESSION" \
        C2C_MCP_BROKER_ROOT="$BROKER" \
        C2C_REPO_ROOT="$WORK" \
        "$BIN" 2>&1 )
if echo "$OUT2" | grep -q "(from peer-bystander)"; then
  fail "shared_with_me false positive: peer-bystander leaked"
else
  ok "shared_with_me scoping rejects description-mention false positive"
fi

# Case 17: empty state — no findings, no logs, no memory beyond own
# empty dir, no worktrees. Binary should still emit a well-formed
# envelope with empty section bodies (regression coverage for
# Sys.readdir on missing dirs).
WORK_EMPTY=$(mktemp -d)
trap 'rm -rf "$WORK" "$WORK_EMPTY"' EXIT
git -C "$WORK_EMPTY" init -q -b master
git -C "$WORK_EMPTY" config user.email t@t
git -C "$WORK_EMPTY" config user.name t
echo readme > "$WORK_EMPTY/README"
git -C "$WORK_EMPTY" add README
git -C "$WORK_EMPTY" commit -q -m readme
BROKER_EMPTY="$WORK_EMPTY/broker"
mkdir -p "$BROKER_EMPTY"
cat > "$BROKER_EMPTY/registry.json" <<EOF
[{"session_id":"$SESSION","alias":"$ALIAS","pid":1,"registered_at":1700000000.0}]
EOF
OUT3=$( C2C_MCP_SESSION_ID="$SESSION" \
        C2C_MCP_BROKER_ROOT="$BROKER_EMPTY" \
        C2C_REPO_ROOT="$WORK_EMPTY" \
        "$BIN" 2>&1 )
if echo "$OUT3" | grep -q '"hookEventName": *"PostCompact"' \
   && echo "$OUT3" | grep -q "kind=\\\\\"post-compact\\\\\"" \
   && echo "$OUT3" | grep -q "operational-reflex-reminder"; then
  ok "empty-state fixture still emits well-formed envelope"
else
  fail "empty-state fixture broke envelope shape"
  echo "  output: $OUT3" >&2
fi

# Case 18: truncation — write a very large finding body and verify the
# emitted block stays under the 4 KB ceiling and the per-finding row
# carries an ellipsis marker.
LARGE=$(python3 -c 'print("x"*5000)')
cat > "$WORK/.collab/findings/2026-04-26T12-00-00Z-test-stanza-huge.md" <<EOF
# Huge finding

$LARGE
EOF
OUT4=$( C2C_MCP_SESSION_ID="$SESSION" \
        C2C_MCP_BROKER_ROOT="$BROKER" \
        C2C_REPO_ROOT="$WORK" \
        "$BIN" 2>&1 )
SIZE4=$(echo "$OUT4" | python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())["hookSpecificOutput"]["additionalContext"]))' 2>/dev/null || echo "0")
if [ "$SIZE4" -gt 0 ] && [ "$SIZE4" -le 4096 ]; then
  ok "oversized finding truncated under 4 KB ceiling ($SIZE4)"
else
  fail "oversized finding broke 4 KB ceiling: SIZE=$SIZE4"
fi
if echo "$OUT4" | grep -q "\\.\\.\\."; then
  ok "truncation ellipsis present after oversized input"
else
  fail "truncation ellipsis missing after oversized input"
fi

# Case 19: alias-aware sort on slices — own slice should appear before
# peer slices (Finding 1 from review). Add a second worktree whose name
# does NOT contain alias.
git -C "$WORK" worktree add -q -b "slice/peer-other" "$WORK/.worktrees/peer-other" 2>/dev/null
( cd "$WORK/.worktrees/peer-other" && \
    echo p > p && git add p && git commit -q -m "peer slice marker" )
# Add a worktree that does contain the alias substring.
git -C "$WORK" worktree add -q -b "slice/$ALIAS-mine" "$WORK/.worktrees/$ALIAS-mine" 2>/dev/null
( cd "$WORK/.worktrees/$ALIAS-mine" && \
    echo m > m && git add m && git commit -q -m "own slice marker" )
OUT5=$( C2C_MCP_SESSION_ID="$SESSION" \
        C2C_MCP_BROKER_ROOT="$BROKER" \
        C2C_REPO_ROOT="$WORK" \
        "$BIN" 2>&1 )
SLICES=$(echo "$OUT5" | python3 -c '
import json,sys,re
ctx=json.loads(sys.stdin.read())["hookSpecificOutput"]["additionalContext"]
m=re.search(r"active-worktree-slices.*?</c2c-context-item>", ctx, re.S)
print(m.group(0) if m else "")' 2>/dev/null)
own_pos=$(echo "$SLICES" | grep -o "$ALIAS-mine" | head -1)
peer_pos=$(echo "$SLICES" | grep -o "peer-other" | head -1)
if [ -n "$own_pos" ] && [ -n "$peer_pos" ]; then
  # Check ordering: own should appear first in section
  if echo "$SLICES" | awk -v alias="$ALIAS-mine" -v peer="peer-other" '
    /'"$ALIAS"'-mine/ && !found_peer { print "own-first"; exit }
    /peer-other/ { found_peer=1 }
  ' | grep -q "own-first"; then
    ok "active_slices: alias-matched rows ordered before peer rows"
  else
    fail "active_slices: alias-matched row did NOT come first"
    echo "  section: $SLICES" >&2
  fi
else
  fail "active_slices: own or peer worktree missing from output"
fi

echo
echo "summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
