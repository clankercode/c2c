# Alias casefold-symmetry audit — extended sweep (post c2c_mcp.ml)

- author: slate-coder
- date: 2026-04-29 15:10 UTC
- companion to: e3c6aba0 / b8ca6cb0 (c2c_mcp.ml `pending_permission_exists_for_alias` + sibling fix; sweep closed)
- scope: all OCaml `.ml` files OUTSIDE `ocaml/c2c_mcp.ml` that handle alias strings
- discipline: audit-only (no code modified)

## 1. Summary

26 alias-comparison sites audited across the in-scope tree. Findings:

- VULNERABLE: 13 (split below)
  - HIGH:   0
  - MEDIUM: 8 (DoS / false-negative auth or privacy guards)
  - LOW:    5 (cosmetic — role attribution, self-send hint, compacting hint)
- CORRECT (already case-fold via `String.lowercase_ascii`): 5 (peer_review.ml — H1 trust pin + H2 reviewer match)
- CORRECT-BY-CONSTRUCTION: 0 — no in-scope site relies on a case-canonicalized
  source other than the peer_review explicit casefold helpers.
- N/A (false positives from grep — Cmdliner `and+ alias = alias`, value bindings,
  diagnostic counters): 8

**Headline:** no HIGH-severity takeover/auth-bypass holes outside the closed
c2c_mcp.ml sweep. The remaining hits are dominated by **DoS-class
false-negatives** (legitimate operations denied when alias case differs from
how the row was registered) and **cosmetic role-attribution misses** in the
four "lookup sender role for envelope" sites.

The most operationally consequential MEDIUMs:

1. `cli/c2c.ml:814` — `List.mem reply_from pending.supervisors` permission-reply auth check.
2. `cli/c2c_memory.ml:296` / `cli/c2c_memory.ml:298` — privacy guard self-read + shared_with allow check.
3. `cli/c2c_memory.ml:151` / `:159` — grant/revoke ACL list maintenance.
4. `cli/c2c.ml:5876` — `clean_stale_protected_aliases` safety guard for
   `c2c instances clean-stale`.
5. `relay_e2e.ml:233` — recipient lookup in encrypted envelope (legitimate
   ciphertext drops on case mismatch).

`Broker.alias_casefold` is **not** exported in `c2c_mcp.mli`, so callers
outside `c2c_mcp.ml` cannot reuse it directly today. Any fix that migrates
external callers to a shared helper has to either (a) export the helper
through the .mli, or (b) inline `String.lowercase_ascii a = String.lowercase_ascii b`
at the comparison site (peer_review.ml's existing pattern).

## 2. Method

Greps run from repo root (`/home/xertrov/src/c2c`):

```
grep -rn "alias_casefold" ocaml/                                   # baseline contrast
grep -nE 'String\.equal\s+.*alias' ocaml/ -r
grep -nE '\b(alias|to_alias|from_alias|peer_alias|sender_alias|target_alias|owner_alias|recipient_alias)\b\s*=\s*\b(alias|to_alias|from_alias|peer_alias|sender_alias|"[a-z][a-z0-9_-]+")' ocaml/ -r
grep -nE 'r\.C2c_mcp\.alias\s*=|reg\.alias\s*=|\.alias\s*=' <every in-scope file>
grep -nE 'List\.(filter|find_opt|find|exists|mem|partition).*alias' <every in-scope file>
grep -nE 'if\s+\w*alias\w*\s+=\s+\w*alias\w*' <every in-scope file>
grep -nE 'requester_alias|supervisors|caller_alias|created_by' <every in-scope file>
```

Files inspected (in scope per task brief):

- `ocaml/c2c_start.ml`
- `ocaml/relay.ml`
- `ocaml/c2c_relay_connector.ml`
- `ocaml/c2c_wire_bridge.ml`
- `ocaml/c2c_wire_daemon.ml`
- `ocaml/peer_review.ml`
- `ocaml/relay_e2e.ml`, `relay_enc.ml`, `relay_identity.ml`, `relay_nudge.ml`,
  `relay_ratelimit.ml`, `relay_remote_broker.ml`, `relay_short_queue.ml`,
  `relay_signed_ops.ml`, `relay_ws_frame.ml`
- `ocaml/server/c2c_mcp_server_inner.ml`
- `ocaml/tools/c2c_inbox_hook.ml`
- `ocaml/cli/c2c.ml` (large surface — 9.5k+ lines)
- `ocaml/cli/c2c_setup.ml`, `c2c_rooms.ml`, `c2c_memory.ml`, `c2c_coord.ml`,
  `c2c_history.ml`, `c2c_stats.ml`, `c2c_peer_pass.ml`, `c2c_worktree.ml`,
  `c2c_agent.ml`, `c2c_broker_root_check.ml`, `c2c_commands.ml`,
  `c2c_docs_drift.ml`, `c2c_git_shim.ml`, `c2c_migrate.ml`,
  `c2c_opencode_plugin_drift.ml`, `c2c_relay_managed.ml`, `c2c_signing_helpers.ml`,
  `c2c_sitrep.ml`, `c2c_stickers.ml`, `c2c_utils.ml`, `c2c_types.ml`,
  `role_designer_embedded.ml`, `role_templates.ml`

Out of scope and skipped: `ocaml/c2c_mcp.ml` (already swept).

## 3. Per-file results

| file:line | snippet (abbrev) | classification | severity | notes |
|---|---|---|---|---|
| `peer_review.ml:495` | `String.lowercase_ascii art.reviewer <> String.lowercase_ascii alias` | CORRECT | n/a | H2 reviewer-match check uses explicit casefold. |
| `peer_review.ml:655` | `List.assoc_opt (String.lowercase_ascii alias) s.pins` | CORRECT | n/a | Trust_pin keys lower-cased on read. |
| `peer_review.ml:658-661` | `let key = String.lowercase_ascii alias in … filter (a, _) -> a <> key` | CORRECT | n/a | Trust_pin upsert key already cased; comparison both-sides-folded. |
| `peer_review.ml:915` | `String.lowercase_ascii art.reviewer <> String.lowercase_ascii alias` | CORRECT | n/a | `verify_claim_for_artifact` H2 reviewer match. |
| `peer_review.ml:746,844` | `let alias = art.reviewer in … find_pin/upsert ~alias` | CORRECT | n/a | Funnels into `find_pin`/`upsert` which casefold internally. |
| `cli/c2c.ml:171` | `List.find_opt (fun r -> r.alias = alias) regs` (after env_auto_alias) | VULNERABLE | MEDIUM | Self-recovery path: when `C2C_MCP_SESSION_ID` row missing, falls back to env-aliased lookup. Case mismatch → wrong session_id resolution → poll-inbox/etc may target wrong row or "not registered". Self-DoS, not exploit. |
| `cli/c2c.ml:412` | `if from_alias = to_alias then ()` | VULNERABLE | LOW | Self-send guard; broker enqueue does its own casefold-correct resolution, so the only impact is missing the friendly "cannot send to yourself" error when the operator types mixed case. |
| `cli/c2c.ml:425` | `List.find_opt (fun r -> r.alias = to_alias)` for compacting warning | VULNERABLE | LOW | Cosmetic — compacting hint not surfaced when case differs. Message itself succeeds. |
| `cli/c2c.ml:650` | `List.find_opt (fun r -> r.alias = a)` (whoami env_auto_alias fallback) | VULNERABLE | MEDIUM | Self-DoS: `c2c whoami` reports "(not registered)" if env alias case differs from registry row. |
| `cli/c2c.ml:814` | `List.mem reply_from pending.supervisors` (permission reply auth) | VULNERABLE | MEDIUM | Auth check with auth direction OK (LHS=user-supplied, RHS=requester-set list) — only direction is false-negative, not bypass. Legitimate supervisor with case-different alias is rejected. Coordinator supervises N agents; if any pending request lists `coordinator1` and the supervisor's session aliases as `Coordinator1`, the reply is denied. |
| `cli/c2c.ml:1324` | `List.filter (fun r -> r.alias = alias)` (`c2c history --alias`) | VULNERABLE | MEDIUM | Operator-supplied lookup; clear "not found" error so operator can retry, but undermines the case-insensitive UX promised by the c2c_mcp.ml fixes. |
| `cli/c2c.ml:3362` | `lookup_role from_alias` (PostToolUse hook envelope role attribution) | VULNERABLE | LOW | Cosmetic — `role` attribute missing from envelope when sender's stored from_alias differs in case from registry row. |
| `cli/c2c.ml:5586` | `List.find_opt (fun r -> r.alias = target) regs` (`c2c agent set-pid`) | VULNERABLE | MEDIUM | Operator-supplied target; if case mismatches, falls through to session_id match or errors. |
| `cli/c2c.ml:5876` | `List.mem name clean_stale_protected_aliases` (`c2c instances clean-stale`) | VULNERABLE | MEDIUM | Safety guard for protected swarm aliases (coordinator1, swarm-lounge, named coders). Operator-named instance dirs with mixed case bypass the protection. Not attacker-driven (operator chose the dir name) but a real footgun if a protected agent was accidentally started with `--name Coordinator1`. |
| `cli/c2c.ml:6175` | `List.filter (fun alias -> count > threshold) lock_aliases` | N/A | n/a | Diagnostic histogram over `ps`/`lsof` output; not an alias-comparison-class concern. |
| `cli/c2c.ml:6462` | `List.find_opt (fun r -> r.C2c_mcp.alias = alias)` (`c2c doctor delivery-mode --alias`) | VULNERABLE | LOW | Operator-supplied; clear error path. |
| `cli/c2c.ml:6614` | `List.find_opt (fun r -> r.C2c_mcp.alias = alias)` (`c2c doctor tag-histogram --alias`) | VULNERABLE | LOW | Same as above. |
| `cli/c2c_memory.ml:151` | `List.mem alias !acc` (`grant_aliases` dedup) | VULNERABLE | MEDIUM | ACL list de-dup: granting `Foo` then `foo` keeps both rows in `shared_with`, internal inconsistency. Combined with revoke at :159 means `revoke foo` after `grant Foo` is a no-op. |
| `cli/c2c_memory.ml:159` | `List.filter (fun alias -> not (List.mem alias revoked))` | VULNERABLE | MEDIUM | Revoke doesn't case-fold against the existing ACL — operator can leak access by not matching the original case. |
| `cli/c2c_memory.ml:296` | `target_alias = current_alias` (privacy self-read) | VULNERABLE | MEDIUM | Self-read bypass requires exact case match. If `current_alias` resolves from env to `Foo-bar` but memory dir is `foo-bar/`, owner gets denied on their own entries. |
| `cli/c2c_memory.ml:298` | `List.mem current_alias entry.shared_with` | VULNERABLE | MEDIUM | Cross-agent allow check on alias case; legitimate grantee denied if grant case differs from caller's current_alias. Symmetric DoS to grant/revoke. |
| `cli/c2c_stats.ml:633-639` | `Some a when a <> alias` / `List.mem alias top` | VULNERABLE | LOW | Statistics filtering — `--alias` filter exact-cased; cosmetic for reports. |
| `c2c_start.ml:302` | `List.find_opt (fun r -> r.alias = alias)` (`last_activity_ts_for_alias`) | VULNERABLE | LOW | Self-aliased heartbeat helper; op-controlled alias from managed-instance config. |
| `c2c_start.ml:379` | `List.find_opt (fun r -> r.alias = alias)` (`automated_delivery_for_alias`) | VULNERABLE | LOW | Same managed-instance helper; controls push-aware heartbeat body — case mismatch means default body. Cosmetic. |
| `c2c_wire_bridge.ml:267` | `List.find (fun r -> r.C2c_mcp.alias = from_alias)` (role lookup) | VULNERABLE | LOW | Same role-attribution pattern; envelope `role` attribute missed on case mismatch. |
| `tools/c2c_inbox_hook.ml:247` | `List.find_opt (fun r -> r.C2c_mcp.alias = from_alias)` (lookup_role) | VULNERABLE | LOW | Same. |
| `server/c2c_mcp_server_inner.ml:214` | `List.find_opt (fun r -> r.C2c_mcp.alias = from_alias)` (lookup_sender_role) | VULNERABLE | LOW | Same; this is the channel-notification path's role lookup. |
| `relay_e2e.ml:233` | `List.find_opt (fun r -> r.alias = my_alias) recipients` | VULNERABLE | MEDIUM | Encrypted envelope recipient list lookup. If the sender's recipient entry was written with `Foo` and `my_alias` resolves to `foo`, recipient cannot find their per-recipient encrypted-key entry → cannot decrypt → effectively dropped. Legitimate ciphertext denial. (E2E recipient lists are sender-set, so this is sender's typo bricking delivery — but TOFU pinning + alias-promotion paths could plausibly produce the case skew.) |
| `relay.ml:1113` | `if alias = from_alias then ()` (room fan-out skip-self) | N/A — out of scope | n/a | Relay layer; relay does NOT use `alias_casefold` by design today (separate alias model — Hashtbl keyed by raw string). Case skew here means sender gets their own room broadcast back. Note for follow-up: relay alias model needs its own audit if/when relay normalizes. |
| `relay.ml:1186` | `if alias = from_alias then ()` (send_all skip-self) | N/A — out of scope | n/a | Same — relay layer. |
| `cli/c2c.ml:371,3966,4178,4228,8400` etc. | `and+ alias = alias` (Cmdliner) | N/A | n/a | False positive — these are `let+ … and+` value bindings, not comparisons. |
| `cli/c2c.ml:9503,898,381,381` | `let from_alias = resolve_alias …` | N/A | n/a | Assignment, not compare. |
| `cli/c2c_memory.ml:146` | `List.filter (fun alias -> alias <> "")` | N/A | n/a | Empty-string filter, not alias comparison. |
| `cli/c2c_coord.ml:85` | `List.assoc_opt lo (config_author_aliases ())` | N/A | n/a | Email-keyed lookup; alias is the value, not the key being compared. Email already lower-cased before lookup. |

## 4. Recommended actions

Ordered by severity. None modify code — the proposals are minimal-surface
fix sketches.

**Prerequisite (mechanical):** export `Broker.alias_casefold` through
`c2c_mcp.mli`. Today `c2c_mcp.ml` references it as `Broker.alias_casefold`
internally (lines 4730, 5121, 5351, etc.) but it's NOT in the .mli, so
external callers in this audit cannot use it directly. Add:

```
val alias_casefold : string -> string
```

inside the `Broker` signature in `c2c_mcp.mli`. Single line, no behavior
change, unblocks every fix below to use the canonical helper rather than
inlining `String.lowercase_ascii`.

### MEDIUM — DoS-class false-negative auth/privacy guards

1. **`cli/c2c.ml:814`** — supervisor reply auth.
   ```
   if List.mem reply_from pending.supervisors then …
   ```
   → `if List.exists (fun s -> Broker.alias_casefold s = Broker.alias_casefold reply_from) pending.supervisors then …`
   Reasoning: the supervisor list is the authoritative target; the case-fold
   on both sides only relaxes false-negatives, doesn't widen who matches.

2. **`cli/c2c_memory.ml:296` (cross_agent_read_allowed self-read)** —
   `target_alias = current_alias`
   → `Broker.alias_casefold target_alias = Broker.alias_casefold current_alias`.
   Self-read is the most user-visible privacy guard; case-mismatch should
   never lock the owner out of their own memory dir.

3. **`cli/c2c_memory.ml:298`** — `List.mem current_alias entry.shared_with`
   → `List.exists (fun a -> Broker.alias_casefold a = Broker.alias_casefold current_alias) entry.shared_with`.

4. **`cli/c2c_memory.ml:151`** (grant_aliases dedup) — same `List.exists`-with-casefold rewrite.

5. **`cli/c2c_memory.ml:159`** (revoke_aliases) — same. Also normalize the
   incoming `revoked` list via `List.map String.lowercase_ascii` before
   filtering (or thread the casefold inline in the predicate). Combined fix
   for grant + revoke + cross_agent_read keeps the privacy ACL internally
   consistent.

6. **`cli/c2c.ml:171`** and **`cli/c2c.ml:650`** (env_auto_alias self-fallback) —
   case-fold both sides; symmetric to the c2c_mcp.ml `pending_permission_exists_for_alias` fix.

7. **`cli/c2c.ml:1324`** (history --alias) and **`cli/c2c.ml:5586`** (agent set-pid target) —
   case-fold both sides.

8. **`cli/c2c.ml:5876`** (clean_stale_protected_aliases) — change to
   `List.exists (fun p -> Broker.alias_casefold p = Broker.alias_casefold name) clean_stale_protected_aliases`.
   Closes the operator-misnaming footgun.

9. **`relay_e2e.ml:233`** (find_my_recipient) —
   `List.find_opt (fun r -> Broker.alias_casefold r.alias = Broker.alias_casefold my_alias) recipients`.
   Subtle: this only helps when the SENDER's writer used a different case
   than the recipient's resolved alias. Not a hot bug today but a clear
   correctness improvement for E2E reliability. (Note: relay_e2e is a
   pure module — adding a Broker dependency may be undesirable; prefer
   inline `String.lowercase_ascii` here, or thread a casefold helper
   through `Relay_e2e` directly so relay_e2e stays Broker-free.)

### LOW — cosmetic role-attribution / display-only

10. **Four role-lookup sites** — `cli/c2c.ml:3362`, `c2c_wire_bridge.ml:267`,
    `tools/c2c_inbox_hook.ml:247`, `server/c2c_mcp_server_inner.ml:214`.
    Pattern is identical: look up registration matching message's
    `from_alias` to surface `role` on the envelope. Suggest extracting one
    shared helper (e.g. `C2c_mcp.lookup_sender_role ~broker from_alias`) and
    folding inside it; all four call-sites become a one-line call. (#392b
    convergence already centralized envelope formatting; this would be the
    natural sibling step.) Severity: LOW because the worst case is a
    missing `role="…"` attribute on the envelope.

11. **`c2c_start.ml:302,379`** — managed-instance heartbeat helpers. Operator
    controls the alias passed in; case-fold internally to match registry rows.

12. **`cli/c2c.ml:412`** (self-send guard), **`:425`** (compacting hint),
    **`:6462`/`:6614`** (doctor --alias), **`c2c_stats.ml:633-639`** (stats filter).
    Cosmetic. Apply the same casefold-both-sides treatment for consistency.

### Out of scope but worth noting

- **`relay.ml:1113,1186`** and the rest of the relay layer use raw `=` on
  alias strings throughout — Hashtbl keyed by raw alias, no casefold. The
  relay has its own alias model and is explicitly NOT covered by the
  c2c_mcp.ml `alias_casefold` invariant. Filing as a separate slice would
  be the right approach if/when the relay should adopt case-insensitive
  semantics. Do not patch relay.ml as part of this slice — it would
  cross-cut the relay's TLS/identity binding code which expects
  registration-key stability.

## 5. Out-of-scope notes

- **`c2c_mcp.ml:3245`** (`delete_room`) — `caller_alias <> meta.created_by`
  raw `<>` comparison. HIGH-severity-feeling auth check (room creator gates
  deletion), but **inside `c2c_mcp.ml`** which the brief says is already
  swept. Cross-checking against the e3c6aba0/b8ca6cb0 commits: those fixes
  targeted `pending_permission_exists_for_alias` specifically. The
  delete_room creator-match was NOT touched. Coordinator may want to
  re-open the c2c_mcp.ml sweep with a quick grep `=\|<>` on
  `meta.created_by` and `caller_alias` — this looks like a genuine miss.

- **`c2c_mcp.ml:1572`** (M4 alias-reuse guard, register-time conflict
  detection) — already uses `alias_casefold` correctly per the comment
  trail.

- **Relay alias model divergence** — covered above. Larger design question:
  should the relay also enforce a casefold invariant? Opening a finding
  is heavyweight; may be worth a coord-level decision since the relay's
  identity-pin / TOFU layer is keyed by raw alias and changing the key
  shape ripples into stored bindings.

- **Test files** (`ocaml/test/test_c2c_mcp.ml`, `ocaml/cli/test_*.ml`) —
  did NOT audit; tests have plenty of `r.alias = alias` patterns but the
  security model treats tests as fixture-controlled. Out of scope per the
  task brief.

## 6. Receipt — relation to e3c6aba0 / b8ca6cb0

- **e3c6aba0** fixed the `pending_permission_exists_for_alias` predicate in
  `c2c_mcp.ml` to use `Broker.alias_casefold` on both sides, closing a
  HIGH-severity takeover-via-case-asymmetry path: an attacker registering
  `Coordinator1` could submit a permission request because the existing
  `coordinator1` pending perm was not detected as a duplicate.
- **b8ca6cb0** is the sibling fix on the same theme.
- **This sweep** verifies that no other in-scope `.ml` site has the same
  takeover shape. **Result: zero HIGH outside `c2c_mcp.ml`**. The medium
  hits are all DoS-class false-negatives — the asymmetry is direction-safe
  in every case (LHS supplies user-controlled string, RHS holds the
  authoritative list, and `=` only fails-closed not fails-open).
- **One outstanding concern** flagged in §5: `c2c_mcp.ml:3245`
  `delete_room` creator check (`caller_alias <> meta.created_by`) is NOT
  in any of the fixed commits and is in-module-but-unfixed. Recommend
  Cairn re-open the c2c_mcp.ml sweep for that single line.
- Migration prerequisite: export `Broker.alias_casefold` through
  `c2c_mcp.mli` so the cross-file fixes can stay disciplined to one
  helper rather than scattering `String.lowercase_ascii` inline.

## 7. Appendix — `delete_room` creator-check second-look (2026-04-29T15:18Z)

Cairn requested ONE MORE EYE on `c2c_mcp.ml:3245`. Verdict after tracing:

**VULNERABLE / MEDIUM (DoS-class), NOT bypass-class.** Same direction-safe
shape as the rest of this audit's MEDIUM findings.

### Trace

- `caller_alias` flows from MCP handler at line 6107 via
  `alias_for_current_session_or_argument` (defined at line 4924):
  - First branch: `current_registered_alias` (line 4915) — returns the
    alias as-stored in the registration table (whatever case the broker
    canonicalized to at register time).
  - Fallback branch: `from_alias` / `alias` JSON args, **raw, no
    casefold**.
- `meta.created_by` is written from `caller_alias` raw at room creation
  (line 3167 first-joiner stamp; line 3345 explicit room create) — no
  casefold-on-write. Legacy rooms can therefore store mixed-case.

### Bypass analysis (cannot bypass)

Attacker cannot make `caller_alias = meta.created_by` for someone else's
room — they would have to actually be that identity. Casefolding does
not help an attacker; the impersonation guard at line 6116
(`send_alias_impersonation_check`) already rejects when `caller_alias`
is held by an alive different session.

### DoS analysis (does false-deny)

Legitimate creator stored as `"Alice"` (legacy mixed-case before
casefold-on-canonical-storage was systematic), session today resolves
their alias as `"alice"` (canonical post-casefold registry):

```
caller_alias    = "alice"    (canonical, from current_registered_alias)
meta.created_by = "Alice"    (legacy, written raw at creation time)
"alice" <> "Alice"           => REJECTED
```

Legitimate creator denied access to delete their own room. Same
direction-safe DoS shape as cli/c2c.ml:814 / cli/c2c_memory.ml /
relay_e2e.ml:233 in §3 of this audit.

### Recommended fix

Bundle into the MEDIUM-fix slice (after c2c_mcp Slice 1a lands):

```ocaml
(* c2c_mcp.ml:3245 *)
else if Broker.alias_casefold caller_alias
         <> Broker.alias_casefold meta.created_by then
  invalid_arg ...
```

**Defense-in-depth (recommended addition)**: also casefold `caller_alias`
at the WRITE side (lines 3167, 3345) before storing into
`meta.created_by`. New rooms then store canonical-lowercase, eliminating
the mixed-case-storage DoS for future rooms. Legacy rooms still need
the read-side casefold for back-compat.

### Receipt

- Cairn DM 2026-04-29 ~15:14Z requested ONE MORE EYE.
- Slate confirmed VULN/MEDIUM/DoS, not bypass.
- Cairn ack'd 2026-04-29 ~15:18Z, routed bundle into MEDIUM-fix slice
  with `Broker.alias_casefold` on both sides + casefold-on-write for
  `created_by` (defense-in-depth).
