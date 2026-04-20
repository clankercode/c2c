# Public relay at relay.c2c.im is down (Railway fallback)

- **Date:** 2026-04-20T15:48Z (2026-04-21 01:48 local +10)
- **Alias:** planner1
- **Severity:** high — v1 ship-gate (`c2c-delivery-smoke.md §8`) cannot
  run against production; any agent trying to register through the
  public relay will 404.
- **Fix status:** RESOLVED 2026-04-21T01:53Z local by Max. Account-
  side issue on Railway; service now back. `/health` → `{"ok":true}`
  and native `c2c relay status --relay-url https://relay.c2c.im`
  returns `{ok:true}`. Builder/railway.json mismatch (see Diagnosis)
  was a symptom, not the cause.

## Symptom

All paths on `https://relay.c2c.im` return HTTP 404 with
`x-railway-fallback: true`:

```
$ curl -fsS -o /dev/null -w "%{http_code} %{url}\n" \
    https://relay.c2c.im/{,health,status} \
    https://c2c-production-69dd.up.railway.app/health
404 https://relay.c2c.im/
404 https://relay.c2c.im/health
404 https://relay.c2c.im/status
404 https://c2c-production-69dd.up.railway.app/health
```

Response headers include `x-railway-fallback: true` — Railway is
serving its fallback page because the target service is not
reachable. Both the custom domain (`relay.c2c.im`) and the raw
Railway URL (`c2c-production-69dd.up.railway.app`) 404, so DNS /
custom-domain wiring is NOT the problem — the service itself is down.

## How I discovered it

Began dry-running `c2c-delivery-smoke.md §8.1` (TLS handshake +
`/health`) as prep for the v1 ship-gate. `/health` is the very first
command in that section and it fails.

## Diagnosis (coordinator1, 2026-04-21T01:51Z local)

Railway's latest deployment is at merge commit `15890c23` on
`origin/master`, but its server-side service manifest is
`"builder": "RAILPACK"` with `"healthcheckPath": null` and
`"startCommand": null` — i.e. Railway is **ignoring the committed
`railway.json`** (which specifies `DOCKERFILE`, `/health`, and our
`sh -c` startCommand).

Logs show the container:

1. Starts cleanly, binds `:8080`, prints the startup banner.
2. Prints the banner a second time (one restart).
3. `Stopping Container`.
4. `ON_FAILURE` with the 10-retry cap exhausted → Railway serves
   the fallback 404 that the `x-railway-fallback: true` header
   identifies.

**Root cause:** the service was initially provisioned via the Railway
UI with the `RAILPACK` builder. `railway.json` was added to the repo
*later* but the server-side manifest still overrides it. Fresh pushes
to master *may* re-read `railway.json` on a new build, but that's not
guaranteed — a dashboard-level builder switch may also be needed.

Local is 30 commits ahead of `origin/master`; a push to master would
at minimum attempt a fresh build against the Dockerfile. Waiting on
Max to authorize the push (policy — no unilateral push to shared
infrastructure).

## Likely causes

1. A recent push broke the OCaml relay binary (build failed, Railway
   deploy rolled over to fallback).
2. The service crashed or its process exited; Railway restart limit
   hit.
3. Railway workspace suspended (billing / quota).

Cannot diagnose further without Railway dashboard access.

## Impact

- `§8.1` through `§8.5` of the runbook are all blocked — nothing in
  the ship-gate can run without `/health` up.
- L4/3 and L4/4 implementers cannot validate their changes against
  the live relay; they must rely on alcotest only until the relay is
  back.
- Any other swarm member trying `c2c relay register --relay-url
  https://relay.c2c.im` will see a confusing 404 rather than a clean
  auth error.

## Next step

1. Someone with Railway access (probably coder1 — shipped the deploy
   at `a8266bd`) to check the Railway dashboard: latest deploy status
   + logs.
2. If a recent commit broke the build, roll back to the prior known-
   good deploy.
3. Add a §8.0 precheck to the runbook: `curl -fsS <url>/health` must
   return 200 BEFORE running the remaining §8 steps, so we fail fast
   with a clear error instead of misreading a 404 as an auth issue.

## Related

- `docs/c2c-research/relay-railway-deploy.md` — operator recipe
- `docs/c2c-research/RELAY.md` Layer-adjacent Task #6 — claims relay
  is live (`a8266bd`). Index is now stale until the service is back.
