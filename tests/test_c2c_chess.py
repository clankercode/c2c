"""Deterministic unit tests for scripts/c2c_chess.py.

No agents, no network. Drives the CLI as a subprocess against a tmp_path
state file (and exercises a few error paths). python-chess is required.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

pytest.importorskip("chess")

REPO_ROOT = Path(__file__).resolve().parents[1]
CHESS_CLI = REPO_ROOT / "scripts" / "c2c_chess.py"


def run(*args: str) -> subprocess.CompletedProcess:
    """Invoke the chess CLI as a subprocess and return the completed process."""
    return subprocess.run(
        [sys.executable, str(CHESS_CLI), *args],
        capture_output=True,
        text=True,
    )


def new_game(path: Path) -> None:
    res = run("new", str(path))
    assert res.returncode == 0, res.stderr


def status(path: Path) -> dict:
    res = run("status", str(path))
    assert res.returncode == 0, res.stderr
    return json.loads(res.stdout)


def test_new_starting_position(tmp_path: Path) -> None:
    f = tmp_path / "g.json"
    res = run("new", str(f))
    assert res.returncode == 0
    assert "FEN:" in res.stdout
    assert f.exists()

    data = json.loads(f.read_text())
    assert data == {"moves": [], "ended_by_agreement": False}

    st = status(f)
    assert st["turn"] == "white"
    assert st["ply"] == 0
    assert st["is_game_over"] is False
    assert st["result"] == "none"
    assert st["winner"] is None


def test_board_reflects_start(tmp_path: Path) -> None:
    f = tmp_path / "g.json"
    new_game(f)
    res = run("board", str(f))
    assert res.returncode == 0
    assert "turn: white" in res.stdout
    assert "ply: 0" in res.stdout
    assert "FEN:" in res.stdout


def test_legal_uci_move_accepted(tmp_path: Path) -> None:
    f = tmp_path / "g.json"
    new_game(f)
    res = run("move", str(f), "e2e4")
    assert res.returncode == 0
    assert "turn: black" in res.stdout

    data = json.loads(f.read_text())
    assert data["moves"] == ["e2e4"]

    st = status(f)
    assert st["turn"] == "black"
    assert st["ply"] == 1


def test_legal_san_move_accepted(tmp_path: Path) -> None:
    f = tmp_path / "g.json"
    new_game(f)
    res = run("move", str(f), "Nf3")
    assert res.returncode == 0, res.stderr

    data = json.loads(f.read_text())
    assert data["moves"] == ["g1f3"]  # SAN Nf3 normalizes to UCI g1f3

    st = status(f)
    assert st["turn"] == "black"
    assert st["ply"] == 1


def test_illegal_move_rejected_unchanged(tmp_path: Path) -> None:
    f = tmp_path / "g.json"
    new_game(f)
    before = f.read_text()
    res = run("move", str(f), "e2e5")
    assert res.returncode == 2
    assert res.stderr.strip()  # a reason was printed
    assert f.read_text() == before  # file unchanged


def test_legal_subcommand_exit_codes(tmp_path: Path) -> None:
    f = tmp_path / "g.json"
    new_game(f)
    before = f.read_text()

    assert run("legal", str(f), "e2e4").returncode == 0
    assert run("legal", str(f), "e2e5").returncode == 1

    assert f.read_text() == before  # legal never mutates


def test_moves_lists_twenty(tmp_path: Path) -> None:
    f = tmp_path / "g.json"
    new_game(f)
    res = run("moves", str(f))
    assert res.returncode == 0
    listed = [ln for ln in res.stdout.splitlines() if ln.strip()]
    assert len(listed) == 20


def test_fools_mate_checkmate(tmp_path: Path) -> None:
    f = tmp_path / "g.json"
    new_game(f)
    for mv in ["f2f3", "e7e5", "g2g4", "d8h4"]:
        res = run("move", str(f), mv)
        assert res.returncode == 0, res.stderr

    st = status(f)
    assert st["is_game_over"] is True
    assert st["result"] == "checkmate"
    assert st["winner"] == "black"

    # moving after game over -> exit 3
    res = run("move", str(f), "e2e4")
    assert res.returncode == 3


def test_declare_stalemate_midgame(tmp_path: Path) -> None:
    f = tmp_path / "g.json"
    new_game(f)
    run("move", str(f), "e2e4")

    res = run("declare-stalemate", str(f))
    assert res.returncode == 0

    st = status(f)
    assert st["result"] == "ended_by_agreement"
    assert st["is_game_over"] is True
    assert st["ended_by_agreement"] is True

    # moving after agreement -> exit 3
    res = run("move", str(f), "e7e5")
    assert res.returncode == 3


def test_persistence_round_trip(tmp_path: Path) -> None:
    f = tmp_path / "g.json"
    new_game(f)
    for mv in ["e2e4", "e7e5", "g1f3"]:
        assert run("move", str(f), mv).returncode == 0

    # A fresh invocation rebuilds the board from the file.
    st = status(f)
    assert st["ply"] == 3
    assert st["turn"] == "black"

    res = run("board", str(f))
    assert "ply: 3" in res.stdout


def test_status_json_has_exact_keys(tmp_path: Path) -> None:
    f = tmp_path / "g.json"
    new_game(f)
    st = status(f)
    assert set(st.keys()) == {
        "turn",
        "is_game_over",
        "result",
        "winner",
        "ended_by_agreement",
        "ply",
    }


def test_missing_file_error(tmp_path: Path) -> None:
    f = tmp_path / "nope.json"
    for cmd in (["status", str(f)], ["move", str(f), "e2e4"], ["board", str(f)]):
        res = run(*cmd)
        assert res.returncode == 4, cmd
        assert res.stderr.strip()


def test_corrupt_file_error(tmp_path: Path) -> None:
    f = tmp_path / "bad.json"
    f.write_text("{ this is not json")
    res = run("status", str(f))
    assert res.returncode == 4
    assert res.stderr.strip()
