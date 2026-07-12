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

Live tmux dogfooding was not rerun for this narrow environment/context change;
the existing B144 app-server E2E remains the live delivery coverage.
