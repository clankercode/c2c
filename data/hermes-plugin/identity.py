"""Profile-owned session bindings; no process-wide current identity or env writes.

Hermes hooks pass a durable session id. TUI/desktop tools and commands also
carry a task-local route key (gateway.session_context.bound_session_key).
The manager's immutable home owns every binding. Missing or contradictory
ownership fails before any c2c subprocess is invoked.
"""

import hashlib
import os
import threading
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType


class OwnershipError(ValueError):
    pass


def _text(value):
    return value if isinstance(value, str) and value.strip() == value and value else ""


def _bound_key():
    try:
        from gateway.session_context import bound_session_key
        return _text(bound_session_key())
    except ImportError:
        return ""


@dataclass(frozen=True)
class Binding:
    profile_home: str
    session_id: str
    session_key: str
    broker_session_id: str
    broker_root: str
    alias: str
    cwd: str
    surface: str


class Session:
    """One immutable identity plus its delivery/lifecycle state."""

    def __init__(self, binding, cli, ctx):
        from .delivery import Delivery
        self.binding = binding
        self.cli = cli
        self.ctx = ctx
        self.active = True
        self.delivery = Delivery(self)
        self.watcher = None

    def owned(self):
        """A watcher cannot borrow a replaced profile/CLI owner."""
        try:
            manager = self.ctx._manager
            if str(Path(manager.home_path).resolve()) != self.binding.profile_home:
                return False
            cli = manager._cli_ref
            if cli is not None:
                return (self.binding.surface == "cli"
                        and getattr(cli, "session_id", None) == self.binding.session_id)
            return self.binding.surface in ("tui", "desktop")
        except Exception:
            return False


class SessionRegistry:
    """Owned by exactly one PluginContext, never shared across profiles."""

    def __init__(self, ctx):
        self.ctx = ctx
        manager = getattr(ctx, "_manager", None)
        home = getattr(manager, "home_path", None)
        self.home = str(Path(home).resolve()) if home else ""
        snapshot = dict(os.environ)
        if self.home:
            snapshot["HERMES_HOME"] = self.home
        self.env = MappingProxyType(snapshot)
        self._sessions = {}
        self._pending = set()
        self._lock = threading.Lock()

    def _coordinates(self, *, session_id=None, session_key=None, profile_home=None, **kwargs):
        if not self.home:
            raise OwnershipError("Hermes manager profile home is required")
        manager_home = getattr(getattr(self.ctx, "_manager", None), "home_path", None)
        if not manager_home or str(Path(manager_home).resolve()) != self.home:
            raise OwnershipError("Hermes profile owner changed")
        if profile_home is not None and str(Path(profile_home).resolve()) != self.home:
            raise OwnershipError("invocation belongs to a different profile")
        sid, key, bound = _text(session_id), _text(session_key), _bound_key()
        if session_id is not None and not sid or session_key is not None and not key:
            raise OwnershipError("invalid session identity")
        if key and bound and key != bound:
            raise OwnershipError("invocation contradicts Hermes session key")
        key = key or bound
        cli = getattr(self.ctx._manager, "_cli_ref", None)
        if cli is not None:
            cli_sid = _text(getattr(cli, "session_id", None))
            if not cli_sid or sid and sid != cli_sid or key and key != cli_sid:
                raise OwnershipError("invocation does not own the classic CLI")
            sid, key = cli_sid, cli_sid
        if not sid and not key:
            raise OwnershipError("explicit invocation session identity is required")
        return sid, key

    def resolve(self, **invocation):
        sid, key = self._coordinates(**invocation)
        with self._lock:
            matches = [s for s in self._sessions.values()
                       if (not sid or s.binding.session_id == sid)
                       and (not key or s.binding.session_key == key) and s.active and s.owned()]
        if len(matches) != 1:
            raise OwnershipError("unknown, ended, or ambiguous Hermes session")
        return matches[0]

    def start(self, **invocation):
        from .c2c_cli import C2cCli
        sid, key = self._coordinates(**invocation)
        if not sid or not key:
            raise OwnershipError("session start requires a durable id and owned route key")
        surface = self.ctx.session_surface()
        if surface not in ("cli", "tui", "desktop"):
            # No automatic messaging-gateway enrollment or wake.
            raise OwnershipError("unsupported automatic delivery surface")
        cwd = self.ctx.session_cwd()
        if not isinstance(cwd, str) or not os.path.isabs(cwd) or not os.path.isdir(cwd):
            raise OwnershipError("session working directory is required")
        slot = (sid, key)
        with self._lock:
            existing = self._sessions.get(slot)
            if existing:
                if not existing.active or existing.binding.cwd != os.path.realpath(cwd):
                    raise OwnershipError("session binding cannot be replaced")
                return existing
            if slot in self._pending:
                raise OwnershipError("session registration is already in progress")
            self._pending.add(slot)
        try:
            # Length-framed profile+session+route avoids same-ID profile collisions
            # and c2c name truncation/sanitization collisions.
            frame = "".join(f"{len(v)}:{v}" for v in (self.home, sid, key))
            broker_sid = "hermes-" + hashlib.sha256(frame.encode()).hexdigest()[:32]
            env = dict(self.env)
            env.update(C2C_MCP_SESSION_ID=broker_sid, C2C_MCP_CLIENT_TYPE="hermes")
            alias = env.get("C2C_MCP_AUTO_REGISTER_ALIAS")
            if not alias:
                env["C2C_MCP_AUTO_REGISTER_ALIAS"] = broker_sid
                env["C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN"] = "1"
            cli = C2cCli(env=env, cwd=cwd)
            root = cli.broker_root()
            if not root or not os.path.isabs(root):
                raise OwnershipError("could not resolve session broker")
            root = os.path.realpath(root)
            env["C2C_MCP_BROKER_ROOT"] = root
            cli = C2cCli(env=env, cwd=cwd)
            try:
                who = cli.whoami()
            except Exception:
                who = None
            if not isinstance(who, dict) or who.get("error") or not who.get("alias"):
                who = cli.register()
            if (not isinstance(who, dict) or who.get("error")
                    or who.get("session_id") != broker_sid or not _text(who.get("alias"))):
                raise OwnershipError("c2c registration did not confirm exact session ownership")
            binding = Binding(self.home, sid, key, broker_sid, root, who["alias"],
                              os.path.realpath(cwd), surface)
            session = Session(binding, cli, self.ctx)
            with self._lock:
                self._sessions[slot] = session
            # Room membership belongs to this immutable binding too.
            for room in env.get("C2C_MCP_AUTO_JOIN_ROOMS", "swarm-lounge").split(","):
                if room.strip():
                    try:
                        cli.rooms_join(room.strip())
                    except Exception:
                        pass
            return session
        finally:
            with self._lock:
                self._pending.discard(slot)

    def end(self, **invocation):
        session = self.resolve(**invocation)
        session.delivery.close()
        if session.watcher:
            session.watcher.stop()

    def close(self):
        """Plugin unload invalidates all old callbacks and watcher bindings."""
        with self._lock:
            sessions = list(self._sessions.values())
        for session in sessions:
            session.delivery.close()
            if session.watcher:
                session.watcher.stop()

    def command(self, fn):
        """Resolve host kwargs/context before running a slash command."""
        def invoke(args_str, **kwargs):
            try:
                session = self.resolve(**kwargs)
                return fn(args_str, session)
            except Exception:
                return '{"error": "c2c invocation refused or failed"}'
        return invoke

    def tool(self, fn):
        """Tool parameters never supply routing identity; host context does."""
        def invoke(params, **kwargs):
            try:
                session = self.resolve(**kwargs)
                return fn(params, session)
            except Exception:
                return '{"error": "c2c invocation refused or failed"}'
        return invoke
