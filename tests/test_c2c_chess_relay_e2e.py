"""Controller-driven chess over the c2c relay (default: public relay.c2c.im).

Every move is a REAL relay round-trip: `c2c relay dm send` (with proof-of-work)
-> relay -> `c2c relay dm poll`. The controller plays both sides with a
deterministic first-legal-move policy, keeping two private boards via
scripts/c2c_chess.py, so each ply genuinely traverses the relay and the two
boards MUST stay in sync (the FEN-equality assertion per ply is what proves the
relay carried the move intact). This isolates RELAY TRANSPORT validation from
the flaky live-agent autonomy that stalls the local agent-vs-agent game.

Gated on `C2C_TEST_RELAY_CHESS_E2E=1` (hits the prod relay, does POW, registers
transient `chess-relay-*` aliases the relay GCs). Skips if python-chess / c2c
are absent or the relay is unreachable.

Knobs:
- `C2C_RELAY_URL`        relay to use (default https://relay.c2c.im). Point at a
                         local `c2c relay` (POW off) to avoid prod traffic.
- `C2C_RELAY_CHESS_MAX_PLIES`  hard ply cap (default 40); the game also stops on
                         checkmate/draw.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest


C2C_BIN = shutil.which("c2c")
_HAVE_CHESS = importlib.util.find_spec("chess") is not None
RELAY_URL = os.environ.get("C2C_RELAY_URL", "https://relay.c2c.im")
MAX_PLIES = int(os.environ.get("C2C_RELAY_CHESS_MAX_PLIES", "40"))
CHESS_CLI = Path(__file__).resolve().parents[1] / "scripts" / "c2c_chess.py"


def _relay_reachable(url: str) -> bool:
    # Probe via the c2c HTTP client (the same transport the test uses), not
    # urllib — the prod relay's edge 403s urllib's default User-Agent. `rooms
    # list` is an unauthenticated route, so it needs no identity/POW.
    if not C2C_BIN:
        return False
    try:
        res = subprocess.run(
            ["c2c", "relay", "rooms", "list", "--relay-url", url],
            capture_output=True, text=True, timeout=15, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    try:
        return json.loads(res.stdout.strip() or "{}").get("ok") is True
    except json.JSONDecodeError:
        return False


pytestmark = pytest.mark.skipif(
    os.environ.get("C2C_TEST_RELAY_CHESS_E2E") != "1"
    or not _HAVE_CHESS
    or not C2C_BIN
    or not _relay_reachable(RELAY_URL),
    reason=(
        "set C2C_TEST_RELAY_CHESS_E2E=1, install python-chess + c2c, and ensure "
        f"the relay at {RELAY_URL} is reachable"
    ),
)


def _chess(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(CHESS_CLI), *args],
        capture_output=True, text=True, check=False,
    )


def _relay(*args: str) -> dict:
    """Run `c2c relay <args> --relay-url URL` and return the parsed object.

    `c2c relay` subcommands emit JSON by default — they do NOT accept a `--json`
    flag (passing one errors), so we never add it.
    """
    res = subprocess.run(
        ["c2c", "relay", *args, "--relay-url", RELAY_URL],
        capture_output=True, text=True, check=False,
    )
    try:
        return json.loads(res.stdout.strip() or "{}")
    except json.JSONDecodeError:
        return {"ok": False, "_raw": res.stdout, "_err": res.stderr}


def _fen(state_file: Path) -> str:
    out = _chess("board", str(state_file)).stdout
    for line in out.splitlines():
        if line.startswith("FEN:"):
            return line.split("FEN:", 1)[1].strip()
    return ""


def _legal_moves(state_file: Path) -> list[str]:
    res = _chess("moves", str(state_file))
    return res.stdout.split()


def _status(state_file: Path) -> dict:
    res = _chess("status", str(state_file))
    try:
        return json.loads(res.stdout.strip() or "{}")
    except json.JSONDecodeError:
        return {}


def _relay_recv_move(alias: str, timeout: float = 30.0) -> str | None:
    """Poll the relay for `alias` until a `MOVE <uci>` message arrives.

    Returns the uci PARSED FROM THE RECEIVED RELAY PAYLOAD (not the locally-sent
    value), so the caller can apply *that* move — making the downstream
    FEN-equality check a genuine transport test (a corrupted body desyncs the
    boards). The controller plays strictly serially and drains both inboxes
    before play, so the only in-flight message is the move just sent.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        res = _relay("dm", "poll", "--alias", alias)
        for m in res.get("messages", []) or []:
            body = (m.get("content") or m.get("body") or "").strip()
            if body.startswith("MOVE "):
                return body.split(None, 1)[1].strip()
        time.sleep(1.0)
    return None


def test_chess_over_relay_round_trips_every_move(tmp_path: Path) -> None:
    """Play a legal game where every move traverses the relay; boards stay synced.

    AC:
    - both players register on the relay
    - each ply: mover sends `MOVE <uci>` via the relay, opponent receives it via
      the relay, and after both apply it the two private boards have identical
      FEN (proves the relay carried the move intact)
    - the game reaches a terminal result or the ply cap, with >0 plies played
    """
    suffix = f"{os.getpid()}-{int(MAX_PLIES)}"
    white = f"chess-relay-white-{suffix}"
    black = f"chess-relay-black-{suffix}"
    boards = {white: tmp_path / "white.chess.json", black: tmp_path / "black.chess.json"}
    for f in boards.values():
        assert _chess("new", str(f)).returncode == 0

    assert _relay("register", "--alias", white).get("ok") is True, "white relay register failed"
    assert _relay("register", "--alias", black).get("ok") is True, "black relay register failed"
    # Drain any stale inbox state so polls only see this game's moves.
    _relay("dm", "poll", "--alias", white)
    _relay("dm", "poll", "--alias", black)

    transcript: list[str] = []
    mover, other = white, black
    plies = 0
    for _ in range(MAX_PLIES):
        if _status(boards[mover]).get("is_game_over"):
            break
        legal = _legal_moves(boards[mover])
        if not legal:
            break
        uci = legal[0]  # deterministic first-legal-move policy
        assert _chess("move", str(boards[mover]), uci).returncode == 0, f"{mover} could not play {uci}"

        sent = _relay("dm", "send", other, f"MOVE {uci}", "--alias", mover)
        assert sent.get("ok") is True, f"relay send {mover}->{other} failed: {sent}"

        # Apply the move PARSED FROM THE RELAY PAYLOAD, not the local uci — so the
        # FEN check below genuinely tests transport integrity.
        recv_uci = _relay_recv_move(other)
        assert recv_uci is not None, (
            f"{other} did not receive a move over the relay within timeout"
        )
        assert recv_uci == uci, f"relay corrupted the move: sent {uci!r}, received {recv_uci!r}"
        assert _chess("move", str(boards[other]), recv_uci).returncode == 0, (
            f"{other} could not apply relayed move {recv_uci}"
        )

        # Independently load-bearing now: both boards agree iff the relay carried
        # the exact move (mover applied `uci`, other applied the received move).
        assert _fen(boards[mover]) == _fen(boards[other]), (
            f"board desync after relaying {uci}: "
            f"{mover}={_fen(boards[mover])} {other}={_fen(boards[other])}"
        )
        transcript.append(f"{mover} -> {other}  MOVE {uci}")
        plies += 1
        mover, other = other, mover

    # Record what crossed the relay.
    out_dir = Path(os.environ.get("TMPDIR", "/tmp")) / f"c2c-chess-relay-{os.getpid()}"
    out_dir.mkdir(parents=True, exist_ok=True)
    final = _status(boards[white])
    header = (
        f"c2c chess over relay {RELAY_URL}\n"
        f"plies={plies} result={final.get('result')} "
        f"game_over={final.get('is_game_over')}\n" + "-" * 50 + "\n"
    )
    (out_dir / "relay-transcript.txt").write_text(header + "\n".join(transcript) + "\n")

    assert plies > 0, "no moves were played over the relay"
    assert plies == MAX_PLIES or final.get("is_game_over"), (
        f"game neither reached a result nor the ply cap (plies={plies})"
    )
    assert _fen(boards[white]) == _fen(boards[black]), "final boards desynced"
