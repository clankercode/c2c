#!/usr/bin/env bash
# Validate an optional buildbox PASS receipt immediately before install copies.
# Ordinary installs remain compatible: with C2C_VALIDATION_RECEIPT unset this
# is a no-op. This script is called from inside the install flock.
set -euo pipefail

receipt="${C2C_VALIDATION_RECEIPT:-}"
if [[ -z "$receipt" ]]; then exit 0; fi
if [[ ! -f "$receipt" ]]; then
  echo "[c2c install-receipt] REFUSE: validation receipt does not exist: $receipt" >&2
  exit 1
fi

export C2C_VALIDATION_RECEIPT="$receipt"
python3 - <<'PY'
import hashlib, json, os, subprocess, sys

def fail(message):
    print(f"[c2c install-receipt] REFUSE: {message}", file=sys.stderr)
    raise SystemExit(1)

path = os.environ["C2C_VALIDATION_RECEIPT"]
try:
    with open(path, encoding="utf-8") as handle: receipt = json.load(handle)
except Exception as exc: fail(f"malformed receipt ({exc})")
if not isinstance(receipt, dict): fail("receipt must be a JSON object")
status = receipt.get("status", receipt.get("verdict", receipt.get("result")))
if isinstance(status, dict): status = status.get("status", status.get("verdict"))
if status not in ("PASS", "pass", "passed", "success"):
    fail(f"receipt is not a successful buildbox PASS (status={status!r})")

def git(*args):
    try: return subprocess.check_output(["git", *args], text=True, stderr=subprocess.DEVNULL).strip()
    except Exception as exc: fail(f"could not inspect source tree ({exc})")

sha, tree = git("rev-parse", "HEAD"), git("write-tree")
source = receipt.get("source") if isinstance(receipt.get("source"), dict) else receipt
expected_sha = source.get("commit", source.get("sha", source.get("head")))
expected_tree = source.get("tree", source.get("tree_sha", source.get("treeSha")))
if not isinstance(expected_sha, str) or not expected_sha: fail("receipt has no source commit/sha")
if expected_sha != sha: fail(f"source commit mismatch (receipt {expected_sha}, current {sha})")
if not isinstance(expected_tree, str) or not expected_tree: fail("receipt has no source tree")
if expected_tree != tree: fail(f"source tree mismatch (receipt {expected_tree}, current {tree})")
dirty = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"], text=True).strip()
if dirty: fail("source checkout is not clean; rebuild and preserve a receipt for this exact tree")

def identity(name, commands):
    value = os.environ.get("C2C_VALIDATION_" + name.upper())
    if value: return value
    parts = []
    for command in commands:
        try: parts.append(subprocess.check_output(command, text=True, stderr=subprocess.DEVNULL).strip())
        except Exception: parts.append("unavailable")
    return "\n".join(parts)

toolchain = identity("toolchain_id", [["ocamlc", "-version"], ["dune", "--version"], ["opam", "--version"]])
dependencies = identity("dependency_id", [["opam", "list", "--installed", "--short"]])
for label, current in (("toolchain", toolchain), ("dependencies", dependencies)):
    expected = receipt.get(label, receipt.get(label + "_id"))
    if isinstance(expected, dict): expected = expected.get("id", expected.get("sha256"))
    if expected is None: fail(f"receipt has no {label} identity")
    if str(expected) != current: fail(f"{label} identity mismatch")

artifacts = {
    "c2c": "_build/default/ocaml/cli/c2c.exe",
    "c2c-mcp-server": "_build/default/ocaml/server/c2c_mcp_server.exe",
    "c2c-mcp-inner": "_build/default/ocaml/server/c2c_mcp_server_inner_bin.exe",
    "c2c-inbox-hook-ocaml": "_build/default/ocaml/tools/c2c_inbox_hook.exe",
    "c2c-stop-hook-ocaml": "_build/default/ocaml/tools/c2c_stop_hook.exe",
    "c2c-cold-boot-hook": "_build/default/ocaml/tools/c2c_cold_boot_hook.exe",
    "c2c-post-compact-hook": "_build/default/ocaml/tools/c2c_post_compact_hook_bin.exe",
    "c2c-deliver-inbox": "_build/default/ocaml/cli/c2c_deliver_inbox.exe",
}
raw = receipt.get("artifacts", receipt.get("binaries"))
if isinstance(raw, list):
    entries = {item.get("name", item.get("artifact")): item for item in raw if isinstance(item, dict)}
elif isinstance(raw, dict): entries = raw
else: fail("receipt has no artifacts object/list")
if set(entries) != set(artifacts): fail("receipt must contain exactly the eight install artifact hashes")
for name, relative in artifacts.items():
    item = entries[name]
    expected_hash = item if isinstance(item, str) else item.get("sha256", item.get("hash")) if isinstance(item, dict) else None
    if not isinstance(expected_hash, str) or len(expected_hash) != 64: fail(f"artifact {name} has no valid sha256")
    artifact = os.path.join(os.getcwd(), relative)
    if not os.path.isfile(artifact): fail(f"prepared artifact is missing: {relative}")
    digest = hashlib.sha256()
    with open(artifact, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""): digest.update(chunk)
    if digest.hexdigest() != expected_hash: fail(f"artifact hash mismatch: {name}")
print(f"[c2c install-receipt] validated PASS for {sha} (8 artifacts)", file=sys.stderr)
PY
