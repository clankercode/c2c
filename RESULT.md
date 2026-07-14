# B176 — Improve Codex app-server startup feedback and lifecycle logging

## Summary

Codex app-server startup now emits progressive, timestamped lifecycle lines so
slow starts no longer look hung, and every `[c2c codex app-server]` log carries
a local `HH:MM:SS` stamp.

### Operator-facing format

```
[c2c codex app-server] [HH:MM:SS] <message>
```

- Label keeps historical yellow-bold styling on a color-capable TTY (`NO_COLOR`
  / non-TTY → plain).
- Timestamp is local wall clock.

### Lifecycle phases (in order)

1. **Launching** — immediately before `spawn_server`  
   `launching app-server (c2c-alias=<alias>)`
2. **Ready** — after readiness probe succeeds, before TUI attach  
   `app-server ready (<endpoint>)`
3. **TUI handoff** — immediately before `spawn_frontend` (TUI inherits stdio)  
   B159 polished banner body: `c2c codex · ready · <alias> · <endpoint>`  
   (multi-segment color preserved when supported)

Failure / restart / degraded paths that already used
`app_server_log_label` now go through the same timestamped helper.

### Implementation notes

- Pure formatters in `C2c_codex_session` (`app_server_log_hms`,
  `format_app_server_log`, lifecycle body helpers) for hermetic tests.
- Additive `lifecycle_phase` + `config.lifecycle_log` callback on
  `C2c_codex_app_server` (default no-op). No readiness/timeout rewrite
  (B175 sibling owns that).
- Post-start duplicate banner removed; handoff is the single polished ready
  line and fires before the TUI owns the terminal.

## Tests

```
./_build/default/ocaml/test/test_c2c_codex_session.exe   # 36 OK
./_build/default/ocaml/test/test_c2c_codex_app_server.exe # 30 OK
```

New coverage:

| Case | What it locks |
|------|----------------|
| `app-server log timestamp format (B176)` | local `HH:MM:SS`, plain + colored line shape |
| `app-server lifecycle phase bodies (B176)` | three distinguishable bodies; alias/endpoint; label+ts |
| `lifecycle phases order (B176)` | Launching → Ready → Tui_handoff; Launching before spawn_server; Ready/Handoff before spawn_frontend |

## Risks

- **B175 collision**: sibling worktree may also touch `start`/diagnostics.
  This change is additive (`lifecycle_log` field + three `emit_lifecycle`
  calls). Merge carefully if both land.
- **Config record field**: any hand-built full `config` literals (not
  `{ default_config with … }`) must set `lifecycle_log`. In-repo sites use
  `default_config` / record update.
- **Log volume**: three lines on every successful managed start instead of one
  banner; intentional for progress visibility.
- **Timezone**: stamp is localtime (as requested), not UTC.

## Files

- `ocaml/c2c_codex_session.ml` / `.mli`
- `ocaml/c2c_codex_app_server.ml` / `.mli`
- `ocaml/test/test_c2c_codex_session.ml`
- `ocaml/test/test_c2c_codex_app_server.ml`

## Out of scope (per instructions)

- No merge to master
- No `bl done`
- No B175 readiness/timeout diagnostic rewrite
