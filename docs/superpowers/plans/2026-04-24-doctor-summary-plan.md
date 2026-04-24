# c2c doctor --summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--summary` flag to `scripts/c2c-doctor.sh` that produces compact ACTION REQUIRED output with FIX NOW / COORDINATOR / ALL CLEAR sections and inline remediation hints.

**Architecture:** Single-flag addition to existing shell script; `c2c health` output is captured once and parsed for both full and summary modes. No OCaml changes needed.

**Tech Stack:** Bash, `c2c health` JSON/text output parsing.

---

## Task 1: Add `--summary` flag and restructure output sections

**File:** `scripts/c2c-doctor.sh`

- [ ] **Step 1: Read the current c2c-doctor.sh into memory and identify all section boundaries**

Run: `wc -l scripts/c2c-doctor.sh` (188 lines total, already read above)

- [ ] **Step 2: Add `--summary` flag parsing and `SUMMARY=0/1` variable at top of script**

After line 9 (`JSON=0`), add:
```bash
SUMMARY=0
[[ "${1:-}" == "--summary" ]] && SUMMARY=1 && shift
[[ "${1:-}" == "--json" ]] && JSON=1 && shift
```

- [ ] **Step 3: Add icon variables after existing color functions (after line 16)**

```bash
FIX_CHAR="✗"
COORD_CHAR="⚠"
OK_CHAR="✓"
CLEAR_CHAR="–"
```

- [ ] **Step 4: Capture health output once at top of script (after flag parsing, before any echo)**

Add after line 16 (color functions):
```bash
# Capture health output once for both full and summary modes
HEALTH_OUTPUT=$(c2c health 2>&1 || true)
```

- [ ] **Step 5: Replace the "1. Health" section (lines 18-25) with conditional output**

Replace lines 18-25:
```bash
# ---------------------------------------------------------------------------
# 1. Health
# ---------------------------------------------------------------------------
if [[ $SUMMARY -eq 1 ]]; then
  # Summary mode: only show non-OK checks inline in ACTION REQUIRED block
  :
else
  echo ""
  bold "=== c2c health ==="
  echo ""
  echo "$HEALTH_OUTPUT"
  echo ""

  bold "=== managed instances ==="
  echo ""
  c2c instances 2>&1 || true
  echo ""
fi
```

- [ ] **Step 6: After the commit classification block (after line 132), add the SUMMARY output block**

Add before line 134 (the "3. Verdict" section):
```bash
# ---------------------------------------------------------------------------
# Summary mode: ACTION REQUIRED block
# ---------------------------------------------------------------------------
if [[ $SUMMARY -eq 1 ]]; then
  echo ""
  bold "=== ACTION REQUIRED ==="
  echo ""

  # Classify health checks from HEALTH_OUTPUT
  # Parse lines like: "  ✓ relay: reachable" or "  ✗ broker root: false"
  FIX_ITEMS=()
  CLEAR_ITEMS=()
  HEALTH_PASS_COUNT=0
  HEALTH_TOTAL_COUNT=0

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Count all check lines (lines with leading spaces and status char)
    if [[ "$line" =~ ^[[:space:]]+[✓⚠✗–].* ]]; then
      HEALTH_TOTAL_COUNT=$((HEALTH_TOTAL_COUNT + 1))
      # Strip leading spaces to get icon + rest
      stripped="${line#"${line%%[![:space:]]*}"}"
      icon="${stripped:0:1}"
      rest="${stripped:1}"
      case "$icon" in
        ✓)
          HEALTH_PASS_COUNT=$((HEALTH_PASS_COUNT + 1))
          item=$(echo "$rest" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
          [[ -n "$item" ]] && CLEAR_ITEMS+=("$item")
          ;;
        ⚠) CLEAR_ITEMS+=("$rest") ;;
        ✗) FIX_ITEMS+=("$rest") ;;
      esac
    fi
  done <<< "$HEALTH_OUTPUT"

  # Extract relay stale status
  RELAY_STALE=0
  if echo "$HEALTH_OUTPUT" | grep -q "stale deploy"; then
    RELAY_STALE=1
  fi

  # Extract dead registrations
  DEAD_REGS=""
  DEAD_COUNT=0
  if echo "$HEALTH_OUTPUT" | grep -qE "registrations:.*dead"; then
    DEAD_REGS=$(echo "$HEALTH_OUTPUT" | grep "registrations:" | grep -oE "[0-9]+ dead" | grep -oE "[0-9]+")
    [[ -n "$DEAD_REGS" ]] && DEAD_COUNT=$DEAD_REGS
  fi

  # Extract /tmp space
  TMP_LOW=""
  if echo "$HEALTH_OUTPUT" | grep -qE "/tmp.*low|/tmp.*[0-9]+MB"; then
    TMP_LOW=$(echo "$HEALTH_OUTPUT" | grep -i "/tmp" | sed 's/^[[:space:]]*//')
  fi

  # Print FIX NOW
  if [[ ${#FIX_ITEMS[@]} -gt 0 || $DEAD_COUNT -gt 0 || -n "$TMP_LOW" ]]; then
    printf "  $FIX_CHAR FIX NOW:  " >&2
    first=1
    if [[ $DEAD_COUNT -gt 0 ]]; then
      printf "%d dead registration%s" "$DEAD_COUNT" "$([ $DEAD_COUNT -eq 1 ] && echo "" || echo "s")" >&2
      printf " (→ run: c2c sweep)" >&2
      first=0
    fi
    if [[ -n "$TMP_LOW" ]]; then
      [[ $first -eq 0 ]] && printf "; " >&2
      printf "%s (→ free /tmp space)" "$TMP_LOW" >&2
      first=0
    fi
    for item in "${FIX_ITEMS[@]}"; do
      [[ $first -eq 0 ]] && printf "; " >&2
      printf "%s" "$item" >&2
      first=0
    done
    printf "\n" >&2
  fi

  # Print COORDINATOR
  if [[ ${#RELAY_CRITICAL[@]} -gt 0 && $RELAY_STALE -eq 1 ]]; then
    printf "  $COORD_CHAR COORDINATOR:  " >&2
    printf "relay-stale + %d relay-critical commit%s queued (push needed)" "${#RELAY_CRITICAL[@]}" "$([ ${#RELAY_CRITICAL[@]} -eq 1 ] && echo "" || echo "s")" >&2
    printf "\n" >&2
  elif [[ $RELAY_STALE -eq 1 ]]; then
    printf "  $COORD_CHAR COORDINATOR:  relay-stale but no relay-critical commits\n" >&2
  fi

  # Print ALL CLEAR
  printf "  $OK_CHAR ALL CLEAR:  " >&2
  has_clear=0
  if [[ $RELAY_STALE -eq 0 && ${#RELAY_CRITICAL[@]} -eq 0 ]]; then
    printf "relay current; " >&2
    has_clear=1
  fi
  if [[ $HEALTH_TOTAL_COUNT -gt 0 && $HEALTH_PASS_COUNT -eq $HEALTH_TOTAL_COUNT ]]; then
    printf "%d/%d health checks passing; " "$HEALTH_PASS_COUNT" "$HEALTH_TOTAL_COUNT" >&2
    has_clear=1
  elif [[ $HEALTH_TOTAL_COUNT -eq 0 ]]; then
    printf "no health checks; " >&2
    has_clear=1
  fi
  if [[ $DEAD_COUNT -eq 0 ]]; then
    printf "no dead registrations; " >&2
    has_clear=1
  fi
  # Remove trailing "; " if present
  printf "\n" >&2

  echo ""
  bold "=== HEALTH: ${HEALTH_PASS_COUNT}/${HEALTH_TOTAL_COUNT} checks passing ==="
  echo ""
  for item in "${FIX_ITEMS[@]}"; do
    printf "  %s\n" "$item"
  done
  if [[ $DEAD_COUNT -gt 0 ]]; then
    printf "  dead registrations: %d\n" "$DEAD_COUNT"
  fi
  echo ""

  bold "=== PUSH: ${#RELAY_CRITICAL[@]} relay-critical commits queued ==="
  echo ""
  for entry in "${RELAY_CRITICAL[@]}"; do
    sha="${entry%% *}"
    msg="${entry#* }"
    printf "  %s  %s\n" "$sha" "$msg"
  done
  if [[ ${#RELAY_CRITICAL[@]} -eq 0 ]]; then
    printf "  (none)\n"
  fi
  echo ""

  bold "=== managed instances ==="
  echo ""
  c2c instances 2>&1 || true
  echo ""

  exit 0
fi
```

- [ ] **Step 7: Verify the script still works in full mode (no --summary)**

Run: `bash scripts/c2c-doctor.sh 2>&1 | head -30`
Expected: Full verbose output starting with "=== c2c health ==="

- [ ] **Step 8: Test --summary mode**

Run: `bash scripts/c2c-doctor.sh --summary 2>&1`
Expected: ACTION REQUIRED block with FIX NOW / COORDINATOR / ALL CLEAR sections

- [ ] **Step 9: Verify --json still works**

Run: `bash scripts/c2c-doctor.sh --json | head -5`
Expected: JSON output (unchanged)

- [ ] **Step 10: Commit**

```bash
git add scripts/c2c-doctor.sh
git commit -m "feat: add --summary mode to c2c doctor for actionable operator output"
```

---

## Task 2: Smoke-test the implementation

**Files:** `scripts/c2c-doctor.sh`

- [ ] **Step 1: Test with no args (full mode unchanged)**

Run: `bash scripts/c2c-doctor.sh 2>&1 | grep -E "^(===|✓|✗|⚠)" | head -20`
Expected: Section headers and check icons

- [ ] **Step 2: Test --summary output structure**

Run: `bash scripts/c2c-doctor.sh --summary 2>&1 | grep -E "^(===|  (✗|⚠|✓))"`
Expected: ACTION REQUIRED, HEALTH, PUSH, managed instances sections with correct icons

- [ ] **Step 3: Commit**

```bash
git add scripts/c2c-doctor.sh
git commit -m "test: smoke-test c2c doctor --summary"
```
