#!/usr/bin/env python3
"""c2c_chess — a self-contained chess CLI for agent-vs-agent games over c2c.

Each agent keeps its OWN private board in a JSON state file and never reads the
opponent's file. The board is rebuilt from the move list on every invocation
(moves are persisted as UCI; FEN is never persisted, which avoids drift).

State file format (JSON):
    {"moves": ["e2e4", ...], "ended_by_agreement": false}

Exit codes:
    0  success
    1  `legal` only: the move is not legal
    2  `move`: illegal / unparseable move (reason on stderr)
    3  `move`: the game is already over (reason on stderr)
    4  state file missing or corrupt (reason on stderr)

Example:
    python3 scripts/c2c_chess.py new /tmp/white.json
    python3 scripts/c2c_chess.py move /tmp/white.json e2e4
    python3 scripts/c2c_chess.py move /tmp/white.json Nf3      # SAN also accepted
    python3 scripts/c2c_chess.py status /tmp/white.json
    python3 scripts/c2c_chess.py declare-stalemate /tmp/white.json
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile

import chess


EXIT_OK = 0
EXIT_NOT_LEGAL = 1
EXIT_ILLEGAL_MOVE = 2
EXIT_GAME_OVER = 3
EXIT_STATE_ERROR = 4


def _die(code: int, message: str) -> "NoReturn":  # type: ignore[name-defined]
    print(message, file=sys.stderr)
    sys.exit(code)


def _load_state(path: str) -> dict:
    """Load and validate the state file. Exits 4 on missing / corrupt input."""
    if not os.path.exists(path):
        _die(EXIT_STATE_ERROR, f"error: state file not found: {path}")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (json.JSONDecodeError, ValueError) as exc:
        _die(EXIT_STATE_ERROR, f"error: corrupt state file {path}: {exc}")
    except OSError as exc:
        _die(EXIT_STATE_ERROR, f"error: cannot read state file {path}: {exc}")

    if not isinstance(data, dict):
        _die(EXIT_STATE_ERROR, f"error: corrupt state file {path}: not a JSON object")
    moves = data.get("moves", [])
    if not isinstance(moves, list) or not all(isinstance(m, str) for m in moves):
        _die(EXIT_STATE_ERROR, f"error: corrupt state file {path}: 'moves' must be a list of strings")
    ended = data.get("ended_by_agreement", False)
    if not isinstance(ended, bool):
        _die(EXIT_STATE_ERROR, f"error: corrupt state file {path}: 'ended_by_agreement' must be a bool")
    return {"moves": list(moves), "ended_by_agreement": ended}


def _build_board(state: dict, path: str) -> chess.Board:
    """Replay the move list into a fresh board. Exits 4 if a stored move is bad."""
    board = chess.Board()
    for idx, uci in enumerate(state["moves"]):
        try:
            move = chess.Move.from_uci(uci)
        except ValueError as exc:
            _die(EXIT_STATE_ERROR, f"error: corrupt state file {path}: move #{idx} {uci!r}: {exc}")
        if move not in board.legal_moves:
            _die(EXIT_STATE_ERROR, f"error: corrupt state file {path}: illegal stored move #{idx} {uci!r}")
        board.push(move)
    return board


def _atomic_write(path: str, state: dict) -> None:
    """Write state to path atomically (temp file in the same dir + os.replace)."""
    directory = os.path.dirname(os.path.abspath(path)) or "."
    os.makedirs(directory, exist_ok=True)
    payload = json.dumps(
        {"moves": list(state["moves"]), "ended_by_agreement": bool(state["ended_by_agreement"])},
        indent=2,
    )
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".c2c_chess.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(payload)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _turn_name(board: chess.Board) -> str:
    return "white" if board.turn == chess.WHITE else "black"


def _parse_move(board: chess.Board, text: str) -> chess.Move:
    """Try UCI first, then SAN. Raises ValueError if neither parses to a legal move."""
    # UCI attempt
    try:
        move = chess.Move.from_uci(text)
    except ValueError:
        move = None
    if move is not None:
        if move in board.legal_moves:
            return move
        raise ValueError(f"illegal move: {text} is not legal in this position")
    # SAN fallback
    try:
        return board.parse_san(text)
    except ValueError as exc:
        raise ValueError(f"unparseable or illegal move: {text} ({exc})")


# --- subcommands -----------------------------------------------------------


def cmd_new(args: argparse.Namespace) -> int:
    state = {"moves": [], "ended_by_agreement": False}
    _atomic_write(args.file, state)
    board = chess.Board()
    print(f"new game initialized: {args.file}")
    print(f"FEN: {board.fen()}")
    return EXIT_OK


def cmd_move(args: argparse.Namespace) -> int:
    state = _load_state(args.file)
    board = _build_board(state, args.file)

    if state["ended_by_agreement"]:
        _die(EXIT_GAME_OVER, "error: game already ended by agreement")
    if board.is_game_over():
        _die(EXIT_GAME_OVER, f"error: game is already over ({_result_kind(board, state)})")

    try:
        move = _parse_move(board, args.move)
    except ValueError as exc:
        _die(EXIT_ILLEGAL_MOVE, f"error: {exc}")

    uci = move.uci()
    board.push(move)
    state["moves"].append(uci)
    _atomic_write(args.file, state)
    print(f"played: {uci}")
    print(f"FEN: {board.fen()}")
    print(f"turn: {_turn_name(board)}")
    return EXIT_OK


def cmd_legal(args: argparse.Namespace) -> int:
    state = _load_state(args.file)
    board = _build_board(state, args.file)
    try:
        _parse_move(board, args.move)
    except ValueError:
        print(f"not legal: {args.move}")
        return EXIT_NOT_LEGAL
    print(f"legal: {args.move}")
    return EXIT_OK


def cmd_moves(args: argparse.Namespace) -> int:
    state = _load_state(args.file)
    board = _build_board(state, args.file)
    for move in board.legal_moves:
        print(move.uci())
    return EXIT_OK


def cmd_board(args: argparse.Namespace) -> int:
    state = _load_state(args.file)
    board = _build_board(state, args.file)
    print(str(board))
    print(f"FEN: {board.fen()}")
    print(f"turn: {_turn_name(board)}")
    print(f"ply: {len(state['moves'])}")
    return EXIT_OK


def _result_kind(board: chess.Board, state: dict) -> str:
    """Return the documented result kind string for the current position."""
    if state["ended_by_agreement"]:
        return "ended_by_agreement"
    if board.is_checkmate():
        return "checkmate"
    if board.is_stalemate():
        return "stalemate"
    if board.is_insufficient_material():
        return "insufficient_material"
    if board.is_seventyfive_moves():
        return "seventyfive_moves"
    if board.is_fivefold_repetition():
        return "fivefold_repetition"
    return "none"


def cmd_status(args: argparse.Namespace) -> int:
    state = _load_state(args.file)
    board = _build_board(state, args.file)

    ended_by_agreement = state["ended_by_agreement"]
    if ended_by_agreement:
        is_game_over = True
        result = "ended_by_agreement"
    else:
        is_game_over = board.is_game_over()
        result = _result_kind(board, state)

    winner = None
    if not ended_by_agreement and board.is_checkmate():
        # board.turn is the side to move, who has been mated; the other side won.
        winner = "black" if board.turn == chess.WHITE else "white"

    out = {
        "turn": _turn_name(board),
        "is_game_over": is_game_over,
        "result": result,
        "winner": winner,
        "ended_by_agreement": ended_by_agreement,
        "ply": len(state["moves"]),
    }
    print(json.dumps(out))
    return EXIT_OK


def cmd_declare_stalemate(args: argparse.Namespace) -> int:
    state = _load_state(args.file)
    state["ended_by_agreement"] = True
    _atomic_write(args.file, state)
    print(f"stalemate declared by agreement: {args.file}")
    return EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="c2c_chess",
        description="Private per-agent chess board for agent-vs-agent games over c2c.",
        epilog=(
            "example:\n"
            "  c2c_chess.py new /tmp/white.json\n"
            "  c2c_chess.py move /tmp/white.json e2e4   # SAN or UCI\n"
            "  c2c_chess.py status /tmp/white.json\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("new", help="initialize a fresh game (overwrites)")
    p.add_argument("file")
    p.set_defaults(func=cmd_new)

    p = sub.add_parser("move", help="apply a move (SAN or UCI)")
    p.add_argument("file")
    p.add_argument("move")
    p.set_defaults(func=cmd_move)

    p = sub.add_parser("legal", help="exit 0 if move legal, 1 if not (no mutation)")
    p.add_argument("file")
    p.add_argument("move")
    p.set_defaults(func=cmd_legal)

    p = sub.add_parser("moves", help="list all legal moves (UCI, one per line)")
    p.add_argument("file")
    p.set_defaults(func=cmd_moves)

    p = sub.add_parser("board", help="print ASCII board + FEN + turn + ply")
    p.add_argument("file")
    p.set_defaults(func=cmd_board)

    p = sub.add_parser("status", help="print game status as a JSON object")
    p.add_argument("file")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("declare-stalemate", help="end the game by mutual agreement")
    p.add_argument("file")
    p.set_defaults(func=cmd_declare_stalemate)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
