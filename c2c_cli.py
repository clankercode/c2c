#!/usr/bin/env python3
import os
import sys

import c2c_install
import c2c_list
import c2c_mcp
import c2c_register
import c2c_send
import c2c_verify
import c2c_whoami


SAFE_AUTO_APPROVE_SUBCOMMANDS = {"send", "list", "whoami", "verify"}


def auto_approve_enabled() -> bool:
    return os.environ.get("C2C_AUTO_APPROVE", "").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }


def is_safe_auto_approve_command(command: str) -> bool:
    parts = command.strip().split()
    if len(parts) < 2:
        return False
    if parts[0] != "c2c":
        return False
    return parts[1] in SAFE_AUTO_APPROVE_SUBCOMMANDS


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        print(
            "usage: c2c <install|list|mcp|register|send|verify|whoami> [...args]",
            file=sys.stderr,
        )
        return 2

    subcommand, remainder = argv[0], argv[1:]

    if subcommand == "install":
        return c2c_install.main(remainder)
    if subcommand == "list":
        return c2c_list.main(remainder)
    if subcommand == "mcp":
        return c2c_mcp.main(remainder)
    if subcommand == "register":
        return c2c_register.main(remainder)
    if subcommand == "send":
        return c2c_send.main(remainder)
    if subcommand == "verify":
        return c2c_verify.main(remainder)
    if subcommand == "whoami":
        return c2c_whoami.main(remainder)

    print(f"unknown c2c subcommand: {subcommand}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
