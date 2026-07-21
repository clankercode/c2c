#!/usr/bin/env python3
"""Pure-Python PTY master-fd injector. ACTIVE.

This is the production PTY injection backend used by c2c_poker,
claude_send_msg, c2c_restart_me, and the deprecated wake daemons.
It is NOT deprecated — it is the active mechanism for PTY-based
input injection when broker-native delivery paths (PostToolUse hook,
promptAsync) are unavailable.

Mechanism: pidfd_open + pidfd_getfd to duplicate the PTY master fd,
then write bracketed-paste + Enter to deliver synthetic input.

Replacement for the external ``pty_inject`` binary that used to live at
``/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject``.
That helper reached into a terminal emulator (ghostty, kitty, ...) via
``pidfd_open`` + ``pidfd_getfd`` to duplicate the PTY master fd and
wrote bracketed-paste + Enter to deliver synthetic input. This module
does the same thing without shelling out.

Mechanism
---------
1. ``os.pidfd_open(terminal_pid)`` — pidfd for the terminal emulator.
2. Scan ``/proc/<terminal_pid>/fd/*`` for a symlink pointing at
   ``/dev/ptmx`` whose matching ``/proc/<terminal_pid>/fdinfo/<fd>`` has
   a ``tty-index:`` line equal to the target pts number. That's the
   master side of ``/dev/pts/<N>``.
3. ``pidfd_getfd(pidfd, remote_fd)`` — duplicate that master fd into
   our process via the raw syscall (Python has no stdlib wrapper yet).
4. Write ``\\x1b[200~MSG\\x1b[201~`` (bracketed paste) to the dup'd fd.
5. Sleep ``submit_delay`` seconds (default 0.2s).
6. Write ``\\r`` as a second, separate write. (Ink/TUI apps process the
   paste before the Enter — sending them together races the paste.)

Permissions
-----------
``pidfd_getfd`` requires ``CAP_SYS_PTRACE`` on the caller when
``kernel.yama.ptrace_scope >= 1`` (the default on most distros). The
old binary carried ``cap_sys_ptrace=ep`` as a file capability. To grant
the same to Python, run once per interpreter install::

    sudo setcap cap_sys_ptrace=ep /usr/bin/python3.13

(pick the real interpreter you run c2c under; if you use a venv, setcap
the symlink target). Without that, this module falls back to raising
``PermissionError`` — the caller is expected to surface that.

Thread-safety / reentrancy
--------------------------
Stateless. Each call opens a fresh pidfd, does the dup, writes, and
closes everything. Safe to call concurrently from different threads.
"""
from __future__ import annotations

import ctypes
import errno
import os
import platform
import time
from pathlib import Path

__all__ = ["inject", "PtyInjectError", "DEFAULT_SUBMIT_DELAY"]

DEFAULT_SUBMIT_DELAY = 0.2

# x86_64 Linux syscall number for pidfd_getfd. Other arches listed for
# completeness — kept simple because this tool only targets Linux boxes
# where c2c runs today.
_PIDFD_GETFD_SYSCALL = {
    "x86_64": 438,
    "aarch64": 438,
    "armv7l": 438,
    "i686": 438,
    "riscv64": 438,
}.get(platform.machine(), 438)


class PtyInjectError(RuntimeError):
    """Raised on injection-specific failures (no master fd found, etc.)."""


def _libc() -> ctypes.CDLL:
    return ctypes.CDLL(None, use_errno=True)


def _pidfd_getfd(pidfd: int, target_fd: int) -> int:
    """Wrap the raw ``pidfd_getfd`` syscall.

    Returns a new fd in the caller's process duplicating ``target_fd`` in
    the process ``pidfd`` refers to. Raises ``OSError`` with errno set on
    failure — notably ``EPERM`` when CAP_SYS_PTRACE is missing.
    """
    libc = _libc()
    libc.syscall.restype = ctypes.c_long
    # long syscall(long number, ...);  pidfd_getfd(pidfd, targetfd, flags)
    rv = libc.syscall(
        ctypes.c_long(_PIDFD_GETFD_SYSCALL),
        ctypes.c_int(pidfd),
        ctypes.c_int(target_fd),
        ctypes.c_uint(0),
    )
    if rv < 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err), f"pidfd_getfd(pidfd={pidfd}, fd={target_fd})")
    return int(rv)


def _find_master_fd(terminal_pid: int, pts_num: int) -> int:
    """Locate the remote fd on terminal_pid that is the master for /dev/pts/<pts_num>.

    Walks ``/proc/<terminal_pid>/fd/*`` for entries symlinking to
    ``/dev/ptmx`` and reads the sibling ``/proc/<terminal_pid>/fdinfo/<fd>``
    for the ``tty-index:`` line. Returns the matching integer fd number.
    Raises ``PtyInjectError`` when no match.
    """
    fd_dir = Path(f"/proc/{terminal_pid}/fd")
    fdinfo_dir = Path(f"/proc/{terminal_pid}/fdinfo")
    if not fd_dir.is_dir():
        raise PtyInjectError(f"no /proc/{terminal_pid}/fd — process gone?")

    try:
        entries = os.listdir(fd_dir)
    except PermissionError as exc:
        raise PtyInjectError(
            f"cannot list /proc/{terminal_pid}/fd — insufficient permissions ({exc})"
        ) from exc

    for entry in entries:
        try:
            target = os.readlink(fd_dir / entry)
        except OSError:
            continue
        if target != "/dev/ptmx":
            continue
        fdinfo_path = fdinfo_dir / entry
        try:
            with fdinfo_path.open("r") as fh:
                for line in fh:
                    if line.startswith("tty-index:"):
                        idx = line.split(":", 1)[1].strip()
                        try:
                            if int(idx) == pts_num:
                                return int(entry)
                        except ValueError:
                            pass
                        break
        except OSError:
            continue

    raise PtyInjectError(
        f"no PTY master fd found in pid {terminal_pid} for /dev/pts/{pts_num}; "
        "check that the target terminal actually owns that pts and that you have "
        "permission to read its /proc entries"
    )


def _sanitize(payload: bytes) -> bytes:
    """Strip embedded bracketed-paste markers from payload to avoid framing corruption."""
    return payload.replace(b"\x1b[200~", b"").replace(b"\x1b[201~", b"")


def _to_bytes(payload: str | bytes) -> bytes:
    if isinstance(payload, bytes):
        return payload
    return payload.encode("utf-8", errors="replace")


def inject(
    terminal_pid: int,
    pts_num: int | str,
    payload: str | bytes,
    *,
    submit_delay: float | None = None,
    bracketed_paste: bool = True,
    submit_enter: bool = True,
) -> None:
    """Inject ``payload`` into the TTY at ``/dev/pts/<pts_num>`` owned by ``terminal_pid``.

    Args:
        terminal_pid: PID of the process holding the PTY master (e.g.
            ghostty, kitty). Used with pidfd_open + pidfd_getfd.
        pts_num: The pts slave number the target app reads from. May be
            a string like ``"12"`` or ``"/dev/pts/12"`` — trailing path
            components are stripped.
        payload: Text to paste. UTF-8 encoded. Bracketed-paste markers
            inside the payload are stripped to prevent framing corruption.
        submit_delay: Seconds to sleep between the paste write and the
            Enter write. Defaults to :data:`DEFAULT_SUBMIT_DELAY` (0.2s).
            Pass ``1.5`` for Kimi (see :mod:`c2c_kimi_wake_daemon`).
        bracketed_paste: When True (default), wrap the payload in
            ``\\x1b[200~ ... \\x1b[201~``. Set False for raw byte
            sequences (e.g. when sending only a keycode).
        submit_enter: When True (default), send ``\\r`` after the paste
            write + submit_delay. Set False if the caller needs to
            stage text without submitting it.

    Raises:
        PtyInjectError: The target terminal has no master fd for that pts.
        PermissionError: ``pidfd_getfd`` returned EPERM — you likely need
            ``setcap cap_sys_ptrace=ep`` on the Python interpreter.
        ProcessLookupError: terminal_pid is gone.
    """
    # Accept "12", 12, or "/dev/pts/12"
    if isinstance(pts_num, str):
        pts_num = pts_num.rsplit("/", 1)[-1]
        pts_num = int(pts_num)
    else:
        pts_num = int(pts_num)

    delay = DEFAULT_SUBMIT_DELAY if submit_delay is None else float(submit_delay)

    body = _sanitize(_to_bytes(payload))
    if bracketed_paste:
        first = b"\x1b[200~" + body + b"\x1b[201~"
    else:
        first = body

    # Step 1: pidfd for the terminal emulator.
    try:
        pidfd = os.pidfd_open(int(terminal_pid))
    except ProcessLookupError:
        raise
    except PermissionError:
        raise
    except OSError as exc:
        # pidfd_open returning ESRCH shows up as OSError on some libcs
        if exc.errno == errno.ESRCH:
            raise ProcessLookupError(exc.errno, os.strerror(exc.errno)) from exc
        raise

    try:
        # Step 2 + 3: find the remote master fd, pidfd_getfd it.
        remote_fd = _find_master_fd(int(terminal_pid), pts_num)
        try:
            local_fd = _pidfd_getfd(pidfd, remote_fd)
        except OSError as exc:
            if exc.errno == errno.EPERM:
                raise PermissionError(
                    exc.errno,
                    "pidfd_getfd returned EPERM — the Python interpreter likely lacks "
                    "CAP_SYS_PTRACE. Run e.g. `sudo setcap cap_sys_ptrace=ep "
                    f"{os.readlink('/proc/self/exe')}` (or raise "
                    "kernel.yama.ptrace_scope restrictions).",
                ) from exc
            raise

        try:
            # Step 4: paste write.
            _write_all(local_fd, first)
            if submit_enter:
                # Step 5: delay.
                if delay > 0:
                    time.sleep(delay)
                # Step 6: Enter write (separate, so Ink commits paste first).
                _write_all(local_fd, b"\r")
        finally:
            os.close(local_fd)
    finally:
        os.close(pidfd)


def _write_all(fd: int, data: bytes) -> None:
    """os.write loop that retries short writes / EINTR."""
    view = memoryview(data)
    while view:
        try:
            n = os.write(fd, view)
        except InterruptedError:
            continue
        if n <= 0:
            raise OSError(f"short write to fd {fd}: wrote {n}")
        view = view[n:]


def main(argv: list[str] | None = None) -> int:
    """Binary-compatible drop-in for the old pty_inject helper.

    Usage: c2c_pty_inject.py <terminal_pid> <pts_num> <message> [submit_delay]

    Mirrors the original ``pty_inject`` C binary so scripts that shell
    out still work during the transition. Prefer calling :func:`inject`
    directly from Python.
    """
    import sys
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) < 3 or len(args) > 4:
        sys.stderr.write(
            "usage: c2c_pty_inject.py <terminal_pid> <pts_num> <message> [submit_delay_seconds]\n"
        )
        return 2
    terminal_pid = int(args[0])
    pts_num = args[1]
    message = args[2]
    submit_delay = float(args[3]) if len(args) == 4 else None
    try:
        inject(terminal_pid, pts_num, message, submit_delay=submit_delay)
    except (PtyInjectError, PermissionError, ProcessLookupError, OSError) as exc:
        sys.stderr.write(f"c2c_pty_inject: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
