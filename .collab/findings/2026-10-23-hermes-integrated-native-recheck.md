# Integrated Hermes native fixture recheck

The previous B372–B375 handoff left the real-manager rerun against the corrected
native ACK binary pending. That integration gate passed on x-p35 on 2026-10-23.
This supplements the previous deterministic regressions and independent source
review; it does not turn the fixture into a live model-wake proof.

## Exact source and gate

- Source: `29506fc28b4fb368b8699f32e9d1b6771c0f979e`.
- Tree: `0a48951536fa4359cddfc6e8ae99f45b266557e2`.
- Clean isolated clone: `x-p35:/home/xertrov/src/c2c-hermes-final-29506fc2`.
- Fresh built CLI SHA-256: `85d5725df4b704be0fa9c1a55b193f54b06588a9f3ebba6caa3f7a863b819231`.
- `env DUNEJOBS=2 DUNE_THROTTLE_JOBS=2 just check`: exit 0, including the
  read-only Hermes distribution check, relay supervisor tests, generated-source
  checks, native build, broker event catalog and 40 documentation command checks.
- `PYTHONDONTWRITEBYTECODE=1`, Python 3.14.4. No installed executable, user
  profile, live agent or service was changed.

Fixture invocation (inside that clone):

```sh
env PYTHONDONTWRITEBYTECODE=1 \
  PYTHONPATH=/home/xertrov/src/c2c-hermes-runtime-gate/deps \
  HERMES_SOURCE_ROOT=/home/xertrov/src/c2c-hermes-runtime-gate/hermes-source \
  C2C_HERMES_SOURCE=/home/xertrov/src/c2c-hermes-final-29506fc2/data/hermes-plugin \
  C2C_HERMES_FIXTURE_ROOT=/home/xertrov/src/c2c-hermes-final-29506fc2/.native-proof \
  C2C_BIN=/home/xertrov/src/c2c-hermes-final-29506fc2/_build/default/ocaml/cli/c2c.exe \
  python3 tests/test_hermes_plugin_native.py
```

Result: **one test passed**, exit 0, against actual Hermes PluginManager/context
and routing functions plus the freshly built integrated native broker/ACK path.
The fixture checks distinct A/B identities, scrubbed inherited identity/broker
state, first-turn staged DATA followed by exact request-context acceptance,
selected ACK, idle/busy target routing, ended/unknown/no-consent retention,
correct slash-send identity and finalization. Controlled host/model-launch
collaborators remain explicit. Temporary profiles/brokers were cleaned by the
fixture's owned context.

## Evidence and limits

Full check/native logs and identities are preserved under
`/home/xertrov/.cache/c2c/hermes-final-20261023/`, with prefix
`c2c-hermes-final-29506fc2-`. This includes hashes of all ten runtime Python
modules and the four Hermes authority/routing source files used by the fixture.
The source identity was checked clean after execution.

The fixture prints `model_wake_proven:false`; it proves enqueue and
request-context acceptance. It does not start a live Hermes app or model.
B371's separately recorded five real fallback wakes remain fallback evidence.
B378's separate actual CLI/TUI proof is needed for interactive rendering.
The explicit per-target consent and conditional wake description remain intact.
