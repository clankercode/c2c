#!/bin/bash
# c2c command drift detector
# Compares help text command names against registered Cmdliner commands.
# Fails if help text mentions a command that doesn't exist.

set -e

# Extract TIER 2 command names from --help (help text uses ANSI bold, not backticks).
# The TIER 2 section ends at the "Tier 3 and 4 commands hidden" line.
TIER2_COMMANDS=$(c2c --help 2>&1 | \
  sed -n '/== TIER 2: LIFECYCLE/,/Tier 3 and 4 commands hidden/p' | \
  sed 's/\x1b\[[0-9;]*m/ /g' | \
  awk '{for(i=1;i<=NF;i++) if($i ~ /^[a-z]+-[a-z0-9_]+$/) print $i}' | \
  sort -u)

# Get registered commands — first field of each non-comment, non-empty line.
REGISTERED=$(c2c commands 2>/dev/null | awk 'NF && !/^#/ {print $1}' | grep -E '^[a-z][-a-z0-9_]*$' | sort -u)

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
