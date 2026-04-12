#!/usr/bin/env python3
import shlex
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SWITCH = "/home/xertrov/src/call-coding-clis/ocaml"


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    rendered_args = " ".join(shlex.quote(arg) for arg in args)
    command = (
        f'eval "$(opam env --switch={shlex.quote(SWITCH)} --set-switch)" '
        f"&& dune exec ./ocaml/server/c2c_mcp_server.exe -- {rendered_args}"
    ).strip()
    return subprocess.run(["bash", "-lc", command], cwd=ROOT).returncode


if __name__ == "__main__":
    raise SystemExit(main())
