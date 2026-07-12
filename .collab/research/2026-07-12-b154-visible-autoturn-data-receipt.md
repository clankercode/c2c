# B154 live receipt: auto-turn carries visible c2c DATA

Date: 2026-07-12T09:43:43Z
Branch: `slice/b154-codex-autoturn-visible-data`

## Contract under test

When local c2c mail starts a Codex app-server turn, the model must see the
sender, message ID, and body as explicitly-delimited DATA even if
`thread/inject_items` history is not surfaced to that turn. The delivery must
retain B098 approval isolation, remote-origin fail-closed behavior, serialized
turns, and idempotency.

## Command

```text
AUTOTURN_DRIVER=<worktree>/_build/default/ocaml/test/dev_codex_autoturn_dogfood.exe ./scripts/codex-autoturn-e2e.py
```

The harness used an isolated `CODEX_HOME`, temporary broker root, authenticated
loopback app-server, and owned process group. It removed all of them at exit.

## Evidence

- Local `at-m1` started turn `019f55b5-c1de-7e31-bd98-3799ca58d8b7`.
- Mid-turn local `at-m2` was queued behind the active turn, then started the
  distinct turn `019f55b5-d426-7221-a62f-39ecd198a6e5`.
- A remote-origin marker remained `remote_only` and did not start a turn.
- Re-running delivery started no extra turns.
- The verification turn echoed both local unique markers and the remote marker.
  Its model response also described `at-m2` as a DATA message from
  `peer-local`, with its body, and stated that no operator action was taken.
- The harness exited PASS and confirmed its app-server PID was dead after
  cleanup.

## Result

The auto-turn input now carries the canonical, explicitly labelled c2c DATA
envelopes. This fixes the count-only-nudge failure while retaining the existing
persist-first, idempotency, provenance, and B098 invariants.
