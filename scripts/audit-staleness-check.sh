#!/usr/bin/env bash
# audit-staleness-check.sh — verify audit doc findings haven't already landed on master
# Usage: ./scripts/audit-staleness-check.sh <audit-doc-path>
# Exits 0 if all findings verified (or no refs found), 1 if stale refs detected.

set -euo pipefail

audit_doc="${1:-}"
if [[ -z "$audit_doc" ]]; then
  echo "Usage: $0 <audit-doc-path>" >&2
  exit 1
fi
if [[ ! -f "$audit_doc" ]]; then
  echo "Error: file not found: $audit_doc" >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

echo "=== audit-staleness-check: $audit_doc ==="
echo ""

# ── 1. SHA refs (7-40 hex) ──────────────────────────────────────────────────
sha_pattern='[0-9a-f]{7,40}'
stale=0

echo "--- Commit SHAs ---"
shas=$(grep -oP "(?<![0-9a-f])$sha_pattern(?![0-9a-f])" "$audit_doc" | grep -E '^[0-9a-f]{7,}$' | sort -u)
if [[ -z "$shas" ]]; then
  echo "(none found)"
else
  while IFS= read -r sha; do
    if git merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
      short=$(git log -1 --format='%s' "$sha" 2>/dev/null | cut -c1-60 || echo "?")
      echo "  [ALREADY LANDED] $sha — $short"
      stale=1
    else
      echo "  [NOT YET LANDED] $sha"
    fi
  done <<< "$shas"
fi

# ── 2. Issue / PR refs (#NNN) ────────────────────────────────────────────────
echo ""
echo "--- Issue/PR refs ---"
issues=$(grep -oP '(?<=fixes|closes|resolves|addresses)\s+#\d+' "$audit_doc" \
       | grep -oP '#\d+' | sort -u | tr -d '#')
if [[ -z "$issues" ]]; then
  echo "(none found)"
else
  # Check if any matching commit is on master (loose heuristic: commit msg mentions #NNN)
  while IFS= read -r num; do
    if git log --all --oneline --grep="#$num" HEAD 2>/dev/null | head -1 | grep -q .; then
      commit=$(git log --all --oneline --grep="#$num" HEAD 2>/dev/null | head -1)
      echo "  [POSSIBLY ADDRESSED] #$num — $commit"
      stale=1
    else
      echo "  [NO MATCH FOUND]  #$num"
    fi
  done <<< "$issues"
fi

# ── 3. File:line refs ────────────────────────────────────────────────────────
echo ""
echo "--- File:line refs ---"
filerefs=$(grep -oP '\b[a-zA-Z0-9_./-]+\.ml:\d+\b' "$audit_doc" | sort -u)
if [[ -z "$filerefs" ]]; then
  echo "(none found)"
else
  while IFS= read -r ref; do
    file="${ref%:*}"
    line="${ref#*:}"
    if [[ -f "$file" ]]; then
      current=$(sed -n "${line}p" "$file" 2>/dev/null | tr -d '\n' | cut -c1-70)
      if [[ -n "$current" ]]; then
        echo "  [OK] $ref: $current"
      else
        echo "  [EMPTY] $ref (line may be beyond EOF)"
      fi
    else
      echo "  [FILE NOT FOUND] $ref (may be from a different branch)"
    fi
  done <<< "$filerefs"
fi

echo ""
if [[ $stale -eq 1 ]]; then
  echo "Result: STALE REFS DETECTED — some findings may already be resolved on master."
  echo "Review the [ALREADY LANDED] / [POSSIBLY ADDRESSED] entries above."
  exit 1
else
  echo "Result: no stale refs detected. Findings are current."
  exit 0
fi
