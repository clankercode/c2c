#!/usr/bin/env bash
# audit-staleness-check.sh — verify audit doc findings haven't already landed on master
# Usage: ./scripts/audit-staleness-check.sh [--json] <audit-doc-path>
# Exits 0 if no stale refs, 1 if stale refs detected.
# Set AUDIT_BASE env var to override the default base branch (default: origin/master).

set -euo pipefail

JSON=0
audit_doc=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1; shift ;;
    -*) echo "Usage: $0 [--json] <audit-doc-path>" >&2; exit 1 ;;
    *) audit_doc="$1"; shift ;;
  esac
done

if [[ -z "$audit_doc" ]]; then
  echo "Usage: $0 [--json] <audit-doc-path>" >&2
  exit 1
fi
if [[ ! -f "$audit_doc" ]]; then
  echo "Error: file not found: $audit_doc" >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

# Default base is origin/master — prevents false-OK when run from a slice branch.
BASE="${AUDIT_BASE:-origin/master}"

sha_pattern='[0-9a-f]{7,40}'
stale=0
sha_json="["
sha_first=1
issue_json="["
issue_first=1
fileref_json="["
fileref_first=1

append_sha() {
  local sha="$1"; local status="$2"; local subject="${3:-}"
  if [[ $JSON -eq 1 ]]; then
    [[ $sha_first -eq 1 ]] && sha_first=0 || sha_json+=","
    sha_json+=$'\n'"      {\"sha\": \"$sha\", \"status\": \"$status\""
    [[ -n "${subject:-}" ]] && sha_json+=", \"subject\": \"$subject\""
    sha_json+="}"
  fi
}

append_issue() {
  local num="$1"; local status="$2"; local detail="${3:-}"
  if [[ $JSON -eq 1 ]]; then
    [[ $issue_first -eq 1 ]] && issue_first=0 || issue_json+=","
    issue_json+=$'\n'"      {\"issue\": \"#$num\", \"status\": \"$status\""
    [[ -n "$detail" ]] && issue_json+=", \"detail\": \"$detail\""
    issue_json+="}"
  fi
}

append_fileref() {
  local ref="$1"; local status="$2"
  if [[ $JSON -eq 1 ]]; then
    [[ $fileref_first -eq 1 ]] && fileref_first=0 || fileref_json+=","
    fileref_json+=$'\n'"      {\"ref\": \"$ref\", \"status\": \"$status\"}"
  fi
}

log() { [[ $JSON -eq 0 ]] && echo "$@" || true; }

log "=== audit-staleness-check: $audit_doc ==="
log "base: $BASE"
log ""

# ── 1. SHA refs (with cherry-pick detection) ────────────────────────────────
sha_pattern='[0-9a-f]{7,40}'
log "--- Commit SHAs ---"
shas=$(grep -oP "(?<![0-9a-f])${sha_pattern}(?![0-9a-f])" "$audit_doc" \
       | grep -E '^[0-9a-f]{7,}$' | sort -u) || true

if [[ -z "$shas" ]]; then
  log "(none found)"
  sha_json="[]"
else
  sha_json="["
  sha_first=1
  while IFS= read -r sha; do
    # Step 1: ancestor check (cheap)
    if git merge-base --is-ancestor "$sha" "$BASE" 2>/dev/null; then
      subject=$(git log -1 --format='%s' "$sha" 2>/dev/null | cut -c1-60 || echo "?")
      log "  [ALREADY LANDED]      $sha — $subject"
      stale=1
      append_sha "$sha" "ALREADY_LANDED" "$subject"
    else
      # Step 2: cherry-pick detection — search origin/master for same subject line
      subject=$(git log -1 --format='%s' "$sha" 2>/dev/null | cut -c1-60 || echo "")
      landed=0
      if [[ -n "$subject" ]]; then
        # Escape subject for literal grep (handles parentheses, regex chars in commit msgs)
        subject_esc=$(printf '%s' "$subject" | sed 's/[[\.*+?^${}()|\\]/\\&/g')
        if git log --format='%s' "$BASE" 2>/dev/null | grep -qF -- "$subject_esc"; then
          log "  [LANDED VIA CHERRY-PICK] $sha — '$subject'"
          stale=1
          landed=1
          append_sha "$sha" "LANDED_VIA_CHERRY_PICK" "$subject"
        fi
      fi
      if [[ $landed -eq 0 ]]; then
        log "  [NOT YET LANDED]    $sha"
        append_sha "$sha" "NOT_YET_LANDED" ""
      fi
    fi
  done <<< "$shas"
  sha_json+=$'\n    ]'
fi

# ── 2. Issue/PR refs (word-boundary) ────────────────────────────────────────
log ""
log "--- Issue/PR refs ---"
issues=$(grep -oP '(?<!\w)#\d+' "$audit_doc" | grep -oP '\d+' | sort -u) || true

if [[ -z "$issues" ]]; then
  log "(none found)"
  issue_json="[]"
else
  issue_json="["
  issue_first=1
  while IFS= read -r num; do
    commit=$(git log --all --oneline \
             -E --since="90 days ago" \
             --grep="\(fix\|feat\|chore\|refactor\)#${num}\b\|(#${num})" \
             HEAD 2>/dev/null | head -1)
    if [[ -n "$commit" ]]; then
      detail=$(echo "$commit" | cut -c1-60)
      log "  [POSSIBLY ADDRESSED] #$num — $commit"
      stale=1
      append_issue "$num" "POSSIBLY_ADDRESSED" "$detail"
    else
      log "  [NO MATCH]         #$num"
      append_issue "$num" "NO_MATCH" ""
    fi
  done <<< "$issues"
  issue_json+=$'\n    ]'
fi

# ── 3. File:line refs ─────────────────────────────────────────────────────
log ""
log "--- File:line refs ---"
filerefs=$(grep -oP '\b[a-zA-Z0-9_./-]+\.ml:\d+' "$audit_doc" | sort -u) || true

if [[ -z "$filerefs" ]]; then
  log "(none found)"
  fileref_json="[]"
else
  fileref_json="["
  fileref_first=1
  while IFS= read -r ref; do
    file="${ref%:*}"
    line="${ref#*:}"
    if [[ -f "$file" ]]; then
      current=$(sed -n "${line}p" "$file" 2>/dev/null | tr -d '\n' | cut -c1-70)
      if [[ -n "$current" ]]; then
        log "  [OK]       $ref: $current"
        append_fileref "$ref" "OK"
      else
        log "  [EMPTY]    $ref (line may be beyond EOF)"
        append_fileref "$ref" "EMPTY"
      fi
    else
      log "  [FILE MISSING] $ref (may be from a different branch)"
      append_fileref "$ref" "FILE_MISSING"
    fi
  done <<< "$filerefs"
  fileref_json+=$'\n    ]'
fi

log ""
if [[ $JSON -eq 1 ]]; then
  stale_str=$([[ $stale -eq 1 ]] && echo 'true' || echo 'false')
  printf '{"stale":%s,"path":"%s","base":"%s","shas":%s,"issues":%s,"filerefs":%s}\n' \
    "$stale_str" "$audit_doc" "$BASE" "$sha_json" "$issue_json" "$fileref_json"
fi

if [[ $stale -eq 1 ]]; then
  log "Result: STALE REFS — some findings may already be resolved."
  exit 1
else
  log "Result: no stale refs detected."
  exit 0
fi
