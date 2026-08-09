"""c2c plugin for Hermes Agent — send/list/rooms tools, auto-delivery, idle wake.

This plugin makes Hermes a first-class c2c peer, mirroring the pi-c2c
extension architecture:
  - on_session_start: auto-register c2c identity
  - LLM-callable tools: c2c_send, c2c_list, c2c_poll_inbox, c2c_join_room, ...
  - Slash commands: /c2c-send, /c2c-list, /c2c-poll, /c2c-whoami, /c2c-rooms
  - Background watcher: drains inbox, injects via ctx.inject_message (idle wake)
  - pre_llm_call hook: turn-boundary context injection

All c2c interactions shell to the `c2c` binary (no reimplemented broker logic).
The plugin handles missing-binary and gateway-mode gracefully.
"""

import logging

logger = logging.getLogger("c2c")


def register(ctx):
    """Wire all hooks, tools, commands, and start the background watcher."""

    # -- Check c2c binary availability early -------------------------------
    from .c2c_cli import C2cCli
    cli = C2cCli()
    if not cli.available:
        logger.warning(
            "[c2c] c2c binary not found on PATH. Plugin will register tools/commands "
            "but they will return errors. Set C2C_BIN or install c2c to enable."
        )

    # -- Register LLM-callable tools --------------------------------------
    from .tools import register_all_tools
    register_all_tools(ctx)

    # -- Register slash commands ------------------------------------------
    from .commands import register_all_commands
    register_all_commands(ctx)

    # -- Register the c2c skill (so skill_view('plugin:c2c') works) ------
    import os
    skill_path = os.path.join(os.path.dirname(__file__), "skills", "c2c")
    if os.path.isdir(skill_path):
        try:
            ctx.register_skill("c2c", skill_path)
            logger.info("[c2c] skill registered at %s", skill_path)
        except Exception as e:
            logger.debug("[c2c] skill registration failed: %s", e)

    # -- Hook: on_session_start — auto-register identity ------------------
    from .identity import register_identity
    ctx.register_hook("on_session_start", register_identity)

    # -- Hook: pre_llm_call — turn-boundary context injection -------------
    from .delivery import drain_for_context
    from .identity import get_alias

    def pre_llm_call_hook(session_id=None, user_message=None,
                          conversation_history=None, is_first_turn=False,
                          model=None, platform=None, **kwargs):
        """Drain inbox at turn start and return context if messages found.

        This gives mid-turn delivery (like Claude PostToolUse) as a
        complement to the background watcher's idle wake. Returns
        {"context": "<c2c envelopes>"} if any messages were drained,
        None if inbox is empty.
        """
        # Don't drain on the first turn — on_session_start handles that.
        if is_first_turn:
            return None
        try:
            alias = get_alias()
            context = drain_for_context(cli=cli, self_alias=alias)
            if context:
                return {"context": context}
        except Exception as e:
            logger.debug("[c2c] pre_llm_call drain error: %s", e)
        return None

    ctx.register_hook("pre_llm_call", pre_llm_call_hook)

    # -- Hook: on_session_end — cleanup -----------------------------------
    def on_session_end_hook(session_id=None, completed=False, interrupted=False,
                            model=None, platform=None, **kwargs):
        """Log session end. The watcher is a daemon thread and dies with the process."""
        logger.info("[c2c] session ended (completed=%s, interrupted=%s)", completed, interrupted)

    ctx.register_hook("on_session_end", on_session_end_hook)

    # -- Start the background watcher (the wake mechanism) -----------------
    from .broker_watcher import BrokerWatcher
    watcher = BrokerWatcher(ctx, cli=cli)
    watcher.start()

    # Store watcher reference on ctx to prevent GC
    # (daemon threads don't prevent process exit, but we want it alive
    # for the session lifetime)
    try:
        ctx._c2c_watcher = watcher
    except Exception:
        pass

    logger.info("[c2c] plugin registered — tools, commands, hooks, and watcher active")