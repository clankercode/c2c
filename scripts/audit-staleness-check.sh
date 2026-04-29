#!/usr/bin/env bash
# audit-staleness-check.sh — verify audit doc findings haven't already landed on master
# Usage: ./scripts/audit-staleness-check.sh [--json] <audit-doc-path>
# Exits 0 if no stale refs, 1 if stale refs detected.
# Set AUDIT_BASE env var to override the default base branch (default: origin/master).
# Set AUDIT_PATCH_ID_SCAN_LIMIT (default 500) to bound patch-id scan depth.
#
# SHA-staleness detection runs four passes per orphan SHA, fastest first:
#   1. ancestor check                — git merge-base --is-ancestor (cheapest)
#   2. cherry-pick `-x` trailer      — `(cherry picked from commit <SHA>)` exact substring
#   3. subject-line grep             — same %s on BASE
#   4. patch-id content-hash match   — survives subject rewrites + squash; expensive
# Stops at the first hit. Prints landed_at when steps 2/3/4 detect a cherry-pick.

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
  local sha="$1"; local status="$2"; local subject="${3:-}"; local landed_at="${4:-}"
  if [[ $JSON -eq 1 ]]; then
    [[ $sha_first -eq 1 ]] && sha_first=0 || sha_json+=","
    sha_json+=$'\n'"      {\"sha\": \"$sha\", \"status\": \"$status\""
    [[ -n "${subject:-}" ]] && sha_json+=", \"subject\": \"$subject\""
    [[ -n "${landed_at:-}" ]] && sha_json+=", \"landed_at\": \"$landed_at\""
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
  # Lazily-built cache of BASE patch-ids: "<patch-id> <BASE-SHA>" lines.
  # Built on first patch-id miss; reused across all stale SHAs in this run.
  base_patch_id_cache=""
  patch_scan_limit="${AUDIT_PATCH_ID_SCAN_LIMIT:-500}"

  build_base_patch_id_cache() {
    [[ -n "$base_patch_id_cache" ]] && return 0
    base_patch_id_cache=$(mktemp)
    # `git patch-id --stable` emits one "<patch-id> <commit-sha>" per piped commit.
    # We feed it the recent BASE history. Scope: tip..ancestor over patch_scan_limit.
    git log --format='%H' -n "$patch_scan_limit" "$BASE" 2>/dev/null \
      | while read -r base_sha; do
          git show --format='%H' "$base_sha" 2>/dev/null \
            | git patch-id --stable 2>/dev/null \
            | head -n1
        done > "$base_patch_id_cache" || true
  }

  while IFS= read -r sha; do
    # Step 1: ancestor check (cheap, exact)
    if git merge-base --is-ancestor "$sha" "$BASE" 2>/dev/null; then
      subject=$(git log -1 --format='%s' "$sha" 2>/dev/null | cut -c1-60 || echo "?")
      log "  [ALREADY LANDED]      $sha — $subject"
      stale=1
      append_sha "$sha" "ALREADY_LANDED" "$subject"
      continue
    fi

    subject=$(git log -1 --format='%s' "$sha" 2>/dev/null | cut -c1-60 || echo "")
    landed=0

    # Step 2: cherry-pick `-x` trailer match (cheap, exact).
    # `git cherry-pick -x` appends `(cherry picked from commit <40-char-SHA>)`.
    # Orphan SHA in audit doc may be 7-12 chars; the trailer SHA is full-length
    # so substring-match works. --grep --fixed-strings handles regex chars.
    landed_at=$(git log --format='%H' --fixed-strings \
                  --grep="cherry picked from commit ${sha}" "$BASE" 2>/dev/null \
                | head -1)
    if [[ -n "$landed_at" ]]; then
      log "  [LANDED VIA CHERRY-PICK -x] $sha → ${landed_at:0:12} — '$subject'"
      stale=1
      landed=1
      append_sha "$sha" "LANDED_VIA_CHERRY_PICK_TRAILER" "$subject" "$landed_at"
    fi

    # Step 3: subject-line grep (existing — catches plain `cherry-pick` w/o `-x`).
    if [[ $landed -eq 0 && -n "$subject" ]]; then
      subject_esc=$(printf '%s' "$subject" | sed 's/[[\.*+?^${}()|\\]/\\&/g')
      landed_at=$(git log --format='%H %s' "$BASE" 2>/dev/null \
                  | grep -F -- "$subject_esc" | head -1 | awk '{print $1}') || true
      if [[ -n "$landed_at" ]]; then
        log "  [LANDED VIA CHERRY-PICK] $sha → ${landed_at:0:12} — '$subject'"
        stale=1
        landed=1
        append_sha "$sha" "LANDED_VIA_CHERRY_PICK" "$subject" "$landed_at"
      fi
    fi

    # Step 4: patch-id content-hash match (expensive — survives subject rewrites + squash).
    # Only run when steps 1-3 missed. Cache BASE patch-ids on first hit.
    if [[ $landed -eq 0 ]]; then
      orphan_pid=$(git show --format='%H' "$sha" 2>/dev/null \
                   | git patch-id --stable 2>/dev/null \
                   | awk '{print $1}' | head -1)
      if [[ -n "$orphan_pid" ]]; then
        build_base_patch_id_cache
        landed_at=$(grep "^${orphan_pid} " "$base_patch_id_cache" 2>/dev/null \
                    | head -1 | awk '{print $2}') || true
        if [[ -n "$landed_at" ]]; then
          log "  [LANDED VIA PATCH-ID]   $sha → ${landed_at:0:12} — '$subject'"
          stale=1
          landed=1
          append_sha "$sha" "LANDED_VIA_PATCH_ID" "$subject" "$landed_at"
        fi
      fi
    fi

    if [[ $landed -eq 0 ]]; then
      log "  [NOT YET LANDED]    $sha"
      append_sha "$sha" "NOT_YET_LANDED" ""
    fi
  done <<< "$shas"
  sha_json+=$'\n    ]'
  # Clean up patch-id cache if built.
  [[ -n "$base_patch_id_cache" && -f "$base_patch_id_cache" ]] && rm -f "$base_patch_id_cache"
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
