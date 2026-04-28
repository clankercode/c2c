# #412 — codex tool list + env-builder centralization

- Author: coordinator1 (Cairn-Vigil)
- Timestamp (UTC): 2026-04-28T10:37:00Z
- Type: design / scoping (no code changes)
- Inputs: `.collab/findings/2026-04-28T10-23-15Z-slate-coder-c2c-install-consistency-audit.md`,
  `.collab/research/2026-04-28T10-23-00Z-coordinator1-c2c-install-cross-client-audit.md`
- Targets: `ocaml/cli/c2c_setup.ml:244` (`c2c_tools_list`), `ocaml/c2c_mcp.ml:3302`
  (`base_tool_definitions`), `setup_codex/kimi/gemini/opencode/crush/claude` env blocks.

---

## Part A — #412: codex `c2c_tools_list` is stale

### A.1 Source-of-truth locations

- **Codex per-tool auto-approve list**: `ocaml/cli/c2c_setup.ml:244-250`,
  hand-maintained list of **17** tool names. Used at line 296-299 to emit
  `[mcp_servers.c2c.tools.<tool>] approval_mode = "auto"` stanzas in
  `~/.codex/config.toml`.
- **Actual MCP tool registry**: `ocaml/c2c_mcp.ml:3302-3454`
  (`base_tool_definitions`), 31 entries, plus `debug_tool_definition`
  (3293, dev-mode only — not relevant for codex auto-approve since dev
  flag gates registration anyway). Returned from `tools/list` JSON-RPC
  handler at line 5980-5981.

### A.2 Diff (codex list vs MCP base)

Codex auto-approves (17): `register, whoami, list, send, send_all,
poll_inbox, peek_inbox, history, join_room, leave_room, send_room,
list_rooms, my_rooms, room_history, sweep, tail_log, server_info`.

MCP base also registers 14 more, **all of which prompt the operator on
every codex call today**:

1. `delete_room`
2. `prune_rooms`
3. `send_room_invite`
4. `set_room_visibility`
5. `set_dnd`
6. `dnd_status`
7. `open_pending_reply`
8. `check_pending_reply`
9. `set_compact`
10. `clear_compact`
11. `stop_self`
12. `memory_list`
13. `memory_read`
14. `memory_write`

(Slate's audit said "~13 missing"; the precise count is **14**. The
discrepancy is probably whether `send_room_invite` was counted — it is
registered at `c2c_mcp.ml:3386` but lands close to `prune_rooms` in the
file order.)

### A.3 Operator impact

A codex session that tries to write a per-agent memory note, set a DND
window, post a room invite, or stop itself will get a confirmation
prompt for *every* call. In the swarm, that means: silent friction on
the most-modern tools (memory was added in #163, DND/pending-reply/
compact in subsequent slices). The codex peer either (a) ignores the
modern tool entirely, (b) approves blindly, or (c) bounces back to CLI.
Three of those are anti-goals for the swarm.

### A.4 Fix shape — three options

**(a) Generated from single source-of-truth at build time.**
Refactor `c2c_tools_list` out of `c2c_setup.ml` and into a function
exported from `c2c_mcp.ml` (or a small shared module) that maps
`base_tool_definitions` to its list of names. `setup_codex` calls
`C2c_mcp.tool_names ()`. New tools self-register everywhere
automatically.
- Pros: zero maintenance contract; cannot drift.
- Cons: introduces a build-time dep from `cli/c2c_setup.ml` on
  `c2c_mcp.ml`. The CLI already links the broker (it can spawn it),
  so the dep should be free, but a quick check of `dune` files is
  needed before signing this off.
- Best for: long-term correctness.

**(b) Hand-maintained list + CI check.**
Keep `c2c_tools_list` literal in `c2c_setup.ml`, add a unit test that
diff-asserts it against `base_tool_definitions` names. New tool added
without updating the list ⇒ test FAIL.
- Pros: list stays grep-able and editable per-client (in case codex
  ever needs to opt *out* of auto-approving a specific tool — e.g.
  `stop_self` is plausibly something an operator wants to confirm).
- Cons: maintenance contract, but it's enforced.
- Best for: keeping the per-client opt-out lever; no cross-module dep.

**(c) Hand-listed superset.**
Just expand the literal to all 31 names today, no automation.
- Pros: trivial 14-line PR, ships in 5min.
- Cons: drifts again the next time a tool lands.
- Best for: an emergency hotfix while (a) or (b) is in flight.

**Recommendation**: **(a) for the structural fix, (c) as a same-day
companion**. Land (c) immediately so codex peers stop prompting, then
do (a) as a 1-2hr slice. (b) is a fallback if the dune dep in (a) is
uglier than expected.

A subtle wrinkle for (a)/(b): there is a real argument for `stop_self`
NOT being on the codex auto list — telling a peer to kill itself is
the kind of thing an operator might want to eyeball. If we centralise,
we should keep an explicit override list (`tools_skipping_auto_approve
= ["stop_self"]` or similar) so the per-client policy lever still
exists. Today nobody is using that lever, but the shape should support
it.

---

## Part B — #412b: env-builder centralization (slate's P2)

### B.1 Env-var literals across the six setup_* functions

Counted via `grep -cn` on `c2c_setup.ml`:

| Var | Occurrences |
|---|---|
| `C2C_MCP_BROKER_ROOT` | 7 |
| `C2C_MCP_AUTO_JOIN_ROOMS` | 6 |
| `C2C_AUTO_JOIN_ROLE_ROOM` | 6 |
| `C2C_MCP_AUTO_REGISTER_ALIAS` | 4 |
| `C2C_MCP_SESSION_ID` | 4 |
| `C2C_MCP_CLIENT_TYPE` | 1 (codex only) |
| `swarm-lounge` (room literal) | 6 |
| **Total var-name string literals across env blocks** | **32** |

Plus three single-client outliers: `C2C_MCP_CHANNEL_DELIVERY`
(claude conditional), `C2C_MCP_AUTO_DRAIN_CHANNEL` (opencode, stale —
broker default is now 0 per CLAUDE.md), `C2C_CLI_COMMAND` (opencode,
plugin-specific).

Each setup function rebuilds its env block as either a JSON `Assoc`
(claude/kimi/gemini/opencode/crush) or hand-rolled TOML lines (codex).
Six independent constructions of the same conceptual data.

### B.2 Sketch — `c2c_mcp_env` module

Goal: one canonical record, one builder, two emitters (JSON + TOML).

```ocaml
(* ocaml/cli/c2c_mcp_env.ml *)

type identity_mode =
  | Harness_sets_identity   (* claude, codex, opencode: c2c start injects *)
  | Install_sets_identity   (* kimi, gemini, crush: bake alias into config *)

type t = {
  broker_root : string;
  client : string;        (* "claude" | "codex" | ... *)
  alias : string;
  identity_mode : identity_mode;
  channel_delivery : bool;     (* claude only, conditional *)
  cli_command : string option; (* opencode plugin shells out *)
  auto_join_rooms : string;    (* default "swarm-lounge" *)
  auto_join_role_room : bool;  (* default true *)
}

(* ordered list of (key, value) for stable output *)
val to_pairs : t -> (string * string) list

(* JSON emitter for {claude, kimi, gemini, opencode, crush} *)
val to_json_assoc : t -> Yojson.Safe.t  (* `Assoc [...] *)

(* TOML emitter for codex (plain key = "value" lines) *)
val to_toml_lines : t -> string list
```

The builder centralizes the policy decisions slate flagged:

- `Harness_sets_identity` ⇒ omit `SESSION_ID` and `AUTO_REGISTER_ALIAS`
  (matches today's claude/codex/opencode behavior).
- `Install_sets_identity` ⇒ include both (matches today's kimi/gemini/
  crush). Documents the contract instead of leaving each `setup_*` to
  remember it.
- Today, **claude is incoherent**: it sets `AUTO_REGISTER_ALIAS` but
  not `SESSION_ID`. The audit calls this a probable bug. Centralising
  forces us to pick one of {harness, install} for claude — a
  deliberate decision rather than per-line drift.
- `C2C_MCP_CLIENT_TYPE` becomes universal automatically (slate's
  Slice 1).
- The stale `C2C_MCP_AUTO_DRAIN_CHANNEL=0` on opencode (broker default
  matches) drops out — no field exists for it.

### B.3 Quantified win

Direct removal:
- **32 env-var string literals** across the file collapse to **~8**
  in the new module (one per field name, defined once).
- 6 hand-coded env blocks (~5 lines each in JSON form, ~6 lines for
  codex TOML) ⇒ each setup site shrinks to a single `let env =
  C2c_mcp_env.{ broker_root; client = "kimi"; alias; identity_mode =
  Install_sets_identity; ... }` literal plus a `to_json_assoc env`
  call.
- ~6 × ~5 = **~30 lines deleted**, replaced by one ~50-line module
  with tests. Net code is roughly the same, but the **degrees of
  freedom drop from 6 to 1**.

Indirect win (the bigger one):
- Adding the next env var (`C2C_MCP_FOO`) becomes a one-line change
  in the type + emitters, not 6 separate `setup_*` edits.
- The audit's findings A (auto_register_alias drift), B (session_id
  drift), and M (client_type drift) all become **expressible as type
  constraints**, not memorable conventions.
- Future `--scope=user|project` (slate's Slice 5) can thread through
  the builder cleanly.

### B.4 Risk + sequencing

- Pure refactor; semantics-preserving except where we deliberately
  fix claude's incoherent identity-mode (call that out in commit msg
  + DM coordinator before the slice).
- Reviewer should diff golden `--dry-run --json` output of all six
  `c2c install <client>` invocations before/after — slate's Slice 4
  (per-client install integration tests) is a prerequisite. Land
  Slice 4 first, then this.
- Codex's TOML emission needs care: today the env block goes inline
  under `[mcp_servers.c2c.env]`; emitter must produce identical bytes
  (modulo ordering, which we should freeze).

---

## Part C — Slice ordering recommendation

1. **Hotfix (today)**: option (c) for codex tool list — expand
   literal to all 31 base tools. ~5 lines, immediate operator relief.
2. **Slice S1**: per-client install dry-run JSON tests
   (slate's Slice 4). Prerequisite for safe refactor.
3. **Slice S2**: env-builder module (Part B above). Behavior-
   preserving refactor; deliberately fixes claude `SESSION_ID`/
   `AUTO_REGISTER_ALIAS` incoherence.
4. **Slice S3**: replace codex's hand-listed `c2c_tools_list` with
   `C2c_mcp.tool_names ()` (option (a)). Drops the maintenance
   contract once and for all.

S1+S2 are blockers for safe convergence on slate's other findings (P3
mcp_command builder, P5 force-flag uniformity). S3 is independent of
S2 but cheaper to land after env-builder lands the cross-module
plumbing convention.

---

## Open questions

1. Does `stop_self` belong in codex's auto-approve list, or should the
   operator confirm? (Affects whether `tool_names ()` returns the
   full set or a curated subset.)
2. Is `C2C_MCP_CLIENT_TYPE` actually consumed by the broker? If yes,
   universalising in S2 is a pure win. If no, S2 should set it
   universally anyway and we file a follow-up to make the broker
   read it.
3. Should claude move to `Install_sets_identity` mode (matching its
   current `AUTO_REGISTER_ALIAS` write) or `Harness_sets_identity`
   (matching its current `SESSION_ID` omission)? Flag for Max.
