#!/usr/bin/env python3
"""c2c_tmux.py — unified Python CLI for tmux-based swarm operations.

Consolidates scripts/c2c-swarm.sh + c2c-tmux-enter.sh + c2c-tmux-exec.sh +
tmux-layout.sh + tui-snapshot.sh into one discoverable CLI with subcommands.

Usage:
    c2c_tmux.py list
    c2c_tmux.py peek <alias> [-n N]
    c2c_tmux.py peek-all [-n N]
    c2c_tmux.py send <alias> <text>
    c2c_tmux.py send-raw <alias> <text>
    c2c_tmux.py enter <alias>
    c2c_tmux.py keys <alias> <key> [<key>...]
    c2c_tmux.py exec <target> <command> [--force|--escape-tui|--dry-run]
    c2c_tmux.py capture <alias|target> [-n N]
    c2c_tmux.py follow <alias> [logfile]
    c2c_tmux.py unfollow <alias>
    c2c_tmux.py grep <regex> [-S SCROLLBACK]
    c2c_tmux.py grep-echild [-S SCROLLBACK]
    c2c_tmux.py restart <alias>
    c2c_tmux.py layout <COLSxROWS>
    c2c_tmux.py whoami
    c2c_tmux.py launch <client> [-n ALIAS] [--auto] [--cwd DIR] [--split h|v] [--new-window] [--window NAME] [--extra ARG ...]
    c2c_tmux.py wait-alive <alias> [--timeout SECONDS]
    c2c_tmux.py stop <alias>
    c2c_tmux.py supervise [--manifest PATH] [--once] [--dry-run] [--interval S]

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
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterator, NamedTuple

SCRIPT_DIR = Path(__file__).resolve().parent
ENTER_HELPER = SCRIPT_DIR / "c2c-tmux-enter.sh"
ALIAS_CACHE_PATH = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "c2c" / "tmux-aliases.json"


def _load_alias_cache() -> dict[str, str]:
    try:
        return json.loads(ALIAS_CACHE_PATH.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _save_alias_cache(cache: dict[str, str]) -> None:
    ALIAS_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    ALIAS_CACHE_PATH.write_text(json.dumps(cache, indent=2, sort_keys=True))


def _remember_alias(alias: str, target: str) -> None:
    cache = _load_alias_cache()
    if cache.get(alias) != target:
        cache[alias] = target
        _save_alias_cache(cache)


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


def target_for_alias(alias: str, allow_cache: bool = True) -> tuple[str, bool] | None:
    """Return (target, is_live), or None if alias not found in live panes or cache.
    Does NOT sys.exit — callers decide how to handle a missing alias."""
    for p in enumerate_swarm():
        if p.alias == alias:
            _remember_alias(alias, p.target)
            return p.target, True
    if allow_cache:
        cache = _load_alias_cache()
        cached = cache.get(alias)
        if cached:
            print(
                f"c2c_tmux: alias '{alias}' not live in any pane — using last-known target {cached} "
                f"(pane may be reused or empty; verify before acting)",
                file=sys.stderr,
            )
            return cached, False
    return None


def _resolve_target(arg: str) -> tuple[str, bool, bool]:
    """Resolve an alias to (target, is_live, is_bare_target).
    is_bare_target=True means arg was used directly as a tmux target (not from alias cache).
    Bare tmux targets look like 'window.pane' (e.g. '0:1.1')."""
    result = target_for_alias(arg)
    if result is not None:
        return result[0], result[1], False
    # No alias found — treat arg as a bare tmux target if it looks like one
    if any(c in arg for c in ":%."):
        return arg, False, True
    sys.exit(
        f"c2c_tmux: '{arg}' is not a known alias and does not look like a tmux target "
        f"(expected format: window.pane, e.g. '0:1.1'); try `{sys.argv[0]} list`"
    )


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
    live_aliases = {p.alias for p in panes if p.alias}
    # Update cache for all live panes.
    for p in panes:
        if p.alias:
            _remember_alias(p.alias, p.target)
    cache = _load_alias_cache()
    cached_only = {a: t for a, t in cache.items() if a not in live_aliases}

    w = max(
        [len(a) for a in live_aliases | cached_only.keys()] + [5],
        default=8,
    )
    if panes:
        print(f"{'ALIAS':<{w}}  TARGET           PANE_PID   CLIENT_PID")
        for p in panes:
            print(f"{p.alias:<{w}}  {p.target:<15}  {p.pane_pid:<9}  {p.client_pid or '-'}")
    else:
        print("(no live swarm panes)")

    if cached_only and args.show_cached:
        print()
        print(f"{'ALIAS':<{w}}  LAST_TARGET      STATUS")
        for a, t in sorted(cached_only.items()):
            print(f"{a:<{w}}  {t:<15}  cached (not live)")
    elif cached_only:
        print(f"\n({len(cached_only)} cached aliases not live; `list --show-cached` to see)")
    return 0


def cmd_peek(args: argparse.Namespace) -> int:
    target, live, _is_bare = _resolve_target(args.alias)
    tag = "live" if live else "CACHED"
    print(f"-- peek {args.alias} @ {target} ({tag}) --", file=sys.stderr)
    out = tmux("capture-pane", "-t", target, "-p").stdout
    lines = out.rstrip("\n").splitlines()
    for line in lines[-args.lines:]:
        print(line)
    return 0 if live else 2


def cmd_capture(args: argparse.Namespace) -> int:
    target = args.target
    if not any(c in target for c in ":%."):
        target, live, _is_bare = _resolve_target(target)
        tag = "live" if live else "CACHED"
        print(f"-- capture {args.target} @ {target} ({tag}) --", file=sys.stderr)
    out = tmux("capture-pane", "-t", target, "-p", "-S", f"-{args.lines}").stdout
    sys.stdout.write(out)
    return 0


def cmd_send(args: argparse.Namespace) -> int:
    target, live, is_bare = _resolve_target(args.alias)
    if not live and not is_bare:
        print(
            f"c2c_tmux: refusing to send to CACHED target {target} (pane may belong to another process). "
            f"Use `c2c_tmux list` to confirm.",
            file=sys.stderr,
        )
        return 2
    print(f"-- send {args.alias} @ {target} --", file=sys.stderr)
    tmux("send-keys", "-l", "-t", target, " ".join(args.text), capture=False)
    return _send_enter(target)


def cmd_enter(args: argparse.Namespace) -> int:
    target, live, is_bare = _resolve_target(args.alias)
    if not live and not is_bare:
        print(
            f"c2c_tmux: refusing to enter CACHED target {target}. "
            f"Use `c2c_tmux list` to confirm.",
            file=sys.stderr,
        )
        return 2
    print(f"-- enter {args.alias} @ {target} --", file=sys.stderr)
    return _send_enter(target)


def _send_enter(target: str) -> int:
    if ENTER_HELPER.exists():
        return subprocess.run([str(ENTER_HELPER), target]).returncode
    tmux("send-keys", "-t", target, "Enter", capture=False)
    return 0


def cmd_keys(args: argparse.Namespace) -> int:
    target, live, is_bare = _resolve_target(args.alias)
    if not live and not is_bare:
        print(
            f"c2c_tmux: refusing to send keys to CACHED target {target}. "
            f"Use `c2c_tmux list` to confirm, or pass a bare tmux target directly.",
            file=sys.stderr,
        )
        return 2
    print(f"-- keys {args.alias} @ {target} : {' '.join(args.keys)} --", file=sys.stderr)
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
        for token in args.extra:
            cmd.extend(shlex.split(token))
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


def cmd_peek_all(args: argparse.Namespace) -> int:
    """Peek the last N lines of every live swarm pane."""
    panes = enumerate_swarm()
    if not panes:
        print("(no live swarm panes)", file=sys.stderr)
        return 0
    for p in panes:
        print(f"===== {p.alias} ({p.target}) =====")
        out = tmux("capture-pane", "-t", p.target, "-p").stdout
        lines = out.rstrip("\n").splitlines()
        for line in lines[-args.lines:]:
            print(line)
        print()
    return 0


def cmd_send_raw(args: argparse.Namespace) -> int:
    """Type text into a pane WITHOUT a trailing Enter."""
    target, live, is_bare = _resolve_target(args.alias)
    if not live and not is_bare:
        print(
            f"c2c_tmux: refusing to send-raw to CACHED target {target} (pane may belong to another process). "
            f"Use `c2c_tmux list` to confirm.",
            file=sys.stderr,
        )
        return 2
    print(f"-- send-raw {args.alias} @ {target} --", file=sys.stderr)
    # -l = literal text (match the bash original's `send-keys -l "$*"`); without
    # it tokens like Enter / C-c are interpreted as key names, not typed text.
    tmux("send-keys", "-l", "-t", target, " ".join(args.text), capture=False)
    return 0


def cmd_follow(args: argparse.Namespace) -> int:
    """Stream a pane's output to a logfile via tmux pipe-pane."""
    target, live, is_bare = _resolve_target(args.alias)
    if not live and not is_bare:
        print(
            f"c2c_tmux: refusing to follow CACHED target {target}. "
            f"Use `c2c_tmux list` to confirm.",
            file=sys.stderr,
        )
        return 2
    logfile = args.logfile or f"/tmp/c2c-swarm-{args.alias}.log"
    tmux("pipe-pane", "-t", target, "-o", f"cat >> {shlex.quote(logfile)}", capture=False)
    print(f"streaming {args.alias} ({target}) → {logfile}")
    print(f"stop with: {sys.argv[0]} unfollow {args.alias}")
    return 0


def cmd_unfollow(args: argparse.Namespace) -> int:
    """Stop streaming a pane (clear its pipe-pane)."""
    target, live, is_bare = _resolve_target(args.alias)
    if not live and not is_bare:
        print(
            f"c2c_tmux: refusing to unfollow CACHED target {target}. "
            f"Use `c2c_tmux list` to confirm.",
            file=sys.stderr,
        )
        return 2
    tmux("pipe-pane", "-t", target, capture=False)
    print(f"stopped streaming {args.alias}")
    return 0


_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def _grep_swarm(pattern: str, ignore_case: bool, scrollback: int) -> int:
    """Grep ANSI-stripped scrollback across all live swarm panes.
    Returns 0 always (matches the bash original's lenient contract)."""
    flags = re.IGNORECASE if ignore_case else 0
    try:
        rx = re.compile(pattern, flags)
    except re.error as e:
        print(f"c2c_tmux: bad regex {pattern!r}: {e}", file=sys.stderr)
        return 2
    hits = 0
    for p in enumerate_swarm():
        out = tmux("capture-pane", "-t", p.target, "-p", "-S", f"-{scrollback}").stdout
        matched: list[str] = []
        for i, raw in enumerate(out.splitlines(), start=1):
            line = _ANSI_RE.sub("", raw)
            if rx.search(line):
                matched.append(f"{i}:{line}")
        if matched:
            hits += 1
            print(f"===== {p.alias} ({p.target}) =====")
            print("\n".join(matched))
            print()
    if hits == 0:
        print("(no matches across swarm)", file=sys.stderr)
    return 0


def cmd_grep(args: argparse.Namespace) -> int:
    return _grep_swarm(args.pattern, ignore_case=False, scrollback=args.scrollback)


def cmd_grep_echild(args: argparse.Namespace) -> int:
    return _grep_swarm("echild", ignore_case=True, scrollback=args.scrollback)


def cmd_restart(args: argparse.Namespace) -> int:
    """Send /exit to a pane, wait for it to return to a shell prompt (handling
    Claude Code's 'Background work is running' confirm dialog along the way),
    then relaunch `c2c start claude -n <alias>` in the same pane."""
    import time as _time

    target, live, is_bare = _resolve_target(args.alias)
    if not live and not is_bare:
        print(
            f"c2c_tmux: refusing to restart CACHED target {target}. "
            f"Use `c2c_tmux list` to confirm.",
            file=sys.stderr,
        )
        return 2
    print(f"restarting {args.alias} at {target} …")
    # Claude Code responds to the /exit slash command.
    tmux("send-keys", "-t", target, "/exit", capture=False)
    _send_enter(target)
    print("sent /exit; waiting up to 30s for shell prompt to return…")
    # The shell-ready signal is the c2c-start wrapper's post-exit banner
    # ("resume via: c2c start …"). Waiting on a bare "❯" is unreliable
    # because Claude's "Background work is running" confirmation dialog
    # also renders "❯ 1. Exit anyway" in its last three lines. If we see
    # that dialog, press Enter to confirm option 1 (Exit anyway).
    confirmed = False
    for _ in range(60):
        snap_raw = tmux("capture-pane", "-t", target, "-p").stdout
        snap = _ANSI_RE.sub("", "\n".join(snap_raw.splitlines()[-15:]))
        if "resume via: c2c start" in snap:
            print("shell prompt detected (c2c-start exit banner)")
            break
        if ("Background work is running" in snap or "Exit anyway" in snap) and not confirmed:
            print("confirm-exit dialog detected; pressing Enter to confirm")
            _send_enter(target)
            confirmed = True
        _time.sleep(0.5)
    print(f"relaunching: c2c start claude -n {args.alias}")
    tmux("send-keys", "-t", target, f"c2c start claude -n {args.alias}", capture=False)
    _send_enter(target)
    print("done — give Claude Code a few seconds to boot")
    return 0


# ------------------------------------------------ supervise (self-healing)
#
# A lightweight DECLARATIVE supervisor: a TOML manifest of agents to keep
# alive, plus a respawn loop that detects a dead/exited agent and relaunches
# it in a fresh tmux window. The decision logic is factored into pure
# functions (parse_supervise_manifest / decide_respawns / backoff_delay) so it
# is unit-testable without a real tmux server; the only effectful pieces are
# live_aliases() (queries the broker via `c2c list --json`) and
# _respawn_agent() (drives tmux). run_supervise_tick() takes those as
# injectable callables so tests never touch tmux or the broker.
#
# Manifest shape (.c2c/supervise.toml — see .c2c/supervise.example.toml):
#
#     [supervisor]
#     poll_interval_s = 15      # seconds between liveness polls
#     backoff_base_s  = 30      # post-launch grace + first retry delay
#     backoff_max_s   = 300     # exponential-backoff ceiling
#     session         = ""      # optional tmux session to spawn windows in
#
#     [[agent]]
#     alias  = "coordinator1"
#     client = "claude"
#     role   = "coordinator"     # optional; pre-seeds .c2c/roles/<alias>.md
#     cwd    = "/path/to/repo"   # optional; cd before `c2c start`
#     extra  = ["--auto"]        # optional extra args to `c2c start`

DEFAULT_SUPERVISE_OPTS: dict[str, object] = {
    "poll_interval_s": 15.0,
    "backoff_base_s": 30.0,
    "backoff_max_s": 300.0,
    "session": None,
}


@dataclass
class SuperviseSpec:
    """A single agent the supervisor keeps alive."""

    alias: str
    client: str
    role: str = ""
    cwd: str = ""
    extra: list[str] = field(default_factory=list)


def _default_manifest_path() -> Path:
    env = os.environ.get("C2C_SUPERVISE_MANIFEST")
    if env:
        return Path(env)
    return Path.cwd() / ".c2c" / "supervise.toml"


def parse_supervise_manifest(text: str) -> tuple[list[SuperviseSpec], dict[str, object]]:
    """Parse a TOML supervise manifest into (specs, supervisor-options).

    Pure: string in, data out. Raises ValueError on a malformed agent entry
    (missing alias/client) so the caller can keep the last-good config.
    """
    import tomllib  # stdlib, Python 3.11+; imported lazily so other
    # subcommands keep working on older interpreters.

    data = tomllib.loads(text)

    opts = dict(DEFAULT_SUPERVISE_OPTS)
    raw = data.get("supervisor", {})
    if isinstance(raw, dict):
        for k in ("poll_interval_s", "backoff_base_s", "backoff_max_s"):
            if k in raw:
                opts[k] = float(raw[k])
        if "session" in raw:
            session = str(raw["session"]).strip()
            opts["session"] = session or None

    specs: list[SuperviseSpec] = []
    for entry in data.get("agent", []):
        if not isinstance(entry, dict):
            continue
        alias = str(entry.get("alias", "")).strip()
        client = str(entry.get("client", "")).strip()
        if not alias or not client:
            raise ValueError(f"agent entry missing alias/client: {entry!r}")
        extra_raw = entry.get("extra", [])
        extra = [str(x) for x in extra_raw] if isinstance(extra_raw, list) else []
        specs.append(
            SuperviseSpec(
                alias=alias,
                client=client,
                role=str(entry.get("role", "")),
                cwd=str(entry.get("cwd", "")),
                extra=extra,
            )
        )
    return specs, opts


def backoff_delay(fail_count: int, base_s: float, cap_s: float) -> float:
    """Exponential backoff: base * 2**(fail_count-1), capped at cap_s.

    fail_count is 1 on the first respawn attempt. The base delay doubles as
    the post-launch grace period — after issuing a respawn we wait at least
    base_s before considering the agent failed again, so a slow-booting agent
    is not double-launched.
    """
    if fail_count <= 1:
        return min(base_s, cap_s)
    return min(base_s * (2 ** (fail_count - 1)), cap_s)


def decide_respawns(
    specs: list[SuperviseSpec],
    live: set[str],
    state: dict[str, dict],
    now: float,
    *,
    base_s: float,
    cap_s: float,
) -> tuple[list[SuperviseSpec], dict[str, dict]]:
    """Pure respawn decision.

    Given the desired *specs*, the set of currently-*live* aliases, the prior
    backoff *state* (alias -> {"fail_count", "next_attempt_ts"}) and the
    current time *now*, return (to_respawn, new_state).

    Invariants:
      - A live alias is never respawned (idempotent) and its backoff resets.
      - A dead alias is respawned only when now >= its next_attempt_ts.
      - Each respawn pushes next_attempt_ts out by backoff_delay(...) to damp
        crash-loops.
      - State for aliases no longer in the manifest is dropped.
    """
    new_state = {a: dict(v) for a, v in state.items()}
    to_respawn: list[SuperviseSpec] = []
    spec_aliases: set[str] = set()

    for spec in specs:
        spec_aliases.add(spec.alias)
        if spec.alias in live:
            new_state.pop(spec.alias, None)  # healthy → reset backoff
            continue
        entry = new_state.get(spec.alias, {"fail_count": 0, "next_attempt_ts": 0.0})
        if now >= entry["next_attempt_ts"]:
            fail_count = int(entry["fail_count"]) + 1
            delay = backoff_delay(fail_count, base_s, cap_s)
            new_state[spec.alias] = {
                "fail_count": fail_count,
                "next_attempt_ts": now + delay,
            }
            to_respawn.append(spec)
        else:
            new_state[spec.alias] = entry  # still backing off

    for alias in list(new_state):
        if alias not in spec_aliases:
            new_state.pop(alias, None)  # drop stale (removed from manifest)

    return to_respawn, new_state


def live_aliases() -> set[str]:
    """Set of aliases the broker reports as alive (via `c2c list --json`)."""
    c2c_bin = shutil.which("c2c") or "c2c"
    try:
        out = subprocess.run(
            [c2c_bin, "list", "--json"], capture_output=True, text=True, check=False
        ).stdout
        rows = json.loads(out) if out.strip() else []
    except (json.JSONDecodeError, FileNotFoundError):
        return set()
    return {r.get("alias") for r in rows if r.get("alive") is True and r.get("alias")}


def _respawn_agent(spec: SuperviseSpec, session: str | None = None) -> bool:
    """Launch `c2c start <client> -n <alias>` in a fresh detached tmux window.

    Returns True if the launch was issued. Requires being inside tmux.
    """
    if not os.environ.get("TMUX"):
        print(
            "supervise: not inside tmux — cannot respawn "
            "(run the supervisor inside a tmux session)",
            file=sys.stderr,
        )
        return False

    c2c_bin = shutil.which("c2c") or "c2c"
    cmd = [c2c_bin, "start", spec.client, "-n", spec.alias, *spec.extra]
    shell_cmd = shlex.join(cmd)

    title = f"c2c-{spec.alias}"
    window_args = ["new-window", "-d", "-n", title, "-P", "-F", "#{pane_id}"]
    if session:
        window_args.extend(["-t", session])
    window_args.append("bash")
    res = tmux(*window_args)
    pane = res.stdout.strip()
    if not pane:
        print(f"supervise: failed to create window for {spec.alias}", file=sys.stderr)
        return False

    if spec.cwd:
        tmux("send-keys", "-t", pane, f"cd {shlex.quote(spec.cwd)}", "Enter", capture=False)
    # Pre-seed a role file so `c2c start` doesn't block on the role prompt.
    # Mirrors cmd_launch --role semantics. Targets the workdir the client will
    # run in (spec.cwd if set, else the supervisor's cwd).
    if spec.role:
        role_dir = Path(spec.cwd) if spec.cwd else Path.cwd()
        roles = role_dir / ".c2c" / "roles"
        roles.mkdir(parents=True, exist_ok=True)
        (roles / f"{spec.alias}.md").write_text(spec.role.rstrip() + "\n")
    tmux("send-keys", "-t", pane, shell_cmd, "Enter", capture=False)
    print(f"supervise: respawned {spec.alias} ({spec.client}) on {pane} [{title}]")
    return True


def run_supervise_tick(
    specs: list[SuperviseSpec],
    state: dict[str, dict],
    *,
    live_fn: Callable[[], set[str]],
    respawn_fn: Callable[[SuperviseSpec], bool],
    now: float,
    base_s: float,
    cap_s: float,
    dry_run: bool = False,
) -> dict[str, dict]:
    """Run one supervise iteration; return the updated backoff state.

    Effects are confined to the injected *live_fn* / *respawn_fn*, so unit
    tests pass fakes and never touch tmux or the broker.
    """
    live = live_fn()
    to_respawn, new_state = decide_respawns(
        specs, live, state, now, base_s=base_s, cap_s=cap_s
    )
    for spec in to_respawn:
        if dry_run:
            fail_count = new_state.get(spec.alias, {}).get("fail_count", 1)
            print(
                f"supervise[dry-run]: would respawn {spec.alias} "
                f"({spec.client}) — attempt #{fail_count}"
            )
        else:
            respawn_fn(spec)
    return new_state


def cmd_supervise(args: argparse.Namespace) -> int:
    """Declarative self-healing loop: keep manifest agents alive.

    Re-reads the manifest each tick (hot-reload), polls broker liveness, and
    respawns any dead agent whose backoff window has elapsed. `--once` runs a
    single tick (cron-friendly); `--dry-run` reports decisions without
    launching anything.
    """
    import time as _time

    manifest_path = Path(args.manifest) if args.manifest else _default_manifest_path()
    specs: list[SuperviseSpec] = []
    opts: dict[str, object] = dict(DEFAULT_SUPERVISE_OPTS)

    def load() -> bool:
        """Reload manifest; keep last-good config on parse error. Returns
        False only when nothing usable is available."""
        nonlocal specs, opts
        try:
            text = manifest_path.read_text()
        except FileNotFoundError:
            print(f"supervise: manifest not found: {manifest_path}", file=sys.stderr)
            return bool(specs)
        try:
            specs, opts = parse_supervise_manifest(text)
        except Exception as exc:  # parse/validation error
            print(
                f"supervise: manifest parse error ({exc}); keeping last-good config",
                file=sys.stderr,
            )
            return bool(specs)
        return True

    if not load() and not specs:
        return 1
    if not specs:
        print(f"supervise: no agents in manifest {manifest_path}", file=sys.stderr)
        return 1

    state: dict[str, dict] = {}

    def respawn(spec: SuperviseSpec) -> bool:
        return _respawn_agent(spec, session=opts.get("session"))  # type: ignore[arg-type]

    print(
        f"supervise: watching {len(specs)} agent(s) from {manifest_path} "
        f"({'dry-run' if args.dry_run else 'live'}"
        f"{', once' if args.once else ''})",
        file=sys.stderr,
    )
    try:
        while True:
            load()  # hot-reload before each tick
            interval = float(
                args.interval if args.interval is not None else opts["poll_interval_s"]
            )
            base_s = float(opts["backoff_base_s"])
            cap_s = float(opts["backoff_max_s"])
            state = run_supervise_tick(
                specs,
                state,
                live_fn=live_aliases,
                respawn_fn=respawn,
                now=_time.monotonic(),
                base_s=base_s,
                cap_s=cap_s,
                dry_run=args.dry_run,
            )
            if args.once:
                return 0
            _time.sleep(max(interval, 1.0))
    except KeyboardInterrupt:
        print("\nsupervise: interrupted — exiting", file=sys.stderr)
        return 0


# ---------------------------------------------------------------- argparse


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="c2c_tmux", description=__doc__.splitlines()[0])
    sp = p.add_subparsers(dest="cmd", required=True)

    ls = sp.add_parser("list", help="enumerate swarm panes by alias")
    ls.add_argument("--show-cached", action="store_true", help="include cached aliases no longer live")
    ls.set_defaults(func=cmd_list)

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
    sd.add_argument("text", nargs="+", help="text to type literally (joined by spaces)")
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

    pa = sp.add_parser("peek-all", help="tail every live swarm pane")
    pa.add_argument("-n", "--lines", type=int, default=10)
    pa.set_defaults(func=cmd_peek_all)

    sr = sp.add_parser("send-raw", help="type text into a pane WITHOUT a trailing Enter")
    sr.add_argument("alias")
    sr.add_argument("text", nargs="+", help="text to type literally (joined by spaces)")
    sr.set_defaults(func=cmd_send_raw)

    fl = sp.add_parser("follow", help="stream a pane to a logfile (tmux pipe-pane)")
    fl.add_argument("alias")
    fl.add_argument("logfile", nargs="?", help="default: /tmp/c2c-swarm-<alias>.log")
    fl.set_defaults(func=cmd_follow)

    uf = sp.add_parser("unfollow", help="stop streaming a pane (clear pipe-pane)")
    uf.add_argument("alias")
    uf.set_defaults(func=cmd_unfollow)

    gr = sp.add_parser("grep", help="grep ANSI-stripped scrollback across all swarm panes")
    gr.add_argument("pattern", help="regex (Python re syntax)")
    gr.add_argument("-S", "--scrollback", type=int, default=2000, help="lines of scrollback to search per pane")
    gr.set_defaults(func=cmd_grep)

    ge = sp.add_parser("grep-echild", help="convenience: grep -i echild across all swarm panes")
    ge.add_argument("-S", "--scrollback", type=int, default=2000, help="lines of scrollback to search per pane")
    ge.set_defaults(func=cmd_grep_echild)

    rs = sp.add_parser("restart", help="/exit a claude pane (handle confirm dialog) + relaunch in place")
    rs.add_argument("alias")
    rs.set_defaults(func=cmd_restart)

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

    su = sp.add_parser(
        "supervise",
        help="declarative self-healing loop: keep manifest agents alive",
    )
    su.add_argument(
        "--manifest",
        help="path to the TOML manifest (default: $C2C_SUPERVISE_MANIFEST or .c2c/supervise.toml)",
    )
    su.add_argument("--once", action="store_true", help="run a single tick then exit (cron-friendly)")
    su.add_argument("--dry-run", action="store_true", help="report respawn decisions without launching")
    su.add_argument(
        "--interval",
        type=float,
        default=None,
        help="override poll interval (seconds); default from manifest [supervisor].poll_interval_s",
    )
    su.set_defaults(func=cmd_supervise)

    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
