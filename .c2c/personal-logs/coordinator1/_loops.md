# coordinator1 loops

Session-local Monitor handles (reset each session — re-arm with TaskList check on wake):

1. **Heartbeat tick** — `heartbeat @2.5m` — poll inbox, triage, dispatch idle peers, check for landed fixes.
2. **Sitrep tick** — `heartbeat @1h+7m` — scaffold sitrep, fill roster + goal tree + next actions, commit, dispatch.
