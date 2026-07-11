#!/usr/bin/env python3
"""Lightweight docs-command harness for docs/connect.md (friction slice D1).

Verifies that every `c2c ...` invocation shown in docs/connect.md names a real
subcommand / relay subcommand / enum leaf, by deriving the valid command paths
from the actual binary's `--help` output — NOT a hand-maintained list.

It catches the class of drift where a doc shows a plausible-but-nonexistent
subcommand (e.g. `c2c relay rooms knock`, which is a relay *server route* but is
not exposed on the `c2c relay rooms` CLI).

Validation depth (command tokens only — trailing positional args like aliases
are not checked):
  * `c2c <top>`                     -> <top> must be a real top-level subcommand
  * `c2c relay <sub>`               -> <sub> must be a real relay subcommand
  * `c2c relay rooms <enum>`        -> <enum> in the rooms positional enum
  * `c2c relay dm <enum>`           -> <enum> in the dm positional enum
  * `c2c relay identity <sub>`      -> <sub> in the identity subcommands

Convention this relies on: connect.md writes the subcommand BEFORE any flags
(e.g. `c2c relay dm poll --alias ...`), so leading non-flag tokens are the
command path. Extraction stops at the first token that starts with '-' or a quote.

Usage:  scripts/check-connect-commands.py [--bin PATH] [--doc PATH]
Exit 0 = all commands valid; exit 1 = one or more invalid (or setup error).
"""
import argparse
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DOC = os.path.join(REPO, "docs", "connect.md")
DEFAULT_BIN_CANDIDATES = [
    os.path.join(REPO, "_build", "default", "ocaml", "cli", "c2c.exe"),
    "c2c",
]

# relay subcommands that take a positional-enum first arg (not cmdliner subcommands).
ENUM_LEAF = {"rooms", "dm"}
# relay subcommands that are real cmdliner subcommand groups.
SUBGROUP = {"identity"}

ANSI = re.compile(r"\x1b\[[0-9;]*m")
# A COMMANDS-section entry: indented, lowercase name, then whitespace and the
# start of a synopsis — '[' (optional args/COMMAND), '--' (required flag, e.g.
# `register --alias=ALIAS`), or '<' (positional). Matches `connect [OPTION]…`,
# `dm [--alias=…]`, `identity [COMMAND] …`, `register --alias=ALIAS …`; does NOT
# match the enum line `send|poll|peek|send-all` (no whitespace before '|').
CMD_ENTRY = re.compile(r"^\s{4,}([a-z][a-z0-9-]*)\s+(?:\[|--|<)")


def _strip(text):
    return ANSI.sub("", text)


def run_help(binary, path_tokens):
    """Return ANSI-stripped stdout+stderr of `<binary> <path...> --help`."""
    try:
        p = subprocess.run(
            [binary, *path_tokens, "--help=plain"],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, "COLUMNS": "200", "TERM": "dumb"},
        )
        return _strip(p.stdout + p.stderr)
    except Exception as e:  # pragma: no cover - defensive
        return f"__ERR__ {e}"


def top_level_commands(binary):
    """Enumerate top-level subcommands from the 'Must be one of ...' error."""
    p = subprocess.run(
        [binary, "zzz-not-a-real-command"],
        capture_output=True, text=True, timeout=30,
        env={**os.environ, "TERM": "dumb"},
    )
    text = _strip(p.stdout + p.stderr)
    m = re.search(r"Must be one of\s+(.+?)(?:\n\n|\Z)", text, re.S)
    if not m:
        return set()
    blob = m.group(1)
    # tokens are comma/whitespace/'or'-separated identifiers
    toks = re.findall(r"[a-z][a-z0-9-]*", blob.replace(" or ", " "))
    return set(toks)


def _commands_section(binary, path_tokens):
    """Parse names from the COMMANDS section of a (sub)command's --help."""
    text = run_help(binary, path_tokens)
    cmds = set()
    in_cmds = False
    for line in text.splitlines():
        if re.match(r"^[A-Z][A-Z ]+$", line.strip()):
            in_cmds = line.strip() == "COMMANDS"
            continue
        if in_cmds:
            m = CMD_ENTRY.match(line)
            if m:
                cmds.add(m.group(1))
    return cmds


def relay_subcommands(binary):
    """Parse the COMMANDS section of `c2c relay --help`."""
    return _commands_section(binary, ["relay"])


def enum_from_synopsis(binary, path_tokens):
    """Extract an `a|b|c` positional enum from a command's --help text."""
    text = run_help(binary, path_tokens)
    best = set()
    for m in re.finditer(r"([a-z][a-z0-9-]*(?:\|[a-z][a-z0-9-]*)+)", text):
        parts = set(m.group(1).split("|"))
        if len(parts) > len(best):
            best = parts
    return best


def extract_command_lines(doc_path):
    """Yield token lists for each `c2c ...` invocation inside code fences."""
    out = []
    in_fence = False
    with open(doc_path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if line.lstrip().startswith("```"):
                in_fence = not in_fence
                continue
            if not in_fence:
                continue
            stripped = line.strip()
            # allow leading env-var assignments: FOO=bar c2c ...
            m = re.search(r"(?:^|\s)c2c\s+(.*)$", stripped)
            if not m:
                continue
            if stripped.startswith("#"):
                continue
            rest = m.group(1)
            # leading command-path tokens: stop at first flag / quote / pipe / redirect
            tokens = []
            for tok in rest.split():
                if tok.startswith("-") or tok[0] in "\"'|$<>&`":
                    break
                tokens.append(tok)
            if tokens:
                out.append((stripped, tokens))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin")
    ap.add_argument("--doc", default=DEFAULT_DOC)
    args = ap.parse_args()

    binary = args.bin
    if not binary:
        for cand in DEFAULT_BIN_CANDIDATES:
            if os.path.sep in cand:
                if os.path.exists(cand):
                    binary = cand
                    break
            else:
                binary = cand  # rely on PATH
                break
    if not binary:
        print("check-connect-commands: no c2c binary found (build it or pass --bin)", file=sys.stderr)
        return 1

    top = top_level_commands(binary)
    if not top:
        print("check-connect-commands: could not enumerate top-level commands", file=sys.stderr)
        return 1
    relay_subs = relay_subcommands(binary)
    rooms_enum = enum_from_synopsis(binary, ["relay", "rooms"])
    dm_enum = enum_from_synopsis(binary, ["relay", "dm"])
    identity_subs = relay_subcommands_group(binary, "identity")

    problems = []
    checked = 0
    for line, tokens in extract_command_lines(args.doc):
        checked += 1
        t0 = tokens[0]
        if t0 not in top:
            problems.append((line, f"'{t0}' is not a c2c subcommand"))
            continue
        if t0 != "relay" or len(tokens) < 2:
            continue
        t1 = tokens[1]
        if t1 not in relay_subs:
            problems.append((line, f"'relay {t1}' is not a relay subcommand"))
            continue
        if len(tokens) < 3:
            continue
        t2 = tokens[2]
        if t1 in ENUM_LEAF:
            enum = rooms_enum if t1 == "rooms" else dm_enum
            if enum and t2 not in enum:
                problems.append((line, f"'relay {t1} {t2}' not in {{{'|'.join(sorted(enum))}}}"))
        elif t1 in SUBGROUP and t1 == "identity":
            if identity_subs and t2 not in identity_subs:
                problems.append((line, f"'relay identity {t2}' not in {{{'|'.join(sorted(identity_subs))}}}"))

    print(f"check-connect-commands: checked {checked} `c2c` invocations in {os.path.relpath(args.doc, REPO)}")
    if problems:
        print(f"FAIL: {len(problems)} invalid command(s):", file=sys.stderr)
        for line, why in problems:
            print(f"  - {why}\n      in: {line}", file=sys.stderr)
        return 1
    print("PASS: all commands resolve to real c2c subcommands.")
    return 0


def relay_subcommands_group(binary, group):
    """COMMANDS names for a nested relay group like `relay identity`."""
    return _commands_section(binary, ["relay", group])


if __name__ == "__main__":
    sys.exit(main())
