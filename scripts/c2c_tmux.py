#!/usr/bin/env python3
"""c2c_tmux.py — unified Python CLI for tmux-based swarm operations.

Consolidates scripts/c2c-swarm.sh + c2c-tmux-enter.sh + c2c-tmux-exec.sh +
tmux-layout.sh + tui-snapshot.sh into one discoverable CLI with subcommands.

Usage:
    c2c_tmux.py list
    c2c_tmux.py peek <alias> [-n N]
    c2c_tmux.py send <alias> <text>
    c2c_tmux.py enter <alias>
    c2c_tmux.py keys <alias> <key> [<key>...]
    c2c_tmux.py exec <target> <command> [--force|--escape-tui|--dry-run]
    c2c_tmux.py capture <alias|target> [-n N]
    c2c_tmux.py layout <COLSxROWS>
    c2c_tmux.py whoami

Shared conventions:
    <alias>  — a swarm agent alias (resolved via `c2c start <client> -n <alias>`).
    <target> — any tmux target (session:window.pane, %42, etc.).
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Iterator, NamedTuple

SCRIPT_DIR = Path(__file__).resolve().parent
ENTER_HELPER = SCRIPT_DIR / "c2c-tmux-enter.sh"


# ---------------------------------------------------------------- tmux helpers


def tmux(*args: str, check: bool = True, capture: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["tmux", *args],
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


# ---------------------------------------------------------------- swarm resolve

CLIENT_ARGV_RE = re.compile(r"c2c\s+start\s+\S+\s+(?:.*\s)?-n\s+(\S+)")


class Pane(NamedTuple):
    target: str
    pane_pid: int
    client_pid: int | None
    alias: str | None


def _iter_panes() -> Iterator[Pane]:
    out = tmux("list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_pid}").stdout
    for line in out.splitlines():
        target, _, pid_s = line.partition(" ")
        try:
            pane_pid = int(pid_s)
        except ValueError:
            continue
        yield Pane(target=target, pane_pid=pane_pid, client_pid=None, alias=None)


def _children(pid: int) -> list[int]:
    try:
        out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True, check=False).stdout
    except FileNotFoundError:
        return []
    return [int(x) for x in out.split() if x.strip().isdigit()]


def _argv_of(pid: int) -> str:
    try:
        return subprocess.run(["ps", "-p", str(pid), "-o", "args="], capture_output=True, text=True, check=False).stdout.strip()
    except FileNotFoundError:
        return ""


def _enrich(p: Pane) -> Pane:
    """Walk pane_pid → child; if child is `c2c start <client> -n <alias>`, record it."""
    kids = _children(p.pane_pid)
    if not kids:
        return p
    child = kids[0]
    argv = _argv_of(child)
    m = CLIENT_ARGV_RE.search(argv)
    alias = m.group(1) if m else None
    # client PID: grandchild (claude/opencode/codex/kimi) if present
    grand = _children(child)
    client_pid = grand[0] if grand else None
    return p._replace(client_pid=client_pid, alias=alias)


def enumerate_swarm() -> list[Pane]:
    return [q for q in (_enrich(p) for p in _iter_panes()) if q.alias]


def target_for_alias(alias: str) -> str:
    for p in enumerate_swarm():
        if p.alias == alias:
            return p.target
    sys.exit(f"c2c_tmux: no alias '{alias}' found; try `{sys.argv[0]} list`")


# ---------------------------------------------------------------- commands


def cmd_list(args: argparse.Namespace) -> int:
    panes = enumerate_swarm()
    if not panes:
        print("(no swarm panes found)")
        return 0
    w = max((len(p.alias or "") for p in panes), default=8)
    print(f"{'ALIAS':<{w}}  TARGET           PANE_PID   CLIENT_PID")
    for p in panes:
        print(f"{p.alias:<{w}}  {p.target:<15}  {p.pane_pid:<9}  {p.client_pid or '-'}")
    return 0


def cmd_peek(args: argparse.Namespace) -> int:
    target = target_for_alias(args.alias)
    out = tmux("capture-pane", "-t", target, "-p").stdout
    lines = out.rstrip("\n").splitlines()
    for line in lines[-args.lines:]:
        print(line)
    return 0


def cmd_capture(args: argparse.Namespace) -> int:
    target = args.target
    if not any(c in target for c in ":%."):
        target = target_for_alias(target)
    out = tmux("capture-pane", "-t", target, "-p", "-S", f"-{args.lines}").stdout
    sys.stdout.write(out)
    return 0


def cmd_send(args: argparse.Namespace) -> int:
    target = target_for_alias(args.alias)
    tmux("send-keys", "-t", target, args.text, capture=False)
    return _send_enter(target)


def cmd_enter(args: argparse.Namespace) -> int:
    target = target_for_alias(args.alias)
    return _send_enter(target)


def _send_enter(target: str) -> int:
    if ENTER_HELPER.exists():
        return subprocess.run([str(ENTER_HELPER), target]).returncode
    tmux("send-keys", "-t", target, "Enter", capture=False)
    return 0


def cmd_keys(args: argparse.Namespace) -> int:
    target = target_for_alias(args.alias)
    tmux("send-keys", "-t", target, *args.keys, capture=False)
    return 0


def cmd_exec(args: argparse.Namespace) -> int:
    """Delegate to scripts/c2c-tmux-exec.sh — it already handles TUI detection."""
    exec_sh = SCRIPT_DIR / "c2c-tmux-exec.sh"
    cmd: list[str] = [str(exec_sh)]
    if args.force:
        cmd.append("--force")
    if args.escape_tui:
        cmd.append("--escape-tui")
    if args.dry_run:
        cmd.append("--dry-run")
    cmd.extend([args.target, args.command])
    return subprocess.run(cmd).returncode


def cmd_layout(args: argparse.Namespace) -> int:
    """Delegate to scripts/tmux-layout.sh — the grid math is already there."""
    layout_sh = SCRIPT_DIR / "tmux-layout.sh"
    return subprocess.run([str(layout_sh), args.grid]).returncode


def cmd_whoami(args: argparse.Namespace) -> int:
    tty_env = os.environ.get("TMUX_PANE") or ""
    if not tty_env:
        print("not inside a tmux pane")
        return 1
    for p in enumerate_swarm():
        info = tmux("display-message", "-t", p.target, "-p", "#{pane_id}").stdout.strip()
        if info == tty_env:
            print(f"alias={p.alias} target={p.target} pane_pid={p.pane_pid} client_pid={p.client_pid}")
            return 0
    print(f"pane_id={tty_env} — not a swarm pane")
    return 1


# ---------------------------------------------------------------- argparse


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="c2c_tmux", description=__doc__.splitlines()[0])
    sp = p.add_subparsers(dest="cmd", required=True)

    sp.add_parser("list", help="enumerate swarm panes by alias").set_defaults(func=cmd_list)

    pk = sp.add_parser("peek", help="tail a pane's visible scrollback")
    pk.add_argument("alias")
    pk.add_argument("-n", "--lines", type=int, default=20)
    pk.set_defaults(func=cmd_peek)

    cp = sp.add_parser("capture", help="capture pane scrollback (alias or target)")
    cp.add_argument("target")
    cp.add_argument("-n", "--lines", type=int, default=500)
    cp.set_defaults(func=cmd_capture)

    sd = sp.add_parser("send", help="type text + Enter into a swarm pane")
    sd.add_argument("alias")
    sd.add_argument("text")
    sd.set_defaults(func=cmd_send)

    en = sp.add_parser("enter", help="send a bare Enter (extended-keys safe)")
    en.add_argument("alias")
    en.set_defaults(func=cmd_enter)

    kk = sp.add_parser("keys", help="forward raw tmux key tokens (Enter, Escape, C-c, ...)")
    kk.add_argument("alias")
    kk.add_argument("keys", nargs="+")
    kk.set_defaults(func=cmd_keys)

    ex = sp.add_parser("exec", help="safely run a shell command in a pane (TUI-aware)")
    ex.add_argument("target")
    ex.add_argument("command")
    ex.add_argument("--force", action="store_true")
    ex.add_argument("--escape-tui", action="store_true")
    ex.add_argument("--dry-run", action="store_true")
    ex.set_defaults(func=cmd_exec)

    ly = sp.add_parser("layout", help="apply a COLSxROWS grid layout to the current window")
    ly.add_argument("grid", help="e.g. 3x2")
    ly.set_defaults(func=cmd_layout)

    sp.add_parser("whoami", help="identify the calling pane by alias").set_defaults(func=cmd_whoami)

    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
