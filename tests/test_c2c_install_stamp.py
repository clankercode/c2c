import hashlib
import json
import os
import subprocess
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]


def write_executable(path: Path, content: bytes) -> None:
    path.write_bytes(content)
    path.chmod(0o755)


def sha256_hex(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_install_stamp_records_installed_binary_hashes(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    stamp = bin_dir / ".c2c-version"

    write_executable(bin_dir / "c2c", b"cli-binary")
    write_executable(bin_dir / "c2c-mcp-server", b"mcp-server-binary")
    write_executable(bin_dir / "c2c-inbox-hook-ocaml", b"inbox-hook-binary")
    write_executable(bin_dir / "c2c-cold-boot-hook", b"cold-boot-hook-binary")

    env = os.environ.copy()
    env["C2C_INSTALL_STAMP"] = str(stamp)
    env["C2C_MCP_AUTO_REGISTER_ALIAS"] = "stamp-test"

    result = subprocess.run(
        ["bash", "scripts/c2c-install-stamp.sh"],
        cwd=REPO,
        env=env,
        text=True,
        capture_output=True,
        timeout=10,
    )

    assert result.returncode == 0, result.stderr
    payload = json.loads(stamp.read_text())

    assert payload["sha"]
    assert payload["binaries"]["c2c"]["sha256"] == sha256_hex(bin_dir / "c2c")
    assert (
        payload["binaries"]["c2c-mcp-server"]["sha256"]
        == sha256_hex(bin_dir / "c2c-mcp-server")
    )
    assert (
        payload["binaries"]["c2c-inbox-hook-ocaml"]["sha256"]
        == sha256_hex(bin_dir / "c2c-inbox-hook-ocaml")
    )
    assert (
        payload["binaries"]["c2c-cold-boot-hook"]["sha256"]
        == sha256_hex(bin_dir / "c2c-cold-boot-hook")
    )
