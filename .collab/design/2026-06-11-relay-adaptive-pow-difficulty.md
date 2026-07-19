# Relay adaptive proof-of-work difficulty (PARTIAL — register enforcement + retry landed)

**Status**: partial implementation. The hashcash primitive, adaptive policy,
flag-gated relay `/register` enforcement, and bounded client mint/retry on
`pow_required` are implemented behind `C2C_RELAY_POW=1`; proactive precompute
from advertisement headers, broader costed route enforcement, production tuning,
and Sybil hardening remain open. Logged from a request by Max (2026-06-11).
Companion todo entry in `todo.txt`.
**Author**: claude (Max's interactive session).
**Motivation surfaced alongside**: the lease-TTL bump to 24h (commit on branch
`relay-lease-ttl-24h`) — longer leases make alias squatting cheaper, which
sharpens the need for a cost on high-frequency relay requests.

---

## 0. Correction to a stated assumption

Max asked "I think we have PoW on requests to the relay right?" — at the time,
we did not. As of the initial implementation slice, relay PoW exists only for
`/register` and is disabled unless `C2C_RELAY_POW=1`. What exists today on
`relay.c2c.im` (prod mode):

- **Ed25519 identity auth** — `/register` is a signed op (TOFU pin); peer routes
  (`/send`, `/poll_inbox`, room ops) require per-request Ed25519 signatures.
- **Nonce replay protection** — `register_nonce_ttl = 600s`, `request_nonce_ttl
  = 120s`, signature time windows.
- **Register-only PoW enforcement when enabled** — `/register` uses
  per-identity adaptive cost accounting and server-issued challenges behind
  `C2C_RELAY_POW=1`. Legacy unsigned registration is rejected while this flag
  is enabled because there is no canonical Ed25519 actor to charge. Bounded
  client transparent retry is implemented for `pow_required`; other routes and
  proactive precompute from the `X-C2C-PoW-Next` header are still follow-up work.

So this feature began as net-new PoW work: the primitive and initial adaptive
register enforcement have landed, but the design below still tracks the broader
rollout.

## 1. Goal (Max's framing, captured verbatim-ish)

> The more requests you make to the relay, the more PoW is required. Each
> request has a 'cost' (registration is the main one I care about right now),
> and that cost is how much it puts pressure on increasing the PoW difficulty.
> There should be a grace where it doesn't increase, then it goes up in discrete
> steps. PoW requirements for the next request are sent in reply headers (or in
> an error-type message with payload if a request is made with a difficulty
> that's too low).

Restated as requirements:

- **R1 — per-request cost.** Each relay request type has a cost weight.
  `register` is the dominant cost; cheap/free for low-impact reads.
- **R2 — cost drives difficulty.** Accumulated cost (per actor, sliding window)
  raises the *required* PoW difficulty for that actor's next request.
- **R3 — grace band.** Below a threshold of accumulated cost, difficulty stays
  at a floor (often zero) — normal usage pays nothing.
- **R4 — discrete steps.** Past the grace band, difficulty rises in discrete
  steps, not continuously.
- **R5 — proactive advertisement.** The difficulty required for an actor's
  *next* request is returned in a response header (e.g. `X-C2C-PoW-Next`).
- **R6 — reactive challenge.** A request that arrives with too-low (or missing)
  PoW is rejected with a structured error whose payload carries the required
  difficulty + challenge parameters, so the client can retry correctly.

## 2. PoW primitive (proposed)

Hashcash-style. Client finds a `pow_nonce` such that
`SHA256(challenge_string || pow_nonce)` has **≥ D leading zero bits**, where `D`
is the required difficulty.

`challenge_string` must bind the work to *this* request so it can't be
precomputed or replayed:

```
challenge = ctx="c2c/v1/pow" | route | actor_id | server_epoch | server_nonce
```

- `server_epoch` / `server_nonce` are issued by the relay (in the advertisement
  header / challenge error) and expire — bounds precompute and ties work to a
  recent server-issued challenge.
- `actor_id` binds work to the actor so one actor can't farm another's PoW.
- Verification cost is one hash; minting cost is `~2^D` hashes (the asymmetry).

PoW fields ride in the request body alongside the existing Ed25519 proof
(`pow_nonce`, `pow_server_nonce`, `pow_epoch`). PoW is **independent of and
composes with** the existing Ed25519 signature — sig proves *who*, PoW proves
*work done*.

## 3. Accounting & difficulty function (proposed)

Per **actor** (see §5 open question on actor identity), maintain a sliding-window
cost accumulator `C`:

```
cost weights (initial straw values, tune later):
  register        : 10      # the one Max cares about
  send / send_all : 1
  room send       : 1
  poll / peek     : 0       # reads are free
  heartbeat       : 0       # MUST stay free — connectors heartbeat every ~30s

C := decayed_sum_over_window(actor's request costs)

required_difficulty(C):
  if C <= GRACE            -> 0            # R3 grace band
  else                     -> STEP * ceil((C - GRACE) / BUCKET)   # R4 discrete steps
  capped at D_MAX
```

- `GRACE`, `BUCKET`, `STEP`, `D_MAX`, window length, decay = tuning constants
  (single canonical home, à la the lease-ttl constant we just centralized).
- **Decay** (e.g. exponential half-life, or token-bucket refill) returns an
  actor to the grace band after a quiet period — so a legitimate burst is cheap
  and only *sustained* high-rate request flows pay escalating cost.

## 4. Protocol shape (proposed)

**Advertisement (R5)** — every relay response includes:
```
X-C2C-PoW-Next: difficulty=<D>; epoch=<e>; server_nonce=<n>; ttl=<s>
```
A well-behaved client reads this and pre-computes PoW for its next costly
request before sending it.

**Challenge-on-reject (R6)** — a costly request arriving with insufficient PoW
gets `429`-ish:
```json
{ "ok": false, "error_code": "pow_required",
  "required": { "difficulty": <D>, "epoch": <e>, "server_nonce": <n>,
                "ctx": "c2c/v1/pow", "ttl_s": <s> } }
```
Client mints PoW from the payload and retries. Note the client's `requirement`
does not parse `ttl_s` and ignores it: at the bounded retry budget the whole
mint+retry sequence costs single-digit milliseconds, so a challenge cannot
expire underneath it. Revisit if the retry ever grows a wall-clock component.
(Mirrors how the relay already returns structured `error_code` + payload for
`alias_conflict`, nonce reuse, etc., so the client surface is consistent.)

**Capability discovery** — advertise support in `/health`
(e.g. `"pow": {"enabled": true, "scheme": "sha256-leading-zeros-v1"}`) so older
clients/relays degrade gracefully and we can stage rollout.

## 5. Open questions (need decisions before building)

1. **Actor identity = ?** Per-Ed25519-identity is natural (we already have it)
   but identities are *free to mint*, so a Sybil attacker sidesteps per-identity
   difficulty by rotating keys. Options: (a) per-identity, (b) per-source-IP,
   (c) **both** (max of the two difficulties), (d) tie new-identity creation
   itself to PoW. Leaning (c)+(d). This is the crux — get it wrong and the
   feature is decorative.
2. **State location & cost.** Difficulty accounting is per-actor mutable state.
   In-memory (lost on relay restart — acceptable? the relay already keeps
   sessions in memory by default) vs the SQLite backend. Restart resets everyone
   to the grace band — probably fine.
3. **Heartbeat exemption.** The connector heartbeats every ~30s; with 24h leases
   that's a lot of requests. Heartbeats MUST be cost-0 (or near), or we punish
   exactly the well-behaved long-lived peers. Confirm heartbeat is a distinct
   route from `register` for accounting.
4. **Tuning constants.** `GRACE / BUCKET / STEP / D_MAX / window / decay` —
   pick straw values, then observe real `relay.c2c.im` traffic before hardening.
5. **Clock / epoch model.** `server_epoch` rotation cadence vs challenge `ttl`
   vs the existing nonce TTLs — reuse the nonce-window machinery where possible.
6. **Client UX.** The OCaml `c2c` client now mints PoW and retries on
   `pow_required` transparently, bounded at 3 minted attempts and
   short-circuiting when the relay repeats an identical challenge (#11). It
   still needs proactive precompute from the advertisement header if we want
   agents to avoid the initial challenge failure.

## 6. Suggested phasing

- **P0 (primitive)**: shipped — implement + unit-test the hashcash verify/mint
  pair and the challenge-string binding.
- **P1 (register enforcement)**: relay side shipped behind `C2C_RELAY_POW=1`.
- **P2 (adaptive)**: relay-side per-actor cost accounting + difficulty function
  + `X-C2C-PoW-Next` advertisement + `pow_required` challenge error shipped for
  `/register`; bounded client mint+retry on `pow_required` shipped. Broader route
  coverage and proactive header precompute remain open.
- **P3 (Sybil hardening)**: per-IP dimension and/or PoW-gated identity creation
  (resolve OQ1).
- **P4 (tune)**: observe prod traffic, set the constants.

## 7. Why this matters now

The relay is a **public commons** with no admission cost. Registration is the
abuse-sensitive op (alias squatting, especially now that leases last 24h).
PoW makes *sustained* high-rate registration expensive while keeping normal
single-agent usage free (grace band) — without a centralized rate-limiter or
per-tenant accounts (which c2c deliberately doesn't have yet).

---

— claude, 2026-06-11. Parked for processing; see `todo.txt`. Seeking input from
the swarm before implementation (per `todo-ideas.txt` communal-process norm).
