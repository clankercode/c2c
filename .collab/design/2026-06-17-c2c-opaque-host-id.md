# c2c-side opaque_host_id — fix the canonical_alias privacy leak

**Goal**: replace the leaky parts of `canonical_alias` (`<alias>#<repo-slug>@<short-hostname>`) with an opaque, stable, non-reversible `opaque_host_id` that the c2c broker computes client-side and stores in the registration. The relay and other consumers can use it for routing and dedup without learning the project name or hostname.

**Date**: 2026-06-17. Pre-implementation design. Co-authored with `pi-c01ea5` (this session) — slices split below.

**Status**: design only. The extension-side workaround in `pi-c2c/src/relay.ts` (compute a `host_hash` from `product_uuid` → `machine-id` → `hostname`, embed as `<alias>#<host_hash>` in the relay alias) is in production. This doc covers the c2c-side proper fix.

## Problem

The c2c broker's `canonical_alias` is auto-populated on every `register` to `<alias>#<repo-slug>@<short-hostname>` (see `ocaml/c2c_broker.ml:1721-1725`):

```ocaml
let compute_canonical_alias ~alias ~broker_root =
  Printf.sprintf "%s#%s@%s" alias
    (repo_slug_of_broker_root broker_root)   (* e.g. "pi-c2c", "c2c" *)
    (short_hostname ())                       (* e.g. "xsm", "stormbox" *)
```

Where:

- `repo_slug_of_broker_root` walks up the broker root path: `…/repo/.git/c2c/mcp` → `…/repo` → basename → `repo` (`ocaml/c2c_broker.ml:1703-1710`). Exposes the project name.
- `short_hostname` is `Unix.gethostname()` split on `.` and taking the first component (`ocaml/c2c_broker.ml:1712-1720`). Exposes the machine name.

This leaks in three contexts:

| Context | Leaked info | Why it matters |
|---|---|---|
| `c2c list` output (MCP `/list` JSON, `c2c list --json`) | every peer's project + host | anyone with read access to a broker learns the structure of every user's dev environment |
| `canonical_alias` field on the registration JSON (sent to other peers in `register` responses, `peek_inbox` envelopes, MCP `whoami`) | every peer's project + host | any peer you interact with learns your project + host |
| Sessions broker (`~/.c2c/sessions/broker`) fallback | the `$HOME` dirname when the broker root resolution falls through to `$HOME/.c2c/sessions/broker` | leaks the **OS username** (`/home/xertrov/...` → canonical_alias contains `xertrov`) — observed in the field on `pi-313d8c`'s session |

The leak is irreversible from the alias string (you can't un-do `xsm` or `pi-c2c`), so any tool that consumes the alias to route or dedup has no way to avoid the disclosure.

## What we leverage (do NOT reinvent)

| Need | Existing primitive | Source |
|---|---|---|
| Stable per-host identifier | `host_hash` recipe (product_uuid → machine-id → hostname, 12-hex SHA256, kind-prefixed) | `pi-c2c/src/relay.ts:62-93` (`computeHostHash`, `pickHostSource`) |
| Single primary source + fallback chain | `FsLike` / `NetLike` injection in the host_hash recipe | `pi-c2c/src/relay.ts:43-93`; the test in `pi-c2c/tests/relay.test.ts:26-30` exercises fake fs/net injection |
| Per-host configuration | `~/.config/c2c/identity.json` (Ed25519 keypair) | `ocaml/cli/c2c.ml:5606-5716` |
| Per-registration state (where the new field lives) | `RegistrationLease` JSON shape on relay register | `ocaml/relay.ml:184-217` |
| Auto-population hook on broker `register` | `Broker.register` computes `canonical_alias` from `broker_root` + `Unix.gethostname()` | `ocaml/c2c_broker.ml:1721-1725`, populated at `:1980` |

## What we add

A single new field on the registration record:

| Field | Type | Source | Notes |
|---|---|---|---|
| `opaque_host_id` | string (12-16 hex chars) | client-side, computed once on first register of a session, persisted in the registration JSON | Stable per host; not reversible from the string alone |

The field is **client-supplied** at register time. The broker doesn't compute it (the broker doesn't have access to `/sys/class/dmi/id/product_uuid` on the client's machine). The client computes it the same way the extension's `computeHostHash` does, but the *recipe* moves to c2c itself so non-pi-c2c clients (e.g. raw `c2c` CLI users, OpenCode plugin) can populate it without depending on the extension.

### Wire format — the new field

Add to `RegistrationLease.to_json` (`ocaml/relay.ml:184-217`):

```ocaml
; opaque_host_id = str_opt "opaque_host_id" json
```

Add to the `RegistrationLease` record type (same file, above `to_json`):

```ocaml
opaque_host_id: string option;
```

And to `registration_to_json` in `ocaml/c2c_broker.ml` (around line 1980, the auto-population block):

```ocaml
let with_ohid = match opaque_host_id with
  | Some h -> with_ca @ [ ("opaque_host_id", `String h) ]
  | None -> with_ca
```

### Wire format — the new alias shape

The `canonical_alias` field stays for back-compat (do NOT remove it in this slice), but the **alias-string** used in `register --alias` and the relay's `/list` / `dm/send` routing can now optionally use the new shape:

- Old: `<alias>` (the bare alias the caller chose)
- New (optional, when `opaque_host_id` is set): `<alias>#<host_id>`

The extension and the OpenCode plugin can opt into the new shape by computing the `opaque_host_id` once on the client and passing `--alias <alias>#<host_id>` to `c2c relay register`. The broker doesn't need to change the alias-resolution path — it just stores both `alias` (the full string including `#<host_id>`) and the extracted components (`alias_name`, `opaque_host_id`) in the registration.

For local broker registration, the existing `canonical_alias` is *not* changed in this slice. It stays as `<alias>#<repo-slug>@<host>` (preserves the local-broker provenance). The opaque_host_id is a **relay-layer** concept for now — it solves the cross-machine privacy leak, not the local-broker one (which is a different threat model: the local broker is on your machine, anyone with read access already has your machine).

## Slices

### Slice 1: c2c-side `opaque_host_id` plumbing (this design)

- Add `opaque_host_id: string option` to `RegistrationLease` record
- Add `opaque_host_id` JSON field to `to_json` and `of_json` in `ocaml/relay.ml`
- Add `opaque_host_id: string option` to the local-broker registration record in `ocaml/c2c_broker.ml` (mirrored, but unused for now — the local broker doesn't need it for routing)
- Add `opaque_host_id: string option` to the registration JSON output
- **New c2c CLI subcommand**: `c2c host-id` — compute and print the host id (uses the same recipe as the extension's `computeHostHash`, with `--json` for structured output)
- Update `c2c relay register --alias` to accept `<alias>#<host_id>` form (the `#` separator already works; just don't reject it)
- Update the relay's `/list` handler to return `opaque_host_id` per peer
- Tests: `test_relay_opaque_host_id.ml` covers the lease field round-trip, the CLI subcommand, and the alias-shape parser

### Slice 2: extension consumes opaque_host_id (pi-c2c)

- Extension's `register()` call computes the host id once (same recipe as slice 1's `c2c host-id` subcommand) and passes the new alias shape to `c2c relay register --alias`
- Extension's `c2c_pi_local_info` shows `host_id` (already does, via `computeHostHash()`) and can additionally show the new `opaque_host_id` field on the registration if present
- Tests: `tests/relay.test.ts` already covers the host_hash recipe; just add a test that the extension calls `c2c host-id` once on session_start and caches the result

### Slice 3: deprecate canonical_alias's leaky bits (1+ release later)

- Add a `c2c broker deprecate-canonical-alias` flag that, when set, replaces `canonical_alias` with `<alias>#<host_id>` (opaque) for local registrations too
- Document the migration: existing `canonical_alias` consumers will need to use the new `opaque_host_id` field for cross-machine privacy
- Deprecation warning on `canonical_alias` in the broker log: "WARNING: canonical_alias exposes project + host; consider migrating to opaque_host_id"
- Removal (1+ release later): drop the `<repo-slug>@<host>` portion of `canonical_alias` entirely; leave just `<alias>` as the bare alias

#### `c2c relay gc --stale` — self-cleaning ghost leases

> Full spec + 6 tests + DoD: see commit `ad5289e4` (`design: add c2c relay gc --stale to opaque_host_id slice 3`). The summary below is the design rationale; the commit has the implementation details.

Ghost leases are registrations from sessions that no longer exist (process

Ghost leases are registrations from sessions that no longer exist (process
crashed, session id changed, `C2C_MCP_SESSION_ID` was stale). They persist
until the 24h TTL (`default_lease_ttl = 86400s` in `ocaml/relay.ml`) expires.
This is the `pi-25ac7b` problem observed in the field.

The `ee5fa39` fix prevents *new* ghost leases (by clearing the session id
before relay calls), but existing ghosts need manual cleanup or TTL expiry.
`c2c relay gc --stale` provides self-service cleanup.

**Subcommand**: `c2c relay gc --stale [OPTIONS]`

| Flag | Default | Description |
|---|---|---|
| `--dry-run` | off | Print leases that would be pruned, don't delete |
| `--max-age <seconds>` | `86400` (24h) | Only prune leases older than this |
| `--match-alias <pattern>` | `*` (all) | Glob pattern to scope pruning (e.g. `cli-*` to drop all pre-fix ghost leases) |

**Safety**: the CLI knows its own identity (`~/.config/c2c/identity.json`), so it
can safely drop leases that match `(identity_pk, alias)` but were registered
from a different session. It will NOT drop leases owned by a *different*
identity_pk (those are another machine's legitimate registrations).

**Implementation** (in `ocaml/relay.ml`):

```ocaml
val gc_stale_leases
  :  relay_url:string
  -> token:string option
  -> identity:identity     (* local Ed25519 keypair *)
  -> max_age_s:int
  -> match_alias:string    (* glob pattern *)
  -> dry_run:bool
  -> (int * string list)   (* count pruned, aliases pruned *)
```

The function:
1. Calls `relay list` to get all leases
2. Filters to leases where:
   - `identity_pk` matches the local identity
   - `registered_at < now - max_age_s`
   - `alias` matches the glob pattern
3. For each match: calls `relay register --alias <alias>` with a new session id
   (the alias-collision rejection surfaces the existing lease, and a
   re-register with the same identity_pk takes over, effectively dropping
   the stale session binding)
4. Returns the count and list of pruned aliases

**CLI** (`ocaml/cli/c2c.ml`):

```
$ c2c relay gc --stale --dry-run
Scanning for stale leases (max-age: 86400s, pattern: *)...
  cli-pi-25ac7b  (registered 23h ago, session cli-pi-25ac7b)
  cli-pi-test    (registered 4h ago, session cli-pi-test)
2 stale leases found (dry-run, no changes made)

$ c2c relay gc --stale
Pruned 2 stale leases: cli-pi-25ac7b, cli-pi-test
```

**Tests** (`ocaml/test/test_relay_gc.ml`):
- `gc --dry-run` lists matches without deleting
- `gc --max-age 3600` respects the age threshold
- `gc --match-alias 'cli-*'` scopes correctly
- `gc` does NOT prune leases owned by a different identity_pk
- `gc` handles empty list gracefully
- Integration: register a ghost, gc it, verify it's gone from `relay list`

## Migration / back-compat

The new field is **purely additive**. Existing consumers keep working:

- `canonical_alias` field on registrations: unchanged, still computed as before, still emitted
- `alias` field on registrations: unchanged, callers can still use the bare alias or the full `<alias>#<host_id>` shape
- Relay routing: unchanged for clients that use the bare alias; clients that opt into the new shape get the cross-machine privacy

Old clients (no `opaque_host_id` populated) continue to work; their `canonical_alias` still leaks, but that's the local-broker threat model, not the relay one. New clients (with `opaque_host_id` populated) get the relay privacy immediately.

## Open questions

1. **Hash length**: 12 hex (48 bits) gives ~10⁻⁶ collision at 1M hosts, ~10⁻⁹ at 100K. 16 hex (64 bits) gives ~10⁻¹⁰ at 1M, ~10⁻¹³ at 100K. The extension uses 12 hex. 16 is safer but longer. **Lean: 12 hex, matches the extension's recipe, and the c2c-side c2c host-id subcommand uses the same recipe for consistency.**

2. **Should `canonical_alias` be reformatted when `opaque_host_id` is present?** Two options:
   - (a) Keep `canonical_alias` as-is, add `opaque_host_id` alongside. The local broker still sees the leaky project + host. The relay sees the opaque id. Two parallel identifiers.
   - (b) When `opaque_host_id` is set, replace `canonical_alias` with `<alias>#<host_id>` (the opaque form). The local broker also benefits. But this is a breaking change for any consumer of `canonical_alias`'s leaky fields.
   - **Lean: (a) for slice 1-2, (b) gated behind a `deprecate-canonical-alias` flag in slice 3.** This gives the local broker time to migrate.

3. **Should the new field be a hash or a random nonce?** Hash is deterministic (same host = same id, stable across reboots). Random nonce is opaque but changes per registration. **Lean: hash, matching the extension's recipe.** Determinism is what makes the host id useful for dedup and routing.

4. **Where does the host id live long-term?** Options:
   - (a) Computed every time from `/sys/class/dmi/id/product_uuid` etc. (no state)
   - (b) Cached in `~/.config/c2c/identity.json` or a sibling file
   - **Lean: (a) for slice 1, (b) as an optimization later.** The recipe is fast (one file read), and not caching makes the migration easier (no stale state to worry about).

## Threat model recap

- **Adversary**: anyone who can read the broker (local, sessions, or relay). Includes: the user themselves if they share a broker with others, anyone on the relay for relay-shared data, anyone with file-read access to a sessions broker.
- **Goal**: prevent the adversary from learning the project name and hostname of every c2c user.
- **Current**: `canonical_alias` exposes both. The extension's relay-only fix (`<alias>#<host_hash>`) covers the relay case. Local broker still leaks.
- **This design**: relay case is covered by `opaque_host_id`. Local broker still leaks (different threat model). Slice 3 deprecates the local-broker leak too.

## Files to touch (slice 1, c2c side)

| File | Change |
|---|---|
| `ocaml/relay.ml` | Add `opaque_host_id` to `RegistrationLease` record, `to_json`, `of_json` |
| `ocaml/c2c_broker.ml` | Add `opaque_host_id` field to local-broker registration; emit in `registration_to_json` |
| `ocaml/cli/c2c.ml` | New `c2c host-id` subcommand; update `c2c relay register` to accept `<alias>#<host_id>` form (no-op, the `#` is already valid) |
| `ocaml/relay.ml` (`/list` handler) | Return `opaque_host_id` per peer in the list response |
| `ocaml/test/test_relay_opaque_host_id.ml` | New test file: lease round-trip, CLI subcommand, alias parser |
| `ocaml/relay/relay_client.ml` (or wherever the client builds the `/list` request) | Include the host id in signed requests so the relay can verify ownership |

## Definition of done (slice 1)

- [x] Recipe parity verified by PoC. `ocaml/tools/host_id_poc.ml` (commit `9f11a74c`) ports the extension's `computeHostHash()` to OCaml and produces the same value (`3d08761ae3f3` on this machine). Confirmed: same recipe = same host = same id. The production `c2c host-id` subcommand can safely reuse this recipe.
- [ ] `c2c host-id` returns the same value as `pi-c2c/src/relay.ts:computeHostHash()` on the same machine (recipe parity)
- [ ] `c2c relay register --alias <alias>#<host_id>` succeeds and the resulting lease has `opaque_host_id = <host_id>`
- [ ] `c2c relay list` returns `opaque_host_id` per peer
- [ ] Existing tests pass (no regressions on `canonical_alias` consumers)
- [ ] New test file: `ocaml/test/test_relay_opaque_host_id.ml`, ≥6 tests covering the lease round-trip, the CLI subcommand, the alias parser, and the relay list output
- [ ] Design doc reviewed and merged

## Files to touch (slice 3, c2c side)

| File | Change |
|---|---|
| `ocaml/cli/c2c.ml` | New `c2c relay gc --stale` subcommand with `--dry-run`, `--max-age`, `--match-alias` flags |
| `ocaml/relay.ml` | `gc_stale_leases` function: list leases, filter by (identity_pk, age, alias glob), re-register to take over stale bindings |
| `ocaml/test/test_relay_gc.ml` | New test file: dry-run, max-age, match-alias, identity-pk safety, empty list, integration |
| `ocaml/cli/c2c.ml` | `c2c broker deprecate-canonical-alias` flag |

## Definition of done (slice 3)

- [ ] `c2c relay gc --stale --dry-run` lists stale leases without deleting
- [ ] `c2c relay gc --stale` prunes ghost leases owned by the local identity
- [ ] `--max-age` and `--match-alias` flags work as documented
- [ ] `gc` does NOT prune leases owned by a different identity_pk
- [ ] `c2c broker deprecate-canonical-alias` flag gates the canonical_alias reformatting
- [ ] New test file: `ocaml/test/test_relay_gc.ml`, ≥6 tests
- [ ] Existing tests pass (no regressions)
