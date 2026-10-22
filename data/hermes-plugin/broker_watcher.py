"""One watcher per confirmed binding; never consult ambient identity/env."""

import logging
import threading
from pathlib import Path

logger = logging.getLogger("c2c.watcher")
POLL_INTERVAL = 2.0


class BrokerWatcher:
    def __init__(self, ctx, session, poll_interval=None):
        self._ctx = ctx
        self.session = session
        self._poll_interval = poll_interval or POLL_INTERVAL
        self._stop_event = threading.Event()
        self._thread = None
        b = session.binding
        self._inbox_path = Path(b.broker_root) / f"{b.broker_session_id}.inbox.json"

    @property
    def is_running(self):
        return self._thread is not None and self._thread.is_alive()

    def start(self):
        if self.is_running:
            return
        self._thread = threading.Thread(target=self._run, name="c2c-hermes-watcher", daemon=True)
        self._thread.start()

    def stop(self):
        self._stop_event.set()

    def _run(self):
        previous = None
        ticks = 0
        while not self._stop_event.is_set() and self.session.active:
            try:
                st = self._inbox_path.stat()
                current = (st.st_mtime_ns, st.st_size)
            except OSError:
                current = None
            if current != previous or ticks % 5 == 0:
                self.session.delivery.inject(self._ctx)
            previous = current
            ticks += 1
            self._stop_event.wait(self._poll_interval)
