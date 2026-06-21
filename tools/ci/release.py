#!/usr/bin/env python3
"""Release helpers for c2c CI.

The GitHub release workflow uses this script for version/changelog validation,
release-note extraction, checksum generation, and npm package staging. Keep it
stdlib-only so it runs on fresh GitHub-hosted runners.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


SEMVER_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:[-+][0-9A-Za-z.-]+)?$")
OCAML_VERSION_RE = re.compile(r'^\s*let\s+version\s*=\s*"([^"]+)"\s*$')
CHANGELOG_HEADING_RE = re.compile(r"^##\s+\[?v?([^]\s]+)\]?(?:\s|$)")


@dataclass(frozen=True)
class Platform:
    target: str
    npm_suffix: str
    os_name: str
    cpu: str
    exe_name: str


PLATFORMS: dict[str, Platform] = {
    "linux-x64": Platform("linux-x64", "linux-x64", "linux", "x64", "c2c"),
    "linux-arm64": Platform("linux-arm64", "linux-arm64", "linux", "arm64", "c2c"),
    "darwin-x64": Platform("darwin-x64", "darwin-x64", "darwin", "x64", "c2c"),
    "darwin-arm64": Platform("darwin-arm64", "darwin-arm64", "darwin", "arm64", "c2c"),
}

REPOSITORY = {
    "type": "git",
    "url": "git+https://github.com/clankercode/c2c.git",
}


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def normalize_version(version: str) -> str:
    version = version.strip()
    if version.startswith("refs/tags/"):
        version = version.removeprefix("refs/tags/")
    if version.startswith("v"):
        version = version[1:]
    if not SEMVER_RE.match(version):
        die(f"version is not semver: {version!r}")
    return version


def read_ocaml_version(root: Path) -> str:
    version_file = root / "ocaml" / "version.ml"
    for line in version_file.read_text(encoding="utf-8").splitlines():
        match = OCAML_VERSION_RE.match(line)
        if match:
            return normalize_version(match.group(1))
    die(f"could not find let version = ... in {version_file}")


def changelog_sections(changelog: Path) -> dict[str, str]:
    sections: dict[str, list[str]] = {}
    current: str | None = None
    for line in changelog.read_text(encoding="utf-8").splitlines():
        match = CHANGELOG_HEADING_RE.match(line)
        if match:
            candidate = match.group(1).rstrip(":")
            if SEMVER_RE.match(candidate):
                current = normalize_version(candidate)
                sections.setdefault(current, [])
                continue
        if current is not None:
            sections[current].append(line)
    return {version: "\n".join(lines).strip() for version, lines in sections.items()}


def validate_release(root: Path, version: str) -> None:
    expected = normalize_version(version)
    actual = read_ocaml_version(root)
    if actual != expected:
        die(f"ocaml/version.ml is {actual}, expected {expected}")
    sections = changelog_sections(root / "docs" / "changelog.md")
    notes = sections.get(expected, "")
    if not notes:
        die(f"docs/changelog.md has no non-empty '## {expected}' or '## v{expected}' section")
    print(f"release validation ok: version={expected}")


def write_release_notes(root: Path, version: str, out: Path) -> None:
    expected = normalize_version(version)
    notes = changelog_sections(root / "docs" / "changelog.md").get(expected, "")
    if not notes:
        die(f"no changelog notes found for {expected}")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(f"# c2c {expected}\n\n{notes}\n", encoding="utf-8")
    print(out)


def iter_files(root: Path) -> Iterable[Path]:
    for path in sorted(root.rglob("*")):
        if path.is_file():
            yield path


def write_checksums(input_dir: Path, out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    for path in iter_files(input_dir):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        lines.append(f"{digest}  {path.relative_to(input_dir).as_posix()}")
    if not lines:
        die(f"no files found under {input_dir}")
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(out)


def write_manifest(root: Path, artifacts_dir: Path, version: str, out: Path) -> None:
    version = normalize_version(version)
    files = []
    for path in iter_files(artifacts_dir):
        files.append({
            "path": path.relative_to(artifacts_dir).as_posix(),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "bytes": path.stat().st_size,
        })
    if not files:
        die(f"no files found under {artifacts_dir}")
    manifest = {
        "schema_version": 1,
        "project": "c2c",
        "version": version,
        "git_sha": os.environ.get("GITHUB_SHA", ""),
        "git_ref": os.environ.get("GITHUB_REF_NAME", ""),
        "ocaml_version": read_ocaml_version(root),
        "artifacts": files,
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    package_json(out, manifest)
    print(out)


def artifact_binary(artifacts_dir: Path, platform: Platform, executable: str | None = None) -> Path:
    executable = executable or platform.exe_name
    candidates = [
        path for path in artifacts_dir.rglob(executable)
        if platform.target in path.as_posix()
    ]
    if not candidates:
        die(f"missing {executable} artifact for {platform.target} under {artifacts_dir}")
    if len(candidates) > 1:
        formatted = ", ".join(str(path) for path in candidates)
        die(f"multiple candidate binaries for {platform.target}: {formatted}")
    return candidates[0]


def package_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def write_executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def stage_npm_packages(artifacts_dir: Path, dist_dir: Path, version: str, scope: str) -> None:
    version = normalize_version(version)
    scope = scope.strip().rstrip("/")
    if not scope.startswith("@"):
        die("--scope must be an npm scope such as @clanker-code")

    if dist_dir.exists():
        shutil.rmtree(dist_dir)
    dist_dir.mkdir(parents=True)

    optional_dependencies: dict[str, str] = {}
    for platform in PLATFORMS.values():
        pkg_name = f"{scope}/c2c-{platform.npm_suffix}"
        optional_dependencies[pkg_name] = version
        pkg_dir = dist_dir / f"c2c-{platform.npm_suffix}"
        bin_dir = pkg_dir / "bin"
        bin_dir.mkdir(parents=True)
        shutil.copy2(artifact_binary(artifacts_dir, platform, platform.exe_name), bin_dir / platform.exe_name)
        (bin_dir / platform.exe_name).chmod(0o755)
        shutil.copy2(artifact_binary(artifacts_dir, platform, "c2c-deliver-inbox"), bin_dir / "c2c-deliver-inbox")
        (bin_dir / "c2c-deliver-inbox").chmod(0o755)
        package_json(pkg_dir / "package.json", {
            "name": pkg_name,
            "version": version,
            "description": f"c2c CLI binary for {platform.target}",
            "license": "MIT",
            "repository": REPOSITORY,
            "os": [platform.os_name],
            "cpu": [platform.cpu],
            "files": ["bin/"],
            "bin": {
                "c2c": f"bin/{platform.exe_name}",
                "c2c-deliver-inbox": "bin/c2c-deliver-inbox",
            },
        })

    meta_dir = dist_dir / "c2c"
    source_pkg = repo_root() / "npm-pkgs" / "c2c"
    (meta_dir / "bin").mkdir(parents=True)
    package_json(meta_dir / "package.json", {
        "name": f"{scope}/c2c",
        "version": version,
        "description": "Resolver and CLI wrapper for the c2c agent messaging binary",
        "license": "MIT",
        "repository": REPOSITORY,
        "main": "index.js",
        "bin": {
            "c2c": "bin/c2c-js-wrapper.js",
            "c2c-deliver-inbox": "bin/c2c-deliver-inbox-js-wrapper.js",
        },
        "files": ["bin/", "index.js"],
        "optionalDependencies": optional_dependencies,
    })
    shutil.copy2(source_pkg / "index.js", meta_dir / "index.js")
    shutil.copy2(source_pkg / "bin" / "c2c-js-wrapper.js", meta_dir / "bin" / "c2c-js-wrapper.js")
    shutil.copy2(source_pkg / "bin" / "c2c-js-wrapper.js", meta_dir / "bin" / "c2c-deliver-inbox-js-wrapper.js")
    (meta_dir / "bin" / "c2c-js-wrapper.js").chmod(0o755)
    (meta_dir / "bin" / "c2c-deliver-inbox-js-wrapper.js").chmod(0o755)
    print(dist_dir)


def write_publish_order(dist_dir: Path, out: Path) -> None:
    packages = sorted(path for path in dist_dir.iterdir() if (path / "package.json").exists())
    platform_packages = [path for path in packages if path.name != "c2c"]
    meta = [path for path in packages if path.name == "c2c"]
    ordered = platform_packages + meta
    if not ordered or not meta:
        die(f"npm package staging incomplete under {dist_dir}")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(str(path) for path in ordered) + "\n", encoding="utf-8")
    print(out)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("version", help="print ocaml/version.ml semver")
    p.add_argument("--root", type=Path, default=repo_root())

    p = sub.add_parser("validate", help="validate version and changelog")
    p.add_argument("--root", type=Path, default=repo_root())
    p.add_argument("--version", required=True)

    p = sub.add_parser("notes", help="write release notes from docs/changelog.md")
    p.add_argument("--root", type=Path, default=repo_root())
    p.add_argument("--version", required=True)
    p.add_argument("--out", type=Path, required=True)

    p = sub.add_parser("checksums", help="write SHA256SUMS for a directory")
    p.add_argument("--input-dir", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)

    p = sub.add_parser("manifest", help="write a release artifact manifest")
    p.add_argument("--root", type=Path, default=repo_root())
    p.add_argument("--artifacts-dir", type=Path, required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--out", type=Path, required=True)

    p = sub.add_parser("package-npm", help="stage npm meta/platform packages")
    p.add_argument("--artifacts-dir", type=Path, required=True)
    p.add_argument("--dist-dir", type=Path, required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--scope", default="@clanker-code")

    p = sub.add_parser("npm-publish-order", help="write platform-before-meta publish order")
    p.add_argument("--dist-dir", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)

    args = parser.parse_args(argv)
    if args.cmd == "version":
        print(read_ocaml_version(args.root))
    elif args.cmd == "validate":
        validate_release(args.root, args.version)
    elif args.cmd == "notes":
        write_release_notes(args.root, args.version, args.out)
    elif args.cmd == "checksums":
        write_checksums(args.input_dir, args.out)
    elif args.cmd == "manifest":
        write_manifest(args.root, args.artifacts_dir, args.version, args.out)
    elif args.cmd == "package-npm":
        stage_npm_packages(args.artifacts_dir, args.dist_dir, args.version, args.scope)
    elif args.cmd == "npm-publish-order":
        write_publish_order(args.dist_dir, args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
