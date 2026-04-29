# Outbox + Relay State-Machine Audit (2026-04-29)

**Author**: stanza-coder
**Scope**: Connector / relay / managed supervisor / E2E layer / doctor / runbook
**Seed commit**: `b0813b3d` (outbox TTL/max-attempts/DLQ landing) — broader sync loop has grown organically; this pass enumerates remaining sharp edges. No code changes; recommendations are sliceable.

Severity legend: HIGH = data loss / silent corruption, MEDIUM = operator surprise / debug pain, LOW = nit / cleanup.

---

## F1 — `write_outbox` truncate-rewrite + `write_json_file` skip `fsync` (HIGH)

`ocaml/c2c_relay_connector.ml:343-370` (`write_outbox`) opens with `open_out` (truncate), writes, then `close_out` — no `fsync` of file or parent dir before the next sync cycle. `ocaml/c2c_mcp.ml:517-546` (`write_json_file`) is similarly tmp+rename only — atomic against partial writes at process exit, but a power-loss / hard-reboot between rename and disk-flush can lose the entire rewritten outbox (or inbox). For the outbox specifically, this is the *only* durable record of an in-flight relay-bound message: lose it post-rename and the `attempts` counter resets to whatever was previously persisted, plus N freshly-enqueued messages disappear.

**Proposed slice**: add `Unix.fsync fd` before `close` (and an `Unix.openfile` of the parent dir + `fsync` for rename durability) in both `write_outbox` and `write_json_file`. Gate behind `C2C_FSYNC=0` for tests (perf cost on btrfs/ext4 is ~1ms per write).

---

## F2 — `append_outbox_entry` is a non-locked append (HIGH)

`ocaml/c2c_relay_connector.ml:414-432` opens the outbox with `Open_append` and writes a single line **without taking `with_outbox_lock`**. The header comment at line 277-281 promises `with_outbox_lock` "compatible with any other Unix flock holder on the same sidecar," but `append_outbox_entry` itself bypasses it. If a connector sync cycle is mid-`read_outbox → write_outbox`, an MCP `send` calling `append_outbox_entry` writes a line into a file that's about to be truncated — silent message loss, exactly the TOCTOU the lock was added to fix. (Single POSIX `write()` of a short JSON line is atomic at the kernel level, so no partial-line corruption — but the line is still discarded by the next `write_outbox`.)

**Proposed slice**: wrap `append_outbox_entry`'s body in `with_outbox_lock`. Add a unit test that interleaves an append between `read_outbox` and `write_outbox` and asserts the appended entry survives.

---

## F3 — Registration / heartbeat retries are unbounded (HIGH)

`ocaml/c2c_relay_connector.ml:734-752` retries failed register/heartbeat **on every sync cycle, forever**. There is no `attempts` counter, no `max_age`, no exponential backoff, no DLQ — only the outbox got that treatment in `b0813b3d`. A relay returning `alias_conflict` or `alias_identity_mismatch` (both permanent — see `relay_err_*` codes in `relay.ml:11-12`) loops until the operator notices, hammering `/register` at the connector's `interval` (30s default) and producing a noisy `last_error` on every sync line. Worse: `alias_conflict` retries can win the race and accidentally bump out a healthy peer that just re-registered.

**Proposed slice**: classify register/heartbeat errors the same way `classify_error` does for sends. Permanent codes (`alias_conflict`, `alias_identity_mismatch`, `alias_not_allowed`) → mark the session as "registration-failed" with an exponential-backoff timer + structured log; ephemeral (`connection_error`) → bounded retry with jitter. Surface the failed-registration set in `c2c doctor` so an operator can see it.

---

## F4 — Relay-side re-registration strands inbox messages (HIGH)

`ocaml/relay.ml:685` replaces `t.leases[alias]` with a new lease keyed by the new `(node_id, session_id)`, then `relay.ml:689-690` ensures a fresh inbox under the new key. The old inbox (keyed by the old node/session pair) is **not migrated**. Any messages queued during the gap — the exact stale-lease scenario in the audit prompt — are stranded under an inbox key no client will ever poll. They survive only until the GC sweep at `relay.ml:1220-1224` deletes them as `stale_keys`, at which point they vanish without a dead-letter trail. (`SqliteRelay` has the same shape — see the inbox SELECTs at `relay.ml:1492` keyed by `(node_id, session_id)`.) Local broker has the matching migration at `c2c_mcp.ml:1972-1992`; relay does not.

**Proposed slice**: in `register`, when an existing lease for the alias is being replaced and `(old_node_id, old_session_id) <> (new_node_id, new_session_id)`, splice the old inbox into the new key before evicting. Add a peer-PASS test: register A → enqueue 3 msgs → A re-registers with new session → poll new session, assert 3 msgs.

---

## F5 — Connector resets `attempts` to 1 in `append_outbox_entry`, ignoring history (MEDIUM)

`ocaml/c2c_relay_connector.ml:425` hardcodes `"attempts", 'Int 1` in fresh outbox entries. That's correct for new sends, but `append_outbox_entry` is also the path the broker uses on every remote send — there's no "this is a re-enqueue" path. Combined with F2 (unlocked append), if a sync cycle DLQs an entry and the next remote `send` to the same alias is enqueued seconds later, the new entry starts fresh at `attempts=1`. That's actually the intended behavior, but it creates an indistinguishable retry-storm shape on the wire if a sender is both retrying-from-the-app and the connector is also retrying — the relay sees N copies of the same message-pattern. Not corruption — operator surprise + cost on a flaky relay.

**Proposed slice**: dedupe `append_outbox_entry` against existing `(from, to, content)` (or even just `message_id` when set) to avoid double-queueing. If `message_id` is unset, generate one at enqueue time so the relay-side dedup window catches the dupes. Currently `message_id` is `?optional`; make it required (helper to mint UUID).

---

## F6 — DLQ is append-only with zero coalescing or rotation (MEDIUM)

`ocaml/c2c_relay_connector.ml:373-397` (`append_dlq_entry`) opens with `Open_append; Open_creat` and does not check size. The runbook (`.collab/runbooks/remote-relay-operator.md:380`) acknowledges this: *"a typo alias retrying every 30s produces one new DLQ entry per retry"* — except for `unknown_alias` / `recipient_dead`, which post-`b0813b3d` are immediate-DLQ no-retry. So the runbook is **stale** for those codes, but **still correct** for `connection_error → max_attempts` (60 attempts × 30s = 30 minutes of identical entries before reason flips). DLQ has no rotation, no compaction, no retention TTL. A broker that's been online for months with a flaky upstream relay accumulates an unbounded `remote-outbox-dlq.jsonl`.

**Proposed slice**: (a) update runbook §6 to reflect immediate-DLQ for permanent codes; (b) add `c2c doctor outbox-dlq` that summarizes by `(to_alias, reason)` and reports total bytes; (c) add an optional retention sweep (default off) that deletes entries older than 7d when run.

---

## F7 — Inbound-poll has no per-session backpressure (MEDIUM)

`ocaml/c2c_relay_connector.ml:796-811` polls every registered session every cycle and `append_to_local_inbox` (`:98-116`) just `existing @ messages` — unbounded growth. If a relay-pool peer is faster than the local agent's drain rate (compacting agent, slow MCP polling, OOM-paused harness) the local inbox grows linearly. There's no high-water-mark, no `nudge_after_n` to push, no stop-polling-from-relay backpressure. `read_local_registrations` could fail to reflect a session that's gone unreachable — meanwhile the connector keeps draining the relay's queue into a JSON file the agent can't read because the agent is dead.

**Proposed slice**: cap per-session inbox at e.g. 500 messages (configurable via `C2C_LOCAL_INBOX_CAP`); on overflow, stop draining from the relay (leave messages on the relay so the relay's own DLQ/lease policy applies) and surface a `c2c doctor` warning. Pair with a `last_drained_ts` exposed on the registry so the connector can detect "session hasn't drained in N min, skip its remote poll."

---

## F8 — `relay_pins.json` operator-rotation only; no programmatic invalidate path (MEDIUM)

`ocaml/c2c_mcp.ml:920-1114` documents the operator interface: delete `relay_pins.json` to wipe pins. That's clean for human operators. But the connector itself has **no programmatic invalidate** — if the connector observes a `key-changed` envelope from the relay (Relay_e2e returns `Key_changed` per `relay_e2e.ml:18`), there is no surface to clear *just that one alias's* pin. The downgrade-to-rotation path is currently "tell a human to `rm relay_pins.json`," which nukes every pin including the unaffected ones. Adversarial implication: an attacker who can flip one alias's keys forces the operator into a TOFU reset for every peer in the swarm.

**Proposed slice**: expose `c2c doctor relay-pins clear --alias X` (CLI) + `Broker.clear_pinned_x25519 ~alias` / `clear_pinned_ed25519 ~alias` (programmatic) so per-alias re-TOFU is possible. The connector can call this on a confirmed `Key_changed` after surfacing the alarm to the recipient.

---

## F9 — Managed supervisor has no auto-restart loop (MEDIUM)

`ocaml/cli/c2c_relay_managed.ml:16-21` is explicit: *"Auto-restart NOT implemented in v1. The connector is a single long-running process. If it crashes the user re-runs `c2c start relay-connect`."* Translation: a daemonized connector that segfaults / OOMs / panics on a malformed relay response **stays dead**, with no observability on the operator side beyond `c2c instances` showing it's gone. The pidfile at `outer.pid` becomes stale; the next `start` refuses with "already running" if the kernel happens to recycle that PID to anything alive (unlikely but possible). And in-flight outbox entries accumulate via MCP → `append_outbox_entry` while no connector is draining them — they sit there until the operator notices.

**Proposed slice**: minimal respawn loop in `start` daemon mode — fork a watchdog parent that re-execs the connector on non-zero exit with bounded backoff (1s → 60s, capped). Or wire to systemd-style supervision via `c2c supervisor` group (already exists in the CLI per `c2c.ml:10016`).

---

## F10 — Relay-side `register_nonces` Hashtbl GC is opportunistic, not bounded (MEDIUM)

`ocaml/relay.ml:840-846` (`check_nonce_in`) prunes expired nonces inline on each call: `Hashtbl.iter ... if t0 < cutoff then expired := n :: !expired`. That's O(N) where N is the table size — fine for small N, but if an attacker (or a buggy connector) pumps registrations with random nonces faster than the prune cadence catches up, the table grows unbounded between nonces of the same age, and every `check_register_nonce` becomes O(table-size). There's no max-size cap, no FIFO eviction. SqliteRelay version (`relay.ml:1643-1649`) has the same shape with `DELETE FROM register_nonces WHERE ts < ?` which is at least O(log N) on the index, but still no cap.

**Proposed slice**: cap `register_nonces` at e.g. 100k entries; on overflow, evict lowest-ts batch. Add a metric exposed via `/health` (`nonce_table_size`) so operators can see runaway. Same treatment for `request_nonces`.

---

## F11 — `relay_pins.json` write-through cache amplifies disk I/O on every TOFU read (LOW)

`ocaml/c2c_mcp.ml:1079-1096`: every `get_pinned_*` and `set_pinned_*` call takes `with_relay_pins_lock` AND re-loads the entire JSON from disk before answering. Correct (matches operator-rotation semantics), but expensive if a hot path calls `get_pinned_x25519` per inbound envelope. Under sustained delivery, that's one fopen+parse per message just to consult an in-memory Hashtbl that *would* be authoritative if not for the operator-delete contract.

**Proposed slice**: track an `mtime`-stamped cache: re-load only if the on-disk `mtime` changed (one `Unix.stat` instead of full file parse). Operator-delete still works because removing the file changes the dirfd state. Bench against current implementation; ship only if the savings are significant on a swarm-scale workload.

---

## F12 — `c2c doctor delivery-mode` over-reports push-intent under deferrable=false but ephemeral=true (LOW)

`ocaml/cli/c2c.ml:6478-6501` histograms by sender intent (deferrable flag at write time). `c2c_mcp.ml:54` declares `ephemeral : bool` as a peer field of `deferrable`. Ephemeral messages are *excluded from archive* (per the doc footer), so they don't show up — that's correct. But the footer note (line 6498-6501) says *"counts measure sender intent (deferrable flag), not which delivery path actually surfaced the message."* It does NOT call out the asymmetry that ephemeral=true is silently invisible — an operator who sees `push_intent: 0` for sender X might mistakenly conclude X never DMs, when in fact X always sends ephemeral. Minor, but a known dogfooding pothole on a tool whose entire reason for existing is observability.

**Proposed slice**: add a third bucket "ephemeral (uncounted)" estimated from `c2c_mcp.archive`'s ephemeral filter — even if it's just a placeholder log line "(ephemeral msgs excluded; X sent N in window per broker.log)." Smaller version: append the caveat to the printed footer ("ephemeral counts not shown") + JSON `caveats` already lists it. Currently the JSON does (`ephemeral_excluded`); the human output doesn't surface it as visibly as it should.

---

## F13 — `peer_relays` table is wired but `cross_host_not_implemented` is unconditional (MEDIUM)

`ocaml/relay.ml:423-440` defines `peer_relay_t` and full accessor surface (`add_peer_relay`, `peer_relay_of`, `peer_relays_list`); both `InMemoryRelay` (`:602-604`) and `SqliteRelay` (`:1314-1317`) implement them. But `handle_send` at `relay.ml:3197-3216` rejects every cross-host send with `cross_host_not_implemented` and writes a dead-letter — **without consulting `peer_relays_list` to see if `host_opt` resolves to a known peer relay**. The whole `peer_relays` table is dead code as far as message forwarding goes. This is #330 Slice 1 (registration only), but the user-visible behavior is a confusing "you wired up `--peer-relay foo=https://...` and the relay still rejects sends to `alias@foo`". Documentation surface is also missing — `remote-relay-operator.md` doesn't mention peer-relay setup at all.

**Proposed slice**: either (a) implement Slice 2 — `handle_send` consults `peer_relay_of ~name:host_opt` and forwards via HTTP POST `/send` to that peer's URL with the peer's identity_pk in Authorization, or (b) remove the dead `peer_relays` accessor surface until it's actually wired, to reduce confusion. Whichever way, doc the decision in the runbook.

---

## F14 — Cross-process handoff: managed restart doesn't propagate `attempts` correctly on stale outbox (LOW)

When `c2c stop relay-connect` followed by `c2c start relay-connect` happens (managed supervisor flow at `c2c_relay_managed.ml`), the new process reads the existing `remote-outbox.jsonl` via `read_outbox` (`c2c_relay_connector.ml:304-341`). The legacy-compat path (`:328-334`) defaults `attempts=0` and `enqueued_at=now` for entries missing those fields. That's fine for the upgrade transition, but it also means: a kill -9 mid-write that leaves a partial line (which `read_outbox` silently swallows at `:339`) loses both the attempts counter and the original enqueue time for *that* entry only — the next replay from the new process will treat it as fresh. Combined with F1 (no fsync), there's a small window where a fault corrupts only the latest record's metadata but not the message body — which then survives forever in retry-land because its clock keeps resetting.

**Proposed slice**: log an explicit warning in `read_outbox` when a legacy-or-corrupt line is silently swallowed (`Printf.eprintf "[outbox] skipped malformed line at offset N"`), so the operator sees the event. Combined with F1 fsync, this becomes vanishingly rare; today it's fully invisible.

---

## Summary table

| # | Severity | Surface | One-line |
|---|---|---|---|
| F1 | HIGH | connector + broker | tmp+rename without fsync — power-loss loses outbox/inbox |
| F2 | HIGH | connector | `append_outbox_entry` skips `with_outbox_lock` — TOCTOU truncate clobbers appends |
| F3 | HIGH | connector | register/heartbeat retries are unbounded — permanent errors hammer relay forever |
| F4 | HIGH | relay | re-register replaces lease without inbox migration — messages strand |
| F5 | MEDIUM | connector | `append_outbox_entry` always sets attempts=1, no msg_id dedup → silent dupes |
| F6 | MEDIUM | connector + runbook | DLQ is append-only no rotation; runbook §6 stale on retry behavior |
| F7 | MEDIUM | connector | inbound poll has no per-session inbox cap → unbounded growth |
| F8 | MEDIUM | broker | relay_pins.json: no per-alias programmatic invalidate, only nuke-everything |
| F9 | MEDIUM | managed | supervisor has no auto-restart; crashed connector stays dead |
| F10 | MEDIUM | relay | nonce tables uncapped; O(N) prune per call |
| F11 | LOW | broker | relay_pins.json read-through reloads on every TOFU read |
| F12 | LOW | doctor | delivery-mode footer doesn't visibly surface ephemeral exclusion |
| F13 | MEDIUM | relay | peer_relays accessor surface is dead until #330 S2 wires forwarding |
| F14 | LOW | connector | `read_outbox` silently drops malformed lines — invisible corruption |

## Top-5 Recommended Slice Ordering

1. **F2** (HIGH, ~30min) — wire `with_outbox_lock` into `append_outbox_entry`. Trivial, high-value, blocks data-loss racing.
2. **F4** (HIGH) — relay-side re-registration inbox migration. Mirror the broker-side fix from `c2c_mcp.ml:1972-1992`.
3. **F3** (HIGH) — bounded register/heartbeat retries. Reuse the F1/outbox classifier; permanent-vs-transient surface already exists.
4. **F1** (HIGH) — fsync on outbox/inbox/registry writes. Cheap insurance; gate via env flag for tests.
5. **F9** (MEDIUM) — managed supervisor respawn loop. Otherwise F1-F4 are Pyrrhic — nobody's running the connector when it dies.

F8 (per-alias pin invalidate), F13 (peer_relay forwarding), and F6 (DLQ rotation) are the next batch — operator-quality-of-life rather than correctness.
