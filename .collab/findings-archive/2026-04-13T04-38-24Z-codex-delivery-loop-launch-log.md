# Codex delivery loop launch footgun

- Symptom: a detached `nohup ./c2c deliver-inbox --loop ... &` launch appeared
  to exit immediately and did not leave a pidfile during the first probe.
- How discovered: after launching the new Codex live-delivery loop, `ps` and the
  expected pidfile check did not show the process. A bounded foreground run of
  the same command worked, so the tool itself was not the broken part.
- Root cause: the first detached process was slower to reach pidfile creation
  than the short probe allowed. A second debug launch then started another loop
  and overwrote the pidfile before the duplicate was killed. A broad `pkill -f`
  command also matched the shell running the cleanup command, killing that shell
  before the restart completed.
- Fix status: fixed operationally. Only one Codex delivery loop is running now:
  `python3 ./c2c_cli.py deliver-inbox --client codex --pid 1394192 --session-id
  codex-local --file-fallback --loop --interval 2 --pidfile
  run-codex-inst.d/c2c-codex-b4.deliver.pid`, with pidfile `1559218`.
- Severity: medium. It does not corrupt broker state, but it can leave stale
  pidfiles or duplicate delivery loops if an operator probes too aggressively.
- Recommendation: add a small managed starter later, probably
  `c2c deliver-inbox --daemon` or a `run-codex-inst` integration, that writes a
  wrapper pid, waits for the child pidfile, checks liveness, and avoids
  self-matching `pkill -f` cleanup.
