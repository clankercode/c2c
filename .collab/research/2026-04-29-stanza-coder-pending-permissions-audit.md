# Pending-permissions broker audit (stanza, 2026-04-29)

Source files reviewed: `ocaml/c2c_mcp.ml` (broker types lines 72-121,
broker pending API 711-751, MCP `open_pending_reply` handler 5761-5805,
`check_pending_reply` handler 5806-5840, M4 register-guard 4538-4548,
RPC audit-log writer 6222-6243), `ocaml/c2c_mcp.mli`, `ocaml/test/test_c2c_mcp.ml`
(cases 6826-7106), `docs/security/pending-permissions.md`. Drift survey
at `.collab/research/2026-04-29-stanza-coder-pending-permissions-drift.md`
covers doc/code drift; this audit focuses on five concerns: race
conditions, capacity bounds, TTL/expiry, authorization binding, audit
trail.

## Overview

The mechanism is **not** "operator-approves-staged-MCP-call". It tracks
plugin-driven permission/question DM round-trips so the broker can
validate that an inbound supervisor reply is bound to a pending request
(M2) and reject re-registration of an alias that still has open pending
state (M4). State lives in `<broker_root>/pending_permissions.json` as
a flat list of `{perm_id, kind, requester_session_id, requester_alias,
supervisors[], created_at, expires_at}`. `open_pending_reply` writes;
`check_pending_reply` reads; entries are filtered by TTL on every
read; expiry is lazy. There is no operator-in-the-loop approve/deny —
the supervisor agent's reply is the "approval", and validation is just
`reply_from_alias ∈ supervisors`.

## Findings

### 1. Race condition / no lock around pending-permissions file — HIGH

`Broker.open_pending_permission` (`c2c_mcp.ml:730-732`) does
load → filter-expired → cons new → save; `remove_pending_permission`
(741-744) does load → filter-by-id → save. None of the four pending-API
functions use `with_registry_lock` (compare DND/register at lines 1408,
1439, 1453 which all do). `write_json_file` (476-505) gives readers
all-or-nothing via temp+rename, so corruption is impossible, but classic
lost-update is: if two `open_pending_reply` calls interleave their
load/save, one entry is silently dropped. Two concurrent agents can
also observe inconsistent state since reads are not serialized with
writes. Tests do not cover concurrent access.

**Severity HIGH** because the M4 alias-reuse guard
(`pending_permission_exists_for_alias`, 4538) depends on this file
being authoritative — a dropped entry silently disables the security
guard for that alias.

### 2. No capacity bound — MED

`open_pending_permission` (730) appends with no per-alias or global cap.
A misbehaving or compromised agent can call `open_pending_reply` in a
loop with random `perm_id`s and 600s TTLs to grow
`pending_permissions.json` arbitrarily — every other broker call that
reads it (and the M4 register guard does so on every register) does
an O(N) JSON parse + linear filter. There is no rate-limit at this
surface (`relay_ratelimit.ml` is for relay-tier traffic, not local
MCP tools).

**Severity MED** rather than HIGH because the file is per-broker-root
(per repo) and writers must be a registered local session, but the
broker's own register flow consults this file, so a flooded file
degrades registration latency.

### 3. TTL / expiry — works, with two gaps — LOW

Expiry is enforced lazily: `get_active_pending_permissions` (725-727)
and the inline `expires_at > now` checks in `find_pending_permission`
(737) and `pending_permission_exists_for_alias` (750) all filter on
read. `open_pending_permission` rewrites the file with the filtered
set, so expired entries do get pruned opportunistically when new ones
are added. Default TTL is 600s, overridable via
`C2C_PERMISSION_TTL`.

- **Gap A**: if no new `open_pending_reply` ever fires, expired entries
  accumulate on disk forever (no janitor).
- **Gap B**: malformed `C2C_PERMISSION_TTL` silently falls back to 600s
  (5783-5786) without trimming — see drift note in the prior research
  file.

Abandoned entries are otherwise harmless (filtered on read).

### 4. Authorization binding — partial, with hole — MED

`check_pending_reply` (5806-5840) verifies
`reply_from_alias ∈ pending.supervisors` and returns
`pending.requester_session_id` so the plugin knows where to deliver.
The supervisor-set is captured at open-time, which is the right
binding. However:

- `open_pending_reply` (5774-5781) resolves the requester's alias from
  the registry; if the calling session is unregistered, it stores
  `requester_alias = ""` and writes the entry anyway. A subsequent
  register of alias `""` (or any code path reading `requester_alias`)
  would match.
- Worse: `reply_from_alias` is supplied by the **caller** of
  `check_pending_reply`, not derived from the calling session; so the
  validator trusts the calling agent to honestly report the reply's
  sender. Any agent can call `check_pending_reply` with a known
  `perm_id` plus any supervisor's alias and get back the requester's
  session_id (information disclosure).

**Severity MED** — the surface is local-only and `perm_id`s are UUIDs.

### 5. Audit trail — MISSING for decisions — MED

`broker.log` (6222-6243) records `{ts, tool, ok}` per RPC, deliberately
excluding content. So you can see **that** `open_pending_reply` /
`check_pending_reply` fired, but not `perm_id`, `kind`, `supervisors`,
`requester_alias`, or `valid/invalid` outcome. There is no separate
decision log. For forensics ("who approved what for whom") this log is
insufficient. The `pending_permissions.json` file is also delete-on-resolve
in design (per docs) — though `remove_pending_permission` is **unused**
in code, so today entries TTL-out rather than being removed, which
incidentally preserves a short-lived audit record but not a persistent
one.

## Recommendation (slicing)

- **Slice A — Finding 1 (lock)**: wrap all four `Broker.*pending*`
  functions in `with_registry_lock`, add a concurrent-write test.
  Small, contained, M4 guard's correctness depends on it. **HIGH —
  do this first.**
- **Slice B — Finding 4 (auth holes)**:
  - Reject `open_pending_reply` from unregistered sessions (mirrors
    the CLI behavior already in place).
  - Have `check_pending_reply` derive `reply_from_alias` from the
    calling session's registration rather than trusting an argument.
  - **MED — near-term.**
- **Slice C — Finding 2 (capacity)**: design first — propose a 1k-entry
  global cap + per-alias cap (e.g. 16). MED, defer behind A+B.
- **Slice D — Finding 5 (decision log)**: write `pending_permissions.log`
  JSONL with hashed `perm_id`s. MED, defer.
- **Finding 3 (TTL gaps)**: LOW — file and ignore until a real
  symptom shows up.

## Note on framing

The mechanism is leaner than the audit framing assumed (no
operator-staged approval gate, just a request-reply binding registry).
Some of the original concerns map onto a richer design that doesn't
exist yet — if "operator-staged approval" is a future feature, it's a
**new design**, not a hardening of this one. Worth confirming with
Cairn whether the broker should grow that surface or stay narrow.
