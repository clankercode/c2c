# Finding: #407 S5 implementation — key path discoveries

**Time (UTC):** 2026-04-29 ~01:00
**Alias:** birch-coder
**Issue:** #407 S5 — signing keys provisioning E2E
**Severity:** info (implementation note)

## Key discoveries

### 1. Identity and artifact paths inside E2E containers

`c2c relay identity init` (layer 3 relay identity, separate from broker) stores:
- **Private key + identity:** `~/.config/c2c/identity.json` — inside the container
  this resolves to `/home/testagent/.config/c2c/identity.json` when run as
  the `testagent` user (uid 1000, the unprivileged runtime user in
  `Dockerfile.test`).
- **Peer-pass artifacts:** `~/.cache/c2c/peer-passes/<sha>-<alias>.json`
  — resolves to `/home/testagent/.cache/c2c/peer-passes/<sha>-<alias>.json`.

These paths are independent of `C2C_MCP_BROKER_ROOT` (/var/lib/c2c), which
is the broker layer.

### 2. Running as testagent user

`_signing_helpers.py` (cedar's fixture module) runs commands via:
```bash
docker exec <container> sudo -u testagent \
  -e C2C_CLI_FORCE=1 -e C2C_IN_DOCKER=1 \
  /usr/local/bin/c2c <command>
```
This requires `sudo` to be installed in `Dockerfile.test`. It was missing
and needed to be added (`apt-get install sudo`).

### 3. Cross-container artifact transfer

agent-a1 (broker-a) and agent-b1 (broker-b) have **independent broker
volumes** — copying to `/var/lib/c2c/` on one is NOT visible on the other.
The correct approach is `docker cp` which routes through the Docker host
filesystem, bypassing container networking. `artifact_copy_across_broker()` in
`_signing_helpers.py` does this correctly.

### 4. Shared git volume for test commit

The `make_test_commit_in_container()` helper creates a bare git repo at
`/tmp/s5-test-repo` inside the container. This is a local path — both
agent-a1 and agent-b1 have the `s5-git` named volume mounted at
`/tmp/s5-shared.git`, so they can share the git repo via that volume.

### 5. Compose file state

`docker-compose.e2e-multi-agent.yml` was deleted from origin/master during
the course of this work (due to my reset error). The canonical copy is in
the S1 worktree (`.worktrees/407-s1-e2e-baseline/`). When S5 lands, the
compose file must be committed to origin/master as part of the S5 artifact.

## Status

**Closed — implementation complete. Peer-PASS in progress (slate-coder).**
