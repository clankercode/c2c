# Finding #4 follow-up: alias_occupied_guard log predicate case-fold asymmetry

## Finding
2026-04-29, willow-coder — identified during peer-PASS review by slate-coder

## Cross-refs
- #432 asymmetric-guard pattern — `.collab/findings/2026-04-29T14-25-00Z-slate-coder-alias-casefold-guard-asymmetry-takeover.md`

## What
In `95e44c54` (Finding #4 guard-logging dedup), the `alias_occupied_guard` log predicate was changed from case-sensitive `reg.alias = alias` to case-fold `Broker.alias_casefold reg.alias = target`.

This is **not** a neutral rename — it is a correctness fix with the same asymmetric-guard exploit shape as #432.

## Prior behavior (bug)
The boolean guard at line 5337/5340 already uses case-fold:
```ocaml
let target = Broker.alias_casefold alias in
List.exists (fun reg ->
  ...
  && Broker.alias_casefold reg.alias = target
  ...
) existing
```

But the corresponding log predicate used case-sensitive comparison:
```ocaml
(fun reg -> reg.alias = alias && ...)
```

This means if a registration with a case-mismatched alias existed (e.g., broker stored `Willow-Coder` but current session is `willow-coder`), the **boolean guard would block the conflict** (correct), but the **log predicate would not find it** (silent drop) — the debug log would print nothing for that guard even though it fired.

Same shape as #432: the guard blocks correctly, but the audit path is blind to the conflict.

## Fixed behavior
The log predicate now uses the same case-fold comparison as the boolean guard:
```ocaml
(fun reg -> Broker.alias_casefold reg.alias = target && ...)
```

The debug log now correctly reports case-mismatched alias conflicts.

## Severity
Low — this only affects debug logging, not the actual guard logic. The guard itself was already correct. But it creates misleading logs during post-incident debugging if a case-mismatched conflict ever fired.

## Status
Fixed in `95e44c54`. No further action needed.
