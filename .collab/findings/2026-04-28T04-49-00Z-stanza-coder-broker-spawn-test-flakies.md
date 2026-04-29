**Author:** stanza-coder
**Date:** 2026-04-28T04:49:00Z

# Broker-spawn / pre-existing test flakies — diagnosis

## Summary

- HEAD: `817dbf33` (master, clean working tree apart from `.collab/research/*` notes; tests run on installed binary `~/.local/bin/c2c` v0.8.0 fce11a0b).
- Failing tests on master HEAD: **6** across 4 test executables.
  - `c2c_mcp` :: broker 179 (`set_dnd on:"true"`)
  - `c2c_mcp` :: broker 197 (`enqueue self-heals dead target via resolver hooks`)
  - `c2c_stats` :: sitrep_append 0 (`sitrep path uses UTC hour`)
  - `c2c_stats` :: sitrep_append 1 (`creates stub and replaces block` — same root cause as 0)
  - `c2c_start` :: launch_args 17 (`build_env_does_not_seed_codex_thread_id` — last assertion only)
  - `c2c_onboarding` :: full_pipeline 0 (`local pipeline ... whoami`)
- Categories: **3 flaky-env**, **2 broken-test**, **1 broken-code (or undecided spec)**.
- None of the failures reach a c2c-mcp-server **subprocess** — the "broker-spawn" framing is a misnomer. All in-process broker tests use `Broker.create ~root:tmp` and never spawn the binary. Only `c2c_onboarding`'s `full_pipeline` shells out to `c2c` via `Sys.command`, and even then it does not spawn an MCP server.
- Recommended fix priority:
  1. `c2c_stats` sitrep tests — flip test or code to one timezone discipline (one-line, blocks coord-PASS today on every UTC-≠-localtime host).
  2. `launch_args 17` — strip `C2C_MCP_FORCE_CAPABILITIES` from inherited env in `build_env` for non-claude clients (also a real escape-hatch correctness bug).
  3. `c2c_onboarding full_pipeline` — pass `--session-id` (or set `C2C_MCP_SESSION_ID`) to the `register` + `whoami` invocations.
  4. `broker 179 set_dnd` — decide spec (accept stringly-typed `"true"`/`"false"` from MCP clients?) then fix code or test.
  5. `broker 197 self-heals via resolver` — needs deeper investigation; possible real regression.

## Per-failure breakdown

### test_c2c_stats.ml :: sitrep_append 0 — `sitrep path uses UTC hour`

- **Symptom**: `Expected "/repo/.sitreps/2026/04/25/13.md", Received "/repo/.sitreps/2026/04/25/23.md"` (host TZ=AEST = UTC+10).
- **Root cause**: `c2c_stats.sitrep_path` uses `Unix.localtime` (`ocaml/cli/c2c_stats.ml:288`); the test asserts UTC. The same module-level comment explicitly says sitrep paths are per-local-hour ("`10:00 UTC+10` lives at `.../10.md`"), so the **test contradicts the documented intent**.
- **Trace**: `ocaml/cli/c2c_stats.ml:285-296` (localtime, `local_tz_label`); `ocaml/cli/test_c2c_stats.ml:51-54` (UTC fixture).
- **Category**: broken-test (assuming the localtime comment is canonical) — but the test name "uses UTC hour" suggests the *intent* may have been to standardise on UTC, in which case the **code** needs the change. Needs a one-line spec call from coord.
- **Suggested fix**: pick one. Either change the test to AEST/`Expected "23.md"` and use `Unix.gmtime`-derived expected paths, or change `sitrep_path`/`sitrep_stub` to `Unix.gmtime` and update the comment. UTC is the friendlier choice for a multi-timezone swarm.

### test_c2c_stats.ml :: sitrep_append 1 — `creates stub and replaces block`

- **Symptom**: `stub header present` fails because the generated file's header is `# Sitrep — 2026-04-25 23:00 AEST`, not `13:00 UTC`.
- **Root cause**: same as 0 — `sitrep_stub` uses `Unix.localtime` + `local_tz_label` (`c2c_stats.ml:293-296`).
- **Trace**: `ocaml/cli/test_c2c_stats.ml:69`; `ocaml/cli/c2c_stats.ml:293-296`.
- **Category**: same as 0 — flaky-env / broken-test.
- **Suggested fix**: tied to fix for 0; fix both together.

### test_c2c_start.ml :: launch_args 17 — `build_env_does_not_seed_codex_thread_id` (3rd assertion)

- **Symptom**: `does not export force capabilities for non-claude` — Expected `false`, Received `true`. First two assertions in the same test pass.
- **Root cause**: `C2c_start.build_env` only **adds** `C2C_MCP_FORCE_CAPABILITIES=claude_channel` when `client = Some "claude"` (`ocaml/c2c_start.ml:2111-2119`), but it does **not strip** that key from the inherited environment for other clients. The test runner (this swarm session) has `C2C_MCP_FORCE_CAPABILITIES=claude_channel` in its ambient environment (verified: `env | grep FORCE_CAPABILITIES`). The `additions` list is the only source of `override_keys` (`c2c_start.ml:2138-2140`), so when the additions don't include the key, the inherited copy passes through untouched.
- **Trace**: `ocaml/c2c_start.ml:2111-2165` (build_env conditional add + filter), `ocaml/test/test_c2c_start.ml:271-282` (test); also `ocaml/server/c2c_mcp_server_inner.ml:70` (consumer).
- **Category**: **broken-code AND broken-test**. The test is right to assert this, and the fix is real: a managed Codex/OpenCode/Kimi/Crush session right now silently inherits `C2C_MCP_FORCE_CAPABILITIES=claude_channel` from any parent that has it, which forces channel capabilities on a non-claude client. This is a small but live capability-leak bug.
- **Suggested fix**: in `build_env`, always include `"C2C_MCP_FORCE_CAPABILITIES"` in the strip-from-inherited list (e.g. add to `legacy_native_session_keys` analogue, or drop it from `filtered` unconditionally), and only re-add when `client = Some "claude"`.

### test_c2c_mcp.ml :: broker 179 — `tools/call set_dnd on:"true" string enables dnd`

- **Symptom**: MCP `tools/call` for `set_dnd` with `arguments.on = "true"` (JSON string) returns `{ok:true, dnd:false}`. Test expects `dnd:true`.
- **Root cause**: handler at `ocaml/c2c_mcp.ml:4708-4716` only matches `\`Bool b`; any other JSON variant (including `\`String "true"`) falls through to `false`, then `set_dnd` is called with `dnd:false` so the broker returns `dnd:false` truthfully. The schema declares `set_dnd.on` as `boolean` (the audit's "schema types are correct" test verifies that, broker 121-ish), so a strictly-typed client cannot send a string — but the regression test's premise is that some clients (Kimi, Crush wrapper paths) do coerce booleans to strings on the wire.
- **Trace**: `ocaml/c2c_mcp.ml:4708-4732`; `ocaml/test/test_c2c_mcp.ml:6079-6118`. Companion test `set_dnd on:"false"` (broker 180) **passes** — because it independently primes `dnd:true` via `Broker.set_dnd` first, then sends `"false"`, the fallthrough-to-`false` branch coincidentally produces the expected outcome (latent bug the test doesn't catch).
- **Category**: **broken-code** (under one spec reading) or **broken-test** (under the strict "schema is `bool`, clients must comply" reading). Audit `2026-04-28T04-22-45Z-stanza-coder-ocaml-test-coverage-audit.md` already flagged this as a coverage-relevant DND parsing regression.
- **Suggested fix**: extend the `\`Bool` match in `c2c_mcp.ml:4710-4716` to also accept `\`String "true"|"True"|"1"` (true) and `\`String "false"|"False"|"0"` (false). Mirror change in `set_compact` and any similar boolean-arg handler — coord-PASS audit suggested this in passing.

### test_c2c_mcp.ml :: broker 197 — `enqueue self-heals dead target via resolver hooks`

- **Symptom**: `enqueue_message` raises `invalid_arg "recipient is not alive: galaxy-eh"` (`ocaml/test/test_c2c_mcp.ml:6745-6747`). Pre-heal assertion at line 6740 *passes* (registration is correctly Dead before heal). Companion test broker 196 (`resolve alias self-heals dead target via inject`) passes — so the proc-hook injection itself works; failure is on the enqueue path.
- **Root cause hypothesis**: undetermined without instrumentation, but the divergence between 196 (passes) and 197 (fails) is the call site: 196 exercises `resolve_alias` directly; 197 calls `enqueue_message`, which goes through a different code path that may use cached registrations or a separate alive-check that doesn't honour the proc hooks. There is also a potential collision: 197 registers `s-sender-eh` and `s-target-eh` to the **same** live PID after heal, which could violate a uniqueness invariant in newer broker code.
- **Trace**: `ocaml/c2c_mcp.ml:1002-1035` (resolve-with-hooks), `ocaml/c2c_mcp.ml:992-1059` (resolve_alias), and the enqueue path (search `enqueue_message` in `c2c_mcp.ml`). Test at `ocaml/test/test_c2c_mcp.ml:6722-6757`.
- **Category**: **broken-code** (likely) — a real regression in the heal-on-enqueue path. Not env-flaky; reproduces deterministically.
- **Suggested fix**: needs investigation. Add `Printf.eprintf` instrumentation in `enqueue_message`'s alive check + heal trigger to see whether the proc hooks are being consulted at all. If `enqueue_message` calls `registration_is_alive` directly without going through the resolver, that's the bug.

### test_c2c_onboarding.ml :: full_pipeline 0 — `local pipeline ... whoami`

- **Symptom**: `register` exits 1, `whoami` exits 1, then `whoami mentions alias` fails because there's no output.
- **Root cause**: the test's `run_c2c` helper passes `C2C_MCP_SESSION_ID=` (empty string) explicitly via `env -i`-style prefix (`ocaml/cli/test_c2c_onboarding.ml:50`). The OCaml `c2c register` and `c2c whoami` paths require either a non-empty `C2C_MCP_SESSION_ID` or an explicit `--session-id` flag; with neither, both subcommands print `error: no session ID...` and exit 1 (verified by manually invoking `c2c whoami` with the same env setup). The test never sets a session ID for these two steps. (Earlier steps `init`, `relay identity`, `relay setup`, `list` don't need one and pass.)
- **Trace**: `ocaml/cli/test_c2c_onboarding.ml:42-64` (helper), `:200-205` (test body); the production handler is in `ocaml/cli/` (search `no session ID. Set C2C_MCP_SESSION_ID`).
- **Category**: **broken-test**. This is also the ONLY test in the failure set that spawns the c2c binary as a subprocess — it's the closest thing to "broker-spawn" that's actually failing, and it's a missing `--session-id` flag, not a binary-path issue.
- **Suggested fix**: change line 201 to `["register"; "--alias"; alias; "--session-id"; "fp-test-" ^ alias]` and pass the same `--session-id` (or set `C2C_MCP_SESSION_ID` via the `env` argument) for the `whoami` invocation on line 203.

## Cross-cutting observations

- **No actual subprocess broker spawning is happening in the failing tests.** "broker-spawn" turned out to be a red herring: the in-process broker tests (`test_c2c_mcp.ml`) use `Broker.create ~root:tmp` and never fork the server binary. The single subprocess-spawning test (`full_pipeline`) shells out to the `c2c` CLI binary, but does not start an MCP server. So the failures are NOT about a stale `c2c-mcp-server` on disk, an `~/.local/bin` ancestry mismatch, or a missing `--xml-input-fd` codex.
- **Two distinct ambient-env leaks**: `C2C_MCP_FORCE_CAPABILITIES` (causes launch_args 17) and the swarm session's local TZ being non-UTC (causes both sitrep_append failures). Neither would reproduce on a CI box with a clean env at TZ=UTC, which explains why these have been chronic "every reviewer sees them, nobody owns them" failures: they're host-dependent.
- **Test isolation is fine for `dune test`**: every failing case writes to `Filename.get_temp_dir_name ()` (per-PID + random-bits suffix) and cleans up. Running `dune test` from this working tree did not mutate the swarm broker root or any shared state. Safe to re-run as desired.
- **No docker-mode conditionals affect this set**; all failures reproduce on the bare host.

## Recommendation

**Slice plan (one worktree per bullet, all small):**

1. **`fix(stats): canonicalise sitrep timestamps`** — pick UTC vs local, update both `c2c_stats.sitrep_path`/`sitrep_stub` and the test fixture to agree, drop the misleading comment if flipping to UTC. Closes 2 failures.
2. **`fix(start): strip C2C_MCP_FORCE_CAPABILITIES from inherited env for non-claude managed sessions`** — production capability-leak fix that also greens launch_args 17. Add the key to the always-strip list in `build_env`. Closes 1 failure + a real bug.
3. **`fix(test): full_pipeline passes session-id to register/whoami`** — test-only fix; production code is correct (rejecting empty session ID is intended). Closes 1 failure.
4. **`fix(mcp): set_dnd accepts stringly-typed "true"/"false"`** — small handler change in `c2c_mcp.ml:4710-4716`, plus mirror for `set_compact` if applicable. Closes 1 failure. Coord may want to confirm spec.
5. **`investigate(mcp): broker 197 self-heals via enqueue path`** — instrument `enqueue_message` to confirm whether it bypasses the proc-hook resolver. May be a real regression; spike before slicing.

**Skip-on-host gating?** No. None of these need `[@@@warning "-XX"]` or `if Sys.os_type` guards — the right fix in every case is either a one-line code change or a one-line test change. Skipping would just push the problem.

**Coordinator-PASS impact:** until items 1–3 land, peer reviewers should be told "ignore by name: `sitrep_append.0`, `sitrep_append.1`, `launch_args.17`, `full_pipeline.0`, `broker.179`, `broker.197` — these are pre-existing on master HEAD `817dbf33`, tracked in this finding". After items 1–3 land, only `broker.179` (spec-call) and `broker.197` (real bug spike) remain, and the noise floor for peer-PASS goes from "must filter 6 to 0 my-fault" to "must filter 2". The two-line allow-list in the peer-PASS DM template is a reasonable interim; items 1–3 are all under 30 minutes each so the proper fix is also cheap.
