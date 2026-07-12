#!/usr/bin/env bash
# c2c-post-install-restart-prompt.sh — after a successful `just install`,
# offer to run `c2c restart-stale` so running managed sessions pick up the
# freshly-installed binary (idea I010).
#
# Behaviour:
#   - Interactive TTY (stdin AND stderr are TTYs): show the dry-run report and,
#     if anything is actually stale, prompt [y/N]; on yes run `c2c restart-stale`.
#   - Non-interactive, or C2C_SKIP_RESTART_PROMPT=1: NEVER block — print the
#     explicit follow-up command instead (the opt-out for automation that
#     allocates a pseudo-TTY).
#   - Nothing stale/actionable: stay silent.
#
# This script never fails the install: the caller invokes it with `|| true`
# and it exits 0 on every path.
set -euo pipefail

hint() {
  echo "" >&2
  echo "[c2c] Running managed sessions still hold the OLD binary until restarted." >&2
  echo "[c2c] Pick up the new binary with:" >&2
  echo "" >&2
  echo "    c2c restart-stale        # dry-run first with: c2c restart-stale --dry-run" >&2
  echo "" >&2
}

c2c="$(command -v c2c || true)"
if [ -z "$c2c" ]; then
  # No installed c2c on PATH yet — can't classify; just point at the command.
  hint
  exit 0
fi

# Opt-out for automation (e.g. CI that allocates a pseudo-TTY).
if [ "${C2C_SKIP_RESTART_PROMPT:-0}" = "1" ]; then
  hint
  exit 0
fi

# What would restart-stale do? (Cheap: enumerate + classify, no process change.)
report="$("$c2c" restart-stale --dry-run 2>&1 || true)"

# Only speak up when there is genuinely stale/actionable work.
if ! printf '%s' "$report" | grep -qE 'would restart|manual: c2c restart'; then
  exit 0
fi

# Non-interactive: print the report + follow-up command, never prompt.
if [ ! -t 0 ] || [ ! -t 2 ]; then
  printf '%s\n' "$report" >&2
  hint
  exit 0
fi

# Interactive: show the report and ask.
printf '%s\n' "$report" >&2
printf '\n[c2c] Restart the stale managed sessions above now? [y/N] ' >&2
read -r ans || ans=""
case "$ans" in
  y | Y | yes | YES)
    "$c2c" restart-stale || true
    ;;
  *)
    hint
    ;;
esac
exit 0
