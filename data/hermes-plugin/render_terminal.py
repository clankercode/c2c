"""Literal TUI/CLI cards. No Rich/Markdown dependency; ANSI is optional."""

import os
import sys

from .message_style import visible


def supports_ansi(stream=None):
    stream = sys.stdout if stream is None else stream
    try:
        tty = getattr(stream, 'isatty', lambda: False)()
    except (OSError, ValueError):
        tty = False
    return (tty and os.environ.get('TERM', '') not in ('', 'dumb')
            and 'NO_COLOR' not in os.environ and os.environ.get('C2C_HERMES_PLAIN') != '1')


def render(message, *, ansi=False):
    """All body lines (including empty/trailing lines) have a literal-data gutter."""
    heading, status = message.heading, message.status
    metadata = ' | '.join(f'{key}={value}' for key, value in message.metadata)
    if ansi:
        color = '31' if message.state == 'error' else '33' if message.state != 'incoming' else '36'
        heading = f'\x1b[1;36m{heading}\x1b[0m'
        status = f'\x1b[{color}m{status}\x1b[0m'
        metadata = f'\x1b[2m{metadata}\x1b[0m' if metadata else ''
    prefix = [heading, status]
    if metadata:
        prefix.append(metadata)
    prefix.append('Attempted body (literal):' if message.state in ('error', 'unknown') else 'Body (literal):')
    gutter = '\x1b[2m|\x1b[0m ' if ansi else '| '
    prefix.extend(gutter + line for line in visible(message.body).split('\n'))
    return '\n'.join(prefix)
