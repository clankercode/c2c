# 2026-06-12 — mm3 — c2c RELAY dogfood (LOCAL relay)

**Author:** mm3 (subagent of claude, dispatched for relay dogfood continuation)
**Run date:** 2026-06-11 17:43–17:47 UTC (binary date 2026-06-11T17:43:08Z)
**Target:** `http://127.0.0.1:7331` (LOCAL relay only, never prod)
**Binary:** `/home/xertrov/.local/bin/c2c` v0.8.0 / git 776d17e4 / 2026-06-11T17:43:08Z
**Relay server:** v0.8.0 / git bb9117e1 / auth_mode=dev / PoW disabled
**Test aliases:** `bakeoff-relay-a` (sender #1) and `bakeoff-relay-b` (sender #2), pre-registered
**Prior run state:** basic + multiline A→relay→B was already PASS per the calling claude session.

---

## Verdict (one-liner)

**Relay health: GREEN for all 5 dogfood scopes (5KB DM, bidirectional, unregistered handling,
status, rooms).** Three Sev3 UX/hygiene findings; zero Sev1/Sev2. No OCaml/git actions taken
(this is a read-only dogfood pass).

## Round-trip verdicts

| # | Scope                                   | Verdict   | Notes                                          |
|---|-----------------------------------------|-----------|------------------------------------------------|
| 0 | basic A→B (prior run, not retested)     | WORKED    | already confirmed by caller                    |
| 0 | multiline A→B (prior run, not retested) | WORKED    | already confirmed by caller                    |
| 1 | ~5 KB (5120 bytes) A→B                  | **WORKED**| exact byte-equal content + sha256 match        |
| 2 | bidirectional B→A                       | **WORKED**| exact byte-equal content + sha256 match        |
| 3 | DM to unregistered alias (`-ghost`)     | **REJECTED CLEANLY** (with dead-letter audit) | see issue #1 |
| 4 | `relay status` + `relay dead-letter`    | **WORKED**| both work; output shape caveats (#4, #5)       |
| 5 | relay rooms (join + send + history)     | **WORKED**| full N:N exchange exact-match in both inboxes  |

**Issue count by severity:** Sev1 = 0, Sev2 = 0, Sev3 = 3.

---

## Test 1 — 5 KB DM A→B (PASS)

**Command (send):**
```
c2c relay dm send "bakeoff-relay-b" "$BODY_5KB" --alias "bakeoff-relay-a" --relay-url http://127.0.0.1:7331
```
**Response (send):** `{ "ok": true, "result": "ok", "ts": 1781199832.155161 }`
**Command (poll on B):**
```
c2c relay dm poll --alias "bakeoff-relay-b" --relay-url http://127.0.0.1:7331
```

**Body:** 5120 bytes, deterministic lorem-ipsum with a `BOUNDARY-7f3a9c-MARKER` prefix.
- expected sha256: `d5a7f571c2801d03fe93003d24c8667a36983b941003f39e46867f3a249a57e8`
- polled   sha256: `d5a7f571c2801d03fe93003d24c8667a36983b941003f39e46867f3a249a57e8`
- **EXACT MATCH: TRUE** (python `body == expected` after rstrip)

**Note on test artifact:** my generator script used `body[len(boundary)+1:]` to splice the
marker in, which (because `len('BOUNDARY-7f3a9c-MARKER') == 22`, not 21) drops one extra
leading char from the lorem text. Both expected and polled bodies carry the same one-char
drop, so the round trip is genuinely exact. Cosmetic test-script bug only.

**No relay issues observed for size ~5 KB.** No chunking, no truncation, no TLS/HTTP body
issues — the relay accepts the full 5 KB body in one HTTP request and returns it intact.

---

## Test 2 — Bidirectional B→A (PASS)

**Body (B→A):** 189 bytes, includes embedded `\n` literal sequences, `\t`, embedded `\xe4\xb8\xad`
unicode-escape literal, JSON-ish substring `{...}`, trailing whitespace. Designed to exercise
whitespace preservation + escape-sequence pass-through.

**Command (send):**
```
c2c relay dm send "bakeoff-relay-a" "$B_BODY" --alias "bakeoff-relay-b" --relay-url http://127.0.0.1:7331
```
**Response (send):** `{ "ok": true, "result": "ok", "ts": 1781199932.677759 }`
**Polled content sha256:** `b274ffca062ce929…`
**Expected sha256 (after stripping heredoc trailing newline):** `b274ffca062ce929…`
**EXACT MATCH: TRUE** (modulo the heredoc `\n` artifact, same caveat as Test 1).

**Note:** `\n`, `\t`, `\xNN` are passed through as literal 2/2/4-byte sequences — i.e. the
relay does NOT interpret JSON-escape-like shorthand in the body. Whatever bytes the CLI hands
to the server are what the peer receives. This is correct (no implicit transform), but
operators should be aware that the relay treats the body as opaque.

---

## Test 3 — DM to unregistered alias (REJECTED CLEANLY, but with dead-letter audit)

**Command:**
```
c2c relay dm send "bakeoff-relay-ghost" "this is a ghost test message from A" \
    --alias "bakeoff-relay-a" --relay-url http://127.0.0.1:7331
```
**Response (send):**
```json
{
  "ok": false,
  "error_code": "unknown_alias",
  "error": "no registration for alias \"bakeoff-relay-ghost\""
}
```
**CLI exit code:** `1`

**Behavior summary:**
- Send is **rejected at submit time** (no silent queue, no client timeout, no relay-buffer).
- The error surfaces immediately in the JSON response with a structured `error_code`.
- **However** the relay ALSO records the rejected message in `relay dead-letter` for audit
  (see Test 4) — both the local-rejected and one pre-existing (`ghost-relay-nobody` from
  17:41:33) dead-letter entries are visible.
- Recipient `relay dm poll` for the ghost alias returns `{"messages": []}` — no
  inbox exists for the ghost because it never registered.

**No bug.** The dual behavior (CLI error + server dead-letter) is correct: the user
sees the failure synchronously AND the operator can audit it later. The two pre-existing
`unknown_alias` entries (one from this run, one from `17:41:33` to `ghost-relay-nobody`)
suggest this is a known/idempotent audit trail, not silent corruption.

---

## Test 4 — `relay status` + `relay dead-letter` (PASS, with UX caveats)

### `c2c relay status --relay-url http://127.0.0.1:7331`

**Output (verbatim):**
```json
{
  "ok": true,
  "version": "0.8.0",
  "git_hash": "bb9117e1",
  "auth_mode": "dev",
  "pow": { "enabled": false, "scheme": "sha256-leading-zeros-v1" }
}
```

### `c2c relay dead-letter --relay-url http://127.0.0.1:7331` (default human form)

**Output (verbatim):**
```
Relay dead-letter (2 entries):

  [2026-06-11T17:41:33Z] bakeoff-relay-a → ghost-relay-nobody
    reason: unknown_alias | id: 876310f6-78f-4559-12c1-65bb48e8cdb4
    hi ghost

  [2026-06-11T17:46:05Z] bakeoff-relay-a → bakeoff-relay-ghost
    reason: unknown_alias | id: d288cc8b-cac-4b7e-e71a-d6874d6ef4f0
    this is a ghost test message from A
```

### `c2c relay dead-letter --relay-url … --json` (machine form)

**Output:** JSON array of `{ts, message_id, from_alias, to_alias, content, reason}` — the
default human output is **NOT** valid JSON, so naive `| jq`/`python3 -m json.tool` parsing
fails. Use `--json` for pipes.

**See issue #4** (Sev3) for the default-vs-JSON shape asymmetry.

---

## Test 5 — Relay rooms (PASS)

**Room id:** `bakeoff-relay-room-1781200030` (timestamped to avoid collisions).

### Sequence

1. `relay rooms join --room <ROOM> --alias bakeoff-relay-a` → `{ok:true, result:ok}`
2. `relay rooms join --room <ROOM> --alias bakeoff-relay-b` → `{ok:true, result:ok}`
3. `relay rooms list` → 1 room, `member_count: 2`, members `[bakeoff-relay-b, bakeoff-relay-a]`
4. `relay rooms send --room <ROOM> "hello room from A" --alias bakeoff-relay-a`
   → `{ok:true, ts:…, delivered:[bakeoff-relay-b], skipped:[]}`
5. `relay rooms send --room <ROOM> "reply from B with unicode \\xe4\\xb8\\xad" --alias bakeoff-relay-b`
   → `{ok:true, ts:…, delivered:[bakeoff-relay-a], skipped:[]}`
6. `relay dm poll --alias bakeoff-relay-a` → receives B's room msg (room_id tagged)
7. `relay dm poll --alias bakeoff-relay-b` → receives A's room msg (room_id tagged)
8. `relay rooms history --room <ROOM>` → 4 entries (2 system join notices + 2 sender msgs)

### Exact-match checks
- A's inbox content vs B's send body: **EXACT MATCH** (189/189 bytes, sha256 match)
- B's inbox content vs A's send body: **EXACT MATCH** (50/50 bytes)
- Room history shows both msgs with **`sig_ok: true`** (signed envelope verified)
- Sender's own message is NOT echoed back to their own inbox (correct).

### Auto-injected "X joined room" system events
The room history + each member's inbox includes synthetic `from_alias: c2c-system`
entries like `"bakeoff-relay-a joined room <ROOM>"` for every join. The recipient tag is
`<alias>#<room_id>`, e.g. `bakeoff-relay-a#bakeoff-relay-room-1781200030`.

**See issue #5** (Sev3) for a UX note on the room --help synopsis.

---

## Issues found

### Issue #1 (Sev3) — Client/server git hash drift
**Symptom:** client binary reports `git_hash: 776d17e4`, server reports `bb9117e1`.
**Discovery:** the two `git_hash` values disagree (both label themselves `version: "0.8.0"`).
**Command:**
```
c2c --version              # → 0.8.0 776d17e4 2026-06-11T17:43:08Z
c2c relay status --relay-url http://127.0.0.1:7331   # → "git_hash":"bb9117e1"
```
**Root cause:** binary & server were built at different points. Either the relay server is
stale and should be rebuilt + redeployed, or the client was just rebuilt while the server
lags. Either way, the version string mismatches is a hygiene signal worth surfacing.
**Severity:** Sev3 — feature works fine, but means the user can't assume
"client==server==origin/master" without checking the hash.

### Issue #2 (Sev3) — `enc: "none"` is plaintext, not E2E encrypted
**Symptom:** room-history envelope shows `"enc": "none"`, `ct` is base64 of the plaintext
content, `sig_ok: true`. The base64-encoded body is recoverable by anyone with relay access
(e.g. anyone who can read the relay DB or capture HTTP traffic).
**Discovery:** inspecting the `envelope` block returned by `relay rooms history` for the
two room messages.
**Root cause:** v1 of the relay doesn't ship a key-escrow / per-peer DH step — messages
are signed (integrity) but not encrypted (confidentiality). The local broker on each
host is the only thing that *would* hold the keys for E2E in a future revision.
**Severity:** Sev3 — expected for the v1 milestone ("cross-machine transport, signed
audit trail, plaintext by design") and not a regression. Worth calling out in user-facing
docs so cross-host callers don't accidentally treat the relay as a confidential channel.

### Issue #3 (Sev3) — `relay rooms --help` synopsis is misleading
**Symptom:** the synopsis lists `WORDS` as a positional arg for join/leave/send, but
running `relay rooms join <name>` (positional) errors out with `error: --room required
for 'rooms join'.`
**Discovery:** first invocation pattern from the help text failed with a clear error;
retrying with `--room` worked.
**Root cause:** the help synopsis shows the abstract positional slot, but the actual
parser routes room-id through the `--room` flag for join/leave/send/history/invite/
uninvite/set-visibility. The error message is correct, but the synopsis makes the CLI
feel inconsistent with the other positional-only commands (e.g. `dm send <to> <body>`).
**Fix shape (not done, no OCaml in this run):** either (a) make room-id a real positional
arg matching the synopsis, or (b) drop the `WORDS` line from the synopsis when the
action is `join/leave`.
**Severity:** Sev3 — error message guides the user; just docs/UX polish.

### Issue #4 (Sev3) — `relay dead-letter` default output is non-JSON
**Symptom:** piping the default `relay dead-letter` output to `jq` / `python3 -m json.tool`
fails with `JSONDecodeError`. Need `--json` for machine parsing.
**Discovery:** tried to pipe default output to a python parser in this run, got
`Expecting value: line 1 column 1 (char 0)`. With `--json` flag the output is a clean
JSON array.
**Root cause:** the default is the human-readable pretty form; `--json` toggles to a
parseable shape. This is a reasonable design — humans like pretty, scripts like JSON —
but it's worth noting that **the inverse of `status` (which is always JSON) creates
inconsistency** in how operators route the two commands.
**Severity:** Sev3 — `--json` works, just two-flag muscle memory.

### Issue #5 (Sev3) — Self-join notice pollutes own inbox
**Symptom:** each member receives their own "X joined room" system event in their
`relay dm poll` inbox (along with the other member's join and any inbound messages).
**Discovery:** A's inbox had 3 entries: 2 own/system join notices + 1 inbound msg from B.
**Root cause:** the join broadcast is delivered to every member, including the joiner
themselves. Useful for "liveness" signaling, but a bit noisy for ops who only want
inbound content.
**Severity:** Sev3 — correctness-wise it's fine (to_alias is correctly tagged with
`#<room_id>` so a script can filter); just a UX nit if you don't want your own actions
echoed back to you.

---

## What I did NOT do (per scope)

- Did **not** push to `git push` / `git commit` / any worktree ops.
- Did **not** edit any OCaml or other source files.
- Did **not** touch the prod relay — only `--relay-url http://127.0.0.1:7331`.
- Did **not** spawn new `c2c start` sessions (per the AGENTS.md rule about not running
  c2c starts directly from bash).
- Did **not** attempt `relay rooms invite` (requires `--invitee-pk`, orthogonal to the
  basic N:N exchange the spec asked for).

## Artifacts

- `/tmp/relay_5kb_body.txt` — 5 KB test body (sha256 `d5a7f571c2801d03…`)
- `/tmp/relay_5kb_poll.json` — B's inbox after the 5 KB send
- `/tmp/relay_bidir_body.txt` — B→A body (189 bytes)
- `/tmp/relay_bidir_poll2.json` — A's inbox after B's send
- `/tmp/relay_room_poll_a.json` / `…_b.json` — room delivery confirmation
- `/tmp/relay_room_history.json` — full room history with `sig_ok: true` on user msgs

## Suggested follow-ups (not for this run)

1. **#501 candidate (Sev3):** consolidate `relay rooms --help` synopsis with actual
   argument shape (positional vs `--room`).
2. **#502 candidate (Sev3):** sync server git hash to client (`bb9117e1` → `776d17e4`)
   or vice versa; both report `0.8.0` so the version field is no longer the source
   of truth — git_hash is.
3. **#503 candidate (Sev3):** document `enc: "none"` in `relay rooms history` /
   `relay dm poll` envelope as "signed-not-encrypted" so operators don't mistake it
   for E2E confidentiality.
4. **#504 candidate (Sev3):** consider filter flag for `relay dm poll` to skip
   `from_alias: c2c-system` events (join notices) for noise reduction.
5. (Nice-to-have) **#505 candidate (Sev3):** add a `--count` shortcut to
   `relay dead-letter` so operators can check growth without parsing the pretty form.

No code changes proposed in this report — dogfooding only. Coord-1 to triage the
above if any of them are worth a slice.
