"""C2cCli — a thin wrapper that shells out to the `c2c` binary with --json.

All c2c interactions go through this class. It resolves the binary path
(from C2C_BIN env or `shutil.which`), runs subcommands with `--json`, and
parses the JSON output. If the binary is missing, methods return an
error dict instead of crashing.

The plugin never reimplements broker logic — it always shells to `c2c`,
which handles broker-root resolution, locking, atomic writes, etc.
"""

import json
import os
import shutil
import subprocess
import logging

logger = logging.getLogger("c2c.cli")

# Timeout for most c2c subcommands (seconds). `monitor` / `wait-inbox`
# are long-running and not used through this path.
DEFAULT_TIMEOUT = 30


class C2cError(Exception):
    """Raised when a c2c invocation exits non-zero."""

    def __init__(self, message, code, stderr):
        super().__init__(message)
        self.code = code
        self.stderr = stderr


class C2cCli:
    """Wraps the `c2c` binary, always requesting JSON output."""

    def __init__(self, binary=None):
        self._binary = binary or self._resolve_binary()
        # Ensure C2C_MCP_CLIENT_TYPE is pinned so c2c doesn't misidentify us.
        if not os.environ.get("C2C_MCP_CLIENT_TYPE"):
            os.environ["C2C_MCP_CLIENT_TYPE"] = "hermes"

    @staticmethod
    def _resolve_binary():
        env_bin = os.environ.get("C2C_BIN")
        if env_bin and os.path.isfile(env_bin) and os.access(env_bin, os.X_OK):
            return env_bin
        return shutil.which("c2c")

    @property
    def available(self):
        """True if the c2c binary was found."""
        return self._binary is not None

    def _run(self, args, timeout=DEFAULT_TIMEOUT):
        """Run `c2c <args...> --json` and return parsed JSON.

        If the binary is missing, returns an error dict.
        If the command exits non-zero, raises C2cError.
        If JSON parsing fails, returns the raw stdout as a string.
        """
        if not self._binary:
            return {"error": "c2c binary not found on PATH", "hint": "Set C2C_BIN or install c2c"}

        # Insert --json BEFORE any '--' separator. If it goes after '--',
        # c2c treats it as a positional arg and rejects with 'too many arguments'.
        if "--" in args:
            idx = args.index("--")
            full_args = [self._binary] + args[:idx] + ["--json"] + args[idx:]
        else:
            full_args = [self._binary] + args + ["--json"]
        try:
            proc = subprocess.run(
                full_args,
                capture_output=True,
                text=True,
                timeout=timeout,
                env=os.environ.copy(),
            )
        except subprocess.TimeoutExpired:
            return {"error": f"c2c {' '.join(args)} timed out after {timeout}s"}
        except FileNotFoundError:
            return {"error": "c2c binary not found", "hint": "It was on PATH at init but is gone now"}

        if proc.returncode != 0:
            raise C2cError(
                f"c2c {' '.join(args)} exited {proc.returncode}",
                proc.returncode,
                proc.stderr.strip(),
            )

        stdout = proc.stdout.strip()
        if not stdout:
            return {}
        try:
            return json.loads(stdout)
        except json.JSONDecodeError:
            # Some commands emit non-JSON informational text; pass it through.
            return {"raw": stdout}

    # -- Identity -----------------------------------------------------------

    def register(self, alias=None):
        """Register a c2c alias.

        With no `alias`, c2c takes the name from C2C_MCP_AUTO_REGISTER_ALIAS —
        and that is the path identity.py uses on purpose. An explicit
        `--alias hermes-<hex>` counts as USER-supplied and is refused by the
        alias blocklist (`hermes-` is a reserved client prefix); the env-var
        path paired with C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN=1 is the
        auto-generated path, which is what a client-prefixed alias is.
        """
        args = ["register"]
        if alias:
            args += ["--alias", alias]
        return self._run(args)

    def whoami(self):
        """Return current c2c identity."""
        return self._run(["whoami"])

    def broker_root(self):
        """Resolve the broker root the way `c2c` itself resolves it.

        `c2c health --json` is the only JSON surface that reports
        `broker_root`. Never reimplement the resolution (repo fingerprint,
        C2C_STATE_HOME, the deliberately-ignored XDG_STATE_HOME) and never
        guess it by scanning ~/.c2c/repos/* — that picks an arbitrary,
        unrelated repository's broker.
        """
        try:
            result = self.health()
        except Exception as e:
            logger.debug("[c2c] broker_root probe failed: %s", e)
            return None
        if isinstance(result, dict):
            root = result.get("broker_root")
            if isinstance(root, str) and root:
                return root
        return None

    def session_id(self):
        """Resolve this session's c2c session id via `c2c whoami --json`."""
        try:
            who = self.whoami()
        except Exception as e:
            logger.debug("[c2c] session_id probe failed: %s", e)
            return None
        if isinstance(who, dict):
            sid = who.get("session_id")
            if isinstance(sid, str) and sid:
                return sid
        return None

    # -- Messaging ----------------------------------------------------------

    def send(self, target, body, ephemeral=False, deferrable=False, urgent=False,
             blocking=False, session=None):
        """Send a direct message to a peer alias.

        EVERY option flag must precede the `--` separator. `c2c send` collects
        its positionals with cmdliner's `Arg.pos_all` and joins everything
        after the recipient into the message body, so a flag placed after `--`
        is silently delivered as literal text with the flag itself unset —
        no error, wrong message.

        With `--session`, `c2c send` treats ALL positionals as the body (there
        is no recipient alias to resolve), so `target` is not passed.
        """
        args = ["send"]
        if ephemeral:
            args.append("--ephemeral")
        if deferrable:
            args.append("--deferrable")
        if urgent:
            args.append("--urgent")
        if blocking:
            args.append("--blocking")
        if session:
            args.append(f"--session={session}")
            args += ["--", body]
        else:
            args += ["--", target, body]
        return self._run(args)

    def send_all(self, body):
        """Broadcast a message to all peers."""
        return self._run(["send-all", "--", body])

    def list(self):
        """List all known peers."""
        return self._run(["list"])

    def poll_inbox(self, alias=None, session_id=None, wait=False, timeout=None):
        """Drain the inbox, returning messages as a list."""
        args = ["poll-inbox"]
        if alias:
            args.append(f"--alias={alias}")
        if session_id:
            args.append(f"--session-id={session_id}")
        if wait:
            args.append("--wait")
        if timeout:
            args.append(f"--timeout={timeout}")
        return self._run(args, timeout=DEFAULT_TIMEOUT * 4 if wait else DEFAULT_TIMEOUT)

    def peek_inbox(self):
        """Peek at inbox without draining."""
        return self._run(["peek-inbox"])

    def history(self):
        """Get message history."""
        return self._run(["history"])

    # -- Rooms --------------------------------------------------------------

    def rooms_join(self, room):
        return self._run(["rooms", "join", "--", room])

    def rooms_send(self, room, body):
        return self._run(["rooms", "send", "--", room, body])

    def rooms_list(self):
        return self._run(["rooms", "list"])

    def rooms_my_rooms(self):
        return self._run(["rooms", "my-rooms"])

    def rooms_leave(self, room):
        return self._run(["rooms", "leave", "--", room])

    def rooms_knock(self, room):
        return self._run(["rooms", "knock", "--", room])

    def rooms_knocks(self, room):
        return self._run(["rooms", "knocks", "--", room])

    def rooms_approve_knock(self, room, alias):
        return self._run(["rooms", "approve-knock", "--", room, alias])

    def rooms_deny_knock(self, room, alias):
        return self._run(["rooms", "deny-knock", "--", room, alias])

    def rooms_history(self, room, limit=None):
        # `--limit` before `--`: `c2c rooms history` takes exactly one
        # positional (ROOM), so a flag after the separator parses as a second
        # positional and the whole call exits 124 (command line parse error).
        args = ["rooms", "history"]
        if limit:
            args.append(f"--limit={limit}")
        args += ["--", room]
        return self._run(args)

    def rooms_members(self, room):
        return self._run(["rooms", "members", "--", room])

    def rooms_invite(self, room, alias):
        return self._run(["rooms", "invite", "--", room, alias])

    def rooms_visibility(self, room):
        return self._run(["rooms", "visibility", "--", room])

    # -- Health / Status ----------------------------------------------------

    def health(self):
        return self._run(["health"])

    def status(self):
        return self._run(["status"])