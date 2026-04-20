#!/usr/bin/env python3
"""c2c relay configuration helpers — Phase 5.

Persists relay connection settings (URL + token) so operators don't need to
pass --relay-url / --token on every `c2c relay` command.

Config file location (in priority order):
  1. Path given via C2C_RELAY_CONFIG env var.
  2. <broker-root>/relay.json  (next to registry.json)
  3. ~/.config/c2c/relay.json  (fallback user-level config)

Config file format (JSON):
    {"url": "https://host:8443", "token": "secret", "node_id": "hostname-abc12345",
     "ca_bundle": "/etc/c2c/relay.crt"}

All fields are optional; absent fields fall back to CLI args or auto-derivation.
`ca_bundle` points at a PEM file used to verify a self-signed relay cert (see
docs/c2c-research/relay-tls-setup.md §3.3). Unset means trust the system CA bundle.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Optional


_DEFAULT_USER_CONFIG = Path("~/.config/c2c/relay.json").expanduser()


def _broker_root_from_env() -> Optional[Path]:
    val = os.environ.get("C2C_MCP_BROKER_ROOT", "").strip()
    return Path(val) if val else None


def default_config_path() -> Path:
    """Return the config file path according to priority rules."""
    env_override = os.environ.get("C2C_RELAY_CONFIG", "").strip()
    if env_override:
        return Path(env_override)
    broker_root = _broker_root_from_env()
    if broker_root:
        return broker_root / "relay.json"
    return _DEFAULT_USER_CONFIG


def load_config(path: Optional[Path] = None) -> dict:
    """Load relay config from disk. Returns {} if file is missing or invalid."""
    p = path or default_config_path()
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_config(data: dict, path: Optional[Path] = None) -> Path:
    """Write relay config to disk. Creates parent directories as needed."""
    p = path or default_config_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return p


def resolve_relay_params(
    url: Optional[str] = None,
    token: Optional[str] = None,
    node_id: Optional[str] = None,
    ca_bundle: Optional[str] = None,
    config_path: Optional[Path] = None,
) -> dict:
    """Merge CLI args, environment, and saved config.

    Precedence: explicit args, C2C_RELAY_* environment variables, saved config.

    Returns dict with keys: url, token, node_id, ca_bundle (any may be None/empty).
    """
    cfg = load_config(config_path)
    return {
        "url": url or os.environ.get("C2C_RELAY_URL") or cfg.get("url") or "",
        "token": token or os.environ.get("C2C_RELAY_TOKEN") or cfg.get("token") or "",
        "node_id": (
            node_id
            or os.environ.get("C2C_RELAY_NODE_ID")
            or cfg.get("node_id")
            or ""
        ),
        "ca_bundle": (
            ca_bundle
            or os.environ.get("C2C_RELAY_CA_BUNDLE")
            or cfg.get("ca_bundle")
            or ""
        ),
    }


def main(argv: Optional[list[str]] = None) -> int:
    """c2c relay setup — save relay config to disk.

    Usage:
        c2c relay setup --url http://host:7331 [--token SECRET] [--node-id ID]
        c2c relay setup --show
    """
    import argparse
    import sys
    from c2c_relay_contract import derive_node_id

    parser = argparse.ArgumentParser(description="Configure c2c relay connection")
    parser.add_argument("--url", default="", help="Relay server URL")
    parser.add_argument("--token", default="", help="Bearer token")
    parser.add_argument("--token-file", default="", help="File containing Bearer token")
    parser.add_argument("--node-id", default="",
                        help="Override node_id (default: auto-derived)")
    parser.add_argument("--ca-bundle", default="",
                        help="Path to PEM CA bundle for self-signed relay certs")
    parser.add_argument("--config", default="",
                        help="Config file path (default: auto)")
    parser.add_argument("--show", action="store_true",
                        help="Show current config and exit (does not write)")
    parser.add_argument("--json", action="store_true", help="Output JSON")
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)

    config_path = Path(args.config).expanduser() if args.config else None

    if args.show:
        cfg = load_config(config_path)
        path = config_path or default_config_path()
        if args.json:
            import json as _json
            print(_json.dumps({"config_path": str(path), "config": cfg}, indent=2))
        else:
            print(f"config: {path}")
            if cfg:
                for k, v in cfg.items():
                    display = "***" if k == "token" and v else v
                    print(f"  {k}: {display}")
            else:
                print("  (no config saved)")
        return 0

    if not args.url:
        print("relay setup: --url is required", file=sys.stderr)
        return 1

    token = args.token.strip()
    if not token and args.token_file:
        token = Path(args.token_file).expanduser().read_text(encoding="utf-8").strip()

    node_id = args.node_id.strip()
    if not node_id:
        try:
            node_id = derive_node_id()
        except Exception:
            node_id = ""

    data: dict = {"url": args.url}
    if token:
        data["token"] = token
    if node_id:
        data["node_id"] = node_id
    ca_bundle = args.ca_bundle.strip()
    if ca_bundle:
        data["ca_bundle"] = str(Path(ca_bundle).expanduser())

    saved_path = save_config(data, config_path)
    if args.json:
        import json as _json
        print(_json.dumps({"ok": True, "config_path": str(saved_path),
                           "config": {k: ("***" if k == "token" else v)
                                      for k, v in data.items()}}, indent=2))
    else:
        print(f"relay config saved to {saved_path}")
        print(f"  url: {data['url']}")
        if token:
            print("  token: ***")
        if node_id:
            print(f"  node_id: {node_id}")
        if "ca_bundle" in data:
            print(f"  ca_bundle: {data['ca_bundle']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
