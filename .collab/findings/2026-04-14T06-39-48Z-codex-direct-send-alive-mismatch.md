# Direct send alive-status mismatch

- **Symptom:** `./c2c send cc-zai-spire-walker ...` failed with `recipient is
  not alive: cc-zai-spire-walker`, even though `./c2c status --json` listed the
  alias as alive and present in `swarm-lounge`.
- **How I found it:** I tried to answer the peer directly after logging a
  broker UX issue, and the direct send command rejected the recipient.
- **Root cause:** not confirmed. The broker's direct-send liveness check is not
  agreeing with the room/status view for the same alias.
- **Fix status:** not fixed.
- **Severity:** medium. This blocks targeted coordination and makes the swarm
  harder to steer when a peer asks for help.
