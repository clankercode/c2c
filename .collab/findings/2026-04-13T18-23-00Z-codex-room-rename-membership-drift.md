# Register rename leaves room membership on old alias

- **Symptom:** A broker-native system event reported
  `crush-xertrov-x-game` was renamed to `ember-flame`, and `c2c list --broker`
  showed live session `crush-xertrov-x-game` under alias `ember-flame`, but
  `c2c room list --json` still showed `swarm-lounge` member
  `crush-xertrov-x-game`. After a manual repair, the old alias was re-added
  beside `ember-flame`, producing two room members with the same `session_id`.
- **How discovered:** Codex polled a queued C2C system message after a
  notify-only nudge, then compared MCP `list_rooms`, CLI `c2c list --broker`,
  and CLI `c2c room list --json`.
- **Root cause:** The OCaml `register` tool detected same-session alias renames
  and fanned out a `peer_renamed` room-history notification, but it did not
  update `rooms/<room>/members.json`. Room membership is stored as
  `(alias, session_id)`, and `my_rooms` finds rooms by `session_id`, so the
  notifier could see the old rooms while `list_rooms` continued displaying the
  old alias. A second source compounded this: both OCaml and Python `join_room`
  treated only exact `(alias, session_id)` matches as idempotent, so the same
  session could occupy one room under two aliases. Finally,
  `auto_join_rooms_startup` used `C2C_MCP_AUTO_REGISTER_ALIAS` directly instead
  of the current registry alias, allowing stale launcher env to rejoin the old
  name.
- **Fix status:** Fixed in OCaml by updating room member aliases for the stable
  `session_id` during register rename before fanning out the notification,
  making `join_room` deduplicate by alias or session ID, and making startup
  auto-join prefer the current registered alias. Fixed the Python CLI fallback
  with the same alias/session dedupe rule. Added regressions for register rename
  membership update, same-session alias rejoin, stale-env auto-join, and Python
  alias/session rejoin. The live `swarm-lounge` membership was repaired by
  rejoining `ember-flame` with session ID `crush-xertrov-x-game`; the fixed
  Python join removed the duplicate old alias.
- **Severity:** Medium. Message routing by session ID still worked, but room UI
  and social presence drifted from the registry after a rename, which undermines
  the shared-room north-star experience.
