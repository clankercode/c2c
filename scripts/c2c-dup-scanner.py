#!/usr/bin/env python3
"""
c2c-dup-scanner: detect copy-pasted code blocks across .py/.ml/.mli files.

Usage:
    c2c-dup-scanner.py --repo <repo_path> [--summary|--full] [--warn-only] [--json]
    c2c-dup-scanner.py --repo . --summary --warn-only

Wired into c2c-doctor.sh like c2c-command-test-audit.py.
"""

import argparse
import hashlib
import os
import re
import sys
import json
from pathlib import Path
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed

# Parameters
WINDOW_TOKENS = 25  # tokens per hash window
MIN_MATCH_TOKENS = 25  # minimum window size to consider
MAX_GAP_TOKENS = 5  # max gap between matching windows in a cluster

# File patterns to scan
INCLUDE_EXTENSIONS = {".py", ".ml", ".mli"}
EXCLUDE_DIRS = {
    "_build", ".git", "node_modules", "vendor",
    ".pytest_cache", "__pycache__", ".mypy_cache",
    ".codex-probe-home", ".claude-w", ".claude-p", ".claude-workspace",
    ".neobeacon", ".ruff_cache", ".hypothesis",
    ".worktrees", ".c2c",
}
GENERATED_MARKERS = {"# GENERATED", "# DO NOT EDIT", "(* GENERATED", "(* DO NOT EDIT"}


def _remove_strings(line: str) -> str:
    """Remove all string literals from a Python source line, leaving code."""
    result = []
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        # Comment: skip to end of line
        if c == '#':
            break
        # Check for triple-quoted strings (f""" or """ or f''' or ''')
        if (i + 5 <= n and line[i:i+3] in ('f"""', '"""', "f'''", "'''")):
            delim = line[i:i+3]
            i += 3
            result.append(' STR ')
            # Find closing triple-quote
            end = i
            quote_count = 0
            while end < n:
                if line[end] == '\\':
                    end += 2
                    continue
                if line[end] == delim[0]:
                    quote_count += 1
                    end += 1
                    if quote_count == 3:
                        break
                else:
                    quote_count = 0
                    end += 1
            i = end
            continue
        if c in ('"', "'"):
            quote = c
            j = i + 1
            while j < n:
                if line[j] == '\\':
                    j += 2
                    continue
                if line[j] == quote:
                    i = j + 1
                    result.append(' STR ')
                    break
                j += 1
            else:
                result.append(c)
                i += 1
            continue
        result.append(c)
        i += 1
    return ''.join(result)


def tokenize_python(content: str) -> list[str]:
    """Tokenize Python: strip comments/strings, normalize whitespace."""
    lines = content.splitlines()
    tokens = []
    for line in lines:
        code_part = _remove_strings(line)
        code_part = re.sub(r'\s+', ' ', code_part).strip()
        if code_part:
            tokens.append(code_part)
    return tokens


def tokenize_ocaml(content: str) -> list[str]:
    """Tokenize OCaml: strip comments/strings, normalize whitespace."""
    # Remove block comments first
    content = re.sub(r'\(\*.*?\*\)', ' ', content, flags=re.DOTALL)
    lines = content.splitlines()
    tokens = []
    for line in lines:
        # Strip line comments
        code_part = line.split("(*")[0].split("(*")[0]  # already removed block
        # Remove string literals
        s = re.sub(r'"(?:[^"\\]|\\.)*"', ' STRING ', code_part)
        # Normalize whitespace
        s = re.sub(r'\s+', ' ', s).strip()
        if s:
            tokens.append(s)
    return tokens


def tokenize(content: str, ext: str) -> list[str]:
    if ext == ".py":
        return tokenize_python(content)
    else:
        return tokenize_ocaml(content)


def is_generated(content: str) -> bool:
    """Check if file contains generated code markers."""
    for marker in GENERATED_MARKERS:
        if marker in content:
            return True
    return False


def hash_window(window: list[str]) -> str:
    """Hash a token window using MD5 (fast, good enough for dedup)."""
    joined = " ".join(window)
    return hashlib.md5(joined.encode()).hexdigest()


def find_windows(tokens: list[str]) -> list[tuple[int, str]]:
    """Find all rolling hash windows of WINDOW_TOKENS tokens."""
    if len(tokens) < MIN_MATCH_TOKENS:
        return []
    windows = []
    for i in range(len(tokens) - WINDOW_TOKENS + 1):
        window = tokens[i:i + WINDOW_TOKENS]
        h = hash_window(window)
        windows.append((i, h))
    return windows


def token_to_line_mapping(tokens: list[str], content_lines: list[str]) -> dict[int, int]:
    """Map token index to approximate line number.
    This is an approximation since tokenization changes the content.
    We do it by counting tokens per line during tokenization.
    Returns: token_idx -> line_number (1-indexed)
    """
    mapping = {}
    token_idx = 0
    for line_no, line in enumerate(content_lines, 1):
        code_part = line.split("#")[0]
        code_part = code_part.split("(*")[0]
        s = re.sub(r'"(?:[^"\\]|\\.)*"', ' STRING ', code_part)
        s = re.sub(r'\s+', ' ', s).strip()
        n_tokens = len(s.split()) if s else 0
        for _ in range(n_tokens):
            if token_idx < len(tokens):
                mapping[token_idx] = line_no
                token_idx += 1
    return mapping


def scan_file(filepath: Path) -> dict | None:
    """Scan a single file for token windows. Returns file data dict or None."""
    try:
        content = filepath.read_text(errors="replace")
    except Exception:
        return None

    if is_generated(content):
        return None

    ext = filepath.suffix.lower()
    if ext not in INCLUDE_EXTENSIONS:
        return None

    tokens = tokenize(content, ext)
    windows = find_windows(tokens)

    content_lines = content.splitlines()
    # Approximate: each ~5 tokens corresponds to one line (rough heuristic)
    # Better: map token positions back to lines by re-tokenizing per line
    line_map = token_to_line_mapping(tokens, content_lines)

    return {
        "filepath": str(filepath),
        "tokens": tokens,
        "windows": windows,
        "line_map": line_map,
        "n_tokens": len(tokens),
    }


def find_clusters(file_datas: list[dict]) -> list[dict]:
    """Find clusters of duplicate windows across files."""
    # Build hash -> [(filepath, token_start, line_start), ...]
    hash_to_locations = defaultdict(list)
    for fd in file_datas:
        if fd is None:
            continue
        for token_start, h in fd["windows"]:
            line_start = fd["line_map"].get(token_start, 1)
            hash_to_locations[h].append((fd["filepath"], token_start, line_start))

    # Filter to hashes appearing in 2+ files
    clusters = []
    for h, locations in hash_to_locations.items():
        files_involved = set(loc[0] for loc in locations)
        if len(files_involved) >= 2:
            # Group consecutive windows into clusters
            # Sort by filepath then token_start
            locations.sort(key=lambda x: (x[0], x[1]))
            clusters.append({
                "hash": h,
                "locations": locations,
                "n_files": len(files_involved),
                "n_windows": len(locations),
                "files": list(files_involved),
            })

    # Merge clusters that share the same files AND have windows within MAX_GAP_TOKENS
    merged_clusters = []
    for cluster in sorted(clusters, key=lambda c: -c["n_windows"]):
        merged = False
        for mc in list(merged_clusters):
            if set(mc["files"]) != set(cluster["files"]):
                continue
            # Check if any window from cluster is within MAX_GAP of any window in mc
            cluster_starts = {loc[1] for loc in cluster["locations"]}
            mc_starts = {loc[1] for loc in mc["locations"]}
            for cs in cluster_starts:
                for ms in mc_starts:
                    if abs(cs - ms) <= MAX_GAP_TOKENS:
                        mc["locations"].extend(cluster["locations"])
                        mc["locations"].sort(key=lambda x: (x[0], x[1]))
                        mc["n_windows"] = len(mc["locations"])
                        merged = True
                        break
                if merged:
                    break
            if merged:
                break
        if not merged:
            merged_clusters.append(cluster)

    return merged_clusters


def merge_token_ranges(ranges: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """Merge overlapping/adjacent token ranges."""
    if not ranges:
        return []
    sorted_ranges = sorted(ranges)
    merged = [sorted_ranges[0]]
    for start, end in sorted_ranges[1:]:
        last_start, last_end = merged[-1]
        if start <= last_end + 1:  # overlapping or adjacent
            merged[-1] = (last_start, max(last_end, end))
        else:
            merged.append((start, end))
    return merged


def format_cluster_summary(cluster: dict, all_file_datas: dict) -> str:
    """Format a cluster as a readable summary."""
    files = cluster["files"]
    n_windows = cluster["n_windows"]

    # Estimate duplicate coverage using merged token ranges (avoids overlap inflation)
    file_ranges: dict[str, list[tuple[int, int]]] = {f: [] for f in files}
    for loc in cluster["locations"]:
        filepath, token_start, _ = loc
        file_ranges[filepath].append((token_start, token_start + WINDOW_TOKENS))

    # Compute union span per file
    total_dup_span = 0
    for f in files:
        merged = merge_token_ranges(file_ranges[f])
        total_dup_span += sum(end - start for start, end in merged)

    est_loc = total_dup_span // 4  # ~4 tokens per line

    # Similarity: union span vs smaller file's total tokens
    if len(files) == 2:
        loc0 = get_file_loc(files[0], all_file_datas) or 0
        loc1 = get_file_loc(files[1], all_file_datas) or 0
        smaller = min(loc0, loc1) if (loc0 or loc1) else 0
        if smaller > 0:
            sim = min(total_dup_span / max(smaller, 1), 1.0)
            sim_pct = int(sim * 100)
            sim_str = f"{sim_pct}%"
        else:
            sim_str = "?"
    else:
        sim_str = "?"

    file_names = [Path(f).name for f in files]
    files_str = ", ".join(file_names[:4])
    if len(files) > 4:
        files_str += f" (+{len(files)-4} more)"

    return (f"  [{est_loc} dup LOC] {files_str}  ({n_windows} windows, {sim_str} similar)")


def get_file_loc(filepath: str, all_file_datas: dict) -> int | None:
    """Get total tokens/LOC for a file."""
    for fd in all_file_datas:
        if fd and fd["filepath"] == filepath:
            return fd["n_tokens"] // 4
    return None


def run_scanner(repo_path: str, summary: bool, full: bool, warn_only: bool, json_output: bool) -> int:
    """Run the duplication scanner."""
    repo = Path(repo_path)
    if not repo.exists():
        print(f"error: repo not found: {repo_path}", file=sys.stderr)
        return 1

    # Find all files
    files_to_scan = []
    for root, dirs, files in os.walk(repo):
        # Prune excluded dirs
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
        for f in files:
            if Path(f).suffix.lower() in INCLUDE_EXTENSIONS:
                files_to_scan.append(Path(root) / f)

    if not files_to_scan:
        print("no .py/.ml/.mli files found", file=sys.stderr)
        return 0

    # Scan files in parallel
    file_datas = []
    with ThreadPoolExecutor() as executor:
        futures = {executor.submit(scan_file, fp): fp for fp in files_to_scan}
        for future in as_completed(futures):
            try:
                result = future.result()
                file_datas.append(result)
            except Exception as e:
                pass  # skip files that error

    # Find clusters
    clusters = find_clusters(file_datas)

    if json_output:
        output = {
            "n_clusters": len(clusters),
            "total_dup_windows": sum(c["n_windows"] for c in clusters),
            "clusters": [
                {
                    "files": c["files"],
                    "n_windows": c["n_windows"],
                    "locations": [
                        {"file": loc[0], "token_start": loc[1], "line_start": loc[2]}
                        for loc in c["locations"]
                    ],
                }
                for c in clusters
            ],
        }
        print(json.dumps(output, indent=2))
        return 0

    if not clusters:
        if summary or full:
            print("no duplication clusters found")
        return 0

    # Sort clusters by total wasted LOC (n_windows * WINDOW_TOKENS / 4)
    clusters.sort(key=lambda c: -(c["n_windows"] * WINDOW_TOKENS // 4))

    if summary:
        total_dup_loc = sum(c["n_windows"] * WINDOW_TOKENS // 4 for c in clusters)
        print(f"{len(clusters)} duplication cluster(s) found (~{total_dup_loc} total duplicate LOC)")

    if full:
        print(f"\n{'='*60}")
        print(f"CODE DUPLICATION SCAN — {len(files_to_scan)} files scanned")
        print(f"{'='*60}\n")
        for i, cluster in enumerate(clusters, 1):
            print(f"CLUSTER {i}:")
            print(format_cluster_summary(cluster, file_datas))
            print()

    if warn_only:
        return 0

    return 1 if clusters else 0


def main():
    parser = argparse.ArgumentParser(
        description="Detect copy-pasted code blocks across .py/.ml/.mli files"
    )
    parser.add_argument(
        "--repo",
        required=True,
        help="Path to the repository to scan",
    )
    parser.add_argument(
        "--summary",
        action="store_true",
        help="Print summary only (cluster count + total dup LOC)",
    )
    parser.add_argument(
        "--full",
        action="store_true",
        help="Print full report with all clusters and file details",
    )
    parser.add_argument(
        "--warn-only",
        action="store_true",
        help="Exit 0 always; warnings go to stderr",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Machine-readable JSON output",
    )
    args = parser.parse_args()

    if not args.summary and not args.full and not args.json:
        args.summary = True  # default to summary mode

    exit_code = run_scanner(
        args.repo,
        summary=args.summary,
        full=args.full,
        warn_only=args.warn_only,
        json_output=args.json,
    )

    if args.warn_only:
        return 0
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
