# B166/B167 — managed Codex frontend identity and delivery-context receipt

## Finding

The app-server delivery loop already owns repo-local ingress and the safe
idle-only auto-turn policy, but the remote Codex frontend did not inherit the
launcher's normal `C2C_MCP_SESSION_ID`. A bare `c2c init` inside that frontend
therefore synthesized a separate session/alias. Besides making the advertised
identity drift, that can make peers address an inbox other than the delivery
loop's stable managed session.

## Change

- Added frontend-only environment overrides to the authenticated app-server
  launcher; the server process never receives them.
- Managed `c2c new codex` now gives its remote frontend the stable launcher
  `C2C_MCP_SESSION_ID`, the existing app-server ownership marker, and the
  managed marker. Inherited ambient keys are replaced, not duplicated.
- The app-server SessionStart context now accurately says that local c2c mail
  is injected at arrival time and that eligible idle mail starts one safe
  steering turn. It also tells the agent registration is already complete.
- The hook remains identity-only for app-server sessions: it does not drain the
  inbox or create a second identity, leaving arrival-time delivery exclusively
  to `C2c_codex_deliver_loop` / `C2c_codex_autoturn`.

## Verification

- `test_c2c_codex_session.exe`: 34 tests passed.
- `test_c2c_codex_app_server.exe`: 29 tests passed; asserts frontend-only
  identity env and that the app-server process does not receive it.
- `test_c2c_hook_codex.exe`: 36 tests passed; asserts app-server hook identity
  adoption, no inbox drain, and the injected delivery contract.
- Isolated CLI check: after registering `managed-b166` as `stable-b166`, a bare
  `c2c init --client codex --no-setup --room '' --json` with that managed
  `C2C_MCP_SESSION_ID` retained `stable-b166`.

## B167 live tmux reproduction and follow-up

Using the mandated `scripts/c2c_tmux.py` harness against commit `bd003f94`, a
fresh managed Codex app-server session reached `online-attached` and advertised
`codex-plasma-rubble-84db`.  That alias was not routable.  On its first actual
SessionStart hook, Codex instead registered `codex-range-thick-hh1n`; a local
message sent to that user-visible alias remained queued and was not injected or
auto-turned by the app-server loop.

The cause was twofold:

1. `run_delivery_loop` registered and polled under the managed instance name,
   while the remote frontend received the distinct launcher `session_id` in
   `C2C_MCP_SESSION_ID`.  The SessionStart hook therefore could not adopt the
   loop's broker row and generated a second identity.
2. The loop registration did not set `from_auto_gen=true`, so the broker
   rejected the generated `codex-*` alias.  The exception was swallowed,
   leaving the advertised alias unreachable.

The B167 fix registers the generated app-server alias synchronously as soon as
the authenticated unit starts, under the exact frontend session id and with
`from_auto_gen=true`.  The delivery loop now uses that same session id for
registration, inbox polling, DND, rooms, and cleanup.  This leaves one
user-visible alias and one inbox from startup through arrival injection.

Focused verification:

- `test_c2c_codex_session.exe -- test lifecycle-glue 0` passes; it asserts the
  broker row exists under the remote frontend session id (this failed before
  the fix).
- `test_c2c_hook_codex.exe -- test hook-codex 13` passes; it preserves the
  managed app-server hook adoption/no-drain contract.
