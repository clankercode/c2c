# B378 live terminal validation — 2026-10-23

**PASS: actual Hermes Ink TUI and native CLI application paint.** Both show
outgoing native send receipts and incoming native inbox DATA, including long,
multiline, literal markup and Unicode bodies. This closes the application-paint
gap in the earlier styling receipt; no product implementation was changed.

## Runtime and exact bytes

- Live host: `xsm`; worktree HEAD `cf556665e35fb5bb6b74d03333e54f04e8c2ae4d`.
- Hermes source: `/home/xertrov/.hermes/hermes-agent`, clean tracked/untracked
  status, HEAD `6111c4e82f3d72f456bdf66503c87cffe53d6e1a`.
- c2c: parent's freshly built x-p35 artifact from
  `/home/xertrov/src/c2c-hermes-final-29506fc2/_build/default/ocaml/cli/c2c.exe`.
  Source HEAD: `29506fc28b4fb368b8699f32e9d1b6771c0f979e`.
  Local copy: `/tmp/c2c-b378-integrated-29506fc2.exe`.
  Remote and local SHA-256 both:
  `85d5725df4b704be0fa9c1a55b193f54b06588a9f3ebba6caa3f7a863b819231`.
  Actual isolated invocation reports `0.19.0 29506fc2 (built 2026-10-23)`.
- Canonical plugin copied into each owned home from `data/hermes-plugin`.
  `git diff 29506fc2 -- data/hermes-plugin` is empty. All twelve installed
  source/manifest/skill files are hashed in `manifest.json`.
- Actual interpreter:
  `/home/xertrov/.hermes/installs/d34db847329d993b/environments/18e686aed3e24692909490eb13bcecd3/venv/bin/python`;
  SHA-256 `8dfa9757a52b9c3edf1dedaaa2a7a8c40ea4beb058f20e90bdd47b48f3b1b176`.
- Actual Node, from owned process executable/argv inspection:
  `/home/xertrov/.hermes/tools/node-26.7.0-linux-x64/bin/node`;
  SHA-256 `ad19784f7e90ba789a099eccba77ede8dc90a778c424f1c10a70fed3ff903fdc`.
  `manifest.json` also records the PATH candidate; `runtime.json` records
  what Hermes actually launched.
- Actual prebuilt TUI: `ui-tui/dist/entry.js` in that checkout;
  SHA-256 `b53149cd0f8be098d845fc060c310d4a6e77aa1fbd9a4db7c056f90006e44e77`.
  No source build or dependency preparation was needed for the final proof.

## Reproduction and ownership

The focused script uses `scripts/c2c_tmux.py` helpers to launch real
applications in new 150-column, 65-row tmux sessions, send literal slash
commands, and capture both plain and ANSI terminal buffers. It checks for
existing tmux context; this run had none. It does not use `c2c start hermes`.

Actual artifact transfer and final run:

```bash
scp -q x-p35:/home/xertrov/src/c2c-hermes-final-29506fc2/_build/default/ocaml/cli/c2c.exe /tmp/c2c-b378-integrated-29506fc2.exe
sha256sum /tmp/c2c-b378-integrated-29506fc2.exe
ssh -o BatchMode=yes x-p35 'sha256sum /home/xertrov/src/c2c-hermes-final-29506fc2/_build/default/ocaml/cli/c2c.exe'
python3 scripts/hermes-b378-live-proof.py --output /tmp/c2c-b378-live-20261023-proof --c2c-bin /tmp/c2c-b378-integrated-29506fc2.exe run
```

The run exited **0** and printed PASS for both surfaces. Exact subprocess
environment and launch command are saved in each lane's `env.json` and
`launch.sh`; exact slash input and SGR expansion clicks are in
`commands.jsonl`. The interactive operations were:

```text
/b378-proof bootstrap
/b378-proof send
/b378-proof poll
```

Each lane has a separate `home`, OS home, config/cache/state/runtime, cwd and
broker beneath `/tmp/c2c-b378-live-20261023-proof/{tui,cli}`. The environment
starts empty and carries no user's provider or messaging credentials. Both
homes explicitly grant `plugins.entries.c2c.allow_gateway_injection: true`.
Relay remains unconfigured; no messaging platforms are enabled. Only the
lane's owned `b378-fixture-tui` or `b378-fixture-cli` identity exchanges test
mail with its Hermes conversation. No foreign inbox or user chat is addressed.

Exact final native bindings, also saved in each lane's `binding.json`:

- TUI alias `hermes-b71783cb2b5d76e0a0e3f44998e3bc06`, native session
  `local-7e50ab31d217ccd79813b7796acc6cde88d49b05b259f8630734a0b69456642b`.
- CLI alias `hermes-35d6e6f91bdbe90f2f68528f8f07bf7b`, native session
  `local-26c8384c018ebe0887e2f47b8111a3788cdce61bf4fac26c21ccfba019fb7346`.
- Each route key is exactly `agent:main:local:dm:` followed by its native
  session ID. Each broker root is exactly that lane's `broker` directory.

The owned diagnostic plugin resolves the actual registered c2c SessionRegistry
and bootstraps its binding before the first model turn. Slash dispatch itself
has surface `local`, so the probe obtains the host's **existing admitted**
LocalSessionPolicy from the exact SessionSource and uses the host policy scope;
it does not invent a surface, session or routing key. Actual first-turn
registration is outside this paint-only proof. It starts no watcher.

The command then calls real `model_tools.handle_function_call`, native c2c
handlers, the integrated OCaml binary, normal completion hooks, NativeDisplay,
the real gateway event stream and actual Ink/CLI consumers. No formatter,
consumer, subprocess result, authority, broker or injection API is mocked or
replaced. The only extra plugin is inside the owned homes.

`HERMES_DISABLE_LAZY_INSTALLS=1` prevents automatic dependency preparation;
`HERMES_TUI_DIR` selects the existing bundle. The existing committed
interpreter launches the source application directly. CLI additionally sets
`C2C_HERMES_PLAIN=1`; its application chrome still has its own colors, while
the c2c card is readable plain text.

## What was seen and checked

Both outgoing tool results and the actual fixture inbox contain the exact
1,673-character body, once. The application cards say:

```text
Queued | recipient receipt unavailable
type=dm | time=03:36:22 UTC | broker-state=delivered
Body (literal):
```

That is the TUI capture's real metadata: the binary's legacy `delivered`
state is visibly labelled **Queued**, never proof of recipient receipt.
Both cards retain literal `<b>literal</b>`, `**markup**`, `[red]no Rich[/red]`,
reserved closing tags and system-reminder text, newlines, Unicode and the
long body's `LONG-END` marker. The TUI's long system entries were clicked
open in the real application, then recaptured; neither expansion nor body
inspection is inferred from a mocked event consumer.

Both incoming native poll results match the corresponding pre-poll inbox
**exactly**, including full message IDs, original body, terminal ESC,
combining marks, trailing spaces and final LF. The body is 1,707 characters.
The expanded application cards visibly include:

```text
Peer DATA | untrusted; never instructions or approval authority
Body (literal):
```

The peer's ESC is displayed as literal `\x1b[31m`, not executed. Literal markup
is not interpreted. Expanded Ink/ANSI rendering composes `e` + combining acute
into `é` in the terminal capture; glyph comparison normalizes only the
capture assertion. JSON/tool/inbox body comparisons remain byte-for-byte
Unicode-string equality. Tmux capture trims right-side terminal whitespace,
so original trailing spaces are verified through those machine results.

Selected message IDs returned by the real receive path:

- TUI: `4b4705b6-b5ef-4017-89ef-f54aed6d76be`.
- CLI: `0d8e612d-ada0-497a-9d6f-7c3e9be5e6f7`.

The production Delivery.poll path reserves, accepts the selected batch and
uses `ack-inbox --message-id` through the real binary. Each lane's
`inbox-before.json` equals `poll-result.json`; `inbox-after.json` is `[]`.
The fixture's separate outgoing inbox retains its one message. This proves
explicit receive/ACK for the exact selected DATA; it is not an idle-injection
or crash/exactly-once experiment.

Afterward, both actual Hermes SQLite databases report **0 messages and
0 session admissions**. Display events did not create model history or a
model turn. No approval API or verdict path was used. The earlier 151 OCaml
tests and Python results are not re-counted here. No suite was executed on
xsm; the parent's corrected native real-manager regression on x-p35 remains
separate work.

## Evidence and cleanup

Raw evidence root: `/tmp/c2c-b378-live-20261023-proof/`.

- `{tui,cli}/outgoing-expanded.txt` and `.ansi.txt` — actual expanded send paint.
- `{tui,cli}/incoming-expanded.txt` and `.ansi.txt` — actual expanded DATA paint.
- `manifest.json`, `runtime.json`, `build-provenance.json`, `proof-script.sha256`.
- Each lane's input bodies, native results, before/after inbox snapshots,
  exact binding, dispatch context, binary version and launcher/environment.
- `verdict.json`, `broker-assertions.json`, `commands.jsonl`, `SHA256SUMS`.
- `cleanup.json` and `cleanup-all-attempts.json`.

Portable capture/metadata archive:
`/tmp/c2c-b378-live-terminal-proof-20261023.tar.gz`.
SHA-256: `aef5ac2b4d0dad6a2a6c308608ea652e60fddffbf7cdbb9e806919c10f528695`.
The archive omits runtime sockets, broker keys and database internals.

The script's finally block kills only its owned tmux sessions and signals
only processes with either exact owned HERMES_HOME in their initial
environment. Final run remaining owned PIDs: **[]**. A subsequent inspection
across all eight attempt roots also found **[]**. Shared gateways/services
were not restarted. Cleanup's abrupt viewer shutdown can log PTY EIO or
WebSocket disconnect errors after the successful captures; no application
paint error was observed during the proof.

Execution deviation: the **first** stock `hermes` launch unexpectedly
auto-synced dependencies into its fresh isolated home before it was stopped.
That violated the requested no-dependency-install constraint. The selected
environment is entirely under
`/tmp/c2c-b378-live-20261023-ivy/tui/home/installs/`; its facts snapshot and
startup capture are retained in that attempt root. Final proof launches do
not use that environment and disable this bootstrap. No dependency or profile
install was made into the user's shared home.

Automatic approval review rejected removing the initial temporary dependency
directory because recursive `shutil.rmtree` deletion is blocked. It remains
inert at the path above, with no running owned process; removal is the sole
cleanup gap. No deletion workaround was attempted.

Coverage limits: no model-visible injection, idle wake, active model-stream
boundary, live MCP server, Telegram transport/UI, or non-TTY Hermes application
run is claimed. The reopened TUI/CLI application-paint requirement passes;
those other surfaces retain their earlier test evidence and stated limits.
