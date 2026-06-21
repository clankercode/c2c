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
        binary_dir = artifacts / f"c2c-{platform.target}"
        for executable in [platform.exe_name, "c2c-deliver-inbox"]:
            binary = binary_dir / executable
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_text("binary", encoding="utf-8")
            binary.chmod(0o755)

    dist = tmp_path / "npm"
    release.stage_npm_packages(artifacts, dist, "1.2.3", "@clanker-code")

    meta = json.loads((dist / "c2c" / "package.json").read_text(encoding="utf-8"))
    assert meta["name"] == "@clanker-code/c2c"
    assert meta["version"] == "1.2.3"
    assert meta["repository"] == {
        "type": "git",
        "url": "git+https://github.com/clankercode/c2c.git",
    }
    assert set(meta["optionalDependencies"]) == {
        "@clanker-code/c2c-linux-x64",
        "@clanker-code/c2c-linux-arm64",
        "@clanker-code/c2c-darwin-x64",
        "@clanker-code/c2c-darwin-arm64",
    }

    linux = json.loads((dist / "c2c-linux-x64" / "package.json").read_text(encoding="utf-8"))
    assert linux["os"] == ["linux"]
    assert linux["cpu"] == ["x64"]
    assert linux["repository"] == meta["repository"]
    assert linux["bin"] == {
        "c2c": "bin/c2c",
        "c2c-deliver-inbox": "bin/c2c-deliver-inbox",
    }
    assert (dist / "c2c-linux-x64" / "bin" / "c2c").exists()
    assert (dist / "c2c-linux-x64" / "bin" / "c2c-deliver-inbox").exists()
    assert meta["bin"] == {
        "c2c": "bin/c2c-js-wrapper.js",
        "c2c-deliver-inbox": "bin/c2c-deliver-inbox-js-wrapper.js",
    }
    assert (dist / "c2c" / "index.js").read_text(encoding="utf-8") == (
        release.repo_root() / "npm-pkgs" / "c2c" / "index.js"
    ).read_text(encoding="utf-8")
    assert (dist / "c2c" / "bin" / "c2c-deliver-inbox-js-wrapper.js").exists()


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


def test_checksums_and_manifest_cover_final_release_tarballs(tmp_path: Path) -> None:
    root = tmp_path / "repo"
    release_dir = tmp_path / "release"
    (root / "ocaml").mkdir(parents=True)
    (root / "ocaml" / "version.ml").write_text('let version = "1.2.3"\n', encoding="utf-8")
    release_dir.mkdir()
    for name in [
        "c2c-1.2.3-linux-x64.tar.gz",
        "c2c-1.2.3-npm-packages.tar.gz",
    ]:
        (release_dir / name).write_text(name, encoding="utf-8")

    sums = release_dir / "SHA256SUMS"
    manifest = release_dir / "release-manifest.json"
    release.write_checksums(release_dir, sums)
    release.write_manifest(root, release_dir, "1.2.3", manifest)

    sums_text = sums.read_text(encoding="utf-8")
    manifest_json = json.loads(manifest.read_text(encoding="utf-8"))
    manifest_paths = {entry["path"] for entry in manifest_json["artifacts"]}

    assert "c2c-1.2.3-linux-x64.tar.gz" in sums_text
    assert "c2c-1.2.3-npm-packages.tar.gz" in sums_text
    assert "c2c-1.2.3-linux-x64.tar.gz" in manifest_paths
    assert "c2c-1.2.3-npm-packages.tar.gz" in manifest_paths
