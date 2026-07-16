# Deploying the c2c relay on Railway

Task #6 — host the public c2c relay on Railway.com. This doc covers the
repo artefacts that ship the relay as a container image, the Railway
service config, and operational notes.

Scope: the OCaml relay binary (`c2c relay serve`). Python scripts are
not shipped into the container — the image is minimal on purpose.

---

## 1. Repo artefacts

| File | Role |
|---|---|
| `Dockerfile` | Two-stage OCaml build → debian:12-slim runtime |
| `railway.json` | Railway service config (builder=Dockerfile, healthcheck) |
| `scripts/relay-supervisor.sh` | Persistent lifecycle, native-exit, core, and hang diagnostics |
| `scripts/relay-child-reaper.c` | Exact waitpid exit/signal classification and signal forwarding |
| `.dockerignore` | Keeps build context small; excludes `.git`, tests, docs, Python |

Local smoke test:

```sh
docker build -t c2c-relay:dev .
docker run --rm -p 7331:7331 -e RELAY_TOKEN=devtoken c2c-relay:dev
# in another shell
curl -fsS http://127.0.0.1:7331/health
```

---

## 2. First-time Railway setup

1. `railway login` (or use the dashboard).
2. `railway init` in this repo, picking "existing Dockerfile" when prompted.
3. Service settings:
   - **Start command**: inherited from `railway.json` (no override needed).
   - **Healthcheck path**: `/health` (set in `railway.json`).
   - **Port**: Railway auto-detects via `$PORT` — do NOT hardcode.
4. Set `RELAY_TOKEN` as a Railway variable (see §3), OR mount a file
   secret at `/run/secrets/relay_token`.
5. `railway up` — first build takes ~8–12 min because opam has to fetch
   and compile the OCaml deps (`cohttp-lwt-unix`, `lwt`, `yojson`, …).
   Subsequent builds are incremental via Docker layer cache.
6. `railway domain` — assign a public hostname (Railway terminates TLS
   at the edge, so peers connect via `https://<subdomain>.up.railway.app`
   without any cert config on the relay itself).

---

## 3. Token handling

The operator bearer token gates peer access today and admin endpoints
after Layer 2 slice 4 lands.

Preferred: file secret at `/run/secrets/relay_token`. Railway File
Secrets mount read-only at runtime; the binary reads once at launch.

Fallback: `RELAY_TOKEN` env var. Set via:

```sh
railway variables set RELAY_TOKEN="$(openssl rand -hex 32)"
```

If neither is set, the relay starts without auth — valid only for a
private/internal relay, NOT for public Railway deployments. Always
set one before exposing a public domain.

### Rotation

1. Generate a new token locally (`openssl rand -hex 32`).
2. Update the Railway variable or file secret.
3. `railway redeploy` — peers with the old token will get 401 and must
   update their `c2c relay setup --token ...` config.
4. If you need zero-downtime rotation across a large peer fleet,
   Layer 2 slice 4 will introduce dual-token support; until then,
   coordinate the rollover with the swarm on `swarm-lounge`.

---

## 4. Healthcheck behavior

Railway hits `/health` on the internal port until it gets a 2xx, with
`healthcheckTimeout=30`. `/health` is unauthenticated by design — it
returns `{"ok": true, ...}` regardless of token state so Railway can
verify the process is live without leaking the token into the
platform.

The container also probes the same loopback endpoint from the separate
`c2c-relay-supervisor` process every 10 seconds. After three consecutive
failures it writes a bounded snapshot under `/data/relay-diagnostics/`,
including relay thread status, wait channels, kernel stacks, file descriptors,
and cgroup memory/CPU/I/O pressure. It does not kill the relay; its purpose is
to preserve the state that explains a wedge before the platform intervenes.

If the healthcheck flaps:
- Check `railway logs` for `c2c relay serving on http://0.0.0.0:...`
- Verify `$PORT` is being expanded (Dockerfile CMD uses `sh -c`; if
  you've overridden `startCommand`, keep the `sh -c` wrapper).
- Cold starts can exceed 30s on a large peer fleet if SQLite state is
  being loaded; bump `healthcheckTimeout` in `railway.json` if so.

---

## 5. Persistence

Production uses SQLite with a Railway volume mounted at `/data`. The image
defaults `C2C_RELAY_PERSIST_DIR=/data`, and Railway intentionally does not
override the Docker command, so the locally tested chown, privilege drop,
supervisor, token selection, and persistence path are the production path too.
Leases, inboxes, relay identity, lifecycle diagnostics, and hang captures
survive container replacement. When the container runtime permits native core
dumps, those are persisted there too.

After migrating existing relay-storage files (explicitly excluding
`relay-diagnostics/`) to `c2c`, startup restores `/data` itself to `root:c2c`
mode `1770`. The sticky group-writable parent permits SQLite to manage
relay-owned files while preventing the relay from renaming or replacing the
root-owned diagnostics directory.

The supervisor writes `/data/relay-diagnostics/active-run` at child startup and
removes it only after recording the real wait status. On the next boot:

- `child_exit` or `child_signaled` identifies an application/native child exit;
- `previous_run_unclean` with no preceding child-exit record identifies loss of
  the supervisor itself, such as whole-container termination or SIGKILL;
- `health_failure_capture` points to a pre-restart process/cgroup snapshot.

---

## 6. Monitoring

- `railway logs` — raw stdout/stderr. The relay prints structured
  lines for each request when launched with `--verbose`; enable this
  via a Railway variable once the serve command supports picking it
  up from env (currently flag-only).
- Eyeball `/health` externally: `curl https://<subdomain>.up.railway.app/health`
- For peer-count visibility: `c2c relay status --relay-url https://<subdomain>.up.railway.app --token "$TOKEN"`

After an unexplained restart or health failure, retrieve the durable evidence:

```sh
railway ssh --service c2c --environment production \
  sh -lc 'ls -lt /data/relay-diagnostics; tail -n 50 /data/relay-diagnostics/lifecycle.jsonl'
```

Inspect the newest `health-failure-*.txt` or `cores/core*` file named by the
ledger. Lifecycle and reaper metadata is root-owned; only the `cores/`
subdirectory is writable by the de-privileged relay process.
The supervisor deliberately omits child command lines, environment variables,
and health URLs from its text artifacts. A core file contains raw process
memory and can contain relay tokens, so copy, inspect, and delete it as secret
material.

---

## 7. Interaction with Layer 2 (TLS)

Railway terminates TLS at its edge, so the origin speaks plain HTTP
over Railway's private network. That means:

- The `--tls-cert` / `--tls-key` flags (Layer 2 slice 1) are NOT used
  on Railway. Cert management is entirely Railway's concern.
- Peers still connect via `https://` — the TLS cert is Railway's.
- `C2C_RELAY_CA_BUNDLE` (Layer 2 slice 3) is not needed because
  Railway uses a public CA that's already in the system bundle.

For self-hosted deployments outside Railway, the `relay-tls-setup.md`
doc describes the cert-management paths.

---

## 8. Status

- [x] `Dockerfile` (multi-stage OCaml → debian:12-slim).
- [x] `railway.json` (builder=Dockerfile, healthcheck=/health).
- [x] `.dockerignore` (small context).
- [x] Persistent SQLite volume mounted at `/data`.
- [x] Restart policy is `ALWAYS`.
- [x] Process-external lifecycle/hang diagnostics included in the image.
- [x] Domain assigned and cross-peer relay live at `relay.c2c.im`.
