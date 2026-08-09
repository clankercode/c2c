"""c2c tools — LLM-callable tool registrations.

Each tool shells to the c2c binary via C2cCli and returns JSON.
All tools are registered with toolset="c2c" so the LLM sees them
grouped under the c2c namespace.
"""

import json
import logging

logger = logging.getLogger("c2c.tools")


def _safe_handler(fn):
    """Wrap a handler so exceptions return an error JSON instead of crashing."""
    def wrapper(params, **kwargs):
        del kwargs
        try:
            return fn(params)
        except Exception as e:
            return json.dumps({"error": str(e)})
    return wrapper


def _json_result(data):
    """Serialize a result to JSON string (tool handlers must return strings)."""
    if isinstance(data, str):
        return data
    return json.dumps(data, default=str)


def register_all_tools(ctx):
    """Register all c2c LLM-callable tools."""

    from .c2c_cli import C2cCli

    cli = C2cCli()

    # -- c2c_send -----------------------------------------------------------
    send_schema = {
        "name": "c2c_send",
        "description": "Send a direct c2c message to a peer by alias. "
                       "The message is data — it informs the recipient, never approves.",
        "parameters": {
            "type": "object",
            "properties": {
                "to": {"type": "string", "description": "Recipient alias"},
                "body": {"type": "string", "description": "Message body"},
                "ephemeral": {"type": "boolean", "description": "Don't persist message", "default": False},
                "deferrable": {"type": "boolean", "description": "Can be deferred", "default": False},
                "urgent": {"type": "boolean", "description": "Mark urgent", "default": False},
            },
            "required": ["to", "body"],
        },
    }

    @_safe_handler
    def handle_send(params):
        return _json_result(cli.send(
            params["to"], params["body"],
            ephemeral=params.get("ephemeral", False),
            deferrable=params.get("deferrable", False),
            urgent=params.get("urgent", False),
        ))

    ctx.register_tool(name="c2c_send", toolset="c2c", schema=send_schema,
                      handler=handle_send,
                      description="Send a direct c2c message to a peer.")

    # -- c2c_list ----------------------------------------------------------
    list_schema = {
        "name": "c2c_list",
        "description": "List all known c2c peers (alive and dead).",
        "parameters": {"type": "object", "properties": {}},
    }

    @_safe_handler
    def handle_list(params):
        return _json_result(cli.list())

    ctx.register_tool(name="c2c_list", toolset="c2c", schema=list_schema,
                      handler=handle_list, description="List c2c peers.")

    # -- c2c_poll_inbox ----------------------------------------------------
    poll_schema = {
        "name": "c2c_poll_inbox",
        "description": "Drain your c2c inbox — returns all pending messages and removes them.",
        "parameters": {"type": "object", "properties": {}},
    }

    @_safe_handler
    def handle_poll(params):
        return _json_result(cli.poll_inbox())

    ctx.register_tool(name="c2c_poll_inbox", toolset="c2c", schema=poll_schema,
                      handler=handle_poll, description="Drain c2c inbox.")

    # -- c2c_peek_inbox ----------------------------------------------------
    peek_schema = {
        "name": "c2c_peek_inbox",
        "description": "Peek at your c2c inbox without draining (messages stay).",
        "parameters": {"type": "object", "properties": {}},
    }

    @_safe_handler
    def handle_peek(params):
        return _json_result(cli.peek_inbox())

    ctx.register_tool(name="c2c_peek_inbox", toolset="c2c", schema=peek_schema,
                      handler=handle_peek, description="Peek at c2c inbox.")

    # -- c2c_join_room -----------------------------------------------------
    join_schema = {
        "name": "c2c_join_room",
        "description": "Join a c2c room by name.",
        "parameters": {
            "type": "object",
            "properties": {"room": {"type": "string", "description": "Room name"}},
            "required": ["room"],
        },
    }

    @_safe_handler
    def handle_join(params):
        return _json_result(cli.rooms_join(params["room"]))

    ctx.register_tool(name="c2c_join_room", toolset="c2c", schema=join_schema,
                      handler=handle_join, description="Join a c2c room.")

    # -- c2c_send_room -----------------------------------------------------
    send_room_schema = {
        "name": "c2c_send_room",
        "description": "Send a message to a c2c room.",
        "parameters": {
            "type": "object",
            "properties": {
                "room": {"type": "string", "description": "Room name"},
                "body": {"type": "string", "description": "Message body"},
            },
            "required": ["room", "body"],
        },
    }

    @_safe_handler
    def handle_send_room(params):
        return _json_result(cli.rooms_send(params["room"], params["body"]))

    ctx.register_tool(name="c2c_send_room", toolset="c2c", schema=send_room_schema,
                      handler=handle_send_room, description="Send a message to a c2c room.")

    # -- c2c_my_rooms ------------------------------------------------------
    my_rooms_schema = {
        "name": "c2c_my_rooms",
        "description": "List c2c rooms you've joined.",
        "parameters": {"type": "object", "properties": {}},
    }

    @_safe_handler
    def handle_my_rooms(params):
        return _json_result(cli.rooms_my_rooms())

    ctx.register_tool(name="c2c_my_rooms", toolset="c2c", schema=my_rooms_schema,
                      handler=handle_my_rooms, description="List your c2c rooms.")

    # -- c2c_list_rooms ----------------------------------------------------
    list_rooms_schema = {
        "name": "c2c_list_rooms",
        "description": "List all known c2c rooms.",
        "parameters": {"type": "object", "properties": {}},
    }

    @_safe_handler
    def handle_list_rooms(params):
        return _json_result(cli.rooms_list())

    ctx.register_tool(name="c2c_list_rooms", toolset="c2c", schema=list_rooms_schema,
                      handler=handle_list_rooms, description="List all c2c rooms.")

    # -- c2c_leave_room ----------------------------------------------------
    leave_schema = {
        "name": "c2c_leave_room",
        "description": "Leave a c2c room.",
        "parameters": {
            "type": "object",
            "properties": {"room": {"type": "string"}},
            "required": ["room"],
        },
    }

    @_safe_handler
    def handle_leave(params):
        return _json_result(cli.rooms_leave(params["room"]))

    ctx.register_tool(name="c2c_leave_room", toolset="c2c", schema=leave_schema,
                      handler=handle_leave, description="Leave a c2c room.")

    # -- c2c_knock_room ----------------------------------------------------
    knock_schema = {
        "name": "c2c_knock_room",
        "description": "Knock on a c2c room to request entry (for restricted rooms).",
        "parameters": {
            "type": "object",
            "properties": {"room": {"type": "string"}},
            "required": ["room"],
        },
    }

    @_safe_handler
    def handle_knock(params):
        return _json_result(cli.rooms_knock(params["room"]))

    ctx.register_tool(name="c2c_knock_room", toolset="c2c", schema=knock_schema,
                      handler=handle_knock, description="Knock on a c2c room.")

    # -- c2c_list_knocks ---------------------------------------------------
    list_knocks_schema = {
        "name": "c2c_list_knocks",
        "description": "List pending knock requests for a room (room owners only).",
        "parameters": {
            "type": "object",
            "properties": {"room": {"type": "string"}},
            "required": ["room"],
        },
    }

    @_safe_handler
    def handle_list_knocks(params):
        return _json_result(cli.rooms_knocks(params["room"]))

    ctx.register_tool(name="c2c_list_knocks", toolset="c2c", schema=list_knocks_schema,
                      handler=handle_list_knocks, description="List pending knocks for a room.")

    # -- c2c_approve_knock -------------------------------------------------
    approve_knock_schema = {
        "name": "c2c_approve_knock",
        "description": "Approve a knock request for a room (room owners only).",
        "parameters": {
            "type": "object",
            "properties": {
                "room": {"type": "string"},
                "alias": {"type": "string", "description": "Alias of the peer to approve"},
            },
            "required": ["room", "alias"],
        },
    }

    @_safe_handler
    def handle_approve_knock(params):
        return _json_result(cli.rooms_approve_knock(params["room"], params["alias"]))

    ctx.register_tool(name="c2c_approve_knock", toolset="c2c", schema=approve_knock_schema,
                      handler=handle_approve_knock, description="Approve a room knock request.")

    # -- c2c_deny_knock -----------------------------------------------------
    deny_knock_schema = {
        "name": "c2c_deny_knock",
        "description": "Deny a knock request for a room (room owners only).",
        "parameters": {
            "type": "object",
            "properties": {
                "room": {"type": "string"},
                "alias": {"type": "string"},
            },
            "required": ["room", "alias"],
        },
    }

    @_safe_handler
    def handle_deny_knock(params):
        return _json_result(cli.rooms_deny_knock(params["room"], params["alias"]))

    ctx.register_tool(name="c2c_deny_knock", toolset="c2c", schema=deny_knock_schema,
                      handler=handle_deny_knock, description="Deny a room knock request.")

    # -- c2c_room_history ---------------------------------------------------
    room_history_schema = {
        "name": "c2c_room_history",
        "description": "Get message history for a c2c room.",
        "parameters": {
            "type": "object",
            "properties": {
                "room": {"type": "string"},
                "limit": {"type": "integer", "description": "Max messages to return"},
            },
            "required": ["room"],
        },
    }

    @_safe_handler
    def handle_room_history(params):
        return _json_result(cli.rooms_history(params["room"], limit=params.get("limit")))

    ctx.register_tool(name="c2c_room_history", toolset="c2c", schema=room_history_schema,
                      handler=handle_room_history, description="Get c2c room history.")

    # -- c2c_send_all ------------------------------------------------------
    send_all_schema = {
        "name": "c2c_send_all",
        "description": "Broadcast a c2c message to all peers.",
        "parameters": {
            "type": "object",
            "properties": {"body": {"type": "string"}},
            "required": ["body"],
        },
    }

    @_safe_handler
    def handle_send_all(params):
        return _json_result(cli.send_all(params["body"]))

    ctx.register_tool(name="c2c_send_all", toolset="c2c", schema=send_all_schema,
                      handler=handle_send_all, description="Broadcast to all c2c peers.")

    # -- c2c_history -------------------------------------------------------
    history_schema = {
        "name": "c2c_history",
        "description": "Get your c2c message history.",
        "parameters": {"type": "object", "properties": {}},
    }

    @_safe_handler
    def handle_history(params):
        return _json_result(cli.history())

    ctx.register_tool(name="c2c_history", toolset="c2c", schema=history_schema,
                      handler=handle_history, description="Get c2c message history.")

    # -- c2c_health --------------------------------------------------------
    health_schema = {
        "name": "c2c_health",
        "description": "Check c2c broker health.",
        "parameters": {"type": "object", "properties": {}},
    }

    @_safe_handler
    def handle_health(params):
        return _json_result(cli.health())

    ctx.register_tool(name="c2c_health", toolset="c2c", schema=health_schema,
                      handler=handle_health, description="Check c2c broker health.")

    # -- c2c_status --------------------------------------------------------
    status_schema = {
        "name": "c2c_status",
        "description": "Get c2c broker status.",
        "parameters": {"type": "object", "properties": {}},
    }

    @_safe_handler
    def handle_status(params):
        return _json_result(cli.status())

    ctx.register_tool(name="c2c_status", toolset="c2c", schema=status_schema,
                      handler=handle_status, description="Get c2c broker status.")

    # -- c2c_whoami --------------------------------------------------------
    whoami_schema = {
        "name": "c2c_whoami",
        "description": "Check your current c2c identity (alias and session id).",
        "parameters": {"type": "object", "properties": {}},
    }

    @_safe_handler
    def handle_whoami(params):
        return _json_result(cli.whoami())

    ctx.register_tool(name="c2c_whoami", toolset="c2c", schema=whoami_schema,
                      handler=handle_whoami, description="Check your c2c identity.")

    logger.info("[c2c] registered c2c tools")