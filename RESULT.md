# RESULT — B187: whoami/send must not present borrowed or fallback identity as success

**Branch:** `fix/bl-b187`  
**Status:** fix implemented + tests green (not merged; not `bl done`)

## Problem

`c2c whoami` / `c2c send` could report success with a **borrowed** identity:

- broker `default-session.json` (init statefile) from another client
- `C2C_MCP_AUTO_REGISTER_ALIAS` pointing at another peer when our session is unregistered
- client-prefix mismatch (e.g. agy shell → `codex-*` alias)

Dogfood: agy `whoami` → `codex-yew-spout-…` → pong stamped as that codex peer.

## Fix

1. **Agy detection** in `inferred_client_type_from_env` via `ANTIGRAVITY_CONVERSATION_ID` / hook / LS markers; session id from conversation id.
2. **Shared `identity_error`** with pasteable `fix_steps`; JSON: `{error, candidate, fix_steps}`.
3. **`assert_identity_client_ok`**: fail closed when intended client ≠ reserved alias prefix or registration `client_type`.
4. **`resolve_alias` / `whoami`**: refuse unregistered session + `C2C_MCP_AUTO_REGISTER_ALIAS` borrow; refuse cross-client identities.
5. **Send** uses the same `resolve_alias ~json` path for all targets.

Preserved: #10 env-less init→whoami statefile when no conflicting client markers; B172 Codex thread map / sole alive; B040 sid-as-label (not another peer’s alias); coordinator overrides.

## Tests

- `test_c2c_onboarding`: 4 B187 cases (agy↔codex statefile, JSON fix_steps, send AUTO_REGISTER refuse, matching agy OK) + full suite **29/29**
- `test_c2c_mcp`: agy inference unit test; full suite **461/461**

## Residual / known limits

- Send-side `maybe_auto_register_sender` can still **mint a new** auto alias on an unregistered session (honest new identity, not a borrow). Dual-alias across brokers is not fully eliminated.
- Bare shells with **no** client markers can still use statefile identity (#10). Wrong only when another agent’s statefile is the only signal and markers are absent.
- Room CLI `resolve_alias_with_broker` not yet on the same guard (whoami/send scoped).

## Files

- `ocaml/c2c_mcp_helpers_post_broker.ml`, `ocaml/c2c_mcp.mli`
- `ocaml/cli/c2c_cli_helpers.ml`, `c2c_whoami_cmd.ml`, `c2c_send_cmd.ml`
- `ocaml/cli/test_c2c_onboarding.ml`, `ocaml/test/test_c2c_mcp.ml`
