# #142 end-to-end dogfood test design

- **Author:** stanza-coder
- **Date:** 2026-04-30
- **Status:** DESIGN — gates on slices 3 + 4 landing
- **Cross-references:**
  - #142 (parent: kimi parity, tool/command permissions forwarded)
  - #157 (slice 1: hook script + `c2c await-reply` CLI; SHAs `985b05b7` + `674b6230`)
  - Slice 2 (`c2c install kimi` toml block + script install; SHA `0f85a486`, cherry-picked at `439765ec`)
  - Slice 3 (`--afk`→`--yolo` swap; in flight by fern-coder)
  - Slice 4 (Claude Code parity in `~/.claude/settings.json`; in flight by cedar-coder)

## Goal

Validate that when an operator opts in (uncomment a `[[hooks]]` block in
`~/.kimi/config.toml` or matching Claude Code entry), a kimi (or Claude
Code) PreToolUse approval request actually reaches a remote reviewer
via c2c DM, blocks until the reviewer replies, and translates the
verdict back to the agent's exit-code protocol.

If this works end-to-end, the parity-by-construction property of #142
is real, not just structurally plausible.

## Pre-flight (after slices 3 + 4 cherry-picked + installed)

1. Cherry-pick slice 3 + 4 → local master.
2. `just install-all` from main tree.
3. Pre-conditions to verify:
   - `~/.local/bin/c2c-kimi-approval-hook.sh` exists (slice 2).
   - `~/.local/bin/c2c-kimi-approval-hook.sh` is mode 0755.
   - `c2c await-reply` subcommand resolves (`c2c await-reply --help`).
   - `~/.kimi/config.toml` has the slice-2 commented [[hooks]] block.

## Test 1: kimi → operator approval round-trip (allow path)

**Setup:**

1. Edit `~/.kimi/config.toml`:
   - Delete or comment out the top-level `hooks = []` line (TOML schema
     conflict with `[[hooks]]` AOT).
   - Uncomment **example C** of the slice-2 block (matcher `""`, the
     match-everything case — this guarantees the next tool call fires
     the hook regardless of tool name).
2. `c2c restart kuura-viima` (picks up `--yolo` from slice 3 + new
   config from edit).
3. Verify kuura is back online: `c2c list | jq '.[] | select(.alias=="kuura-viima")'`.

**Probe:**

4. From stanza-coder session, DM kuura: "please run `bash` to print
   `hello from approval test` and tell me the result". Anything
   guaranteed to use a tool.
5. Within ~5s, expect a DM **TO stanza-coder** from kuura's session
   alias (or via c2c-system if the script's `c2c send` runs as the
   hook process):
   ```
   [kimi-approval] PreToolUse:
     tool: <tool_name>
     args: <json>
     token: ka_<hex>
     timeout: 120s

   Reply with:
     c2c send <kimi-alias> "<TOKEN> allow"
     c2c send <kimi-alias> "<TOKEN> deny because <reason>"
   ```
6. Reply: `c2c send kuura-viima "<TOKEN> allow"`.
7. Within ~5s, expect kuura's tool call to proceed and the hook
   process to exit 0.
8. Kuura completes the brief (prints "hello from approval test", DMs
   the result back).

**Pass criteria:**

- Approval DM arrives at stanza within 5s of the brief landing.
- Verdict reply is recognized; tool proceeds.
- No error in `~/.kimi/logs/<wh>/<sid>/c2c-chat-log.md` for the hook.
- `~/.kimi/logs/<wh>/<sid>/kimi.log` shows hook fire + exit 0 trace.

## Test 2: deny path

Same setup as Test 1, repeat with a fresh brief.

7'. Reply: `c2c send kuura-viima "<TOKEN> deny because dogfood test"`.
8'. Expect kuura's tool call to be blocked. The reason "dogfood test"
    appears in kimi's TUI as the rejection.
9'. Kuura DMs stanza about the denial (or the swarm-lounge); confirms
    no side effect from the denied tool call.

## Test 3: timeout fall-closed

Setup as Test 1 BUT do not reply.

- After 120s (configurable via `C2C_KIMI_APPROVAL_TIMEOUT`), the hook
  process exits 2 with stderr "no verdict from reviewer=stanza-coder
  within 120s; falling closed (token=...)".
- Kuura's tool call is blocked.
- The hook's stderr is shown to kuura's agent loop as the rejection
  reason.

To make the timeout test fast, override:
```bash
C2C_KIMI_APPROVAL_TIMEOUT=10 c2c restart kuura-viima
```
(or whatever the env-pass mechanism is).

## Test 4: Claude Code parity (gates on slice 4)

Same shape as Tests 1–3 but using a Claude Code session instead of
kimi.

- Verify slice 4's `~/.claude/settings.json` PreToolUse entry is
  registered (or whatever the chosen design (A)/(B)/(C) ends up being).
- If (B) sentinel-matcher: edit the matcher to `^Bash$` (or whatever
  matches the test tool).
- Restart Claude Code session (whatever mechanism the swarm uses).
- Run a Bash tool call; expect approval DM.

**Cross-client parity proof:** the SAME `c2c-kimi-approval-hook.sh`
script handles both. The DM body looks identical from the reviewer's
side regardless of whether the tool call originated in kimi or Claude
Code. That's the load-bearing claim of #142's hook-based design.

## Test 5: token uniqueness (light)

If the hook fires twice in close succession for two different tool
calls, the tokens must differ so the operator's `<TOKEN> allow` reply
disambiguates.

- Brief kuura: "run `bash` printing 'one' AND `bash` printing 'two'
  back to back".
- Expect TWO approval DMs with different tokens.
- Reply to each independently; verify each tool call only proceeds
  when its specific token's allow reply lands.

(Slice-1 minted tokens via `ka_<tool_call_id>` — should be unique by
construction. This test sanity-checks that.)

## Negative tests / safety

- **Wrong-token reply ignored:** reply with a fabricated token that
  doesn't match the active one. Should NOT unblock the hook; the
  legitimate token's hook continues to wait.
  (Slice-1 c2c_await_reply tests already cover this offline; e2e
  validates over the broker.)
- **Network glitch / broker down during approval:** harder to test
  in-process; document as known limitation. The fall-closed timeout
  is the safety net.

## Test runner / runbook

After validation, write into `.collab/runbooks/142-e2e-approval-test.md`
as a step-by-step playbook so any future stanza (or kuura, or anyone)
can re-run it after subsequent changes touch the hook surface.

## Sequencing

```
slice 3 PASS + cherry-pick → slice 4 PASS + cherry-pick → install-all
                                                              ↓
                                                  Test 1 (kimi allow)
                                                              ↓
                                                  Test 2 (kimi deny)
                                                              ↓
                                                  Test 3 (kimi timeout)
                                                              ↓
                                                  Test 4 (claude parity)
                                                              ↓
                                                  Test 5 (token uniqueness)
                                                              ↓
                                                  Write runbook ↓ close #142
```

## What this validates

1. The hook script's c2c send + await-reply round-trip works in the
   wild against the live broker (not just bash unit tests).
2. The kimi-cli hooks subsystem fires the script synchronously
   BEFORE its own approval runtime (verified in source; e2e
   validates the actual order of operations).
3. The `--yolo` posture (slice 3) is safe in the presence of an
   uncommented hook block.
4. Cross-client parity is real, not just structural — same script,
   same DM shape, same exit-code protocol works for kimi AND Claude
   Code.
5. The fall-closed timeout is a real safety boundary.

## Out of scope for this dogfood pass

- Multi-reviewer consensus (one reviewer for v1).
- Hash-based idempotency (lumi's #483 Phase B note; out of scope
  for v1).
- TTL-based cache of recent verdicts (Phase C territory).
- Codex / Gemini parity (separate slices; codex doesn't have a
  hook system today).

## Failure modes to watch for

- **Token in DM body gets line-broken or formatting-eaten** — would
  break operator's reply parsing. The slice-1 contract is "any DM
  whose content contains the token plus 'allow' or 'deny'". Test by
  inspecting actual DM content shows token on its own segment.
- **kimi-cli hook timeout < operator response time** — defaults to
  30s in HookDef.timeout; the script's `await-reply` defaults to 120s.
  Mismatch means the hook process gets killed by kimi-cli BEFORE
  await-reply returns, defeating the design. Slice-2 toml examples
  set `timeout = 120` to align with the await-reply default. Verify
  that explicitly during Test 1.
- **`c2c send` from inside the hook process under `--yolo`** — the
  hook process is a subprocess of kimi-cli. If `c2c send` itself
  triggers some nested approval (e.g. file write to broker dir), we
  could deadlock. Likely fine because broker writes are not subject
  to PreToolUse (those are the agent's tool calls, not the broker
  ops). But verify by tail -f on broker.log during Test 1.

🪨 — stanza-coder
