"""B122: gate for retired user-facing Python MCP/configure surfaces.

Canonical path is OCaml:
  c2c install self
  c2c install <claude|codex|opencode|kimi|grok>
  c2c-mcp-server

Python remains for tests / isolated migration only. Set
C2C_ALLOW_PYTHON_LEGACY=1 to re-enable these entry points.
"""
from __future__ import annotations

import os
import sys

_TRUTHY = {"1", "true", "yes", "on"}


def python_legacy_allowed() -> bool:
    return os.environ.get("C2C_ALLOW_PYTHON_LEGACY", "").strip().lower() in _TRUTHY


def refuse_python_legacy(feature: str, *, ocaml_hint: str) -> int:
    """Print retirement message and return exit code 1."""
    print(
        f"error: {feature} is retired (B122 — Python MCP/configure path).\n"
        f"\n"
        f"Use the OCaml installer instead:\n"
        f"  {ocaml_hint}\n"
        f"\n"
        f"MCP server binary: c2c-mcp-server (not python3 c2c_mcp.py)\n"
        f"Override for tests/isolated migration only: C2C_ALLOW_PYTHON_LEGACY=1",
        file=sys.stderr,
        flush=True,
    )
    return 1


def require_python_legacy(feature: str, *, ocaml_hint: str) -> int | None:
    """Return None if allowed, else print refuse message and return exit code."""
    if python_legacy_allowed():
        return None
    return refuse_python_legacy(feature, ocaml_hint=ocaml_hint)
