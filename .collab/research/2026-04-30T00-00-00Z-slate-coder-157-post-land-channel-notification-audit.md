# Audit: channel_notification + format_c2c_envelope cluster post-#157

**Date**: 2026-04-30T00:00:00Z  
**Agent**: slate-coder  
**Trigger**: Cairn requested post-#157 code-health pass (channel_notification + format_c2c_envelope cluster)  
**Status**: Research only — no code changes. Potential Audit-5 candidates.

---

## Context

`#157` (SHA `807e40a1`) added UTC HH:MM `ts` field to `channel_notification` meta JSON.
Two functions now format the same `float → "HH:MM"` string independently:

- `format_c2c_envelope` (~line 510): `?ts` optional, embedded as XML attribute
- `channel_notification` (~line 4537): `ts` required from message record, in JSON meta

---

## Findings

### HIGH

None.

---

### MED

#### M1 — `format_ts_hhmm` helper missing (2 sites duplicate same 2-LoC pattern)

Both functions independently compute:
```ocaml
let tm = Unix.gmtime t in
Printf.sprintf "%02d:%02d" tm.tm_hour tm.tm_min
```

If the format ever changes (e.g. adding seconds, or timezone suffix), both sites
need updating in lockstep. The duplication is load-bearing — a drift would make
`<c2c ts="...">` and `<channel ts="...">` show different formats for the same message.

**Fix**: Extract a shared helper before both functions:
```ocaml
let format_ts_hhmm (t : float) : string =
  let tm = Unix.gmtime t in
  Printf.sprintf "%02d:%02d" tm.tm_hour tm.tm_min
```

Replace both call sites. ~5 LoC change, net -1 LoC. XS-slice.

---

### LOW

#### L1 — `ts` optionality asymmetry between the two surfaces

- `format_c2c_envelope` takes `?ts` — silently omits ts attr when None
- `channel_notification` always has ts (required from message record)

A reader comparing `<c2c>` and `<channel>` may see inconsistent presence of ts.
Not a bug — the design intent differs (envelope ts is optional context;
channel meta ts is always present for elapsed-time visibility). But the
asymmetry could confuse future maintainers adding fields.

**Fix direction**: Document the intentional asymmetry in a comment on
`format_c2c_envelope`'s `?ts` parameter, or make `channel_notification`
ts presence explicit in the .mli. No code change required.

#### L2 — `deferrable = _` explicit pattern vs trailing `_` wildcard

`channel_notification` destructures:
```ocaml
{ from_alias; to_alias; content; deferrable = _; ts; _ }
```
`deferrable` is redundantly named — it's ignored both by `= _` and by
the trailing `_` wildcard. Could drop the explicit `deferrable = _` and
let the `_` catch it, shrinking the destructure.

**Fix**: `{ from_alias; to_alias; content; ts; _ }` — drop `deferrable = _`.
Tiny. Low-value unless doing a broader message-record destructure cleanup pass.

#### L3 — `role` appended AFTER `ts` in meta list

```ocaml
let base = [ ("from", ..); ("to", ..); ("ts", ..) ] in
match role with Some r -> base @ [("role", r)] | None -> base
```

`role` semantically belongs with sender metadata (`from`), not after timestamp.
JSON object key order is implementation-defined so this has no functional impact,
but reads slightly odd: `from, to, ts, role` instead of `from, to, role, ts`.

**Fix direction**: Reorder `base` to `[("from", ..); ("to", ..); ("role_opt_if_any"); ("ts", ..)]`
using an inline match. Minor; acceptable as-is.

---

### INFO

#### I1 — `message_id` not surfaced in channel meta

`message_id : string option` exists in the message record but is absent
from `channel_notification` meta. Could enable client-side deduplication
if a message is delivered via both channel push AND explicit poll.

Currently not a problem (Claude Code doesn't deduplicate on message_id in
the channel notification path). Future work if dedup becomes needed.

#### I2 — `enc_status` absent from channel meta

Encryption status (plain / box-x25519-v1 / not_for_me / ...) is not
surfaced in the `<channel>` tag. Agents cannot verify in-flight encryption
from the transcript tag alone.

Low priority — enc_status is visible in the body content rendered by
`format_c2c_envelope`, just not in the outer meta attributes.

---

## Recommendation for Audit-5

**M1 (`format_ts_hhmm` helper)** is the cleanest candidate:
- XS-slice, ~5 LoC, net -1 LoC
- Prevents format-drift between `<c2c ts=...>` and `<channel ts=...>`
- Tests trivially (one call, same format, two callers)
- No behavior change

**L2** (drop redundant `deferrable = _`) can bundle with M1 as a 1-line
drive-by in the same commit.

**L1, L3, I1, I2** are doc/non-issues — no code change warranted.

