# MCP handler argument-trust audit (post-#432 Slice B)

**Scope:** every dispatch arm in `ocaml/c2c_mcp.ml`'s `match tool_name with` block (lines 4476-6280). For each handler, classify whether it derives the caller's identity from the MCP session (via `resolve_session_id` / `current_registered_alias`) or trusts a caller-supplied request argument.

**Reference fix shape (#432 Slice B / canonical):** for any tool needing "who is calling," derive from `resolve_session_id ?session_id_override arguments` → `Broker.list_registrations broker` → `reg.alias`. The `mcp__c2c__send` handler (lines 4728-4748) is the model: it calls `alias_for_current_session_or_argument` (session-first, arg-fallback) then `send_alias_impersonation_check` to refuse if `from_alias` is held by a different alive session.

---

## Resolved 2026-04-29T18-48-00Z

All four findings have shipped to `origin/master` before this audit was acted on. Cross-reference for audit-staleness checkers (cedar's potential audit-vs-master grep tool):

| Finding | Fix SHA(s) | Test SHA(s) | Current line in master |
|---------|-----------|------------|-----------------------|
| HIGH `check_pending_reply` (was `c2c_mcp.ml:5866-5900`) | `09bf2d44` (#432 Slice B B1+B2) — preceded by schema-deprecation `33d5fc8c` | `[#432 B2] check_pending_reply derives reply_from_alias from calling session` (test_c2c_mcp.ml:10234) | `c2c_mcp.ml:6641-6740` |
| MED `delete_room` (was `c2c_mcp.ml:5554-5575`) | `418ca369` / `34c37757` — earlier cut at `4d4cb557` | `test_delete_room_impersonation_rejected` (test_c2c_mcp.ml:10512) | `c2c_mcp.ml:6259-6297` |
| MED `stop_self` (was `c2c_mcp.ml:5935-5967`) | `418ca369` / `34c37757` — refined by `6260360b` | `test_stop_self_cannot_kill_other` (test_c2c_mcp.ml:10516) | `c2c_mcp.ml:6775-6840` |
| LOW `leave_room` (was `c2c_mcp.ml:5532-5553`) | `418ca369` / `34c37757` | `test_leave_room_impersonation_rejected` (test_c2c_mcp.ml:10514) | `c2c_mcp.ml:6221-6258` |

Audit-vs-master drift discovered when slate dispatched a fix-bundle subagent on 2026-04-29T18:47Z; subagent grep-verified each finding was already addressed and tore down the worktree without commits. Pattern 11 ground-truth-vs-prose discipline applied: the audit's pre-fix line numbers (5866-5900, 5554-5575, 5935-5967, 5532-5553) are correct as of audit time but had drifted; current HEAD line numbers in the rightmost column above.

— resolved by slate-coder via subagent dispatch (NO-OP audit-of-audit)

---

## Section 1 — Handlers that DERIVE identity from session (no action)

These look up via `resolve_session_id` and/or `current_registered_alias` directly; the request body has no identity-bearing field.

| Tool | Line | Notes |
|------|------|-------|
| `register` | 4476 | `session_id` from env; `alias` is the *new* identity being claimed, hijack-checked at 4551. |
| `list` | 4688 | No identity input; pure read. |
| `whoami` | 5020 | Resolves session, reflects own registration. |
| `debug.send_msg_to_self` / `send_raw_to_self` | 5043 / 5084 | `sender_alias` from `current_registered_alias` only; payload sent to self. |
| `debug.get_env` | 5133 | No identity input. |
| `poll_inbox` | 5169 | Explicitly rejects when `session_id` arg disagrees with caller's env (line 5176). Strong. |
| `peek_inbox` | 5257 | Comment at 5258-5260: "Resolves session_id from env only (ignores argument overrides)". |
| `history` | 5288 | Comment at 5289-5295 explicitly bypasses `resolve_session_id` to refuse arg override. |
| `tail_log` | 5328 | No identity; reads shared `broker.log`. |
| `server_info` | 5376 | No identity. |
| `sweep` / `prune_rooms` | 5379 / 5420 | Mutate broker-wide state; no identity input. (Trust boundary is "do not call sweep" — see CLAUDE.md.) |
| `set_dnd` / `dnd_status` | 5437 / 5465 | `session_id` via `resolve_session_id`; effect is bound to that session. |
| `my_rooms` | 5680 | Comment at 5681-5685 explicitly ignores arg override. |
| `set_compact` / `clear_compact` | 5901 / 5924 | Reject if no env session_id (lines 5902, 5925). |
| `open_pending_reply` | 5821 | `session_id` from `resolve_session_id`; `alias` looked up from registration (line 5836). Good. |

## Section 2 — Handlers that ACCEPT caller-supplied alias with documented legacy-fallback rationale (no action)

All of these route through `alias_for_current_session_or_argument` (line 4362), which prefers `current_registered_alias` and only falls back to the request's `alias` / `from_alias` when the session has no registration. Send-class handlers additionally invoke `send_alias_impersonation_check` (line 4395), which rejects if the supplied alias is held by a *different alive session*. The schema labels these "Legacy fallback ... (deprecated)" (lines 3755, 3759, 3767, 3799, 3803).

| Tool | Line | Notes |
|------|------|-------|
| `send` | 4728 | Canonical pattern. Session-first; impersonation check; pidless legacy regs allowed (4407 comment). |
| `send_all` | 4968 | Same shape as `send`. |
| `join_room` | 5493 | session-first via `alias_for_current_session_or_argument`; no impersonation check needed (joining a room is a self-affecting op, not impersonation), and the join binds `(alias, session_id)` together (line 5500). |
| `leave_room` | 5532 | Same; the `Broker.leave_room` call is keyed on alias + room. See LOW finding below — leaving is not impersonation-checked. |
| `send_room` | 5576 | session-first + impersonation-check. |
| `send_room_invite` | 5755 | session-first + impersonation-check. |
| `set_room_visibility` | 5784 | session-first + impersonation-check. |
| `stop_self` | 5935 | `name` resolved via `alias_for_current_session_or_argument`; effect is signaling the outer.pid file for that instance. Lookup-by-instance-name, not impersonation per se — but see MED finding below. |

## Section 3 — Handlers that TRUST caller-supplied identity without justification (BUGS)

### 3.1 `check_pending_reply` — HIGH — `ocaml/c2c_mcp.ml:5866-5900`

```ocaml
| "check_pending_reply" ->
    let perm_id = string_member "perm_id" arguments in
    let reply_from_alias = string_member "reply_from_alias" arguments in   (* ← trusted caller-supplied identity *)
    ...
    if List.mem reply_from_alias pending.supervisors then
      (* returns valid:true + requester_session_id *)
```

**Trust-boundary issue:** `reply_from_alias` is the *attestor* whose membership in `pending.supervisors` decides whether to disclose `requester_session_id` and treat the reply as authoritative. Any caller who knows (a) a live `perm_id` and (b) a supervisor's alias gets `valid:true` plus the requester's `session_id`. This is both an info-disclosure leak (requester session_id) and an auth bypass for the permission-reply flow that #432 Slice B was tightening up.

**Fix shape:** derive `reply_from_alias` from the MCP session, not from the body:

```ocaml
let session_id = resolve_session_id ?session_id_override arguments in
let reply_from_alias =
  match List.find_opt (fun r -> r.session_id = session_id)
          (Broker.list_registrations broker) with
  | Some reg -> reg.alias
  | None -> "" (* unregistered → cannot attest *)
in
```

If a CLI / non-MCP path needs the legacy arg form, route it through a separate code path with a clear "legacy fallback" comment and an impersonation check, mirroring the `send` arm.

### 3.2 `delete_room` — MED — `ocaml/c2c_mcp.ml:5554-5575`

```ocaml
let caller_alias =
  match alias_for_current_session_or_argument ?session_id_override broker arguments with
  | Some a -> a
  | None -> ""
in
(try Broker.delete_room broker ~room_id ~caller_alias ~force ();
```

**Trust-boundary issue:** `delete_room` uses `alias_for_current_session_or_argument` (session-first, arg-fallback) but does **not** call `send_alias_impersonation_check`. So an unregistered MCP caller can pass `alias="lyra-quill"` and (if `Broker.delete_room` does any caller-alias-based ACL check) impersonate `lyra-quill` for the deletion authorization. Whether this matters depends entirely on whether `Broker.delete_room` enforces creator/membership ACL on `caller_alias` — if it does, this is exploitable; if it doesn't, deletion is unrestricted regardless. Either way the symmetry is wrong: every other room-mutating arm (`send_room`, `send_room_invite`, `set_room_visibility`) goes through the impersonation check — `delete_room` should too.

**Fix shape:** add the same `send_alias_impersonation_check` guard used by sibling room-mutation handlers. While at it, audit `Broker.delete_room` for what `caller_alias=""` actually does.

### 3.3 `stop_self` — MED — `ocaml/c2c_mcp.ml:5935-5967`

```ocaml
| Some name ->
    let pid_path = Filename.concat (Filename.concat instances_dir name) "outer.pid" in
    ... Unix.kill pid Sys.sigterm ...
```

**Trust-boundary issue:** `name` is the instance to terminate. It comes from `alias_for_current_session_or_argument`, so a caller without a registered session can pass any `alias=<peer-name>` and SIGTERM that peer's outer process. There is no impersonation guard. The schema description says "stop self" but the implementation will happily stop *anyone* whose outer.pid the broker can read. (Mitigated by: instances_dir is per-host, and you need to know the instance name. But a malicious / confused agent listing peers via `list` then calling `stop_self` with each alias in turn is a denial-of-service vector.)

**Fix shape:** require the resolved alias to match the calling session's registered alias — derive from `current_registered_alias` only, no arg fallback. If a legacy CLI path needs arg-based naming, route via a separate explicit `--name` admin tool.

### 3.4 `leave_room` — LOW — `ocaml/c2c_mcp.ml:5532-5553`

`leave_room` accepts an arg-supplied `alias` via `alias_for_current_session_or_argument` and calls `Broker.leave_room broker ~room_id ~alias` with no impersonation check. An unregistered caller can evict any member by aliasing in. Symmetry argument: every other room handler that mutates membership/state checks `send_alias_impersonation_check`; `leave_room` should match.

**Fix shape:** add `send_alias_impersonation_check` before `Broker.leave_room`, matching the pattern in `send_room` (line 5593).

---

## Summary

- **HIGH (1):** `check_pending_reply` trusts `reply_from_alias` for ACL + info disclosure.
- **MED (2):** `delete_room` and `stop_self` accept arg-supplied alias for destructive ops with no impersonation guard.
- **LOW (1):** `leave_room` lacks the impersonation check its siblings have.

The canonical pattern (`send` arm) is applied consistently to most send-class handlers; the gaps are in the room-lifecycle handlers (`delete_room`, `leave_room`), the permission-reply attestation (`check_pending_reply`, the most serious), and the lifecycle-control handler (`stop_self`).

Inbox-shaped handlers (`poll_inbox`, `peek_inbox`, `history`, `my_rooms`, `set_compact`/`clear_compact`) are already locked down — recent commits explicitly bypass argument overrides and reject mismatched session_ids. Good baseline; extend the same discipline to the four flagged arms.
