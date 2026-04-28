---
author: coder2-expert
ts: 2026-04-21T09:10:00Z
status: draft — awaiting coordinator1 review
---

# Alias Naming Standardization Protocol

## Motivation

Today every agent registers a short alias (`coordinator1`, `coder2-expert`,
`opencode-local`) that is unique only within a single broker root. As relay
federation lands, two independent deployments may both have a `coordinator1`.
We need a canonical form that uniquely identifies an agent across brokers and
hosts without requiring every message sender to type a long FQDN every time.

---

## 1. Canonical Alias Form

```
<name>#<repo>@<host>
```

| Field    | Description                                           | Example              |
|----------|-------------------------------------------------------|----------------------|
| `<name>` | Human-chosen short alias                             | `coordinator1`       |
| `<repo>` | Git repo slug (`basename $(git rev-parse --show-toplevel)`) | `c2c`          |
| `<host>` | Machine hostname (`hostname -s`)                     | `xertrov-cachyos`    |

Full example: `coordinator1#c2c@xertrov-cachyos`

### Invariants

- `<name>` must match `[a-z][a-z0-9-]{0,62}` (existing validation, unchanged).
- `#` and `@` are reserved separators; neither may appear in name/repo/host.
- `<repo>` defaults to the git repo slug of `C2C_MCP_BROKER_ROOT` (walk up to
  find `.git`, take `basename`). Falls back to `unknown` if outside a git tree.
- `<host>` defaults to `hostname -s` output, truncated to 32 chars.

### Storage

The broker stores the full canonical form internally:
- Registry field: `canonical_alias` (new field, alongside existing `alias`).
- `alias` (short name) stays as the primary routing key for backwards compat.
- Two agents on different hosts can hold the same `alias` if their
  `canonical_alias` differs.

---

## 2. Short-Prefix Resolution

Senders typically type only `<name>` (e.g. `coordinator1`). Resolution rules:

1. **Exact short match, unique**: one registration has `alias == name` →
   deliver directly.
2. **Exact short match, ambiguous**: multiple alive registrations share the
   same `alias` → error: "ambiguous alias 'coordinator1'; candidates:
   coordinator1#c2c@xertrov-cachyos, coordinator1#other@remote-box".
3. **Partial canonical prefix**: `coordinator1#c2c` matches all registrations
   whose canonical alias starts with `coordinator1#c2c` → apply uniqueness
   check again (rule 1/2).
4. **Full canonical**: `coordinator1#c2c@xertrov-cachyos` → exact lookup; no
   ambiguity possible.

Resolution preference order for `send`:
```
short → partial-canonical → full canonical
```

If a short alias is ambiguous and the sender is on the same host/repo as one
of the candidates, the local candidate wins (locality tiebreak). This keeps
single-host swarms working without change.

---

## 3. `-N` Next-Prime Disambiguator

When `c2c start -n coordinator1` is requested but `coordinator1` is already
alive on the same canonical coordinates (`#repo@host`), the broker proposes a
disambiguated alias instead of rejecting outright:

```
coordinator1-2    (first candidate: 2 is the first prime)
coordinator1-3    (next prime if -2 also taken)
coordinator1-5
coordinator1-7
coordinator1-11
…
```

Why primes? Sequential integers (`-1`, `-2`) collide with teams that already
number their agents (`coder1`, `coder2` → starting a third one shouldn't
silently produce `coder1-1`). Primes are visually distinct, unlikely to be
pre-chosen by humans, and yield an infinite unique sequence.

### Implementation sketch

```ocaml
let primes = [| 2; 3; 5; 7; 11; 13; 17; 19; 23; 29; 31; 37; 41; 43; 47 |]

let disambiguate broker ~base_alias =
  (* Try base first *)
  if not (alias_alive broker base_alias) then base_alias
  else
    let rec try_prime i =
      let p = if i < Array.length primes then primes.(i)
              else (* sieve on demand *) next_prime primes.(Array.length primes - 1) in
      let candidate = Printf.sprintf "%s-%d" base_alias p in
      if not (alias_alive broker candidate) then candidate
      else try_prime (i + 1)
    in
    try_prime 0
```

The broker returns both the proposed alias and a `disambiguated: true` flag so
the caller can surface a warning: `[c2c start] alias 'coordinator1' taken;
auto-assigned 'coordinator1-2'. Pass -n NAME to override.`

---

## 4. Interaction with Existing Alias Guard

The existing `alias_occupied_guard` (liveness check before hijack) stays
unchanged — it guards against stealing a live peer's alias. The prime
disambiguator runs *before* registration: it proposes a free name, then
registration proceeds normally. No change to the hijack-rejection path.

---

## 5. Migration / Backwards Compatibility

- **Phase 0 (current)**: no canonical form stored; short alias only.
- **Phase 1 (near-term)**: broker stores `canonical_alias` alongside `alias`.
  Resolution rules apply but are opt-in (federation not live). MCP tools
  `whoami` and `list` gain a `canonical_alias` field. No wire format change.
- **Phase 2 (relay federation)**: relay routes using full canonical; brokers
  on different hosts can exchange messages. Short-prefix resolution becomes
  load-bearing cross-host.

Phase 1 is the implementation target. Phase 2 is future work gated on the
relay federation slice.

---

## 6. Open Questions

- Should `<repo>` use the git remote URL slug (e.g. `c2c` from
  `github.com/xertrov/c2c.git`) or the local dir basename? Remote URL is more
  stable across clones; local basename is available offline. Suggest: remote
  URL slug when available, local basename as fallback.
- Should prime-disambiguated aliases be suggested by the broker (server-side)
  or computed client-side? Server-side is authoritative and avoids races;
  client-side is simpler. Suggest: server-side, returned in the `register`
  response as `suggested_alias` when a collision occurs.
- Max's long-term vision mentions `c2c init --supervisor`. Does the supervisor
  registration use the canonical form too, or a separate resolver?

---

## Summary

| Feature                  | Current        | Proposed            |
|--------------------------|----------------|---------------------|
| Alias form               | `name`         | `name#repo@host`    |
| Cross-host uniqueness    | No             | Yes (Phase 2)       |
| Ambiguity on short alias | Silent fail    | Explicit error + list |
| Collision on `c2c start` | Error          | Propose `name-N`    |
| Locality tiebreak        | N/A            | Same host/repo wins |
