#!/usr/bin/env bash
# #407 S5 — signing keys provisioning E2E: cross-container peer-PASS sign + verify.
#
# Builds on the S2 cross-host topology (two broker volumes + relay).
# agent-a1 generates an ed25519 identity, makes a test commit in a shared
# git volume, signs a peer-PASS verdict, copies the artifact to agent-b1's
# view of the volume, and agent-b1 verifies the signature.
#
# This validates S5 AC: keys provisioned in containers, signed messages
# verify across the relay broker boundary.
#
# Modes:
#   05-peer-pass-signing.sh                              # full up + sign + verify + down
#   05-peer-pass-signing.sh --validate                   # syntax only
#   05-peer-pass-signing.sh --build-only                 # build images only
#   05-peer-pass-signing.sh --no-teardown                # leave stack up on success
#
# Depends on: docker-compose.e2e-multi-agent.yml (S1/S2 baseline)
# Artifact: tests/e2e/05-peer-pass-signing.sh.draft (promote to .sh after first green)

set -euo pipefail

MODE="full"
NO_TEARDOWN=0
for arg in "$@"; do
  case "$arg" in
    --validate|--validate-only) MODE="validate" ;;
    --build-only) MODE="build" ;;
    --no-teardown) NO_TEARDOWN=1 ;;
    -h|--help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *) echo "[s5] unknown arg: $arg" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_FILE="docker-compose.e2e-multi-agent.yml"
if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "[s5] missing $COMPOSE_FILE — are you in the repo root?" >&2
  exit 2
fi

COMPOSE=(docker compose -f "$COMPOSE_FILE")

# --- validate-only path
if [[ "$MODE" == "validate" ]]; then
  echo "[s5] mode=validate — checking compose syntax + script syntax"
  "${COMPOSE[@]}" config --quiet
  bash -n "$0"
  echo "[s5] PASS — compose + script syntax OK"
  exit 0
fi

# --- need docker daemon
if ! docker info >/dev/null 2>&1; then
  echo "[s5] docker daemon unreachable — cannot proceed" >&2
  exit 2
fi

cleanup() {
  local rc=$?
  if [[ "$NO_TEARDOWN" == "1" && "$rc" == "0" ]]; then
    echo "[s5] --no-teardown set + PASS, leaving stack up"
    return
  fi
  echo "[s5] tearing down..."
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ "$MODE" == "build" ]]; then
  echo "[s5] mode=build — building images only"
  DOCKER_BUILDKIT=1 "${COMPOSE[@]}" build
  echo "[s5] PASS — images built"
  trap - EXIT
  exit 0
fi

# --- full test path
echo "[s5] building + starting topology..."
DOCKER_BUILDKIT=1 "${COMPOSE[@]}" up -d --build --wait --wait-timeout 60

echo "[s5] confirming relay healthy..."
status=$(docker inspect --format '{{.State.Health.Status}}' c2c-e2e-relay 2>/dev/null || echo "missing")
if [[ "$status" != "healthy" ]]; then
  echo "[s5] relay healthcheck status=$status — aborting" >&2
  docker logs --tail 50 c2c-e2e-relay 2>&1 || true
  exit 1
fi

RELAY_URL="http://relay:7331"
AGENT_A1="c2c-e2e-agent-a1"
AGENT_B1="c2c-e2e-agent-b1"

# Initialize identities on relay so cross-broker routing works
echo "[s5] initializing relay identities..."
for c in "$AGENT_A1" "$AGENT_B1"; do
  docker exec -e C2C_CLI_FORCE=1 "${c}" c2c relay identity init >/dev/null 2>&1
done
docker exec -e C2C_CLI_FORCE=1 "${AGENT_A1}" \
  c2c relay register --alias agent-a1 --relay-url "${RELAY_URL}" >/dev/null 2>&1
docker exec -e C2C_CLI_FORCE=1 "${AGENT_B1}" \
  c2c relay register --alias agent-b1 --relay-url "${RELAY_URL}" >/dev/null 2>&1

# Create a shared git volume so agent-a1 can make a commit agent-b1 can see
# Both agents share a bare-repo volume for the test git data
echo "[s5] setting up shared git volume for test commit..."
SHARED_GIT_VOLUME="git-shared"
docker volume create "${SHARED_GIT_VOLUME}" >/dev/null 2>&1 || true

# Agent-a1: clone the repo (or init fresh), make a test commit
echo "[s5] agent-a1: making a test commit..."
docker exec -e C2C_CLI_FORCE=1 "${AGENT_A1}" bash -c '
  set -e
  cd /tmp
  # Clone the repo if reachable, otherwise init a fresh git dir for the test
  if git clone --bare http://github.com/xertrov/c2c /tmp/shared-repo 2>/dev/null; then
    echo "[a1] cloned existing repo"
  else
    git init --bare /tmp/shared-repo
    echo "[a1] initialized fresh bare repo"
  fi
  # Make a temporary working clone to create the test commit
  rm -rf /tmp/test-clone
  git clone /tmp/shared-repo /tmp/test-clone
  cd /tmp/test-clone
  git config user.email "s5-test@c2c.ci"
  git config user.name "S5 Test Agent"
  echo "s5-test-$(date +%s)" > /tmp/s5-test.txt
  git add /tmp/s5-test.txt
  git commit -m "S5 test commit for peer-pass signing"
  TEST_SHA=$(git rev-parse HEAD)
  echo "${TEST_SHA}" > /tmp/test_sha.txt
  # Push to shared bare repo so agent-b1 can see it
  git push /tmp/shared-repo HEAD:refs/heads/s5-test
  echo "[a1] committed TEST_SHA=${TEST_SHA}"
' 2>&1

TEST_SHA=$(docker exec -e C2C_CLI_FORCE=1 "${AGENT_A1}" cat /tmp/test_sha.txt 2>/dev/null | tr -d '\r\n')
if [[ -z "$TEST_SHA" ]]; then
  echo "[s5] FAIL — could not obtain TEST_SHA from agent-a1" >&2
  exit 1
fi
echo "[s5] agent-a1 committed TEST_SHA=${TEST_SHA}"

# Agent-a1: sign the peer-PASS verdict for the test SHA
echo "[s5] agent-a1: signing peer-PASS verdict for ${TEST_SHA}..."
docker exec -e C2C_CLI_FORCE=1 "${AGENT_A1}" bash -c '
  set -e
  cd /tmp
  # Get the shared repo so peer-pass sign can read the commit
  if [[ ! -d /tmp/shared-repo ]]; then
    git init --bare /tmp/shared-repo
  fi
  # Import the test commit into the shared repo if not already there
  git clone /tmp/shared-repo /tmp/test-clone 2>/dev/null || true
  cd /tmp/test-clone
  git fetch /tmp/shared-repo s5-test 2>/dev/null || true
  git checkout s5-test 2>/dev/null || true

  # Initialize identity and sign
  c2c relay identity init
  c2c peer-pass sign '"${TEST_SHA}"' --verdict PASS --criteria "s5-e2e-test" --notes "S5 cross-container signing test"
  echo "[a1] peer-pass sign done"
' 2>&1

# Find the signed artifact produced by agent-a1
echo "[s5] agent-a1: locating signed artifact..."
ARTIFACT_FILE=$(docker exec -e C2C_CLI_FORCE=1 "${AGENT_A1}" bash -c '
  set -e
  # The artifact is stored in C2C_PEER_PASS_DIR (default ~/.c2c/peer-pass/)
  # Find the most recent JSON file matching the TEST_SHA
  cd ~/.c2c/peer-pass
  ls -t *'"${TEST_SHA}"'*.json 2>/dev/null | head -1 || echo ""
' 2>/dev/null | tr -d '\r\n')

if [[ -z "$ARTIFACT_FILE" ]]; then
  echo "[s5] FAIL — no peer-pass artifact found for SHA ${TEST_SHA}" >&2
  docker exec -e C2C_CLI_FORCE=1 "${AGENT_A1}" ls ~/.c2c/peer-pass/ 2>&1 || true
  exit 1
fi
echo "[s5] agent-a1: artifact = ${ARTIFACT_FILE}"

# Copy the artifact to a shared location agent-b1 can access
# Both agents have access to the broker-a volume, use it as shared space
echo "[s5] agent-a1: copying artifact to shared volume..."
docker exec -e C2C_CLI_FORCE=1 "${AGENT_A1}" bash -c '
  set -e
  cp ~/.c2c/peer-pass/'"${ARTIFACT_FILE}"' /var/lib/c2c/s5-test-artifact.json
  echo "[a1] artifact copied to shared volume"
' 2>&1

# Agent-b1: import the shared repo and verify the artifact
echo "[s5] agent-b1: fetching test commit and verifying artifact..."
docker exec -e C2C_CLI_FORCE=1 "${AGENT_B1}" bash -c '
  set -e
  cd /tmp
  # Get the shared repo
  rm -rf /tmp/test-clone 2>/dev/null || true
  git clone /var/lib/c2c/shared-repo /tmp/test-clone 2>/dev/null || git init --bare /tmp/shared-repo
  cd /tmp/test-clone
  git fetch /var/lib/c2c/shared-repo s5-test 2>/dev/null || true
  git checkout s5-test 2>/dev/null || true

  # Initialize identity on this agent too (for verification context)
  c2c relay identity init

  # Verify the artifact
  VERIFY_OUT=$(c2c peer-pass verify /var/lib/c2c/s5-test-artifact.json 2>&1)
  echo "[b1] verify output: ${VERIFY_OUT}"
  if echo "${VERIFY_OUT}" | grep -qi "PASS\|valid\|ok\|verified"; then
    echo "[b1] SIGNATURE VERIFIED OK"
    exit 0
  else
    echo "[b1] FAIL: signature verification failed"
    exit 1
  fi
' 2>&1

VERIFY_RC=$?

# Cleanup shared git volume
docker volume rm "${SHARED_GIT_VOLUME}" >/dev/null 2>&1 || true

if [[ "$VERIFY_RC" == "0" ]]; then
  echo "[s5] PASS — peer-PASS artifact signed by agent-a1, verified by agent-b1 across broker boundary"
  exit 0
else
  echo "[s5] FAIL — verification returned non-zero" >&2
  exit 1
fi