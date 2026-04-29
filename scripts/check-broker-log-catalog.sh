#!/usr/bin/env bash
# check-broker-log-catalog.sh — enforce broker-log-events.md completeness
#
# FAIL conditions:
#   - any `"event", `String "<name>"` emitter in ocaml/ (excluding tests
#     + the explicit out-of-scope allow-list below) is missing a catalog
#     entry in .collab/runbooks/broker-log-events.md
#   - WARN (rc=0): a catalog entry has no corresponding emitter in
#     ocaml/ (catalog drift; possibly removed event)
#
# Usage:
#   ./scripts/check-broker-log-catalog.sh        # check + report
#   ./scripts/check-broker-log-catalog.sh --json # machine-readable
#
# Exit:
#   0  catalog complete (no missing emitters)
#   1  missing emitters (CI gate)
#   2  internal error (catalog file not found, etc.)
#
# Wired into `just check` via dune rule (see ocaml/dune).
#
# See:
#   .collab/runbooks/broker-log-events.md  — the catalog itself
#   #442  — slice that introduced this guard

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

CATALOG=".collab/runbooks/broker-log-events.md"
OUTPUT_JSON=0
[[ "${1:-}" == "--json" ]] && OUTPUT_JSON=1

if [[ ! -f "$CATALOG" ]]; then
  echo "error: catalog not found at $CATALOG" >&2
  exit 2
fi

# ── Out-of-scope allow-list ──────────────────────────────────────────────────
# Events that emit "event": "<name>" but write to a DIFFERENT log file
# (not broker.log). Kept short + audited; updates require a catalog
# "Out of scope" section update in the same slice.
declare -A OUT_OF_SCOPE=(
  ["named.checkpoint"]="c2c.ml:9089 — c2c session-restoration checkpoint"
  ["state.snapshot"]="c2c_inbox_hook.ml:125 — claude-code state snapshot"
)

# ── Step 1: emitter names from ocaml/ (production code only, exclude tests) ─
mapfile -t emitters < <(
  grep -rohP '"event", `String "[^"]+"' ocaml/ \
    --exclude-dir=test --exclude="test_*.ml" 2>/dev/null \
    | grep -oP 'String "\K[^"]+' \
    | sort -u
)

# ── Step 2: cataloged names (### `name` headers) ───────────────────────────
mapfile -t cataloged < <(
  grep -oP '^### `\K[^`]+' "$CATALOG" \
    | sort -u
)

# ── Step 3: diff ────────────────────────────────────────────────────────────
missing=()       # in source, not in catalog (FAIL unless allow-listed)
oos_seen=()      # in source, allow-listed (info)
stale=()         # in catalog, not in source (WARN)

for e in "${emitters[@]}"; do
  if [[ -n "${OUT_OF_SCOPE[$e]:-}" ]]; then
    oos_seen+=("$e")
    continue
  fi
  if ! printf '%s\n' "${cataloged[@]}" | grep -qxF "$e"; then
    missing+=("$e")
  fi
done

for c in "${cataloged[@]}"; do
  if ! printf '%s\n' "${emitters[@]}" | grep -qxF "$c"; then
    stale+=("$c")
  fi
done

# ── Step 4: emit report ─────────────────────────────────────────────────────
if [[ $OUTPUT_JSON -eq 1 ]]; then
  # JSON output for CI / programmatic consumers.
  printf '{\n'
  printf '  "ok": %s,\n' "$([[ ${#missing[@]} -eq 0 ]] && echo true || echo false)"
  printf '  "emitter_count": %d,\n' "${#emitters[@]}"
  printf '  "cataloged_count": %d,\n' "${#cataloged[@]}"
  printf '  "missing": ['
  for i in "${!missing[@]}"; do
    [[ $i -gt 0 ]] && printf ', '
    printf '"%s"' "${missing[$i]}"
  done
  printf '],\n'
  printf '  "stale": ['
  for i in "${!stale[@]}"; do
    [[ $i -gt 0 ]] && printf ', '
    printf '"%s"' "${stale[$i]}"
  done
  printf '],\n'
  printf '  "out_of_scope_seen": ['
  for i in "${!oos_seen[@]}"; do
    [[ $i -gt 0 ]] && printf ', '
    printf '"%s"' "${oos_seen[$i]}"
  done
  printf ']\n'
  printf '}\n'
else
  echo "=== broker.log catalog completeness check ==="
  echo "Source emitters:    ${#emitters[@]} (excluding tests)"
  echo "Cataloged events:   ${#cataloged[@]}"
  echo "Out-of-scope list:  ${#OUT_OF_SCOPE[@]}"
  echo ""

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "❌ FAIL: ${#missing[@]} emitter(s) missing catalog entry:"
    for e in "${missing[@]}"; do
      echo "   - $e"
    done
    echo ""
    echo "   Add a per-event entry to $CATALOG"
    echo "   following the ### \`<name>\` heading convention."
    echo ""
  fi

  if [[ ${#stale[@]} -gt 0 ]]; then
    echo "⚠️  WARN: ${#stale[@]} cataloged event(s) with no source emitter:"
    for c in "${stale[@]}"; do
      echo "   - $c"
    done
    echo "   (catalog drift; verify the event was intentionally removed)"
    echo ""
  fi

  if [[ ${#oos_seen[@]} -gt 0 ]]; then
    echo "ℹ️  out-of-scope (allow-listed): ${#oos_seen[@]}"
    for e in "${oos_seen[@]}"; do
      echo "   - $e (${OUT_OF_SCOPE[$e]})"
    done
    echo ""
  fi

  if [[ ${#missing[@]} -eq 0 ]]; then
    echo "✅ catalog complete."
  fi
fi

exit $([[ ${#missing[@]} -eq 0 ]] && echo 0 || echo 1)
