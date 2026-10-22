"""Best-effort native presentation, independent of model input and broker ACK.

Only local CLI/TUI sinks are used. No post_message, peer sends, model-history
writes, role changes, or monkey patches. Native events are presentation only.
"""

import asyncio
import sys
import threading
from collections import deque
from concurrent.futures import Future, TimeoutError
from contextlib import contextmanager
from dataclasses import replace
from pathlib import Path

from .message_style import inbound_message, tool_messages
from .render_terminal import render, supports_ansi


@contextmanager
def _profile_scope(home):
    try:
        from hermes_constants import set_hermes_home_override, reset_hermes_home_override
    except ImportError:
        yield
        return
    token = set_hermes_home_override(home)
    try:
        yield
    finally:
        reset_hermes_home_override(token)


class NativeDisplay:
    def __init__(self, ctx, registry):
        self.ctx, self.registry = ctx, registry
        self._lock = threading.Lock()
        self._seen = deque(maxlen=256)
        self._closed = False

    def close(self):
        with self._lock:
            self._closed = True

    def format(self, message, *, ansi=False):
        # Watchers have no turn-local home. Bind only this immutable profile
        # while applying Hermes's existing display policy, including commands.
        with _profile_scope(self.registry.home):
            try:
                from agent.redact import redact_sensitive_text
            except ImportError:
                redact_sensitive_text = lambda text: text
            body = redact_sensitive_text(message.body)
            metadata = tuple((k, redact_sensitive_text(v)) for k, v in message.metadata)
            if body != message.body:
                metadata += (('display', 'secrets redacted by host policy'),)
            message = replace(message, sender=redact_sensitive_text(message.sender),
                              recipient=redact_sensitive_text(message.recipient),
                              body=body, metadata=metadata)
        return render(message, ansi=ansi)

    def _active(self, sid, key):
        with self._lock:
            if self._closed:
                return False
        if str(Path(self.ctx._manager.home_path).resolve()) != self.registry.home:
            return False
        with self.registry._lock:
            return not (self.registry._closed or (sid, key) in self.registry._ended)

    def _gateway_show(self, message, sid, key):
        """None means an older, in-process host; False never falls back to one.

        Current CLI and Ink sessions live in SessionAuthority, not the legacy
        tui_gateway registry. Only the existing profile/route may publish a
        display event. No attach, restore, admission, or conversation mutation.
        """
        ref = getattr(sys.modules.get('gateway.run'), '_gateway_runner_ref', None)
        runner = ref() if callable(ref) else None
        if runner is None:
            return None
        loop = getattr(runner, '_gateway_loop', None)
        if (not sid or not key or not getattr(runner, '_running', False)
                or getattr(runner, '_draining', False) or loop is None
                or loop.is_closed() or not loop.is_running()):
            return False

        def publish():
            from gateway.session_authorities import authority_for_home
            from gateway.session_contract import SessionRef
            from gateway.config import Platform

            if not self._active(sid, key) or getattr(runner, '_draining', False):
                return False
            authority = authority_for_home(runner, self.registry.home)
            if (authority is None or getattr(authority, 'retiring', False)
                    or getattr(authority, 'retired', False)
                    or str(Path(authority.profile_id).resolve()) != self.registry.home):
                return False
            # A route shared by multiple live owners is ambiguous even when a
            # supplied id happens to select one. Superseded history is read-only.
            matches = [(owner, live) for owner, live in authority.sessions.items()
                       if live.route == key and not live.superseded]
            if len(matches) != 1:
                return False
            owner, live = matches[0]
            if live.source is None or live.source.platform != Platform.LOCAL:
                return False
            target = authority.physical_target(SessionRef(authority.profile_id, owner))
            if sid not in (owner, target):
                return False
            row = authority.db.get_session(target)
            if (not row or row.get('ended_at') is not None
                    or owner in authority.pending_closes):
                return False
            with live.event_stream.lock:
                if (authority.sessions.get(owner) is not live or live.superseded
                        or not self._active(sid, key)):
                    return False
                # This is the current host's common display-only text sink:
                # Ink's event switch, GatewayAgent._on_review_summary, and the
                # idle CLI's queue_admitted_turn all print it, without adding
                # model history or a turn. agent.print is ignored by Ink;
                # notification.show is discarded by the idle CLI. The event
                # name adds no visible review label; the card identifies c2c.
                # Both consumers strip outer whitespace. A closing label keeps
                # every literal body line, including trailing spaces/LFs, intact.
                text = self.format(message) + '\nEnd of literal body.'
                return bool(live.event_stream.publish(owner, {'text': text},
                            event_type='review.summary', execution={}))

        try:
            current_loop = asyncio.get_running_loop()
        except RuntimeError:
            current_loop = None
        if current_loop is loop:
            return publish()
        # A watcher/tool worker needs the gateway's owner loop.
        outcome = Future()

        def on_loop():
            if not outcome.set_running_or_notify_cancel():
                return
            try:
                outcome.set_result(publish())
            except Exception:
                outcome.set_result(False)

        handle = loop.call_soon_threadsafe(on_loop)
        try:
            return outcome.result(timeout=2)
        except TimeoutError:
            # A late callback must not display into a session after this handoff
            # timed out. Work already executing still checks ownership itself.
            outcome.cancel()
            handle.cancel()
            return False

    def show(self, message, *, binding=None, session_id='', session_key=''):
        """Return whether a native sink was available; this is never delivery evidence."""
        try:
            surface = binding.surface if binding else self.ctx.session_surface()
            if surface not in ('cli', 'tui'):
                return False  # Messaging platforms retain their own entity/transport adapters.
            manager = self.ctx._manager
            if str(Path(manager.home_path).resolve()) != self.registry.home:
                return False
            if binding is None:
                from .identity import _bound_home
                home = _bound_home()
                if home is not None and str(Path(home).resolve()) != self.registry.home:
                    return False
            cli = getattr(manager, '_cli_ref', None)
            sid = binding.session_id if binding else session_id
            key = binding.session_key if binding else session_key
            if binding and str(Path(manager.home_path).resolve()) != binding.profile_home:
                return False
            if binding and ((session_id and session_id != sid) or (session_key and session_key != key)):
                return False
            if cli is not None:
                if key and key != sid:
                    return False
                key = sid
            if not sid or not self._active(sid, key):
                return False
            if cli is not None:
                if surface != 'cli' or getattr(cli, 'session_id', None) != sid:
                    return False
            else:
                if not key:
                    return False
                if binding is None:
                    from .identity import _bound_key
                    bound = _bound_key()
                    if bound and bound != key:
                        return False
            current = self._gateway_show(message, sid, key)
            if current is not None:
                return current  # A gateway never falls through to terminal stdout.
            if cli is not None:
                text = self.format(message, ansi=supports_ansi())
                # Use the host's prompt_toolkit-aware printer without importing
                # cli.py (importing it can initialize a second application).
                printer = getattr(sys.modules.get('cli'), '_cprint', None)
                if callable(printer):
                    printer(text)
                else:
                    print(text)
                return True
            if surface != 'tui':
                return False
            # Version-isolated host adapter: never import/initialize a gateway,
            # guess a latest session, or print into its JSON-RPC stdout.
            host = sys.modules.get('tui_gateway.server')
            if host is None:
                main = sys.modules.get('__main__')
                if getattr(getattr(main, '__spec__', None), 'name', None) == 'tui_gateway.server':
                    host = main
            if host is None:
                return False
            def profile_home(session):
                home = session.get('profile_home')
                # Hermes uses None for its launch profile. Only the host's
                # process-owned launch home can resolve that sentinel.
                if home is None:
                    home = host._launch_home()
                return str(Path(home).resolve())
            with host._sessions_lock:
                matches = [(ui_sid, session) for ui_sid, session in host._sessions.items()
                           if session.get('session_key') == key
                           and profile_home(session) == self.registry.home]
                if len(matches) != 1:
                    return False
                ui_sid, session = matches[0]
                if session.get('_closing') or session.get('_finalized'):
                    return False
                agent_sid = getattr(session.get('agent'), 'session_id', None)
                if not agent_sid or sid != agent_sid:
                    return False
                if not self._active(sid, key):
                    return False
                text = self.format(message)
                # The old in-process TUI also consumes notification.show.
                return bool(host._emit('notification.show', ui_sid, {
                    'text': text, 'detail': text, 'level': 'info', 'kind': 'ttl',
                    'ttl_ms': 6000, 'key': 'c2c.native',
                }))
        except Exception:
            # Do not log exceptions: they can contain bodies or private targets.
            return False

    def inbound(self, batch, binding):
        for msg in batch:
            self.show(inbound_message(msg, binding.alias), binding=binding)

    def post_tool_call(self, tool_name, args, result, session_id='', tool_call_id='', status=None, **kwargs):
        """Observe completions only. Return None so Hermes retains the exact tool result."""
        try:
            if self.ctx.session_surface() not in ('cli', 'tui'):
                return
            from .identity import _bound_key
            key = _bound_key()
            sender = 'unknown'
            try:
                session = self.registry.resolve(session_id=session_id,
                                                **({'session_key': key} if key else {}))
                sender = session.binding.alias
            except Exception:
                pass  # MCP identities can exist without a native-plugin registration.
            messages = tool_messages(tool_name, args, result, status=status, sender=sender,
                                     self_alias=sender if tool_name.startswith('c2c_') else 'unknown')
            if not messages or not session_id or not tool_call_id:
                return
            correlation = (session_id, key, tool_call_id)
            with self._lock:
                if self._closed or correlation in self._seen:
                    return
                self._seen.append(correlation)
            for message in messages:
                self.show(message, session_id=session_id, session_key=key)
        except Exception:
            pass
