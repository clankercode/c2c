## RESOLVED — `c2c oc-plugin stream-write-statefile` is now implemented and available. Confirmed 2026-04-21 by coder2-expert.

## Symptom (original)

The OpenCode plugin can now emit state snapshots, but there is still no
installed `c2c oc-plugin stream-write-statefile` command on the CLI/OCaml side
to receive them.

## How I discovered it

While implementing plugin-side state streaming in `.opencode/plugins/c2c.ts`, I
searched the repo and the installed CLI help for `oc-plugin` and
`stream-write-statefile`.

## Root cause

This slice was intentionally plugin-first. The plugin can spawn:

```bash
c2c oc-plugin stream-write-statefile
```

and pipe JSON snapshots to stdin, but there is no corresponding command in
`ocaml/cli/c2c.ml` or another CLI surface yet. So the child process path is a
best-effort no-op for now.

## Fix status

Plugin side implemented; sink side still missing.

- `.opencode/plugins/c2c.ts` now tracks idle state, step count, last step
  summary, provider/model, inferred TUI focus, prompt-has-text, pid, start
  time, and last-updated time.
- It streams snapshots through a child process and silently ignores failures.
- The plugin contains an explicit TODO noting the missing OCaml sink.

## Severity

Low to medium. No production regression, but the feature is only half live
until the CLI/OCaml sink lands, so operators should not expect a persisted
statefile yet.

## Update (2026-04-21, planner1)

**RESOLVED.** `c2c oc-plugin stream-write-statefile` was implemented by
coordinator1 in commit `83234c7`. The sink now reads JSON snapshots from stdin
and writes them atomically to `~/.local/share/c2c/instances/NAME/oc-plugin-state.json`.
The `c2c statefile` CLI command also provides read access. Feature fully live.
