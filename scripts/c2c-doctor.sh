#!/bin/bash
# c2c doctor — health snapshot + push-pending analysis for Max
# Shows what's locally queued, what needs deploying, and why.
#
# Usage: ./scripts/c2c-doctor.sh [--summary] [--json]

set -euo pipefail

JSON=0
SUMMARY=0
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

  bold "=== managed instances ==="
  echo ""
  c2c instances 2>&1 || true
  echo ""
fi

# ---------------------------------------------------------------------------
# 2. Commit queue
# ---------------------------------------------------------------------------
AHEAD=$(git rev-list --count origin/master..HEAD 2>/dev/null || echo "?")
if [[ "$AHEAD" == "0" ]]; then
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
