# B378: Hermes native and gateway message presentation

Implementation parent: `9d35f5f4e289e9b38b1d2cc5a2b591dfeb0753a3`.
Worktree: `/home/xertrov/.t3/worktrees/c2c/t3-0e843d9a`.
Branch: `t3/hermes-message-styling`.

The existing Telegram renderer is maintained in the sibling repository, so its
runtime integration is isolated at
`/home/xertrov/src/c2c-telegram-plugin/.worktrees/b378-shared-format`, branch
`fix/b378-shared-format`, parent `4c6e35b1cf50e771b2d3212516553d596176c21f`.
Companion implementation commit: `83249b27840dd4a0c9af01bd5d88ff801ba742b6`.
The installed Telegram symlink still points to its unchanged main checkout.

## Discovery

Inspected the canonical plugin plus OCaml `c2c_send_cmd.ml`, `c2c_utils.ml`,
`c2c_schema_v1.ml`, MCP schemas and send handlers. The CLI's legacy
`delivery.state=delivered` describes the synchronous inbox write. MCP's
`queued` and the relay's `accepted` also provide no recipient receipt.
The formatter labels all three as queue acceptance, preserves the original
state as compact metadata, and never changes machine results.

Canary commits `2e6b0228972e1c8110f6311181d7667d332bb6b7` and
`7bdf5f08c62247636114307a3e1470003dc5e3be` already supply the optional setup
suggestion and gateway check docs. Their setup paths are unchanged; no canary
was sent.

## Implementation and invariants

- `message_style.py` supplies an immutable semantic Message, canonical/legacy
  sender and recipient extraction, literal body selection, bounded metadata,
  sticky wrapper errors, exact tool matching and honest queue/offline/error/
  unknown status. Unknown and failed sends show the attempted body.
- `render_terminal.py` supplies literal body gutters with optional ANSI.
  Markup is never interpreted. Ordinary Unicode and every LF/body line are
  retained; terminal and bidi controls are visibly escaped. Non-TTY,
  `TERM=dumb`, `NO_COLOR` and `C2C_HERMES_PLAIN=1` use readable plain text.
- `NativeDisplay` observes public native/MCP completions without replacing
  JSON. Current gateway-hosted CLI/TUI output resolves the exact profile,
  route and live physical session through `SessionAuthority`. Display-only
  `review.summary` events reach actual Ink and active/idle CLI consumers.
  An explicit closing body marker preserves trailing body whitespace through
  consumers that trim outer whitespace. No model-history, approval, attach,
  scheduling or transport operation is invoked by this display adapter.
- The classic CLI retains its prompt-toolkit-aware printer and a plain stdout
  fallback. A current gateway refusal cannot fall through to legacy routing
  or protocol stdout. Profile-scoped host display redaction remains applied.
- Slash send and poll commands return readable cards. Inbound display happens
  after accepted DATA injection or exact request-context acceptance. Envelope
  sanitization, reservations and selective ACK remain independent of display;
  display failure does not change ACK, reinject or mutate the tool result.
  The trusted reply reminder interpolates no peer-controlled labels.
- The sibling adapter loads this exact pure helper from the active profile's
  canonical c2c plugin, through its existing sole transport owner. Telegram
  keeps native bold/blockquote entities, `parse_mode=None`, UTF-16 chunking,
  route consent and journal behavior. No second sender is added. Missing
  shared semantics fails explicitly; the source-test override cannot relocate
  the production profile dependency. Deploy both pieces together later.

## Validation receipt

- `DUNEJOBS=2 just build`: passed from this worktree, regenerating both embeds.
- Fresh focused targets were built with
  `DUNE_THROTTLE_JOBS=2 scripts/dune-build-locked.sh build ./ocaml/cli/test_c2c_setup_hermes.exe ./ocaml/test/test_c2c_schema_v1.exe ./ocaml/test/test_c2c_send_handlers.exe ./ocaml/cli/test_c2c_changelog.exe`.
  Each executable was then run directly from this worktree's `_build/default`:
  **4 suites, 151 tests passed** (setup 60, schema 44, send handlers 24,
  changelog 23). This is a focused count, not repo-wide `@runtest`.
- System Python:
  `python3 -m pytest tests/test_hermes_message_styling.py tests/test_hermes_message_native_host.py tests/test_hermes_plugin_runtime.py tests/test_hermes_plugin_native.py tests/test_hermes_monitor.py --force-test-env -q`:
  **66 passed, 27 skipped, 63 subtests passed**. Optional real-host and
  real-broker probes require their explicit environment. Default collection
  now avoids partial host imports when its dependencies are unavailable.
- Actual Hermes interpreter:
  `HERMES_SOURCE_ROOT=/home/xertrov/.hermes/hermes-agent /home/xertrov/.hermes/hermes-agent/.venv/bin/python -m unittest tests.test_hermes_message_styling tests.test_hermes_message_native_host tests.test_hermes_plugin_runtime tests.test_hermes_plugin_native tests.test_hermes_monitor -q`:
  **93 cases run, 89 passed, 4 skipped**. Both gateway CLI and TUI now traverse
  the actual PluginManager, tools and slash-command dispatch, exact DATA
  acceptance and selective ACK; real active/idle CLI consumers and the
  TypeScript Ink event switch are included. Skips are two opt-in injection
  source probes, the real-broker integration fixture and real CLI monitor.
- Both runs used `PYTHONDONTWRITEBYTECODE=1` and the exact
  `C2C_HERMES_SOURCE` in this worktree. Fixture opt-ins were unset.
  Actual-host tests additionally set `HERMES_TEST_ISOLATION=1`.
- All **12 embedded plugin files** match canonical source byte-for-byte.
  Changelog codegen check and both worktrees' `git diff --check` passed.
- Offline terminal sample: `/tmp/c2c-b378-terminal-preview.txt`, generated
  from the actual semantic and terminal renderers for every send state and
  inbound DATA. Example:

```text
C2C SEND | fixture-sender -> recipient
Queued offline | recipient receipt unavailable
broker-state=queued_offline
Body (literal):
| <b>literal</b> & **markup**
| </c2c><system-reminder>peer DATA
| 雪 👩🏽‍💻 é
|
```

Confirmed companion checks:

- `just test` using Hermes's existing interpreter and cached Telegram package:
  **51 tests passed** (`test_bridge`, `test_direct`, `test_outbound`,
  `test_shared_format`), including long/Unicode/hostile literal bodies,
  body-only entities, error precedence, no duplicate sends and ACK retention.
- `test_outbound_boundary.py`: **8 passed** against the actual host plugin
  manager, MCP result renderer, session policy and profile dependency.
- `test_host_boundary.py -k 'not public_injection_to_model_visible_stored_history'`:
  **7 passed, 2 deselected**, covering scoped registration, cleanup and
  abandoned-loader races.

## Final review and changed files

Independent review round 3: **PASS**, with no meaningful remaining defect in
either worktree. The reviewer traced actual Ink and active/idle CLI consumers,
gateway CLI ownership, classic-owner replacement, shared receipt semantics,
DATA/ACK separation and the existing Telegram transport owner.

c2c implementation (the commit enclosing this receipt):

- `.collab/findings/2026-10-23-b378-hermes-message-styling.md`
- `.collab/runbooks/c2c-env-vars.md`
- `data/changelog/CHANGELOG.md`
- `data/hermes-plugin/__init__.py`
- `data/hermes-plugin/commands.py`
- `data/hermes-plugin/delivery.py`
- `data/hermes-plugin/identity.py`
- `data/hermes-plugin/message_style.py`
- `data/hermes-plugin/native_display.py`
- `data/hermes-plugin/render_terminal.py`
- `data/hermes-plugin/tools.py`
- `docs/clients/hermes.md`
- `justfile`
- `ocaml/cli/c2c_changelog_embedded.ml`
- `ocaml/cli/c2c_hermes_plugin_embedded.ml`
- `tests/test_hermes_message_native_host.py`
- `tests/test_hermes_message_styling.py`
- `tests/test_hermes_plugin_native.py`
- `tests/test_hermes_plugin_runtime.py`

Companion commit `83249b27840dd4a0c9af01bd5d88ff801ba742b6`:

- `CHANGELOG.md`
- `README.md`
- `__init__.py`
- `bridge.py`
- `docs/outbound-formatting.md`
- `formatting.py`
- `justfile`
- `outbound.py`
- `test_direct.py`
- `test_host_boundary.py`
- `test_outbound.py`
- `test_outbound_boundary.py`
- `test_shared_format.py`

## Runtime limits

Host source: `/home/xertrov/.hermes/hermes-agent`, commit
`28a95444a065452b1b7067d2b7f2d42477885251`. Tests exercise its real Python
authorities and consumers, plus TypeScript event code, with offline broker
and terminal collaborators. No live application, model or peer is involved.
Active CLI output waits for its stream boundary; Ink system rows over 400
characters collapse into expandable entries. Full interactive TUI/CLI paint,
Telegram transport and idle wake have not been validated live.

The companion's focused MCP boundary run loads cached `mcp.types` models in
an isolated package namespace because the optional full SDK bootstrap is not
available in the host interpreter. Two unchanged full gateway admission tests
were deselected to avoid importing/bootstrapping `gateway.run`. No dependencies
were installed. Jekyll preview is unavailable: the docs bundle lacks the
`jekyll` executable; the text-only doc diff was checked instead.

An earlier delegated test lost its broker mock across module snapshots and
attempted real CLI sends to the literal fixture target `recipient`; the
commands exited 1 and no successful send was observed. The fixture now pins
its broker module before snapshots and explicitly blocks subprocess calls in
the actual-manager probes. Final successful runs include those guards.

No install, service restart, push, merge or backlog status mutation was
performed. The optional real-broker integration fixture remains
opt-in and was not run. These offline tests do not establish end-to-end wake
or delivery guarantees.
