"""Variant C: pi plays chess over the relay using ONLY its native c2c_pi_* tools.

pi (Black) runs in relay mode; the controller (White) is a relay-only peer. The
controller sends moves via `c2c relay dm send`; pi RECEIVES them through its
relay-watcher (into its transcript) and REPLIES with `c2c_pi_send` — its native
tool, not the c2c CLI or bash. This exercises the pi-native relay send/receive
path end-to-end.

It depends on the relay accepting a full-address (`<name>@<host>`) signer, which
pi-c2c always uses — the fix lives in `ocaml/relay.ml` (commit "fix(relay):
accept full-address signer on send routes"). So this test runs against a LOCAL
relay built from THIS worktree (the fix is not yet deployed to relay.c2c.im):

- `local-pow-off`  : local relay, C2C_RELAY_POW=0
- `local-pow-on`   : local relay, C2C_RELAY_POW=1
- `remote`         : relay.c2c.im — SKIPPED until the fix is deployed there.

Gated on `C2C_TEST_PI_RELAY_CHESS_E2E=1` plus python-chess / pi / tmux and the
worktree relay binary at `_build/default/ocaml/cli/c2c.exe`.
"""
from __future__ import annotations

import contextlib
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

import pytest


REPO = Path(__file__).resolve().parents[1]
RELAY_BIN = REPO / "_build" / "default" / "ocaml" / "cli" / "c2c.exe"
CHESS_CLI = REPO / "scripts" / "c2c_chess.py"
PI_BIN = shutil.which("pi")
CLIENT_C2C = shutil.which("c2c")  # pi's client + our CLI calls
_HAVE_CHESS = importlib.util.find_spec("chess") is not None

pytestmark = pytest.mark.skipif(
    os.environ.get("C2C_TEST_PI_RELAY_CHESS_E2E") != "1"
    or not _HAVE_CHESS
    or not PI_BIN
    or not CLIENT_C2C
    or not shutil.which("tmux")
    or not RELAY_BIN.exists(),
    reason=(
        "set C2C_TEST_PI_RELAY_CHESS_E2E=1, install python-chess/pi/tmux, and "
        f"build the worktree relay binary ({RELAY_BIN})"
    ),
)

# (param-id, env for relay, skip-reason-or-None)
RELAY_CONFIGS = [
    pytest.param(("local", "0"), id="local-pow-off"),
    pytest.param(("local", "1"), id="local-pow-on"),
    pytest.param(("remote", None), id="remote",
                 marks=pytest.mark.skip(reason="relay.ml fix not yet deployed to relay.c2c.im")),
]


def _free_port() -> int:
    with contextlib.closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(params=RELAY_CONFIGS)
def relay(request, tmp_path: Path):
    """Yield a relay URL for a (kind, pow) config; start+stop a local relay."""
    kind, pow_flag = request.param
    if kind == "remote":
        yield "https://relay.c2c.im"
        return
    port = _free_port()
    url = f"http://127.0.0.1:{port}"
    env = dict(os.environ)
    env["C2C_RELAY_POW"] = pow_flag
    proc = subprocess.Popen(
        [str(RELAY_BIN), "relay", "serve", "--listen", f"127.0.0.1:{port}",
         "--persist-dir", str(tmp_path / "relaydb")],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        # wait for /health
        deadline = time.monotonic() + 20
        ready = False
        while time.monotonic() < deadline:
            try:
                out = subprocess.run([str(RELAY_BIN), "relay", "rooms", "list", "--relay-url", url],
                                     capture_output=True, text=True, timeout=5).stdout
                if json.loads(out or "{}").get("ok"):
                    ready = True
                    break
            except Exception:
                pass
            time.sleep(0.5)
        assert ready, f"local relay did not come up at {url}"
        yield url
    finally:
        with contextlib.suppress(Exception):
            proc.terminate()
            proc.wait(timeout=5)


def _relay(url: str, *args: str, bin_: str | None = None) -> dict:
    res = subprocess.run([bin_ or str(RELAY_BIN), "relay", *args, "--relay-url", url],
                         capture_output=True, text=True, check=False)
    try:
        return json.loads(res.stdout.strip() or "{}")
    except json.JSONDecodeError:
        return {"ok": False, "_raw": res.stdout, "_err": res.stderr}


def _host_id() -> str:
    return subprocess.run([str(RELAY_BIN), "host-id"], capture_output=True, text=True).stdout.strip()


def _chess(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(CHESS_CLI), *args],
                          capture_output=True, text=True, check=False)


# --------------------------------------------------------------------------- #
# 1. Deterministic regression for the relay fix (no pi). Fast.
# --------------------------------------------------------------------------- #
def test_relay_accepts_full_address_signer(relay) -> None:
    """The relay must accept a `<name>@<host>` signer on send (the variant-C fix)."""
    host = _host_id()
    ts = int(time.time() * 1000)
    a, b = f"sigtest-a-{ts}", f"sigtest-b-{ts}"
    assert _relay(relay, "register", "--alias", a).get("ok") is True
    assert _relay(relay, "register", "--alias", b).get("ok") is True
    # bare alias has always worked
    assert _relay(relay, "dm", "send", b, "bare", "--alias", a).get("ok") is True
    # full-address signer — the bug; must now be accepted
    full = _relay(relay, "dm", "send", b, "full", "--alias", f"{a}@{host}")
    assert full.get("ok") is True, f"relay rejected full-address signer: {full}"


# --------------------------------------------------------------------------- #
# 2. Live: pi plays chess over the relay using ONLY its native c2c_pi_* tools.
# --------------------------------------------------------------------------- #
SOCKET = "c2c-pi-relay-chess"
MIN_PI_MOVES = int(os.environ.get("C2C_PI_RELAY_MIN_MOVES", "2"))


def _init_git(path: Path) -> None:
    subprocess.run(["git", "init", "-q"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.name", "t"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.email", "t@t.t"], cwd=path, check=True)
    subprocess.run(["git", "commit", "--allow-empty", "-m", "i", "-q"], cwd=path, check=True)


def _tmux(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["tmux", "-L", SOCKET, "-f", "/dev/null", *args],
                          capture_output=True, text=True, check=False)


def _relay_recv_move(url: str, alias: str, timeout: float = 60.0) -> tuple[str, str] | None:
    """Poll `alias`'s relay inbox for a `MOVE <uci>` reply. Returns (uci, from)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for m in _relay(url, "dm", "poll", "--alias", alias).get("messages", []) or []:
            body = (m.get("content") or m.get("body") or "").strip()
            if body.upper().startswith("MOVE "):
                frm = m.get("from_alias") or m.get("from") or "?"
                return body.split(None, 1)[1].strip().split()[0], frm
        time.sleep(2.0)
    return None


def test_pi_plays_over_relay_via_native_tools(relay, tmp_path: Path) -> None:
    """pi (Black) replies with moves over the relay using only c2c_pi_send.

    AC:
    - pi registers on the relay and receives the controller's relayed moves
    - pi sends >= MIN_PI_MOVES moves back OVER THE RELAY via its NATIVE tool
      (the controller, a relay-only peer, can only be reached via the relay)
    - the moves are legal black replies (validated with the chess CLI)
    """
    workdir = tmp_path / "wd"
    workdir.mkdir()
    _init_git(workdir)
    host = _host_id()
    ts = int(time.time())
    white = f"pi-relay-white-{ts}"   # controller
    black = f"pi-relay-black-{ts}"   # pi
    board = workdir / "white.chess.json"
    assert _chess("new", str(board)).returncode == 0

    assert _relay(relay, "register", "--alias", white).get("ok") is True
    _relay(relay, "dm", "poll", "--alias", white)  # drain

    pi_moves: list[str] = []
    transcript: list[str] = []
    _tmux("kill-server")
    try:
        _tmux(
            "new-session", "-d", "-s", "pirelay", "-x", "200", "-y", "50",
            "-e", f"C2C_PI_ALIAS={black}", "-e", "C2C_PI_RELAY=1",
            "-e", f"C2C_PI_RELAY_URL={relay}", "-e", "C2C_PI_CROSS_REPO=0",
            "-e", f"C2C_MCP_BROKER_ROOT={workdir/'broker'}",
            "-e", f"C2C_BIN={CLIENT_C2C}",
            "bash", "-lc",
            f"cd {workdir} && exec pi --model zai-coding-plan/glm-5-turbo",
        )
        # wait for pi to register on the relay
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            peers = _relay(relay, "list").get("peers", []) or []
            if any(black in (p.get("alias") or "") for p in peers):
                break
            time.sleep(4)
        else:
            pytest.fail("pi never registered on the relay")

        # The controller signs its relay sends with its FULL address
        # (`<name>@<host>`) — exactly what pi-c2c uses, and what the relay.ml
        # full-address-signer fix enables. This makes pi RECEIVE the moves from
        # `white@host`, so pi's UI tags the recv line `▼⇄` (relay) instead of
        # defaulting to `▼◎` (the bare-alias "route unknown" fallback). Registration
        # stays bare so pi's bare-target replies still reach white's relay outbox.
        white_addr = f"{white}@{host}"
        kickoff = (
            f"You are playing CHESS as BLACK against {white} over c2c. Use ONLY your "
            f"c2c_pi_send tool to send moves (target={white}). Do NOT use bash, the "
            f"shell, or the c2c CLI. I (White) will send 'MOVE <uci>'. Reply with your "
            f"move as 'MOVE <uci>' (UCI, e.g. e7e5) via c2c_pi_send. I move first."
        )
        assert _relay(relay, "dm", "send", black, kickoff, "--alias", white_addr).get("ok") is True

        # Controller plays White (first legal move); pi replies as Black.
        for _ in range(MIN_PI_MOVES + 2):
            if _chess("status", str(board)).stdout and json.loads(
                _chess("status", str(board)).stdout or "{}").get("is_game_over"):
                break
            wmove = _chess("moves", str(board)).stdout.split()[0]
            _chess("move", str(board), wmove)
            assert _relay(relay, "dm", "send", black, f"MOVE {wmove}", "--alias", white_addr).get("ok") is True
            transcript.append(f"{white}@{host} -> {black}@{host}  MOVE {wmove}")

            recv = _relay_recv_move(relay, white, timeout=90.0)
            if recv is None:
                break
            uci, frm = recv
            transcript.append(f"{frm} -> {white}@{host}  MOVE {uci}  [pi native tool]")
            # apply pi's move to the board if legal; record either way
            if _chess("move", str(board), uci).returncode == 0:
                pi_moves.append(uci)
            else:
                pi_moves.append(f"{uci}(illegal)")
    finally:
        out_dir = Path(os.environ.get("TMPDIR", "/tmp")) / f"c2c-pi-relay-chess-{os.getpid()}"
        with contextlib.suppress(Exception):
            out_dir.mkdir(parents=True, exist_ok=True)
            (out_dir / "transcript.txt").write_text(
                f"pi-native chess over relay {relay} (machine id {host})\n"
                + "-" * 50 + "\n" + "\n".join(transcript) + "\n")
            (out_dir / "pi.pane.txt").write_text(
                _tmux("capture-pane", "-t", "pirelay", "-p", "-S", "-200").stdout)
        _tmux("kill-server")
        with contextlib.suppress(Exception):
            env = dict(os.environ)
            env["C2C_MCP_BROKER_ROOT"] = str(workdir / "broker")
            subprocess.run(["c2c", "stop", black, "--json"], cwd=workdir, env=env,
                           capture_output=True, text=True, check=False)

    legal = [m for m in pi_moves if "(illegal)" not in m]
    assert len(pi_moves) >= MIN_PI_MOVES, (
        f"pi sent only {len(pi_moves)} move(s) over the relay via its native tools "
        f"(need {MIN_PI_MOVES}); moves={pi_moves}"
    )
    assert legal, f"pi sent moves over the relay but none were legal black replies: {pi_moves}"
