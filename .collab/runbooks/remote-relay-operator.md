# Remote Relay Operator Runbook

**Audience**: c2c operators deploying a relay with remote broker polling.
**Goal**: deploy a working remote relay node from scratch without re-discovering known failure modes.

---

## TL;DR

```bash
# 1. Prerequisites (see §1)
ssh-copy-id operator@remote-broker-host
# generate token:
TOKEN=$(openssl rand -hex 24)

# 2. Start relay (see §2)
c2c relay serve \
  --listen 0.0.0.0:7331 \
  --relay-name relay.example.com \
  --token "$TOKEN" \
  --remote-broker-ssh-target operator@remote-broker-host \
  --remote-broker-root /home/operator/.local/share/c2c \
  --remote-broker-id my-broker

# 3. Verify (see §3)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:7331/remote_inbox/some-session-id
```

---

## §1 — Prerequisites

### 1.1 Passwordless SSH to remote broker host

Remote relay uses SSH to poll the broker's inbox directory. Public-key auth is required.

**On the relay host** (as the operator user that will run `c2c relay serve`):

```bash
# Check for existing key
ls ~/.ssh/id_ed25519.pub 2>/dev/null || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519

# Add to authorized_keys on remote broker host
ssh-copy-id operator@remote-broker-host

# Verify passwordless access
ssh -o BatchMode=yes operator@remote-broker-host echo "SSH works"
```

If `ssh-copy-id` is not available:

```bash
cat ~/.ssh/id_ed25519.pub | ssh operator@remote-broker-host \
  "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

**Host key warning**: The relay adds `-o StrictHostKeyChecking=no` to all SSH commands, so first-time connections to new hosts work without manual intervention. This is safe for private networks.

### 1.2 Broker root conventions

The remote broker root must be accessible at the SSH target. The standard location is:

```
~/.local/share/c2c/
├── registry.json        # registration database
├── inbox/              # per-session message queues
│   ├── session-id-1.json
│   └── session-id-2.json
├── archive/            # message archives (optional)
└── rooms/              # room data (optional)
```

Confirm the path exists on the remote host before starting the relay:

```bash
ssh operator@remote-broker-host "ls ~/.local/share/c2c/inbox/ | head -3"
```

### 1.3 Token generation

The relay requires a Bearer token to authenticate admin endpoints including `/remote_inbox/`. Generate a strong random token:

```bash
# Generate a 48-character hex token (24 bytes)
TOKEN=$(openssl rand -hex 24)
echo "Token: $TOKEN"
# Save it somewhere safe — you'll need it for all relay admin operations
echo "$TOKEN" > ~/.config/c2c/relay.token
chmod 600 ~/.config/c2c/relay.token
```

---

## §2 — First-Boot Flow

### 2.1 Start the relay

```bash
c2c relay serve \
  --listen 0.0.0.0:7331 \
  --relay-name relay.example.com \
  --token "$TOKEN" \
  --remote-broker-ssh-target operator@remote-broker-host \
  --remote-broker-root /home/operator/.local/share/c2c \
  --remote-broker-id my-broker
```

`--relay-name` (#379) is this relay's well-known host name for cross-host
alias resolution. When senders use `<alias>@<host>` form, the relay strips
and resolves the bare alias only when `<host>` matches this name (or the
literal `"relay"` back-compat or empty). Other `<host>` parts dead-letter
with reason `cross_host_not_implemented`. Defaults to the `--listen` host
if omitted; in production you almost always want to set it explicitly to
the public DNS name peers will address.

**Expected output** (first ~10 lines):
```
██████╗██████╗ ██████╗
██╔════╝╚════██╗██╔════╝
██║      █████╔╝██║
██║     ██╔═══╝ ██║
╚██████╗███████╗╚██████╗
 ╚═════╝╚══════╝ ╚═════╝  relay-server v0.8.0  build=dev
listen=0.0.0.0:7331
relay-name=relay.example.com
storage: memory
remote-broker: polling operator@remote-broker-host:/home/operator/.local/share/c2c
auth: enabled (Bearer token)
gc: disabled
```

**Key lines to verify**:
- `listen=0.0.0.0:7331` — correct bind address
- `remote-broker: polling …` — SSH target and broker root correct
- `auth: enabled` — token is set (prod mode)

### 2.2 Run under supervision (recommended)

Use `tmux` or `systemd` to keep the relay alive:

```bash
# tmux session
tmux new -s c2c-relay -d \
  "c2c relay serve \
    --listen 0.0.0.0:7331 \
    --token \"$TOKEN\" \
    --remote-broker-ssh-target operator@remote-broker-host \
    --remote-broker-root /home/operator/.local/share/c2c \
    --remote-broker-id my-broker"

# Watch the session
tmux attach -t c2c-relay

# Stop
tmux kill-session -t c2c-relay
```

Or with systemd (`/etc/systemd/system/c2c-relay.service`):

```ini
[Unit]
Description=c2c Remote Relay Server
After=network.target

[Service]
ExecStart=/home/operator/.local/bin/c2c relay serve \
    --listen 0.0.0.0:7331 \
    --token-file /home/operator/.config/c2c/relay.token \
    --remote-broker-ssh-target operator@remote-broker-host \
    --remote-broker-root /home/operator/.local/share/c2c \
    --remote-broker-id my-broker
User=operator
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

---

## §3 — Verifying the Deploy

### 3.1 Health check

```bash
curl -s http://localhost:7331/health
# Expected: {"ok": true, "version": "…", "relay_id": "…"}
```

### 3.2 Remote inbox poll (with auth)

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:7331/remote_inbox/some-session-id
```

**Expected responses**:

| Condition | HTTP status | Body |
|---|---|---|
| Session has messages | 200 | `{"messages": [{"message_id": "…", "from_alias": "…", ...}]}` |
| Session has no messages | 200 | `{"messages": []}` |
| No auth header | 401 | `{"ok": false, "error": "admin route requires Bearer token"}` |
| Wrong token | 401 | `{"ok": false, "error": "admin route requires Bearer token"}` |

### 3.3 End-to-end smoke test

From a host that has the c2c binary and is configured as a remote node:

```bash
# Register a session on the remote broker (on the remote host)
ssh operator@remote-broker-host \
  "echo '[{\"message_id\":\"smoke-001\",\"from_alias\":\"test-sender\",\"to_alias\":\"test-session\",\"content\":\"hello\",\"ts\":$(date +%s)}]' > ~/.local/share/c2c/inbox/test-session.json"

# Poll from the relay
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:7331/remote_inbox/test-session
# Expected: message appears in response
```

---

## §4 — Common Failure Modes

### 4.1 SSH connection fails

**Symptom**: Relay starts but remote inbox polls always return empty, no SSH traffic to remote host.

**Diagnosis**:
```bash
# Manual SSH test from relay host
ssh -v -o BatchMode=yes operator@remote-broker-host "echo connected"
# Look for "Authenticated" in output
```

**Fixes**:
- Verify public key is in `~/.ssh/authorized_keys` on remote host
- Check SSH agent is running: `ssh-add -l`
- For non-default key location: add `IdentityFile ~/.ssh/my_key` to `~/.ssh/config`

### 4.2 ANSI escape codes in session listing

**Symptom**: `list_remote_sessions` returns garbled session names with ANSI escape sequences, or empty list.

**Cause**: `ls --color=auto` outputs ANSI color codes when connected to a TTY, which corrupts session name parsing.

**Fix**: The relay always uses `ls --color=never` internally. If you manually SSH, use `--color=never`:

```bash
ssh operator@remote-broker-host "ls --color=never ~/.local/share/c2c/inbox/"
```

### 4.3 Off-by-one path length: 404 on `/remote_inbox/<id>`

**Symptom**: `GET /remote_inbox/test-session` returns 404 or empty instead of messages.

**Cause**: Historical bug — the route prefix was matched as 13 chars (`"/remote_inbox"`, 13 chars) instead of 14 (`"/remote_inbox/"`). This is **fixed in v0.8.0+**.

**Verify your version**:
```bash
c2c --version  # should be 0.8.0 or later
```

**If on older version**: upgrade and rebuild:
```bash
cd /path/to/c2c && git pull && just install-all
```

### 4.4 Auth rejected: "admin route requires Bearer token"

**Symptom**: `GET /remote_inbox/<id>` returns 401 even with a token.

**Causes and fixes**:

1. **Token not set when starting relay**: Restart relay with `--token`:
   ```bash
   # Wrong (no token = dev mode):
   c2c relay serve --listen 0.0.0.0:7331 ...

   # Correct (prod mode):
   c2c relay serve --listen 0.0.0.0:7331 --token "$TOKEN" ...
   ```

2. **Wrong token value**: Verify the token matches what you generated:
   ```bash
   # Check what token the relay was started with (if using token file)
   cat ~/.config/c2c/relay.token

   # Verify with curl
   curl -s -H "Authorization: Bearer YOUR_TOKEN" \
     http://localhost:7331/health
   ```

3. **Token file not readable**: If using `--token-file`, ensure permissions are 600:
   ```bash
   chmod 600 ~/.config/c2c/relay.token
   ```

### 4.5 Dev mode is open (no auth)

**Symptom**: `curl http://localhost:7331/remote_inbox/<id>` works without any auth header.

**Cause**: Relay was started without `--token` flag. This is **correct behavior for development only**.

**Fix**: Restart relay with `--token`. Dev mode has no auth — do not expose dev-mode relays on public IPs.

### 4.6 Empty inbox always returned

**Symptom**: `GET /remote_inbox/<id>` returns `{"messages": []}` even when messages exist on remote broker.

**Diagnosis**:
```bash
# Check remote broker inbox directly
ssh operator@remote-broker-host "cat ~/.local/share/c2c/inbox/your-session-id.json"

# Check relay logs for SSH errors
# (relay outputs to stdout/stderr — check tmux or journal)
```

**Possible causes**:
- Session ID mismatch: inbox file is named `<session_id>.json` — ensure exact match
- Permissions: relay SSH user can't read the inbox directory
- Broker root wrong: verify `--remote-broker-root` matches actual broker root on remote host

---

## §5 — Rollback Plan

### 5.1 Immediate rollback: disable remote broker polling

Remove the remote broker flags and restart the relay — it continues serving local traffic without remote polling:

```bash
# Old command with remote broker:
c2c relay serve --listen 0.0.0.0:7331 --token "$TOKEN" \
  --remote-broker-ssh-target operator@remote-broker-host \
  --remote-broker-root /home/operator/.local/share/c2c \
  --remote-broker-id my-broker

# Rollback: remove remote broker flags:
c2c relay serve --listen 0.0.0.0:7331 --token "$TOKEN"
```

### 5.2 Full rollback: stop the relay

```bash
# If running in tmux:
tmux kill-session -t c2c-relay

# If running under systemd:
sudo systemctl stop c2c-relay
sudo systemctl disable c2c-relay
```

### 5.3 Reverting to pre-remote-relay state

The remote relay feature is **additive** — removing the remote broker flags returns the relay to local-only mode. No data migration is needed. All local registrations, rooms, and messages remain intact.

---

## Quick Reference

```bash
# Generate token
TOKEN=$(openssl rand -hex 24)

# Start relay
c2c relay serve \
  --listen 0.0.0.0:7331 \
  --relay-name relay.example.com \
  --token "$TOKEN" \
  --remote-broker-ssh-target user@host \
  --remote-broker-root ~/.local/share/c2c \
  --remote-broker-id my-broker

# Poll remote inbox
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:7331/remote_inbox/session-id

# Check health
curl -s http://localhost:7331/health
```
