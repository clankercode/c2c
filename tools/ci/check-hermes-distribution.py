#!/usr/bin/env python3
"""Check distributed Hermes plugin sources, skills and embedded/install copies.

Maintainer utility for the general cross-platform distribution; never reads a
personal Hermes profile unless --installed-dir explicitly selects one. Generation
remains owned by `just codegen-hermes-plugin`, not this checker.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
ENTRY = re.compile(r'  \("([^"\n]+)", \{([a-z_]+)\|(.*?)\|\2\}\);', re.DOTALL)


def sources(directory: Path) -> dict[str, bytes]:
    return {p.relative_to(directory).as_posix(): p.read_bytes()
            for p in directory.rglob('*')
            if p.is_file() and '__pycache__' not in p.parts
            and p.suffix not in ('.pyc', '.pyo')}


def check(root: Path, installed: Path | None = None) -> list[str]:
    canonical = sources(root / 'data/hermes-plugin')
    if not canonical or 'skills/c2c/SKILL.md' not in canonical:
        return ['canonical Hermes plugin/skill missing']
    text = (root / 'ocaml/cli/c2c_hermes_plugin_embedded.ml').read_bytes().decode('utf-8')
    entries = ENTRY.findall(text)
    embedded = {name: body.encode('utf-8') for name, _, body in entries}
    errors = []
    if len(entries) != len(embedded):
        errors.append('duplicate embedded paths')
    copies = [('embedded', embedded)]
    if installed is not None:
        copies.append(('installed', sources(installed)))
    for label, files in copies:
        for name in sorted(canonical.keys() | files.keys()):
            if name not in files:
                errors.append(f'{label}: missing {name}')
            elif name not in canonical:
                errors.append(f'{label}: unexpected {name}')
            elif canonical[name] != files[name]:
                errors.append(f'{label}: stale {name}')
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT, help='repository root')
    parser.add_argument('--installed-dir', type=Path,
                        help='explicit plugin directory to compare read-only')
    args = parser.parse_args()
    try:
        errors = check(args.root, args.installed_dir)
    except (OSError, UnicodeError) as exc:
        errors = [str(exc)]
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        print('Run just codegen-hermes-plugin; commit sources + embed. For an installed '
              'copy, rebuild c2c then run c2c install hermes for that profile.', file=sys.stderr)
        return 1
    print('Hermes distribution matches canonical sources (including bundled skill).')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
