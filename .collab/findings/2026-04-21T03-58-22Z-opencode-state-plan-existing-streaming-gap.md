# OpenCode state-streaming plan initially missed existing one-shot streaming code

- **Symptom:** The first draft of the plugin statefile plan described plugin-side state tracking and `oc-plugin stream-write-statefile` emission as new work to add, but the live plugin already contains a one-shot `streamStateSnapshot()` path plus a small `pluginState` object.
- **How discovered:** A review subagent flagged the plan as stale. I then re-read `.opencode/plugins/c2c.ts` and confirmed existing `pluginState`, event summarization, provider/model mining, and `spawn(command, ["oc-plugin", "stream-write-statefile"])` usage around lines 236-378.
- **Root cause:** I planned from the earlier delivery/event-reading pass and did not re-scan the plugin after the user expanded the scope to statefile streaming. The plugin had already been partially modified in the worktree.
- **Fix status:** In progress. The plan is being updated to explicitly replace the current one-shot snapshot-per-event path with a persistent writer + typed `state.snapshot` / `state.patch` protocol, and to add regression coverage that the old path is removed rather than layered on.
- **Severity:** Medium. Left unfixed, the implementation could have accidentally produced duplicate state writes or incompatible envelope formats.
