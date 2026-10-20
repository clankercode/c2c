"""Contract tests for the optional buildbox install receipt gate.

These tests use an ignored, miniature git checkout so they exercise the actual
shell/Python guard without depending on the worktree's mutable Dune output or
the developer's toolchain.  The production guard has no test-only identity
override; the fixture supplies deterministic tool binaries on PATH instead.
"""

import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
GUARD = REPO / "scripts" / "c2c-install-receipt-guard.sh"

ARTIFACTS = {
    "c2c": "_build/default/ocaml/cli/c2c.exe",
    "c2c-mcp-server": "_build/default/ocaml/server/c2c_mcp_server.exe",
    "c2c-mcp-inner": "_build/default/ocaml/server/c2c_mcp_server_inner_bin.exe",
    "c2c-inbox-hook-ocaml": "_build/default/ocaml/tools/c2c_inbox_hook.exe",
    "c2c-stop-hook-ocaml": "_build/default/ocaml/tools/c2c_stop_hook.exe",
    "c2c-cold-boot-hook": "_build/default/ocaml/tools/c2c_cold_boot_hook.exe",
    "c2c-post-compact-hook": "_build/default/ocaml/tools/c2c_post_compact_hook_bin.exe",
    "c2c-deliver-inbox": "_build/default/ocaml/cli/c2c_deliver_inbox.exe",
}


def run_git(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=root, text=True).strip()


def write_tool(path: Path, body: str) -> None:
    path.write_text("#!/bin/sh\nset -eu\n" + body)
    path.chmod(0o755)


def fixture(tmp_path: Path) -> tuple[Path, dict[str, str], dict[str, str]]:
    root = tmp_path / "source"
    (root / "scripts").mkdir(parents=True)
    shutil.copy2(GUARD, root / "scripts/c2c-install-receipt-guard.sh")
    (root / ".gitignore").write_text("_build/\n")
    (root / "candidate.txt").write_text("frozen source\n")
    run_git(root, "init", "-q")
    run_git(root, "config", "user.email", "tests@example.invalid")
    run_git(root, "config", "user.name", "receipt tests")
    run_git(root, "add", ".")
    run_git(root, "commit", "-qm", "candidate")

    tool_bin = tmp_path / "tools"
    tool_bin.mkdir()
    write_tool(tool_bin / "ocamlc", 'printf "%s\\n" "ocamlc-fixture"')
    write_tool(tool_bin / "dune", 'printf "%s\\n" "dune-fixture"')
    write_tool(
        tool_bin / "opam",
        'if [ "${1:-}" = list ]; then printf "%s\\n" "dep-a" "dep-b"; else printf "%s\\n" "opam-fixture"; fi',
    )

    artifact_hashes = {}
    for name, relative in ARTIFACTS.items():
        artifact = root / relative
        artifact.parent.mkdir(parents=True, exist_ok=True)
        artifact.write_bytes((name + "-prepared\n").encode())
        artifact_hashes[name] = hashlib.sha256(artifact.read_bytes()).hexdigest()

    identities = {
        "toolchain": "ocamlc-fixture\ndune-fixture\nopam-fixture",
        "dependencies": "dep-a\ndep-b",
    }
    return root, artifact_hashes, {**identities, "commit": run_git(root, "rev-parse", "HEAD"), "tree": run_git(root, "write-tree"), "path": str(tool_bin)}


def receipt_file(root: Path, metadata: dict[str, str], hashes: dict[str, str], **overrides: object) -> Path:
    payload: dict[str, object] = {
        "schema": "c2c-p9-buildbox-pass-v1",
        "status": "PASS",
        "source": {"commit": metadata["commit"], "tree": metadata["tree"]},
        "toolchain": metadata["toolchain"],
        "dependencies": metadata["dependencies"],
        "artifacts": [
            {
                "name": name,
                "path": relative,
                "sha256": digest,
                "bytes": (root / relative).stat().st_size,
            }
            for name, digest in hashes.items()
            for relative in [ARTIFACTS[name]]
        ],
        "commands": {"gate": "all required checks passed"},
    }
    payload.update(overrides)
    path = root.parent / "buildbox-pass.json"
    path.write_text(json.dumps(payload))
    return path


def invoke(root: Path, metadata: dict[str, str], receipt: Path | None) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["PATH"] = metadata["path"] + os.pathsep + env["PATH"]
    if receipt is None:
        env.pop("C2C_VALIDATION_RECEIPT", None)
    else:
        env["C2C_VALIDATION_RECEIPT"] = str(receipt)
    return subprocess.run(
        ["bash", "scripts/c2c-install-receipt-guard.sh"],
        cwd=root,
        env=env,
        text=True,
        capture_output=True,
        timeout=10,
    )


def test_valid_v1_receipt_accepts_exact_eight_artifacts(tmp_path: Path) -> None:
    root, hashes, metadata = fixture(tmp_path)
    result = invoke(root, metadata, receipt_file(root, metadata, hashes))
    assert result.returncode == 0, result.stderr
    assert "8 artifacts" in result.stderr


def test_receipt_free_install_remains_a_noop(tmp_path: Path) -> None:
    root, _hashes, metadata = fixture(tmp_path)
    result = invoke(root, metadata, None)
    assert result.returncode == 0, result.stderr


def test_legacy_or_incomplete_receipt_is_rejected_before_copy(tmp_path: Path) -> None:
    root, hashes, metadata = fixture(tmp_path)
    receipt = receipt_file(root, metadata, hashes, schema="legacy-buildbox-pass-v1")
    target = root / "target-installed-binary"
    target.write_text("old bytes")
    result = invoke(root, metadata, receipt)
    assert result.returncode != 0
    assert "schema" in result.stderr
    assert target.read_text() == "old bytes"


def test_receipt_requires_canonical_source_and_artifact_map(tmp_path: Path) -> None:
    root, hashes, metadata = fixture(tmp_path)

    no_source = receipt_file(root, metadata, hashes)
    payload = json.loads(no_source.read_text())
    payload["source"] = {"sha": metadata["commit"], "tree": metadata["tree"]}
    no_source.write_text(json.dumps(payload))
    result = invoke(root, metadata, no_source)
    assert result.returncode != 0
    assert "source must contain exactly" in result.stderr

    extra_artifact = receipt_file(root, metadata, hashes)
    payload = json.loads(extra_artifact.read_text())
    payload["artifacts"].append(
        {"name": "unexpected", "path": "_build/unexpected", "sha256": "0" * 64, "bytes": 0}
    )
    extra_artifact.write_text(json.dumps(payload))
    result = invoke(root, metadata, extra_artifact)
    assert result.returncode != 0
    assert "exactly the eight" in result.stderr


def test_identity_mismatch_does_not_echo_dependency_contents(tmp_path: Path) -> None:
    root, hashes, metadata = fixture(tmp_path)
    receipt = receipt_file(root, metadata, hashes, dependencies="private-buildbox-token")
    result = invoke(root, metadata, receipt)
    assert result.returncode != 0
    assert "dependencies identity mismatch" in result.stderr
    assert "private-buildbox-token" not in result.stderr
