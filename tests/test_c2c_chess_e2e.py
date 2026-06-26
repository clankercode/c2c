"""Live agent-vs-agent chess over c2c: pi (White) vs opencode (Black).

There is NO central referee. Each agent keeps its OWN private board via
``scripts/c2c_chess.py`` on its OWN temp file and never reads the opponent's.
Moves travel as c2c DMs (``MOVE <uci>``). When the two boards desync the agents
argue over c2c and, failing agreement, both ``declare-stalemate`` — so the game
always terminates, which is what lets this pass without depending on the models'
chess strength. The real dogfood is the bidirectional c2c conversation.

Gated on ``C2C_TEST_CHESS_E2E=1`` plus python-chess / pi / opencode / c2c /
tmux. Runs on a DEDICATED tmux socket so a server crash cannot take down the
operator's main sessions. Long + token-heavy — manual-run only. Knobs:
``C2C_CHESS_TIMEOUT_S`` (default 900) and ``C2C_E2E_*_MODEL`` (see
tests/e2e/framework/models.py).
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

from tests import conftest as conftest_module
from tests.e2e.framework.artifacts import ArtifactCollector
from tests.e2e.framework.client_adapters import OpenCodeAdapter, PiAdapter
from tests.e2e.framework.fake_pty_driver import FakePtyDriver
from tests.e2e.framework.models import e2e_model
from tests.e2e.framework.scenario import Scenario
from tests.e2e.framework.tmux_driver import TmuxDriver


TMUX_BIN = shutil.which("tmux")
PI_BIN = shutil.which("pi")
OPENCODE_BIN = shutil.which("opencode")
C2C_BIN = shutil.which("c2c")
_HAVE_CHESS = importlib.util.find_spec("chess") is not None

CHESS_SOCKET = "c2c-chess-e2e"
CHESS_CLI = Path(__file__).resolve().parents[1] / "scripts" / "c2c_chess.py"
TIMEOUT_S = float(os.environ.get("C2C_CHESS_TIMEOUT_S", "900"))

pytestmark = pytest.mark.skipif(
    os.environ.get("C2C_TEST_CHESS_E2E") != "1"
    or not _HAVE_CHESS
    or not TMUX_BIN
    or not PI_BIN
    or not OPENCODE_BIN
    or not C2C_BIN,
    reason=(
        "set C2C_TEST_CHESS_E2E=1 and ensure python-chess + tmux/pi/opencode/c2c "
        "are available"
    ),
)


def _init_git_repo(path: Path) -> None:
    subprocess.run(["git", "init", "-q"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.name", "c2c test"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.email", "c2c-test@example.invalid"], cwd=path, check=True)
    subprocess.run(["git", "commit", "--allow-empty", "-m", "init", "-q"], cwd=path, check=True)


def _create_opencode_json(workdir: Path, broker_root: Path) -> None:
    mcp_bin = shutil.which("c2c-mcp-server") or "/home/xertrov/.local/bin/c2c-mcp-server"
    c2c_bin = shutil.which("c2c") or "/home/xertrov/.local/bin/c2c"
    oc_dir = workdir / ".opencode"
    oc_dir.mkdir(parents=True, exist_ok=True)
    config = {
        "$schema": "https://opencode.ai/config.json",
        "mcp": {
            "c2c": {
                "type": "local",
                "command": ["opam", "exec", "--", mcp_bin],
                "environment": {
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                    "C2C_MCP_AUTO_JOIN_ROOMS": "swarm-lounge",
                    "C2C_MCP_AUTO_DRAIN_CHANNEL": "0",
                    "C2C_CLI_COMMAND": c2c_bin,
                },
                "enabled": True,
            }
        },
    }
    (oc_dir / "opencode.json").write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")


def _registered(alias: str, scenario: Scenario) -> bool:
    registry = scenario.broker_root() / "registry.json"
    if not registry.exists():
        return False
    try:
        data = json.loads(registry.read_text(encoding="utf-8") or "[]")
        rows = data if isinstance(data, list) else data.get("registrations", [])
        return any(r.get("alias") == alias and r.get("alive") is not False for r in rows)
    except Exception:
        return False


def _chess(*args: str) -> subprocess.CompletedProcess:
    # Use the SAME interpreter the gate probed for python-chess (sys.executable),
    # not a bare `python3` that may resolve to a different env without chess.
    return subprocess.run(
        [sys.executable, str(CHESS_CLI), *args],
        capture_output=True, text=True, check=False,
    )


def _register_referee(alias: str, session: str, broker_root: Path) -> None:
    env = dict(os.environ)
    env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
    env["C2C_MCP_SESSION_ID"] = session
    subprocess.run(
        ["c2c", "register", "--alias", alias, "--session-id", session, "--json"],
        env=env, check=True, capture_output=True, text=True,
    )


def _referee_dm(referee: str, session: str, to_alias: str, body: str, broker_root: Path) -> None:
    """Send a kickoff DM from the referee (which owns `session`, so --from is allowed)."""
    env = dict(os.environ)
    env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
    env["C2C_MCP_SESSION_ID"] = session
    res = subprocess.run(
        ["c2c", "send", "--from", referee, to_alias, body],
        env=env, check=False, capture_output=True, text=True,
    )
    if res.returncode != 0:
        raise AssertionError(f"referee DM to {to_alias} failed: {res.stderr.strip() or res.stdout.strip()}")


def _game_status(state_file: Path) -> dict:
    if not state_file.exists():
        return {"is_game_over": False, "ended_by_agreement": False, "ply": 0, "result": "none"}
    res = _chess("status", str(state_file))
    try:
        return json.loads(res.stdout.strip() or "{}")
    except json.JSONDecodeError:
        return {"is_game_over": False, "ended_by_agreement": False, "ply": 0, "result": "none"}


def _kickoff(*, color: str, my_file: Path, opponent: str, first_to_move: bool) -> str:
    turn_line = (
        "You move FIRST. Make your opening move now."
        if first_to_move
        else f"{opponent} (White) moves first — WAIT for their first `MOVE <uci>` DM, "
        "apply it to your board, then reply with your move."
    )
    return (
        f"You are playing a real game of CHESS as {color} against {opponent}, over c2c. "
        "Follow this protocol EXACTLY.\n\n"
        "YOUR PRIVATE BOARD — maintain it with this CLI (never read any other file):\n"
        f"  python3 {CHESS_CLI} <cmd> {my_file} [move]\n"
        "  cmds: moves <f> (list legal UCI moves) | move <f> <uci> (apply; errors if illegal) | "
        "board <f> | status <f> (JSON) | legal <f> <uci> | declare-stalemate <f>\n\n"
        "PROTOCOL (UCI notation only, e.g. e2e4):\n"
        "1. On your move: run `moves` to see legal options, pick one, run `move <f> <uci>`, "
        f"then send a c2c DM to {opponent} with EXACTLY: MOVE <uci>\n"
        f"2. When {opponent} DMs you `MOVE <uci>`: run `move <f> <their_uci>` to apply it. "
        "If the CLI says ILLEGAL, DM them `DISPUTE: <uci> - <reason>` and discuss; recheck with `legal`.\n"
        f"3. If you and {opponent} cannot agree after a few messages, BOTH run "
        "`declare-stalemate <f>` and DM `STALEMATE-AGREED`, then stop.\n"
        "4. After applying any move run `status <f>`; if is_game_over is true, DM "
        "`GAME OVER: <result>` and stop.\n"
        "5. Otherwise continue from step 1.\n\n"
        f"Send DMs to {opponent} using your c2c send tool/command. {turn_line}"
    )


def _build_scenario(request: pytest.FixtureRequest, workdir: Path) -> Scenario:
    artifacts = ArtifactCollector(Path(".artifacts") / "e2e", request.node.name)
    artifacts.start_run()
    return Scenario(
        test_name=request.node.name,
        workdir=workdir,
        artifacts=artifacts,
        drivers={
            "tmux": TmuxDriver(Path.cwd(), socket=CHESS_SOCKET),
            "fake-pty": FakePtyDriver(),
        },
        adapters={
            "pi": PiAdapter(Path.cwd()),
            "opencode": OpenCodeAdapter(Path.cwd()),
        },
    )


def test_chess_pi_vs_opencode_to_result(request: pytest.FixtureRequest, tmp_path: Path) -> None:
    """pi (White) vs opencode (Black) play to a terminal result over c2c.

    Passes when either private board reaches a terminal state (checkmate / draw /
    mutual stalemate) or a GAME OVER / STALEMATE-AGREED DM lands, within
    C2C_CHESS_TIMEOUT_S. Captures both boards + move logs as artifacts.
    """
    workdir = tmp_path / "workdir"
    workdir.mkdir(parents=True, exist_ok=True)
    _init_git_repo(workdir)

    sc = _build_scenario(request, workdir)
    try:
        _create_opencode_json(workdir, sc.broker_root())
        sc.refresh_capabilities()

        suffix = f"{os.getpid()}"
        white_alias = f"chess-white-{suffix}"   # pi
        black_alias = f"chess-black-{suffix}"   # opencode
        white_file = workdir / "white.chess.json"
        black_file = workdir / "black.chess.json"
        assert _chess("new", str(white_file)).returncode == 0
        assert _chess("new", str(black_file)).returncode == 0

        white = sc.start_agent("pi", name=white_alias, model=e2e_model("pi"))
        black = sc.start_agent("opencode", name=black_alias, model=e2e_model("opencode"))

        sc.wait_for_init(white, black, timeout=150.0)
        sc.wait_for(
            lambda: _registered(white_alias, sc) and _registered(black_alias, sc),
            timeout=90.0,
        )

        # Kick off Black first (so it is waiting), then White to trigger move 1.
        # The referee owns its session, so --from is allowed without coordinator.
        referee = f"chess-referee-{suffix}"
        ref_session = f"chess-ref-session-{suffix}"
        _register_referee(referee, ref_session, sc.broker_root())
        _referee_dm(referee, ref_session, black_alias, _kickoff(
            color="BLACK", my_file=black_file, opponent=white_alias, first_to_move=False),
            sc.broker_root())
        _referee_dm(referee, ref_session, white_alias, _kickoff(
            color="WHITE", my_file=white_file, opponent=black_alias, first_to_move=True),
            sc.broker_root())

        def _terminal() -> bool:
            # The private state files are the only reliable terminal signal:
            # scanning inboxes for "GAME OVER"/"STALEMATE-AGREED" would (a) match
            # the kickoff's own protocol text and (b) race pi's inbox drain.
            # Each agent's own board reflects checkmate/draw/agreement once it
            # applies the deciding move or declares stalemate.
            for f in (white_file, black_file):
                st = _game_status(f)
                if st.get("is_game_over") or st.get("ended_by_agreement"):
                    return True
            return False

        try:
            sc.wait_for(_terminal, timeout=TIMEOUT_S, interval=5.0)
        finally:
            # Always snapshot the game, pass or fail.
            for label, f in (("white", white_file), ("black", black_file)):
                board = _chess("board", str(f))
                sc.artifacts.write_text(f"{label}.board.txt", board.stdout + board.stderr)
                if f.exists():
                    sc.artifacts.write_text(f"{label}.state.json", f.read_text(encoding="utf-8"))
            sc.artifacts.write_text("white.pane.txt", sc.capture(white))
            sc.artifacts.write_text("black.pane.txt", sc.capture(black))

        wst, bst = _game_status(white_file), _game_status(black_file)
        assert wst.get("is_game_over") or bst.get("is_game_over") or _terminal(), (
            f"game did not reach a terminal state; white={wst} black={bst}"
        )
    finally:
        # Tearing down the isolated tmux server is the most important step (it
        # protects the operator's default socket), so it must run even if agent
        # or broker cleanup raises. _cleanup_scenario_agents can raise on a
        # flaky `c2c stop` — guard each step independently.
        try:
            conftest_module._cleanup_scenario_agents(sc)
        finally:
            try:
                conftest_module._cleanup_canonical_broker(sc)
            finally:
                # Never touches the default socket (-L targets only this server).
                subprocess.run(["tmux", "-L", CHESS_SOCKET, "kill-server"],
                               check=False, capture_output=True, text=True)
