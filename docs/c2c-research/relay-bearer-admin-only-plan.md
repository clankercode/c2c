# L2 slice 4 — Move bearer token off peer → admin-only

**Owner:** coder2-expert · **Created:** 2026-04-21 · **Status:** design,
scope **approved** by coordinator1 2026-04-21T01:29Z — hard cut, no flag.
**Unblocked by:** L3/2 (`7742d79`) + L3/3 (`0bc08eb`).

## Scope decision (2026-04-21, coordinator1)

> "Prefer hard cut — L3 is live, first-bind-wins is enforced, no reason
> to keep Bearer as a peer escape hatch. Go for it."

Revised from the draft below: **no `--bearer-admin-only` flag**. Peer
routes become Ed25519-only unconditionally; admin routes become
Bearer-only unconditionally. Admin route list pinned by coordinator1:

- `/gc`
- `/dead_letter`
- `/list?include_dead=1` (the `include_dead=1` query form; bare `/list`
  stays peer-readable)

The original flagged-rollout draft follows for historical context only.

## Goal

Peers authenticate with Ed25519 per-request signatures (spec §5.1,
shipped in L3/3). Bearer tokens should stop being an accepted form on
peer-facing routes and become admin-only.

Today the auth check in `make_callback` (ocaml/relay.ml ~1165) accepts
**Ed25519 OR Bearer** uniformly on every protected route. That was the
soft-rollout during L3/3. This slice closes the rollout window for
peer routes while keeping a narrow admin surface for Bearer.

## Proposed change (minimal surface)

### CLI flag

```
c2c relay serve --bearer-admin-only
```

Default OFF — preserves current behaviour so no peer client breaks
without operator action.

### Route classification

- **Peer routes (Ed25519 only when flag on):** `/register`, `/heartbeat`,
  `/list`, `/list_rooms`, `/send`, `/send_all`, `/poll_inbox`,
  `/peek_inbox`, `/join_room`, `/leave_room`, `/send_room`,
  `/room_history`.
- **Admin routes (Bearer only when flag on):** `/gc`, `/dead_letter`.
  Plus any future `/sweep`, `/metrics`.
- **Unauthenticated:** `/`, `/health` — unchanged.

Rationale for classification: `/gc` mutates relay state (sweeps dead
registrations), `/dead_letter` exposes messages that failed delivery —
neither is part of normal peer traffic.

### Auth matrix

| Flag     | Peer route                                 | Admin route      |
|----------|--------------------------------------------|------------------|
| off      | Ed25519 OR Bearer (today's behaviour)      | Ed25519 OR Bearer |
| on       | Ed25519 only (Bearer rejected)             | Bearer only       |

When flag is on and the caller presents Bearer on a peer route, return
`error_code: "unauthorized"` with `msg: "peer routes require Ed25519 auth
per spec §5.1; bearer is admin-only"`. Similarly for Ed25519 on an admin
route: reject with an unambiguous message.

### Wire-level implementation sketch

In `make_callback`, after the body read + Ed25519 probe:

```ocaml
let is_admin_route = List.mem path ["/gc"; "/dead_letter"] in
let bearer_admin_only = token_cfg.admin_only in
let auth_ok = match ed25519_result, is_admin_route, bearer_admin_only with
  | Ok (Some _), false, _              -> true   (* ed25519 on peer: OK *)
  | Ok (Some _), true,  true           -> false  (* ed25519 on admin when strict: reject *)
  | Ok (Some _), true,  false          -> true   (* soft rollout *)
  | Ok None,     true,  _              -> check_auth token auth_header
  | Ok None,     false, true           -> false  (* peer route needs Ed25519 in strict *)
  | Ok None,     false, false          -> check_auth token auth_header
  | Error _,     _,     _              -> false
```

The tricky bit is that `token` is currently `string option` threaded
through from `start_server`. Extending that to `{ value : string option
; admin_only : bool }` (or passing `admin_only` as a separate arg) keeps
the existing callers compiling.

## Rollout

1. Land the code + flag — default OFF. No client impact.
2. Operator-side: run `c2c relay serve --bearer-admin-only` once
   trusted peers are all on L3 identity. Docs at
   `relay-tls-setup.md` will call this out.
3. Once v1 is declared done, flip the default ON (separate slice; needs
   a soft-deprecation window announcement).

## Tests

- Alcotest for each matrix cell: (flag off|on) × (peer|admin route) ×
  (bearer|ed25519|none) = 12 cases. Golden: the routing matrix above.
- Contract test against a live in-proc relay: a peer without Ed25519
  identity succeeds when flag off, gets 401 when flag on.

## Open Qs for coordinator1 / Max

1. **Flag name:** `--bearer-admin-only` vs `--strict-auth` vs
   `--no-peer-bearer`. Recommend the first — names the mechanism, not
   the posture.
2. **Default:** OFF for v1 is the conservative choice. Keeps Python
   clients and any not-yet-Ed25519 code paths working. Flip to ON in a
   later slice once telemetry shows nobody is still on Bearer.
3. **Admin route list:** is `/gc` really admin? It's a mutation but
   there's no destructive irreversibility. `/dead_letter` leaks
   cross-peer content so it definitely is. Recommend keeping both as
   admin per POLA.
4. **Admin future:** do we want to add `/admin/sweep` or similar as a
   new endpoint in this slice, or keep the slice focused on reshaping
   auth without adding surface? Recommend: focused. Sweep is its own
   slice.

## Blockers

- None code-side. Scope approval pending from coordinator1 (DM'd at
  01:26Z).
- Coordination: avoid committing while coder1 is in the middle of a
  Layer 4 slice on `ocaml/relay.ml` — the shared-WT hazard documented
  at `.collab/findings/2026-04-21T01-24-00Z-coder2-expert-shared-workdir-wip-sweep.md`
  means my `git add ocaml/relay.ml` would sweep their WIP. Wait for
  their commit or negotiate a file lock via lounge.
