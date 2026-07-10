# B108 wake-target binding research

## Acceptance criteria

- A Codex session outside tmux/herdr never retains inherited or previously
  captured wake metadata.
- `wake-watch` refuses legacy/unbound or stale targets before issuing a pane
  command, leaving the broker inbox untouched.
- A valid target is bound to the hook process/session at capture time and is
  revalidated at injection time.
- Regression coverage exercises both stale-metadata clearing and the
  no-inject/no-drain behavior.

## Findings

- `c2c hook codex` refreshed targets only when an environment target was
  present. `Broker.update_wake_targets` deliberately treated `None` as
  preserve, so a later non-tmux `SessionStart` could not clear stale data.
- `C2c_wake_inject.maybe_inject` selected any stored `tmux_location` and sent
  keys without proving the pane still hosted the registered session.
- The safe seam is an exact replacement operation for session-boundary
  refresh plus a persisted binding checked immediately before injection.
- Historical `coordinator1` mentions are evidence, but live code and current
  operational guidance still contain invalid fallbacks that cause attempted
  sends to a nonexistent peer. Those live defaults are a separate cleanup;
  archives and historical test data should not be rewritten.
