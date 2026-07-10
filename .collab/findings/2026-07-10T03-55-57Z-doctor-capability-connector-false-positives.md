# Relay doctor reports capabilities and connector state it has not proved

Severity: **high**

## Symptom

On the public HTTPS relay, doctor reports `subscribe=yes` although the subscribe
command rejects HTTPS. An isolated broker can report a connector running because
unrelated connector processes exist elsewhere on the machine.

## Discovery

T1 compared public `doctor --relay --json` with the actual subscribe preflight
and exercised doctor against an isolated temporary broker.

## Root cause

`check_capabilities` equates generic health reachability with subscribe support
(`ocaml/cli/c2c_doctor_relay.ml:473-497`). `detect_connector_processes` is a
machine-global `pgrep` with no broker-root, relay-URL, or instance ownership
check (`:64-86`). The promised top-level `c2c capabilities --json` is absent,
and `docs_relay` points every check at the unpublished `/docs/relay` path.

## Fix status

Open. Make the matrix scheme/attempt-aware, scope connector evidence, choose and
document the canonical capabilities surface, use published permalinks, and add
a table-driven check/status/fix/attempt suite. Inventory: A024/A026/A076-A085/
A088, B031-B034/B054/B099-B100/B118-B119/B221-B225/B233-B240/B248, C055.
