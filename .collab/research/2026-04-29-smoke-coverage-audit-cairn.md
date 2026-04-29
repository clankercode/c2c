# Smoke-Test Coverage Audit — `scripts/relay-smoke-test.sh`

**Author**: cairn (subagent of coordinator1)
**Date**: 2026-04-29
**Scope**: `scripts/relay-smoke-test.sh` (149 lines) vs current relay
public surface in `ocaml/relay.ml`
**Output target**: 3-5 add-to-script test proposals, sized for the
existing single-file bash script.

---

## 1. What the smoke test currently covers (11 PASS-tracked checks)

The script registers `smoke-$(date +%s)` against `$RELAY` (default
`https://relay.c2c.im`), then walks 7 sections that emit `green`/`red`
counters. The 11 passing checks are:

| # | Section | Check | Endpoint exercised |
|---|---------|-------|-------------------|
| 1 | Health | `auth_mode == "prod"` | `GET /health` |
| 2 | Register | register `ok` (post-`adb152f` bootstrap) | `POST /register` |
| 3 | List | `list ok` w/ `C2C_MCP_AUTO_REGISTER_ALIAS` signing | `GET /list` |
| 4 | Loopback DM | self-DM `ok` | `POST /send` |
| 5 | Poll inbox | self-DM materialises in inbox | `POST /poll_inbox` |
| 6 | Room join | join smoke-room | `POST /join_room` |
| 7 | Room list | unauthenticated list | `GET /list_rooms` |
| 8 | Room send | room send | `POST /send_room` |
| 9 | Room leave | leave (best-effort, soft-fail logged as info, NOT counted) | `POST /leave_room` |
| 10 | Room history | unauthenticated history | `POST /room_history` |
| 11 | Identity file | `~/.config/c2c/identity.json` exists | local FS |

Note: room-leave is marked "non-fatal" in code (line 117-121) — failure
emits `info` not `red`, so the suite reports 10 hard PASS + 1 best-effort
when the relay lacks `/leave_room`. `git_hash` is logged but not asserted.

---

## 2. Relay public surface — what's NOT covered

Cross-referencing the route table in `ocaml/relay.ml:4283-4443`:

### HTTP routes deployed but unsmoked

| Route | Auth | Surface | Smoke today? |
|-------|------|---------|-------------|
| `POST /heartbeat` | bearer | session liveness | NO |
| `POST /send_all` | identity-bound | broadcast (1:N) | NO |
| `POST /peek_inbox` | identity-bound | non-destructive peek | NO |
| `POST /set_room_visibility` | identity-bound | room governance | NO |
| `POST /invite_room` | identity-bound | room invites | NO |
| `POST /uninvite_room` | identity-bound | room invites | NO |
| `POST /send_room_invite` | identity-bound | DM-an-invite | NO |
| `GET /dead_letter` | bearer (admin/operator) | failed-delivery visibility | NO |
| `GET /pubkey/<alias>` | unauth | public-key lookup | NO |
| `GET /remote_inbox/<alias>` | bearer (admin) | cross-host fetch | NO |
| `POST /admin/unbind` | bearer (admin) | identity unbind | NO (admin-only — fine to skip) |
| `POST /gc` | bearer (operator) | manual GC | NO (gated to operator) |
| `GET/POST /device-pair/*` | bearer | mobile pairing | NO |
| `POST /mobile-pair[/prepare]` | identity-bound | mobile QR flow | NO |
| `DELETE /binding/<id>` | identity-bound | revoke binding | NO |
| `GET /observer/<…>` (websocket) | upgrade + bearer | observer push channel | NO |

### MCP-side surfaces with relay implications (less direct fits)

`pin_rotate` is not a relay HTTP route (it's `Peer_review.pin_rotate`
locally + audit log via `c2c_mcp.log_peer_pass_pin_rotate`), so it
doesn't belong in a *relay* smoke. But the underlying public-key the
relay caches for `/list` and Ed25519-bound routes IS replaced by a pin
rotate; a peer's first authed call after rotation hits the `/register`
re-bind path. That round-trip ("rotate locally → re-register → first
authed call still works") is the relay-visible peer-pass surface and IS
in scope for smoke.

### Cross-host (post-S1)

`relay.ml:3196-3215` shows the `alias@host` parser is wired for `/send`
with a deliberate "cross_host_not_implemented" rejection that lands a
dead-letter entry (per recent fix `4450cf56` / `492c052b`). This is a
*regression-protector* test slot that didn't exist before: send to
`smoke-target@some-other-host`, expect non-OK + dead-letter row.

---

## 3. High-value gaps — where bugs would hide today

Ranked by "if this regressed during a Railway deploy, would the swarm
notice?":

1. **`/heartbeat`** (line 4318). Critical for session liveness on the
   relay side; currently invisible to the smoke suite. A regression
   here would silently break nudge cadence and `/list` freshness
   without firing any PASS/FAIL.

2. **`/dead_letter` visibility**. Recent fix in `492c052b` makes
   cross-host rejection write a `dead_letter` entry instead of
   silent-drop. Smoke does NOT verify the row is visible. If the GET
   handler regresses, "fixed silent-drop" is undetectable in prod.

3. **`/peek_inbox` (non-destructive)**. Smoke uses `/poll_inbox`
   (destructive). If `peek_inbox` were broken, the doctor surfaces and
   debug paths that depend on it would silently lie.

4. **`/send_all` (1:N broadcast)**. Group goal calls broadcast
   first-class; never exercised by smoke. A bad commit to fan-out
   could ship to prod undetected.

5. **`/set_room_visibility` + `/invite_room`** (private rooms). Private
   rooms are growing in usage (slice rooms, role rooms); none of the
   visibility/invite plumbing is smoked. Public-only smoke gives a
   false-clear.

6. **Cross-host rejection-and-dead-letter round-trip** (post-S1).
   Highest-leverage *new* test — exercises both the parser fix and the
   dead-letter row in one call. Prevents the silent-drop regression
   from sneaking back in.

7. **`/pubkey/<alias>` lookup**. Cheap (unauth), validates the
   identity-binding side of `/register` actually persisted the public
   key. Catches a class of "register said ok but didn't store" bugs.

8. **Pin-rotate → re-register → next authed call**. Validates the
   peer-pass identity-rotation surface as the relay sees it. Slightly
   more expensive (two register calls + an artifact); skip unless we
   want a dedicated `pin-rotate` smoke section.

9. **Observer websocket** (`/observer/...`). High value for the GUI
   roadmap but materially harder to smoke from bash (curl can do the
   upgrade; reading frames is awkward). Park for v2.

---

## 4. Proposed additions — sized for `relay-smoke-test.sh`

Each proposal is a drop-in section that follows the existing
`green/red`/`python3 -m json.tool` pattern. Numbered to slot after
section 7 (identity check, line 132+).

### Proposal A — `/heartbeat` liveness

```bash
echo "--- 8. Heartbeat ---"
hb_out=$(C2C_MCP_AUTO_REGISTER_ALIAS="$ALIAS" \
  curl -sf -X POST "$RELAY/heartbeat" \
    -H "content-type: application/json" \
    -d "{\"alias\":\"$ALIAS\"}" 2>&1) || true
if echo "$hb_out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
  green "heartbeat ok"
else
  red "heartbeat failed (relay liveness route regressed?)"
fi
```

Note: real heartbeat needs an Ed25519 auth header on identity-bound
routes. If the bearer-style direct curl is wrong for prod, swap for a
shell-out to whatever `c2c relay status` does internally, OR add a
`c2c relay heartbeat` CLI surface and use it. (Lightweight follow-up.)

### Proposal B — `/peek_inbox` non-destructive

```bash
echo "--- 9. Peek inbox (non-destructive) ---"
# Send a self-DM, peek twice, expect both peeks to return it.
c2c relay dm send "$ALIAS" "smoke peek probe" --alias "$ALIAS" --relay-url "$RELAY" >/dev/null
peek1=$(C2C_MCP_AUTO_REGISTER_ALIAS="$ALIAS" c2c relay dm peek --alias "$ALIAS" --relay-url "$RELAY" 2>&1) || true
peek2=$(C2C_MCP_AUTO_REGISTER_ALIAS="$ALIAS" c2c relay dm peek --alias "$ALIAS" --relay-url "$RELAY" 2>&1) || true
n1=$(echo "$peek1" | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('messages',[])))" 2>/dev/null)
n2=$(echo "$peek2" | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('messages',[])))" 2>/dev/null)
if [ "$n1" -ge 1 ] && [ "$n2" -ge 1 ] && [ "$n1" = "$n2" ]; then
  green "peek_inbox is non-destructive (n1=$n1 == n2=$n2)"
else
  red "peek_inbox destructive or empty (n1=$n1 n2=$n2)"
fi
```

Requires a `c2c relay dm peek` subcommand; if missing, raw `curl` to
`POST /peek_inbox` with the right auth header (parallel to the
existing poll path, see `relay.ml:4342`). Either way the test logic is
the same.

### Proposal C — Cross-host rejection + dead-letter row (post-S1)

```bash
echo "--- 10. Cross-host rejection + dead-letter ---"
ch_out=$(c2c relay dm send "$ALIAS@nonexistent-host" "cross-host probe" \
           --alias "$ALIAS" --relay-url "$RELAY" 2>&1) || true
if echo "$ch_out" | python3 -c "import json,sys;d=json.load(sys.stdin);exit(0 if d.get('error')=='cross_host_not_implemented' else 1)" 2>/dev/null; then
  green "cross-host send rejected with cross_host_not_implemented"
else
  red "cross-host send did not reject as expected (silent-drop regression?)"
fi

dl_out=$(curl -sf "$RELAY/dead_letter" 2>&1) || true
if echo "$dl_out" | python3 -c "import json,sys;d=json.load(sys.stdin);entries=d.get('entries',d) if isinstance(d,dict) else d;hits=[e for e in entries if e.get('reason')=='cross_host_not_implemented' and \"$ALIAS\" in str(e)];exit(0 if hits else 1)" 2>/dev/null; then
  green "dead_letter row visible for cross-host rejection"
else
  red "dead_letter row missing — fix 492c052b regressed?"
fi
```

Caveat: `/dead_letter` is admin-bearer in `relay.ml:2564-2567`. If
admin-bearer isn't available in the smoke env, second sub-check should
be guarded by a `[ -n "$C2C_RELAY_ADMIN_TOKEN" ]` check and degrade to
`info`. The first sub-check (rejection shape) stands alone and is the
real regression-catcher.

### Proposal D — `/send_all` broadcast

```bash
echo "--- 11. send_all (1:N broadcast) ---"
# Self-broadcast: with one registered alias, send_all should still ack
# and the loopback message should land in our own inbox.
sa_out=$(C2C_MCP_AUTO_REGISTER_ALIAS="$ALIAS" c2c relay send-all "smoke broadcast" \
           --alias "$ALIAS" --relay-url "$RELAY" 2>&1) || true
if echo "$sa_out" | python3 -c "import json,sys;d=json.load(sys.stdin);exit(0 if d.get('ok') else 1)" 2>/dev/null; then
  green "send_all ok"
  poll=$(C2C_MCP_AUTO_REGISTER_ALIAS="$ALIAS" c2c relay dm poll --alias "$ALIAS" --relay-url "$RELAY" 2>&1)
  if echo "$poll" | grep -q "smoke broadcast"; then
    green "send_all delivered to self-loopback"
  else
    red "send_all ack but not delivered"
  fi
else
  red "send_all failed"
fi
```

Confirm the CLI subcommand spelling; if `c2c relay send-all` does not
exist, fall back to direct curl to `/send_all` with proper signing.

### Proposal E — `/pubkey/<alias>` lookup

```bash
echo "--- 12. Pubkey lookup ---"
pk_out=$(curl -sf "$RELAY/pubkey/$ALIAS" 2>&1) || true
if echo "$pk_out" | python3 -c "import json,sys;d=json.load(sys.stdin);exit(0 if d.get('pubkey') or d.get('identity_pk') else 1)" 2>/dev/null; then
  green "pubkey lookup returned identity binding"
else
  red "pubkey lookup empty — register did not persist binding?"
fi
```

Cheap, unauth, exercises the post-register persistence path. Highest
ROI of the five.

---

## 5. Recommendation

Land Proposals **A, C, E** first — they're cheap, unauth-or-self-auth,
and each catches a specific known-bug class (heartbeat regression,
silent cross-host drop, register-without-binding). Proposal D
(`send_all`) is the next-most valuable; gate it on confirming the CLI
spelling. Proposal B (`peek_inbox`) is correctness-class — keep but it's
the lowest-priority of the five since `poll_inbox` already smoke-tests
the inbox-write path.

Skip for now:

- Observer websocket (defer to a dedicated probe — bash is wrong tool)
- `/admin/unbind`, `/gc`, `/remote_inbox/*` (admin-bearer; not appropriate
  for an unprivileged smoke)
- Pin-rotate round-trip (large; lives in its own e2e harness — see
  `ocaml/test/test_relay_e2e_integration.ml`)

Result targets: bring the smoke suite from 10 hard PASS + 1 best-effort
to **15 hard PASS + 1 best-effort + 1 admin-conditional**, covering
heartbeat / cross-host rejection / dead-letter visibility / send_all /
pubkey lookup, all in <100 added lines.

---

## 6. References

- Smoke script: `scripts/relay-smoke-test.sh:1-149`
- Relay route table: `ocaml/relay.ml:4283-4443`
- Auth classification: `ocaml/relay.ml:2562-2587`
- Cross-host rejection (post-S1): `ocaml/relay.ml:3196-3215`
- Dead-letter handler: `ocaml/relay.ml:4290`
- `c2c relay` CLI group: `ocaml/cli/c2c.ml:4751-4759`
- Recent dead-letter fix commits: `492c052b`, `4450cf56`
- Prior coverage discussion:
  `.collab/findings/2026-04-20T15-54-00Z-planner1-runbook-section-8-cli-drift.md`
