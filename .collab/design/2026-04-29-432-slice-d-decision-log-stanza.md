# #432 Slice D — pending-permissions decision log (stanza, 2026-04-29)

Closes Finding 5 of `.collab/research/2026-04-29-stanza-coder-pending-permissions-audit.md`. Today `broker.log` records `{ts, tool, ok}` per RPC (c2c_mcp.ml 6222-6243), so we know **that** `open_pending_reply` / `check_pending_reply` fired but not `perm_id`, `kind`, supervisors, requester, or outcome. Forensics ("who approved what for whom") is impossible.

## 1. File location

**Recommendation: append to `broker.log` with `event` discriminator.**

- broker.log already carries structured JSONL for adjacent security events: `peer_pass_reject` (3466) and `peer_pass_pin_rotate` (3499). Pending decisions fit the same forensic-trail mould.
- One file = one rotation policy (#61), one tail target (`mcp__c2c__tail_log`), one place an operator looks during incidents.
- Discriminators `pending_open` / `pending_check` are unambiguous; consumers grep by `event`.
- A separate `pending_permissions.log` would split the audit story across files for no win — pending-perm volume is low (TTL 600s, plugin-driven), it won't drown out RPC lines.

Rejected: `pending_permissions.log`. Cleaner separation in theory, but doubles the rotation surface and operators would still cross-reference broker.log for the surrounding RPC context.

## 2. Entry shape

JSONL line per `open_pending_reply` (after `Broker.open_pending_permission` returns) and per `check_pending_reply` (after the validity decision):

```json
{"ts": 1714000000.123, "event": "pending_open",
 "perm_id_hash": "<hex16>", "kind": "permission",
 "requester_session_hash": "<hex16>", "requester_alias": "stanza-coder",
 "supervisors": ["coordinator1", "lyra-quill"],
 "ttl_seconds": 600.0}

{"ts": 1714000050.456, "event": "pending_check",
 "perm_id_hash": "<hex16>", "kind": "permission",
 "requester_session_hash": "<hex16>", "requester_alias": "stanza-coder",
 "supervisors": ["coordinator1", "lyra-quill"],
 "reply_from_alias": "coordinator1",
 "outcome": "valid"}
```

`outcome` ∈ `valid` | `invalid_non_supervisor` | `unknown_perm` | `expired`. (Slice B will have `check_pending_reply` derive `reply_from_alias` from the calling session — the audit field then reflects the trustworthy value.)

## 3. Privacy

Threat model: broker.log lives at `<broker_root>/broker.log`, mode `0o600`, under `~/.c2c/repos/<fp>/broker/` (gitignored, **not** committed). Local-only; readers are anything with the operator's UID. Not adversary-facing, but any agent process inherits the UID, and broker.log is the kind of artifact that gets pasted into bug reports, screenshotted, or surfaced via `mcp__c2c__tail_log`.

- **`perm_id` → hash.** Plaintext perm_id is a live capability bearer (anyone who knows it can call `check_pending_reply` and learn the requester's session_id; Finding 4 hole). Logging it raw turns the audit trail into an oracle. Hash with `Digest.string |> to_hex` truncated to 16 chars — collision-free at this volume, still pivotable across two log lines for the same request. Plaintext argument: forensic clarity. Counter: hashing preserves correlation (same perm_id → same hash) which is all forensics needs.
- **`requester_session_id` → hash.** Same shape: 16-hex. Lets you correlate `pending_open` ↔ `pending_check` ↔ surrounding RPC lines (which carry the raw session_id today, but those are scoped to the RPC writer and can be evolved separately). Raw session_ids leak more than intended if the log is shared.
- **`requester_alias`, `supervisors`, `reply_from_alias` → plaintext.** Aliases are public swarm identity (`mcp__c2c__list` exposes them); hashing would defeat the audit.
- **`kind`, `outcome`, `ttl_seconds` → plaintext.** Bookkeeping, not sensitive.

## 4. Write path

Mirror `log_peer_pass_pin_rotate` (3499-3523) exactly: synchronous, best-effort, swallow-all-errors. Two `try/with _ -> ()` layers (open + write). Append-only `Open_append; Open_creat; Open_wronly` mode `0o600`.

- **Synchronous, not async.** Volume is low; spinning up Lwt machinery for one append is more risk than the latency it saves. The write happens on the caller's Lwt fiber but the file op itself is Unix-blocking — same as the pin-rotate logger, accepted.
- **If the log can't be written**, the handler still returns success. Audit failures must not break a working pending-reply. Same posture as the existing peer-pass loggers.
- **Two new functions** in c2c_mcp.ml next to `log_peer_pass_pin_rotate`: `log_pending_open ~broker_root ~pending` and `log_pending_check ~broker_root ~perm_id ~kind ~requester_alias ~requester_session_id ~supervisors ~reply_from_alias ~outcome`. Hashing helper `short_hash : string -> string` shared between them.

## 5. Rotation

**Piggyback on broker.log rotation (#61).** That's the whole point of choosing the shared file in §1 — one rotation, one cap, one truncation policy. No new config knobs.

## 6. Implementation sketch + test approach

**Sketch** (in c2c_mcp.ml, no new module):
1. Add `short_hash s = Digest.string s |> Digest.to_hex |> fun h -> String.sub h 0 16`.
2. Add `log_pending_open` / `log_pending_check` next to existing `log_peer_pass_*` (~line 3525).
3. Call `log_pending_open` after `Broker.open_pending_permission broker pending` at 5830.
4. Call `log_pending_check` in the `check_pending_reply` handler (5806-5840) after computing the outcome, on **all four** outcome branches.
5. `broker_root` is already in scope at handler call sites (used for other JSONL writers).

**Tests** (test_c2c_mcp.ml, alongside existing pending cases 6826-7106):
- Unit: call `open_pending_reply` then read broker.log, parse last line, assert `event=pending_open`, hash fields are 16-hex, plaintext aliases match, no raw `perm_id` / `session_id` substrings present.
- Unit: four `check_pending_reply` cases (valid / invalid_non_supervisor / unknown_perm / expired) each emit a `pending_check` line with matching `outcome`.
- Correlation: assert `perm_id_hash` from `pending_open` equals `perm_id_hash` from a same-perm `pending_check`.
- Robustness: simulate read-only `broker.log` (chmod 0o400) → handler still returns success; missing log line is acceptable.

## 7. Acceptance criteria

- `broker.log` gains exactly one `event=pending_open` JSONL line per successful `open_pending_reply` RPC. Verifiable: `grep '"event":"pending_open"' broker.log | wc -l` == count of successful opens in the test run.
- `broker.log` gains exactly one `event=pending_check` JSONL line per `check_pending_reply` RPC, on every outcome branch (valid / invalid_non_supervisor / unknown_perm / expired). All four covered by tests.
- No raw `perm_id` and no raw `requester_session_id` appears anywhere in any of the new log lines (regex assertion in tests).
- `requester_alias`, `supervisors`, `reply_from_alias`, `kind`, `outcome`, `ttl_seconds` appear in plaintext.
- Hashing is stable: two log lines with the same source `perm_id` have identical `perm_id_hash`.
- A failed log write (chmod 0o400 on broker.log) does not change the RPC result or raise — handler-level success preserved.
- No new files under `<broker_root>/`; rotation piggybacks on broker.log.
- Build clean, full test suite green, peer-PASS in slice worktree per #427 Pattern 8.
