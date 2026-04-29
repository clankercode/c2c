# Broker Test-Coverage Audit — `c2c_mcp.ml`

**Author**: stanza-coder (subagent dispatch)
**Date**: 2026-04-29
**Scope**: `ocaml/c2c_mcp.ml` public API per `c2c_mcp.mli` + select non-public helpers reachable via tests.
**Counterpart**: `ocaml/test/test_c2c_mcp.ml` (276 tests, 10039 LOC).
**Mode**: discovery only — no fixes, no test code.

## TL;DR — Top 5 gaps by user-impact severity

1. **`decrypt_envelope` / `decrypt_message_for_push` have ZERO unit tests.** All four enc-status branches (`Failed`, `Key_changed`, `Not_for_me`, plain-success) are exercised only indirectly via end-to-end relay tests (`relay_e2e.ml`), not as broker-level unit cases. Receipts: `c2c_mcp.ml:4123` (decrypt_envelope), `c2c_mcp.ml:4102` (decrypt_message_for_push), `c2c_mcp.ml:5687-5742` (poll_inbox inline duplicate). User-impact: silent enc misclassification → DM appears plaintext when it shouldn't, or appears `Failed` when key is genuinely valid. **Severity: HIGH**.
2. **`tag_histogram` has ZERO tests.** Public API exposed at `c2c_mcp.mli:298` and consumed by `cli/c2c.ml:6572`. Body at `c2c_mcp.ml:2367-2429`. The sister function `delivery_mode_histogram` has 3 cases (`test_c2c_mcp.ml:243-321`); tag_histogram has none. User-impact: `c2c doctor` tag histogram silently regresses. **Severity: HIGH** (it's a doctor surface; doctor regressions take ~weeks to spot in dogfooding).
3. **`pin_x25519_sync` / `pin_ed25519_sync` only test the `New_pin` branch.** `Already_pinned` and `Mismatch` branches uncovered. Receipts: `c2c_mcp.ml:1129-1149` (impl), `test_c2c_mcp.ml:8004-8040` (single-branch tests). H2b peer-PASS DM tests at L9151+ exercise `Mismatch` indirectly via the end-to-end peer-PASS path but never as a unit case. User-impact: silent pin downgrade if Mismatch returns `New_pin` due to a future regression. **Severity: HIGH** (security boundary).
4. **`reserved_system_aliases` rejection paths untested.** `register` rejection (`c2c_mcp.ml:1882-1884`) and `enqueue_message` from-alias spoof guard (`c2c_mcp.ml:2017-2020`) both raise `invalid_arg` for `c2c` / `c2c-system`. No tests assert these. User-impact: a future refactor lets an agent self-impersonate `c2c-system` and forge peer_offline / peer_register / room-system events. **Severity: HIGH** (impersonation guard).
5. **`capture_orphan_for_restart`, `capture_pid_start_time`, `read_proc_environ` (mli L165-168), `compute_canonical_alias` have ZERO tests.** All four are exposed in the public mli. Receipts: `c2c_mcp.ml:2822-2866`, `c2c_mcp.ml:1722` (compute_canonical_alias), mli L162-168. `replay_pending_orphan_inbox` IS tested but the **capture half** of the round-trip is not, leaving the atomic write+rename+unlink invariant unverified. User-impact: orphan-replay drops messages on restart if a future change to capture breaks the tmp-rename ordering. **Severity: MED-HIGH**.

---

## Per-function audit

Format: `function | branches present | branches uncovered | proposed test scenarios`. Files referenced are `ocaml/c2c_mcp.ml` (impl) and `ocaml/test/test_c2c_mcp.ml` (tests).

### Encryption / TOFU pin path

| Function | Impl | Branches present | Branches uncovered | Proposed scenarios |
|---|---|---|---|---|
| `decrypt_envelope` | `c2c_mcp.ml:4123` | none | (1) non-JSON content → passthrough; (2) malformed envelope_of_json; (3) `enc="plain"` + `find_my_recipient=Some`; (4) `plain` + `None` → `Not_for_me`; (5) `box-x25519-v1` + `our_x25519=None`; (6) `box` + recipient missing nonce → `Failed`; (7) `decrypt_for_me=None` + pinned mismatch → `Key_changed`; (8) decrypt success but no pinned ed25519 → `Failed`; (9) sig-verify fails → `Key_changed`; (10) full success path → pin call + decrypted content; (11) unknown `enc=` value | unit-level matrix per branch with synthesized envelopes |
| `decrypt_message_for_push` | `c2c_mcp.ml:4102` | none directly (e2e only) | All branches above as observed via the push call site (status discarded) | one test per branch confirming `content` field swap |
| `pin_x25519_sync` | `c2c_mcp.ml:1129` | `New_pin` (`test_c2c_mcp.ml:8004`) | `Already_pinned` (same pk twice), `Mismatch` (different pk same alias) | 2 tests; assert disk file unchanged on Mismatch |
| `pin_ed25519_sync` | `c2c_mcp.ml:1140` | `New_pin` (`test_c2c_mcp.ml:8020`) | `Already_pinned`, `Mismatch` | mirror x25519 cases |
| relay-pins disk schema | `c2c_mcp.ml:995-1052` | external delete + malformed JSON → reset (`test_c2c_mcp.ml:8042-8088`) | concurrent reload-while-saving race; partial-write recovery (truncated mid-save) | targeted fault injection during save |

### Registration / session lifecycle

| Function | Impl | Branches present | Branches uncovered | Proposed scenarios |
|---|---|---|---|---|
| `register` | `c2c_mcp.ml:1881` | hijack-from-alive, takeover-of-pidless, alias rename, case-insensitive eviction (`test_c2c_mcp.ml:1895`+, 3070+, 3112+, 3145+, 6119+) | **`reserved_system_aliases` rejection** (L1882); enc_pubkey supersession by Some-replaces-None (L1927); role supersession (L1931); concurrent same-session re-register collapsing `multiple` arm of `List.partition` (L1959) | reject "c2c" + "c2c-system"; assert pre-existing enc_pubkey survives re-register without arg; defensive `multiple` arm |
| `register` Docker lease side effect | L1998-2008 | none | lease file mtime update on Docker mode | env-flagged test toggling docker mode |
| `save_registrations` | L817 | none directly | atomic tmp+rename invariant; mode 0o600 (only via test_register_writes_registry_at_0o600 L2697 which calls register) | direct call test asserting permission + atomicity |
| `load_registrations` | L746 | implicitly via list_registrations | malformed registry.json (corrupted, missing fields, schema-drift); empty file | corrupt-file recovery test |
| `confirm_registration` | exposed | confirmed_at set (`test_c2c_mcp.ml:4046`) | deferred broadcast emission for `peer_register` AND room-join interleaving when a fresh session is confirmed mid-room-join | combo of pending fresh registration + explicit room join sequence |
| `read_proc_environ` | mli:165-168 | implicitly via discover_live_pid (`test_c2c_mcp.ml:8143+`) | direct call: missing /proc/<pid>/environ; permission-denied; malformed (no NUL terminator); empty | direct unit calls with synthesized fixtures |
| `capture_pid_start_time` | mli:163 | none direct | (1) None input → None; (2) Some pid alive → Some t; (3) Some dead pid → None | 3 unit cases |

### Resolution / liveness

| `resolve_live_session_id_by_alias` | L1502 | Resolved-alive, All_recipients_dead, Unknown_alias, case-insensitive (`test_c2c_mcp.ml:8370`), self-heal-via-/proc (8254, 8302) | **`alive_count > 1` `alias_resolve_multi_match` broker.log emission** (L1517-1540); behaviour when only the second of multiple matches is alive | duplicate-row registry that should still resolve to the alive one + log the smoke signal |

### Inbox / archive

| Function | Impl | Branches present | Branches uncovered | Proposed scenarios |
|---|---|---|---|---|
| `enqueue_message` | L2015 | unknown alias (`test_enqueue_to_dead_peer_raises:2639`), zombie-vs-alive (2650), remote-outbox path (5938) | **`reserved_system_aliases` from-alias rejection** (L2018-2020); ephemeral=true path (only field present in tests, never asserted on the inbox row); deferrable=true row written (currently exercised only via send-tool wrapping) | reject "c2c-system"-from; enqueue ephemeral=true then read back via read_inbox |
| `send_all` | L2072 | fans out, exclude_aliases, dead recipient, sender-only registry (`test_c2c_mcp.ml:3625-3760`) | duplicate alias in registry (Hashtbl-seen short-circuit at L2082); Unknown_alias arm (L2100) — registry enumeration cannot produce Unknown_alias for own row, so this arm is structurally dead-but-reachable on race | dup-registry-row test (artificial via save_registrations) |
| `read_inbox` | L2105 | non-destructive (`test_c2c_mcp.ml:114`) | malformed inbox JSON tolerated as `[]` (relies on load_inbox impl) | corrupt JSON file → empty list |
| `save_inbox` | mli:230 | indirect via enqueue/drain | direct call: atomic tmp+rename, mode 0o600 (asserted by test_enqueue_writes_inbox_at_0o600 indirectly only) | direct save_inbox followed by stat 0o600 |
| `drain_inbox` | L2445 | clears + archives, archive-fail-leaves-inbox claim implied | **archive append IO failure leaves inbox intact** (L2455-2464 invariant) — no test verifies the rollback | inject IOerror via fixture |
| `drain_inbox_push` | L2466 | suppresses deferrable (`test_c2c_mcp.ml:185`) | empty `to_push` shortcut + ephemeral filter on push path (L2475) | mix deferrable+ephemeral+normal in one inbox; assert correct partitioning |
| `delivery_mode_histogram` | L2296 | counts, last_n, empty (`test_c2c_mcp.ml:243-320`) | **`min_ts` filter not tested**; combination `min_ts` + `last_n` ordering | drained-at-spread + min_ts filter |
| `tag_histogram` | L2367 | **none** | `Fail`/`Blocking`/`Urgent`/`untagged` bucketing; by_sender sort tiebreak; min_ts filter; last_n filter; empty archive | 5+ scenarios mirroring delivery_mode coverage |
| `append_archive` / `read_archive` | mli:261-262 | limit + missing session (`test_c2c_mcp.ml:207-241`) | drained_by default vs explicit; multi-line jsonl read order; truncation when limit < entries | drained_by="watcher" vs default; order test |
| `read_orphan_inbox_messages` | mli:231 | implicitly via `test_sweep_preserves_nonempty_orphan_to_dead_letter:3454` | direct: missing file → []; non-empty preserves order | 2 direct cases |
| `read_and_delete_orphan_inbox` | mli:234 | tested (`test_c2c_mcp.ml:3389,3402`) | concurrent enqueue race window guarded by inbox lock — invariant unverified | second-thread enqueue while delete in flight |
| `capture_orphan_for_restart` | mli:238 | **none** | (1) no orphan → 0; (2) empty orphan deleted; (3) non-empty captured + pending file written; (4) tmp/rename failure leaves orphan intact | 4 cases (this is the inverse of replay_pending_orphan_inbox tests) |
| `replay_pending_orphan_inbox` | mli:244 | tested (3408,3427,3438) | concurrent live-inbox enqueue during replay (lock invariant) | second-thread enqueue race |
| `is_session_channel_capable` | mli:250 | tested at L9046,9067 | None (pre-Phase) registration → false default | unit |
| `set_automated_delivery` | mli:376 | tested (9053) | no-op when session unregistered (silent skip) | targeted no-op assertion |

### Sweep / dead-letter

| Function | Impl | Branches present | Branches uncovered | Proposed scenarios |
|---|---|---|---|---|
| `sweep` | L2623 | dead reg, orphan inbox, live preserved, pidless legacy/old/recent/alive, peer_offline emission, broadcast-after-unlock (`test_c2c_mcp.ml:3301-3338, 3356-3389, 3454+, 3781+, 3836+, 3852+, 3874+, 3912+, 3943+, 3976+, 4002+`) | sweep dead-letter `log_dead_letter_write` reason field paths beyond `inbox_sweep` (no other reason callers yet); sweep called twice in a row idempotency | dual-sweep noop test |
| `sweep` MCP tool dispatch | L5860 | none | tools/call wraps Broker.sweep correctly, returns shape | direct RPC test |
| `dead_letter_path` | mli:258 | none | direct value | trivial smoke |
| `append_dead_letter` | L2541 | only via sweep | direct call with explicit reason | unit |

### Rooms

| Function | Impl | Branches present | Branches uncovered | Proposed scenarios |
|---|---|---|---|---|
| `valid_room_id` | L2919 | implicit guard test in many places | **direct unit**: empty string, all special chars, mixed valid+invalid | small purity tests |
| `load_room_meta` / `save_room_meta` | L3043, 3049 | indirect | round-trip with empty `created_by` (legacy migration path); invited_members preserved on read after edit | round-trip unit |
| `create_room` | L3305 | public+auto_join, invite_only+invited, no-join, exists-errors (`test_c2c_mcp.ml:6723-6786`) | invalid_room_id rejection (L3307); empty `caller_alias` accepted-but-flagged | reject test |
| `join_room` | L3131 | creates, idempotent, broadcasts, invite_only accept/reject (`test_c2c_mcp.ml:4548+, 6668+, 6683+`) | invalid_room_id rejection; broadcast skip for idempotent same-session-different-alias rejoin | symmetry tests |
| `leave_room` | L3197 | basic remove (`test_c2c_mcp.ml:4708`), impersonation reject (6504) | invalid_room_id; non-member leave noop; broadcast leave message format | 2-3 cases |
| `delete_room` | L3215 | empty/has-members/legacy-needs-force/creator-only (`test_c2c_mcp.ml:4720+,8849+`) | invalid_room_id (L3216); missing room (L3219); files-cleanup on rmdir (verifies no leftover sidecars) | rejection + dir cleanup |
| `send_room_invite` | L3246 | adds to invite list, auto-DM, only-member, dup-DM-still-fires (`test_c2c_mcp.ml:6607-6655, 6624`) | invalid_room_id; auto-DM enqueue failure silently swallowed | invalid + simulated enqueue err |
| `set_room_visibility` | L3282 | changes mode, only-member can change (`test_c2c_mcp.ml:6700,6711,6843`) | invalid_room_id rejection | unit |
| `evict_dead_from_rooms` | L3376 | tested via sweep eviction (4151+) | dead_session_ids=[] && dead_aliases=[] short-circuit (L3382); rooms_dir missing (L3385) | empty-input + missing-dir |
| `prune_rooms` | L3436 | dead members, all-alive noop, pidless zombies, unverified-pid kept, orphan members (4199-4361) | concurrent prune+register race | second-thread test |
| `fan_out_room_message` | L3080 | implicit via send_room | tag-prefix-not-applied-to-history (already verified at 4928); skipped vs delivered list partitioning when half live half dead | mixed-liveness room |
| `send_room` | L3529 | dedup, no-dedup, tag, sender-skipped, fans-out, history (4752+) | invalid_room_id; very-long content; concurrent send_room from two senders (history dedup window collision) | 3 cases |
| `append_room_history` (public) | mli:345 | indirect | direct call invariant (returns ts, file persists) | 1 unit |
| `read_room_history` | L3472 | tested (5079, 5870, 5961, 5891) | invalid_room_id; `since` filter combined with `limit` boundary | combined-filter test |
| `room_history_path` | mli:344 | none | path shape | trivial |
| `list_rooms` / `my_rooms` | tested broadly | tested (5015, 5326, 8770, 8806) | `ri_member_details` rmi_alive `Unknown` arm wiring | unverified-pid member |

### DND / compacting / activity

| Function | Branches present | Branches uncovered | Notes |
|---|---|---|---|
| `set_dnd` (broker, mli:364) | exercised via tools/call set_dnd tests at 6888-7068 | direct broker call return-value (`bool option` for change-detection); `until` expiry semantics | direct unit |
| `is_dnd` | none direct | true/false readback after set; expired-until → false | unit |
| `set_compacting` (mli:366) | **none direct** | first-call vs second-call return value (`compacting option`) | unit |
| `is_compacting` (mli:365) | **none direct** | None vs Some readback | unit |
| `clear_compacting` (mli:367) | **none direct** | bool return; compaction_count increment | unit |
| `clear_stale_compacting` (mli:368) | **none direct** | clears flags >5min old; counter return | freshness-cutoff unit |
| `touch_session` | implicit | direct: idempotent advance forward only (never backwards) | unit |
| `compute_canonical_alias` (mli:147) | **none** | repo path → repo slug; localhost short hostname; long-path fallback | 3 cases |
| `pop_channel_test_code` (mli:427) | **none** | None when nothing pending; Some after registration generates one | 2 cases |

### Pending permissions (#432)

| Function | Branches present | Branches uncovered |
|---|---|---|
| `open_pending_permission` | per-alias-cap, expired-don't-count, concurrent (`test_c2c_mcp.ml:7857,7894,7624`) | global cap (1024) — per-alias hits first by test design but global arm of exception is unexercised |
| `find_pending_permission` | indirect via MCP tools | direct: missing perm_id → None |
| `remove_pending_permission` | indirect | direct + double-remove idempotency |
| `pending_permission_exists_for_alias` | tested via register guard (7534) | expired-entry-doesn't-count edge case |
| `write_allowed_signers_entry` (mli:397) | **none** | writes line; idempotent on duplicate alias; missing keys file fallback | needs synthesized ed25519 key fixture |

### Memory + send-memory handoff

| `notify_shared_with_recipients` | DMs recipients, skips self/unknown/empty/global (8446-8628) | enqueue raise inside `try` swallowed (8588 covers explicit error broker.log line, but not the underlying enqueue failure path itself with assertions) | inject enqueue failure via reserved-alias from_alias |

### Top-level (non-Broker) helpers

| `parse_send_tag` (mli:28) | **none** | (1) None → Ok None; (2) Some "fail"|"blocking"|"urgent" → Ok Some _; (3) other → Error | 4 trivial cases |
| `tag_to_body_prefix` (mli:12) | indirect via 4959 (uses fail prefix in assertion only) | direct equality on each tag → expected emoji prefix | 4 cases |
| `extract_tag_from_content` (mli:33) | indirect at 5073 | direct: bare content → None; unknown prefix → None; each known prefix → Some tag | 5 cases |
| `format_c2c_envelope` (mli:37) | **none** | optional tag/role/reply_via fields render correctly; ts default; XML escaping in content/role | 5+ cases |
| `parse_alias_list` (mli:123) | indirect | direct: `[]`, `[a, b]`, `a, b`, quoted entries, empty entries skipped | 5 cases |
| `channel_notification` (mli:420) | shape (422+), empty (436), special chars (452), no id (468), method (543), with role (556), without role (566) | nested Yojson string escaping under unicode in role field | unicode round-trip |
| `session_id_from_env` (mli:422) | tested (1391-1426) | client_type override → managed_codex/opencode/claude precedence under absent C2C_MCP_SESSION_ID | precedence matrix |
| `auto_register_startup` (mli:425) | tested (2188-2310) | unhandled error in PID lookup → exception swallowed; redelivery+register interleaving | combined dead-letter |
| `auto_join_rooms_startup` (mli:426) | tested (2403-2473) | malformed env value (random commas, whitespace); join failure for one room shouldn't abort siblings | partial-failure resilience |

### MCP `handle_request` dispatch (top-level RPC)

| Tool | Test | Notes |
|---|---|---|
| `sweep` | **NONE** at the RPC level (broker direct only) | propose: dispatch test asserting JSON shape `{dropped_regs, deleted_inboxes, preserved_messages}` |
| `stop_self` (positive case) | only impersonation rejection (6560) | stop_self own session → returns ok + side-effect on broker | needs careful side-effect isolation |
| `delete_room` | only impersonation reject (6452) | success via MCP RPC (not via Broker direct) | unit |
| `memory_write` / `memory_read` / `memory_list` MCP-tool path | **NONE in this test file** (lives elsewhere or in `test_c2c_memory.ml`) | confirm coverage in sister suite |
| `tail_log` | tested (5728) | filter by event-type | filter scenarios |
| `prompts/list`, `prompts/get` | subprocess tests (7089-7126) | only happy + unknown; no malformed-input | malformed JSON test |

---

## Proposed slicing

Each bullet sized to land in a single worktree slice (≤ ~6 hours of effort, ≤ 200 LOC of new test code, no production changes).

**HIGH priority** (security/correctness/visibility that bites the swarm):

- **Slice T-decrypt (HIGH).** `decrypt_envelope` branch matrix: 11 unit tests covering plain/box-x25519-v1, find_my_recipient hit/miss, missing nonce, decrypt-fail, sig-fail, key-mismatch, full-success. Also adds 1 `decrypt_message_for_push` smoke per branch. Receipts: `c2c_mcp.ml:4123-4202` (need to read full body), 4102-4116, 5687-5742.
- **Slice T-pin-branches (HIGH).** Cover `Already_pinned` + `Mismatch` for both pin_x25519_sync and pin_ed25519_sync. 4 tests. Receipts: `c2c_mcp.ml:1129-1149`.
- **Slice T-tag-histogram (HIGH).** Mirror delivery_mode_histogram coverage: 5 tests (counts, by_sender sort, last_n, min_ts, empty). Receipts: `c2c_mcp.ml:2367-2429`.
- **Slice T-reserved-aliases (HIGH).** Assert register + enqueue_message reject `c2c` and `c2c-system` from-alias. 4 tests. Receipts: `c2c_mcp.ml:1882-1884`, `c2c_mcp.ml:2017-2020`.

**MED priority** (correctness gaps that haven't bitten yet but are load-bearing):

- **Slice T-orphan-capture (MED).** Inverse of replay tests: `capture_orphan_for_restart` 4 cases (no-orphan, empty-orphan, non-empty captured, IO-fail-leaves-orphan-intact). Receipts: `c2c_mcp.ml:2822-2866`.
- **Slice T-compacting (MED).** `set_compacting` / `is_compacting` / `clear_compacting` / `clear_stale_compacting` direct broker tests, including compaction_count increment + 5min stale cutoff. Receipts: `c2c_mcp.ml:1805-1851` (search confirms set/clear bodies live there).
- **Slice T-room-edges (MED).** invalid_room_id rejection across `delete_room` / `leave_room` / `send_room_invite` / `set_room_visibility` / `read_room_history`; missing-room behavior; legacy `created_by=""` migration round-trip. ~8 tests. Receipts: room functions `c2c_mcp.ml:3197-3308`.
- **Slice T-canonical-alias (MED).** `compute_canonical_alias` 3 cases + `pop_channel_test_code` 2 cases + `parse_alias_list` 5 cases + `parse_send_tag` 4 cases + `tag_to_body_prefix` direct 4 cases + `extract_tag_from_content` direct 5 cases. ~23 tests but each is one-liner. Receipts: `c2c_mcp.ml:1722, 384, 400, 417, 467`.
- **Slice T-handle-request-dispatch (MED).** Add MCP tools/call dispatch tests for `sweep`, `delete_room` happy path, `stop_self` happy path. 3 tests. Receipts: `c2c_mcp.ml:5860, 6052, 6562`.

**LOW priority** (footguns, defensive):

- **Slice T-format-envelope (LOW).** `format_c2c_envelope` rendering matrix (tag/role/reply_via combos, content escaping). ~6 tests. Receipts: `c2c_mcp.ml:438-466`.
- **Slice T-archive-rollback (LOW).** drain_inbox + archive IO failure invariant. Requires fault-injection harness (write barrier on archive_lock_path). 1-2 tests, more infra than tests. Receipts: `c2c_mcp.ml:2445-2465`.
- **Slice T-min-ts (LOW).** Add `min_ts` coverage to `delivery_mode_histogram`; combo-filter with `last_n`. 2 tests.
- **Slice T-load-corruption (LOW).** Malformed `registry.json`, `inbox.json`, `room_meta.json` recovery: each should degrade to "empty" or "default-meta" rather than crash. ~5 tests.

---

## Receipts trail

- `ocaml/c2c_mcp.mli:1-431` — public API surface inventory
- `ocaml/c2c_mcp.ml:384-466` — tag helpers (`tag_to_body_prefix`, `extract_tag_from_content`, `parse_send_tag`, `format_c2c_envelope`)
- `ocaml/c2c_mcp.ml:746,817,1212` — `load_registrations` / `save_registrations` / `list_registrations`
- `ocaml/c2c_mcp.ml:1103-1149` — `pin_x25519_if_unknown` / `pin_x25519_sync` / `pin_ed25519_*`
- `ocaml/c2c_mcp.ml:1160-1211` — `write_allowed_signers_entry`
- `ocaml/c2c_mcp.ml:1502-1584` — `resolve_live_session_id_by_alias`
- `ocaml/c2c_mcp.ml:1722` — `compute_canonical_alias`
- `ocaml/c2c_mcp.ml:1774-1851` — DND / compacting setters
- `ocaml/c2c_mcp.ml:1881-2008` — `register`
- `ocaml/c2c_mcp.ml:2015-2071` — `enqueue_message` (incl. remote-outbox + reserved-alias guard)
- `ocaml/c2c_mcp.ml:2072-2103` — `send_all`
- `ocaml/c2c_mcp.ml:2105-2295` — read_inbox / save_inbox / archive
- `ocaml/c2c_mcp.ml:2296-2429` — `delivery_mode_histogram` + `tag_histogram`
- `ocaml/c2c_mcp.ml:2445-2480` — `drain_inbox` / `drain_inbox_push`
- `ocaml/c2c_mcp.ml:2519-2570` — `log_dead_letter_write`, `append_dead_letter`
- `ocaml/c2c_mcp.ml:2598-2706` — `peer_offline_*`, `sweep`
- `ocaml/c2c_mcp.ml:2792-2918` — orphan inbox capture + replay
- `ocaml/c2c_mcp.ml:2919-3290` — room functions (valid_room_id, meta, fan_out, join, leave, delete, invite, set_visibility)
- `ocaml/c2c_mcp.ml:3305-3375` — `create_room`
- `ocaml/c2c_mcp.ml:3376-3470` — eviction + prune_rooms + room_history
- `ocaml/c2c_mcp.ml:3529-3570` — `send_room`
- `ocaml/c2c_mcp.ml:3690-3850` — registration confirmation + touch_session + set_automated_delivery
- `ocaml/c2c_mcp.ml:4050-4083` — `notify_shared_with_recipients`
- `ocaml/c2c_mcp.ml:4085-4101` — `channel_notification`
- `ocaml/c2c_mcp.ml:4102-4202` — `decrypt_message_for_push` + `decrypt_envelope`
- `ocaml/c2c_mcp.ml:5687-5742` — inline poll_inbox decrypt copy (twin of decrypt_envelope)
- `ocaml/c2c_mcp.ml:5860, 6052, 6270, 6299, 6562` — MCP RPC dispatch sites for sweep/delete_room/send_room_invite/set_room_visibility/stop_self
- `ocaml/test/test_c2c_mcp.ml:243-321` — delivery_mode_histogram tests (mirror target for tag_histogram)
- `ocaml/test/test_c2c_mcp.ml:8004-8141` — pin tests (extension target for `Already_pinned`/`Mismatch`)
- `ocaml/test/test_c2c_mcp.ml:9151-9498` — peer-PASS H2/H2b indirect e2e coverage of decrypt path
- `ocaml/test/test_c2c_mcp.ml:8446-8678` — notify_shared_with_recipients coverage
- `ocaml/test/test_c2c_mcp.ml:3389-3454` — orphan replay tests (capture half is the gap)
- `ocaml/test/test_c2c_mcp.ml:6888-7068` — set_dnd MCP tool tests (broker-direct gaps remain)

---

End of audit. No code changes proposed. Recommended next step: take `Slice T-decrypt`, `Slice T-pin-branches`, `Slice T-tag-histogram`, `Slice T-reserved-aliases` as the first peer-PASS-able batch.
