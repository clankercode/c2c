#!/bin/bash
# c2c doctor — health snapshot + push-pending analysis for Max
# Shows what's locally queued, what needs deploying, and why.
#
# Usage: ./scripts/c2c-doctor.sh [--json]

set -euo pipefail

JSON=0
[[ "${1:-}" == "--json" ]] && JSON=1

bold() { printf '\033[1m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
yellow() { printf '\033[33m%s\033[0m' "$*"; }
red() { printf '\033[31m%s\033[0m' "$*"; }
dim() { printf '\033[2m%s\033[0m' "$*"; }

# ---------------------------------------------------------------------------
# 1. Health (pass-through)
# ---------------------------------------------------------------------------
echo ""
bold "=== c2c health ==="
echo ""
c2c health 2>&1 || true
echo ""

bold "=== managed instances ==="
echo ""
c2c instances 2>&1 || true
echo ""

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
bold "=== Verdict ==="
echo ""

RELAY_STALE=0
if c2c health 2>&1 | grep -q "stale deploy"; then
  RELAY_STALE=1
fi

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
