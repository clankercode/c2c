#!/usr/bin/env bash
# DRAFT — #407 S2 smoke. Promote to .sh after S1 compose lands.
#
# Boots the e2e multi-agent topology, sends a DM from agent-a1
# (host-A broker) to agent-b1 (host-B broker), verifies receipt
# on b1. Cross-broker delivery MUST go via the relay container.
#
# Run from repo root.

set -euo pipefail

COMPOSE=(
  docker compose
  -f docker-compose.test.yml
  -f docker-compose.e2e-multi-agent.yml
)

cleanup() {
  echo "[smoke] tearing down..."
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[smoke] building + starting topology..."
DOCKER_BUILDKIT=1 "${COMPOSE[@]}" up -d --build

echo "[smoke] waiting for relay healthcheck..."
for _ in $(seq 1 30); do
  status=$(docker inspect --format '{{.State.Health.Status}}' c2c-e2e-relay 2>/dev/null || echo "starting")
  [[ "$status" == "healthy" ]] && break
  sleep 1
done
[[ "$status" == "healthy" ]] || { echo "[smoke] relay never went healthy"; exit 1; }

TS=$(date +%s)
MSG="smoke-cross-host-${TS}"

echo "[smoke] registering agent-a1 + agent-b1..."
docker exec -e C2C_CLI_FORCE=1 c2c-e2e-agent-a1 c2c register --alias agent-a1 >/dev/null
docker exec -e C2C_CLI_FORCE=1 c2c-e2e-agent-b1 c2c register --alias agent-b1 >/dev/null

echo "[smoke] agent-a1 -> agent-b1: ${MSG}"
docker exec -e C2C_CLI_FORCE=1 c2c-e2e-agent-a1 c2c send agent-b1 "${MSG}"

echo "[smoke] polling agent-b1 inbox (up to 10s)..."
for _ in $(seq 1 10); do
  out=$(docker exec -e C2C_CLI_FORCE=1 c2c-e2e-agent-b1 c2c poll-inbox --json 2>/dev/null || echo "[]")
  if echo "${out}" | grep -q "${MSG}"; then
    echo "[smoke] PASS — agent-b1 received '${MSG}'"
    exit 0
  fi
  sleep 1
done

echo "[smoke] FAIL — agent-b1 did not receive '${MSG}' within 10s"
echo "[smoke] last poll output: ${out}"
echo "[smoke] relay logs:"
docker logs --tail 50 c2c-e2e-relay || true
exit 1
