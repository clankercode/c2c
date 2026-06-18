# Railway smoke flakes after fa22358 deploy

## Symptom

`./scripts/relay-smoke-test.sh` reported room and poll failures against
`https://relay.c2c.im` after the `fa22358` Railway deploy. The first visible
failure was:

```json
{"ok":false,"error_code":"not_found","error":"unknown endpoint: /join_room"}
```

Later reruns moved the failure between `/poll_inbox`, `rooms list`,
`room_history`, cross-host rejection, and a one-off signed DM
`signature_invalid`.

## Discovery

Direct production probes showed the relay endpoint was present:

```sh
curl -fsS -X POST https://relay.c2c.im/join_room \
  -H 'content-type: application/json' \
  -d '{"alias":"probe-direct","room_id":"probe-room"}'
```

That reached the handler and returned `unknown_alias`, while `GET /join_room`
returned the same `unknown endpoint` shape seen in the smoke output. Repeated
isolated CLI register/send/poll loops were green, including a slower 12-alias
signed-DM loop.

## Root Cause

The production relay was live at `git_hash=fa22358`; the failures were smoke
harness brittleness under bursty production probes:

- The script used whatever `c2c` was on `PATH`; on this host that was an older
  installed binary (`56ff8d53`) rather than the freshly built tree binary.
- The retry helper printed human retry notices into stdout captured as JSON,
  so a successful retry result could be misparsed as a failure.
- Several production-sensitive operations had no retry despite Railway/edge
  and relay rate-limit transients during a burst smoke.
- Some failed read-path outputs were hidden, making moving failures look like
  endpoint regressions.

## Fix Status

Fixed locally in `scripts/relay-smoke-test.sh`:

- added `C2C_BIN=${C2C_BIN:-c2c}` so deploy checks can force the built binary;
- moved the retry helper before use;
- kept retry diagnostics out of captured JSON stdout;
- retried poll, room join/send/leave/history/list, cross-host send, and
  send_all;
- printed room list/history bodies when checking them.

Verification after the fix:

```sh
C2C_BIN=./_build/default/ocaml/cli/c2c.exe ./scripts/relay-smoke-test.sh
```

Result: `14 passed, 0 failed`.

## Severity

Medium. This did not indicate a confirmed relay production regression, but it
made post-deploy smoke reports noisy enough to obscure real deploy health.
