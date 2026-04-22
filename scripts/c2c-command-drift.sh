#!/bin/bash
# c2c command drift detector
# Compares help text command names against registered Cmdliner commands.
# Fails if help text mentions a command that doesn't exist.

set -e

HELP_TEXT=$(c2c --help 2>&1)

# Extract all bold command names from the help text (lines with == TIER == sections)
TIER2_COMMANDS=$(echo "$HELP_TEXT" | awk '/== TIER 2: LIFECYCLE/,/== TIER 3:/' | grep -oE '`[a-z][-a-z0-9_]+`' | tr -d '`' | sort -u)

# Get registered commands (excluding subcommands which use dashes-separated group names)
REGISTERED=$(c2c commands 2>/dev/null | grep -v "^#" | tr ' ' '\n' | grep -v "^$" | sort -u)

# Extract fake subcommand names (hyphenated names that are actually subcommands of groups)
FAKE_COMMANDS=$(echo "$TIER2_COMMANDS" | grep -E '^[a-z]+-[a-z]+(-[a-z]+)?$')

# Check each fake command against registered
DRIFT=0
for cmd in $FAKE_COMMANDS; do
    if ! echo "$REGISTERED" | grep -qx "$cmd"; then
        echo "DRIFT: help text mentions '$cmd' but '$cmd' is not a registered command" >&2
        echo "  (Did you mean 'c2c $(echo $cmd | sed 's/-/ /g')'?)" >&2
        DRIFT=1
    fi
done

if [ $DRIFT -eq 0 ]; then
    echo "OK: no command drift detected"
fi

exit $DRIFT
