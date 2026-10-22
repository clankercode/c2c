"""c2c's Hermes adapter: profile/session-owned tools and selected-ACK delivery."""

import logging
from pathlib import Path

logger = logging.getLogger("c2c")


def register(ctx):
    from .identity import SessionRegistry
    from .tools import register_all_tools
    from .commands import register_all_commands
    from .broker_watcher import BrokerWatcher

    registry = SessionRegistry(ctx)
    register_all_tools(ctx, registry)
    register_all_commands(ctx, registry)
    skill_path = Path(__file__).parent / "skills" / "c2c"
    if skill_path.is_dir():
        ctx.register_skill("c2c", str(skill_path))

    def start(**kwargs):
        try:
            session = registry.start(**kwargs)
            if session.watcher is None:
                session.watcher = BrokerWatcher(ctx, session)
                session.watcher.start()
        except Exception:
            logger.warning("[c2c] session registration refused or unavailable")

    def pre_llm_call(**kwargs):
        try:
            # First-turn mail follows the same synchronous acceptance path.
            body = registry.resolve(**kwargs).delivery.context()
            return {"context": body} if body else None
        except Exception:
            return None

    def finalize(**kwargs):
        try:
            registry.end(**kwargs)
        except Exception:
            pass

    ctx.register_hook("on_session_start", start)
    ctx.register_hook("pre_llm_call", pre_llm_call)
    # Hermes on_session_end is per-TURN; only finalize ends the conversation.
    ctx.register_hook("on_session_finalize", finalize)
    ctx.on_unload(registry.close)
    ctx._c2c_sessions = registry
