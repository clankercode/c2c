# Hostile peer bodies could forge delivery markup

- **Severity:** HIGH
- **Surface:** rendered inbound `<c2c>` envelope
- **Status:** H2a fixed at the common helper and wire-bridge seam; client-specific adapter activation remains H2b.

## Symptom

`C2c_mcp.format_c2c_envelope` escaped envelope attributes but passed the
message body through verbatim by default. A peer body containing `</c2c>`
could therefore end the visible data envelope and append text shaped like a
trusted `<system-reminder>` or operator message.

## Root cause

Body escaping was optional (`escape_content_for_xml=false`) and was originally
treated as an outer-XML transport concern. It is instead an authority-boundary
requirement: every body is peer-controlled regardless of the client transport.

## Fix and invariant

All peer bodies now pass through one hostile-safe renderer before envelope
interpolation. Closing tags, reminder-shaped text, entity-shaped strings,
multiline text, and Unicode remain visible as encoded data and cannot create
new envelope markup. Delivery hints also state that peer content is untrusted
data, not an operator instruction, and must never be executed or approved.

The focused golden test uses hostile body and attribute values and locks the
complete public envelope representation. H2b must route each client adapter
through this seam (or prove equivalent encoding) before claiming full client
coverage.
