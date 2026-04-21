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
    c2c_tmux.py launch <client> [-n ALIAS] [--auto] [--cwd DIR] [--split h|v] [--new-window] [--window NAME] [--extra ARG ...]
    c2c_tmux.py wait-alive <alias> [--timeout SECONDS]
    c2c_tmux.py stop <alias>

Shared conventions:
    <alias>  — a swarm agent alias (resolved via `c2c start <client> -n <alias>`).
    <target> — any tmux target (session:window.pane, %42, etc.).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
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


def alias_is_alive(alias: str) -> bool:
    c2c_bin = shutil.which("c2c") or "c2c"
    try:
        out = subprocess.run([c2c_bin, "list", "--json"], capture_output=True, text=True, check=False).stdout
        rows = json.loads(out) if out.strip() else []
    except (json.JSONDecodeError, FileNotFoundError):
        return False
    return any(r.get("alias") == alias and r.get("alive") is True for r in rows)


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


_SHELL_CMDS = {"fish", "bash", "zsh", "sh", "dash"}


def _find_idle_pane_in_active_window(self_pane_id: str | None) -> str | None:
    """Return first pane in the active window whose current command looks
    like an idle shell (fish/bash/zsh/…) and isn't this very pane.
    Skips panes running c2c, claude, opencode, codex, kimi, crush, node, tmux, etc."""
    out = tmux(
        "list-panes", "-F",
        "#{pane_id}\t#{pane_current_command}\t#{pane_active}",
    ).stdout
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        pid, cmd, active = parts[0], parts[1], parts[2]
        if pid == self_pane_id:
            continue  # never hijack the caller's own pane
        if active == "1":
            continue  # leave the active pane for the human
        if cmd in _SHELL_CMDS:
            return pid
    return None


def cmd_launch(args: argparse.Namespace) -> int:
    """Run `c2c start <client> ...` in a tmux pane.

    By default, reuses an idle shell pane in the current window (fish/bash/zsh
    that isn't the caller's pane and isn't the active pane). Falls back to
    splitting the current pane if no idle pane is available. Use --new-window
    to force a fresh window, or --split h|v to split the active pane.

    Must be called from inside tmux.
    """
    if not os.environ.get("TMUX"):
        print("launch: not inside tmux — open a tmux session first", file=sys.stderr)
        return 2

    c2c_bin = shutil.which("c2c") or "c2c"
    cmd = [c2c_bin, "start", args.client]
    if args.auto:
        cmd.append("--auto")
    if args.name:
        cmd.extend(["-n", args.name])
    if args.extra:
        cmd.extend(args.extra)
    shell_cmd = shlex.join(cmd)

    if args.name and alias_is_alive(args.name):
        print(
            f"launch: alias '{args.name}' is already alive — choose a different name or stop it first",
            file=sys.stderr,
        )
        return 1

    self_pane = os.environ.get("TMUX_PANE")
    pane: str | None = None
    placement: str

    if args.new_window:
        title = args.window or (f"c2c-{args.name}" if args.name else f"c2c-{args.client}")
        res = tmux("new-window", "-n", title, "-P", "-F", "#{pane_id}", "bash")
        pane = res.stdout.strip()
        placement = f"new window '{title}'"
    elif args.split in ("h", "v"):
        flag = "-h" if args.split == "h" else "-v"
        res = tmux("split-window", flag, "-P", "-F", "#{pane_id}", "bash")
        pane = res.stdout.strip()
        placement = f"split --{args.split}"
    else:
        # Default: reuse idle shell pane in active window; fall back to split.
        pane = _find_idle_pane_in_active_window(self_pane)
        if pane:
            placement = "reused idle pane"
        else:
            res = tmux("split-window", "-h", "-P", "-F", "#{pane_id}", "bash")
            pane = res.stdout.strip()
            placement = "split -h (no idle pane found)"

    if not pane:
        print("launch: failed to obtain tmux pane", file=sys.stderr)
        return 1

    if args.cwd:
        tmux("send-keys", "-t", pane, f"cd {shlex.quote(args.cwd)}", "Enter", capture=False)
    # Pre-seed a role file so `c2c start` doesn't block on the interactive
    # role prompt. Targets the workdir the client will actually run in
    # (args.cwd if set, else the caller's cwd).
    if args.role and args.name:
        role_dir = Path(args.cwd) if args.cwd else Path.cwd()
        roles = role_dir / ".c2c" / "roles"
        roles.mkdir(parents=True, exist_ok=True)
        (roles / f"{args.name}.md").write_text(args.role.rstrip() + "\n")
    tmux("send-keys", "-t", pane, shell_cmd, "Enter", capture=False)
    print(f"launched on {pane} ({placement}): {shell_cmd}")
    if args.name:
        print(f"next: {sys.argv[0]} wait-alive {args.name}")
    return 0


def cmd_wait_alive(args: argparse.Namespace) -> int:
    """Poll `c2c list --json` until the alias is alive, or timeout."""
    import json as _json
    import time as _time
    c2c_bin = shutil.which("c2c") or "c2c"
    deadline = _time.monotonic() + args.timeout
    last_status = "missing"
    while _time.monotonic() < deadline:
        try:
            out = subprocess.run([c2c_bin, "list", "--json"], capture_output=True, text=True, check=False).stdout
            rows = _json.loads(out) if out.strip() else []
        except (_json.JSONDecodeError, FileNotFoundError):
            rows = []
        for r in rows:
            if r.get("alias") == args.alias:
                if r.get("alive"):
                    print(f"alive: {args.alias} (pid={r.get('pid')})")
                    return 0
                last_status = f"registered but alive={r.get('alive')} pid={r.get('pid')}"
                break
        _time.sleep(0.5)
    print(f"wait-alive: {args.alias} not alive within {args.timeout}s (last={last_status})", file=sys.stderr)
    return 1


def cmd_stop(args: argparse.Namespace) -> int:
    c2c_bin = shutil.which("c2c") or "c2c"
    return subprocess.run([c2c_bin, "stop", args.alias]).returncode


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

    lc = sp.add_parser("launch", help="open a tmux pane and run `c2c start <client> ...`")
    lc.add_argument("client", help="claude | codex | opencode | kimi | crush")
    lc.add_argument("-n", "--name", help="alias to pass to `c2c start -n <name>`")
    lc.add_argument("--auto", action="store_true", help="forward --auto (kickoff prompt)")
    lc.add_argument("--role", help="pre-seed .c2c/roles/<name>.md so `c2c start` skips the role prompt")
    lc.add_argument("--cwd", help="cd into this dir before running c2c start")
    lc.add_argument("--split", choices=("h", "v"), help="force split of active pane (h|v) instead of reusing an idle pane")
    lc.add_argument("--new-window", action="store_true", help="force fresh tmux window instead of reusing an idle pane")
    lc.add_argument("--window", help="name for the new window (with --new-window; default: c2c-<name|client>)")
    lc.add_argument("--extra", nargs=argparse.REMAINDER, help="extra args forwarded to `c2c start`")
    lc.set_defaults(func=cmd_launch)

    wa = sp.add_parser("wait-alive", help="poll broker until an alias is alive")
    wa.add_argument("alias")
    wa.add_argument("--timeout", type=float, default=60.0)
    wa.set_defaults(func=cmd_wait_alive)

    st = sp.add_parser("stop", help="`c2c stop <alias>` a managed instance")
    st.add_argument("alias")
    st.set_defaults(func=cmd_stop)

    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
