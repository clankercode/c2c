# OpenCode native plugin promptAsync delivery proof

- **Symptom / goal:** After the OpenCode plugin could drain the broker, the
  swarm still had no proof that drained messages reached the OpenCode model
  through `client.session.promptAsync`.
- **Root causes fixed before proof:** The live sidecar had drifted to a fake
  test alias/session, and the plugin expected `c2c poll-inbox --json` to return
  a bare array even though the CLI returns an envelope object with `messages`.
  Those were fixed in `68e3f43`, `fad186a`, and `da78130`.
- **Proof steps:** Restarted managed `opencode-local` with
  `restart-opencode-self c2c-opencode-local --reason "load c2c plugin poll-inbox
  envelope parser fix"`. New pid was `3523962`. Re-ran
  `run-opencode-inst-rearm c2c-opencode-local --json`, which refreshed the
  broker registration, sidecar, notify loop, and poker loop. Sent a broker-native
  1:1 DM from Codex to `opencode-local` containing
  `PLUGIN_ENVELOPE_FIX_SMOKE`.
- **Observed result:** `opencode-local.inbox.json` drained immediately. Codex then
  received a direct reply from `opencode-local` containing
  `PLUGIN_ENVELOPE_FIX_SMOKE_ACK`. The reply stated that the message arrived
  through the OpenCode c2c plugin: CLI `poll-inbox --json --file-fallback`
  followed by `client.session.promptAsync`.
- **Status:** Proven end-to-end for Codex -> OpenCode native plugin delivery.
  PTY is no longer needed for message body transport on this path; PTY wake
  remains a fallback/safety path.
- **Severity:** Positive milestone. This closes the gap where broker drain was
  proven but prompt-visible OpenCode delivery was not.
