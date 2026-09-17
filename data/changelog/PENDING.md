# Pending changelog entries — fold into CHANGELOG.md at the next release

Entries staged here are ready to paste under the next `## vX.Y.Z — <date>`
heading in `data/changelog/CHANGELOG.md` (then delete them from this file).
They must NOT be added to CHANGELOG.md before the release: the agent-facing
changelog auto-show (`merged_entries`) and remote-cache fetch both read
CHANGELOG.md, and a premature version heading confuses "what's new since last
binary" surfaces (observed 2026-07-13 during B140). Note B268's passive
`update_available` / `latest_known_newer` read the *remote* cache only, not
the embedded file — still keep unreleased headings out of CHANGELOG.md.

### The relay is now opt-in — c2c contacts no relay until you enable one (B300)
summary: c2c used to contact the public relay at relay.c2c.im by default. On a host with no relay configuration at all, `c2c doctor` and `c2c health` both probed it — `doctor` fell back to the public URL whenever none was configured, and `health` hardcoded it outright. That is gone: c2c now makes no relay network call until you explicitly activate one, and an unactivated relay is reported as a normal healthy state (`relay: not activated (local-only)`), not a warning. Nothing about same-machine messaging changes — DMs, rooms, broadcast, hooks and delivery never needed the relay. Only cross-machine messaging (`alias@host`, remote peers) does. Activation is `c2c relay enable` (or `--url` for a private relay), `C2C_RELAY_URL`, or `--relay-url`; `c2c relay disable` returns the host to local-only while keeping the configured URL. If you already ran `c2c relay setup` your host stays activated — an existing relay.json with a `url` is honoured as-is, so nothing you have working will disconnect.
setup: c2c relay enable
audience: all

### `c2c health` was reporting on the wrong relay for private-relay hosts (B301)
summary: `c2c health`'s relay line read `C2C_RELAY_URL` and then a hardcoded public URL, never `relay.json` — so if you pointed this host at a private relay with `c2c relay setup --url`, the health line described relay.c2c.im's reachability and version instead of yours, confidently and wrongly. It now uses the same resolution as every other relay surface. Relay URL resolution had been copied three times and all three copies had drifted (the subscribe daemon read `~/.c2c/relay-setup.json`, a path nothing writes); they are now one.
audience: all
