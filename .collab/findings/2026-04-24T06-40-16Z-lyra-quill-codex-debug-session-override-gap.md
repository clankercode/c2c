## Symptom

In a restarted managed Codex session, `mcp__c2c__whoami` succeeded but
`mcp__c2c__debug(action="send_msg_to_self")` failed with `missing session_id`.

## Discovery

I reproduced it live immediately after restart:

- `whoami` returned the expected alias
- `debug/send_msg_to_self` returned `missing session_id`

The mismatch showed that Codex managed-session recovery was only wired for some
tools, not all self-scoped tools.

## Root Cause

`ocaml/c2c_mcp.ml` computes a `session_id_override` from Codex
`_meta.x-codex-turn-metadata.session_id` in `request_session_id_override`, but
that function uses a tool-name allowlist.

`whoami` was on the allowlist; `debug` was not.

As a result:

- `whoami` got the managed `session_id` override and lazy bootstrap
- `debug` fell back to raw env/session resolution and raised `missing session_id`

## Fix Status

Fixed locally and installed.

Changes:

- added `debug` to the Codex request-metadata override allowlist in
  `ocaml/c2c_mcp.ml`
- added an OCaml regression for managed Codex `debug/send_msg_to_self`
- added a Python integration regression for the same path

Direct smoke verification against the installed `c2c-mcp-server` now returns a
successful debug self-send with:

- `session_id = Lyra-Quill-X`
- `alias = lyra-quill`

## Severity

Medium-high.

Normal Codex messaging still worked, but the new debug route was broken in the
exact managed-session configuration we need for live delivery testing.
