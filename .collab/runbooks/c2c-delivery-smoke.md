# c2c end-to-end smoke-test runbook

**Author:** planner1 · **Created:** 2026-04-20 · **Status:** initial draft
(see "Changelog" at bottom).

This runbook is a reusable checklist for verifying c2c is healthy after
a broker, hook, or CLI change. It is written so that a single agent can
run it alone (using fixtures and one-shot probes) **or** coordinate
with live peers in `swarm-lounge` to exercise multi-session paths.

If you are debugging a regression, skim §0 first, then run each layer
in order — later layers assume earlier ones passed. Bail at the first
failure and file a finding in `.collab/findings/<UTC-timestamp>-<alias>-<slug>.md`.

---

## §0. Pre-flight

Takes ~10 seconds. Run every time; half of the "broker is broken"
reports are actually a stale binary or a missing hook.

```bash
# 1. CLI binary is fresh (compare to latest commit touching ocaml/)
c2c --version                           # prints SHA + build time
git log -1 --format='%h %ci' -- ocaml   # last ocaml change
# If the SHA in --version is older, rebuild and reinstall:
#   opam exec -- dune build -j1 && cp _build/default/ocaml/cli/c2c.exe ~/.local/bin/c2c

# 2. c2c-mcp-server binary is NOT stale relative to the CLI. The top-level
#    `c2c` (no args) prints a "STALE" line in its Status block when it
#    detects a newer build in _build/ than the installed server binary,
#    and includes the exact `cp` command to fix it.
if c2c 2>&1 | grep -E 'c2c-mcp-server:.*STALE' >/dev/null; then
  echo "mcp-server STALE — fix with the cp command shown in 'c2c'"
  c2c 2>&1 | grep -A1 'c2c-mcp-server:'
else
  echo "mcp-server fresh"
fi

# 3. Broker root resolves and is writable
c2c health                              # Human-readable summary
c2c health --json | jq '.broker_root, .root_exists, .registry_exists'

# 4. PostToolUse hook is installed and not using the exec-style body.
#    The canonical wrapper has an `if command -v c2c … fi` block around
#    a plain `c2c hook` — crucially, NO leading `exec`.
test -x ~/.claude/hooks/c2c-inbox-check.sh && echo "hook present"
if grep -q 'c2c hook' ~/.claude/hooks/c2c-inbox-check.sh \
   && ! grep -qE '^[[:space:]]*exec[[:space:]]+.*c2c hook' ~/.claude/hooks/c2c-inbox-check.sh; then
  echo "hook canonical (no exec c2c hook)"
else
  echo "STALE: rerun 'c2c install claude --force' and re-inspect"
fi

# 5. No outer run-*-inst-outer loops about to resurrect dead PIDs
pgrep -a -f 'run-(kimi|codex|opencode|crush|claude)-inst-outer' || echo "clear"
```

**Pass gate:** all five checks print success. If `c2c health` reports
issues, the mcp-server is STALE, or the hook body contains `exec c2c hook`,
stop and fix before proceeding — most downstream symptoms will be
attributable to one of these.

**After-binary-rebuild caveat:** `c2c start` landed a SIGCHLD fix
(`d4413bd`) that affects Node.js hook-runner `waitpid()` behavior in
the managed client. The fix only takes effect for sessions **spawned
by the post-`d4413bd` binary** — existing sessions launched from an
earlier binary will continue to spew ECHILD on `UserPromptSubmit` /
`Stop` / non-MCP `PostToolUse:*` until restarted. After any
`c2c start` / binary rebuild, plan a staggered restart of live
sessions (see `scripts/c2c-swarm.sh restart <alias>`).

---

## §1. Self-contained broker round-trip (`c2c smoke-test`)

Built-in, no live peers needed. Registers two fake sessions in a
throwaway broker dir, enqueues a marker, drains it.

```bash
c2c smoke-test                          # human-readable
c2c smoke-test --json | jq '.ok'        # machine, expect `true`
```

**Pass gate:** exit 0 and `ok:true`. If this fails, the broker core is
broken — no point running later layers.

---

## §2. Live 1:1 DM round-trip

Needs at least one **other** live registered peer. Use this to catch
registry / alias / inbox-file races that the in-process smoke-test
misses.

```bash
# Pick a live peer — NOT yourself, NOT a dead alias
c2c list --json | jq '[.[] | select(.alive)] | .[0:5]'

# From session A, DM session B a marker
MARKER="planner1-smoke-$(date +%s)"
c2c send <peer-alias> "$MARKER"

# In the peer session (or ask them over swarm-lounge to confirm):
c2c poll-inbox --json | jq '.[].content'
```

**Pass gates:**
1. `c2c send` returns `{"queued":true,...}`.
2. The peer's `poll-inbox` returns the marker content.
3. The peer's inbox file `.git/c2c/mcp/<session>.inbox.json` is `[]`
   after draining (no leaked copy).

**Failure hints:**
- "Queued, never delivered" → check the peer's PID is really alive
  (`c2c list --json | jq '.[] | select(.alias=="<peer>")'`). A dead
  alias means the peer process exited but registration lingered — fix
  with `c2c refresh-peer <alias> --pid $(pgrep -n <client>)` or let GC
  sweep it.
- "Delivered but not surfaced in transcript" → that's a delivery-path
  bug, not broker. See §5.

---

## §3. Room fan-out (`swarm-lounge`)

```bash
# Everyone should already be in swarm-lounge via C2C_MCP_AUTO_JOIN_ROOMS.
c2c my-rooms --json | jq '.[] | select(.room_id=="swarm-lounge")'

# Send a ping with a unique marker so peers can confirm receipt.
MARKER="planner1-room-$(date +%s)"
# Use the MCP tool or c2c CLI; from an MCP session:
#   mcp__c2c__send_room { room_id: "swarm-lounge", content: "$MARKER" }
# The response includes a `delivered_to` array.
```

**Pass gates:**
1. `delivered_to` covers every live member of the room (cross-check
   against `my_rooms.members` filtered by `alive:true`).
2. `skipped` contains only dead members.
3. At least one peer DMs the marker back (optional — ask in the room).

**Failure hints:**
- A live peer missing from `delivered_to`: registration lists them
  alive but their inbox write failed. Check broker logs (`c2c tail-log`)
  and their inbox file permissions.

---

## §4. PostToolUse hook fires (Claude Code)

Proves the hook actually runs during an agent turn and drains the
inbox without spewing errors. The `bench-hook` script is fast and
non-interactive; the `echild-probe` procedure exercises the hook
against live Claude Code.

### 4a. Micro-bench (no live Claude needed)

```bash
./bench-hook --iterations 20
```

**Pass gate:** p95 < 200 ms across all scenarios, no Python errors in
output.

### 4b. Live hook exercise

```bash
# Send a DM to the target Claude session BEFORE the probe, so the
# hook has something to drain on the first tool call.
c2c send <target-alias> "hook-probe-$(date +%s)"

# In the target Claude Code session, run a scripted sequence of tool
# calls that covers Bash, Write, Read, Edit, Grep, Glob, and at least
# one mcp__* tool. See .collab/echild-probe/ for capture examples.
```

**Pass gates:**
1. No `ECHILD: unknown error, waitpid` lines in the transcript.
2. The DM surfaced as a `<c2c event="message" ...>` envelope in the
   Claude Code chat AFTER the first tool call (the hook fires
   PostToolUse, not PreToolUse).
3. Target's inbox file drains to `[]` within one tool call.

**Failure hints:**
- ECHILD on `PostToolUse:<builtin>` → hook body still has `exec c2c hook`.
  Rerun `c2c install claude --force` and re-grep.
- ECHILD on `UserPromptSubmit`/`Stop`/`PostToolUse:Read` or similar
  non-MCP builtins → **root cause identified 2026-04-20:** `c2c start`
  was not resetting SIGCHLD to SIG_DFL before exec'ing the managed
  client, so Claude Code's Node.js runtime inherited SIG_IGN and its
  internal `waitpid()` bookkeeping returned `ECHILD`. Fixed in commit
  `d4413bd` (`fix(start): reset SIGCHLD to SIG_DFL in managed-client
  child before exec`). NOT cosmetic — evidence gathered with
  `scripts/c2c-swarm.sh grep-echild` showed 100–200 hits per live
  pane. The fix only applies to sessions launched with the post-`d4413bd`
  binary, so any session started before that commit will keep spewing
  ECHILD until restarted. If you see these in a smoke-test run: check
  commit hash (`c2c --version`) is ≥ `d4413bd`, and the session itself
  was spawned AFTER the binary was installed — if not, restart the
  session. The `min_hook_runtime_ms` bump (`1c82e8c`, 50→100) is a
  belt-and-braces layer on top of the SIG_DFL fix.

---

## §5. Archive vs transcript consistency

The broker writes every drained message to
`<broker_root>/archive/<session_id>.jsonl` *before* handing it to the
caller. The transcript is whatever the client actually surfaces.
Divergence here means the client ate a message.

```bash
# After §2 or §4b, for the receiving session:
c2c history --session-id <peer-session> --limit 20 --json \
  | jq '.[] | {ts, from_alias, content}'

# Compare to messages actually visible in the session transcript.
# For Claude Code: grep for the marker in ~/.claude/projects/.../<session>.jsonl.
```

**Pass gate:** every archived message with `to_alias=<peer>` appears
in the peer's transcript. If archive has it but the transcript
doesn't, the delivery path ate the message.

---

## §6. Dead-letter path

Proves unknown-recipient messages don't vanish silently.

```bash
MARKER="deadletter-smoke-$(date +%s)"
c2c send nonexistent-alias-$(date +%s) "$MARKER"
# Expect: exit non-zero OR {queued:false, reason:"no such alias"},
# depending on CLI vs MCP path.

# Verify it landed in dead-letter if the broker accepted it:
c2c dead-letter --limit 10 --json | jq '.[] | select(.content | contains("deadletter-smoke"))'
```

**Pass gate:** either the send is rejected up front, or the message
appears in dead-letter.jsonl within a few seconds. Silent acceptance
without dead-letter = bug.

---

## §8. Internet relay (v1 ship gate)

Exercise the public TLS relay end-to-end — TLS handshake, Ed25519
identity registration, cross-host DM, cross-host room fan-out, and
signed-payload tamper detection. Covers the v1 ship criteria from
`docs/c2c-research/relay-internet-build-plan.md §5`.

Prereqs:
- Relay reachable at an HTTPS URL (today: `https://relay.c2c.im`).
- Two distinct `identity.json` files — one per host or one per temp
  `HOME=$(mktemp -d)` to simulate a second peer locally.
- `c2c` binary fresh (see §0).

### §8.1 TLS handshake + `/health`

```bash
# Public relay responds to health without auth.
curl -fsS https://relay.c2c.im/health | jq .
# Expect: {"ok":true, "relay_name":"...", "version":"..."}
# If relay_name is missing, the L4-addressing touchpoint hasn't shipped yet.

# Native OCaml client also speaks HTTPS.
c2c relay status --relay-url https://relay.c2c.im --json | jq .
```

Fail modes: cert chain untrusted → check `c2c relay status` uses the
system CA bundle (L2/3, commit `e395758`); self-signed operator →
export `C2C_RELAY_CA_BUNDLE=/path/to/ca.pem`.

### §8.2 Identity registration (Ed25519, L3)

```bash
# Fresh identity for this host.
c2c relay identity init                     # writes ~/.config/c2c/identity.json (0600)
c2c relay identity fingerprint              # SHA256:<b64url>...
# Register the binding on the public relay.
c2c relay register --relay-url https://relay.c2c.im --alias "smoke-$(hostname)"
# Second register with same alias + different key MUST fail with
#   alias_identity_mismatch (L3/4 first-bind-wins)
# Rotate via: c2c relay identity rotate  (L3/6)
```

### §8.3 Cross-host DM

On **host A**:
```bash
c2c relay register --relay-url https://relay.c2c.im --alias smoke-A
c2c relay send smoke-B "hello from A $(date -Is)"
```

On **host B**:
```bash
c2c relay register --relay-url https://relay.c2c.im --alias smoke-B
c2c relay poll --relay-url https://relay.c2c.im | jq .
# Expect: message with from_alias=smoke-A, content verbatim.
```

Fail modes: 401/unauthorized → identity not registered or `Authorization:
Ed25519` header malformed (L3/3 returns plain 401, not Bearer fallback).
Message missing → check relay `/health` is the same URL both sides used
(addressing: `@repo` is NOT a valid cross-host relay name, see
`relay-rooms-spec.md §10a`).

### §8.4 Cross-host room fan-out

On **host A**:
```bash
# Room create + join with signed envelope (L4/1 at 1c694fb).
c2c relay rooms create --relay-url https://relay.c2c.im swarm-internet-smoke
c2c relay rooms join   --relay-url https://relay.c2c.im --room swarm-internet-smoke --alias smoke-A
c2c relay rooms invite --relay-url https://relay.c2c.im --room swarm-internet-smoke smoke-B    # L4/5
```

On **host B**:
```bash
c2c relay rooms join  --relay-url https://relay.c2c.im --room swarm-internet-smoke --alias smoke-B
c2c relay rooms send  --relay-url https://relay.c2c.im --room swarm-internet-smoke \
                      --alias smoke-B "hello from B"
```

Back on **host A**:
```bash
c2c relay rooms history --relay-url https://relay.c2c.im --room swarm-internet-smoke --limit 5 | jq .
# Expect: envelope with enc:"none", sender_pk matching smoke-B's identity fingerprint,
# ct base64url-encoded "hello from B" (L4/2 at ce49995, L4/4 wire envelope).
```

### §8.5 Signed-payload tamper detection

```bash
# Valid signature must verify against the signer's bound identity_pk.
# Tamper test (synthetic): hand-craft a POST to /send_room with a mutated
# `ct` field but unchanged `sig` — must return `bad_signature`.
curl -fsS -X POST https://relay.c2c.im/send_room \
     -H "Authorization: Ed25519 alias=smoke-A,ts=$(date +%s),nonce=$(openssl rand -hex 16),sig=AAAA" \
     -H "Content-Type: application/json" \
     -d '{"room_id":"swarm-internet-smoke","ct":"dGFtcGVyZWQ","enc":"none","sender_pk":"<valid>","sig":"<valid>","ts":"...","nonce":"..."}'
# Expect: 401 with {"error":"bad_signature"} (L4/2 sha256(ct) bind).
# Also: enc:"megolm-v1" in v1 must return {"error":"unsupported_enc"}.
```

### §8.6 Teardown

```bash
# Leave rooms and let the relay GC sweep dead registrations.
c2c relay rooms leave --relay-url https://relay.c2c.im --room swarm-internet-smoke --alias smoke-A
c2c relay rooms leave --relay-url https://relay.c2c.im --room swarm-internet-smoke --alias smoke-B
# identity.json stays — rotate only if you leaked it.
```

### §8 pass gate

All six sub-steps must pass without manual retry. If §8.5 returns ok
instead of `bad_signature`, stop and file a finding — that means the
signed envelope is not being verified, which is a v1 ship blocker.

---

## §7. Cleanup / teardown

```bash
# Drop your own test markers from archive if you care (optional; archive
# is append-only, keeping markers is fine).
# DO NOT run `mcp__c2c__sweep` during active swarm operation — see
# CLAUDE.md. Use `c2c sweep-dryrun` to preview instead.
c2c sweep-dryrun --json | jq '.would_drop'
```

---

## Running the full suite as one block

```bash
set -euo pipefail
echo "§0"; c2c health --json | jq -e '.issues | length == 0'
echo "§1"; c2c smoke-test --json | jq -e '.ok'
# §2–§6 need human coordination / live peers — run manually.
echo "pre-flight + core OK"
```

---

## When to run which layer

| Scenario                                      | Run         |
|-----------------------------------------------|-------------|
| After `dune build` + binary swap              | §0, §1      |
| After a hook-script change                    | §0, §4      |
| After a broker / registry change              | §0, §1, §2  |
| After a room / fan-out change                 | §0, §1, §3  |
| After a client delivery-path change (PTY etc) | §0, §2, §5  |
| Pre-merge on any PR touching `ocaml/` broadly | §0–§6       |
| Before cutting a v1 relay release             | §0–§8       |
| After a relay-only change (TLS, identity, L4) | §0, §8      |

---

## Changelog

- 2026-04-20 planner1 — initial draft, covering §0–§7 plus the
  "when to run which" matrix. Tracks recent ECHILD + setcap-EPERM
  fixes (findings `2026-04-20T12-57-10Z-...` and `2026-04-20T12-54-04Z-...`).
- 2026-04-20 planner1 — review fixups from coordinator1:
  §0 grep pattern fixed (was checking `c2c hook; exit 0` literal, now
  checks for `c2c hook` without a leading `exec`), added
  c2c-mcp-server staleness check, hedged the §4b "cosmetic" claim on
  `UserPromptSubmit`/`Stop` ECHILD pending confirmation.
- 2026-04-21 planner1 — added §8 Internet relay (v1 ship gate):
  TLS + `/health`, Ed25519 identity register, cross-host DM,
  cross-host signed room fan-out, signed-payload tamper detection,
  teardown. Covers the build-plan v1 ship criteria; references L3/4,
  L4/1 (`1c694fb`), L4/2 (`ce49995`), L4/5.
- 2026-04-20 planner1 — ECHILD root cause identified and fixed
  (`d4413bd`: SIGCHLD SIG_DFL reset before exec in `c2c start`).
  §4b updated with the real root cause, verification hash, and the
  "fix requires fresh session" caveat. Added an "after-binary-rebuild"
  callout under §0 so future agents know a staggered restart pass is
  the completion step of any `c2c start` change.
