# Cross-host routing audit — galaxy DM misdelivery

**Filed:** 2026-04-29 (stanza-coder, in response to galaxy's finding)
**Scope:** read-only audit. Bug: `to_alias=galaxy-coder` delivered to `cedar-coder`.

## Code paths walked

### 1. MCP `send` arm — `ocaml/c2c_mcp.ml:4728-4906`

Argument extraction at L4729: `let to_alias = string_member_any [ "to_alias"; "alias" ] arguments`.
Self-send guard at L4749 (`from_alias = to_alias`). After tag/encryption massaging, the actual delivery is:

```
Broker.enqueue_message broker ~from_alias ~to_alias ~content ...   (L4906)
```

`to_alias` is **never rewritten** between MCP entry and `enqueue_message`. No `@host` stripping, no fallback resolution. So local-only path is solely about `enqueue_message` semantics.

Sidebar lookups at L4779, L4786, L4916, L4922 — each does `List.find_opt (fun r -> r.alias = to_alias)` on the registry to fetch enc_pubkey / dnd / compacting. **Case-sensitive structural equality.** Returns the *first* match in registry-file order regardless of liveness.

### 2. `Broker.enqueue_message` — `ocaml/c2c_mcp.ml:1689-1733`

Branches:
1. Reserved sender check (L1692).
2. **`is_remote_alias to_alias`** (L1695) — true iff `to_alias` contains `@`. Routes to `C2c_relay_connector.append_outbox_entry` (L1700). No host part validation here; ANY '@' goes to the outbox.
3. Otherwise: `resolve_live_session_id_by_alias` (L1703), then write to that session's inbox.

### 3. `resolve_live_session_id_by_alias` — `ocaml/c2c_mcp.ml:1206-1253`

```
let matches = load_registrations t |> List.filter (fun reg -> reg.alias = alias) in
match matches with
| [] -> Unknown_alias
| _ -> let alive_reg = List.find_opt registration_is_alive matches in ...
```

**Case-sensitive equality.** If multiple registrations share the alias, returns the first alive one in registry order, else attempts pid-refresh self-heal across all candidates.

### 4. `register` — `ocaml/c2c_mcp.ml:1555-1667`

Eviction uses `alias_casefold reg.alias = alias_casefold alias` (L1572). **Case-INSENSITIVE.** Evicts other-session entries that case-fold-match the new alias and migrates their inboxes (L1646-1666). Same-session re-register updates in place.

### 5. Cross-host (`split_alias_host` / `host_acceptable`) — `ocaml/relay.ml:406-421, 3163-3191`

```
let split_alias_host s =
  match String.index_opt s '@' with
  | None -> (s, None)
  | Some i -> (String.sub s 0 i, Some (...)
```

`handle_send` at L3171: splits, checks host_acceptable, on rejection writes `cross_host_not_implemented` dead_letter (post #379 fix `492c052b`). On accept: calls `R.send relay ~to_alias:stripped_to_alias` — i.e. **strips `@host` before lookup**.

`InMemoryRelay.send` (L874-908) is `Hashtbl.find_opt t.leases to_alias` — a single hash lookup. If two leases both register the bare alias `galaxy-coder` they'd race for the hashtable slot (`Hashtbl.replace` semantics).

## Hypothesis ranking

### MOST LIKELY: H1' — stale registry entry with `alias=galaxy-coder` pointing at cedar's session_id

`register` only evicts entries whose alias **case-folds to the new alias** (L1572). If cedar's session at some prior point registered as `galaxy-coder` and later re-registered as `cedar-coder`, the eviction filter on cedar's *new* alias (`cedar-coder`) does NOT touch the stale `galaxy-coder`-aliased row. The same-session-update branch at L1623-1636 only touches rows where `reg.session_id = session_id`, so it WOULD update cedar's old `galaxy-coder` row → `cedar-coder` in place. Good.

BUT: the in-place update is gated on `List.partition (fun reg -> reg.session_id = session_id) rest`. `rest` is the post-conflicting filtered list. If cedar's old `galaxy-coder` row survived (because no conflict on the new alias), it *is* in `rest`, and the partition catches it → in-place rename. So pure rename is safe.

Where this breaks: **a fresh session_id**. If cedar restarted with a NEW session_id (kimi/codex one-shot child inheriting a different `C2C_MCP_SESSION_ID`, or post-compact PID flip with stale registry row), the old row (`alias=galaxy-coder, session_id=OLD_CEDAR_SID`) sits in `rest` un-touched because partition finds no row with the new session_id. New cedar registers as `cedar-coder` → both rows persist. Now `resolve("galaxy-coder")` (L1208) returns the OLD cedar row's session_id, which `registration_is_alive` may stamp alive via the pid-refresh self-heal at L1228-1244 (which scans `/proc` and re-binds). Result: `to_alias=galaxy-coder` resolves to cedar's session.

**Concrete code evidence:** L1572 case-fold eviction is keyed on the NEW alias only; never sweeps "any row with my session_id but a different alias claimed by someone else." Combined with `refresh_pid_if_dead` at L1234 (which can flip a stale row to "alive" by binding it to a live pid found in /proc), a stale `galaxy-coder`→cedar_sid row can resurrect.

This matches galaxy's finding exactly: "isolated incident — other DMs to galaxy-coder have arrived correctly" (the row only mismatched in this window; subsequent registry mutations cleared it).

### LIKELY: H1 — straight alias collision (two live `galaxy-coder` regs)

`resolve_live_session_id_by_alias` returns the first alive match. If galaxy and cedar were both registered with `alias = "galaxy-coder"` (cedar typoed during register, or kimi-style env-var leak), case-sensitive filter at L1208 picks them both up; first alive wins. Unlike H1', this requires cedar to have explicitly registered as `galaxy-coder` — possible (alias auto-pick collision pre-existing) but less likely given alias-pool randomness.

### LESS LIKELY: H3 — alias-rename window

Less likely because rename inside the same session updates in place under the registry lock (L1559 `with_registry_lock`). A concurrent reader in the lock would see consistent state. Cross-session rename DOES evict (L1646-1666) and migrates inbox under both locks — no obvious race. Only failure mode: if two registrations existed before the lock was taken (i.e. pre-existing ambiguity), but that's H1/H1'.

### LEAST LIKELY: H2, H4 — cross-host strip / Lwt closure

H2 (cross-host strip): if galaxy's send went `to_alias=galaxy-coder@some-host`, the relay path would split, check `host_acceptable`, then call `R.send` with the bare alias. But the misdelivery happened on the **local broker** (stanza→galaxy local DM). `is_remote_alias` (L1687) only triggers on `@` in `to_alias`; stanza sent the bare `galaxy-coder` per the finding.

H4 (Lwt promise closure): `enqueue_message` is synchronous OCaml under `with_registry_lock`. No promise capture of stale alias mappings.

## Fix sketch (for H1'/H1)

1. **Make `resolve_live_session_id_by_alias` case-insensitive** (`c2c_mcp.ml:1208`):
   `List.filter (fun reg -> alias_casefold reg.alias = alias_casefold alias)` —
   matches the eviction predicate, eliminating asymmetry.
2. **Add a registry invariant assertion at `save_registrations`**: no two alive entries share `alias_casefold reg.alias`. Log + drop the older one.
3. **Eviction sweep on register should be bilateral**: when session S registers as alias A, also drop any *other* row where `session_id = S` (catches "old row from prior alias claim still tagged with my SID after a different agent took the alias"). Probably already handled by the same-session partition at L1623, but worth an explicit assertion.
4. **Diagnostic**: log when `resolve` finds >1 candidate row at L1207 — silent multi-match is the smoking gun for both hypotheses.
5. **Mirror sidebar lookups** at L4779/4786/4916/4922 should use `resolve_live_session_id_by_alias` (or a casefold list filter), not raw `r.alias = to_alias`. Currently they can disagree with the resolver's choice — e.g. enc-pubkey fetched from a dead row while the inbox write goes to an alive row.

## Recommended next step

Pull `broker.log` + the registrations file (`<broker_root>/registrations.yaml`) snapshotted around the misdelivery timestamp. Look for:
- two rows with `alias: galaxy-coder` (or one casefold-equal variant)
- cedar's session_id appearing on a `galaxy-coder` row
- multiple entries with the same session_id

If the registry shows duplicate galaxy-coder rows, H1'/H1 confirmed. Add the casefold fix + invariant check.

## Files cited

- `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml` (lines 1206-1253, 1523-1581, 1555-1667, 1689-1733, 4728-4906)
- `/home/xertrov/src/c2c/ocaml/relay.ml` (lines 406-421, 874-908, 3163-3191)
- `/home/xertrov/src/c2c/ocaml/c2c_relay_connector.ml` (line 319 `append_outbox_entry`)
- `/home/xertrov/src/c2c/.collab/findings/2026-04-29T-galaxy-coder-dm-misdelivery.md`
- `/home/xertrov/src/c2c/.collab/findings/2026-04-29T05-00-00Z-galaxy-coder-379-handle-send-silent-drop.md`
- Commits `492c052b`, `4450cf56` (#379 dead_letter fix — orthogonal to misdelivery)
