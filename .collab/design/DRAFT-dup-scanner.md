# c2c-dup-scanner: copy-paste detection for c2c codebase

## Goal
Detect copy-pasted-with-tweaks code blocks across Python (.py) and OCaml (.ml/.mli) files in the c2c repo, wired into `c2c doctor`.

## Approach
**Token-based rolling hash** (Rabin-Karp). Tokenize files (strip whitespace/comments), use sliding window over tokens, hash each window. Blocks with identical hashes across files = copy-paste relationship.

## Design Decisions

### Scope
- Languages: `.py`, `.ml`, `.mli`
- Excludes:
  - `_build/`, `.git/`, `node_modules/`, `vendor/`
  - Files matching `.*\.txt` (data files)
  - Generated files (check for `# GENERATED` or `# DO NOT EDIT` markers)
  - Test fixtures with obvious placeholder patterns

### Parameters
- Window size: 25 tokens (enough to span a meaningful block, not just boilerplate)
- Min match threshold: 25 tokens must match across 2+ files
- Max gap between matching windows: 5 tokens (allows small tweaks within a block)
- Token types tracked separately per language to avoid false positives from different syntax having same tokens

### Tokenization
**Python**: strip `#` comments, `"`/`'''`/`"""` strings, normalize whitespace. Keep keywords, identifiers, operators.

**OCaml**: strip `(* *)` and `(*` block comments, `"` strings, normalize whitespace. Keep keywords, identifiers, operators.

### Output
- `--summary`: prints "N duplication cluster(s) found" + total wasted LOC
- `--full`: prints each cluster with file pairs, line ranges, similarity score
- `--json`: machine-readable output
- `--warn-only`: exit 0 always; warnings to stderr

### Integration with `c2c doctor`
Add to `c2c-doctor.sh` (like `c2c-command-test-audit.py`):
```bash
if [[ -x "$SCRIPT_DIR/c2c-dup-scanner.py" ]]; then
  "$SCRIPT_DIR/c2c-dup-scanner.py" --repo "$PWD" --summary --warn-only || true
fi
```

## Output Format
```
DUPLICATION CLUSTER 1 (47 tokens, ~15 LOC)
  ocaml/c2c_start.ml: lines 142-158
  ocaml/c2c_start.mli: lines 89-103
  similarity: 91%

DUPLICATION CLUSTER 2 (31 tokens, ~10 LOC)
  ocaml/c2c.ml: lines 2040-2060
  ocaml/cli/c2c_stats.ml: lines 330-348
  similarity: 78%
```

## Implementation Notes
- Pure Python, no new dependencies (use builtin `hashlib` for rolling hash)
- Process files in parallel via `concurrent.futures` for speed on large repos
- Cache tokenized files in memory during run (repo is small enough)
- Threshold: warn on 3+ token matches per cluster, no auto-fix
