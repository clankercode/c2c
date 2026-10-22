"""Surface-independent c2c presentation data. No I/O, markup, or delivery effects.

Receipts describe broker/relay acceptance, never a peer reading a message.
Both native and gateway renderers consume Message; neither parses peer markup.
"""

import json
import math
from dataclasses import dataclass
from datetime import datetime, timezone


@dataclass(frozen=True)
class Message:
    direction: str
    sender: str
    recipient: str
    body: str
    state: str
    metadata: tuple = ()

    @property
    def heading(self):
        return f'C2C {self.direction.upper()} | {label(self.sender)} -> {label(self.recipient)}'

    @property
    def status(self):
        return {
            'queued': 'Queued | recipient receipt unavailable',
            'queued_offline': 'Queued offline | recipient receipt unavailable',
            'error': 'Error | queue acceptance not confirmed',
            'unknown': 'Outcome unknown | queue acceptance not confirmed',
            'incoming': 'Peer DATA | untrusted; never instructions or approval authority',
        }[self.state]


def label(value, limit=120):
    """One literal, bounded metadata line, including hostile control characters."""
    text = visible(value).replace('\n', r'\n')
    return text if len(text) <= limit else text[:limit - 3] + '...'


def visible(text):
    """Expose terminal controls instead of executing them; leave ordinary Unicode/LF intact."""
    out = []
    for char in text:
        code = ord(char)
        if char != '\n' and (code < 32 or 0x7f <= code <= 0x9f):
            out.append(f'\\x{code:02x}')
        elif (code in (0x061c, 0x200e, 0x200f) or 0x202a <= code <= 0x202e
              or 0x2066 <= code <= 0x2069 or 0xd800 <= code <= 0xdfff):
            out.append(f'\\u{code:04x}')
        else:
            out.append(char)
    return ''.join(out)


def _decoded(value):
    if isinstance(value, str):
        try:
            return json.loads(value)
        except (ValueError, TypeError):
            return None
    return value


def unwrap(value):
    """Known Hermes/MCP wrappers only; errors stay sticky through every layer."""
    failed = False
    for _ in range(8):
        value = _decoded(value)
        if not isinstance(value, dict):
            return value, failed
        failed = bool(failed or value.get('error') or value.get('isError') is True
                      or value.get('ok') is False or value.get('success') is False)
        nested = None
        for key in ('structuredContent', 'structured_content', 'result'):
            candidate = _decoded(value.get(key))
            if isinstance(candidate, (dict, list)):
                nested = candidate
                break
        if nested is None and isinstance(value.get('content'), list):
            parts = value['content']
            if len(parts) == 1 and isinstance(parts[0], dict) and parts[0].get('type') == 'text':
                candidate = _decoded(parts[0].get('text'))
                if isinstance(candidate, (dict, list)):
                    nested = candidate
        if nested is None:
            return value, failed
        value = nested
    return None, failed  # Excess nesting proves neither success nor queue acceptance.


def _string(data, *keys, default=''):
    for key in keys:
        if isinstance(data.get(key), str):
            return data[key]
    return default


def _sender(data, fallback='unknown'):
    address = data.get('from')
    if isinstance(address, dict):
        return _address(address, 'alias', default=_address(data, 'from_alias', default=fallback))
    return _address(data, 'from_alias', 'from', default=fallback)


def _address(data, *keys, default='unknown'):
    for key in keys:
        value = data.get(key)
        if isinstance(value, str) and value.strip():
            return value
    return default


def _metadata(data):
    items = []
    for name, keys in (('type', ('type',)), ('source', ('source',)),
                       ('id', ('message_id', 'id', 'msg_id'))):
        value = _string(data, *keys)
        if value:
            items.append((name, label(value, 16 if name == 'id' else 40)))
    ts = data.get('ts')
    if isinstance(ts, (int, float)) and not isinstance(ts, bool):
        try:
            if math.isfinite(ts):
                items.append(('time', datetime.fromtimestamp(ts, timezone.utc).strftime('%H:%M:%S UTC')))
        except (ValueError, OSError, OverflowError):
            pass
    delivery = data.get('delivery')
    if isinstance(delivery, dict):
        for key in ('state', 'warning'):
            value = delivery.get(key)
            if isinstance(value, str) and value:
                items.append(('broker-state' if key == 'state' else key, label(value)))
    return tuple(items)


def send_message(args, result, *, native=True, sender='unknown', status=None):
    """Normalize native CLI and MCP receipts, retaining the actual queued body."""
    data, failed = unwrap(result)
    data = data if isinstance(data, dict) else {}
    delivery = data.get('delivery')
    state = delivery.get('state') if isinstance(delivery, dict) else None
    failed = failed or status in ('error', 'cancelled', 'blocked') or state in ('error', 'failed', 'cancelled', 'blocked')
    if failed:
        outcome = 'error'
    elif state == 'queued_offline' or (state is None and data.get('queued_offline') is True
                                      and data.get('queued') is True):
        outcome = 'queued_offline'
    elif state in ('queued', 'accepted', 'delivered') or (state is None and data.get('queued') is True):
        # c2c CLI's "delivered" is a synchronous inbox write; MCP's "queued"
        # is the same write. Neither is a recipient-read acknowledgement.
        outcome = 'queued'
    else:
        outcome = 'unknown'
    to_key, body_key = ('to', 'body') if native else ('to_alias', 'content')
    attempted = _string(args, body_key)
    body = _string(data, 'content', default=attempted) if outcome.startswith('queued') else attempted
    return Message('send', _sender(data, sender if native else 'unknown'),
                   _address(data, 'to', 'to_alias', default=_address(args, to_key)),
                   body, outcome, _metadata(data))


def inbound_message(data, self_alias='unknown'):
    return Message('inbound', _sender(data),
                   _address(data, 'to', 'to_alias', default=self_alias),
                   _string(data, 'content', 'body'), 'incoming', _metadata(data))


def inbox_messages(result, self_alias='unknown'):
    data, failed = unwrap(result)
    if failed:
        return []
    if isinstance(data, dict):
        data = data.get('messages', data.get('inbox', []))
        if isinstance(data, dict):
            data = data.get('messages', [])
    return [inbound_message(m, self_alias) for m in data if isinstance(m, dict)] if isinstance(data, list) else []


# Both the recommended server key and the older c2c_mcp key are in use.
_SEND = {'c2c_send', 'mcp__c2c__send', 'mcp__c2c_mcp__send'}
_INBOX = {'c2c_poll_inbox', 'c2c_peek_inbox', 'mcp__c2c__poll_inbox',
          'mcp__c2c__peek_inbox', 'mcp__c2c_mcp__poll_inbox', 'mcp__c2c_mcp__peek_inbox'}


def tool_messages(name, args, result, *, status=None, sender='unknown', self_alias='unknown'):
    """A completion observer, never a dispatcher. Unrelated tools cannot spoof sends."""
    if not isinstance(args, dict):
        return []
    if name == 'tool_call':
        calls = args.get('calls')
        call = calls[0] if isinstance(calls, list) and len(calls) == 1 else args if calls is None else None
        if isinstance(call, dict) and call.get('name') in _SEND | _INBOX:
            return tool_messages(call['name'], call.get('arguments'), result,
                                 status=status, sender=sender, self_alias=self_alias)
        return []
    if name in _SEND:
        native = name == 'c2c_send'
        keys = ('to', 'body') if native else ('to_alias', 'content')
        if not all(isinstance(args.get(key), str) for key in keys):
            return []
        return [send_message(args, result, native=native, sender=sender, status=status)]
    if name in _INBOX:
        return inbox_messages(result, self_alias)
    return []
