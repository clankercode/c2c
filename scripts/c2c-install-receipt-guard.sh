#!/usr/bin/env bash
# Validate an optional buildbox PASS receipt immediately before install copies.
# Ordinary installs remain compatible: with C2C_VALIDATION_RECEIPT unset this
# is a no-op. This script is called from inside the install flock.
#
# The supplied receipt is schema v1:
#
#   {"schema":"c2c-p9-buildbox-pass-v1","status":"PASS",
#    "source":{"commit":"<git sha>","tree":"<git tree>"},
#    "toolchain":"<identity>","dependencies":"<identity>",
#    "artifacts":[{"name":"<installed artifact>","path":"<build path>",
#                   "sha256":"<sha256>","bytes":<size>}, ...]}
#
# The artifact list must contain exactly the eight names below. Additional
# top-level evidence fields are allowed so the buildbox can retain command and
# suite results, but the required fields and their types are deliberately
# strict. The receipt is never printed, so dependency output cannot leak
# through diagnostics.
set -euo pipefail

receipt="${C2C_VALIDATION_RECEIPT:-}"
if [[ -z "$receipt" ]]; then exit 0; fi
if [[ ! -f "$receipt" ]]; then
  echo "[c2c install-receipt] REFUSE: validation receipt does not exist: $receipt" >&2
  exit 1
fi

export C2C_VALIDATION_RECEIPT="$receipt"
python3 - <<'PY'
import hashlib
import json
import os
import re
import subprocess
import sys

def fail(message):
    print(f"[c2c install-receipt] REFUSE: {message}", file=sys.stderr)
    raise SystemExit(1)

path = os.environ["C2C_VALIDATION_RECEIPT"]

def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"receipt contains duplicate key: {key}")
        result[key] = value
    return result

try:
    with open(path, encoding="utf-8") as handle:
        receipt = json.load(handle, object_pairs_hook=reject_duplicate_keys)
except Exception as exc: fail(f"malformed receipt ({exc})")
if not isinstance(receipt, dict): fail("receipt must be a JSON object")
if receipt.get("schema") != "c2c-p9-buildbox-pass-v1":
    fail("receipt schema must be c2c-p9-buildbox-pass-v1")
if receipt.get("status") != "PASS":
    fail("receipt status must be PASS")

required = {"schema", "status", "source", "toolchain", "dependencies", "artifacts"}
missing = sorted(required.difference(receipt))
if missing: fail("receipt is missing required field(s): " + ", ".join(missing))

source = receipt["source"]
if not isinstance(source, dict): fail("receipt source must be an object")
if set(source) != {"commit", "tree"}:
    fail("receipt source must contain exactly commit and tree")

sha_pattern = re.compile(r"^[0-9a-f]{40}$")
for field in ("commit", "tree"):
    if not isinstance(source[field], str) or not sha_pattern.fullmatch(source[field]):
        fail(f"receipt source {field} must be a 40-character lowercase git SHA")

for field in ("toolchain", "dependencies"):
    if not isinstance(receipt[field], str) or not receipt[field].strip():
        fail(f"receipt {field} identity must be a non-empty string")

def git(*args):
    try: return subprocess.check_output(["git", *args], text=True, stderr=subprocess.DEVNULL).strip()
    except Exception as exc: fail(f"could not inspect source tree ({exc})")

sha, tree = git("rev-parse", "HEAD"), git("write-tree")
expected_sha = source["commit"]
expected_tree = source["tree"]
if expected_sha != sha: fail(f"source commit mismatch (receipt {expected_sha}, current {sha})")
if expected_tree != tree: fail(f"source tree mismatch (receipt {expected_tree}, current {tree})")
dirty = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"], text=True).strip()
if dirty: fail("source checkout is not clean; rebuild and preserve a receipt for this exact tree")

def identity(commands, label):
    try:
        return subprocess.check_output(commands, text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        fail(f"could not determine current {label} identity")

toolchain = "\n".join([
    identity(["ocamlc", "-version"], "toolchain"),
    identity(["dune", "--version"], "toolchain"),
    identity(["opam", "--version"], "toolchain"),
])
dependencies = identity(["opam", "list", "--installed", "--short"], "dependencies")
if receipt["toolchain"] != toolchain: fail("toolchain identity mismatch")
if receipt["dependencies"] != dependencies: fail("dependencies identity mismatch")

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
raw = receipt["artifacts"]
if not isinstance(raw, list): fail("receipt artifacts must be a list")
entries = {}
for item in raw:
    if not isinstance(item, dict) or set(item) != {"name", "path", "sha256", "bytes"}:
        fail("each artifact must contain exactly name, path, sha256 and bytes")
    name = item["name"]
    if not isinstance(name, str) or name in entries:
        fail("receipt artifacts must have unique names")
    entries[name] = item
if set(entries) != set(artifacts): fail("receipt must contain exactly the eight install artifact hashes")
for name, relative in artifacts.items():
    item = entries[name]
    if item["path"] != relative:
        fail(f"artifact {name} path does not match the install target")
    expected_hash = item["sha256"]
    if not isinstance(expected_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
        fail(f"artifact {name} must be a lowercase sha256 string")
    artifact = os.path.join(os.getcwd(), relative)
    if not os.path.isfile(artifact): fail(f"prepared artifact is missing: {relative}")
    if not isinstance(item["bytes"], int) or isinstance(item["bytes"], bool) or item["bytes"] < 0:
        fail(f"artifact {name} bytes must be a non-negative integer")
    if item["bytes"] != os.path.getsize(artifact):
        fail(f"artifact size mismatch: {name}")
    digest = hashlib.sha256()
    with open(artifact, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""): digest.update(chunk)
    if digest.hexdigest() != expected_hash: fail(f"artifact hash mismatch: {name}")
print(f"[c2c install-receipt] validated PASS for {sha} (8 artifacts)", file=sys.stderr)
PY
