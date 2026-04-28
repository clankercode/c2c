#!/bin/bash
# c2c doctor — health snapshot + push-pending analysis for Max
# Shows what's locally queued, what needs deploying, and why.
#
# Usage: ./scripts/c2c-doctor.sh [--summary] [--json]

set -euo pipefail

JSON=0
SUMMARY=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${1:-}" == "--summary" ]] && SUMMARY=1 && shift
[[ "${1:-}" == "--json" ]] && JSON=1 && shift

bold() { printf '\033[1m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
yellow() { printf '\033[33m%s\033[0m' "$*"; }
red() { printf '\033[31m%s\033[0m' "$*"; }
dim() { printf '\033[2m%s\033[0m' "$*"; }

FIX_CHAR="✗"
COORD_CHAR="⚠"
OK_CHAR="✓"
CLEAR_CHAR="–"

# Capture health output once for both full and summary modes
HEALTH_OUTPUT=$(c2c health 2>&1 || true)

# Detect legacy-broker-root state via health --json (#352).
# When `legacy_broker_warning: true`, surface migration prompt prominently in
# both summary and full doctor output. Falls back to grepping the human
# health text if --json fails or jq is unavailable.
LEGACY_BROKER=0
HEALTH_JSON=$(c2c health --json 2>/dev/null || true)
if [[ -n "$HEALTH_JSON" ]] && command -v jq >/dev/null 2>&1; then
  if [[ "$(echo "$HEALTH_JSON" | jq -r '.legacy_broker_warning' 2>/dev/null)" == "true" ]]; then
    LEGACY_BROKER=1
  fi
elif echo "$HEALTH_OUTPUT" | grep -q "LEGACY"; then
  LEGACY_BROKER=1
fi

# Detect if main working tree is on a non-master/main branch (agents sharing main tree)
# Format: /path/to/main  <sha>  [<branch>]  — or [HEAD detached at <sha>]
_wt_raw=$(git worktree list 2>/dev/null | sed -n '1p')
MAIN_TREE_BRANCH=$(echo "$_wt_raw" | sed 's/.*\[\(.*\)\]/\1/')
MAIN_TREE_SHARED=0
# Warn only when main tree is on a real slice branch (not master/main/detached HEAD)
if [[ -n "$MAIN_TREE_BRANCH" ]] \
   && [[ "$MAIN_TREE_BRANCH" != "master" ]] \
   && [[ "$MAIN_TREE_BRANCH" != "main" ]] \
   && [[ "$MAIN_TREE_BRANCH" != *"detached"* ]]; then
  MAIN_TREE_SHARED=1
fi

# Detect uncommitted modifications in the main working tree (staged or unstaged).
# An agent accumulating WIP directly in the main tree is a contamination risk.
MAIN_TREE_UNSTAGED=$(git diff --name-only 2>/dev/null)
MAIN_TREE_STAGED=$(git diff --cached --name-only 2>/dev/null)
MAIN_TREE_DIRTY=0
MAIN_TREE_DIRTY_COUNT=0
if [[ -n "$MAIN_TREE_UNSTAGED" || -n "$MAIN_TREE_STAGED" ]]; then
  MAIN_TREE_DIRTY=1
  _u=0; [[ -n "$MAIN_TREE_UNSTAGED" ]] && _u=$(echo "$MAIN_TREE_UNSTAGED" | grep -c . 2>/dev/null || true)
  _s=0; [[ -n "$MAIN_TREE_STAGED"   ]] && _s=$(echo "$MAIN_TREE_STAGED"   | grep -c . 2>/dev/null || true)
  MAIN_TREE_DIRTY_COUNT=$(( _u + _s ))
fi

# ---------------------------------------------------------------------------
# Stale binary detection
# Check if OCaml source is newer than installed binary
# ---------------------------------------------------------------------------
BINARY_STALE=0
LOCAL_BIN="${HOME}/.local/bin/c2c"
if [[ -f "$LOCAL_BIN" ]]; then
  binary_mtime=$(stat -c %Y "$LOCAL_BIN" 2>/dev/null || echo "0")
  # Find most recent .ml or .mli file under ocaml/
  newest_source=$(find ocaml/ -name "*.ml" -o -name "*.mli" 2>/dev/null | xargs stat -c %Y 2>/dev/null | sort -n | tail -1 || echo "0")
  if [[ "$newest_source" -gt "$binary_mtime" ]]; then
    BINARY_STALE=1
  fi
fi

# ---------------------------------------------------------------------------
# 1. Health (pass-through or summary)
# ---------------------------------------------------------------------------
if [[ $SUMMARY -eq 1 ]]; then
  # Summary mode: health is parsed inline in the ACTION REQUIRED block
  :
else
  echo ""
  bold "=== c2c health ==="
  echo ""
  echo "$HEALTH_OUTPUT"
  echo ""

  if [[ $LEGACY_BROKER -eq 1 ]]; then
    bold "=== broker migration ==="
    echo ""
    yellow "  ⚠ broker root is on the legacy .git/c2c/mcp layout"
    echo ""
    echo "  Run: c2c migrate-broker --dry-run     # audit what will move"
    echo "  Then: c2c migrate-broker               # perform migration"
    echo "  Migration is now safe (#360 landed 99d7b6cf)."
    echo ""
  fi

  bold "=== managed instances ==="
  echo ""
  c2c instances 2>&1 || true
  echo ""

  # Check for drifted managed PIDs: registry entries with pid_start_time set
  # whose processes have died without cleaning up registration.
  bold "=== managed instance drift ==="
  echo ""
  DRIFT_OUTPUT=$(python3 - << 'PYEOF'
import json, os, sys
from pathlib import Path

def find_broker_root():
    """Resolve broker root via canonical priority:
    1. C2C_MCP_BROKER_ROOT env override
    2. Ask `c2c health --json` (authoritative — implements env →
       XDG_STATE_HOME/c2c/repos/<fp>/broker → HOME/.c2c/repos/<fp>/broker)
    3. Python fallback replicating the same priority if `c2c` is missing.
    """
    import subprocess, hashlib
    root = os.environ.get("C2C_MCP_BROKER_ROOT")
    if root:
        p = Path(root)
        if p.exists(): return p
    # Authoritative: ask the OCaml binary
    try:
        result = subprocess.run(
            ["c2c", "health", "--json"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0 and result.stdout.strip():
            data = json.loads(result.stdout)
            br = data.get("broker_root")
            if br:
                p = Path(br)
                if p.exists(): return p
    except Exception:
        pass
    # Fallback: replicate canonical priority in Python
    try:
        remote = subprocess.run(
            ["git", "config", "--get", "remote.origin.url"],
            capture_output=True, text=True
        ).stdout.strip()
        if not remote:
            remote = subprocess.run(
                ["git", "rev-parse", "--show-toplevel"],
                capture_output=True, text=True
            ).stdout.strip()
        if remote:
            # Match canonical OCaml truncation (ocaml/c2c_repo_fp.ml:21-23)
            fp = hashlib.sha256(remote.encode()).hexdigest()[:12]
            xdg = os.environ.get("XDG_STATE_HOME")
            if xdg:
                p = Path(xdg) / "c2c" / "repos" / fp / "broker"
                if p.exists(): return p
            p = Path.home() / ".c2c" / "repos" / fp / "broker"
            if p.exists(): return p
            # 4th tier (ocaml/c2c_repo_fp.ml:58): ~/.local/state/c2c/repos/<fp>/broker
            # Unreachable in practice when HOME is set, but mirror canonical priority.
            p = Path.home() / ".local" / "state" / "c2c" / "repos" / fp / "broker"
            if p.exists(): return p
    except Exception:
        pass
    return None

broker_root = find_broker_root()
if not broker_root:
    print("  (broker root not found — skipping drift check)")
    sys.exit(0)

registry_path = broker_root / "registry.json"
if not registry_path.exists():
    print("  (no registry — skipping drift check)")
    sys.exit(0)

try:
    with open(registry_path) as f:
        registry = json.load(f)
except Exception as e:
    print(f"  (registry parse error: {e})")
    sys.exit(0)

drifted = []
for entry in registry:
    pid = entry.get("pid")
    pid_start_time = entry.get("pid_start_time")
    if not isinstance(pid, int) or not pid_start_time:
        continue  # not a managed instance
    alias = entry.get("alias", "?")
    # Check if process is alive
    try:
        import signal
        os.kill(pid, 0)  # signal 0 = existence check only
        alive = True
    except OSError:
        alive = False

    if not alive:
        drifted.append({
            "alias": alias,
            "pid": pid,
            "pid_start_time": pid_start_time,
        })

RED = '\033[31m'
RESET = '\033[0m'
if not drifted:
    print("  no drifted managed instances")
else:
    for d in drifted:
        print(f"  {RED}✗{RESET} {d['alias']} — pid {d['pid']} is dead (last seen at pid_start_time {d['pid_start_time']})")
        print(f"    → fix: c2c refresh-peer {d['alias']}  or restart the managed session")
PYEOF
)
  echo "$DRIFT_OUTPUT"
  echo ""

  if [[ $MAIN_TREE_SHARED -eq 1 ]]; then
    bold "=== shared-tree warning ==="
    echo ""
    yellow "  ⚠ main tree is on branch '$MAIN_TREE_BRANCH'"
    echo ""
    echo "  Coordinator should own the main tree on master/main."
    echo "  Agents should use per-agent worktrees instead:"
    echo "    c2c start --worktree --branch <slice-branch> <client>"
    echo "  See: .collab/runbooks/worktree-per-feature.md"
    echo ""
  fi

  if [[ $MAIN_TREE_DIRTY -eq 1 ]]; then
    bold "=== uncommitted WIP in main tree ==="
    echo ""
    yellow "  ⚠ $MAIN_TREE_DIRTY_COUNT file(s) modified but not committed"
    echo ""
    if [[ -n "$MAIN_TREE_STAGED" ]]; then
      echo "  Staged (will be in next commit):"
      echo "$MAIN_TREE_STAGED" | head -10 | while IFS= read -r f; do
        printf "    + %s\n" "$f"
      done
    fi
    if [[ -n "$MAIN_TREE_UNSTAGED" ]]; then
      echo "  Unstaged (not yet staged):"
      echo "$MAIN_TREE_UNSTAGED" | head -10 | while IFS= read -r f; do
        printf "    ~ %s\n" "$f"
      done
    fi
    echo ""
    echo "  WIP in the main tree contaminates the shared working tree."
    echo "  Either commit, or move to a worktree: c2c start --worktree --branch <slice> <client>"
    echo ""
  fi

  if [[ $BINARY_STALE -eq 1 ]]; then
    bold "=== stale binary warning ==="
    echo ""
    yellow "  ⚠ installed binary is older than OCaml source"
    echo ""
    echo "  Run 'just install-all' to rebuild and install the current version."
    echo ""
  fi
fi

# ---------------------------------------------------------------------------
# 2. Commit queue
# ---------------------------------------------------------------------------
AHEAD=$(git rev-list --count origin/master..HEAD 2>/dev/null || echo "?")
if [[ "$AHEAD" == "0" ]]; then
  if [[ $SUMMARY -eq 0 && $JSON -eq 0 ]]; then
    if [[ -x "$SCRIPT_DIR/c2c-command-test-audit.py" ]]; then
      echo ""
      bold "=== command test audit ==="
      echo ""
      "$SCRIPT_DIR/c2c-command-test-audit.py" --repo "$PWD" --summary --warn-only || true
      echo ""
    fi
    if [[ -x "$SCRIPT_DIR/c2c-docs-drift.py" ]]; then
      echo ""
      bold "=== docs drift audit ==="
      echo ""
      "$SCRIPT_DIR/c2c-docs-drift.py" --repo "$PWD" --summary --warn-only || true
      echo ""
    fi
    if [[ -x "$SCRIPT_DIR/c2c-dup-scanner.py" ]]; then
      echo ""
      bold "=== duplication scan ==="
      echo ""
      "$SCRIPT_DIR/c2c-dup-scanner.py" --repo "$PWD" --full --warn-only || true
      echo ""
    fi
  fi
  bold "=== Push status: "
  green "up-to-date"
  echo ""
  echo ""
  exit 0
fi

bold "=== Push queue: $AHEAD commits ahead of origin/master ==="
echo ""

# Classify commits into relay-critical vs local-only.
# Relay-critical = touches relay server code or Python relay connector.
# Docs, findings, GitHub Pages files, and scripts are local-only even when
# their commit message mentions "relay" (e.g. "docs: mark relay.c2c.im live").
# Note: c2c_start.ml is NOT relay-critical — Railway runs `c2c relay serve`, not
# `c2c start`. Changes to the client launcher only affect local agent machines.

# Paths that are always local-only even if they mention relay in the message:
DOCS_ONLY_PATTERN="^(docs/|_config\.yml|Gemfile|_layouts/|_includes/|\.collab/|\.goal-loops/|README)"

RELAY_CRITICAL=()
RELAY_CONNECTOR=()
LOCAL_ONLY=()

while IFS= read -r line; do
  sha="${line%% *}"
  msg="${line#* }"
  # Check which files the commit touches
  files=$(git diff-tree --no-commit-id -r --name-only "$sha" 2>/dev/null || true)
  is_server=0
  is_connector=0
  # Server-critical: relay SERVER code deployed on Railway (ocaml/server/, relay.ml).
  # Railway runs `c2c relay serve` — only these files need a Railway deploy.
  if echo "$files" | grep -qE "ocaml/server/|ocaml/relay\.ml|ocaml/relay_server|ocaml/server_http|^railway\.json|^Dockerfile"; then
    is_server=1
  fi
  # Connector-only: c2c_relay_connector.ml and relay_client*.ml run in each agent's
  # binary. These need a local `just install-all` rebuild but NOT a Railway push.
  if echo "$files" | grep -qE "ocaml/c2c_relay_connector\.ml|ocaml/relay_client"; then
    is_connector=1
  fi
  # Message-based: explicit relay-server scope triggers server-critical.
  # Plain "relay" in body is insufficient (docs/tests can mention relay without
  # touching server code). msg has SHA stripped, so pattern starts at commit subject.
  if echo "$msg" | grep -qiE "^(fix|feat|refactor|perf)\(relay-server\)"; then
    is_server=1
  fi
  # Override: docs/findings/pages files never trigger any relay classification.
  if [[ -n "$files" ]]; then
    non_docs=$(echo "$files" | grep -vE "$DOCS_ONLY_PATTERN" || true)
    if [[ -z "$non_docs" ]]; then
      is_server=0
      is_connector=0
    fi
  fi
  if [[ $is_server -eq 1 ]]; then
    RELAY_CRITICAL+=("$sha $msg")
  elif [[ $is_connector -eq 1 ]]; then
    RELAY_CONNECTOR+=("$sha $msg")
  else
    LOCAL_ONLY+=("$sha $msg")
  fi
done < <(git log --oneline origin/master..HEAD)

if [[ ${#RELAY_CRITICAL[@]} -gt 0 ]]; then
  yellow "  Relay/deploy critical (${#RELAY_CRITICAL[@]}) — Railway deploy needed:"
  echo ""
  for entry in "${RELAY_CRITICAL[@]}"; do
    sha="${entry%% *}"
    msg="${entry#* }"
    printf "    $(yellow '●') %s  %s\n" "$sha" "$msg"
  done
  echo ""
fi

if [[ ${#RELAY_CONNECTOR[@]} -gt 0 ]]; then
  yellow "  Relay-connector (${#RELAY_CONNECTOR[@]}) — local rebuild only:"
  echo ""
  for entry in "${RELAY_CONNECTOR[@]}"; do
    sha="${entry%% *}"
    msg="${entry#* }"
    printf "    $(yellow '○') %s  %s\n" "$sha" "$msg"
  done
  echo ""
fi

if [[ ${#LOCAL_ONLY[@]} -gt 0 ]]; then
  dim "  Local-only (${#LOCAL_ONLY[@]}) — safe to batch:"
  echo ""
  for entry in "${LOCAL_ONLY[@]}"; do
    sha="${entry%% *}"
    msg="${entry#* }"
    printf "    $(dim '○') %s  %s\n" "$sha" "$msg"
  done
  echo ""
fi

# ---------------------------------------------------------------------------
# 2b. Public command test audit
# ---------------------------------------------------------------------------
COMMAND_TEST_AUDIT_OUTPUT=""
COMMAND_TEST_AUDIT_GAPS=0
if [[ -x "$SCRIPT_DIR/c2c-command-test-audit.py" ]]; then
  COMMAND_TEST_AUDIT_OUTPUT=$("$SCRIPT_DIR/c2c-command-test-audit.py" --repo "$PWD" --summary --warn-only 2>&1 || true)
  COMMAND_TEST_AUDIT_GAPS=$(echo "$COMMAND_TEST_AUDIT_OUTPUT" | grep -oE '[0-9]+ gap\(s\)' | head -1 | grep -oE '[0-9]+' || echo "0")
fi

if [[ $SUMMARY -eq 0 && $JSON -eq 0 && -n "$COMMAND_TEST_AUDIT_OUTPUT" ]]; then
  bold "=== command test audit ==="
  echo ""
  echo "$COMMAND_TEST_AUDIT_OUTPUT"
  echo ""
fi

# ---------------------------------------------------------------------------
# Docs drift audit
# ---------------------------------------------------------------------------
DOCS_DRIFT_OUTPUT=""
DOCS_DRIFT_COUNT=0
if [[ -x "$SCRIPT_DIR/c2c-docs-drift.py" ]]; then
  DOCS_DRIFT_OUTPUT=$("$SCRIPT_DIR/c2c-docs-drift.py" --repo "$PWD" --summary --warn-only 2>&1 || true)
  DOCS_DRIFT_COUNT=$(echo "$DOCS_DRIFT_OUTPUT" | grep -oE '[0-9]+ drift finding\(s\)' | sed -n '1p' | grep -oE '[0-9]+' || echo "0")
fi

if [[ $SUMMARY -eq 0 && $JSON -eq 0 && -n "$DOCS_DRIFT_OUTPUT" ]]; then
  bold "=== docs drift audit ==="
  echo ""
  echo "$DOCS_DRIFT_OUTPUT"
  echo ""
fi

# ---------------------------------------------------------------------------
# Duplication scan
# ---------------------------------------------------------------------------
if [[ $SUMMARY -eq 0 && $JSON -eq 0 && -x "$SCRIPT_DIR/c2c-dup-scanner.py" ]]; then
  bold "=== duplication scan ==="
  echo ""
  "$SCRIPT_DIR/c2c-dup-scanner.py" --repo "$PWD" --full --warn-only || true
  echo ""
fi

# ---------------------------------------------------------------------------
# Worktree base staleness
# ---------------------------------------------------------------------------
WORKTREE_BASE_OUTPUT=""
if [[ $JSON -eq 0 ]]; then
  WT_CLI="${C2C_CLI:-c2c}"
  if [[ -x "$WT_CLI" ]] || command -v c2c &>/dev/null; then
    WORKTREE_BASE_OUTPUT=$("$WT_CLI" worktree check-bases 2>&1 || true)
    if [[ -n "$WORKTREE_BASE_OUTPUT" ]]; then
      bold "=== worktree base drift ==="
      echo ""
      echo "$WORKTREE_BASE_OUTPUT"
      echo ""
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 3. Verdict
# ---------------------------------------------------------------------------

RELAY_STALE=0
if echo "$HEALTH_OUTPUT" | grep -qE "stale deploy|relay behind local"; then
  RELAY_STALE=1
fi

# ---------------------------------------------------------------------------
# Summary mode: compact ACTION REQUIRED block
# ---------------------------------------------------------------------------
if [[ $SUMMARY -eq 1 ]]; then
  echo ""
  bold "=== ACTION REQUIRED ==="
  echo ""

  # Parse health output into FIX / CLEAR items
  FIX_ITEMS=()
  CLEAR_ITEMS=()
  HEALTH_PASS_COUNT=0
  HEALTH_TOTAL_COUNT=0

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Check if line contains any icon character
    has_icon=0
    if echo "$line" | grep -q $'\u2713'; then has_icon=1; icon_char=$'\u2713'; fi  # ✓
    if echo "$line" | grep -q $'\u2717'; then has_icon=1; icon_char=$'\u2717'; fi  # ✗
    if echo "$line" | grep -q $'\u26A0'; then has_icon=1; icon_char=$'\u26A0'; fi  # ⚠
    if echo "$line" | grep -q $'\u2796'; then has_icon=1; icon_char=$'\u2796'; fi  # –

    if [[ $has_icon -eq 1 ]]; then
      HEALTH_TOTAL_COUNT=$((HEALTH_TOTAL_COUNT + 1))
      # Extract content after icon (strip leading whitespace + icon)
      rest=$(echo "$line" | sed 's/^[[:space:]]*//' | sed "s/$icon_char[[:space:]]*//")
    case "$icon_char" in
      $'\u2713')
        HEALTH_PASS_COUNT=$((HEALTH_PASS_COUNT + 1))
        [[ -n "$rest" ]] && CLEAR_ITEMS+=("$rest")
        ;;
      $'\u26A0') ;;  # ⚠ warnings handled separately in COORDINATOR
      $'\u2717') FIX_ITEMS+=("$icon_char $rest") ;;    # ✗
    esac
    fi
  done <<< "$HEALTH_OUTPUT"

  # Extract dead registration count
  DEAD_REGS=""
  DEAD_COUNT=0
  if echo "$HEALTH_OUTPUT" | grep -qE "registrations:.*dead"; then
    DEAD_COUNT=$(echo "$HEALTH_OUTPUT" | grep "registrations:" | grep -oE "[0-9]+ dead" | grep -oE "[0-9]+" | head -1)
    [[ -n "$DEAD_COUNT" ]] || DEAD_COUNT=0
  fi

  # Extract /tmp space warning
  TMP_LOW=""
  if echo "$HEALTH_OUTPUT" | grep -qiE "/tmp.*low|/tmp.*[0-9]+MB"; then
    TMP_LOW=$(echo "$HEALTH_OUTPUT" | grep -i "/tmp" | sed 's/^[[:space:]]*//' | head -1)
  fi

  # Print FIX NOW
  if [[ ${#FIX_ITEMS[@]} -gt 0 || $DEAD_COUNT -gt 0 || -n "$TMP_LOW" ]]; then
    printf "  $FIX_CHAR FIX NOW:  " >&2
    first=1
    if [[ $DEAD_COUNT -gt 0 ]]; then
      printf "%d dead registration%s" "$DEAD_COUNT" "$([ $DEAD_COUNT -eq 1 ] && echo "" || echo "s")" >&2
      printf " (→ run: c2c sweep)" >&2
      first=0
    fi
    if [[ -n "$TMP_LOW" ]]; then
      [[ $first -eq 0 ]] && printf "; " >&2
      printf "%s (→ free /tmp space)" "$TMP_LOW" >&2
      first=0
    fi
    for item in "${FIX_ITEMS[@]}"; do
      [[ $first -eq 0 ]] && printf "; " >&2
      printf "%s" "$item" >&2
      first=0
    done
    printf "\n" >&2
  fi

  # Print COORDINATOR
  if [[ ${#RELAY_CRITICAL[@]} -gt 0 && $RELAY_STALE -eq 1 ]]; then
    printf "  $COORD_CHAR COORDINATOR:  " >&2
    printf "relay-stale + %d relay-critical commit%s queued (push needed)" "${#RELAY_CRITICAL[@]}" "$([ ${#RELAY_CRITICAL[@]} -eq 1 ] && echo "" || echo "s")" >&2
    printf "\n" >&2
  elif [[ $RELAY_STALE -eq 1 ]]; then
    printf "  $COORD_CHAR COORDINATOR:  relay-stale but no relay-critical commits\n" >&2
  fi

  if [[ $MAIN_TREE_SHARED -eq 1 ]]; then
    printf "  $COORD_CHAR WARN: main tree on '%s' (not master/main) — agents should use worktrees (c2c start --worktree --branch <slice> <client>)\n" "$MAIN_TREE_BRANCH" >&2
  fi

  if [[ $MAIN_TREE_DIRTY -eq 1 ]]; then
    printf "  $COORD_CHAR WARN: %d file(s) uncommitted in main tree — WIP contaminates shared working tree (commit or move to worktree)\n" "$MAIN_TREE_DIRTY_COUNT" >&2
  fi

  if [[ $BINARY_STALE -eq 1 ]]; then
    printf "  $COORD_CHAR WARN: binary older than OCaml source — run 'just install-all'\n" >&2
  fi

  if [[ ${COMMAND_TEST_AUDIT_GAPS:-0} -gt 0 ]]; then
    printf "  $COORD_CHAR WARN: %d Tier 1/2 command(s) lack obvious test references — run scripts/c2c-command-test-audit.py\n" "$COMMAND_TEST_AUDIT_GAPS" >&2
  fi

  if [[ ${DOCS_DRIFT_COUNT:-0} -gt 0 ]]; then
    printf "  $COORD_CHAR WARN: %d CLAUDE.md docs drift finding(s) — run scripts/c2c-docs-drift.py\n" "$DOCS_DRIFT_COUNT" >&2
  fi

  # Print ALL CLEAR
  printf "  $OK_CHAR ALL CLEAR:  " >&2
  first=1
  if [[ $RELAY_STALE -eq 0 && ${#RELAY_CRITICAL[@]} -eq 0 ]]; then
    printf "relay current; " >&2
    first=0
  fi
  if [[ $HEALTH_TOTAL_COUNT -gt 0 && $HEALTH_PASS_COUNT -eq $HEALTH_TOTAL_COUNT ]]; then
    printf "%d/%d health checks passing; " "$HEALTH_PASS_COUNT" "$HEALTH_TOTAL_COUNT" >&2
    first=0
  elif [[ $HEALTH_TOTAL_COUNT -eq 0 ]]; then
    printf "no health checks; " >&2
    first=0
  fi
  if [[ $DEAD_COUNT -eq 0 ]]; then
    printf "no dead registrations; " >&2
    first=0
  fi
  for item in "${CLEAR_ITEMS[@]}"; do
    [[ $first -eq 0 ]] && printf "; " >&2
    printf "%s" "$item" >&2
    first=0
  done
  printf "\n" >&2

  echo ""
  bold "=== HEALTH: ${HEALTH_PASS_COUNT}/${HEALTH_TOTAL_COUNT} checks passing ==="
  echo ""
  for item in "${FIX_ITEMS[@]}"; do
    printf "  %s\n" "$item"
  done
  if [[ $DEAD_COUNT -gt 0 ]]; then
    printf "  dead registrations: %d\n" "$DEAD_COUNT"
  fi
  if [[ ${#FIX_ITEMS[@]} -eq 0 && $DEAD_COUNT -eq 0 ]]; then
    printf "  (none)\n"
  fi
  echo ""

  bold "=== PUSH: ${#RELAY_CRITICAL[@]} relay-critical commits queued ==="
  echo ""
  for entry in "${RELAY_CRITICAL[@]}"; do
    sha="${entry%% *}"
    msg="${entry#* }"
    printf "  %s  %s\n" "$sha" "$msg"
  done
  if [[ ${#RELAY_CRITICAL[@]} -eq 0 ]]; then
    printf "  (none)\n"
  fi
  echo ""

  bold "=== managed instances ==="
  echo ""
  c2c instances 2>&1 || true
  echo ""

  exit 0
fi

bold "=== Verdict ==="
echo ""

if [[ ${#RELAY_CRITICAL[@]} -gt 0 && $RELAY_STALE -eq 1 ]]; then
  red "  ⚠ PUSH RECOMMENDED"
  echo ""
  echo "  relay.c2c.im is stale AND there are relay-critical commits queued."
  echo "  These fixes are not live in prod until you push:"
  echo ""
  for entry in "${RELAY_CRITICAL[@]}"; do
    sha="${entry%% *}"
    msg="${entry#* }"
    printf "    %s  %s\n" "$sha" "$msg"
  done
  echo ""
  echo "  When ready:"
  echo "    git push                              # triggers Railway rebuild (~15min)"
  echo "    ./scripts/relay-smoke-test.sh         # validate after deploy"
elif [[ ${#RELAY_CRITICAL[@]} -gt 0 ]]; then
  yellow "  ⚡ Relay-critical commits queued (relay already up-to-date)"
  echo ""
  echo "  Relay is current but has relay-critical commits not yet pushed."
  echo "  Push when you're ready to deploy the next batch."
elif [[ $RELAY_STALE -eq 1 ]]; then
  yellow "  ◌ Relay stale but no server-critical changes in queue"
  echo ""
  echo "  relay.c2c.im is behind, but queued commits are local-only or connector-only."
  echo "  Push is low-urgency — batch more commits first."
  if [[ ${#RELAY_CONNECTOR[@]} -gt 0 ]]; then
    echo ""
    echo "  Connector-only commits (need local just install-all, no Railway push):"
    for entry in "${RELAY_CONNECTOR[@]}"; do
      sha="${entry%% *}"
      msg="${entry#* }"
      printf "    %s  %s\n" "$sha" "$msg"
    done
  fi
else
  green "  ✓ No push needed"
  echo ""
  echo "  All $AHEAD queued commits are local-only; relay is current."
fi

echo ""
echo "  To run tests: just test   (Python + OCaml)"
echo "  To smoke-test relay: ./scripts/relay-smoke-test.sh"
echo ""
