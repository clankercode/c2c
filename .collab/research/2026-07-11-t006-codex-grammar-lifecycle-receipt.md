# T006 receipt — managed Codex command grammar, identity, and lifecycle

- Backlog: **P1.M1.E1.T006** (depends on merged T002). Date: 2026-07-11 (UTC).
- Slice worktree: `.worktrees/p1-t006-grammar`, branch `slice/p1-t006-grammar`.
- Consumes T002's primitive `C2c_codex_app_server` (`start`/`supervise_until_exit`/
  `stop`/`persisted`/`diagnostic_to_json`); does NOT re-implement spawn/auth/transport.

## Deliverables

- **`ocaml/c2c_codex_session.ml` (+ `.mli`)** — the one shared implementation path:
  deterministic alias derivation, `--yolo` forwarding, `--` passthrough splitting,
  thread-conflict reconciliation, status terminology, per-instance identity mapping,
  and `run` (the lifecycle glue over T002).
- **`ocaml/cli/c2c_codex_cmd.ml`** — `c2c codex` / `c2c new codex` /
  `c2c resume codex ALIAS`, all calling `C2c_codex_session.run`.
- **`ocaml/cli/c2c_managed_cmd.ml`** — `c2c start codex` delegates to the same path
  (new `--yolo` / `--thread-id` / `--app-server` flags; non-codex clients unchanged).
- **`ocaml/cli/c2c_instances_cmd.ml`** — app-server lifecycle status in JSON + human.
- **`docs/commands.md`** — four-form grammar, flag semantics, `--` passthrough, and
  the recommended `cx='c2c new codex --'` shell alias.
- **`ocaml/test/test_c2c_codex_session.ml`** — 16 cases (below).
- Wiring: `ocaml/dune`, `ocaml/cli/dune`, `ocaml/test/dune`, `c2c_main_cmd.ml`.

## Four command forms — one path

`c2c start codex` / `c2c codex` / `c2c new codex` / `c2c resume codex ALIAS` all
route through `C2c_codex_session.run ~mode:(Start|New|Resume alias)`. `run` resolves
mode: app-server engaged by `--app-server` or `C2C_CODEX_APP_SERVER=1`; otherwise the
legacy hook-backed launch runs via the `fallback` thunk (the existing
`C2c_start.cmd_start`, preserved verbatim). On an app-server startup diagnostic it
prints an actionable minimum-version message and falls back to hooks (safe-contract §6).
`--yolo` forwards the codex bypass flag in BOTH modes.

**Default is hook-backed (app-server opt-in).** This keeps the live `c2c start codex`
behavior unchanged for the running swarm while the passive-ingress (T003) and
turn (T007) stack lands. Flipping the default to app-server is a one-line change in
`C2c_codex_session.run` (drop the `engage` gate) once T003/T007 merge —
**coordinator decision.**

## Deterministic session-ID-derived alias + collision extension

`derive_alias ~session_id ~taken`: SHA256(session_id) → two distinct alias-pool words
(base). If `taken base`, extend deterministically with `SHA256(session_id:n)[0..4]` for
n=1,2,… re-probing `taken` — never an unrelated random alias, stable across
restart/resume. Proven with FIXED ids in `test_c2c_codex_session`:
- `stable`: same id ⇒ identical alias across calls.
- `distinct ids`: two new threads ⇒ distinct aliases.
- `resume stable`: same id re-derives the same alias.
- `collision extension` / `collision chain`: base (and base+first-ext) taken ⇒
  deterministic, base-prefixed, stable extension.
Runtime seed: a fresh stable session id per new instance (persisted in
`<instance_dir>/codex-session.json`); resume/restart reloads it ⇒ same alias. The
Codex thread id (authoritative for resume) is stored separately (`thread_id`); a
`--thread-id` conflict with the saved thread is rejected (`reconcile_thread` ⇒ Error),
never guessed. `--alias` overrides the routing identity only; a conflict with a
differently-owned saved alias is rejected. No routable alias is published before
`C2c_codex_app_server.start` returns `Ok` (version/capability failures return a
diagnostic first — AC7).

## `--yolo` forwarding + non-persistence

`frontend_extra_args ~yolo` prepends exactly `--dangerously-bypass-approvals-and-sandbox`
and a conspicuous stderr warning prints on use. It is a per-launch argv element only —
never written to the identity mapping or instance config, so a later resume without
`--yolo` does not inherit it. Tests: `yolo/forwards bypass`, `yolo/absent by default`,
`lifecycle-glue/hook mode uses fallback` (asserts the bypass flag reaches the hook
fallback's extra_args).

## `--` passthrough (coordinator items 2 & 3)

Everything after a literal `--` is forwarded verbatim to the stock codex frontend and
never parsed as a c2c flag. Split helpers `split_client` / `split_client_alias` /
`drop_sep` are in the lib and unit-tested (`passthrough/*`):
`c2c new codex -- --model gpt-5.3-codex-spark` ⇒ passthrough `[--model; gpt-5.3-codex-spark]`.
Documented `cx='c2c new codex --'` so `cx --model gpt-5.3-codex-spark` Just Works.
Proven live below (the frontend argv carried `--model gpt-5.3-codex-spark`).

## Lifecycle / status

Saved status distinguishes `starting` / `online-attached` / `offline` / `failed-startup`
(`status_of_app_server_state`), surfaced in `c2c instances` (JSON `app_server_status`
+ human `app-server=<status>`), sharing terminology across the grammar. The owning
process supervises app-server + frontend via T002 (`supervise_until_exit` + `stop`);
frontend exit reaps the server, no orphan.

## Live tmux smoke (real codex 0.144.1, gpt-5.3-codex-spark; isolated broker/instances)

Isolated `C2C_MCP_BROKER_ROOT`/`C2C_INSTANCES_DIR` under scratch; bash pane (zsh
autocorrect otherwise eats the `codex` token). Command:
`c2c codex --alias smoke-probe -- --model gpt-5.3-codex-spark` (C2C_CODEX_APP_SERVER=1).

Process tree BEFORE: no `codex app-server` / `codex --remote` (baseline clean).
RUNNING (t≈4s):
```
persisted codex-app-server.json: state=running server_pid=1057958 frontend_pid=1059539
                                 (token_sha256 present; NO raw token field)
server:   node codex app-server --listen ws://127.0.0.1:36585 --ws-auth capability-token --ws-token-sha256 <sha>
frontend: node codex --remote ws://127.0.0.1:36585 --remote-auth-token-env C2C_CODEX_REMOTE_TOKEN_<unitid> --model gpt-5.3-codex-spark  (pts/39)
mapping codex-session.json: {session_id=<uuid>, alias="smoke-probe"}   # published only after Running
pane: full codex TUI rendered — "OpenAI Codex (v0.144.1)  model: gpt-5.3-codex-spark medium"
stderr: [codex app-server] online-attached: alias=smoke-probe endpoint=ws://127.0.0.1:36585
```
Proofs: `--` passthrough reached the frontend (`--model gpt-5.3-codex-spark` in argv);
bearer token passed by ENV-VAR NAME, not raw in argv; alias published only after Running.

EXIT (Ctrl-C in the TUI):
```
persisted: state=offline
orphan sweep: NO ORPHAN — server_pid 1057958 + frontend_pid 1059539 both reaped
port 36585: released
pane: back at shell prompt
```
Process tree AFTER cleanup: no `codex app-server` / `codex --remote`; isolated smoke
env removed; real `~/.local/share/c2c/instances` never touched.

An earlier attempt piped the launch through `| tee` — the frontend refused with
"stdout is not a terminal" (correct: the pipe broke the tty), the supervisor reaped the
server, state=offline, no orphan. Second run without the pipe rendered the TUI and owns
the pane tty (AC5).

## Verification (return codes)

| command | rc |
|---|---|
| `scripts/dune-build-locked.sh build` (full build + suite) | 0 |
| `test_c2c_codex_session.exe` (16 tests) | 0 |
| `test_c2c_start.exe` (197 tests, regression) | 0 |
| `check-broker-log-catalog.sh` | 0 |
| `check-connect-commands.py` (40 cmds) | 0 |
| `codegen-alias-words --check` | 0 |
| `git diff --check` (whitespace) | 0 |
| tmux launch/exit smoke (server+frontend, reap-proof) | 0 (no leaks) |
| `just check` | 1 — **sole failure PRE-EXISTING + unrelated**: `git diff --exit-code -- .../skills` reports the `.codex`/`.opencode/skills/c2c/SKILL.md` codegen drift that also differs vs `origin/master` (T001/T002 receipts note the identical drift). This slice touches no skills files; every other check step passes independently. |

## B127-gated criterion

The `delivery=queued_offline` receipt for a known-offline alias depends on B127
(durable offline delivery) and is intentionally NOT implemented here. Everything else
(grammar, identity, `--yolo`, lifecycle, online attach) is complete and independent of
B127. Unknown-alias sends remain an error.

## Integration seams for later tasks

- **T003** (passive ingress) fills `persisted.thread_id` and reconciles the real
  app-server session id into `codex-session.json`'s `session_id` seed; the alias derived
  from that seed is stable.
- **T005** (docs/doctor/delivery-mode) adds the app-server transport states to
  `delivery_mode` and the full managed-env parity (`publish_alias_env` sets only the
  minimum registration env today).
- **T007** starts turns over the authed control channel.
