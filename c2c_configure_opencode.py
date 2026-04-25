#!/usr/bin/env python3
"""Write a repo-local OpenCode config that exposes the c2c MCP server.

Usage: c2c configure-opencode [--target-dir DIR] [--force] [--json]

Generates `<target>/.opencode/opencode.json` with a single `c2c` MCP
entry pointing at this repo's `c2c_mcp.py` (absolute path) and
broker root (this repo's `.git/c2c/mcp`). The session id is derived
from the target directory's basename so multiple opencode peers in
different repos can co-exist on one shared broker.

Refuses to overwrite an existing `.opencode/opencode.json` unless
`--force` is given. The point is one-command opencode-c2c onboarding
for any repo without hand-editing settings.
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
C2C_MCP_PATH = REPO_ROOT / "c2c_mcp.py"
BROKER_ROOT = REPO_ROOT / ".git" / "c2c" / "mcp"
PLUGIN_SRC = REPO_ROOT / "data" / "opencode-plugin" / "c2c.ts"
PLUGIN_PACKAGE_JSON = {"dependencies": {"@opencode-ai/plugin": "1.4.3"}}
GLOBAL_PLUGIN_DIR = Path.home() / ".config" / "opencode" / "plugins"
C2C_CLI_PATH = Path.home() / ".local" / "bin" / "c2c"


def resolve_c2c_bin() -> str:
    """Return absolute path of the c2c binary, for C2C_CLI_COMMAND."""
    bin_path = shutil.which("c2c", path=str(Path.home() / ".local" / "bin"))
    if bin_path:
        return bin_path
    fallback = Path.home() / ".local" / "bin" / "c2c"
    if fallback.exists():
        return str(fallback)
    return "c2c"


def derive_session_id(target_dir: Path) -> str:
    return f"opencode-{target_dir.name}"


def extract_plugin_version() -> str:
    """Extract PLUGIN_VERSION from c2c.ts for C2C_MCP_PLUGIN_VERSION."""
    if not PLUGIN_SRC.exists():
        return "unknown"
    try:
        content = PLUGIN_SRC.read_text()
        for line in content.splitlines():
            stripped = line.strip()
            if stripped.startswith("const PLUGIN_VERSION") and "=" in stripped:
                version = stripped.split("=")[1].strip().strip('";')
                return version
    except Exception:
        pass
    return "unknown"


def build_config() -> dict:
    return {
        "$schema": "https://opencode.ai/config.json",
        "mcp": {
            "c2c": {
                "type": "local",
                "command": ["python3", str(C2C_MCP_PATH)],
                "environment": {
                    "C2C_MCP_BROKER_ROOT": str(BROKER_ROOT),
                    # C2C_MCP_SESSION_ID and C2C_MCP_AUTO_REGISTER_ALIAS are
                    # intentionally omitted from the shared project config.
                    # Two concurrent `c2c start opencode` in the same workdir
                    # would race to write different aliases; OpenCode overrides
                    # inherited env with opencode.json values, causing the last
                    # writer's alias to win for both sessions (#60).
                    # Per-instance identity is set in the process env by build_env.
                    "C2C_MCP_AUTO_DRAIN_CHANNEL": "0",
                    "C2C_MCP_AUTO_JOIN_ROOMS": "swarm-lounge",
                    "C2C_AUTO_JOIN_ROLE_ROOM": "1",
                    "C2C_MCP_CLIENT_TYPE": "opencode",
                    "C2C_MCP_PLUGIN_VERSION": extract_plugin_version(),
                    # Pin the c2c binary to an absolute path so a CWD-relative
                    # ./c2c shim can never be accidentally preferred (fork-bomb
                    # prevention). Matches the C2C_CLI_COMMAND set by build_env
                    # for managed sessions started via `c2c start opencode`.
                    "C2C_CLI_COMMAND": resolve_c2c_bin(),
                },
                "enabled": True,
            }
        },
    }


def install_plugin(config_dir: Path, *, force: bool) -> tuple[bool, str]:
    """Install the c2c OpenCode plugin into <config_dir>/plugins/c2c.ts.

    Returns (installed: bool, note: str).
    """
    if not PLUGIN_SRC.exists():
        return False, "plugin source not found (expected data/opencode-plugin/c2c.ts in c2c repo)"

    plugins_dir = config_dir / "plugins"
    plugins_dir.mkdir(parents=True, exist_ok=True)

    dest = plugins_dir / "c2c.ts"
    if dest.exists() and not force:
        return False, f"plugin already exists at {dest} (use --force to overwrite)"

    shutil.copy2(str(PLUGIN_SRC), str(dest))

    # Write/merge package.json for the plugin dependency
    pkg_path = config_dir / "package.json"
    if pkg_path.exists():
        try:
            existing = json.loads(pkg_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            existing = {}
        deps = existing.setdefault("dependencies", {})
        for k, v in PLUGIN_PACKAGE_JSON["dependencies"].items():
            if k not in deps:
                deps[k] = v
        pkg_path.write_text(json.dumps(existing, indent=2) + "\n", encoding="utf-8")
    else:
        pkg_path.write_text(json.dumps(PLUGIN_PACKAGE_JSON, indent=2) + "\n", encoding="utf-8")

    return True, str(dest)


def install_plugin_global(*, force: bool) -> tuple[bool, str]:
    """Install the c2c plugin to ~/.config/opencode/plugins/c2c.ts (global).

    Returns (installed: bool, note: str).
    """
    if not PLUGIN_SRC.exists():
        return False, "plugin source not found (expected data/opencode-plugin/c2c.ts in c2c repo)"

    GLOBAL_PLUGIN_DIR.mkdir(parents=True, exist_ok=True)
    dest = GLOBAL_PLUGIN_DIR / "c2c.ts"
    if dest.exists() and not force:
        return False, f"global plugin already exists at {dest} (use --force to overwrite)"

    shutil.copy2(str(PLUGIN_SRC), str(dest))
    return True, str(dest)


def write_plugin_sidecar(config_dir: Path, session_id: str, alias: str) -> Path:
    """Write .opencode/c2c-plugin.json so the plugin can discover config without env vars."""
    sidecar = config_dir / "c2c-plugin.json"
    sidecar.write_text(
        json.dumps(
            {
                "session_id": session_id,
                "alias": alias,
                "broker_root": str(BROKER_ROOT),
            },
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )
    return sidecar


def write_config(
    target_dir: Path, *, force: bool, alias: str | None = None,
    install_plugin_flag: bool = True,
) -> tuple[Path, str, str, dict]:
    target_dir = target_dir.resolve()
    if not target_dir.exists():
        raise SystemExit(f"target dir does not exist: {target_dir}")
    config_dir = target_dir / ".opencode"
    config_path = config_dir / "opencode.json"
    if config_path.exists() and not force:
        raise SystemExit(
            f"refusing to overwrite: {config_path} already exists "
            f"(re-run with --force to replace)"
        )
    config_dir.mkdir(parents=True, exist_ok=True)
    session_id = derive_session_id(target_dir)
    resolved_alias = alias if alias else session_id
    config_path.write_text(
        json.dumps(build_config(), indent=2) + "\n",
        encoding="utf-8",
    )
    write_plugin_sidecar(config_dir, session_id, resolved_alias)
    plugin_result: dict = {}
    if install_plugin_flag:
        ok, note = install_plugin(config_dir, force=force)
        plugin_result = {"installed": ok, "note": note}
    return config_path, session_id, resolved_alias, plugin_result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=("Write a repo-local OpenCode config exposing the c2c MCP server.")
    )
    parser.add_argument(
        "--target-dir",
        type=Path,
        default=Path.cwd(),
        help="directory to write .opencode/opencode.json into (default: cwd)",
    )
    parser.add_argument(
        "--alias",
        default=None,
        help=(
            "stable broker alias (default: same as session id, i.e. opencode-<dir-name>). "
            "Use this when you want a custom name peers use to address this instance."
        ),
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="overwrite an existing .opencode/opencode.json",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON result")
    parser.add_argument(
        "--install-global-plugin",
        action="store_true",
        help=(
            "also install the plugin to ~/.config/opencode/plugins/c2c.ts "
            "so it loads for all OpenCode sessions (project sidecar still needed per repo)"
        ),
    )
    args = parser.parse_args(argv)

    global_plugin_result: dict = {}
    if args.install_global_plugin:
        ok, note = install_plugin_global(force=args.force)
        global_plugin_result = {"installed": ok, "note": note}

    config_path, session_id, resolved_alias, plugin_result = write_config(
        args.target_dir, force=args.force, alias=args.alias,
    )
    payload = {
        "config_path": str(config_path),
        "target_dir": str(args.target_dir.resolve()),
        "session_id": session_id,
        "alias": resolved_alias,
        "broker_root": str(BROKER_ROOT),
        "plugin": plugin_result,
        "global_plugin": global_plugin_result,
    }
    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        print(f"wrote {config_path}")
        print(f"  session id: {session_id}")
        print(f"  alias:      {resolved_alias}")
        print(f"  broker root: {BROKER_ROOT}")
        if plugin_result.get("installed"):
            print(f"  plugin:     {plugin_result['note']}")
            print()
            print("Install plugin dependency (run once in the target .opencode dir):")
            opencode_dir = str(args.target_dir.resolve() / ".opencode")
            print(f"  cd {opencode_dir} && npm install")
            print()
            print("Set these env vars before launching opencode (or export in shell profile):")
            print(f"  export C2C_MCP_SESSION_ID={session_id}")
            print(f"  export C2C_MCP_BROKER_ROOT={BROKER_ROOT}")
        else:
            note = plugin_result.get("note", "")
            if note:
                print(f"  plugin:     skipped — {note}")
        if global_plugin_result.get("installed"):
            print(f"  global plugin: {global_plugin_result['note']}")
            print("    Plugin will load in ALL OpenCode sessions (managed + unmanaged).")
        elif global_plugin_result.get("note"):
            print(f"  global plugin: skipped — {global_plugin_result['note']}")
        elif not args.install_global_plugin:
            print()
            print("Tip: install the plugin globally for ALL OpenCode sessions:")
            print("  c2c setup opencode --install-global-plugin")
            print("  (This copies to ~/.config/opencode/plugins/c2c.ts — no npm install needed)")
        print()
        print(
            "Now run 'cd "
            + str(args.target_dir.resolve())
            + " && opencode mcp list' to verify, or launch opencode from that dir."
        )
        print()
        print("Auto-delivery is handled by the c2c TypeScript plugin (c2c.ts).")
        print("No PTY wake daemon needed — plugin uses c2c monitor for real-time wake.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
