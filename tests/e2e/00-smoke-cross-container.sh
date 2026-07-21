#!/usr/bin/env bash
# #407 S2 — cross-broker DM smoke via the relay.
#
# Boots the e2e multi-agent topology (relay + 4 agents across 2 broker
# volumes), attempts an unsolicited DM from agent-a1 (broker A) to private
# agent-b1 (broker B), and proves the relay rejects it without delivery.
# Cross-broker traffic MUST go via the relay container — the two volumes are
# independent. Authorised contact delivery is covered by the grant/handler
# matrix suites; this smoke pins the containerised private-by-default boundary.
#
# Modes:
#   00-smoke-cross-container.sh                 # full up + send + assert + down
#   00-smoke-cross-container.sh --validate      # `docker compose config` only
#   00-smoke-cross-container.sh --build-only    # build images, do not `up`
#   00-smoke-cross-container.sh --no-teardown   # leave stack up on success
#   00-smoke-cross-container.sh --skip-build    # assume images pre-built (CI)
#
# Idempotent: cleanup trap always runs unless --no-teardown is passed.
# Exits 0 only when the private first-contact denial and non-delivery are verified.
#
# Run from repo root.

set -euo pipefail

MODE="full"
NO_TEARDOWN=0
SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --validate|--validate-only) MODE="validate" ;;
    --build-only) MODE="build" ;;
    --no-teardown) NO_TEARDOWN=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *) echo "[smoke] unknown arg: $arg" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_FILE="docker-compose.e2e-multi-agent.yml"
if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "[smoke] missing $COMPOSE_FILE — are you in the repo root?" >&2
  exit 2
fi

COMPOSE=(docker compose -f "$COMPOSE_FILE")

# --- validate-only path: no daemon interaction beyond config parsing.
if [[ "$MODE" == "validate" ]]; then
  echo "[smoke] mode=validate — checking compose syntax only"
  "${COMPOSE[@]}" config --quiet
  bash -n "$0"
  echo "[smoke] PASS — compose + script syntax OK"
  exit 0
fi

# --- need docker daemon for everything below.
if ! docker info >/dev/null 2>&1; then
  echo "[smoke] docker daemon unreachable — cannot proceed" >&2
  exit 2
fi

cleanup() {
  local rc=$?
  if [[ "$NO_TEARDOWN" == "1" && "$rc" == "0" ]]; then
    echo "[smoke] --no-teardown set + PASS, leaving stack up"
    return
  fi
  echo "[smoke] tearing down..."
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ "$MODE" == "build" ]]; then
  echo "[smoke] mode=build — building images only"
  DOCKER_BUILDKIT=1 "${COMPOSE[@]}" build
  echo "[smoke] PASS — images built"
  # On --build-only success, suppress teardown (no stack came up).
  trap - EXIT
  exit 0
fi

# --- full smoke path.
if [[ "$SKIP_BUILD" == "1" ]]; then
  echo "[smoke] starting topology (images pre-built)..."
  "${COMPOSE[@]}" up -d --wait --wait-timeout 60
else
  echo "[smoke] building + starting topology..."
  DOCKER_BUILDKIT=1 "${COMPOSE[@]}" up -d --build --wait --wait-timeout 60
fi

echo "[smoke] confirming relay healthy..."
status=$(docker inspect --format '{{.State.Health.Status}}' c2c-e2e-relay 2>/dev/null || echo "missing")
if [[ "$status" != "healthy" ]]; then
  echo "[smoke] relay healthcheck status=$status — aborting" >&2
  docker logs --tail 50 c2c-e2e-relay 2>&1 || true
  exit 1
fi

TS=$(date +%s)
MSG="smoke-cross-host-${TS}"

RELAY_URL="http://relay:7331"

# Cross-broker delivery uses the relay-aware path
# (`c2c relay register / dm send / dm poll`), NOT bare `c2c send`.
# Bare `c2c send <alias>` looks the alias up in the LOCAL broker
# only — agent-b1 lives on broker-b, so from agent-a1's broker
# (broker-a) it is unknown ("error: unknown alias: agent-b1"). The
# relay is the cross-broker bridge by design; the relay-aware
# subcommands are the explicit way to use it.
echo "[smoke] initializing identities + registering on relay..."
for c in c2c-e2e-agent-a1 c2c-e2e-agent-b1; do
  docker exec -e C2C_CLI_FORCE=1 "${c}" c2c relay identity init >/dev/null
done
docker exec -e C2C_CLI_FORCE=1 c2c-e2e-agent-a1 \
  c2c relay register --alias agent-a1 --relay-url "${RELAY_URL}" >/dev/null
docker exec -e C2C_CLI_FORCE=1 c2c-e2e-agent-b1 \
  c2c relay register --alias agent-b1 --relay-url "${RELAY_URL}" >/dev/null

echo "[smoke] unsolicited agent-a1 -> private agent-b1 (via relay): ${MSG}"
set +e
send_out=$(docker exec -e C2C_CLI_FORCE=1 c2c-e2e-agent-a1 \
  c2c relay dm send agent-b1 "${MSG}" --alias agent-a1 \
    --relay-url "${RELAY_URL}" 2>&1)
send_rc=$?
set -e
printf '%s\n' "${send_out}"
if [[ "${send_rc}" == "0" ]]; then
  echo "[smoke] FAIL — unsolicited private DM unexpectedly succeeded" >&2
  exit 1
fi
if ! printf '%s' "${send_out}" | grep -q 'contact_unauthorised'; then
  echo "[smoke] FAIL — private denial was not contact_unauthorised (rc=${send_rc})" >&2
  exit 1
fi

echo "[smoke] confirming rejected content never reached agent-b1..."
out=$(docker exec -e C2C_CLI_FORCE=1 c2c-e2e-agent-b1 \
      c2c relay dm poll --alias agent-b1 --relay-url "${RELAY_URL}" 2>/dev/null || echo "")
if printf '%s' "${out}" | grep -q "${MSG}"; then
  echo "[smoke] FAIL — rejected private DM appeared in agent-b1 inbox" >&2
  exit 1
fi

echo "[smoke] PASS — unsolicited private cross-broker DM was denied and not delivered"
exit 0
