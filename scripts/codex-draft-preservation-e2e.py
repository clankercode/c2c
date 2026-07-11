#!/usr/bin/env python3
"""T004 typed-draft preservation proof — passive c2c ingress (T003) never edits
or submits a real stock Codex remote-TUI composer draft.

WHAT THIS PROVES (against the installed codex, default 0.144.1):
  * A live stock `codex --remote` TUI (attached to a T002-style authenticated
    `codex app-server` endpoint) has its composer draft preserved BYTE-FOR-BYTE,
    and its cursor row/col unchanged, across every passive `thread/inject_items`
    arrival driven by the REAL T003 adapter (dev_codex_ingress_dogfood.exe →
    C2c_codex_ingress.real_client).
  * Passive arrival starts NO turn: no `turn/started` notification, no new turn
    id, thread status unchanged (idle stays idle / an active turn's id is stable
    and is neither steered nor interrupted).
  * Message order is preserved and a same-message-id retry injects exactly once
    on the acknowledged path (idempotency ledger); the ambiguous-ack at-least-once
    window is exercised separately.

DELIVERY UNDER TEST is ONLY T003's app-server `thread/inject_items` path. This
harness NEVER uses `tmux send-keys`/PTY/Herdr/turn-steer/turn-interrupt as the
delivery mechanism. Harness keystrokes (bracketed paste + arrow/Enter) are used
SOLELY to set up and submit a TEST draft, never to deliver a c2c message.

DESIGN / REUSE (no second launcher):
  * app-server launch = the T002 flag set (same argv shape as
    scripts/codex-ingress-dogfood.py).
  * injection = the T003 dev driver `dev_codex_ingress_dogfood.exe` (real adapter).
  * TTY side = tmux via scripts/c2c_tmux.py's `tmux()` primitive; deterministic
    cursor via `tmux display-message '#{cursor_x} #{cursor_y}'`; deterministic
    composer bytes via `tmux capture-pane -p`.
  * verification turn(s) = harness-owned `turn/start` on a separate authed
    observer ws connection — NEVER the adapter (the adapter has no turn surface).

Modes:
  preflight  (default) — check prerequisites WITHOUT launching codex (CI-safe).
  run                  — full live matrix. MUST run from inside tmux.

Deterministic: every wait is a bounded poll on a state/event with a timeout and
an actionable failure dump; no fixed "sleep and hope". Self-cleaning: the
app-server process group, the tmux session, and every child are torn down on
exit (including on failure); before/after `codex app-server`/`codex --remote`
process counts are reported.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_DIR = REPO_ROOT / "scripts"

# Reuse the canonical tmux primitive from c2c_tmux.py (no second launcher).
_spec = importlib.util.spec_from_file_location("c2c_tmux", SCRIPT_DIR / "c2c_tmux.py")
c2c_tmux = importlib.util.module_from_spec(_spec)
sys.modules["c2c_tmux"] = c2c_tmux  # required so its @dataclass resolves __module__
_spec.loader.exec_module(c2c_tmux)
tmux = c2c_tmux.tmux

CODEX = os.environ.get("CODEX_BIN", shutil.which("codex") or "codex")
MODEL = os.environ.get("C2C_DRAFT_MODEL", "gpt-5.3-codex-spark")
DRIVER = os.environ.get(
    "INGRESS_DRIVER",
    str(REPO_ROOT / "_build/default/ocaml/test/dev_codex_ingress_dogfood.exe"),
)

# Multibyte + multiline draft (AC: multibyte text + multiple lines).
DRAFT_L1 = "café ☕ naïve — 日本語 DRAFT_MARKER_QZX"
DRAFT_L2 = "second líne ✓ 🚀 do_not_lose_me"
DRAFT_TEXT = DRAFT_L1 + "\n" + DRAFT_L2

VOLATILE_RE = None  # discovered empirically: idle frames are byte-stable.


def log(*a):
    print(*a, flush=True)


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def try_websockets():
    try:
        import websockets  # noqa: F401
        return True
    except Exception:
        return False


# ------------------------------------------------------------------- observer
# A small synchronous authed ws JSON-RPC client used ONLY for harness actions:
#   * thread discovery (thread/loaded/list), thread/read (status),
#   * verification turns (turn/start) + turn/interrupt to reclaim quota,
#   * draining notifications to PROVE no turn/started fired on passive arrival.
# It is a HARNESS surface, never the delivery path under test.

import asyncio  # noqa: E402


class Observer:
    def __init__(self, port: int, token: str):
        self.port = port
        self.token = token
        self._ws = None
        self._id = 100
        self._loop = asyncio.new_event_loop()
        self.turn_ids_seen: list[str] = []       # (legacy; codex emits no turn/started)
        self.status_changes: list[str] = []      # thread/status/changed type stream

    def _run(self, coro):
        return self._loop.run_until_complete(coro)

    def connect(self):
        import websockets

        async def _c():
            self._ws = await websockets.connect(
                f"ws://127.0.0.1:{self.port}",
                additional_headers={"Authorization": f"Bearer {self.token}"},
                open_timeout=10,
                max_size=8 * 1024 * 1024,
            )
            await self._rpc("initialize", {
                "clientInfo": {"name": "t004-observer", "version": "0"},
                "capabilities": {"experimentalApi": True},
            })
        self._run(_c())

    async def _rpc(self, method, params, timeout=30):
        self._id += 1
        i = self._id
        await self._ws.send(json.dumps({"id": i, "method": method, "params": params or {}}))
        end = self._loop.time() + timeout
        while self._loop.time() < end:
            m = json.loads(await asyncio.wait_for(self._ws.recv(), timeout))
            self._note_turn(m)
            if m.get("id") == i and ("result" in m or "error" in m):
                return m
        return {"error": "timeout"}

    def _note_turn(self, m):
        # codex 0.144.1 does NOT emit `turn/started`; a turn's id is returned in
        # the `turn/start` RESPONSE, and the turn LIFECYCLE is signalled via
        # `thread/status/changed` (idle ↔ active). Track those transitions so the
        # no-turn proof can assert the thread never went active on passive
        # arrival, and the active-row proof can confirm the turn stayed active.
        if m.get("method") == "thread/status/changed":
            p = m.get("params") or {}
            st = (p.get("status") or {}).get("type") or p.get("status")
            if st:
                self.status_changes.append(st)

    def rpc(self, method, params, timeout=30):
        return self._run(self._rpc(method, params, timeout))

    def loaded_threads(self) -> list[str]:
        r = self.rpc("thread/loaded/list", {})
        return (r.get("result") or {}).get("data") or []

    def thread_status(self, thread_id: str) -> str:
        r = self.rpc("thread/read", {"threadId": thread_id})
        thr = ((r.get("result") or {}).get("thread") or {})
        return (thr.get("status") or {}).get("type", "?")

    def drain_status(self, seconds: float) -> list[str]:
        """Drain notifications for a BOUNDED window; return the thread-status
        transitions observed (via thread/status/changed). Fails fast (returns
        early) if a transition to `active` is seen — that is the ONLY protocol
        signal that a turn started on this codex build."""
        async def _d():
            base = len(self.status_changes)
            end = self._loop.time() + seconds
            while self._loop.time() < end:
                try:
                    m = json.loads(await asyncio.wait_for(self._ws.recv(), max(0.05, end - self._loop.time())))
                except asyncio.TimeoutError:
                    break
                self._note_turn(m)
                if self.status_changes[base:] and "active" in self.status_changes[base:]:
                    break  # fail fast: a turn started
            return self.status_changes[base:]
        return self._run(_d())

    # back-compat alias used by the passive rows (semantics now = drain_status)
    def drain_no_turn(self, seconds: float) -> list[str]:
        return self.drain_status(seconds)

    def start_turn(self, thread_id: str, prompt: str, timeout=30) -> str | None:
        """turn/start; return the turn id from the RESPONSE (result.turn.id). Does
        NOT wait for completion (caller interrupts to reclaim quota)."""
        r = self.rpc("turn/start", {
            "threadId": thread_id, "model": MODEL, "approvalPolicy": "never",
            "input": [{"type": "text", "text": prompt}]}, timeout=timeout)
        if "error" in r:
            log(f"    [observer] turn/start error: {r['error']}")
            return None
        return ((r.get("result") or {}).get("turn") or {}).get("id")

    def turn_start_raw(self, thread_id: str, prompt: str, timeout=30) -> dict:
        """turn/start returning the raw JSON-RPC response (for the T007-precursor
        serialization probe, which needs to see reject/queue behavior)."""
        return self.rpc("turn/start", {
            "threadId": thread_id, "model": MODEL, "approvalPolicy": "never",
            "input": [{"type": "text", "text": prompt}]}, timeout=timeout)

    def turn_echo(self, thread_id: str, prompt: str, timeout=120) -> str:
        """Full verification turn: run to completion, return concatenated agent
        message text (model-visible evidence). Completion is detected via
        item/completed / thread/status/changed→idle."""
        async def _t():
            self._id += 1
            i = self._id
            await self._ws.send(json.dumps({
                "id": i, "method": "turn/start",
                "params": {"threadId": thread_id, "model": MODEL,
                           "approvalPolicy": "never",
                           "input": [{"type": "text", "text": prompt}]},
            }))
            text = []
            saw_active = False
            end = self._loop.time() + timeout
            while self._loop.time() < end:
                try:
                    m = json.loads(await asyncio.wait_for(self._ws.recv(), 5))
                except asyncio.TimeoutError:
                    continue
                self._note_turn(m)
                meth = m.get("method")
                p = m.get("params") or {}
                if meth in ("item/completed", "item/agentMessage/delta",
                            "item/agentMessage/completed"):
                    it = p.get("item") or p
                    t = it.get("text") or p.get("delta") or ""
                    if isinstance(t, str) and t:
                        text.append(t)
                if meth == "thread/status/changed":
                    st = (p.get("status") or {}).get("type")
                    if st == "active":
                        saw_active = True
                    elif st == "idle" and saw_active:
                        break  # turn finished
            return "".join(text)
        return self._run(_t())

    def interrupt(self, thread_id: str, turn_id: str):
        try:
            self.rpc("turn/interrupt", {"threadId": thread_id, "turnId": turn_id}, timeout=10)
        except Exception:
            pass

    def close(self):
        try:
            if self._ws is not None:
                self._run(self._ws.close())
        except Exception:
            pass
        try:
            self._loop.close()
        except Exception:
            pass


# ------------------------------------------------------------------- proxy
# A transparent recording + fault-injecting ws JSON-RPC proxy sitting BETWEEN the
# T003 adapter and the real app-server. The adapter connects to the proxy port
# (not the app-server), so EVERY JSON-RPC method the adapter issues is recorded
# here — a wire-level proof that passive delivery only ever sends `initialize` +
# `thread/inject_items` (never turn/start|steer|interrupt|cancel, never fs/*),
# and a record of the exact injected message-id ORDER. It can also:
#   * pause() — close the listener so the adapter's next connect is REFUSED
#     (a real adapter-side disconnect; the TUI talks to the app-server directly
#     and is unaffected), and resume() to reconnect;
#   * arm_drop_inject_response() — forward one `thread/inject_items` request to
#     the server (which processes it) but DROP the response and close the adapter
#     side, reproducing T003's real ambiguous-ack window (server accepted,
#     response lost) — NOT a ledger deletion.


class ProxyRecorder:
    def __init__(self, listen_port: int, target_port: int):
        self.listen = listen_port
        self.target = target_port
        self._loop = asyncio.new_event_loop()
        self._server = None
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()
        self.record: list[dict] = []
        self.paused = False
        self._drop_inject_resp = False

    # ---- lifecycle
    def start(self):
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        # wait until the listener is accepting
        for _ in range(100):
            with socket.socket() as s:
                if s.connect_ex(("127.0.0.1", self.listen)) == 0:
                    return
            time.sleep(0.05)

    def _run(self):
        asyncio.set_event_loop(self._loop)
        self._loop.run_until_complete(self._serve())
        self._loop.run_forever()

    async def _serve(self):
        import websockets
        self._server = await websockets.serve(self._handler, "127.0.0.1", self.listen, max_size=8 * 1024 * 1024)

    async def _handler(self, client):
        import websockets
        if self.paused:
            await client.close()
            return
        auth = client.request.headers.get("Authorization")
        try:
            server = await websockets.connect(
                f"ws://127.0.0.1:{self.target}",
                additional_headers=({"Authorization": auth} if auth else None),
                open_timeout=10, max_size=8 * 1024 * 1024)
        except Exception:
            await client.close()
            return
        inject_ids: set = set()

        async def c2s():
            try:
                async for msg in client:
                    self._note(msg, inject_ids)
                    await server.send(msg)
            except Exception:
                pass
            finally:
                try:
                    await server.close()
                except Exception:
                    pass

        async def s2c():
            try:
                async for msg in server:
                    if self._drop_inject_resp:
                        try:
                            j = json.loads(msg)
                            if j.get("id") in inject_ids and ("result" in j or "error" in j):
                                self._drop_inject_resp = False
                                await client.close()  # adapter sees NO response => ambiguous
                                return
                        except Exception:
                            pass
                    await client.send(msg)
            except Exception:
                pass
            finally:
                try:
                    await client.close()
                except Exception:
                    pass
        await asyncio.gather(c2s(), s2c())

    def _note(self, msg: str, inject_ids: set):
        try:
            j = json.loads(msg)
        except Exception:
            return
        meth = j.get("method")
        if not meth:
            return
        mids: list[str] = []
        if meth == "thread/inject_items":
            inject_ids.add(j.get("id"))
            # extract message_id from the DECODED item text (the raw frame has it
            # JSON-escaped, so regex the parsed content, not the wire bytes).
            try:
                for item in (j.get("params") or {}).get("items") or []:
                    for c in (item.get("content") or []):
                        t = c.get("text") or ""
                        mids += re.findall(r'message_id="([^"]+)"', t)
            except Exception:
                pass
        with self._lock:
            self.record.append({"method": meth, "message_ids": mids})

    # ---- control (thread-safe via the loop)
    def snapshot(self) -> list[dict]:
        with self._lock:
            return list(self.record)

    def reset(self):
        with self._lock:
            self.record = []

    def methods(self) -> list[str]:
        return [r["method"] for r in self.snapshot()]

    def injected_ids(self) -> list[str]:
        out: list[str] = []
        for r in self.snapshot():
            if r["method"] == "thread/inject_items":
                out.extend(r["message_ids"])
        return out

    def _sync(self, coro, timeout=5):
        fut = asyncio.run_coroutine_threadsafe(coro, self._loop)
        return fut.result(timeout)

    async def _close_server(self):
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None

    def pause(self):
        self.paused = True
        self._sync(self._close_server())

    def resume(self):
        self.paused = False
        self._sync(self._serve())

    def arm_drop_inject_response(self):
        self._drop_inject_resp = True

    def stop(self):
        try:
            self._sync(self._close_server())
        except Exception:
            pass
        try:
            self._loop.call_soon_threadsafe(self._loop.stop)
        except Exception:
            pass


class _AdapterResult(list):
    """A list of per-pass dicts that also carries the adapter's exit code and the
    proxy-recorded wire trace for the run."""
    returncode: int = 0
    wire_methods: list = []
    wire_ids: list = []


# --------------------------------------------------------------------- harness


class DraftPreservationHarness:
    def __init__(self, run_dir: Path):
        self.run_dir = run_dir
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.port = free_port()
        self.proxy_port = free_port()   # adapter → proxy → app-server
        self.token = secrets.token_hex(32)
        self.sha = hashlib.sha256(self.token.encode()).hexdigest()
        self.broker_root = str(self.run_dir / "broker")
        Path(self.broker_root).mkdir(parents=True, exist_ok=True)
        self.session = f"t004tui-{os.getpid()}"
        self.appserver = None
        self.appserver_pid: int | None = None
        self.appserver_log = str(self.run_dir / "appserver.log")
        self.observer: Observer | None = None
        self.proxy: ProxyRecorder | None = None
        self.thread_id: str | None = None
        self.results: list[tuple[str, bool, str]] = []
        self._snap_n = 0

    # ---- the recording proxy the adapter's traffic flows through
    def start_proxy(self):
        self.proxy = ProxyRecorder(self.proxy_port, self.port)
        self.proxy.start()
        log(f"[setup] recording proxy up: adapter → ws://127.0.0.1:{self.proxy_port} "
            f"→ app-server ws://127.0.0.1:{self.port}")

    ALLOWED_ADAPTER_METHODS = {"initialize", "thread/inject_items"}

    def assert_wire_clean(self, name: str, methods: list[str], min_injects: int = 1):
        """Wire-level no-turn proof: the adapter connection carried ONLY
        initialize + thread/inject_items — never turn/start|steer|interrupt|
        cancel, never fs/*. Recorded by the in-path proxy, so it cannot be gamed
        by status polling."""
        forbidden = [m for m in methods if m not in self.ALLOWED_ADAPTER_METHODS]
        injects = sum(1 for m in methods if m == "thread/inject_items")
        ok = not forbidden and injects >= min_injects
        self._record(name, ok,
                     f"adapter wire methods={methods} (allowed only "
                     f"{sorted(self.ALLOWED_ADAPTER_METHODS)}); forbidden={forbidden}; "
                     f"inject_items={injects} (>= {min_injects})")

    # ---- process discipline
    def _proc_count(self) -> int:
        # Match ONLY THIS run's own invocations — the app-server bound to OUR port
        # and the remote TUI attached to OUR port — so a concurrent unrelated
        # codex run on a different port is never miscounted, and no shell whose
        # argv contains the search string is matched.
        pat = (rf"app-server --listen ws://127\.0\.0\.1:{self.port}\b"
               rf"|--remote ws://127\.0\.0\.1:{self.port}\b")
        out = subprocess.run(["pgrep", "-af", pat], capture_output=True, text=True).stdout
        lines = [ln for ln in out.splitlines()
                 if "pgrep" not in ln and "codex-draft-preservation" not in ln]
        return len(lines)

    def start_appserver(self):
        argv = [CODEX, "app-server", "--listen", f"ws://127.0.0.1:{self.port}",
                "--ws-auth", "capability-token", "--ws-token-sha256", self.sha,
                "-c", f'model="{MODEL}"']
        f = open(self.appserver_log, "w")
        self.appserver = subprocess.Popen(argv, stdout=f, stderr=subprocess.STDOUT,
                                          start_new_session=True)
        self.appserver_pid = self.appserver.pid
        log(f"[setup] app-server pid={self.appserver.pid} endpoint=ws://127.0.0.1:{self.port} "
            f"(token sha256={self.sha[:12]}… REDACTED)")
        if not self._wait(lambda: self._port_open(), 25, "app-server bind"):
            raise RuntimeError("app-server never bound")

    def _port_open(self) -> bool:
        with socket.socket() as s:
            return s.connect_ex(("127.0.0.1", self.port)) == 0

    def start_tui(self):
        tmux("kill-session", "-t", self.session, check=False)
        tmux("new-session", "-d", "-s", self.session, "-x", "120", "-y", "40", "bash")
        # Pin the frontend model too so any submitted turn also uses spark.
        cmd = (f"cd {REPO_ROOT}; TOK={self.token} {CODEX} --remote "
               f"ws://127.0.0.1:{self.port} --remote-auth-token-env TOK "
               f'-c model="{MODEL}"')
        tmux("send-keys", "-t", self.session, cmd, "Enter", check=False)
        # Deterministic readiness: wait for the composer prompt glyph to render.
        if not self._wait(lambda: "›" in self.capture_frame(), 40, "TUI composer render"):
            raise RuntimeError("TUI composer never rendered")
        # The stock TUI emits a one-shot, late-rendering "Skill descriptions were
        # shortened" warning several seconds into the session. Wait for it
        # explicitly (bounded; non-fatal if absent) so it can never appear
        # mid-scenario and confound a byte-exact frame diff.
        self._wait(lambda: "Skill descriptions were shortened" in self.capture_frame(),
                   25, "one-shot skill-shortened warning", quiet=True)
        # let model-load banner + that warning finish painting
        self.settle(timeout=35, consecutive=4)
        log("[setup] remote TUI rendered + settled")

    def observer_connect(self):
        self.observer = Observer(self.port, self.token)
        self.observer.connect()
        if not self._wait(lambda: bool(self.observer.loaded_threads()), 20, "thread/loaded/list"):
            raise RuntimeError("no loaded thread discovered via thread/loaded/list")
        self.thread_id = self.observer.loaded_threads()[0]
        log(f"[setup] discovered TUI thread: {self.thread_id}")

    def settle(self, timeout: float = 25.0, interval: float = 1.0, consecutive: int = 3) -> bool:
        """Wait until the TUI stops repainting: the frame is byte-identical across
        `consecutive` successive `interval` captures AND the model banner is no
        longer 'loading'. The consecutive requirement outlasts late async renders
        (model-load banner, the one-shot 'Skill descriptions were shortened'
        warning). Deterministic readiness (wait on a stability STATE, not a fixed
        sleep)."""
        end = time.monotonic() + timeout
        prev = self.capture_frame()
        streak = 0
        while time.monotonic() < end:
            time.sleep(interval)
            cur = self.capture_frame()
            if cur == prev and "model:     loading" not in cur:
                streak += 1
                if streak >= consecutive:
                    return True
            else:
                streak = 0
            prev = cur
        return False

    # ---- tmux capture / cursor (deterministic; default session, overridable)
    def capture_frame(self, session: str | None = None) -> str:
        return tmux("capture-pane", "-t", session or self.session, "-p").stdout

    def capture_scrollback(self, lines: int = 400, session: str | None = None) -> str:
        return tmux("capture-pane", "-t", session or self.session, "-p", "-S", f"-{lines}").stdout

    def cursor(self, session: str | None = None) -> tuple[int, int]:
        out = tmux("display-message", "-t", session or self.session, "-p", "#{cursor_x} #{cursor_y}").stdout.strip()
        x, y = out.split()
        return int(x), int(y)

    @staticmethod
    def composer_block(frame: str):
        """Return (start_index, [composer lines]). The composer input block is
        the line beginning with the '›' prompt glyph plus its continuation lines,
        up to the status bar or a blank gap. `start_index` is the 0-based pane row
        of the '›' line — used to derive a cursor position RELATIVE to the
        composer, invariant to chrome/transcript above it shifting the block.

        The composer is the BOTTOM-MOST '›' block: transcript user-messages ALSO
        render with a leading '›', and during an active turn the turn's own prompt
        appears in the transcript above the composer. Scanning from the bottom
        selects the live input composer, never a transcript echo."""
        lines = frame.splitlines()
        start = None
        for i in range(len(lines) - 1, -1, -1):
            if lines[i].startswith("›"):
                start = i
                break
        if start is None:
            return None, []
        region = [lines[start]]
        for ln in lines[start + 1:]:
            if "· Context" in ln or "used ·" in ln or ln.strip() == "":
                break
            region.append(ln)
        return start, region

    def snapshot(self, tag: str, session: str | None = None) -> dict:
        """Atomic-enough sample: capture frame A, read the cursor, capture frame B,
        and accept only when the composer BLOCK is identical across A and B — so a
        repaint during active streaming cannot desync `cursor_y − composer_start`
        (mask or fabricate a relative move). Retries briefly if the composer is
        mid-repaint."""
        self._snap_n += 1
        frame = self.capture_frame(session)
        cur = self.cursor(session)
        block = self.composer_block(frame)
        for _ in range(12):
            frame2 = self.capture_frame(session)
            block2 = self.composer_block(frame2)
            if block == block2:
                break  # composer stable across the cursor read
            time.sleep(0.15)
            frame = frame2
            cur = self.cursor(session)
            block = block2
        start, region = block
        rel = (cur[0], (cur[1] - start) if start is not None else None)
        p = self.run_dir / f"snap-{self._snap_n:02d}-{tag}.txt"
        p.write_text(frame)
        return {"tag": tag, "frame": frame, "cursor": cur, "composer": region,
                "composer_start": start, "rel_cursor": rel, "path": str(p)}

    def _composer_is_empty(self) -> bool:
        """True iff the BOTTOM composer holds no user text: cursor at the prompt
        start (rel (≤2, 0)) with a single composer line and no draft marker in it.
        Scoped to the composer region so a submitted draft lingering in the
        transcript never confuses the check."""
        frame = self.capture_frame()
        start, region = self.composer_block(frame)
        if start is None:
            return False
        cur = self.cursor()
        return (cur[0] <= 2 and (cur[1] - start) == 0 and len(region) == 1
                and "DRAFT_MARKER_QZX" not in "".join(region))

    def _composer_has(self, marker: str) -> bool:
        _s, region = self.composer_block(self.capture_frame())
        return marker in "".join(region)

    # ---- composer draft manipulation (harness keystrokes; NOT the delivery path)
    def clear_composer(self):
        # kill-to-start then generous backspace/delete, then verify empty (scoped
        # to the composer region, not the whole frame).
        tmux("send-keys", "-t", self.session, "-N", "400", "BSpace", check=False)
        tmux("send-keys", "-t", self.session, "-N", "400", "DC", check=False)
        self._wait(self._composer_is_empty, 6, "composer clear", quiet=True)

    def set_draft(self, text: str, marker: str):
        self.clear_composer()
        buf = f"t004draft-{os.getpid()}"
        bufpath = self.run_dir / "draft.txt"
        bufpath.write_text(text)
        tmux("load-buffer", "-b", buf, str(bufpath), check=False)
        tmux("paste-buffer", "-p", "-b", buf, "-t", self.session, check=False)
        # wait for the marker to land in the COMPOSER region specifically.
        if not self._wait(lambda: self._composer_has(marker), 8, f"draft marker {marker}"):
            raise RuntimeError(f"draft marker {marker} never rendered in composer")

    def move_cursor_mid(self, left_count: int):
        tmux("send-keys", "-t", self.session, "-N", str(left_count), "Left", check=False)
        # settle: cursor query is instantaneous, but give the TUI a paint tick
        self._wait(lambda: True, 0.3, "cursor-move settle", quiet=True)

    def submit_composer(self):
        # extended-keys off so Enter submits (per tui-snapshot.sh finding).
        prev = tmux("show", "-sv", "extended-keys", check=False).stdout.strip() or "off"
        tmux("set", "-s", "extended-keys", "off", check=False)
        tmux("send-keys", "-t", self.session, "Enter", check=False)
        tmux("set", "-s", "extended-keys", prev, check=False)

    # ---- broker inbox + real T003 adapter
    def seed_inbox(self, session_id: str, msgs: list[dict]):
        path = Path(self.broker_root) / f"{session_id}.inbox.json"
        path.write_text(json.dumps(msgs))
        return str(path)

    @staticmethod
    def mk_msg(from_alias, to_alias, content, ts, message_id):
        return {"from_alias": from_alias, "to_alias": to_alias, "content": content,
                "ts": ts, "deferrable": False, "ephemeral": False,
                "reply_via": None, "enc_status": None, "message_id": message_id}

    def run_adapter(self, session_id: str, passes: int = 1, endpoint_port: int | None = None,
                    through_proxy: bool = True, reset_proxy: bool = True) -> list[dict]:
        """Run the REAL T003 adapter (dev_codex_ingress_dogfood.exe). By default
        the adapter connects through the RECORDING PROXY (so its wire traffic is
        audited). Returns per-pass dicts {inject_calls, health, states} plus, on
        the list object, `.wire_methods` / `.wire_ids` from the proxy for this
        run. `endpoint_port` forces a specific target (e.g. a dead port). The
        driver realpath + a zero exit code are asserted, so a stale/fake driver
        cannot silently satisfy the proof."""
        drv = Path(DRIVER).resolve()
        if "_build/" not in str(drv):
            raise RuntimeError(f"INGRESS_DRIVER is not the built T003 adapter under _build/: {drv}")
        if endpoint_port is not None:
            port = endpoint_port
        elif through_proxy:
            port = self.proxy_port
        else:
            port = self.port
        if through_proxy and reset_proxy and self.proxy:
            self.proxy.reset()
        env = dict(os.environ)
        env.update({
            "C2C_MCP_BROKER_ROOT": self.broker_root,
            "C2C_CODEX_INGRESS_SESSION": session_id,
            "C2C_CODEX_INGRESS_ENDPOINT": f"ws://127.0.0.1:{port}",
            "C2C_CODEX_INGRESS_THREAD": self.thread_id,
            "C2C_CODEX_INGRESS_TOKEN": self.token,
            "C2C_CODEX_INGRESS_LIVE": "1",
        })
        res = subprocess.run([str(drv), str(passes)], env=env, capture_output=True, text=True)
        out: list = []
        for line in res.stdout.splitlines():
            if not line.startswith("PASS "):
                continue
            try:
                calls = int(line.split("real_inject_calls=")[1].split()[0])
                health = json.loads(line.split("health=")[1].split(" states=")[0])
                states = json.loads(line.split("states=")[1])
            except Exception:
                calls, health, states = -1, {}, []
            out.append({"inject_calls": calls, "health": health, "states": states})
        # attach the driver exit + proxy wire trace for this run
        out_wrap = _AdapterResult(out)
        out_wrap.returncode = res.returncode
        if through_proxy and self.proxy:
            out_wrap.wire_methods = self.proxy.methods()
            out_wrap.wire_ids = self.proxy.injected_ids()
        if not out or res.returncode != 0:
            log(f"    [adapter] rc={res.returncode} stdout:\n" + res.stdout)
            log("    [adapter] stderr:\n" + res.stderr)
        return out_wrap

    # ---- deterministic wait
    def _wait(self, pred, timeout: float, what: str, interval=0.25, quiet=False) -> bool:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                if pred():
                    return True
            except Exception:
                pass
            time.sleep(interval)
        if not quiet:
            log(f"    [wait-timeout] {what} did not become true within {timeout}s")
        return False

    # ---- assertions
    def _record(self, name: str, ok: bool, detail: str):
        self.results.append((name, ok, detail))
        log(f"  [{'PASS' if ok else 'FAIL'}] {name} — {detail}")

    def _finding(self, name: str, detail: str):
        """Informational observation (e.g. the T007-precursor exploration). Logged
        + persisted but NEVER counted toward the pass/fail gate, so a turn/start
        anomaly can never fail the passive-injection matrix."""
        if not hasattr(self, "findings"):
            self.findings = []
        self.findings.append((name, detail))
        log(f"  [NOTE] {name} — {detail}")

    def _dump_fail(self, name, before, after):
        safe = name.replace("/", "_")
        (self.run_dir / f"FAIL-{safe}-before.txt").write_text(before["frame"])
        (self.run_dir / f"FAIL-{safe}-after.txt").write_text(after["frame"])
        import difflib
        diff = "".join(difflib.unified_diff(
            before["frame"].splitlines(True), after["frame"].splitlines(True),
            "before", "after"))
        (self.run_dir / f"FAIL-{safe}.diff").write_text(diff)
        return diff

    def assert_draft_preserved(self, name, before: dict, after: dict):
        """NON-EMPTY draft: the composer region bytes (the user's real draft text,
        which replaces any placeholder) must be identical, and the cursor RELATIVE
        to the composer must be identical, across the arrival."""
        ok = (before["composer"] == after["composer"]
              and before["rel_cursor"] == after["rel_cursor"]
              and before["composer"] != [])
        preview = " ⏎ ".join(before["composer"])[:90]
        if ok:
            self._record(name, True,
                         f"composer bytes identical ({len(before['composer'])} lines: {preview!r}); "
                         f"rel-cursor {before['rel_cursor']} stable "
                         f"(abs {before['cursor']}→{after['cursor']}; chrome-shift tolerated)")
        else:
            diff = self._dump_fail(name, before, after)
            self._record(name, False,
                         f"composer before={before['composer']!r} after={after['composer']!r}; "
                         f"rel-cursor before={before['rel_cursor']} after={after['rel_cursor']}; "
                         f"frame diff:\n{diff[:900]}")

    def assert_empty_preserved(self, name, before: dict, after: dict):
        """EMPTY composer: prove arrival inserted NO text and moved NO cursor.
        We require (a) the composer region BYTE-IDENTICAL before/after — this is
        what catches an inserted glyph even when the cursor stays at col ≤2, so
        the check is NOT vacuous — (b) rel-cursor identical, and (c) the state is
        genuinely the empty composer (cursor at prompt start col ≤2, rel row 0,
        single composer line). The composer is captured settled, so its rotating
        placeholder is stable across the short arrival window; a placeholder
        rotation would fail-safe (conservative), never mask an insertion."""
        def is_empty(snap):
            return (snap["rel_cursor"] is not None
                    and snap["rel_cursor"][1] == 0
                    and snap["cursor"][0] <= 2
                    and len(snap["composer"]) == 1)
        ok = (is_empty(before) and is_empty(after)
              and before["composer"] == after["composer"]      # byte-exact: no insert
              and before["rel_cursor"] == after["rel_cursor"])
        if ok:
            self._record(name, True,
                         f"composer byte-identical + empty at prompt start ({before['composer']!r}); "
                         f"rel-cursor {before['rel_cursor']} stable (abs {before['cursor']}→{after['cursor']})")
        else:
            diff = self._dump_fail(name, before, after)
            self._record(name, False,
                         f"empty-check before(composer={before['composer']!r},rel={before['rel_cursor']}) "
                         f"after(composer={after['composer']!r},rel={after['rel_cursor']}); diff:\n{diff[:900]}")

    # ---- teardown
    def teardown(self):
        log("[teardown] tearing down …")
        if self.observer:
            self.observer.close()
        if self.proxy:
            try:
                self.proxy.stop()
            except Exception:
                pass
        # per-owned-resource cleanup receipt
        appserver_alive_before = self.appserver_pid is not None and self._pid_alive(self.appserver_pid)
        tmux("kill-session", "-t", self.session, check=False)
        if self.appserver:
            try:
                os.killpg(os.getpgid(self.appserver.pid), signal.SIGTERM)
                self.appserver.wait(timeout=5)
            except Exception:
                try:
                    os.killpg(os.getpgid(self.appserver.pid), signal.SIGKILL)
                except Exception:
                    pass
        appserver_alive_after = self.appserver_pid is not None and self._pid_alive(self.appserver_pid)
        remaining = self._proc_count()
        log(f"[teardown] owned app-server pid={self.appserver_pid} "
            f"alive before={appserver_alive_before} after={appserver_alive_after}; "
            f"tmux session '{self.session}' killed; proxy stopped; "
            f"loopback app-server/remote procs on our ports remaining: {remaining}")
        return remaining

    @staticmethod
    def _pid_alive(pid: int) -> bool:
        try:
            os.kill(pid, 0)
            return True
        except Exception:
            return False


# ------------------------------------------------------------------- scenarios


def scenario_idle_empty(h, ob):
    log("\n=== Row 1: idle remote TUI, composer EMPTY ===")
    h.clear_composer()
    sess = "r1idle"
    h.settle()
    before = h.snapshot("r1-before")
    status_before = ob.thread_status(h.thread_id)
    turns_before = list(ob.turn_ids_seen)
    mid = "r1-" + secrets.token_hex(3)
    h.seed_inbox(sess, [h.mk_msg("peer-r1", sess, f"row1 idle-empty {mid}", 1000.0, mid)])
    passes = h.run_adapter(sess, 1)
    seen = ob.drain_no_turn(1.5)
    after = h.snapshot("r1-after")
    status_after = ob.thread_status(h.thread_id)
    inj = passes[0]["inject_calls"] if passes else -1
    h.assert_empty_preserved("row1/draft-empty-preserved", before, after)
    h._record("row1/no-new-turn", status_before == "idle" and status_after == "idle"
               and "active" not in seen,
               f"status {status_before}->{status_after}; status-transitions-on-arrival={seen} "
               f"(no active => no turn; codex emits no turn/started, lifecycle via thread/status/changed)")
    h._record("row1/injected-1", inj == 1 and passes.returncode == 0, f"real_inject_calls={inj} rc={passes.returncode} health.injected={passes[0]['health'].get('injected_count') if passes else '?'}")
    h.assert_wire_clean("row1/wire-only-initialize+inject", passes.wire_methods)
    return mid


def scenario_idle_draft(h, ob):
    log("\n=== Row 2: idle remote TUI, composer NON-EMPTY (cursor mid-text) ===")
    sess = "r2idle"
    h.set_draft(DRAFT_TEXT, "DRAFT_MARKER_QZX")
    h.move_cursor_mid(10)  # cursor into the middle of line 2
    h.settle()
    before = h.snapshot("r2-before")
    status_before = ob.thread_status(h.thread_id)
    turns_before = list(ob.turn_ids_seen)
    mid = "r2-" + secrets.token_hex(3)
    h.seed_inbox(sess, [h.mk_msg("peer-r2", sess, f"row2 idle-draft {mid}", 1000.0, mid)])
    passes = h.run_adapter(sess, 1)
    seen = ob.drain_no_turn(1.5)
    after = h.snapshot("r2-after")
    status_after = ob.thread_status(h.thread_id)
    inj = passes[0]["inject_calls"] if passes else -1
    h.assert_draft_preserved("row2/draft-byte-exact-preserved", before, after)
    h._record("row2/no-start-steer-cancel-submit",
              status_before == "idle" and status_after == "idle" and "active" not in seen,
              f"status {status_before}->{status_after}; status-transitions-on-arrival={seen} (no active => no turn/steer/cancel/submit)")
    h._record("row2/injected-1", inj == 1 and passes.returncode == 0, f"real_inject_calls={inj} rc={passes.returncode}")
    h.assert_wire_clean("row2/wire-only-initialize+inject", passes.wire_methods)
    # after-submit: the OPERATOR presses Enter -> the composer empties (the draft
    # moves into the transcript as the submitted user turn) and the thread goes
    # active. Detect via composer emptying (block back to a single prompt line at
    # rel-cursor (2,0)), NOT via marker-absence (the marker survives in the
    # transcript). Proves the draft was intact enough to submit, and that
    # SUBMISSION (operator action) — not passive arrival — is what starts a turn.
    sc_before = len(ob.status_changes)
    h.submit_composer()
    emptied = h._wait(h._composer_is_empty, 10, "composer empties on submit")
    went_active = h._wait(lambda: (ob.drain_status(0.5) or True)
                          and "active" in ob.status_changes[sc_before:], 12,
                          "thread active on submit", quiet=True)
    aftersub = h.snapshot("r2-aftersubmit")
    h._record("row2/after-submit-clears-and-starts-turn", emptied and went_active,
              f"composer emptied={emptied}; thread went active on submit={went_active} "
              f"(operator Enter starts the turn; arrival never did); snap={aftersub['path']}")
    # reclaim quota: interrupt whatever the operator submit started
    st = ob.thread_status(h.thread_id)
    if st == "active":
        rd = ob.rpc("thread/read", {"threadId": h.thread_id})
        # best-effort interrupt: try reading the active turn id, else send a bare
        # interrupt (harness cleanup, not part of the proof)
        ob.rpc("turn/interrupt", {"threadId": h.thread_id}, timeout=8)
        h._wait(lambda: ob.thread_status(h.thread_id) == "idle", 10, "post-submit interrupt -> idle", quiet=True)
    return mid


ACTIVE_PROMPT = ("Count slowly from 1 to 60, one number per line, and add a short "
                 "reflective sentence after each number. Do not stop early.")


def _start_active_turn(h, ob, tag):
    """Start a long harness turn and confirm the thread is active. Returns the
    turn id (from the turn/start response) or None."""
    active_turn = ob.start_turn(h.thread_id, ACTIVE_PROMPT, timeout=30)
    if not active_turn:
        return None
    if not h._wait(lambda: ob.thread_status(h.thread_id) == "active", 20, f"{tag} thread active"):
        ob.interrupt(h.thread_id, active_turn)
        return None
    return active_turn


def scenario_active_empty(h, ob):
    log("\n=== Row 3: ACTIVE generation, composer EMPTY ===")
    sess = "r3active"
    h.clear_composer()
    active_turn = _start_active_turn(h, ob, "row3")
    if not active_turn:
        h._record("row3/setup-active-turn", False, "could not start/confirm an active turn")
        return None
    before = h.snapshot("r3-before")
    sc_before = len(ob.status_changes)
    mid = "r3-" + secrets.token_hex(3)
    h.seed_inbox(sess, [h.mk_msg("peer-r3", sess, f"row3 active-empty {mid}", 1000.0, mid)])
    passes = h.run_adapter(sess, 1)
    ob.drain_status(1.5)
    after = h.snapshot("r3-after")
    status_after = ob.thread_status(h.thread_id)
    transitions = ob.status_changes[sc_before:]
    inj = passes[0]["inject_calls"] if passes else -1
    # composer stays empty (rel-cursor at prompt start) even as the transcript
    # grows during the active turn; the SAME turn keeps running (no new
    # active→idle→active cycle, no interrupt).
    h.assert_empty_preserved("row3/composer-empty-unchanged", before, after)
    h._record("row3/same-turn-not-steered-not-interrupted",
              status_after == "active" and "idle" not in transitions,
              f"turn {active_turn} still active={status_after=='active'}; "
              f"status-transitions-during-arrival={transitions} (no idle => turn not interrupted/steered)")
    h._record("row3/injected-1", inj == 1 and passes.returncode == 0, f"real_inject_calls={inj} rc={passes.returncode}")
    h.assert_wire_clean("row3/wire-no-steer-no-interrupt-during-active", passes.wire_methods)
    ob.interrupt(h.thread_id, active_turn)
    h._wait(lambda: ob.thread_status(h.thread_id) == "idle", 12, "turn interrupt -> idle", quiet=True)
    return mid


def scenario_active_draft(h, ob):
    log("\n=== Row 4: ACTIVE generation, NON-EMPTY draft ===")
    sess = "r4active"
    h.set_draft(DRAFT_TEXT, "DRAFT_MARKER_QZX")
    active_turn = _start_active_turn(h, ob, "row4")
    if not active_turn:
        h._record("row4/setup-active-turn", False, "could not start/confirm an active turn")
        return None
    before = h.snapshot("r4-before")
    sc_before = len(ob.status_changes)
    mid = "r4-" + secrets.token_hex(3)
    h.seed_inbox(sess, [h.mk_msg("peer-r4", sess, f"row4 active-draft {mid}", 1000.0, mid)])
    passes = h.run_adapter(sess, 1)
    ob.drain_status(1.5)
    after = h.snapshot("r4-after")
    status_after = ob.thread_status(h.thread_id)
    transitions = ob.status_changes[sc_before:]
    inj = passes[0]["inject_calls"] if passes else -1
    # transcript legitimately changes (in-flight turn) -> compare COMPOSER region.
    h.assert_draft_preserved("row4/draft-preserved-during-active", before, after)
    h._record("row4/no-extra-turn-id-stable",
              status_after == "active" and "idle" not in transitions,
              f"active turn {active_turn} stable={status_after=='active'}; "
              f"status-transitions-during-arrival={transitions} (no new turn / no interrupt)")
    h._record("row4/injected-1", inj == 1 and passes.returncode == 0, f"real_inject_calls={inj} rc={passes.returncode}")
    h.assert_wire_clean("row4/wire-no-steer-no-interrupt-during-active", passes.wire_methods)
    ob.interrupt(h.thread_id, active_turn)
    h._wait(lambda: ob.thread_status(h.thread_id) == "idle", 12, "turn interrupt -> idle", quiet=True)
    return mid


def scenario_disconnect_reconnect(h, ob):
    log("\n=== Row 5: app-server adapter disconnect/reconnect, NON-EMPTY draft ===")
    sess = "r5recon"
    h.set_draft(DRAFT_TEXT, "DRAFT_MARKER_QZX")
    h.settle()
    before = h.snapshot("r5-before")
    status_before = ob.thread_status(h.thread_id)
    turns_before = list(ob.turn_ids_seen)
    mid = "r5-" + secrets.token_hex(3)
    h.seed_inbox(sess, [h.mk_msg("peer-r5", sess, f"row5 recon {mid}", 1000.0, mid)])
    # 1) REAL adapter↔app-server connection loss: pause the in-path proxy so the
    #    adapter's next connect is REFUSED. The remote TUI talks to the app-server
    #    DIRECTLY (not the proxy), so its draft is unaffected. The inject fails
    #    recoverably → the message stays durably Pending_injection (no loss).
    h.proxy.pause()
    p_fail = h.run_adapter(sess, 1)
    mid_snap = h.snapshot("r5-during-outage")
    fail_state = (p_fail[0]["states"][0]["state"] if p_fail and p_fail[0]["states"] else "?")
    # 2) reconnect the adapter's endpoint and poll passes until the message reaches
    #    `injected` — a bounded wait on the DELIVERY STATE (each pass returns the
    #    state; no fixed sleep). The first retry is also gated by T003's backoff.
    h.proxy.resume()
    ok_state = "?"
    def injected_yet():
        nonlocal ok_state
        p = h.run_adapter(sess, 1)
        ok_state = (p[0]["states"][0]["state"] if p and p[0]["states"] else "?")
        return ok_state == "injected"
    reconnected = h._wait(injected_yet, 30, "row5 reconnect → injected", interval=0.75)
    seen = ob.drain_no_turn(1.5)
    after = h.snapshot("r5-after")
    status_after = ob.thread_status(h.thread_id)
    # 3) idempotency: a further pass must inject ZERO times (exactly one visible).
    p_recheck = h.run_adapter(sess, 1)
    recheck_calls = p_recheck[0]["inject_calls"] if p_recheck else -1
    h.assert_draft_preserved("row5/draft-preserved-across-reconnect", before, after)
    h._record("row5/draft-preserved-during-outage",
              before["composer"] == mid_snap["composer"] and before["rel_cursor"] == mid_snap["rel_cursor"],
              "outage-window composer bytes + rel-cursor identical to before")
    h._record("row5/retry-contract-one-visible-item",
              fail_state == "pending_injection" and reconnected and ok_state == "injected" and recheck_calls == 0,
              f"connection-refused outage state={fail_state} (durable, no loss) -> reconnect state={ok_state}; "
              f"idempotent recheck inject_calls={recheck_calls} (exactly one model-visible item)")
    h._record("row5/no-turn",
              status_before == "idle" and status_after == "idle" and "active" not in seen,
              f"status {status_before}->{status_after}; status-transitions-on-arrival={seen} (no active => no turn)")
    return mid


def scenario_burst_and_retry(h, ob):
    log("\n=== Burst of 3 in order + retry the MIDDLE with same id (acknowledged) ===")
    sess = "burst"
    h.clear_composer()
    m1 = "burst1-" + secrets.token_hex(3)
    m2 = "burst2-" + secrets.token_hex(3)
    m3 = "burst3-" + secrets.token_hex(3)
    msgs = [
        h.mk_msg("peer-b", sess, f"BURST_ONE {m1}", 1000.0, m1),
        h.mk_msg("peer-b", sess, f"BURST_TWO {m2}", 1001.0, m2),
        h.mk_msg("peer-b", sess, f"BURST_THREE {m3}", 1002.0, m3),
    ]
    h.seed_inbox(sess, msgs)
    p1 = h.run_adapter(sess, 1)              # proxy record reset → captures this pass
    wire1 = list(p1.wire_ids)               # ORDERED message_ids as injected on the wire
    # retry the MIDDLE with the same id: re-run the SAME inbox (m1/m2/m3 already
    # Injected). The ledger dedups → ZERO re-injections (exactly one visible per id).
    p2 = h.run_adapter(sess, 1)
    wire2 = list(p2.wire_ids)
    c1 = p1[0]["inject_calls"] if p1 else -1
    c2 = p2[0]["inject_calls"] if p2 else -1
    states1 = {s["message_id"]: s["state"] for s in (p1[0]["states"] if p1 else [])}
    all_injected = all(states1.get(m) == "injected" for m in (m1, m2, m3))
    # visible ORDER proven at the WIRE: the proxy saw inject_items for m1,m2,m3
    # in exactly that order, each exactly once.
    h._record("burst/three-injected-in-order",
              c1 == 3 and all_injected and wire1 == [m1, m2, m3],
              f"pass1 inject_calls={c1}; wire inject order={wire1} (expected [1,2,3]={[m1, m2, m3]}); states={states1}")
    h._record("burst/same-id-retry-exactly-once",
              c2 == 0 and wire2 == [] and wire1.count(m2) == 1,
              f"pass2 (same ids) inject_calls={c2}, wire injects={wire2} (0 re-injections); "
              f"middle id '{m2}' injected exactly once (wire count={wire1.count(m2)})")
    return (m1, m2, m3)


def scenario_ambiguous_at_least_once(h, ob):
    log("\n=== Ambiguous-ack AT-LEAST-ONCE (T003 contract) — REAL response-loss, draft present ===")
    # T003's actual ambiguous window: the server ACCEPTS thread/inject_items (item
    # is in history) but the RESPONSE is lost before the ledger commits, leaving an
    # `Injecting` marker. We reproduce it faithfully with the in-path proxy: it
    # forwards the inject request to the app-server (which processes it) then DROPS
    # the response and closes the adapter side → the adapter observes
    # Inj_ambiguous "connection_closed_before_response". On the next pass the
    # `Injecting` entry is reconciled: thread/read (history_contains) cannot
    # confirm the marker on this codex (no item list), so it re-injects — the
    # documented AT-LEAST-ONCE. Draft must stay byte-exact + no turn across both.
    sess = "ambig"
    h.set_draft(DRAFT_TEXT, "DRAFT_MARKER_QZX")
    h.settle()
    before = h.snapshot("ambig-before")
    status_before = ob.thread_status(h.thread_id)
    mid = "ambig-" + secrets.token_hex(3)
    h.seed_inbox(sess, [h.mk_msg("peer-ambig", sess, f"ambiguous {mid}", 1000.0, mid)])
    # pass 1: proxy drops the inject RESPONSE → real ambiguous ack (server got the
    # item; the adapter sees connection-closed-before-response → `Injecting`).
    h.proxy.arm_drop_inject_response()
    p1 = h.run_adapter(sess, 1)
    state1 = (p1[0]["states"][0]["state"] if p1 and p1[0]["states"] else "?")
    total_wire_injects = list(p1.wire_ids).count(mid)   # server received it here
    # reconcile: the `Injecting` entry is retried on later passes (gated by T003
    # backoff). Poll passes until the state RESOLVES to `injected`, counting every
    # re-inject the server actually receives (at-least-once on this codex, whose
    # thread/read exposes no item list so history_contains cannot confirm).
    final_state = state1
    def resolved():
        nonlocal final_state, total_wire_injects
        p = h.run_adapter(sess, 1)
        total_wire_injects += list(p.wire_ids).count(mid)
        final_state = (p[0]["states"][0]["state"] if p and p[0]["states"] else "?")
        return final_state == "injected"
    got_injected = h._wait(resolved, 20, "ambiguous reconcile → injected", interval=0.75)
    seen = ob.drain_no_turn(1.5)
    after = h.snapshot("ambig-after")
    status_after = ob.thread_status(h.thread_id)
    # AT-LEAST-ONCE: the server received the inject at least once (pass1 ambiguous
    # + reconcile re-injects), and the message ends up delivered.
    h._record("ambiguous/real-response-loss-at-least-once",
              state1 == "injecting" and got_injected and total_wire_injects >= 1,
              f"pass1 ambiguous (response dropped) state={state1}; reconciled to state={final_state}; "
              f"server received the inject {total_wire_injects}x total => AT-LEAST-ONCE "
              f"(≥1; exactly-once NOT claimed across the ambiguous window)")
    h.assert_draft_preserved("ambiguous/draft-preserved-both-injections", before, after)
    h._record("ambiguous/no-turn",
              status_before == "idle" and status_after == "idle" and "active" not in seen,
              f"status {status_before}->{status_after}; status-transitions-on-arrival={seen} (no active => no turn)")
    # secondary, SEPARATELY LABELED: ledger-loss corruption recovery (not the
    # ambiguous window) — if the persisted ledger is destroyed after a clean ack,
    # a later pass cannot confirm delivery and re-injects (at-least-once). Proves
    # graceful degradation on state loss.
    sess2 = "ledgerloss"
    mid2 = "ledgerloss-" + secrets.token_hex(3)
    h.seed_inbox(sess2, [h.mk_msg("peer-ll", sess2, f"ledgerloss {mid2}", 1000.0, mid2)])
    q1 = h.run_adapter(sess2, 1)
    lc1 = q1[0]["inject_calls"] if q1 else -1
    ledger = Path(h.broker_root) / "codex-appserver-ingress" / f"{sess2}.ledger.json"
    removed = False
    try:
        ledger.unlink(); removed = True
    except FileNotFoundError:
        pass
    q2 = h.run_adapter(sess2, 1)
    lc2 = q2[0]["inject_calls"] if q2 else -1
    h._record("ambiguous/ledger-loss-recovery-at-least-once",
              lc1 == 1 and removed and lc2 == 1,
              f"clean ack pass inject_calls={lc1}; ledger removed={removed}; "
              f"post-loss pass inject_calls={lc2} => at-least-once on state loss (separate from the ambiguous window)")
    return mid


def verification_turn(h, ob, markers: list[str]):
    log("\n=== Model-visibility verification turn (documented lifecycle point) ===")
    # DOCUMENTED LIFECYCLE POINT: thread/inject_items appends each item to the
    # thread's model-visible history immediately (empty-object ack); the model
    # actually CONSUMES it on the NEXT turn/start. It is NOT rendered in the stock
    # TUI transcript (model-history-only). We prove the "consumed on next turn"
    # half with ONE harness turn asking the model to echo the injected markers.
    #
    # NOTE (protocol): item/agentMessage notifications on codex 0.144.1 route to
    # the FRONTEND (primary) client, not our secondary observer connection — so we
    # read the model's echoed answer from the FRONTEND PANE (where an observer-
    # initiated turn's output renders), not from observer notifications.
    h.clear_composer()
    want = [m for m in markers if m]
    prompt = ("Some data items were appended to your conversation history by a "
              "delivery system. Reply with EXACTLY each distinct token you can "
              "see that looks like a short word, a dash, then hex — e.g. "
              "r2-ab12cd, r3-…, r4-…, burst1-…, ambig-… — one per line, nothing else.")
    tid = ob.start_turn(h.thread_id, prompt, timeout=30)
    found: list[str] = []

    def check():
        cap = h.capture_scrollback(400)
        found.clear()
        found.extend(m for m in want if m in cap)
        return len(found) >= 1
    got = h._wait(check, 150, "injected markers echoed in the frontend pane")
    h._wait(lambda: ob.thread_status(h.thread_id) == "idle", 20, "verify turn idle", quiet=True)
    cap = h.capture_scrollback(400)
    (h.run_dir / "verification-pane.txt").write_text(cap)
    if tid and ob.thread_status(h.thread_id) == "active":
        ob.interrupt(h.thread_id, tid)
    h._record("verify/injected-items-model-visible", got,
              f"{len(found)}/{len(want)} injected markers echoed by the model in the "
              f"frontend pane (model-visible on the next turn/start). markers seen: {found}")


def scenario_row6_hook_control(h, ob):
    log("\n=== Row 6: ORDINARY non-remote Codex (hook-fallback CONTROL case) ===")
    # CONTROL CASE (not the app-server path): an ordinary `codex` TUI has NO
    # app-server injection seam. c2c's ordinary-codex delivery is the hook path,
    # which drains ONLY at a natural hook boundary (UserPromptSubmit). We prove
    # the T004-relevant property for that path: a c2c message ARRIVING while a
    # draft is typed does NOT mutate the draft and does NOT start a turn — the
    # message stays inbox-pending until the operator submits (the hook boundary).
    # We do NOT redesign or fully wire the hook path (per scope); the isolated
    # CODEX_HOME keeps the user's real ~/.codex config untouched.
    import tempfile
    sess = f"t004r6-{os.getpid()}"
    ch = tempfile.mkdtemp(prefix="t004-codexhome-", dir=str(h.run_dir))
    try:
        try:  # carry login over read-only so the TUI reaches its composer
            import shutil as _sh
            _sh.copy(os.path.expanduser("~/.codex/auth.json"), os.path.join(ch, "auth.json"))
        except Exception:
            pass
        tmux("kill-session", "-t", sess, check=False)
        tmux("new-session", "-d", "-s", sess, "-x", "110", "-y", "35", "bash")
        tmux("send-keys", "-t", sess,
             f'cd {REPO_ROOT}; CODEX_HOME={ch} {CODEX} -c model="{MODEL}" '
             f'--dangerously-bypass-approvals-and-sandbox', "Enter", check=False)
        # dismiss the trust prompt (Enter = "Yes, continue") if it appears
        if h._wait(lambda: "Do you trust" in h.capture_frame(sess), 20, "row6 trust prompt", quiet=True):
            tmux("send-keys", "-t", sess, "Enter", check=False)
        if not h._wait(lambda: h.composer_block(h.capture_frame(sess))[0] is not None
                       and "Do you trust" not in h.capture_frame(sess), 25, "row6 composer"):
            h._record("row6/setup", False, "ordinary codex TUI never reached a composer")
            return None
        h._wait(lambda: h.capture_frame(sess) == h.capture_frame(sess), 3, "row6 settle", quiet=True)
        # type the multibyte/multiline draft via bracketed paste
        buf = f"t004r6draft-{os.getpid()}"
        bufp = h.run_dir / "r6draft.txt"; bufp.write_text(DRAFT_TEXT)
        tmux("load-buffer", "-b", buf, str(bufp), check=False)
        tmux("paste-buffer", "-p", "-b", buf, "-t", sess, check=False)
        if not h._wait(lambda: "DRAFT_MARKER_QZX" in "".join(h.composer_block(h.capture_frame(sess))[1]),
                       8, "row6 draft rendered"):
            h._record("row6/setup", False, "draft never rendered in ordinary-codex composer")
            return None
        before = h.snapshot("r6-before", session=sess)
        # simulate c2c ARRIVAL: write a message into an ISOLATED broker inbox. An
        # ordinary codex session has no arrival-time delivery seam, so nothing
        # should touch the composer (contrast with the app-server passive path).
        r6_broker = str(h.run_dir / "r6-broker"); Path(r6_broker).mkdir(exist_ok=True)
        r6_sess = "r6hooksess"
        mid = "r6-" + secrets.token_hex(3)
        marker = f"R6HOOK_{secrets.token_hex(3).upper()}"
        inbox = Path(r6_broker) / f"{r6_sess}.inbox.json"
        inbox.write_text(json.dumps([h.mk_msg("peer-r6", r6_sess, f"row6 {marker} hook-control {mid}", 1000.0, mid)]))
        # bounded observation window: wait for the composer draft to change (it
        # must NOT) — the wait TIMES OUT when arrival correctly does nothing.
        mutated = h._wait(lambda: "DRAFT_MARKER_QZX" not in "".join(h.composer_block(h.capture_frame(sess))[1])
                          or h.composer_block(h.capture_frame(sess))[1] != before["composer"],
                          5, "row6 draft mutation on arrival (expected NONE)", quiet=True)
        after = h.snapshot("r6-after", session=sess)
        # message must still be pending (boundary-gated; not delivered at arrival)
        pending_at_arrival = False
        try:
            pending_at_arrival = any(m.get("message_id") == mid for m in json.loads(inbox.read_text()))
        except Exception:
            pass
        draft_ok = (before["composer"] == after["composer"]
                    and before["rel_cursor"] == after["rel_cursor"] and not mutated)
        h._record("row6/draft-unchanged-no-arrival-turn",
                  draft_ok,
                  f"ordinary-codex draft byte-exact + cursor stable across c2c arrival={draft_ok} "
                  f"(composer={before['composer']!r} rel-cursor={before['rel_cursor']}; "
                  f"abs {before['cursor']}→{after['cursor']}); no arrival-time composer mutation")
        # NOW fire the actual hook at a natural UserPromptSubmit boundary: run the
        # REAL `c2c hook codex` against this isolated broker/session. It must (a)
        # emit the pending message as hookSpecificOutput.additionalContext, and
        # (b) drain it from the inbox — proving delivery happens ONLY at the hook
        # boundary, never at arrival.
        c2c_bin = (str(REPO_ROOT / "_build/default/ocaml/cli/c2c.exe")
                   if (REPO_ROOT / "_build/default/ocaml/cli/c2c.exe").exists()
                   else (shutil.which("c2c") or "c2c"))
        payload = json.dumps({"hook_event_name": "UserPromptSubmit",
                              "session_id": r6_sess, "cwd": str(REPO_ROOT)})
        henv = dict(os.environ); henv["C2C_MCP_BROKER_ROOT"] = r6_broker
        hres = subprocess.run([c2c_bin, "hook", "codex"], input=payload,
                              env=henv, capture_output=True, text=True)
        (h.run_dir / "r6-hook-output.json").write_text(hres.stdout)
        delivered_at_boundary = marker in hres.stdout and "additionalContext" in hres.stdout
        drained_after = False
        try:
            drained_after = not any(m.get("message_id") == mid for m in json.loads(inbox.read_text()))
        except Exception:
            drained_after = True  # inbox emptied/removed
        h._record("row6/message-delivered-only-at-hook-boundary",
                  pending_at_arrival and delivered_at_boundary and drained_after,
                  f"pending at arrival (not delivered)={pending_at_arrival}; "
                  f"`c2c hook codex` UserPromptSubmit emitted the message as additionalContext="
                  f"{delivered_at_boundary}; inbox drained after the boundary={drained_after} "
                  f"(marker {marker})")
        return mid
    finally:
        tmux("kill-session", "-t", sess, check=False)
        import shutil as _sh
        _sh.rmtree(ch, ignore_errors=True)


# ------------------------------- T007-precursor -----------------------------
# Exploration ADDED at coordinator request (authorized by Max). This is NOT the
# c2c passive-delivery path: it drives the app-server control seam's `turn/start`
# directly to de-risk T007 (auto-turn on inbound mail). All observations are
# recorded via h._finding (informational) so a turn/start anomaly can never fail
# the passive-injection matrix, which stands on its own.

def scenario_t007_turnstart_with_draft(h, ob):
    log("\n=== T007-precursor A: app-server turn/start with a NON-EMPTY draft ===")
    h.set_draft(DRAFT_TEXT, "DRAFT_MARKER_QZX")
    h.settle()
    before = h.snapshot("t7a-before")
    h._finding("t007/A-draft-before",
               f"draft composer={before['composer']!r} rel-cursor={before['rel_cursor']}")
    prompt = ("Write a short haiku about concurrency, then count from 1 to 20 "
              "slowly with a sentence after each number.")
    turn_id = ob.start_turn(h.thread_id, prompt, timeout=30)
    if not turn_id:
        h._finding("t007/A-turnstart", "turn/start returned no turn id (could not start)")
        return
    # DURING streaming: wait until the thread is active + the frontend transcript
    # CONTENT changes (the pane is fixed-size, so compare content, not length),
    # then snapshot the composer.
    active = h._wait(lambda: ob.thread_status(h.thread_id) == "active", 20, "t7a active", quiet=True)
    # fixed-size pane => detect rendering by CONTENT change, not byte length.
    before_sb = before["frame"]
    rendered = h._wait(lambda: h.capture_frame() != before_sb, 30,
                       "t7a frontend renders turn output (frame content changes)", quiet=True)
    during = h.snapshot("t7a-during")
    draft_ok_during = (during["composer"] == before["composer"]
                       and during["rel_cursor"] == before["rel_cursor"])
    h._finding("t007/A-during-streaming",
               f"thread active={active}; frontend transcript grew (streaming rendered)={rendered}; "
               f"draft byte-exact preserved DURING={draft_ok_during} "
               f"(composer={during['composer']!r} rel-cursor={during['rel_cursor']}; abs {before['cursor']}→{during['cursor']})")
    # AFTER: interrupt to reclaim quota (equivalently wait for idle), then snapshot.
    ob.interrupt(h.thread_id, turn_id)
    h._wait(lambda: ob.thread_status(h.thread_id) == "idle", 15, "t7a idle", quiet=True)
    h.settle(timeout=10, consecutive=2)
    after = h.snapshot("t7a-after")
    draft_ok_after = (after["composer"] == before["composer"]
                      and after["rel_cursor"] == before["rel_cursor"])
    # editability probe: type a char, confirm it lands in the composer, delete it.
    tmux("send-keys", "-t", h.session, "-l", "X", check=False)
    edit_ok = h._wait(lambda: h.composer_block(h.capture_frame())[1]
                      and h.composer_block(h.capture_frame())[1][-1].endswith("X"), 4,
                      "t7a composer still editable", quiet=True)
    tmux("send-keys", "-t", h.session, "BSpace", check=False)
    h._finding("t007/A-after-complete",
               f"draft byte-exact preserved AFTER turn={draft_ok_after} "
               f"(composer={after['composer']!r} rel-cursor={after['rel_cursor']}); "
               f"composer still editable after turn={edit_ok}")
    h._finding("t007/A-VERDICT",
               f"app-server turn/start with a live draft: streaming-rendered-in-frontend={rendered}, "
               f"draft-preserved before/during/after={before['composer']==during['composer']==after['composer']}, "
               f"cursor-stable={before['rel_cursor']==during['rel_cursor']==after['rel_cursor']}, editable-after={edit_ok}")


def scenario_t007_serialization(h, ob):
    log("\n=== T007-precursor B: turn/start while a turn is ALREADY running ===")
    h.set_draft(DRAFT_TEXT, "DRAFT_MARKER_QZX")
    h.settle(timeout=10, consecutive=2)
    before = h.snapshot("t7b-before")
    turn1 = ob.start_turn(h.thread_id, ACTIVE_PROMPT, timeout=30)
    if not turn1:
        h._finding("t007/B-setup", "could not start the first turn")
        return
    if not h._wait(lambda: ob.thread_status(h.thread_id) == "active", 20, "t7b active", quiet=True):
        h._finding("t007/B-setup", "first turn never went active")
        ob.interrupt(h.thread_id, turn1)
        return
    # fire a SECOND turn/start while the first is active — capture the raw reply.
    resp2 = ob.turn_start_raw(h.thread_id, "second concurrent turn", timeout=20)
    err = resp2.get("error")
    turn2 = ((resp2.get("result") or {}).get("turn") or {}).get("id")
    if err:
        behavior = f"REJECTED with error {json.dumps(err)[:200]}"
    elif turn2 and turn2 != turn1:
        behavior = f"ACCEPTED as a distinct turn id {turn2} (queued/interleaved)"
    elif turn2 == turn1:
        behavior = f"ACCEPTED, coalesced into the same turn id {turn1}"
    else:
        behavior = f"UNCLEAR: {json.dumps(resp2)[:200]}"
    after = h.snapshot("t7b-after")
    draft_ok = (after["composer"] == before["composer"] and after["rel_cursor"] == before["rel_cursor"])
    h._finding("t007/B-serialization",
               f"second turn/start while active -> {behavior}")
    h._finding("t007/B-draft-survives",
               f"draft byte-exact preserved across the concurrent turn/start={draft_ok} "
               f"(composer={after['composer']!r} rel-cursor={after['rel_cursor']})")
    # cleanup: interrupt both possible turns
    for t in {turn1, turn2}:
        if t:
            ob.interrupt(h.thread_id, t)
    h._wait(lambda: ob.thread_status(h.thread_id) == "idle", 15, "t7b idle", quiet=True)


# ------------------------------------------------------------------- preflight


def preflight() -> int:
    fails = 0

    def ok(m): log(f"  ok   {m}")

    def bad(m):
        nonlocal fails
        log(f"  FAIL {m}"); fails += 1

    log("T004 draft-preservation e2e — PREFLIGHT")
    if shutil.which("tmux"):
        ok(f"tmux present ({subprocess.run(['tmux','-V'],capture_output=True,text=True).stdout.strip()})")
    else:
        bad("tmux missing")
    cx = shutil.which(CODEX) or (CODEX if Path(CODEX).exists() else None)
    if cx:
        v = subprocess.run([CODEX, "--version"], capture_output=True, text=True).stdout.strip()
        ok(f"codex present: {cx} ({v})")
        h = subprocess.run([CODEX, "--help"], capture_output=True, text=True).stdout
        if "--remote" in h:
            ok("codex --help advertises --remote (remote TUI)")
        else:
            bad("codex --help lacks --remote")
    else:
        bad(f"codex not found ({CODEX})")
    if Path(DRIVER).exists():
        ok(f"T003 adapter driver: {DRIVER}")
    else:
        bad(f"adapter driver missing: {DRIVER} (build ./ocaml/test/dev_codex_ingress_dogfood.exe)")
    if try_websockets():
        ok("python websockets available")
    else:
        bad("python websockets missing (pip install websockets)")
    if (SCRIPT_DIR / "c2c_tmux.py").exists():
        ok("scripts/c2c_tmux.py present (tmux primitive reused)")
    else:
        bad("scripts/c2c_tmux.py missing")
    if os.environ.get("TMUX"):
        ok("inside tmux ('run' mode available)")
    else:
        log("  WARN not inside tmux — 'run' mode must be invoked from a tmux session")
    log("")
    if fails == 0:
        log("PREFLIGHT PASS")
        return 0
    log(f"PREFLIGHT FAIL — {fails} missing")
    return 1


def run_live(rows: str) -> int:
    if not os.environ.get("TMUX"):
        log("FATAL: 'run' must be invoked from inside tmux (per CLAUDE.md).")
        return 2
    if preflight() != 0:
        log("FATAL: preflight failed; fix prerequisites first.")
        return 2
    run_dir = Path(os.environ.get("C2C_T004_RUNDIR",
                   f"/tmp/claude-1000/-home-xertrov-src-c2c/t004-run-{int(time.time())}"))
    h = DraftPreservationHarness(run_dir)
    log(f"[setup] run dir: {run_dir}")
    log(f"[setup] codex={CODEX} model={MODEL}")
    log(f"[setup] before: app-server/remote procs = {h._proc_count()}")
    markers: list[str] = []
    try:
        h.start_appserver()
        h.start_proxy()
        h.start_tui()
        h.observer_connect()
        want = (set(rows.split(",")) if rows != "all"
                else {"1", "2", "3", "4", "5", "6", "burst", "ambig", "verify", "t007"})
        ob = h.observer
        if "1" in want:
            markers.append(scenario_idle_empty(h, ob))
        if "2" in want:
            markers.append(scenario_idle_draft(h, ob))
        if "3" in want:
            markers.append(scenario_active_empty(h, ob))
        if "4" in want:
            markers.append(scenario_active_draft(h, ob))
        if "5" in want:
            markers.append(scenario_disconnect_reconnect(h, ob))
        if "6" in want:
            scenario_row6_hook_control(h, ob)
        if "burst" in want:
            bt = scenario_burst_and_retry(h, ob)
            markers.extend(bt)
        if "ambig" in want:
            markers.append(scenario_ambiguous_at_least_once(h, ob))
        if "verify" in want:
            verification_turn(h, ob, markers)
        if "t007" in want:
            scenario_t007_turnstart_with_draft(h, ob)
            scenario_t007_serialization(h, ob)
    except Exception as e:
        import traceback
        log("FATAL exception during run:\n" + traceback.format_exc())
        h._record("harness/exception", False, str(e))
    finally:
        remaining = h.teardown()
        h._record("cleanup/no-leftover-procs", remaining == 0,
                  f"app-server/remote procs remaining after teardown = {remaining}")

    log("\n================ SUMMARY (passive-injection matrix — the AC gate) ================")
    npass = sum(1 for _, ok, _ in h.results if ok)
    for name, ok, detail in h.results:
        log(f"  {'PASS' if ok else 'FAIL':4}  {name}")
    log(f"---- {npass}/{len(h.results)} passive-matrix checks passed ----")
    findings = getattr(h, "findings", [])
    if findings:
        log("\n---- T007-precursor turn/start findings (informational; NOT gated) ----")
        for name, detail in findings:
            log(f"  NOTE  {name} — {detail}")
    log(f"\nsnapshots + logs under: {run_dir}")
    (run_dir / "results.json").write_text(json.dumps(
        {"matrix": [{"name": n, "ok": o, "detail": d} for n, o, d in h.results],
         "t007_findings": [{"name": n, "detail": d} for n, d in findings]}, indent=2))
    return 0 if npass == len(h.results) else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("mode", nargs="?", default="preflight", choices=["preflight", "run"])
    ap.add_argument("--rows", default="all",
                    help="comma list: 1,2,3,4,5,burst,ambig,verify,t007 or 'all'")
    args = ap.parse_args()
    if args.mode == "preflight":
        return preflight()
    return run_live(args.rows)


if __name__ == "__main__":
    sys.exit(main())
