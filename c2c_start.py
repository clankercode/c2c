#!/usr/bin/env python3
"""Unified instance launcher for c2c-managed agent sessions.

Usage:
    c2c start <client> [-n NAME] [--detach] [-- EXTRA_ARGS...]
    c2c stop <NAME>
    c2c restart <NAME>
    c2c instances [--json]

Launches a client with c2c env vars, deliver daemon, and poker.
When the client exits, prints a resume command and exits.
Does NOT loop — use the printed command to relaunch.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import termios
import time
import uuid
from pathlib import Path
from typing import Any

import c2c_mcp

# ---------------------------------------------------------------------------
# Per-client configuration
# ---------------------------------------------------------------------------

CLIENT_CONFIGS: dict[str, dict[str, Any]] = {
    "claude": {
        "binary": "claude",
        "deliver_client": "claude",
        "needs_poker": True,
        "poker_event": "heartbeat",
        "poker_from": "claude-poker",
        "needs_pty": True,
        "extra_env": {},
    },
    "codex": {
        "binary": "codex",
        "deliver_client": "codex",
        "needs_poker": False,
        "extra_env": {},
    },
    "opencode": {
        "binary": "opencode",
        "deliver_client": "opencode",
        "needs_poker": False,
        # TypeScript plugin (c2c.ts) handles delivery via c2c monitor → promptAsync.
        # PTY-based deliver daemon is deprecated for OpenCode.
        "skip_deliver": True,
        "extra_env": {},
    },
    "kimi": {
        "binary": "kimi",
        "deliver_client": "kimi",
        "needs_poker": True,
        "poker_event": "heartbeat",
        "poker_from": "kimi-poker",
        "extra_env": {},
    },
    "crush": {
        "binary": "crush",
        "deliver_client": "crush",
        "needs_poker": False,
        "extra_env": {},
    },
}

SUPPORTED_CLIENTS: set[str] = set(CLIENT_CONFIGS.keys())

# ---------------------------------------------------------------------------
# State directory
# ---------------------------------------------------------------------------

INSTANCES_DIR = Path.home() / ".local" / "share" / "c2c" / "instances"
DOUBLE_SIGINT_WINDOW_SECONDS = 2.0

HERE = Path(__file__).resolve().parent


def _preflight_pidfd_check() -> tuple[bool, str | None]:
    """Probe whether pidfd_getfd works across process boundaries.

    Self-probes always succeed (ptrace_scope doesn't restrict self-access),
    so we check more cheaply: is ptrace_scope permissive, or does the
    interpreter have cap_sys_ptrace? If neither, inject will fail.

    Returns (ok, error_message). ok=True means PTY injection will work.
    ok=False with an error message means the caller should print a banner
    and continue in degraded mode.
    """
    # Short-circuit: if ptrace_scope is 0, cross-process pidfd_getfd is unrestricted.
    try:
        scope_raw = Path("/proc/sys/kernel/yama/ptrace_scope").read_text().strip()
        if scope_raw == "0":
            return True, None
    except OSError:
        return True, None  # no yama module — pidfd_getfd likely unrestricted

    # ptrace_scope >= 1: need cap_sys_ptrace on the interpreter.
    import shutil as _shutil

    getcap = _shutil.which("getcap")
    interp = os.path.realpath(sys.executable)
    if getcap is None:
        return True, None  # can't check; assume ok rather than false-positive banner
    try:
        result = subprocess.run(
            [getcap, interp],
            capture_output=True,
            text=True,
            check=False,
            timeout=5.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return True, None
    if "cap_sys_ptrace" in result.stdout.lower():
        return True, None
    return False, (
        f"ptrace_scope={scope_raw} and interpreter {interp} lacks cap_sys_ptrace"
    )


def _print_pidfd_banner(err: str) -> None:
    interp = os.path.realpath(sys.executable)
    print(
        f"[c2c] PTY injection unavailable: CAP_SYS_PTRACE missing on {interp}\n"
        f"      Run: sudo setcap cap_sys_ptrace=ep {interp}\n"
        f"      Or:  sudo sysctl -w kernel.yama.ptrace_scope=0  (lowers system-wide ptrace guard)\n"
        f"      Continuing in degraded mode — MCP delivery still works for Claude Code\n"
        f"      (PostToolUse hook) and any client that drains via mcp__c2c__poll_inbox.\n"
        f"      Details: {err}",
        flush=True,
    )


def _instance_dir(name: str) -> Path:
    return INSTANCES_DIR / name


def _instance_config_path(name: str) -> Path:
    return _instance_dir(name) / "config.json"


def _outer_pid_path(name: str) -> Path:
    return _instance_dir(name) / "outer.pid"


def _deliver_pid_path(name: str) -> Path:
    return _instance_dir(name) / "deliver.pid"


def _poker_pid_path(name: str) -> Path:
    return _instance_dir(name) / "poker.pid"


def default_name(client: str) -> str:
    """Default instance name: <client>-<hostname>."""
    hostname = socket.gethostname().split(".")[0]
    return f"{client}-{hostname}"


# ---------------------------------------------------------------------------
# Client setup detection and auto-setup
# ---------------------------------------------------------------------------

def _load_json(path: Path) -> dict:
    """Load JSON file, return empty dict if missing or invalid."""
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _is_claude_configured() -> bool:
    """Check if Claude Code has c2c configured (PostToolUse hook)."""
    settings_path = Path.home() / ".claude" / "settings.json"
    if not settings_path.exists():
        return False
    settings = _load_json(settings_path)
    hook_cmd = str(Path.home() / ".claude" / "hooks" / "c2c-inbox-check.sh")
    for group in settings.get("hooks", {}).get("PostToolUse", []):
        for h in group.get("hooks", []):
            if h.get("command") == hook_cmd:
                return True
    return False


def is_client_configured(client: str) -> bool:
    """Check if a client has been set up for c2c."""
    if client == "claude":
        return _is_claude_configured()
    # Other clients: extend as needed
    return True  # Assume configured until we add checks


def ensure_client_configured(client: str) -> bool:
    """Ensure client is configured, running setup if not. Returns True if configured."""
    if is_client_configured(client):
        return True
    print(f"[c2c] {client} not configured, running c2c setup {client}...", flush=True)
    # For claude, use claude-code (the setup client name)
    setup_client = "claude-code" if client == "claude" else client
    setup_script = HERE / "c2c_setup.py"
    args = [sys.executable, str(setup_script), setup_client]
    result = subprocess.run(args)
    if result.returncode != 0:
        print(f"[c2c] warning: setup failed for {client}", flush=True)
        return False
    print(f"[c2c] {client} setup complete", flush=True)
    return True


# ---------------------------------------------------------------------------
# Instance state helpers
# ---------------------------------------------------------------------------


def _read_pid(path: Path) -> int | None:
    """Read a PID from a pidfile, return None if not found or invalid."""
    try:
        return int(path.read_text().strip())
    except (OSError, ValueError):
        return None


def _pid_alive(pid: int | None) -> bool:
    if pid is None or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def _write_pidfile(path: Path, pid: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(str(pid), encoding="utf-8")


def _remove_pidfile(path: Path) -> None:
    try:
        path.unlink()
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Public API (task 1 surface)
# ---------------------------------------------------------------------------


def instances_dir() -> Path:
    """Return ~/.local/share/c2c/instances, creating it if needed."""
    INSTANCES_DIR.mkdir(parents=True, exist_ok=True)
    return INSTANCES_DIR


def instance_dir(name: str) -> Path:
    """Return the state directory for a named instance."""
    return instances_dir() / name


def broker_root() -> Path:
    """Return the MCP broker root (<git-common-dir>/c2c/mcp).

    Uses ``C2C_MCP_BROKER_ROOT`` env override when set, otherwise shells
    out to ``git rev-parse --git-common-dir``.
    """
    env_override = os.environ.get("C2C_MCP_BROKER_ROOT", "").strip()
    if env_override:
        return Path(env_override)
    result = subprocess.run(
        ["git", "rev-parse", "--git-common-dir"],
        capture_output=True,
        text=True,
    )
    return Path(result.stdout.strip()) / "c2c" / "mcp"


def build_env(name: str, alias_override: str | None = None) -> dict[str, str]:
    """Build environment dict for a managed client subprocess."""
    env = dict(os.environ)
    env["C2C_MCP_SESSION_ID"] = name
    env["C2C_MCP_AUTO_REGISTER_ALIAS"] = alias_override or name
    env["C2C_MCP_BROKER_ROOT"] = str(broker_root())
    env["C2C_MCP_AUTO_JOIN_ROOMS"] = "swarm-lounge"
    env["C2C_MCP_AUTO_DRAIN_CHANNEL"] = "0"
    return env


def _kimi_mcp_config_path(name: str) -> Path:
    return _instance_dir(name) / "kimi-mcp.json"


def _has_explicit_kimi_mcp_config(extra_args: list[str]) -> bool:
    explicit_flags = {"--mcp-config-file", "--mcp-config"}
    for arg in extra_args:
        if arg in explicit_flags:
            return True
        if arg.startswith("--mcp-config-file=") or arg.startswith("--mcp-config="):
            return True
    return False


def _build_kimi_mcp_config(name: str, broker_root: Path, alias_override: str | None = None) -> dict[str, Any]:
    alias = alias_override or name
    return {
        "mcpServers": {
            "c2c": {
                "type": "stdio",
                "command": "python3",
                "args": [str(HERE / "c2c_mcp.py")],
                "env": {
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                    "C2C_MCP_SESSION_ID": name,
                    "C2C_MCP_AUTO_REGISTER_ALIAS": alias,
                    "C2C_MCP_AUTO_JOIN_ROOMS": "swarm-lounge",
                    "C2C_MCP_AUTO_DRAIN_CHANNEL": "0",
                },
            }
        }
    }


def prepare_launch_args(
    name: str, client: str, extra_args: list[str], broker_root: Path, alias_override: str | None = None, *, resume_session_id: str | None = None, binary_override: str | None = None, is_resume: bool = False
) -> list[str]:
    """Return client args, adding managed per-instance config where needed."""
    args: list[str] = []

    # Pin a stable --session-id so we can --resume by it later.
    # Only clients that support these flags get them.
    if client == "claude" and resume_session_id:
        args.extend(["--session-id", resume_session_id])
        # Custom binaries (--bin) may not support --session-id without --fork-session.
        if binary_override:
            args.append("--fork-session")
        else:
            args.extend(["--resume", resume_session_id])
    elif client == "opencode":
        # OpenCode session IDs are TUI-generated ("ses_*"); a UUID-style
        # resume_session_id is just our stable-name placeholder. Prefer a
        # captured ses_* ID; otherwise fall back to --continue on resume so
        # the TUI reopens the most recently touched session for this user.
        captured_path = instance_dir(name) / "opencode-session.txt"
        captured = captured_path.read_text().strip() if captured_path.exists() else ""
        if captured.startswith("ses"):
            args.extend(["--session", captured])
        elif resume_session_id and resume_session_id.startswith("ses"):
            args.extend(["--session", resume_session_id])
        elif is_resume:
            args.append("--continue")
    elif client == "codex" and resume_session_id:
        args.extend(["resume", "--last"])

    if client != "kimi" or _has_explicit_kimi_mcp_config(extra_args):
        return args + list(extra_args)

    mcp_config_path = _kimi_mcp_config_path(name)
    mcp_config_path.parent.mkdir(parents=True, exist_ok=True)
    mcp_config_path.write_text(
        json.dumps(_build_kimi_mcp_config(name, broker_root, alias_override), indent=2) + "\n",
        encoding="utf-8",
    )
    return ["--mcp-config-file", str(mcp_config_path), *extra_args]


def write_config(name: str, client: str, extra_args: list[str] | None = None) -> Path:
    """Write a JSON config file for a named instance. Returns the path."""
    cfg = instance_dir(name)
    cfg.mkdir(parents=True, exist_ok=True)
    config_path = cfg / "config.json"
    data = {
        "client": client,
        "name": name,
        "binary": CLIENT_CONFIGS[client]["binary"],
        "extra_args": list(extra_args) if extra_args else [],
    }
    config_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return config_path


def load_config(name: str) -> dict:
    """Load instance config.json; raises SystemExit on error."""
    path = _instance_config_path(name)
    if not path.exists():
        raise SystemExit(f"[c2c-start] config not found: {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"[c2c-start] invalid JSON in {path}: {exc}")
    if not isinstance(data, dict):
        raise SystemExit(f"[c2c-start] config root must be an object: {path}")
    return data


def pid_alive(pid: int) -> bool:
    """Check whether a process with the given PID is alive."""
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def read_pid(pidfile: Path) -> int | None:
    """Read a PID from a pidfile. Returns None if missing or invalid."""
    try:
        return int(pidfile.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None


def write_pid(pidfile: Path, pid: int) -> None:
    """Write a PID to a pidfile, creating parent dirs as needed."""
    pidfile.parent.mkdir(parents=True, exist_ok=True)
    pidfile.write_text(f"{pid}\n", encoding="utf-8")


def cleanup_pidfiles(d: Path) -> list[str]:
    """Remove stale pidfiles in *d* whose processes are no longer alive.

    Returns the list of filenames that were cleaned up.
    """
    cleaned: list[str] = []
    if not d.is_dir():
        return cleaned
    for pidfile in d.glob("*.pid"):
        pid = read_pid(pidfile)
        if pid is None or not pid_alive(pid):
            pidfile.unlink(missing_ok=True)
            cleaned.append(pidfile.name)
    return cleaned


def cleanup_fea_so() -> None:
    """Remove any ``libfea_inject.so`` leftover in /tmp."""
    for candidate in [Path("/tmp/libfea_inject.so")]:
        candidate.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Legacy / internal helpers (kept for backward compat)
# ---------------------------------------------------------------------------


def load_instance_config(name: str) -> dict[str, Any] | None:
    """Load instance config.json; return None if not found."""
    path = _instance_config_path(name)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def save_instance_config(name: str, cfg: dict[str, Any]) -> None:
    path = _instance_config_path(name)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(cfg, indent=2), encoding="utf-8")


# ---------------------------------------------------------------------------
# Instance enumeration
# ---------------------------------------------------------------------------


def list_instances() -> list[dict[str, Any]]:
    """Enumerate all known instances under INSTANCES_DIR."""
    results = []
    if not INSTANCES_DIR.exists():
        return results
    for entry in sorted(INSTANCES_DIR.iterdir()):
        if not entry.is_dir():
            continue
        name = entry.name
        cfg = load_instance_config(name)
        if cfg is None:
            continue
        outer_pid = _read_pid(_outer_pid_path(name))
        deliver_pid = _read_pid(_deliver_pid_path(name))
        poker_pid = _read_pid(_poker_pid_path(name))
        outer_alive = _pid_alive(outer_pid)

        uptime_s: float | None = None
        if outer_alive and outer_pid:
            try:
                stat = Path(f"/proc/{outer_pid}/stat").read_text()
                # Field 22 is starttime in clock ticks since boot
                fields = stat.split()
                starttime_ticks = int(fields[21])
                hz = os.sysconf("SC_CLK_TCK")
                boot_time = float(Path("/proc/uptime").read_text().split()[0])
                start_since_boot = starttime_ticks / hz
                uptime_s = boot_time - start_since_boot
            except (OSError, IndexError, ValueError):
                created_at = cfg.get("created_at")
                if created_at is not None:
                    uptime_s = time.time() - created_at

        results.append(
            {
                "name": name,
                "client": cfg.get("client", "?"),
                "session_id": cfg.get("session_id", name),
                "alias": cfg.get("alias", name),
                "outer_pid": outer_pid,
                "outer_alive": outer_alive,
                "deliver_pid": deliver_pid,
                "deliver_alive": _pid_alive(deliver_pid),
                "poker_pid": poker_pid,
                "poker_alive": _pid_alive(poker_pid),
                "uptime_s": uptime_s,
                "created_at": cfg.get("created_at"),
            }
        )
    return results


# build_env is defined above in the public API section

# ---------------------------------------------------------------------------
# Outer loop (foreground)
# ---------------------------------------------------------------------------


def _find_binary(name: str) -> str | None:
    """Find a binary in PATH; return its path or None."""
    import shutil

    return shutil.which(name)


def _start_deliver_daemon(
    name: str, client: str, broker_root: Path, child_pid: int | None = None
) -> subprocess.Popen | None:
    """Start deliver daemon in the background, return Popen or None."""
    deliver_script = HERE / "c2c_deliver_inbox.py"
    if not deliver_script.exists():
        return None
    cmd = [
        sys.executable,
        str(deliver_script),
        "--client",
        client,
        "--session-id",
        name,
        "--notify-only",
        "--loop",
        "--broker-root",
        str(broker_root),
    ]
    if child_pid is not None:
        cmd.extend(["--pid", str(child_pid)])
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return proc
    except OSError:
        return None


def _start_poker(name: str, client: str, child_pid: int | None = None) -> subprocess.Popen | None:
    """Start poker in the background for clients that need it."""
    cfg = CLIENT_CONFIGS.get(client, {})
    if not cfg.get("needs_poker"):
        return None
    poker_script = HERE / "c2c_poker.py"
    if not poker_script.exists():
        return None
    if child_pid is not None:
        cmd = [
            sys.executable,
            str(poker_script),
            "--pid",
            str(child_pid),
            "--interval",
            "600",
            "--event",
            cfg.get("poker_event", "heartbeat"),
        ]
    else:
        cmd = [
            sys.executable,
            str(poker_script),
            "--claude-session",
            name,
            "--interval",
            "600",
            "--event",
            cfg.get("poker_event", "heartbeat"),
        ]
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return proc
    except OSError:
        return None


def run_outer_loop(
    name: str,
    client: str,
    extra_args: list[str],
    broker_root: Path,
    binary_override: str | None = None,
    alias_override: str | None = None,
    resume_session_id: str | None = None,
    is_resume: bool = False,
) -> int:
    """Run the outer restart loop for the given instance (blocking)."""
    cfg = CLIENT_CONFIGS[client]
    binary = binary_override or cfg["binary"]
    binary_path = _find_binary(binary)
    if binary_path is None:
        print(f"c2c start: '{binary}' not found in PATH", file=sys.stderr)
        print(f"Install {client} first, then re-run.", file=sys.stderr)
        return 2

    # Auto-reap child processes (deliver daemon, poker) so they don't linger
    # as zombies if they exit before the main client.
    signal.signal(signal.SIGCHLD, signal.SIG_IGN)

    # Preflight: warn once if pidfd_getfd is blocked. Non-fatal.
    ok, err = _preflight_pidfd_check()
    if not ok and err is not None:
        _print_pidfd_banner(err)

    inst_dir = _instance_dir(name)
    inst_dir.mkdir(parents=True, exist_ok=True)

    # Write outer loop PID so c2c stop can find us.
    _write_pidfile(_outer_pid_path(name), os.getpid())

    last_sigint = 0.0
    iteration = 0
    child_proc: subprocess.Popen | None = None
    deliver_proc: subprocess.Popen | None = None
    poker_proc: subprocess.Popen | None = None

    def _stop_sidecar(proc: subprocess.Popen | None) -> None:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=3.0)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()

    def _cleanup_and_exit(code: int) -> int:
        _stop_sidecar(deliver_proc)
        _stop_sidecar(poker_proc)
        _remove_pidfile(_outer_pid_path(name))
        _remove_pidfile(_deliver_pid_path(name))
        _remove_pidfile(_poker_pid_path(name))
        return code

    try:
        env = build_env(name, alias_override)
        # Merge client-specific extra env.
        cfg_extra = CLIENT_CONFIGS.get(client, {}).get("extra_env", {})
        env.update(cfg_extra)
        # Pin CLIENT_PID to outer loop's PID so the broker tracks the durable PID.
        env["C2C_MCP_CLIENT_PID"] = str(os.getpid())

        while True:
            iteration += 1
            # Clean stale fonttools /tmp/.fea*.so files before each iteration.
            try:
                _n = c2c_mcp.cleanup_stale_tmp_fea_so()
                if _n:
                    print(
                        f"[c2c-start/{name}] cleaned {_n} stale /tmp/.fea*.so file(s)",
                        flush=True,
                    )
            except Exception:
                pass

            print(
                f"[c2c-start/{name}] iter {iteration}: launching {client}", flush=True
            )
            started = time.monotonic()
            child_proc = None
            try:
                launch_args = prepare_launch_args(name, client, extra_args, broker_root, alias_override, resume_session_id=resume_session_id, binary_override=binary_override, is_resume=(is_resume or iteration > 1))
                cmd = [binary_path, *launch_args]

                # Save TTY attributes so we can restore them after the client exits.
                # This guards against the client leaving the terminal in a corrupted
                # state (e.g., raw mode from a pager).
                old_tty: Any = None
                try:
                    if os.isatty(sys.stdin.fileno()):
                        old_tty = termios.tcgetattr(sys.stdin.fileno())
                except OSError:
                    pass

                child_proc = subprocess.Popen(cmd, env=env, start_new_session=True)

                # Start deliver daemon and poker on first iteration (or restart if dead).
                if not cfg.get("skip_deliver") and (deliver_proc is None or deliver_proc.poll() is not None):
                    deliver_proc = _start_deliver_daemon(
                        name, cfg["deliver_client"], broker_root, child_proc.pid
                    )
                    if deliver_proc is not None:
                        _write_pidfile(_deliver_pid_path(name), deliver_proc.pid)

                if poker_proc is None or poker_proc.poll() is not None:
                    poker_proc = _start_poker(name, client, child_proc.pid)
                    if poker_proc is not None:
                        _write_pidfile(_poker_pid_path(name), poker_proc.pid)

                exit_code = child_proc.wait()

                # Restore TTY attributes after client exits.
                if old_tty is not None:
                    try:
                        if os.isatty(sys.stdin.fileno()):
                            termios.tcsetattr(sys.stdin.fileno(), termios.TCSANOW, old_tty)
                    except OSError:
                        pass
            except KeyboardInterrupt:
                if child_proc is not None and child_proc.poll() is None:
                    child_proc.terminate()
                    try:
                        child_proc.wait(timeout=2.0)
                    except subprocess.TimeoutExpired:
                        child_proc.kill()
                        child_proc.wait()
                now = time.monotonic()
                if now - last_sigint < DOUBLE_SIGINT_WINDOW_SECONDS:
                    print(f"[c2c-start/{name}] double SIGINT — exiting.", flush=True)
                    return _cleanup_and_exit(130)
                last_sigint = now
                print(
                    f"[c2c-start/{name}] SIGINT received. Send again within "
                    f"{DOUBLE_SIGINT_WINDOW_SECONDS:.1f}s to exit.",
                    flush=True,
                )
                exit_code = 130

            elapsed = time.monotonic() - started
            print(
                f"[c2c-start/{name}] inner exited code={exit_code} after {elapsed:.1f}s",
                flush=True,
            )

            # Child exited — clean up and print resume command.
            resume_cmd = f"c2c start {client} -n {name}"
            if binary_override:
                resume_cmd += f" --bin {binary_override}"
            print(f"\n  {resume_cmd}", flush=True)
            return _cleanup_and_exit(exit_code)
    except Exception as exc:
        print(f"[c2c-start/{name}] fatal error: {exc}", file=sys.stderr, flush=True)
        return _cleanup_and_exit(1)


# ---------------------------------------------------------------------------
# start / stop / restart
# ---------------------------------------------------------------------------


def cmd_start(
    client: str,
    name: str,
    extra_args: list[str],
    broker_root: Path,
    json_out: bool = False,
    binary_override: str | None = None,
    alias_override: str | None = None,
    session_id_override: str | None = None,
) -> int:
    if client not in CLIENT_CONFIGS:
        msg = f"unknown client: {client!r}. Choose from: {', '.join(sorted(CLIENT_CONFIGS))}"
        if json_out:
            print(json.dumps({"ok": False, "error": msg}))
        else:
            print(f"error: {msg}", file=sys.stderr)
        return 1

    # Auto-setup: ensure client is configured before starting
    if not ensure_client_configured(client):
        msg = f"{client} setup failed. Please run 'c2c setup {client}' manually."
        if json_out:
            print(json.dumps({"ok": False, "error": msg}))
        else:
            print(f"error: {msg}", file=sys.stderr)
        return 1

    # Validate --session-id before any side effects.
    if session_id_override is not None:
        try:
            uuid.UUID(session_id_override)
        except ValueError:
            msg = "--session-id must be a valid UUID, e.g. 550e8400-e29b-41d4-a716-446655440000"
            if json_out:
                print(json.dumps({"ok": False, "error": msg}))
            else:
                print(f"error: {msg}", file=sys.stderr)
            return 1

    # Check for duplicate running instance.
    pid = _read_pid(_outer_pid_path(name))
    if _pid_alive(pid):
        msg = f"instance {name!r} is already running (pid {pid}). Use 'c2c stop {name}' first."
        if json_out:
            print(json.dumps({"ok": False, "error": msg, "pid": pid}))
        else:
            print(f"error: {msg}", file=sys.stderr)
        return 1

    # Stale pidfile cleanup.
    _remove_pidfile(_outer_pid_path(name))

    # Resume: if an existing config exists, inherit its saved settings
    # unless explicitly overridden on the command line.
    existing = load_instance_config(name)
    if existing is not None:
        saved_client = existing.get("client", client)
        if saved_client != client:
            msg = (
                f"instance {name!r} was previously a {saved_client} instance. "
                f"Cannot resume as {client}. Use 'c2c stop {name}' first or pass "
                f"a different name."
            )
            if json_out:
                print(json.dumps({"ok": False, "error": msg}))
            else:
                print(f"error: {msg}", file=sys.stderr)
            return 1
        # Inherit saved settings where no explicit CLI override was given.
        if binary_override is None:
            binary_override = existing.get("binary_override")
        if alias_override is None:
            alias_override = existing.get("alias", name)
        if not extra_args:
            extra_args = existing.get("extra_args", [])
        saved_root = existing.get("broker_root")
        if saved_root:
            broker_root = Path(saved_root).resolve()

    # Stable session UUID: generated once on first start, reused on resume
    # so the client can --resume by it. Only used by clients that support
    # session resumption (claude, codex, opencode).
    # CLI --session-id override takes precedence; falls back to saved value.
    resume_session_id = session_id_override or (existing.get("resume_session_id") if existing else None)
    if resume_session_id is None:
        resume_session_id = str(uuid.uuid4())

    # Write instance config.
    cfg: dict[str, Any] = {
        "name": name,
        "client": client,
        "session_id": name,
        "resume_session_id": resume_session_id,
        "alias": alias_override or name,
        "extra_args": extra_args,
        "created_at": existing.get("created_at", time.time()) if existing else time.time(),
        "broker_root": str(broker_root),
        "auto_join_rooms": "swarm-lounge",
    }
    if binary_override:
        cfg["binary_override"] = binary_override
    save_instance_config(name, cfg)

    if json_out:
        print(json.dumps({"ok": True, "name": name, "client": client}))

    return run_outer_loop(
        name, client, extra_args, broker_root,
        binary_override=binary_override,
        alias_override=alias_override,
        resume_session_id=resume_session_id,
        is_resume=existing is not None,
    )


def cmd_stop(name: str, json_out: bool = False) -> int:
    pid = _read_pid(_outer_pid_path(name))
    if not _pid_alive(pid):
        msg = f"instance {name!r} is not running (no live pidfile)."
        if json_out:
            print(json.dumps({"ok": False, "error": msg}))
        else:
            print(msg, file=sys.stderr)
        return 1
    assert pid is not None
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError as exc:
        msg = f"failed to stop {name!r} (pid {pid}): {exc}"
        if json_out:
            print(json.dumps({"ok": False, "error": msg}))
        else:
            print(msg, file=sys.stderr)
        return 1

    # Wait up to 10s for the outer loop to clean up.
    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        if not _pid_alive(pid):
            break
        time.sleep(0.1)

    if json_out:
        print(json.dumps({"ok": True, "name": name, "pid": pid}))
    else:
        alive = _pid_alive(pid)
        status = "still running" if alive else "stopped"
        print(f"c2c stop: {name} {status} (pid {pid})")
    return 0


def cmd_restart(name: str, json_out: bool = False) -> int:
    cfg = load_instance_config(name)
    if cfg is None:
        msg = f"no config found for instance {name!r}"
        if json_out:
            print(json.dumps({"ok": False, "error": msg}))
        else:
            print(msg, file=sys.stderr)
        return 1
    rc = cmd_stop(name, json_out=False)
    if rc != 0:
        # Not running — that's fine, just start fresh.
        pass
    broker_root = Path(cfg.get("broker_root") or c2c_mcp.default_broker_root())
    return cmd_start(
        cfg["client"],
        name,
        cfg.get("extra_args", []),
        broker_root,
        json_out=json_out,
        binary_override=cfg.get("binary_override"),
        alias_override=cfg.get("alias"),
    )


def cmd_instances(json_out: bool = False) -> int:
    instances = list_instances()
    if json_out:
        print(json.dumps(instances, indent=2))
        return 0

    if not instances:
        print("No c2c instances found.")
        return 0

    print(f"{'NAME':<20} {'CLIENT':<10} {'STATUS':<8} {'UPTIME':<12} {'PID'}")
    print("-" * 65)
    for inst in instances:
        status = "ALIVE" if inst["outer_alive"] else "DEAD"
        uptime = ""
        if inst["uptime_s"] is not None:
            u = inst["uptime_s"]
            if u < 60:
                uptime = f"{u:.0f}s"
            elif u < 3600:
                uptime = f"{u / 60:.0f}m"
            else:
                uptime = f"{u / 3600:.1f}h"
        pid = str(inst["outer_pid"] or "?")
        print(f"{inst['name']:<20} {inst['client']:<10} {status:<8} {uptime:<12} {pid}")
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Unified c2c instance launcher",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
subcommands:
  start <client> [-n NAME] [-- EXTRA...]   Launch a managed instance
  stop <NAME>                              Stop a running instance
  restart <NAME>                           Stop and restart an instance
  instances [--json]                       List all known instances
""",
    )
    parser.add_argument(
        "subcommand",
        choices=["start", "stop", "restart", "instances"],
        help="subcommand to run",
    )
    parser.add_argument("args", nargs=argparse.REMAINDER)
    parser.add_argument("--json", action="store_true", help="JSON output")
    parser.add_argument("--broker-root", type=Path, default=None)

    args = parser.parse_args(argv)
    broker_root = args.broker_root or Path(c2c_mcp.default_broker_root())
    json_out = args.json

    if args.subcommand == "instances":
        sub = argparse.ArgumentParser(prog="c2c instances")
        sub.add_argument("--json", action="store_true")
        parsed = sub.parse_args(args.args)
        return cmd_instances(json_out=json_out or parsed.json)

    if args.subcommand == "stop":
        sub = argparse.ArgumentParser(prog="c2c stop")
        sub.add_argument("name")
        sub.add_argument("--json", action="store_true")
        parsed = sub.parse_args(args.args)
        return cmd_stop(parsed.name, json_out=json_out or parsed.json)

    if args.subcommand == "restart":
        sub = argparse.ArgumentParser(prog="c2c restart")
        sub.add_argument("name")
        sub.add_argument("--json", action="store_true")
        parsed = sub.parse_args(args.args)
        return cmd_restart(parsed.name, json_out=json_out or parsed.json)

    # start
    sub = argparse.ArgumentParser(prog="c2c start")
    sub.add_argument("client", choices=list(CLIENT_CONFIGS))
    sub.add_argument("-n", "--name", default=None)
    sub.add_argument("--bin", default=None, help="custom binary path or name to launch")
    sub.add_argument("--alias", default=None, help="custom alias (defaults to instance name)")
    sub.add_argument("--session-id", default=None, help="explicit session UUID (overrides auto-generated)")
    parsed, remainder = sub.parse_known_args(args.args)
    # strip leading '--' separator if present
    if remainder and remainder[0] == "--":
        remainder = remainder[1:]
    name = parsed.name or default_name(parsed.client)
    return cmd_start(parsed.client, name, remainder, broker_root, json_out=json_out, binary_override=parsed.bin, alias_override=parsed.alias, session_id_override=parsed.session_id)


if __name__ == "__main__":
    raise SystemExit(main())
