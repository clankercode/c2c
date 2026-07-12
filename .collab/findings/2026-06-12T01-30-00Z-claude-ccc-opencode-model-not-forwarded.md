# ccc does not forward provider/model to opencode → opencode falls back to a broken default

**UTC**: 2026-06-12T01:30:00Z
**Author**: claude (Max's interactive session)
**Severity**: medium (blocks all `ccc @<opencode-alias>` agents; wasted ~2h of agent time before diagnosis)
**Status**: RESOLVED 2026-06-12 at **ccc 0.3.4** (commit `769d5573` "Prefix
opencode model with provider for provider/model format"). Verified: `@glm51` →
`build · glm-5.1` + correct output. Per-alias opencode model forwarding now
works end-to-end. History below.

**FOLLOW-UP (2026-06-12, second bug, also RESOLVED):** after 0.3.4, `@mm`/`@mm3`
still failed with `UnknownError: Unexpected server error` (err_82eb24fc /
err_8d27caa5). Root cause = **wrong provider id in `~/.config/ccc/config.toml`**:
`[aliases.mm]` and `[aliases.mm3]` had `provider = "minimax"`, but opencode's
real provider id is `minimax-coding-plan` (confirmed via opencode auth.json).
ccc 0.3.4 correctly emits `--model <provider>/<model>` = `minimax/MiniMax-M3`,
which opencode cannot resolve → server error. `@mm27` already had the correct
`minimax-coding-plan` provider so it worked. `@glm51` works because
`zai-coding-plan` is correct. **Fix: edited the config, `minimax` →
`minimax-coding-plan` for mm + mm3** (model `MiniMax-M3` is valid under that
provider). Verified: `@mm3` → `build · MiniMax-M3` + `MM3_FIXED_OK`. This was a
config-data bug, NOT a ccc code bug. Optional ccc enhancement: warn at launch
when an alias's `provider` is not in opencode's known provider set, to catch
this class of misconfig early. All four bake-off models now functional:
mm3, mm27, glm51, mimo25p.

ccc upgraded 0.2.0 → 0.3.3 (commit
`1bc55b9d` "Fix opencode --model flag not being passed") via `cargo install
--path ~/src/ccc/rust`. 0.3.3 now PASSES `--model`, but a SECOND bug remained:
it passes the bare model (`--model glm-5.1`) WITHOUT the provider prefix
(`zai-coding-plan/`), so opencode can't resolve the provider →
`UnknownError: Unexpected server error`. (My initial guess that this was
rate-limiting was wrong — Max identified the missing provider prefix.) Max is
fixing the provider-prefix bug in a follow-up (≥0.3.4). Once that lands,
re-verify `@glm51`/`@mm`/`@mimo25p` resolve `<provider>/<model>` correctly.
The direct-opencode launcher idea stays dropped (ccc is the right fix locus).
The opencode default-model workaround (`~/.config/opencode/opencode.json` →
`zai-coding-plan/glm-5.1`) is left as a sane no-model fallback. Original
diagnosis below for record.

---
ORIGINAL (pre-fix):

## Symptom

`ccc @mm` / `ccc @glm51` / `ccc @glm5t` / `ccc @mm27` (all `runner = "opencode"`
aliases) launch, print the opencode startup warning, then **produce no output
and write no files** — hang for minutes/hours. Background tasks stay "alive"
burning ~8% CPU but never make a tool call.

## Root cause (three layers)

1. **ccc's opencode runner never passes `--model` to opencode.** Captured the
   live cmdline of a ccc-launched opencode proc: `opencode run --format json
   --thinking <prompt>` — **no `--model`**, for both the alias-keys path
   (`provider=`/`model=` in `~/.config/ccc/config.toml`) AND the inline
   `:provider:model` control. So opencode never learns the alias's model.
2. **opencode then uses its built-in default model** — observed banner
   `> build · glm-5v-turbo` regardless of the requested alias.
3. **That default model errors**: opencode log shows
   `AI_APICallError: unknown error, 999 (1000)` (a MiniMax/zai *coding-plan*
   provider-side error), retried ~5x then `cancel`. Net: silent hang.

Secondary: the `@mm` alias has `provider = "minimax"` but opencode's real
provider id is `minimax-coding-plan` (mismatch) — moot while #1 holds.

## Proof the providers are fine

Driving opencode **directly** with an explicit model works perfectly:
```
opencode run --model zai-coding-plan/glm-5.1 "Reply: PROBE_OK"   # -> PROBE_OK
opencode run --model minimax-coding-plan/MiniMax-M3 "Reply: PROBE_OK"  # -> PROBE_OK
```
Direct opencode also did a real tool-call + file-write inside a worktree with
the c2c MCP server loaded. (Do NOT use haiku with opencode — per Max.)

## Workaround applied

Added a top-level default to `~/.config/opencode/opencode.json`:
```json
"model": "zai-coding-plan/glm-5.1",
```
After this, `ccc @glm51` runs end-to-end (wrote a file, replied DONE). NOTE:
because ccc still drops per-alias model, **every** opencode alias now runs on
this one default model — you cannot select per-alias model through ccc.

## Proper fixes (not yet done)

- **Per-model agents now**: a launcher that calls `opencode run --model
  <provider/model> "<prompt>"` directly, bypassing ccc. Verified path.
- **Real fix**: patch ccc's opencode runner to emit `--model <provider>/<model>`
  from the alias's `provider`+`model` keys (and fix the `@mm` provider id to
  `minimax-coding-plan`).

## Lesson for the next agent

If a `ccc @<opencode-alias>` agent hangs with no output: check the opencode log
(`~/.local/share/opencode/log/*.log`) for `stream error` / `999 (1000)` and the
banner model. If it's not the model you asked for, ccc dropped `--model`. Use
`opencode run --model <provider/model>` directly, or rely on the opencode
default. **Codex (`ccc @cx-coder`) is unaffected and was the reliable runner.**
