# B013: codex delivery has TWO wired paths that can double-write fd4

- **Date:** 2026-06-26
- **Bug:** B013 (codex delivery hardening)
- **Severity:** MEDIUM (latent; not live on this host — see below)
- **Status:** documented; gating change deferred (untestable from a background
  agent without an xml-fd codex binary)

## Symptom / discovery

While fixing the inotify/xml dispatch shadowing (B013 fix2,
`8ca15412`), I found that managed codex actually has **two independent
delivery mechanisms both wired to run**, both targeting the same codex
xml pipe (fd 4):

1. **In-process daemon** — `c2c_start.ml` `start_deliver_daemon` spawns
   `c2c-deliver-inbox --client codex --xml-output-fd 4 --inotify --loop`.
   Called unconditionally whenever `cfg.needs_deliver` (line ~4913).
2. **Hook + supervisor** — `c2c install codex` defaults to
   `deliver_watch=true` (`c2c_setup.ml` `do_install_client`,
   `?(deliver_watch=true)`), which writes
   `~/.c2c/clients/codex/{deliver-watch.sh, start-hooks/pre-deliver.sh}`.
   `c2c start codex` sources `pre-deliver.sh` (when present) in the child
   before exec (`c2c_start.ml` ~4820), which forks `deliver-watch.sh`,
   which runs `c2c deliver watch --xml-fd 4` (`c2c_deliver_watch.ml`).
   Both drain the inbox destructively and write XML frames to fd 4.

## Why it was masked (and why my fix un-masks it)

Pre-fix, the in-process daemon ran in the **log-only inotify path**
(`run_inotify_loop`): it read the inbox non-destructively and printed a
preview to a `/dev/null` stdout — it NEVER wrote to fd 4. So when the
hook was installed, only the hook delivered; the in-process daemon was a
harmless no-op. **The shadowing bug was accidentally preventing the
double-write.**

My fix2 makes the in-process daemon write XML to fd 4 (correctly). On a
host where the deliver-watch hook is ALSO installed, both processes now
drain the same inbox and write frames to the same fd 4 concurrently:
- drain is serialized under the broker flock, so no message is delivered
  twice, BUT
- two concurrent writers to fd 4 can **interleave/split frames**
  (`output_string oc frame; flush oc` is not a single atomic write),
  risking a corrupted `<message>` frame for codex.

## Why it is NOT live on this host

`~/.c2c/clients/` does not exist on this machine — the deliver-watch
hook is **not installed**. So the live codex path here is the in-process
daemon alone, and fix2 is purely beneficial (it repairs delivery that
was fully broken). The coexistence only bites on a host where
`c2c install codex` (default `deliver_watch=true`) has been run.

## Recommended fix (deferred — needs live-codex testing)

Make the two paths mutually exclusive AND keep the heartbeat working:

- Skip `start_deliver_daemon` for codex when the pre-deliver hook is
  present (`pre_deliver_hook_opt <> None`), so only one writer exists.
- BUT the codex 240s heartbeat is gated on
  `deliver_started = Option.is_some !deliver_pid` (lines ~5028, ~5055).
  If the daemon is skipped, `deliver_pid` stays `None` and the heartbeat
  is suppressed even though the hook delivers. So also compute a
  `deliver_active = Option.is_some !deliver_pid || hook_present` and pass
  THAT as `~deliver_started` to the heartbeat resolution + schedule
  watcher.

This was deferred from the B013 slice because it is **untestable from a
background agent**: this host has no codex binary advertising
`--xml-input-fd` (the configured `/home/xertrov/.local/bin/codex` is
absent; PATH `codex` is the stable bun build without the flag), so a live
`c2c start codex` with the hook installed cannot be exercised. Changing
the gating blind — especially the heartbeat interaction — without a live
codex to validate would violate the "tested in the wild" rule.

## Related sub-finding: codex-headless xml_output_path is unhandled

`c2c_deliver_inbox.ml` `run_loop` dispatch handles `xml_output_fd` and
`pty_master_fd`, but **never consumes `xml_output_path`** (the fifo path
codex-headless passes via `--xml-output-path`). codex-headless therefore
falls through to `Mode_inotify_print` / `Mode_poll`, neither of which
writes to the fifo — so codex-headless delivery via the in-process
daemon does not work either. codex-headless is out of B013 scope (naked/
forked codex is explicitly excluded) and may be covered by the
deliver-watch hook when installed; logged here for the next agent.
