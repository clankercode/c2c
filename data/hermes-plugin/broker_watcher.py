"""BrokerWatcher — background daemon thread that watches the c2c inbox.

The watcher uses a polling fallback (stat every 2s, compare mtime/size)
to avoid external deps. If inotify_simple or pyinotify is available, it
uses that instead for lower latency.

On change, it calls delivery.drain_and_inject() which:
  1. Peeks the inbox via `c2c peek-inbox --json`
  2. Deduplicates by message id
  3. Formats as `<c2c event="message">` envelopes
  4. Injects via ctx.inject_message (the GUARANTEED wake)
  5. Drains via `c2c poll-inbox --json` only after a successful inject

The watcher is a daemon thread, so it dies with the process — no
cleanup needed. It handles the case where c2c binary is missing
gracefully (warns once, then polls less frequently).
"""

import os
import time
import threading
import logging
from pathlib import Path

logger = logging.getLogger("c2c.watcher")

# Poll interval for the safety-net stat-based fallback (seconds).
POLL_INTERVAL = 2.0
# When c2c binary is missing, check every 30s instead of 2s.
MISSING_BINARY_POLL = 30.0
# How often to retry resolving the inbox path once it is still unknown. Each
# attempt may shell out to `c2c health`, so it is not run on every poll.
RESOLVE_RETRY_INTERVAL = 15.0


class BrokerWatcher:
    """Background daemon thread that watches the c2c inbox for changes.

    On change, triggers drain_and_inject which polls the inbox and
    injects novel messages into the conversation via ctx.inject_message.

    The watcher is a *trigger*, not a drainer — it detects that the
    inbox changed and calls drain_and_inject which handles the actual
    drain, dedup, format, and inject pipeline.
    """

    def __init__(self, ctx, cli=None, poll_interval=None):
        self._ctx = ctx
        self._cli = cli
        self._thread = None
        self._stop_event = threading.Event()
        self._poll_interval = poll_interval or POLL_INTERVAL
        self._last_mtime = None
        self._last_size = None
        self._warned_missing = False
        self._inbox_path = None
        # Timestamp of the last (possibly failed) inbox-path resolution. The
        # watcher starts at plugin-load time, before on_session_start has
        # registered an identity, so the first attempts legitimately fail and
        # must be retried — but each retry may shell out to `c2c health`, so
        # they are rate-limited rather than run every poll.
        self._last_resolve_attempt = 0.0

    @property
    def is_running(self):
        return self._thread is not None and self._thread.is_alive()

    def start(self):
        """Start the watcher thread (idempotent)."""
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop_event.clear()
        self._thread = threading.Thread(
            target=self._run, name="c2c-broker-watcher", daemon=True
        )
        self._thread.start()
        logger.info("[c2c] broker watcher started")

    def stop(self):
        """Signal the watcher to stop."""
        self._stop_event.set()

    def _resolve_inbox_path(self, cli=None):
        """Resolve <broker_root>/<session_id>.inbox.json, or leave it unset.

        Both halves come from `c2c` itself — env first, then the binary:
          * C2C_MCP_BROKER_ROOT / C2C_MCP_SESSION_ID when they are set
            (managed launchers and identity.py export them);
          * otherwise `c2c health --json` -> broker_root and
            `c2c whoami --json` -> session_id.

        Deliberately NOT a filesystem guess. The previous implementation
        iterated ~/.c2c/repos/* and took the first directory containing a
        default-session.json — an arbitrary, unrelated repository. With
        `_inbox_path` set to a foreign inbox, `should_drain` stops
        short-circuiting on None and delivery silently degrades from
        file-change latency to the interval poll.

        Returns True when a path was resolved. On failure `_inbox_path` stays
        None and the loop falls back to interval-based draining, which is
        correct — just slower.
        """
        self._last_resolve_attempt = time.time()
        broker_root = os.environ.get("C2C_MCP_BROKER_ROOT")
        session_id = os.environ.get("C2C_MCP_SESSION_ID")

        if cli is not None and cli.available:
            if not broker_root:
                broker_root = cli.broker_root()
            if not session_id:
                session_id = cli.session_id()

        if broker_root and session_id:
            path = Path(broker_root) / f"{session_id}.inbox.json"
            if path.parent.is_dir():
                self._inbox_path = str(path)
                # Re-baseline: a path change must not read as "the inbox grew".
                self._last_mtime = None
                self._last_size = None
                return True

        self._inbox_path = None
        return False

    def _check_inbox_changed(self):
        """Stat the inbox file and return True if it changed since last check."""
        if not self._inbox_path:
            return False
        try:
            st = os.stat(self._inbox_path)
        except (OSError, FileNotFoundError):
            return False
        mtime = st.st_mtime
        size = st.st_size
        changed = False
        if self._last_mtime is not None and self._last_size is not None:
            if mtime != self._last_mtime or size != self._last_size:
                changed = True
        else:
            # First check — initialize but don't trigger a drain (the
            # on_session_start hook already drains).
            self._last_mtime = mtime
            self._last_size = size
            return False
        self._last_mtime = mtime
        self._last_size = size
        return changed

    def _run(self):
        """Main watcher loop. Runs until stop() is called."""
        from .c2c_cli import C2cCli
        from .delivery import drain_and_inject
        from .identity import get_alias

        cli = self._cli or C2cCli()

        if not cli.available:
            if not self._warned_missing:
                logger.warning("[c2c] c2c binary not found — broker watcher will retry "
                               "every %ds", int(MISSING_BINARY_POLL))
                self._warned_missing = True

        # Try to resolve the inbox path for file-based watching. This usually
        # fails here — register(ctx) starts the watcher before the
        # on_session_start hook has established an identity — so the loop
        # retries below until it succeeds.
        if self._resolve_inbox_path(cli):
            logger.info("[c2c] watching inbox: %s", self._inbox_path)
        else:
            logger.info("[c2c] inbox path not resolved yet — interval polling (%.0fs) "
                        "until identity registration", self._poll_interval)

        last_interval_drain = 0
        interval_poll = self._poll_interval * 5  # Safety-net poll every 10s

        while not self._stop_event.is_set():
            current_interval = self._poll_interval
            if not cli.available:
                current_interval = MISSING_BINARY_POLL
                # Re-check if c2c appeared on PATH
                from .c2c_cli import C2cCli as _C
                cli = _C()
                if cli.available:
                    self._warned_missing = False
                    if self._resolve_inbox_path(cli):
                        logger.info("[c2c] c2c binary found — watching inbox: %s",
                                   self._inbox_path)

            now = time.time()

            # Re-resolve once identity registration has populated the env.
            # Rate-limited: resolution can shell out to `c2c health`.
            if (self._inbox_path is None
                    and cli.available
                    and now - self._last_resolve_attempt >= RESOLVE_RETRY_INTERVAL):
                if self._resolve_inbox_path(cli):
                    logger.info("[c2c] watching inbox: %s", self._inbox_path)

            # Check if the inbox file changed
            changed = self._check_inbox_changed()

            # Trigger drain if: file changed, OR safety-net interval elapsed
            should_drain = changed or (self._inbox_path is None) or \
                           (now - last_interval_drain >= interval_poll)

            if should_drain and cli.available:
                alias = get_alias()
                try:
                    drain_and_inject(self._ctx, cli=cli, self_alias=alias)
                except Exception as e:
                    logger.debug("[c2c] drain_and_inject error: %s", e)
                last_interval_drain = now

            # Sleep in small increments so stop() is responsive
            slept = 0
            while slept < current_interval and not self._stop_event.is_set():
                time.sleep(min(0.5, current_interval - slept))
                slept += 0.5