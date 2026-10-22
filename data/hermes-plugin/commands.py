"""c2c slash commands — human-accessible shortcuts.

These let the human at the keyboard interact with c2c without
waiting for the LLM to decide to call a tool. Each command shells
to the c2c binary and prints the result.
"""

import json
import logging

from .message_style import inbox_messages, send_message
from .render_terminal import supports_ansi

logger = logging.getLogger("c2c.commands")


def register_all_commands(ctx, registry):
    """Register all /c2c-* slash commands."""


    def _fmt(data):
        if isinstance(data, str):
            return data
        return json.dumps(data, indent=2, default=str)

    # -- /c2c-send ---------------------------------------------------------
    @registry.command
    def handle_c2c_send(args_str, session):
        """Usage: /c2c-send <alias> <message>"""
        parts = args_str.split(None, 1) if args_str else []
        if len(parts) < 2:
            return "Usage: /c2c-send <alias> <message>"
        target, body = parts[0], parts[1]
        try:
            result = session.cli.send(target, body)
        except Exception:
            result = {"error": "c2c command failed"}
        return ctx._c2c_display.format(send_message({'to': target, 'body': body}, result,
                                                   sender=session.binding.alias),
                                       ansi=session.binding.surface == 'cli' and supports_ansi())

    ctx.register_command("c2c-send", handle_c2c_send,
                         "Send a c2c DM: /c2c-send <alias> <message>")

    # -- /c2c-list ---------------------------------------------------------
    @registry.command
    def handle_c2c_list(args_str, session):
        """Usage: /c2c-list"""
        try:
            return _fmt(session.cli.list())
        except Exception:
            return "c2c command failed"

    ctx.register_command("c2c-list", handle_c2c_list,
                         "List all c2c peers")

    # -- /c2c-poll ---------------------------------------------------------
    @registry.command
    def handle_c2c_poll(args_str, session):
        """Usage: /c2c-poll"""
        try:
            messages = inbox_messages(session.delivery.poll(), session.binding.alias)
            return '\n\n'.join(ctx._c2c_display.format(m, ansi=session.binding.surface == 'cli' and supports_ansi())
                               for m in messages) or 'C2C inbox | no messages'
        except Exception:
            return "c2c command failed"

    ctx.register_command("c2c-poll", handle_c2c_poll,
                         "Drain your c2c inbox")

    # -- /c2c-whoami -------------------------------------------------------
    @registry.command
    def handle_c2c_whoami(args_str, session):
        """Usage: /c2c-whoami"""
        try:
            return _fmt(session.cli.whoami())
        except Exception:
            return "c2c command failed"

    ctx.register_command("c2c-whoami", handle_c2c_whoami,
                         "Show your c2c identity")

    # -- /c2c-rooms -------------------------------------------------------
    @registry.command
    def handle_c2c_rooms(args_str, session):
        """Usage: /c2c-rooms [list|my-rooms|join <room>|send <room> <msg>|leave <room>]"""
        if not args_str:
            try:
                return _fmt(session.cli.rooms_my_rooms())
            except Exception:
                return "c2c command failed"
        parts = args_str.split(None, 1)
        sub = parts[0]
        rest = parts[1] if len(parts) > 1 else ""
        try:
            if sub == "list":
                return _fmt(session.cli.rooms_list())
            elif sub == "my-rooms" or sub == "mine":
                return _fmt(session.cli.rooms_my_rooms())
            elif sub == "join":
                if not rest:
                    return "Usage: /c2c-rooms join <room>"
                return _fmt(session.cli.rooms_join(rest.strip()))
            elif sub == "send":
                send_parts = rest.split(None, 1)
                if len(send_parts) < 2:
                    return "Usage: /c2c-rooms send <room> <message>"
                return _fmt(session.cli.rooms_send(send_parts[0], send_parts[1]))
            elif sub == "leave":
                if not rest:
                    return "Usage: /c2c-rooms leave <room>"
                return _fmt(session.cli.rooms_leave(rest.strip()))
            elif sub == "history":
                if not rest:
                    return "Usage: /c2c-rooms history <room>"
                return _fmt(session.cli.rooms_history(rest.strip()))
            elif sub == "members":
                if not rest:
                    return "Usage: /c2c-rooms members <room>"
                return _fmt(session.cli.rooms_members(rest.strip()))
            else:
                return ("Usage: /c2c-rooms [list|my-rooms|join <room>|"
                        "send <room> <msg>|leave <room>|history <room>|members <room>]")
        except Exception:
            return "c2c command failed"

    ctx.register_command("c2c-rooms", handle_c2c_rooms,
                         "c2c rooms: list, join, send, leave, history, members")

    logger.info("[c2c] registered 5 slash commands")
