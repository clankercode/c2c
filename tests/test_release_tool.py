from __future__ import annotations

import json
from pathlib import Path

from tools.ci import release


def test_validate_release_accepts_matching_version_and_changelog(tmp_path: Path) -> None:
    root = tmp_path
    (root / "ocaml").mkdir()
    (root / "docs").mkdir()
    (root / "ocaml" / "version.ml").write_text('let version = "1.2.3"\n', encoding="utf-8")
    (root / "docs" / "changelog.md").write_text(
        "# Changelog\n\n## v1.2.3\n\n- shipped the thing\n", encoding="utf-8"
    )

    release.validate_release(root, "v1.2.3")


def test_package_npm_stages_meta_and_platform_packages(tmp_path: Path) -> None:
    artifacts = tmp_path / "artifacts"
    for platform in release.PLATFORMS.values():
        binary = artifacts / f"c2c-{platform.target}" / platform.exe_name
        binary.parent.mkdir(parents=True)
        binary.write_text("binary", encoding="utf-8")
        binary.chmod(0o755)

    dist = tmp_path / "npm"
    release.stage_npm_packages(artifacts, dist, "1.2.3", "@clanker-code")

    meta = json.loads((dist / "c2c" / "package.json").read_text(encoding="utf-8"))
    assert meta["name"] == "@clanker-code/c2c"
    assert meta["version"] == "1.2.3"
    assert set(meta["optionalDependencies"]) == {
        "@clanker-code/c2c-linux-x64",
        "@clanker-code/c2c-linux-arm64",
        "@clanker-code/c2c-darwin-x64",
        "@clanker-code/c2c-darwin-arm64",
    }

    linux = json.loads((dist / "c2c-linux-x64" / "package.json").read_text(encoding="utf-8"))
    assert linux["os"] == ["linux"]
    assert linux["cpu"] == ["x64"]
    assert (dist / "c2c-linux-x64" / "bin" / "c2c").exists()


def test_publish_order_puts_meta_package_last(tmp_path: Path) -> None:
    dist = tmp_path / "npm"
    for name in ["c2c", "c2c-linux-x64", "c2c-darwin-arm64"]:
        package_dir = dist / name
        package_dir.mkdir(parents=True)
        (package_dir / "package.json").write_text("{}", encoding="utf-8")

    out = tmp_path / "order.txt"
    release.write_publish_order(dist, out)

    lines = out.read_text(encoding="utf-8").splitlines()
    assert lines[-1].endswith("/c2c")
