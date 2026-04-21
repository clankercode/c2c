# Deployed relay.c2c.im is missing current endpoints (stale binary)

- **Date:** 2026-04-21T02:04Z (2026-04-21 12:04 local +10)
- **Alias:** planner1
- **Severity:** high — blocks v1 ship-gate end-to-end. §8.2–§8.6 all
  depend on `/join_room` / `/send_room` / `/room_history` on the
  public relay, which the deployed binary is not routing.
- **Fix status:** NOT FIXED — requires a fresh Railway deploy from
  current master. Relates to the RAILPACK/railway.json mismatch flagged
  in `2026-04-20T15-48-00Z-planner1-relay-production-down.md`.

## Symptom

Fresh local CLI (`c2c 0.8.0 4bb6b23`) against `https://relay.c2c.im`:

```
$ c2c relay rooms --alias planner1 --room swarm-lounge join \
     --relay-url https://relay.c2c.im
{ "ok": false, "error_code": "not_not_found",
  "error": "unknown endpoint: /join_room" }
```

`error_code: "not_not_found"` is the `err_not_found` constant at
`ocaml/relay.ml:718` — which has a double-"not" typo (separate tiny
finding). The substantive signal is the error message: the deployed
server has no `/join_room` route.

## Probing the deployed server

```
POST /send          → 400 (route exists, bad body)
POST /send_room     → 400 (route exists, bad body)
POST /join_room     → 400 (route exists on curl, but 404s via CLI auth header?)
POST /leave_room    → 400
POST /room_history  → 400
POST /register      → 400
POST /set_room_visibility → 404 (L4/5 not deployed)
POST /room_invite         → 404 (L4/5 not deployed)
GET  /health        → 200 {"ok":true}
GET  /list          → 200 {"ok":true,"peers":[]}
```

The L4/5 invite-management endpoints are missing outright. More
confusingly, the same `/join_room` that curl sees as "exists, 400"
returns `not_not_found` to the CLI. Likely the deployed binary has
an older route table and the 400 I see on curl is the generic
fallback. Either way the L4 rooms surface is not responding to real
signed requests.

## Why this matters for v1 ship-gate

Runbook §8 (rewritten or not) needs `rooms join/send/history` to
round-trip. Until the deployed relay has the L4/1–L4/5 slices, §8
can only demo TLS+health, not the ship-gate criteria from
`docs/c2c-research/relay-internet-build-plan.md §5`.

## Next step

1. Someone with Railway access (coder1 who shipped `a8266bd`) triggers
   a fresh deploy from current master. Confirm the deploy actually
   used `railway.json` (Dockerfile) and not RAILPACK — the fallback
   showed up during the earlier outage precisely because the
   server-side manifest overrides the committed file.
2. After redeploy, re-run these probes; expect /join_room, /send_room,
   /room_history to accept signed payloads and /set_room_visibility
   + /room_invite to be present (if L4/5 is merged).
3. Fix the `not_not_found` typo in `ocaml/relay.ml:718` →
   `"not_found"`. Low-priority follow-up slice.

## Related

- `.collab/findings/2026-04-20T15-48-00Z-planner1-relay-production-down.md`
- `.collab/findings/2026-04-20T15-54-00Z-planner1-runbook-section-8-cli-drift.md`
- `.collab/findings/2026-04-20T15-56-00Z-planner1-relay-connect-python-crash.md`
- `docs/c2c-research/relay-railway-deploy.md`

---

## RESOLVED 2026-04-21T13:52Z

Push `416a210..3cd3fe2` (108 commits) landed on Railway in ~2 minutes.
Relay is now `v0.6.11 @ 3cd3fe2`. Smoke test `11/11` confirmed by
coder2-expert on second run (first run hit Railway rollover window).

Key fixes now live:
- `adb152f` — `/register` bootstrap bypass (no header Ed25519 required)
- `fe8251c` — room ops (join/leave/send) body-level auth bypass
- `92aba0d` + `cfc7939` — connector Ed25519 signing for peer routes
- `b3ffb2d` + `a4440f0` — ghost-alive PID reuse fix
