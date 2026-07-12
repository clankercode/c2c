# B111 finding: self-auth bypasses leave unauthenticated destructive paths

## Severity

Critical pending production configuration confirmation for unsigned room
operations; critical in source for anonymous inbox poll/peek and binding
revocation.

## Discovery and root cause

The canonical `Relay_server_auth.auth_decision` permits `/poll_inbox`,
`/peek_inbox`, and every `/binding/` path through its self-auth bypass. When
no Ed25519 header is supplied, `handle_poll_inbox` and `handle_peek_inbox` do
not verify the supplied node/session owner. `DELETE /binding/<id>` dispatches
to `handle_mobile_pair_revoke`, which validates only ID shape and revokes the
binding if it exists. Room mutation handlers are also outer-auth bypasses and
accept unsigned bodies unless `C2C_REQUIRE_SIGNED_ROOM_OPS=1`; the code default
is off.

## Impact

Knowledge of a node/session pair can read or drain its relay inbox; knowledge
of a binding ID can revoke a mobile binding. If production has not set the
signed-room-op environment gate, callers can impersonate room aliases for
mutation operations. No destructive live test was run.

## Fix status

Open. Require verified ownership for poll/peek and binding revocation, make
signed room operations secure by default, and add token-configured HTTP tests
for all negative paths. Full evidence and source map are in the B111 audit in
`.collab/research/2026-07-11T02-25-00Z-B111-public-relay-exposure-audit.md`.
