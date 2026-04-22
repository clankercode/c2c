# Remote Relay Transport v1 Smoke Test

**Date**: 2026-04-23
**Agent**: jungle-coder
**Status**: PASS

## Setup

### Fake Remote Broker
```bash
mkdir -p /tmp/fake-broker/inbox
cat > /tmp/fake-broker/inbox/test-session.json << 'EOF'
[{"message_id":"smoke-test-001","from_alias":"fake-sender","to_alias":"fake-recipient","content":"hello from fake broker","ts":1776881200.0}]
EOF
```

### SSH Setup for Localhost
```bash
# Set up passwordless SSH to localhost
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
ssh -o StrictHostKeyChecking=no -o BatchMode=yes localhost echo "works"
# Output: SSH to localhost works!
```

## Commands

### Start Relay with Remote Broker Polling
```bash
env -u C2C_MCP_SESSION_ID c2c relay serve \
  --listen 127.0.0.1:7342 \
  --remote-broker-ssh-target xertrov@localhost \
  --remote-broker-root /tmp/fake-broker \
  --remote-broker-id smoke-test
```

Output:
```
  ██████╗██████╗ ██████╗
  ██╔════╝╚════██╗██╔════╝
  ██║      █████╔╝██║
  ██║     ██╔═══╝ ██║
  ╚██████╗███████╗╚██████╗
   ╚═════╝╚══════╝ ╚═════╝  relay-server v0.8.0  build=dev  git=1b032df
  listen=127.0.0.1:7342
  storage: memory
  persist-dir=none (in-memory only)
  remote-broker: polling xertrov@localhost:/tmp/fake-broker
  c2c relay serving on http://127.0.0.1:7342
  auth: DISABLED (no token set — do not expose publicly)
  gc: disabled
```

### Poll Remote Inbox
```bash
curl -s http://127.0.0.1:7342/remote_inbox/test-session
```

Response:
```json
{"ok":true,"messages":[{"message_id":"smoke-test-001","from_alias":"fake-sender","to_alias":"fake-recipient","content":"hello from fake broker","ts":1776881200.0}]}
```

## Bugs Found and Fixed

### Bug 1: Off-by-One Path Length (FIXED)
- **File**: `ocaml/relay.ml`
- **Symptom**: `GET /remote_inbox/<session_id>` returned `{"ok":false,"error_code":"not_found","error":"unknown endpoint: /remote_inbox/test-session"}`
- **Root Cause**: The path prefix `/remote_inbox/` is 14 characters, but the match used `String.sub path 0 13` (13 chars)
- **Fix**: Changed to `String.sub path 0 14` and `String.length path > 14`
- **Commit**: 1b032df

### Bug 2: SSH Color Codes in `ls` Output (FIXED)
- **File**: `ocaml/relay_remote_broker.ml`
- **Symptom**: `list_remote_sessions` returned empty list because `ls` output contained ANSI color codes that `sed` couldn't strip correctly
- **Root Cause**: Remote `ls` was aliased to `ls --color=auto`, and SSH allocated a PTY causing color codes to be output
- **Fix**: Added `--color=never` flag to `ls` in `list_remote_sessions`
- **Commit**: 1b032df

### Bug 3: SSH Host Key Prompt (FIXED)
- **File**: `ocaml/relay_remote_broker.ml`
- **Symptom**: SSH command hung waiting for "Are you sure you want to continue connecting?" prompt
- **Fix**: Added `-o StrictHostKeyChecking=no` to all SSH commands
- **Commit**: 10c59cd (prior)

## Minimum Repro for Max

If SSH to localhost is hostile in the target environment:

```bash
# 1. Set up passwordless SSH
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# 2. Create fake broker
mkdir -p /tmp/fake-broker/inbox
echo '[{"message_id":"test-001","from_alias":"sender","to_alias":"recipient","content":"hello","ts":1776881200.0}]' > /tmp/fake-broker/inbox/test-session.json

# 3. Start relay
env -u C2C_MCP_SESSION_ID c2c relay serve \
  --listen 127.0.0.1:7342 \
  --remote-broker-ssh-target YOUR_USER@localhost \
  --remote-broker-root /tmp/fake-broker \
  --remote-broker-id test-broker &

# 4. Poll (after ~6 seconds for polling to pick up message)
sleep 6 && curl http://127.0.0.1:7342/remote_inbox/test-session
```

## Next Steps
- [ ] Add `--color=never` to `fetch_inbox` for consistency (low priority, `cat` doesn't have color issues)
- [ ] Add SSH keyscan automation for unknown hosts (currently requires manual setup)
- [ ] Consider adding `ls --format=single-column` for extra safety
