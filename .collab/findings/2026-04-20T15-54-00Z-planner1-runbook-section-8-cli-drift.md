# Runbook §8 commands drift from real CLI surface

- **Date:** 2026-04-20T15:54Z (2026-04-21 01:54 local +10)
- **Alias:** planner1
- **Severity:** medium — blocks the v1 ship-gate dry-run until §8 is
  rewritten to use commands that actually exist. Not a code bug.
- **Fix status:** NOT FIXED — requires editing §8 of
  `.collab/runbooks/c2c-delivery-smoke.md` to match real commands.

## Symptom

Running §8.2 and §8.3 as written fails with `unknown command`:

```
$ c2c relay register --relay-url https://relay.c2c.im --alias smoke-A
c2c: unknown command register. Must be one of connect, gc, identity,
     list, rooms, serve, setup or status

$ c2c relay send smoke-B "hello"
c2c: unknown command send. ...
```

## How I discovered it

Max signalled the relay was back up. I began dry-running §8 against
`https://relay.c2c.im`. §8.1 (`/health`, `c2c relay status`) passed.
§8.2 (`c2c relay register`) returned `unknown command`.

## Root cause

§8 was drafted by reading `docs/c2c-research/relay-internet-build-plan.md §5`
("c2c relay register submits signed proof"), which describes the
*conceptual* surface. The actual CLI uses different verbs:

| §8 command                              | Actual CLI                                 |
|-----------------------------------------|--------------------------------------------|
| `c2c relay register --alias smoke-A`    | probably `c2c relay connect` (connector-   |
|                                         | daemon; performs registration on startup)  |
| `c2c relay send <alias> <msg>`          | likely via `c2c relay connect` fan-in to   |
|                                         | `c2c send` through the local broker, OR    |
|                                         | a direct POST (no `send` subcommand today) |
| `c2c relay rooms create <room>`         | no explicit `create`; rooms are implicit   |
|                                         | on first `rooms join`                      |
| `c2c relay poll`                        | no explicit `poll`; connector drains       |

Available `c2c relay` verbs today: `connect`, `gc`, `identity`,
`list`, `rooms`, `serve`, `setup`, `status`.

Available `c2c relay rooms` verbs (need to confirm with --help):
presumably `join`, `leave`, `send`, `history`, `list` (Layer 1
slices 4–9 in RELAY.md).

## Impact

- §8.2 through §8.6 cannot run as written. The v1 ship-gate
  verification is blocked until §8 is rewritten.
- Any swarm member trying to follow §8 today will hit the same
  confusion and waste a loop tick.

## Next step

1. Map each §8.x sub-step to the real CLI surface by reading `c2c
   relay <verb> --help` for each subcommand.
2. Rewrite §8 of `.collab/runbooks/c2c-delivery-smoke.md` with the
   actual commands. Replace the `c2c relay register` flow with the
   `c2c relay connect --once --relay-url ... --node-id ...` flow
   that's actually shipped, plus the identity-init that the
   connector relies on.
3. If the conceptual commands from the build plan (`register`,
   `send`, `rooms create`) are on the roadmap, open a planner note
   or a slice so they land with matching §8 names. Otherwise the
   build plan's ship criteria should be edited to describe the real
   CLI.
4. Re-run §8 end to end and update this finding with the result.

## Related

- Runbook: `.collab/runbooks/c2c-delivery-smoke.md §8` added in
  commit `21d3b5b` (prematurely — spec-before-impl).
- Build plan: `docs/c2c-research/relay-internet-build-plan.md §5`
  lists the conceptual ship criteria.
- CLI source of truth: `ocaml/cli/c2c.ml`.
