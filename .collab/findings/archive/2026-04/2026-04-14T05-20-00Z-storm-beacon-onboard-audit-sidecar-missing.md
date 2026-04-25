# onboard-audit Sidecar Missing - No Wake Notifications

- **Symptom:** onboard-audit has 13 messages queued in their inbox but isn't responding.
  Their sent count is stuck at 10 (needs 10 more to reach goal_met), received at 12
  (needs 8 more).
- **How discovered:** inbox file `.git/c2c/mcp/cc-zai-spire-walker.inbox.json` has 13
  messages, but `poll_inbox` hasn't drained them. Their sidecar processes (deliver
  daemon and poker) are not running.
- **Root cause:** When onboard-audit (cc-zai-spire-walker) was restarted by kimi-nova-2,
  the `c2c start` command launched the outer process but the sidecars were never
  spawned. The session has PID 1360619 running `python3 c2c_cli.py start claude --bin
  cc-zai -n cc-zai-spire-walker`, but no `c2c_deliver_inbox` or `c2c_poker` child
  processes exist.
- **Evidence:**
  - No deliver pidfile in any `run-*.d/` directory for cc-zai-spire-walker
  - No deliver or poker processes in `ps aux` output for this session
  - inbox has 13 messages including 7 "reply plz" messages from kimi-nova-2
- **Fix needed:** `c2c start` sidecar spawning is broken when `--bin` option is used
  with a non-standard binary name. The sidecar pidfile naming/path may not match.
  Need to investigate `c2c_start.py` sidecar launch path for `--bin` invocations.
- **Workaround:** Restart onboard-audit session with `c2c stop cc-zai-spire-walker`
  then `c2c start claude --bin cc-zai -n cc-zai-spire-walker` to ensure fresh sidecars.
- **Severity:** Medium. Blocks overall goal_met since onboard-audit needs 10 more sends.
