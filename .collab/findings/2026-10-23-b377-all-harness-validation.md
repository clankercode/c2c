# B377: all-harness host namespace validation

Date: 2026-10-23. Implementation base: integrated master
`6cf6308f5afc93c8e3acfea08c123a8b45414f3b` (the B377 reopen), following
`29506fc28b4fb368b8699f32e9d1b6771c0f979e`.

## Source audit and compatibility decision

- `ocaml/cli/c2c_setup.ml`, `known_clients`, `install_subcommand_clients`, and
  `detect_client_prefixes` enumerate the install/detection clients, including
  Cursor and legacy Crush. They deliberately omit Pi from install targets.
- `ocaml/cli/c2c_root_cmd.ml`, `print_enriched_landing`, adds Pi as a synthetic
  supported-client entry because it uses the independent `pi-c2c` extension.
- `ocaml/c2c_start.ml`, `default_alias_prefix`, maps `codex-headless` to
  `codex`. Host binding now uses that same canonical namespace and persists it.
- The test matrix independently enumerates `claude`, `codex`,
  `codex-headless` -> `codex`, `opencode`, `kimi`, `pi`, legacy `crush`,
  `grok`, `agy`, `hermes`, `cursor`, and `muse`: twelve inputs, eleven
  canonical namespaces. `pty` and `tmux` are generic transports, not harness
  identities; they remain invalid client types.
- Pi source was read at `/home/xertrov/src/pi-c2c`, commit
  `559e2d42242f22094c312b507a7e7518a338a64a`: `src/identity.ts` derives
  `pi-<hash>` aliases; `src/c2c-cli.ts`, `C2cCli.register`, invokes
  `c2c register --alias ALIAS --session-id SID --json`. Both ordinary and
  sessions-broker startup use it. `ocaml/cli/c2c_register_cmd.ml` marks an
  explicit `--alias` as `from_auto_gen=false`.
- Consequently, globally adding Pi to `C2c_blocklist.banned_aliases` would
  break fresh Pi plugin registrations. The global blocklist remains
  behaviorally unchanged. Host binding reserves the names of all its
  supported client types locally, including Pi. This preserves the plugin's
  existing explicit broker registration and the broker's automatic path
  without adding a new privileged registration exception.

## Contract and regression coverage

The suite covers all twelve client inputs through direct host binding and
the fresh CLI: own-prefix success, returned and persisted canonical client
type, omitted-type rebind, case folding, collisions, foreign-prefix refusal,
and actionable JSON errors. Direct tests exercise all 120 foreign canonical
prefix combinations and immutable client-type changes. Bare reserved names,
system aliases, empty/unknown types, ordinary untyped aliases, and the
Codex/headless equivalent namespace are covered.

The generic registry row remains `client_type=host`,
`registered_by=host-mailbox:<generation>`, with automatic delivery disabled.
The asserted harness remains binding metadata. Existing generation, owner
PID/start-time, registry conflict, crash recovery, and DATA/approval fences
remain in use. Pi's explicit broker path, automatic broker path, and exact
plugin CLI argv are tested alongside independently fenced Pi host bindings;
host attempts to adopt existing plugin aliases are refused.

## Review/fix loop

Round one static review found a compatibility defect in the initial patch:
newly reserving Pi during stored-state decoding would strand previously
valid untyped `pi-*` host bindings. The fix preserves the prior stored-state
contract for all Pi alias shapes, including bare Pi and Pi prefixes with a
different then-valid client assertion. Fresh bindings enforce the new policy.
Only existing untyped `pi-*` bindings may explicitly upgrade to `pi`; the
upgrade checks the exact old host registration, preserves alias, session,
and mail, and rotates generation through the existing transition journal.
Other client-type changes remain refused. Four additional tests cover old
lifecycle operations, the other old alias shapes, upgrade ownership, and
interrupted-upgrade recovery. Round two independent static review returned
**PASS**, with no actionable findings; it confirmed the original P2 was
resolved. Parent's subsequent independent integrated review remains separate.

## Isolated x-p35 gate

All compilation and test execution occurs on x-p35, in:

```text
/home/xertrov/src/c2c-hermes-final-29506fc2/.worktrees/b377-all-harness-hwwb-6cf6308f
```

The worktree starts at the exact integrated base above. Only the owned source
and documentation paths are overlaid for validation. No parent source files
or old P9 roots are modified. The parent's checkout remains clean.

Each build uses a unique wrapper gate, no stale-holder reaper, and `-j1`:

```bash
C2C_DUNE_GLOBAL_LOCK_DIR=/tmp/c2c-b377-hwwb-gate C2C_DUNE_REAPER=0 DUNE_THROTTLE_BYPASS=1 scripts/dune-build-locked.sh build -j1 ./ocaml/cli/c2c.exe ./ocaml/cli/test_c2c_host_mailbox.exe
timeout 180 _build/default/ocaml/cli/test_c2c_host_mailbox.exe
C2C_DUNE_GLOBAL_LOCK_DIR=/tmp/c2c-b377-hwwb-gate C2C_DUNE_REAPER=0 DUNE_THROTTLE_BYPASS=1 scripts/dune-build-locked.sh build -j1 ./ocaml/test/test_c2c_mcp.exe
timeout 120 _build/default/ocaml/test/test_c2c_mcp.exe test broker 146,174-175,473-477
```

After the compatibility fix, all three targets were explicitly rebuilt
together before rerunning both test commands:

```bash
C2C_DUNE_GLOBAL_LOCK_DIR=/tmp/c2c-b377-hwwb-gate C2C_DUNE_REAPER=0 DUNE_THROTTLE_BYPASS=1 scripts/dune-build-locked.sh build -j1 ./ocaml/cli/c2c.exe ./ocaml/cli/test_c2c_host_mailbox.exe ./ocaml/test/test_c2c_mcp.exe
```

The selected broker cases cover same-alias refresh, startup metadata refresh,
reserved names, ordinary aliases, automatic client prefixes, and explicit
Codex refusal. Direct executable invocation executes the cases afresh;
compilation precedes execution, and exit statuses are captured independently
of log-tail commands.

Initial validation: host suite 24/24; selected broker cases 8/8.
Final validation after the compatibility fix: build exit 0; host suite
**28/28**, run ID `TSMB0ZLY`, 6.047 seconds; selected broker cases **8/8**,
0.031 seconds. Both test processes exited 0. Local and remote
`git diff --check` passed. The four source/documentation SHA-256 hashes
match between the implementation checkout and the remote gate:

```text
47b7197126ef937808149f2986d74600f1ce3a1fadc694b3ff872bde931ec56e  ocaml/c2c_host_mailbox.ml
9785e65615ace301c5ad05809beb862a92879fe89441cf8d7513e39280b253fb  ocaml/c2c_blocklist.ml
200be08c33a5b6799f5c413075263d4fdf42fdd1e8d00e393d2eb6b799443060  ocaml/cli/test_c2c_host_mailbox.ml
16caf166b1eb179787efd9a7e1a559f7e4406fce98da437219aae82bc9a66d25  docs/reference/host-mailbox.md
```

Fresh remote executable SHA-256 hashes:

```text
dde1b9bd584b1ab740915b5b9c3551054112e8ff200c61d15588b971503a11db  _build/default/ocaml/cli/c2c.exe
8b0542602c35a01ba6a3a06e7722afda7886e6b059785996aa04806fbd7e3c2a  _build/default/ocaml/cli/test_c2c_host_mailbox.exe
302eb60eb96340904628bcfadef20a82b13319274126acb80634898055bee07c  _build/default/ocaml/test/test_c2c_mcp.exe
```

Remote logs: `/tmp/c2c-b377-hwwb-build.log`,
`/tmp/c2c-b377-hwwb-host-tests.log`, `/tmp/c2c-b377-hwwb-broker-build.log`,
`/tmp/c2c-b377-hwwb-broker-tests.log`. Final logs:
`/tmp/c2c-b377-hwwb-build-final.log`,
`/tmp/c2c-b377-hwwb-host-tests-final.log`, and
`/tmp/c2c-b377-hwwb-broker-tests-final.log`.
The initial build reports pre-existing
warnings in unrelated modules, including `c2c_relay_systemd.ml`; no unrelated
source changes are made.

## Scope and remaining validation

No workstation builds/tests, user-profile installation, service changes,
external messages, pushes, backlog edits, P9 changes, changelog changes, or
shared embed regeneration are performed. Pi plugin compatibility is verified
by source trace and its real CLI/broker invocation against isolated files;
no live Pi TUI is launched. Parent owns the final integrated full check/test
and independent review after receiving the scoped commit.
