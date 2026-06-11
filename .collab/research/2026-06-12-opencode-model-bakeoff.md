# OpenCode model bake-off — mm3 vs glm51 vs mimo25p

**Started** 2026-06-12 (claude, autonomous, Max directive). Goal: develop an
evidence-based opinion on which opencode-runner model is best/fastest for c2c
feature work, by cycling comparable tasks between them, having them
review-and-fix each other's work, and tallying bugs found (count + severity).

## Contenders
| Alias | Provider | Model | thinking |
|---|---|---|---|
| `mm3` | minimax | MiniMax-M3 | 4 |
| `glm51` | zai-coding-plan | glm-5.1 | 4 |
| `mimo25p` | xiaomi-token-plan-sgp | mimo-v2.5-pro | 3 |

(codex = `@cx-coder`/`@cx-reviewer` is the rescue/final-review path, NOT a
bake-off contender.)

## Scoring dimensions
- **Speed**: wall-clock from launch → final commit/report.
- **Correctness**: build rc, tests green first try, did it follow the spec.
- **Autonomy**: needed hand-holding / got stuck / went off-scope?
- **Review quality**: when reviewing another's work — bugs found (count +
  severity Sev1/2/3), false positives.
- **Hygiene**: worktree discipline, no leaks, ran review-and-fix, clean commit msg.

## Reliability / config notes
- **mm3 (+mm) were broken** by a wrong provider id in `~/.config/ccc/config.toml`
  (`provider = "minimax"`; opencode's real id is `minimax-coding-plan`). ccc 0.3.4
  emitted `--model minimax/MiniMax-M3` → opencode `UnknownError`. FIXED by editing
  config → `minimax-coding-plan`. mm27 was already correct. All 4 now functional.
  Lesson: a model "failing" may be a ccc-config provider-id mismatch, not the model.

## Task log
| # | Task | Model | Launched | Done | Wall | Build | Tests | Verdict | Notes |
|---|---|---|---|---|---|---|---|---|---|
| T1 | P3a `c2c sessions` impl | glm51 | 03:16 | 03:27 | ~11m | rc=0 | 4/4 | self-PASS (needs peer) | clean explore, recovered from Edit-uniqueness retries; triggered global install via commit-msg hook. STRONG. |
| T2 | P3a peer-review | mimo25p | 03:31 | 03:36 | ~5m | n/a | n/a | INCOMPLETE | loaded peer-review skill, read diff/stat, but produced NO verdict/tally, NO fixes, hit a failed Read on design doc, fizzled. WEAK review — P3a still unreviewed. |
| T3 | memory/schedule/ephemeral dogfood | glm51 | 03:31 | 03:36 | ~5m | n/a | n/a | DONE | 13 issues (3 Sev2, 10 Sev3), clean summary table, cleaned up artifacts. THOROUGH. Found recurring "send-to-unregistered-alias silent" Sev2. |
| T4 | relay dogfood (local relay) | mm3 | 03:38 | 03:42 | ~4m | n/a | n/a | PARTIAL→re-run | basic+multiline A→relay→B EXACT MATCH ✓ (relay transport WORKS), but DIED on a permission-rejection (no --yolo) before 5KB test + findings file. Re-dispatched with --yolo (b60h8j3kp). |
| T5 | rooms dogfood | mm27 | 03:38 | 03:42 | ~4m | n/a | n/a | DONE | STRONG: found 2 Sev1 silent-msg-loss bugs + 4 Sev2 + 2 Sev3. Wrote findings. Comparable to glm51. |
| T6 | P0 peer-review | cx-reviewer (codex) | 03:38 | — | — | — | — | running | bap7gpgnd (final-review path, not a contender) |
| T7 | relay dogfood finish (--yolo) | mm3 | 03:43 | 03:49 | ~6m | n/a | n/a | DONE | STRONG: relay verdict GREEN, all round-trips sha256 exact-match, unregistered-alias cleanly rejected, relay rooms work. 5 Sev3 hygiene items. mm3's no-yolo death was the only blemish. |
| T8 | sessions/send/pow dogfood (--yolo) | glm51 | 03:43 | 03:49 | ~6m | n/a | n/a | DONE | STRONG: 9 issues (2 Sev2, 7 Sev3). Found `--from` sender-SPOOFING (security) + confirmed local silent-queue. PoW has zero CLI surface. |
| T9 | my-rooms CLI impl (--yolo) | mimo25p | 03:50 | 04:11 | ~21m | rc=0 | 3/3 | DONE (needs peer) | bm41mqgn1. Clean impl: reused Broker.my_rooms, --json schema matches rooms list, registered in both groups, empty-state "Not in any rooms." Drive-bys: edited test c2c_cmd helper (Sys.executable_name) + left .opencode/package.json modified-unstaged (correctly NOT committed). HEAD 42551846. SLOWER than glm51's comparable impl (~21m vs ~11m) but correct + scoped. mimo's first real impl sample = SOLID. |
| T10 | P3a peer-review (--yolo) | mm3 | 03:50 | — | — | — | — | running | b89tcdvqd — proper peer-PASS attempt (mimo's was incomplete) |
| T11 | P0 peer-review (codex) | cx-reviewer | 03:38 | 04:15 | ~37m | rc=0 | 8/8 | PASS (code) | bap7gpgnd. Rigorous: found+fixed 4 Sev2 (double hook-JSON, case-sensitive reserved-sender, stale Claude docs, unbounded stdin JSON parse), extracted cold-boot-ctx lib. COULDN'T commit (codex sandbox made .git RO) — I committed its fixes (3b818659) + re-verified + MERGED P0 to master (d7b1a925). codex = strongest reviewer (not a bake-off contender). 425k tokens — thorough but expensive. |
| T12 | my-rooms peer-review (--yolo) | glm51 | 04:16 | — | — | — | — | running | bu8d26em9 — independent review of mimo's 42551846 |
| T13 | P1 Stop-hook impl (--yolo) | mimo25p | 04:16 | — | — | — | — | running | b11sl6sur — mimo's 2nd impl sample (chain-slice on P0) |
| T10 | P3a peer-review (--yolo) | mm3 | 03:50 | 04:18 | ~28m | rc=0 | 8/8 | **PASS** | b89tcdvqd. STRONG review: 5 fixes (4 Sev2, 1 Sev3) in 2 commits. Caught HOLLOW tests (re-impl formatting inline, never called sessions_cmd), `live`-vs-`alive` JSON drift, LIVE/yes-no vs STATE/alive-dead header divergence, drive-by indent, missing canonical_alias test. Extracted C2c_sessions_format helper to make tests real. P3a MERGED to master (d618c850). mm3 = excellent reviewer — the "look at the neighbors" pass glm51's impl lacked. |
| T15 | #7 hook test harness (--yolo) | mm3 | 04:18 | — | — | — | — | running | by9n4mzm3 — e2e + latency harness for PostToolUse hook (chain on P0/P3a) |
| T12 | my-rooms peer-review (--yolo) | glm51 | 04:16 | 04:23 | ~7m | rc=0 | 3/3 | **PASS** | bu8d26em9. Found 1 Sev2 docs-drift (docs/commands.md missing my-rooms) → fixed in 6235751d. Validated drive-by c2c_cmd change is sound, confirmed no stray files in commit, schema matches rooms list. Thorough + fast. my-rooms MERGED (e319dc52). |
| T14 | silent-send fix impl (--yolo) | mm27 | 03:55 | 04:25 | ~30m | rc=0 | 3/3 | DONE (in review) | bt85wynx9. HEAD cb011f17. Bug1 send-after-leave→RAISES (gated on room having a creator), Bug2 ghost-room→warns+sr_warning field, Bug3 unregistered-local-alias→RAISES (remote @ still queues). HIGH sev (broker send-semantics) → glm51 reviewing for regressions. |
| T16 | silent-send peer-review (--yolo) | glm51 | 04:26 | — | — | — | — | running | bfn4s4tup — HIGH-sev regression hunt (raise-on-unknown could break send_all/MCP) |
| T17 | P4 client-broker impl (--yolo) | mm27 | 04:26 | 04:48 | KILLED | — | — | MISFIRE | bte9xegox — edited MAIN tree not worktree (ccc launched from main-tree cwd → opencode relative paths leaked). WIP saved to /tmp/mm27-p4-partial-*.patch, main tree restored. Finding: 2026-06-12T04-48 ccc-cwd-worktree-leak. NOT a mm27-quality issue — orchestration bug. |
| T16 | silent-send peer-review (--yolo) | glm51 | 04:26 | 04:43 | ~17m | rc=0 | full-green | **PASS** | bfn4s4tup. 2 regression fixes (1 Sev1 + 1 Sev2) in 57873904. silent-send MERGED (0be94b4b). 358/358 c2c_mcp green. |
| T18 | P4 client-broker impl REDUX (--yolo, cwd=worktree) | mm27 | 04:49 | — | — | — | — | running | b756grfwa — re-dispatched correctly from inside wt-p4-clients |
| T19 | P1 Stop-hook peer-review (--yolo, cwd=worktree) | glm51 | 04:49 | 05:04 | ~15m | rc=0 | 11/11+8/8 | **PASS** | b24krnmaz. 2 fixes (Sev2: refactor regressed resolve_session_id → exit 0 not 1 on invalid sid, restored P0 contract; Sev3: installer Stop-skip edge). Confirmed NO #7 cross-slice break. P1 MERGED (97a81138). |
| T20 | --from sender-spoofing fix (--yolo, cwd=worktree) | glm51 | 05:05 | — | — | — | — | running | b7vasue5x — SECURITY fix glm51 itself found in dogfooding (authorize --from by caller identity) |
| T15b | #7 hook harness impl (--yolo) | mm3 | 04:18 | 05:05 | ~47m | rc=0 | 12/12 | DONE (needs peer) | by9n4mzm3. HEAD 5f622d0f. Drives BUILT c2c_inbox_hook exe as subprocess: 10 correctness + 2 speed (K=50, median ~20ms). Speed gated behind C2C_HOOK_SPEED_STRICT (record-only default, <250ms strict). Test-only/additive. mm3 thorough as always — used in-session fresh-slate subagent review (self-review). → mimo25p independent peer-review (T21). |
| T21 | #7 hook harness peer-review (--yolo, cwd=worktree) | mimo25p | 05:06 | 05:18 | ~12m | rc=0 | 12/12 | **PASS** | b8hgixs7s. COMPLETE, thorough, evidence-backed review (full checklist, verified each test non-vacuous + drives real hook exe + determinism + 175-test full suite). 0 bugs (clean slice). **BIG improvement over T2** (which fizzled) — mimo CAN review well on contained slices. #7 MERGED (00e4906c). |
| T22 | sessid-delivery dogfood (--yolo, installed binary) | mimo25p | 05:20 | — | — | — | — | running | b1wfe1msz — dogfood shipped P0/P1/silent-send/sessions/my-rooms end-to-end; mimo's 1st dogfood sample |
| T18b | P4 client-broker impl REDUX (--yolo, cwd=worktree) | mm27 | 04:49 | 05:25 | ~36m | rc=0 | 23+8 | DONE (needs peer) | b756grfwa. HEAD 104471fb. Correct worktree this time (cwd fix worked). Added C2c_kimi_notifier.poll_once_global (drains global broker → kimi notif store) + drain_global_messages in deliver_watch + poll_once_kimi calls it. Self-review only. → mm3 peer-review (T23). Reviewer must check codex/opencode coverage (task=all 3) + no double-delivery/cross-session-leak. |
| T23 | P4 peer-review (--yolo, cwd=worktree) | mm3 | 05:25 | 05:51 | ~26m | n/a | n/a | INCOMPLETE | bm9i1mqx2. Deep review (traced path-traversal, double-delivery, approval-verdict filtering) but RAN OUT mid-fix adding a .mli + integration test → hit Cmdliner build error, left a BROKEN untracked .mli, NO verdict. Over-scoped. Useful findings surfaced (Sev3 path-traversal hardening in poll_once_global; is_approval_verdict_body unused=pre-existing; weak test). Broken .mli removed; P4 restored to buildable 104471fb. → glm51 fresh review (T25). Lesson: mm3 rigorous but over-scopes review-into-refactor + runs out. |
| T25 | P4 peer-review REDUX (--yolo, cwd=worktree) | glm51 | 05:55 | 06:07 | ~12m | rc=0 | 24+8 | **PASS** | b7od4f3ny. Complete review: confirmed ALL 3 clients covered (codex/opencode via deliver_watch.drain_global_messages, kimi via poll_once_global), no double-delivery (separate broker dirs), non-vacuous leak test. FIXED mm3's Sev3 (session_id traversal guard, 9b06d5c8). P4 MERGED (9b761e58). |
| T24b | --from security peer-review (--yolo, cwd=worktree) | mm27 | 05:39 | 06:03 | ~24m | rc=0 | 6+22 | **PASS** | b0fjs8iv1. CONFIRMED+FIXED the Sev2 rule-3 hole I flagged (unregistered --from → was ALLOW = impersonate offline peer; now REJECT, 5cd9ddc1). Traced real --from call sites for regressions (inject/nudge/schedule unaffected; poker covered by coord gate). --from MERGED (574447d6). Strong security review. |
| T26 | sessid-test-hermetic fix (--yolo, cwd=worktree) | mm3 | 06:08 | — | — | — | — | running | b2p3fu3hh — port #7 binary-resolution so test_session_id_delivery passes under full dune test |
| T20b | --from spoofing fix impl (--yolo, cwd=worktree) | glm51 | 05:05 | 05:38 | ~33m | rc=0 | 22+6+358 | DONE (needs peer) | b7vasue5x. HEAD a6e44825. BROADER than asked: validated --from across send/send-all/rooms-send + casefolded MCP impersonation check. Rule: own-alias/coordinator/unregistered→allow, registered-to-other→reject. Flagged 2 open Qs (no broker-level/relay enforcement). Self-review only → mm27 SECURITY review (T24). Concerns to probe: rule-3 (unregistered→allow) = impersonate offline peer? + managed-launcher --from regression. |
| T24 | --from security peer-review (--yolo, cwd=worktree) | mm27 | 05:39 | — | — | — | — | running | b0fjs8iv1 — HIGH-sev: rule-3 hole + launcher-regression trace |
| T22b | sessid-delivery dogfood (--yolo) | mimo25p | 05:20 | 05:35 | ~15m | n/a | n/a | DONE | b1wfe1msz. **KEY RESULT: session-id delivery WORKS END-TO-END** (concrete transcript: send --session → global broker file → c2c-inbox-hook-ocaml drains + emits additionalContext → 2nd drain empty). 7 Sev3 polish (0 Sev1/2): sessions JSON missing role/CLIENT="?"/STATE="?"; from_alias defaults c2c-cli even in registered session (overlaps glm51 --from fix!); hook --help empty; solo-room "0 members" warning misleading. Clean transcripts + cleanup + findings file. mimo's 1st dogfood = SOLID. Findings: 2026-06-12-mimo25p-sessid-delivery-dogfood.md |
| — | install master + smoke | claude | 05:06 | 05:07 | ~1m | rc=0 | — | OK | 5 merged slices installed (v0.8.0 97a81138). `c2c sessions` (P3a+mm3 STATE cols) + `c2c rooms my-rooms` validated live. Deep hook-into-transcript dogfood needs tmux (deferred). |
| T13 | P1 Stop-hook impl (--yolo) | mimo25p | 04:16 | 04:31 | ~15m | rc=0 | 4/4 | DONE (needs peer) | b11sl6sur. HEAD 02fbeff0. Factored shared drain+format into c2c_hook_lib.ml; new c2c_stop_hook.ml uses decision:block+reason (correct — Stop hooks can't use additionalContext per §4.3); installer wires c2c-stop-deliver.sh. Good design awareness, sound no-double-delivery (destructive drain + mutually-exclusive lifecycle). mimo's 2nd impl = SOLID, faster this time (~15m). NOTE: refactor moves c2c_inbox_hook shared logic → reviewer must check mm3 #7 harness (branched pre-refactor) still builds post-merge. AWAITING PEER (queued — 4 agents busy). |

## Cross-review tally (bugs found & fixed)
| Reviewer | Reviewed | Author | Sev1 | Sev2 | Sev3 | FalsePos | Notes |
|---|---|---|---|---|---|---|---|
| mimo25p | P3a sessions | glm51 | 0 | 0 | 0 | 0 | INCOMPLETE — no verdict produced; does not count as a peer-PASS |
| mm3 | P3a sessions | glm51 | 0 | 4 | 1 | 0 | PASS. 5 real fixes: hollow tests, live/alive drift, header divergence, indent, missing canonical_alias test. Excellent. |
| cx-reviewer (codex) | P0 sessid | claude/glm51 | 0 | 4 | 0 | 0 | PASS. double hook-JSON, case-sens reserved-sender, stale docs, unbounded stdin parse. Not a bake-off contender (final-review path). |
| glm51 | my-rooms CLI | mimo25p | 0 | 1 | 0 | 0 | PASS. Sev2 docs-drift (commands.md). Validated drive-by + no stray files. Fast + thorough. |
| glm51 | silent-send fix | mm27 | 1 | 1 | 3 | 0 | PASS. **Caught 2 REAL regressions** (Sev1: send_room blocked c2c-system msgs; Sev2: enqueue raise broke notify_shared_with relay fallback #286) — exactly the broad-behavioral-change risks flagged. Excellent HIGH-sev review. |
| glm51 | P1 Stop-hook | mimo25p | 0 | 1 | 1 | 0 | PASS. Sev2: refactor regressed resolve_session_id exit-code (restored P0 contract); Sev3 installer edge. Confirmed no #7 cross-slice break. |
| mimo25p | #7 hook harness | mm3 | 0 | 0 | 0 | 0 | PASS (clean). COMPLETE evidence-backed review — big improvement over its incomplete T2. Capable on contained slices. |
| mm27 | --from spoofing fix | glm51 | 0 | 1 | 2 | 0 | PASS. **Found+FIXED Sev2 rule-3 hole** (unregistered --from = impersonate offline peer). Traced real call sites for regressions. Excellent security review. |
| mm3 | P4 client-broker | mm27 | 0 | 0 | 1 | 0 | **INCOMPLETE** — deep but over-scoped (review→refactor), ran out mid-fix, left broken .mli, NO verdict. Useful findings but no peer-PASS. Redone by glm51. |
| glm51 | P4 client-broker | mm27 | 0 | 0 | 1 | 0 | PASS. Confirmed all 3 clients covered + no double-delivery/leak. Fixed Sev3 traversal guard. Clean complete review. |

## Real c2c defects surfaced by dogfooding (fix candidates)
**THEME: sends that go nowhere succeed SILENTLY** — systemic, undermines the
"messaging you can trust" group goal. Being fixed in `wt-silent-send-fix`.
- **Sev2: `c2c send`/ephemeral to UNREGISTERED alias silently queues** (glm51 ×2:
  memory-dogfood E-1 + finding #7). No warning; nobody reads it.
- **Sev1: `c2c rooms send` AFTER `leave` → "0 delivered", message LOST** (mm27).
- **Sev1: `c2c rooms send` to non-existent/typo room → creates ghost empty room,
  message LOST** (mm27).
- **Sev2: `my-rooms` exists as MCP tool but NO CLI equivalent** (mm27).
- Sev2: room tags (🔴 FAIL etc.) missing from sender's OWN history (mm27).
- Sev2: messages from non-members appear in room history (mm27) — needs verify.
- **Sev2 (SECURITY): `c2c send --from <alias>` is UNVALIDATED → sender spoofing**
  (glm51). A spoofed `--from` is delivered to recipient + written to history as that
  sender. Fix AFTER wt-silent-send-fix merges (same send handlers — avoid parallel edits).
  Assign to glm51 (it found it; strong).
- Relay (mm3): GREEN. local-broker silently queues unregistered-alias sends, but the
  RELAY path correctly rejects them (unknown_alias, exit 1) — so the silent bug is
  local-broker-specific. 5 Sev3 hygiene items (git-hash drift, enc:none plaintext,
  rooms --help synopsis mismatch, dead-letter non-JSON default, self-join echo).
- **PoW has ZERO CLI observability** (glm51) — no `c2c pow ...`, not in server-info.
  A user cannot see PoW working. Enhancement candidate (low sev, real gap).

## Running opinion (update as evidence accumulates)
- **glm51**: strongest so far — thorough implementer (P3a, clean) AND thorough dogfooder
  (13 well-classified issues). Reliable.
- **mimo25p**: weak on review depth — went through motions but no conclusion. Needs
  re-test on an implementation task before judging.
- **mm27**: confirmed working; quality TBD (rooms dogfood in flight).
- **mm3**: was config-broken; now functional; quality TBD (relay dogfood in flight).

## STOP CONDITION (Max directive 2026-06-12)
Do NOT stop the heartbeat Monitor (task bdrcosvel) until ABSOLUTELY EVERYTHING is done:
all code changes through review-and-fix loops to PASS, all tests green, all slices
merged/peer-passed. ONLY THEN: print full agent rankings to the user (mm3, mm27, glm51,
**mimo25p** — do not forget mimo), THEN stop the Monitor (TaskStop bdrcosvel).
- **mimo25p still needs a fair IMPLEMENTATION task** — its only sample was a weak review.
  Candidate slices for mimo: `my-rooms` CLI (mm27's Sev2 gap), P1 Stop hook, or #7 harness.

## Final verdict (2026-06-12, all 9 slices merged)

**Slices shipped (all peer-PASSed + merged to local master):** P0 (send --session +
global broker + hook), P3a (`c2c sessions`), my-rooms CLI, silent-send fix, P1 (Stop
hook), #7 (hook harness), `--from` spoofing fix, P4 (cross-client global drain),
sessid-test-hermetic. Feature validated end-to-end in the wild (mimo dogfood transcript).
All feature tests green (isolation + full `dune test`). 17 remaining suite failures are
PRE-EXISTING, unrelated, heterogeneous infra/env debt (14 c2c_cli state/binary, 2
peer_pass trailer-parse, 1 get_tmux env) — confirmed not regressions.

### RANKINGS

**1. glm51 (glm-5.1) — BEST OVERALL.** Most consistent across impl + review + dogfood;
zero failures/retries. Fast (P3a impl ~11m, dogfoods ~5-6m). As reviewer caught the most
+ most-severe regressions: the silent-send Sev1 (system-msg block) + Sev2 (relay fallback
break), P1 Sev2 (resolve_session_id exit-code), my-rooms docs-drift, P4 Sev3 traversal.
As dogfooder found the `--from` SECURITY bug + the unregistered-alias silent queue. Default
pick for most work.

**2. mm27 (MiniMax-M2.7-highspeed) — STRONG #2, best bug-finder.** Found 2 Sev1 silent-loss
bugs (rooms dogfood) + the `--from` rule-3 Sev2 security hole (review) that even the author
missed. Solid impl (silent-send, P4). Thorough security reviewer who traces real call sites.
Slightly slower (~24-36m). No reliability issues (its one "misfire" was MY launcher-cwd bug).

**3. mm3 (MiniMax-M3) — HIGHEST CEILING, LOWEST RELIABILITY.** Deepest work when it finishes:
excellent P3a review (5 fixes incl hollow-test detection), rigorous #7 harness (subprocess
e2e + latency benchmark). BUT over-scopes reviews into refactors and RUNS OUT of budget —
P4 review ended with no verdict + a broken .mli; #7 impl took ~47m (longest). Also died once
without `--yolo`. Use for hard/contained tasks with TIGHT scope; not for open-ended reviews.

**4. mimo25p (mimo-v2.5-pro) — IMPROVED SHARPLY, reliable when scoped.** Early weak point: its
first review (P3a) fizzled with no verdict. Recovered strongly: clean my-rooms + P1 impls
(good design awareness — knew Stop hooks can't use additionalContext), a COMPLETE evidence-
backed #7 review, and a solid first dogfood proving the feature e2e. Reliable on contained
tasks; slightly slower impl (my-rooms ~2x glm51). Trending up.

**Not a contender — codex/cx-reviewer:** strongest single reviewer (P0: 4 Sev2 fixes) but
EXPENSIVE (~425k tokens) and hit the `.git`-RO sandbox commit blocker. Reserve for
final/merge-critical reviews or when an opencode model is stuck.

### Cross-review bug tally (reviewer → bugs found+fixed)
- glm51: ~6 real (incl 1 Sev1, 4 Sev2) across silent-send/my-rooms/P1/P4. Best reviewer.
- mm3: 5 (4 Sev2, 1 Sev3) on P3a — then 1 INCOMPLETE (P4, no verdict).
- mm27: 1 Sev2 security (the rule-3 hole) + regression-trace. High signal.
- mimo25p: 0 on P3a (incomplete) → complete clean PASS on #7. Variable→reliable.

### Speed (rough wall-clock): glm51 fastest + most consistent · mimo25p/mm27 moderate ·
mm3 slowest (over-scopes).

### Orchestration lesson logged: launch `ccc` with cwd = the worktree (finding
2026-06-12T04-48 ccc-cwd-worktree-leak) — main-tree cwd makes opencode edit the wrong tree.
