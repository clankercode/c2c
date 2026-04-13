#!/usr/bin/env python3
import os
import sys

import c2c_broker_gc
import c2c_dead_letter
import c2c_configure_claude_code
import c2c_history
import c2c_configure_codex
import c2c_configure_crush
import c2c_configure_kimi
import c2c_configure_opencode
import c2c_deliver_inbox
import c2c_health
import c2c_setup
import c2c_init
import c2c_inject
import c2c_install
import c2c_list
import c2c_mcp
import c2c_poll_inbox
import c2c_poker_sweep
import c2c_prune
import c2c_register
import c2c_restart_me
import c2c_room
import c2c_send
import c2c_send_all
import c2c_verify
import c2c_watch
import c2c_whoami


SAFE_AUTO_APPROVE_SUBCOMMANDS = {
    "send",
    "send-all",
    "list",
    "whoami",
    "verify",
    "init",
    "health",
    "history",
}


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
            "usage: c2c <broker-gc|configure-claude-code|configure-codex|configure-crush|configure-kimi|configure-opencode|dead-letter|deliver-inbox|health|history|init|inject|install|list|mcp|peek-inbox|poker-sweep|poll-inbox|prune|refresh-peer|register|restart-me|room|send|send-all|setup|sweep|verify|watch|whoami|wire-daemon> [...args]",
            file=sys.stderr,
        )
        return 2

    subcommand, remainder = argv[0], argv[1:]

    if subcommand == "broker-gc":
        return c2c_broker_gc.main(remainder)
    if subcommand == "dead-letter":
        return c2c_dead_letter.main(remainder)
    if subcommand == "health":
        return c2c_health.main(remainder)
    if subcommand == "history":
        return c2c_history.main(remainder)
    if subcommand == "configure-claude-code":
        return c2c_configure_claude_code.main(remainder)
    if subcommand == "configure-codex":
        return c2c_configure_codex.main(remainder)
    if subcommand == "configure-crush":
        return c2c_configure_crush.main(remainder)
    if subcommand == "configure-kimi":
        return c2c_configure_kimi.main(remainder)
    if subcommand == "configure-opencode":
        return c2c_configure_opencode.main(remainder)
    if subcommand == "setup":
        return c2c_setup.main(remainder)
    if subcommand == "deliver-inbox":
        return c2c_deliver_inbox.main(remainder)
    if subcommand == "init":
        return c2c_init.main(remainder)
    if subcommand == "inject":
        return c2c_inject.main(remainder)
    if subcommand == "install":
        return c2c_install.main(remainder)
    if subcommand == "list":
        return c2c_list.main(remainder)
    if subcommand == "mcp":
        return c2c_mcp.main(remainder)
    if subcommand == "poker-sweep":
        return c2c_poker_sweep.main(remainder)
    if subcommand == "poll-inbox":
        return c2c_poll_inbox.main(remainder)
    if subcommand == "peek-inbox":
        return c2c_poll_inbox.main(["--peek", *remainder])
    if subcommand == "prune":
        return c2c_prune.main(remainder)
    if subcommand == "refresh-peer":
        import c2c_refresh_peer
        return c2c_refresh_peer.main(remainder)
    if subcommand == "relay":
        # c2c relay serve    [--listen HOST:PORT] [--token TOKEN] ...
        # c2c relay connect  --relay-url URL [--token TOKEN] ...
        # c2c relay setup    --url URL [--token TOKEN] [--show]
        # c2c relay status   [--relay-url URL] [--token TOKEN] [--json]
        # c2c relay list     [--relay-url URL] [--token TOKEN] [--dead] [--json]
        if remainder and remainder[0] == "serve":
            import c2c_relay_server
            return c2c_relay_server.main(remainder[1:])
        if remainder and remainder[0] == "connect":
            import c2c_relay_connector
            return c2c_relay_connector.main(remainder[1:])
        if remainder and remainder[0] == "setup":
            import c2c_relay_config
            return c2c_relay_config.main(remainder[1:])
        if remainder and remainder[0] in ("status", "list"):
            import c2c_relay_status
            return c2c_relay_status.main(remainder)
        if remainder and remainder[0] == "rooms":
            import c2c_relay_rooms
            return c2c_relay_rooms.main(remainder[1:])
        if remainder and remainder[0] == "gc":
            import c2c_relay_gc
            return c2c_relay_gc.main(remainder[1:])
        print(
            "usage: c2c relay <subcommand> ...\n"
            "  serve    --listen HOST:PORT [--token TOKEN] [--token-file PATH] [--storage memory|sqlite] [--db-path PATH] [--verbose]\n"
            "  connect  --relay-url URL [--token TOKEN] [--node-id ID] [--broker-root DIR] [--interval N] [--once]\n"
            "  setup    --url URL [--token TOKEN] [--node-id ID] [--show]\n"
            "  status   [--relay-url URL] [--token TOKEN] [--json]\n"
            "  list     [--relay-url URL] [--token TOKEN] [--dead] [--json]\n"
            "  rooms    <list|join|leave|send|history> [--relay-url URL] [--json]\n"
            "  gc       [--relay-url URL] [--token TOKEN] [--interval N] [--once] [--json]",
            file=sys.stderr,
        )
        return 2
    if subcommand == "register":
        return c2c_register.main(remainder)
    if subcommand == "restart-me":
        return c2c_restart_me.main(remainder)
    if subcommand == "room":
        return c2c_room.main(remainder)
    if subcommand == "send":
        return c2c_send.main(remainder)
    if subcommand == "send-all":
        return c2c_send_all.main(remainder)
    if subcommand == "sweep":
        # alias for broker-gc --once
        return c2c_broker_gc.main(["--once"] + remainder)
    if subcommand == "verify":
        return c2c_verify.main(remainder)
    if subcommand == "watch":
        return c2c_watch.main(remainder)
    if subcommand == "whoami":
        return c2c_whoami.main(remainder)
    if subcommand == "wire-daemon":
        import c2c_wire_daemon
        return c2c_wire_daemon.main(remainder)

    print(f"unknown c2c subcommand: {subcommand}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
