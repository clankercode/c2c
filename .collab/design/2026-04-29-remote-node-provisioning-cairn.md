# Remote Node Provisioning UX — design

**Author:** cairn-vigil (coordinator1)
**Date:** 2026-04-29
**Status:** design / pre-slice
**Related:**
- `.collab/design/2026-04-29-relay-forwarder-transport-cairn.md` (#330 V3 forwarder)
- todo-ongoing.txt → "Remote relay transport" (v1 shipped 25dc1b1)
- `.collab/runbooks/remote-relay-operator.md` (today's manual flow)
- `docs/relay-quickstart.md`, `docs/cross-machine-broker.md`

## TL;DR

Today, putting a c2c agent on a remote box is ~12 manual steps across two
hosts: SSH key copy, install OCaml/dune, build c2c, set env, register
alias, hand-pair tokens, launch session, peer-discover from the local
side. Goal: collapse this to **one command** —
`c2c remote provision <user@host>` — and keep agents reachable as
first-class swarm members from `c2c list`.

The design treats the remote box as a **federated peer relay**, not a
shared filesystem (matches #330 forwarder direction). One identity per
host; aliases stay local to that host's broker; the local relay learns
about the remote via auto-populated `peer_relays` config.

---

## 1. Today's friction (numbered)

What an operator goes through right now to add a remote agent:

1. **SSH key bootstrap.** No standard key location guidance; user picks
   one, runs `ssh-copy-id`, hopes agent forwarding isn't needed for
   relay→remote later.
2. **Manual remote install.** No `curl | sh` installer; user has to
   `git clone`, install opam + dune, run `just install-all`, deal with
   missing system packages (libev, gmp).
3. **Path divergence.** Remote `~/.local/bin/c2c` rarely on PATH for
   non-login SSH; `c2c install self` on remote silently puts the binary
   somewhere the next `ssh host c2c whoami` can't find.
4. **Broker-root drift.** Local + remote each compute their own
   `XDG_STATE_HOME/c2c/repos/<fp>/broker/`; if the remote is a fresh
   clone, the fp matches; if it's a different repo or no repo, fp
   diverges silently → cross-host alias routing breaks.
5. **Identity-key sync.** Each host generates its own
   `relay-identity.json` on first relay boot. Operator must copy
   relay-A's pubkey into relay-B's `--peer-relay-pubkey` flag and
   vice-versa — two manual file scrapes per direction.
6. **Token sharing.** `--token` is a Bearer secret per relay; copy-paste
   to every other host that connects. No rotation story. No
   per-edge tokens (revoking one client revokes all).
7. **Alias collisions.** Remote agent registers `lyra-quill` while a
   local one already holds it → silent reassignment or refusal,
   depending on canonical-alias version.
8. **Session-launch invocation.** No remote analog to
   `c2c start claude`; operator SSHs in, runs it manually, has to
   keep the SSH session alive (or set up systemd / tmux / nohup).
9. **`c2c list` lies.** Local `list` only shows local-broker
   sessions; remote agents are invisible until cross-host routing
   resolves — no `--all-hosts` flag.
10. **Reachability mystery.** When a send fails, operator can't tell
    if it's local broker, local relay, peer relay, peer broker, or
    remote agent. No `c2c remote ping <host>` end-to-end probe.
11. **Doctor blindness.** `c2c doctor` is local-only. Cross-host
    health requires hand-running `curl /relay_info` and eyeballing.
12. **Lifecycle gap.** No way from local CLI to stop, restart, or
    refresh credentials on a remote agent. Every change is "SSH in
    and re-do it."

---

## 2. v1 happy path (annotated)

```
$ c2c remote provision deploy@gpu-box.tail-abc.ts.net --name gpu-box
Step 1/6: validating SSH access ........ ok (deploy@gpu-box, key auth)
Step 2/6: installing c2c on gpu-box ..... ok (download + extract, sha256 verified)
              installer: https://c2c.im/install.sh  → ~/.local/bin/c2c (v0.42.1)
Step 3/6: bootstrapping remote relay .... ok
              broker root: ~/.c2c/repos/<fp>/broker (auto-detected)
              identity:    relay-server-identity.json (generated, pk: 7f3a…)
Step 4/6: pairing relays ................ ok
              local  → registered gpu-box pk in peer_relays
              remote → registered local-host pk in peer_relays
              shared edge token: c2c-edge-7f3a-… (saved both sides)
Step 5/6: starting remote relay daemon .. ok
              systemd --user: c2c-relay.service active (or nohup fallback)
              health: http://gpu-box:7331/healthz → 200
Step 6/6: end-to-end smoke .............. ok
              local→remote send (ping@gpu-box) round-tripped in 134ms

Provisioned. Use:
  c2c remote list                 # see registered hosts
  c2c remote start gpu-box claude # launch a managed agent on gpu-box
  c2c remote stop  gpu-box <name> # stop a managed agent
  c2c remote ping  gpu-box        # 1-shot health probe
  c2c remote logs  gpu-box        # tail remote relay log
```

Then to spin up an agent there:

```
$ c2c remote start gpu-box claude --role researcher
launching claude on gpu-box… alias: kestrel-haze@gpu-box
$ c2c list --all-hosts
  cairn-vigil       local              alive 12s
  stanza-coder      local              alive 4m
  kestrel-haze      gpu-box            alive 3s
$ c2c send kestrel-haze@gpu-box "welcome to the swarm"
ok (forwarded via gpu-box, 142ms)
```

**Time budget**: provision ≤90s on a warm box (install dominates),
≤30s on already-installed boxes. Start-agent ≤10s.

---

## 3. Slice plan (4–6 slices)

### S1 — `c2c remote` command skeleton + SSH validation [XS, ~120 LOC]

- New `c2c remote` group: `provision`, `list`, `stop`, `ping`,
  `logs`, `start` (stub).
- `remote provision <target>`: validate ssh access only; print the
  6-step plan but only execute step 1.
- New file `ocaml/cli/c2c_remote.ml`; thin shell wrapper around
  `Lwt_process` for SSH; surface `--ssh-opt` passthrough.
- Saved hosts file: `~/.config/c2c/remotes.toml` (atomic write).
- **AC:** unit test (fixture-gated SSH stub) — registers a host
  entry; `c2c remote list` prints it; rejects unreachable target.

### S2 — remote installer (`install.sh` + `c2c install --remote`) [S, ~250 LOC]

- Public `install.sh` at `https://c2c.im/install.sh` (added to
  `docs/`), detects platform (linux-amd64, linux-arm64, darwin-arm64),
  downloads pinned release tarball from GitHub Releases, places at
  `~/.local/bin/c2c`, sha256-verifies, ensures PATH hint.
- `c2c remote provision` step 2 = `ssh <target> "curl -fsSL c2c.im/install.sh | sh"`.
- Idempotent: if remote already has same SHA, skip; if older,
  upgrade respecting `C2C_INSTALL_FORCE`.
- **AC:** installer passes shellcheck + bashbang test; provision
  on a Docker target leaves a working `c2c whoami` reachable over
  SSH (`ssh target ~/.local/bin/c2c whoami`).

### S3 — remote relay bootstrap + edge-token pairing [M, ~400 LOC]

- Step 3: SSH-execute `c2c relay init --auto` on remote, which
  generates `relay-server-identity.json`, picks a free port, writes
  `<broker-root>/relay.toml` with listen+token, prints the pubkey to
  stdout.
- Step 4: local CLI captures remote pubkey, writes a `peer_relays`
  entry to local `relay.toml`, then SSH-pushes local relay's pubkey
  to remote's `relay.toml`. Single shared **edge token** scoped to
  this pair (random 24-byte hex), saved to both sides under
  `peer_relays.<host>.token`.
- Both sides reload config (SIGHUP if running, otherwise picked up
  on next start).
- **AC:** integration test in `docker-tests/test_remote_provision.py`
  with two relay containers — provision wires them up, both
  `peer_relays` tables populated, signed cross-relay POST succeeds.

### S4 — remote managed-session control (`remote start`/`stop`) [M, ~300 LOC]

- `c2c remote start <host> <client> [--role R] [--alias A]`:
  SSH-execs `c2c start <client> ...` on remote inside a `tmux new
  -d -s <session>` (or systemd-run user scope). Stream a
  registration-confirmation back over SSH stdout.
- `c2c remote stop <host> <name>`: SSH `c2c stop <name>`.
- `c2c remote list`: SSH `c2c instances --json`, merge with local
  `c2c instances --json` into a single table.
- `c2c list --all-hosts` (extension to existing `list`): query
  each host in `remotes.toml` over the relay's `/list` endpoint
  (already exists); aggregate.
- **AC:** integration — provisioned host can launch a fake claude
  shim, alias appears in `c2c list --all-hosts`, send round-trips,
  `remote stop` cleans up.

### S5 — health: `remote ping`, `remote logs`, doctor integration [S, ~180 LOC]

- `c2c remote ping <host>`: end-to-end probe. Sends a dummy
  message to a reserved alias `c2c-echo@<host>` (broker-side
  echo handler, 5-line addition). Reports each leg's latency.
- `c2c remote logs <host> [--follow]`: `ssh <host> tail -f
  <broker-root>/relay.log`.
- `c2c doctor remote-mesh`: lists each remote with last-ping,
  pubkey fp, edge-token age, peer_relays entries on both sides.
- **AC:** ping succeeds in test container; doctor surfaces an
  intentionally-broken peer (mismatched pubkey) with red status.

### S6 — docs + closeout [XS]

- New `docs/remote-provisioning.md` — public quickstart.
- Update `docs/relay-quickstart.md` to point at provision command
  for the multi-host case.
- Runbook: `.collab/runbooks/remote-provisioning.md` (failure
  modes, manual-recovery escape hatches, file layout).
- Coord-PASS, push, close epic.

**Sequencing:** S1+S2 in one worktree. S3 in its own (touches both
hosts, biggest risk). S4 after S3. S5/S6 in parallel.

---

## 4. Auth model

**v1: per-host identity, per-edge shared token.**

- Each host runs **one** relay → **one** Ed25519
  `relay-server-identity.json` (matches forwarder design §4).
- Trust between two relays is bound by **mutual pubkey
  registration**, not certificates. Provision is the trust-bootstrap
  ceremony — the only moment where keys flow over SSH (an already-
  trusted channel).
- Each *edge* (pair of relays) gets its own **bearer token** scoped
  to that edge, used for HTTP calls. Compromise of one token only
  affects one edge; rotation = re-run `c2c remote provision <host>`
  (idempotent, replaces token+pk if pk hasn't drifted; refuses if
  pk changed without `--force`).
- Aliases stay **local to the host they registered on**. Cross-host
  addressing uses `alias@host` (already in #379). No global alias
  registry, no "shared identity" — each agent is rooted to its
  host's broker.

**Why not federated/single shared identity?**
- A "swarm-wide" identity creates a single point of compromise
  and forces a key-distribution problem we don't need to solve.
- Per-host identity matches the operational reality: each box has
  one operator, one user, one relay process.

**Why not OAuth/OIDC?**
- Out of proportion to v1 stakes (small private swarms). Adds an
  IdP dependency. Revisit at v3 if multi-tenant becomes a use-case.

**Why not WireGuard / Tailscale-only?**
- Many users will be on Tailscale (and provision should detect &
  prefer the `*.ts.net` address), but we shouldn't *require* it.
  Ed25519+token works on any TCP-reachable host. Tailscale is a
  great default but not a hard dep.

**v2 directions** (design must not foreclose):
- Per-edge token → per-call signed requests using each side's
  identity (no token at all, just signature). Deferred because
  current `Relay_signed_ops` requires alias-bound keys; relay-as-
  client identity needs a parallel signing path (filed as #330
  forwarder S1 in companion design).
- Identity-key rotation: today, `c2c remote rotate <host>`
  refuses if pk changed; v2 = optional auto-refresh window.

---

## 5. Relationship to forwarder (#330 V3 / #379)

**Strict layering** — provisioning sits *above* the forwarder:

| Layer | Owner | What it does |
|---|---|---|
| Routing (alias@host parsing, dead-letter) | #379 (shipped) | `split_alias_host`, dead-letter contract, `from_alias` rewriting |
| Transport (relay→relay POST, signing, via-cap) | #330 V3 forwarder | `peer_relays` Hashtbl, `forward_send`, identity bootstrap |
| Provisioning (this doc) | new | populates `peer_relays`, generates identities, wires SSH-driven setup |

The forwarder design **assumes** `peer_relays` is populated and
identities exchanged. This doc's S3 is exactly that population
ceremony, scripted. **The forwarder lands first**; provisioning is
the UX layer that makes it usable without hand-editing `relay.toml`.

Concretely:
- Forwarder S1 introduces `peer_relays` Hashtbl + identity file.
- Provisioning S3 writes to those structures via CLI (`c2c relay
  add-peer <name> --url --pubkey --token`) instead of operators
  hand-editing TOML.
- `c2c remote ping` exercises forwarder S2's `forward_send` path.
- Dead-letter doctor (forwarder S5) feeds `c2c doctor remote-mesh`
  here.

**No code overlap**, just a hand-off at the `peer_relays` boundary.

---

## 6. Open questions

1. **Where does the public installer live?** `c2c.im/install.sh`
   needs hosting + a release-tarball pipeline. GitHub Releases via
   tag-driven CI is the obvious shape. Decision: ship S2 with a
   manual-tarball fallback and a placeholder script that operators
   can self-host; promote to `c2c.im` once the release pipeline lands.

2. **Should `remote provision` require Tailscale?** No (per §4),
   but should we *recommend* it strongly when the target's address
   resolves to a public IP? Lean: yes, warning in S1.

3. **Systemd vs nohup vs tmux for daemonizing remote relay.**
   Try systemd-user first (`systemctl --user enable --now`),
   fall back to `nohup` if not available, refuse to use plain
   tmux for the relay (it's a daemon, not an interactive session).
   Managed *agent* sessions (S4) keep using tmux as today.

4. **Provision for boxes without sudo / without homedir.** Guard
   for `~/.local/bin/c2c` failing — fall back to `~/c2c-bin/` with
   a PATH-export hint. Is that worth solving in v1 or punt?
   Recommend: punt; document the assumption (homedir + PATH or
   `~/.local/bin` writable).

5. **Cross-host alias collisions.** If `lyra-quill` exists on both
   hosts, the canonical-alias work (memory: project_canonical_alias)
   already disambiguates as `lyra-quill#repo@host`. Provision
   should surface this at boot — print "host gpu-box has aliases
   {…}; collisions: {lyra-quill}" so operators see it.

6. **Edge-token vs forwarder identity-only auth.** S3 provisions
   *both* a token (for HTTP Bearer) and pubkeys (for forwarder
   POST signing). Is that belt-and-suspenders? Maybe; but token
   covers the relay's admin endpoints (`/instances`, `/logs`)
   which the forwarder doesn't sign. Keep both.

7. **Where does `remotes.toml` live?** `~/.config/c2c/remotes.toml`
   keeps it user-scoped not repo-scoped (a remote box is a host-
   level resource, not per-project). Confirm: does this break
   the per-repo broker root model? No — broker root is per-repo,
   peer relays are per-host. Different axes.

8. **Re-provisioning idempotency.** Running `c2c remote provision`
   twice on the same target should be safe. S3 needs to detect
   "already-paired" state (matching pubkey + valid token) and
   skip with "already provisioned (last verified <ts>)". Force
   refresh = `--force` flag.

9. **Remote-side broker root surprise.** If user's remote has
   `XDG_STATE_HOME` unset and a non-empty `$HOME`, broker lands
   at `$HOME/.c2c/repos/<fp>/`. fp comes from this repo's git
   remote URL. What if the remote isn't a clone? Fall back to
   `c2c-default` fp namespace. Provision should print the
   resolved broker root prominently so operators can spot
   surprises.

10. **GUI integration.** The planned Tauri/Vite GUI
    (memory: project_gui_app) should expose `remote provision`
    as a wizard. Out of scope here; flag for GUI epic.

---

## Appendix — file map (anticipated)

- **New:** `ocaml/cli/c2c_remote.ml` (~600 LOC across S1+S4+S5).
- **New:** `ocaml/remote_config.ml` (`remotes.toml` read/write).
- **New:** `docs/install.sh` (POSIX-sh installer).
- **New:** `docs/remote-provisioning.md` (public quickstart).
- **New:** `.collab/runbooks/remote-provisioning.md`.
- **Touch:** `ocaml/cli/c2c.ml` (register `remote` group).
- **Touch:** `ocaml/cli/c2c_relay.ml` (`relay add-peer`,
  `relay init --auto` subcommands feeding S3).
- **Touch:** `ocaml/cli/c2c_list.ml` (`--all-hosts` flag).
- **Touch:** `ocaml/cli/c2c_doctor.ml` (`doctor remote-mesh`).
- **Reuse:** forwarder's `peer_relays` Hashtbl + identity loader.

**Next action:** validate sequencing against the forwarder slice
plan in `swarm-lounge` (does forwarder S1+S2+S3 land before
provisioning S3?). If yes, file as the next epic after #330; if
not, S1+S2 (skeleton + installer) can land in parallel since
they're forwarder-independent.
