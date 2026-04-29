# Pending-Permissions Drift Audit — 2026-04-29 (stanza-coder)

Doc surface audited:
- `docs/security/pending-permissions.md` (the canonical reference)
- `docs/commands.md` §"Permission/reply tracking" + CLI table
- `docs/index.md` MCP tool listing
- `docs/ocaml-module-structure.md` line-number table

Code surface: `ocaml/c2c_mcp.ml` (Broker + tool dispatch), `ocaml/cli/c2c.ml` (`open-pending-reply`, `check-pending-reply` subcommands).

Format: `DOC vs CODE: <symbol> — <delta>` [SEVERITY]

---

## CRITICAL

- **DOC vs CODE: M4 alias-reuse guard "Is prior owner still alive?" branch — does not exist in code.** [CRITICAL]
  `docs/security/pending-permissions.md` lines 156–164 describe a 2-step decision tree: pending exists → check `registration_is_alive` on prior owner → only reject if alive. Code at `c2c_mcp.ml:4387–4398` rejects unconditionally on `pending_permission_exists_for_alias broker alias` (single-predicate). There is no alive-check around it. This is a security-semantics drift: real behaviour is *stricter* than documented (any active pending entry blocks re-register, even if prior owner is unreachable). Doc claim that the guard "eliminates the ~30-minute window" is correct in effect but for the wrong reason. Either fix the doc, or implement the alive-branch as designed.

## MED

- **DOC vs CODE: `open_pending_reply` MCP — silently uses `alias=""` if caller's session is unregistered.** [MED]
  Doc says (line 72) "Resolves caller's `alias` from the registry." Code at `c2c_mcp.ml:5615–5620` falls back to `alias = ""` when no registration matches the session, then writes the entry anyway. The CLI variant (`c2c.ml:743–749`) errors-and-exits in the same situation. Either two surfaces should agree, or the doc should call out the MCP-vs-CLI behavioural split. Note: an empty `requester_alias` would later make the M4 guard match any future register of `""`, which is a footgun.

- **DOC vs CODE: `kind` MCP arg — doc says required, MCP schema says required, CLI says optional default `permission`.** [MED]
  `c2c_mcp.ml:3612` lists `kind` in `~required`. CLI at `c2c.ml:723–724` declares `kind` as `value & opt … None` with doc "default: permission". `docs/commands.md:413` matches MCP (yes/required). The CLI surface is undocumented as having a default. Low risk but inconsistent across surfaces.

- **DOC vs CODE: `c2c.ts` plugin integration — referenced commit `d116139` and line ranges (1039–1062, 1407–1417) cannot be verified against this repo.** [MED]
  Whole "Plugin Integration Example" section in `pending-permissions.md` cites a TypeScript file/commit that is not in `ocaml/` (the OCaml source-of-truth tree). If `c2c.ts` is in another repo (older OpenCode plugin), the doc should say so explicitly — currently it reads as if those line numbers are local. Likely stale carry-over from the migration period.

## LOW

- **DOC vs CODE: stale broker line numbers.** [LOW]
  `pending-permissions.md` cites `c2c_mcp.ml line 3324` for `open_pending_reply` and `line 3368` for `check_pending_reply`. Actual locations: 3610 (tool def) / 5600 (handler) and 3618 / 5645. Also cites alias-reuse guard at "2619–2637"; actual is `4387–4398`. `docs/ocaml-module-structure.md:29–30` cites `674–746` / `747–793` for the CLI subcommands; actual `c2c.ml` lines are `717–785` / `790–~830`. Per `docs/CLAUDE.md` §"Common drift hotspots", line numbers should be dropped unless load-bearing.

- **DOC vs CODE: `expires_at` JSON shape.** [LOW]
  Code emits `("expires_at", \`Float pending.expires_at)` (Yojson `Float` → JSON number). Doc example shows `1753315200.123` (correct), no drift in shape — but the `null` case for `requester_session_id` is documented as a literal `null` while code uses `\`Null` (`null`) — matches. No fix needed; flagging only because the doc example numerics are arbitrary.

- **DOC vs CODE: `remove_pending_permission` MCP surface.** [LOW]
  Broker exposes `remove_pending_permission` (`c2c_mcp.ml:704`, `c2c_mcp.mli:333`) but no MCP tool or CLI subcommand wraps it. Doc line 145 says "the plugin calls `remove_pending_permission`" — but the only way for a plugin to do that today is via direct broker access (in-process) or by letting the TTL lazy-evict. The TS plugin cannot call this. If the plugin is meant to close-after-first, an MCP tool is missing.

## NIT

- **DOC vs CODE: server `features` list does not advertise `pending_permissions` / `m4_alias_reuse_guard`.** [NIT]
  `c2c_mcp.ml:144` `server_features` list lacks any entry for the pending-permissions feature; clients cannot detect support via `server_info`. Either add a feature flag (`pending_permission_tracking`) or note in the doc that detection is by-tool-presence only.

- **DOC vs CODE: TTL env trim.** [NIT]
  CLI handler trims `C2C_PERMISSION_TTL` (`c2c.ml:765`); MCP handler does not (`c2c_mcp.ml:5621–5625`). Drift in input-handling, undocumented either way.

---

## NEW behaviour code has that isn't documented

- **`pending_permission_exists_for_alias` is unconditional** (see CRITICAL above) — current behaviour is "block register iff active pending entry mentions that alias", which is the actual semantic. Document this as the implemented form.
- **MCP `open_pending_reply` accepts unregistered sessions** and writes `requester_alias=""`. Undocumented; likely a bug.
- **`pending_permissions.json` is included in `c2c migrate` source files** (`test_c2c_migrate.ml:72` writes one as a fixture). Doc does not mention migration interaction; migration runbook should reference this file alongside `registry.yaml`.
- **Tier classification**: `open_pending_reply` / `check_pending_reply` are listed in the Tier-3 hidden-default group at `c2c_mcp.ml:3872`. Visible only when tier ≥ that level. Not documented in `commands.md`'s tier guidance.

End of report.
