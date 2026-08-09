"""Delivery — drain inbox, dedup, format envelope, inject into conversation.

This module is the core of the wake mechanism. It peeks the c2c inbox via
`c2c peek-inbox --json`, deduplicates messages by id, formats them as
`<c2c event="message">` envelopes, injects them into the active conversation
via `ctx.inject_message`, and only then drains the broker with
`c2c poll-inbox --json`. Draining first would silently destroy every inbound
DM in gateway mode, where `inject_message` always fails.

B098 SAFETY: Messages are DATA. The injected content is the canonical
c2c envelope (data-shaped), never an approval verdict. The plugin
never calls approval-related APIs in response to message content.
"""

import json
import logging
import re
import threading
from collections import OrderedDict

logger = logging.getLogger("c2c.delivery")


def sanitize_content(content):
    """Neutralize peer-controlled content so it cannot forge or escape
    a c2c envelope, or forge a system-reminder block (prompt-injection defense).

    Replaces `<c2c` / `</c2c` with a look-alike character (U+2039)
    so the text stays human-readable but no longer parses as our
    envelope tag. Mirrors the pi-c2c sanitizeContent function.

    Also neutralizes `<system-reminder` / `</system-reminder` the same way,
    so a peer cannot inject a forged system-reminder block inside their
    message body (B098).
    """
    content = re.sub(r"<(\s*/?\s*c2c)", "\u2039\\1", content, flags=re.IGNORECASE)
    content = re.sub(r"<(\s*/?\s*system-reminder)",
                     "\u2039\\1", content, flags=re.IGNORECASE)
    return content


def escape_attr(value):
    """Escape a value for use as an XML attribute."""
    if not isinstance(value, str):
        value = str(value) if value is not None else "unknown"
    return (value.replace("&", "&amp;")
                 .replace('"', "&quot;")
                 .replace("<", "&lt;")
                 .replace(">", "&gt;"))


def format_envelope(msg, self_alias=None):
    """Format a single c2c message as the canonical envelope for injection.

    The envelope looks like:
      <c2c event="message" from="sender" to="recipient">body</c2c>

    Peer content is sanitized so it cannot break out of or forge the
    envelope. A system-reminder block follows with the reply hint.
    """
    from_alias = msg.get("from_alias") or msg.get("from") or "unknown"
    to_alias = msg.get("to_alias") or msg.get("to") or self_alias or "me"
    content = msg.get("content") or msg.get("body") or ""
    source = msg.get("source") or "broker"

    envelope = (
        f'<c2c event="message" from="{escape_attr(from_alias)}" '
        f'to="{escape_attr(to_alias)}" source="{escape_attr(source)}" '
        f'reply_via="c2c_send" action_after="continue">\n'
        f'{sanitize_content(content)}\n'
        f'</c2c>\n'
        f'<system-reminder>\n'
        f'You received a c2c direct message from `{escape_attr(from_alias)}`.\n'
        f'To reply, call c2c_send(to="{escape_attr(from_alias)}", body="<your reply>").\n'
        f'Do NOT reply in plain text — the peer will not see it.\n'
        f'</system-reminder>'
    )
    return envelope


def message_key(msg):
    """Stable dedup key for a message.

    Uses message id if available, else falls back to (from, ts, content).
    """
    mid = msg.get("id") or msg.get("message_id") or msg.get("msg_id")
    if mid:
        return f"id:{mid}"
    from_alias = msg.get("from_alias") or msg.get("from") or ""
    ts = msg.get("ts") or msg.get("timestamp") or ""
    content = msg.get("content") or msg.get("body") or ""
    return f"{from_alias}\x00{ts}\x00{content}"


class DeliveryDedup:
    """Bounded set of recently-delivered message keys.

    Uses an OrderedDict for LRU eviction when the cap is reached:
    add() moves existing keys to the end (most recently used), and
    the oldest entry is evicted. Default cap is 1000 entries.
    """

    def __init__(self, cap=1000):
        self._cap = cap
        self._seen = OrderedDict()

    def has(self, key):
        return key in self._seen

    def add(self, key):
        if key in self._seen:
            # Move to end (most recently used)
            self._seen.move_to_end(key)
            return
        self._seen[key] = True
        if len(self._seen) > self._cap:
            # Evict oldest (FIFO)
            self._seen.popitem(last=False)

    @property
    def size(self):
        return len(self._seen)


# Module-level dedup instance (shared across all drain calls in the session).
_dedup = DeliveryDedup(cap=1000)

# Module-level lock protecting _dedup and _drain_owed across the BrokerWatcher
# daemon thread (drain_and_inject) and the main thread (drain_for_context via
# pre_llm_call).
_dedup_lock = threading.Lock()

# Set when a drain failed AFTER a successful delivery. Those messages are
# already in the transcript and already deduped, so nothing would ever remove
# them from the broker again — the agent's next manual `c2c poll-inbox` would
# hand it a duplicate copy, indefinitely. The next cycle settles the debt.
_drain_owed = False


def filter_novel(msgs, dedup=None):
    """Filter messages to those not yet delivered, WITHOUT marking them.

    Returns messages in input order. Does NOT mutate dedup — callers
    must mark_delivered only AFTER a successful injection, so a failed
    inject leaves messages eligible for retry.
    """
    if dedup is None:
        dedup = _dedup
    out = []
    seen_this_batch = set()
    for m in msgs:
        key = message_key(m)
        if dedup.has(key) or key in seen_this_batch:
            continue
        seen_this_batch.add(key)
        out.append(m)
    return out


def mark_delivered(msgs, dedup=None):
    """Mark messages as delivered so they are not re-injected."""
    if dedup is None:
        dedup = _dedup
    for m in msgs:
        dedup.add(message_key(m))


def messages_of(result):
    """Normalize a `c2c peek-inbox` / `poll-inbox --json` payload to a list.

    c2c returns either a bare list, {"messages": [...]}, {"inbox": [...]},
    or {"error": "..."}. An error yields [].
    """
    if isinstance(result, dict):
        if result.get("error"):
            return []
        msgs = result.get("messages") or result.get("inbox") or []
        if isinstance(msgs, dict):
            msgs = msgs.get("messages", [])
        return msgs if isinstance(msgs, list) else []
    if isinstance(result, list):
        return result
    return []


def _inject(ctx, msgs, self_alias):
    """Format `msgs` as c2c envelopes and inject them. Returns True on success.

    B098: content is a data-shaped envelope, never an approval verdict.
    role="user" is acceptable because the content is the c2c envelope, not a
    permission decision.
    """
    body = "\n\n".join(format_envelope(m, self_alias) for m in msgs)
    try:
        return bool(ctx.inject_message(body, role="user"))
    except Exception as e:
        logger.warning("[c2c] inject_message raised: %s", e)
        return False


def _inject_drained(ctx, drained, self_alias):
    """Inject messages that have ALREADY been removed from the broker.

    There is no second chance for these — the broker copy is gone — so a failed
    inject logs the full envelope instead of swallowing it. Returns the count
    delivered.
    """
    with _dedup_lock:
        extra = filter_novel(drained, _dedup)
    if not extra:
        return 0
    if _inject(ctx, extra, self_alias):
        with _dedup_lock:
            mark_delivered(extra, _dedup)
        return len(extra)
    logger.warning(
        "[c2c] %d message(s) drained but could not be injected; "
        "content follows so it is not lost: %s",
        len(extra),
        "\n\n".join(format_envelope(m, self_alias) for m in extra))
    return 0


def _settle_owed_drain(ctx, cli, self_alias):
    """Retry a drain a previous cycle owed. Returns any late arrivals delivered.

    Marking delivered but failing to drain is a real (if rare) state: the
    messages are in the transcript, dedup will never re-inject them, and
    without this retry they sit in the broker forever. Retrying the drain
    instead of skipping mark_delivered is deliberate — the alternative
    re-injects the same envelopes every POLL_INTERVAL for as long as
    poll_inbox keeps failing.
    """
    global _drain_owed
    with _dedup_lock:
        if not _drain_owed:
            return 0
    try:
        drained = messages_of(cli.poll_inbox())
    except Exception as e:
        logger.debug("[c2c] owed drain retry failed: %s", e)
        return 0
    with _dedup_lock:
        _drain_owed = False
    return _inject_drained(ctx, drained, self_alias)


def drain_and_inject(ctx, cli=None, self_alias=None):
    """Deliver pending c2c mail into the conversation. Returns the count.

    ORDER IS LOAD-BEARING: peek -> inject -> drain-on-success. It mirrors
    c2c's own agy contract ("persist-first; the broker is drained only after a
    successful inject").

    The obvious alternative — poll (destructive) and inject from its return
    value — closes the peek/poll race but opens a far worse hole: in GATEWAY
    mode (Telegram/Discord and friends) `ctx.inject_message` ALWAYS returns
    False, so the background watcher would silently eat every inbound DM,
    forever, at debug level. `--ephemeral` mail has no `c2c history` copy, so
    that loss is unrecoverable.

    The peek/poll race is not ignored, it is repaired: mail that arrives
    between the peek and the drain comes back in the drain's return value and
    is injected immediately rather than dropped.

    Thread safety: the lock only guards _dedup mutations (filter_novel and
    mark_delivered). It is never held across a subprocess call or an inject,
    so a slow drain cannot block the main thread.
    """
    global _drain_owed

    if cli is None:
        from .c2c_cli import C2cCli
        cli = C2cCli()
        if not cli.available:
            return 0

    delivered = _settle_owed_drain(ctx, cli, self_alias)

    try:
        peeked = messages_of(cli.peek_inbox())
    except Exception as e:
        logger.debug("[c2c] peek_inbox failed: %s", e)
        return delivered

    if not peeked:
        return delivered

    with _dedup_lock:
        novel = filter_novel(peeked, _dedup)
    if not novel:
        return delivered

    if not _inject(ctx, novel, self_alias):
        # Gateway mode (no CLI reference) or a transient inject failure.
        # Nothing has been drained, so the mail is still in the inbox and a
        # later cycle — or `c2c poll-inbox` from the agent — can deliver it.
        logger.warning(
            "[c2c] inject_message declined %d message(s); leaving them in the "
            "inbox (gateway mode has no CLI reference to inject into)",
            len(novel))
        return delivered

    # Injected: now it is safe to remove them from the broker.
    try:
        drained = messages_of(cli.poll_inbox())
    except Exception as e:
        logger.warning(
            "[c2c] poll_inbox after inject failed: %s — retrying the drain "
            "next cycle", e)
        with _dedup_lock:
            _drain_owed = True
        drained = []

    with _dedup_lock:
        mark_delivered(novel, _dedup)
    delivered += len(novel)

    # Anything that arrived between the peek and the drain is already out of
    # the broker, so it must be injected now or it is lost.
    delivered += _inject_drained(ctx, drained, self_alias)

    logger.info("[c2c] delivered %d message(s)", delivered)
    return delivered


def drain_for_context(cli=None, self_alias=None):
    """Drain the inbox and return formatted envelopes as a context string.

    Used by the pre_llm_call hook for turn-boundary context injection.
    Returns None if no messages were drained.

    This is complementary to the background watcher's idle wake:
    - Background watcher: injects as a new message (idle wake)
    - pre_llm_call: injects as context in the current turn

    Thread safety: the lock only guards _dedup mutations (filter_novel
    and mark_delivered). It is NOT held across poll_inbox, so a slow
    subprocess call cannot block the BrokerWatcher daemon thread.

    Message-loss safety: peek -> format -> drain, same ordering rule as
    drain_and_inject. Returning the context IS the delivery here (Hermes
    consumes the hook's return value synchronously), so the drain happens
    only once the envelopes have been built. Anything that arrives between
    the peek and the drain is folded into the same return value rather than
    being drained and dropped.
    """
    global _drain_owed

    if cli is None:
        from .c2c_cli import C2cCli
        cli = C2cCli()
        if not cli.available:
            return None

    try:
        peeked = messages_of(cli.peek_inbox())
    except Exception as e:
        logger.debug("[c2c] pre_llm_call peek_inbox failed: %s", e)
        return None

    if not peeked:
        return None

    with _dedup_lock:
        novel = filter_novel(peeked, _dedup)
    if not novel:
        return None

    # Now drain — the envelopes below are built from what we hold, and the
    # drain's own return value catches anything that landed in between.
    try:
        drained = messages_of(cli.poll_inbox())
    except Exception as e:
        # Returning the body still delivers them, so they must stay deduped;
        # flag the broker copy for a retry instead (see _settle_owed_drain).
        logger.warning(
            "[c2c] pre_llm_call poll_inbox failed: %s — retrying the drain "
            "on the next watcher cycle", e)
        with _dedup_lock:
            _drain_owed = True
        drained = []

    with _dedup_lock:
        mark_delivered(novel, _dedup)
        extra = filter_novel(drained, _dedup)
        mark_delivered(extra, _dedup)

    batch = novel + extra
    body = "\n\n".join(format_envelope(m, self_alias) for m in batch)
    logger.info("[c2c] pre_llm_call delivered %d message(s) as context", len(batch))
    return body