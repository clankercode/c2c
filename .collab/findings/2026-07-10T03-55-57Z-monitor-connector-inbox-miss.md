# Monitor silently misses connector-managed relay inboxes

Severity: **high**

## Symptom

A default `c2c monitor` can report a healthy relay watcher yet emit no message
for an alias registered by the normal `c2c relay connect` bridge.

## Discovery

The T1 live reproduction placed a message at `<host-id>/<actual-session-id>`;
monitor announced and watched `cli-<alias>/cli-<alias>`, emitted neither the
message nor an error, while a direct peek of the correct inbox saw it.

## Root cause

`C2c_monitor_logic.decide_relay_watch` defaults both key components to
`cli-<alias>` (`ocaml/cli/c2c_monitor_logic.ml:242-264`). Connector registration
uses the machine host ID and actual local session. In addition,
`extract_relay_messages` maps an `ok:false` or malformed response without a
`messages` array to healthy emptiness (`ocaml/cli/c2c_monitor_logic.ml:183-189`).

## Fix status

Open. Resolve the connector-managed node/session from the local registration,
fail honestly on terminal auth/session errors, retain bounded transient retry,
and add connector-managed, auth-failure, recovery, same-stream, and public-HTTPS
proof. Inventory: A012-A015, A029-A041, B021-B027, B177-B182, B187/B190/B196,
B217-B220/B231/B235/B237/B241, C001/C018/C049.
