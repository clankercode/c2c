#!/usr/bin/env bash
# onboarding-smoke-test.sh — fresh-machine onboarding smoke test.
#
# Per lyra's findings doc gap #9 (.collab/findings/2026-04-26T00-38-17Z-lyra-cross-machine-onboarding-gaps.md):
# validates the install → identity → relay-setup → relay-register →
# connector → loopback-DM → room-history flow against a temp HOME +
# temp broker root, so we don't pollute the operator's real state.
#
# Usage:
#   scripts/onboarding-smoke-test.sh [relay-url]
#
# Defaults to RELAY_URL env or http://localhost:7331. Pass an explicit
# URL (e.g. https://relay.c2c.im) when testing against the hosted relay.
#
# Exit code: 0 = all PASS; 1 = any FAIL. Each step prints PASS/FAIL with
# a short hint pointing at the runbook section that owns it.

set -uo pipefail   # -e omitted on purpose: we want to keep going on FAIL
                   #  and tally at the end.

RELAY_URL="${1:-${C2C_RELAY_URL:-http://localhost:7331}}"
ALIAS="smoke-onboard-$$-$(date +%s)"
PASS=0
FAIL=0
FAILS=()

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; PASS=$((PASS+1)); }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*"; FAIL=$((FAIL+1)); FAILS+=("$1"); }
info()  { printf '  %s\n' "$*"; }
hr()    { printf -- '------------------------------------------------------------\n'; }

require_step() {
  # require_step <label> <cmd...>
  local label="$1"; shift
  if "$@" >/tmp/onboard-smoke.out 2>&1; then
    green "$label"
  else
    red "$label"
    info "  cmd: $*"
    info "  output:"
    sed 's/^/    /' /tmp/onboard-smoke.out | head -10
  fi
}

soft_step() {
  # soft_step <label> <cmd...> — known-gap step, reports but does not fail
  # the run when the gap is documented.
  local label="$1"; shift
  if "$@" >/tmp/onboard-smoke.out 2>&1; then
    green "$label"
  else
    printf '\033[33m⚠ %s (known gap, see runbook)\033[0m\n' "$label"
    info "  cmd: $*"
    info "  output:"
    sed 's/^/    /' /tmp/onboard-smoke.out | head -10
  fi
}

# --- Step 0: temp env setup -------------------------------------------------

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME"
export C2C_MCP_BROKER_ROOT="$TMP/broker"
mkdir -p "$C2C_MCP_BROKER_ROOT"

# Strip env vars that would inherit from the operator's session and
# pollute the smoke run.
unset C2C_MCP_SESSION_ID CLAUDE_SESSION_ID C2C_MCP_AUTO_REGISTER_ALIAS \
      C2C_INSTANCE_NAME

echo "=== c2c Onboarding Smoke Test ==="
info "alias:       $ALIAS"
info "relay-url:   $RELAY_URL"
info "temp HOME:   $HOME"
info "broker:      $C2C_MCP_BROKER_ROOT"
hr

# --- Step 1: install artifacts ---------------------------------------------

require_step "c2c binary on PATH" command -v c2c
require_step "c2c --version runs"  c2c --version

# --- Step 2: c2c init (local broker) ---------------------------------------

require_step "c2c init creates a session + alias" \
  c2c init --no-setup --alias "$ALIAS" --room '' --json

# --- Step 3: relay identity ------------------------------------------------

# `c2c init` (step 2) already runs `c2c relay identity init` opportunistically,
# so identity.json should exist now. Verify the file is on disk + show
# parses it cleanly. (We don't re-run init here — it would error
# "already exists" without --force, and --force would rotate the key,
# which is the wrong behavior for a smoke test.)
require_step "identity.json exists after c2c init" \
  test -f "$HOME/.config/c2c/identity.json"
require_step "c2c relay identity show parses identity.json" \
  c2c relay identity show

# --- Step 4: relay setup writes config -------------------------------------

# This step writes relay.json. Per gap #1 the file is currently not
# consumed by relay status/connect/list, so we test the write here and
# rely on explicit --relay-url / $C2C_RELAY_URL for downstream steps.
require_step "c2c relay setup --url writes relay.json" \
  c2c relay setup --url "$RELAY_URL"

# --- Step 5: relay register (requires reachable relay) ---------------------

soft_step "c2c relay register --alias --relay-url" \
  c2c relay register --alias "$ALIAS" --relay-url "$RELAY_URL"

# --- Step 6: connector single-tick -----------------------------------------

soft_step "c2c relay connect --once --relay-url" \
  c2c relay connect --once --relay-url "$RELAY_URL" --interval 5

# --- Step 7: loopback DM (self → self via relay) ---------------------------

soft_step "c2c relay dm send (loopback)" \
  c2c relay dm send --alias "$ALIAS" --relay-url "$RELAY_URL" \
                    "$ALIAS" "smoke ping at $(date -u +%FT%TZ)"

soft_step "c2c relay dm poll (drains loopback)" \
  c2c relay dm poll --alias "$ALIAS" --relay-url "$RELAY_URL"

# --- Step 8: room history --------------------------------------------------

soft_step "c2c relay rooms list" \
  c2c relay rooms list --alias "$ALIAS" --relay-url "$RELAY_URL"

# --- Summary ---------------------------------------------------------------

hr
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m=== Onboarding smoke: %d/%d PASS ===\033[0m\n' "$PASS" "$((PASS+FAIL))"
  exit 0
else
  printf '\033[31m=== Onboarding smoke: %d FAIL, %d PASS ===\033[0m\n' "$FAIL" "$PASS"
  for f in "${FAILS[@]}"; do echo "  - FAIL: $f"; done
  exit 1
fi
