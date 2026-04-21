# Kimi Wire Bridge Live `--once` Proof

- **Agent:** codex
- **Date:** 2026-04-13T16:10Z
- **Severity:** INFO — native Kimi Wire delivery path live-proven

## Summary

Ran `c2c-kimi-wire-bridge --once` against a real `kimi --wire` subprocess using
an isolated temp broker root. The bridge drained one preloaded broker inbox
message, delivered it through Wire `prompt`, cleared the spool after success,
and exited with status 0.

## Command Shape

```bash
tmp=$(mktemp -d /tmp/c2c-kimi-wire-live.XXXXXX)
mkdir -p "$tmp/broker"
cat > "$tmp/broker/kimi-wire-live.inbox.json" <<'JSON'
[{"from_alias":"codex","to_alias":"kimi-wire-live","content":"Kimi Wire live once proof. Please acknowledge internally; this is a c2c bridge smoke test."}]
JSON
timeout 120s ./c2c-kimi-wire-bridge \
  --session-id kimi-wire-live \
  --alias kimi-wire-live \
  --broker-root "$tmp/broker" \
  --work-dir /home/xertrov/src/c2c-msg \
  --spool-path "$tmp/spool.json" \
  --once \
  --json \
  --timeout 0
```

## Observed Result

```json
{"ok": true, "delivered": 1}
```

After the run:

- `rc=0`
- temp broker inbox contained Kimi's acknowledgment:
  `Acknowledged - c2c bridge is live and Kimi Wire is receiving. Continuing.`
- spool file was `[]`
- temp broker registry contained `kimi-wire-live` with a live pid at registration
  time

## Interpretation

This proves the dry-run-only Kimi Wire bridge has crossed into a live subprocess
smoke: broker inbox drain -> crash-safe spool -> real Wire `initialize`/`prompt`
-> spool clear. It does not yet prove a long-running daemon/watch mode because
the current bridge surface is `--once`.

## Follow-up

- Add a long-running watch/loop mode if Kimi Wire should replace PTY wake for
  sustained managed sessions.
- Consider adding an automated e2e-style test around a fake Wire subprocess plus
  real broker files; keep real Kimi subprocess proof manual/operator-gated.
