# Status/whoami label a local alias as relay-registered

Severity: **medium**

## Symptom

An unconfigured, never-relay-registered local alias is printed as
`registered: <alias>`, while relay registration/lease remains unknown unless
the operator knows to request a live probe. Connector/connection state is absent.

## Discovery

T1 reproduced the output in an isolated environment. The renderer labels
`snapshot.alias` as `registered` regardless of relay configuration
(`ocaml/cli/c2c_relay_state.ml:224-245`). JSON avoids that literal but still has
no explicit relay-registration state.

## Root cause

The status model conflates the current local broker alias with relay lease
registration, and treats “not probed” as presentation text rather than a
machine-readable state.

## Fix status

Open. Rename the static field to `local_alias`, model
`unchecked|registered|not_found|unreachable`, add broker/relay-scoped connector
state, and test configured/unconfigured/live/expired/unreachable human+JSON
parity. Inventory: A020/A027, B223/B233, and the B094 contract.
