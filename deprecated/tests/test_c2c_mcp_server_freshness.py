"""Tests for c2c_mcp.server_is_fresh() binary freshness check."""
from __future__ import annotations

import os
import time
from pathlib import Path

import pytest

import c2c_mcp
from c2c_mcp import server_is_fresh


class TestServerIsFresh:
    def test_returns_false_when_binary_missing(self, tmp_path: Path) -> None:
        assert not server_is_fresh(tmp_path / "nonexistent.exe")

    def test_returns_true_when_no_ocaml_sources_exist(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Binary is fresh when there are no OCaml source files to check."""
        binary = tmp_path / "server.exe"
        binary.write_bytes(b"fake binary")
        monkeypatch.setattr(c2c_mcp, "ROOT", tmp_path)

        assert server_is_fresh(binary)

    def test_returns_true_when_binary_newer_than_sources(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Binary is fresh when it's newer than all source files."""
        monkeypatch.setattr(c2c_mcp, "ROOT", tmp_path)
        ocaml_dir = tmp_path / "ocaml"
        ocaml_dir.mkdir()
        src = ocaml_dir / "my_module.ml"
        src.write_text("let () = ()")
        old_time = time.time() - 100
        os.utime(src, (old_time, old_time))
        binary = tmp_path / "server.exe"
        binary.write_bytes(b"fake binary")

        assert server_is_fresh(binary)

    def test_returns_false_when_source_newer_than_binary(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Binary is stale when any source file is newer."""
        monkeypatch.setattr(c2c_mcp, "ROOT", tmp_path)
        ocaml_dir = tmp_path / "ocaml"
        ocaml_dir.mkdir()
        binary = tmp_path / "server.exe"
        binary.write_bytes(b"old binary")
        old_time = time.time() - 100
        os.utime(binary, (old_time, old_time))
        src = ocaml_dir / "my_module.ml"
        src.write_text("let () = ()")

        assert not server_is_fresh(binary)

    def test_checks_dune_build_files(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A newer dune file also triggers rebuild."""
        monkeypatch.setattr(c2c_mcp, "ROOT", tmp_path)
        ocaml_dir = tmp_path / "ocaml"
        ocaml_dir.mkdir()
        binary = tmp_path / "server.exe"
        binary.write_bytes(b"old binary")
        old_time = time.time() - 100
        os.utime(binary, (old_time, old_time))
        dune_file = ocaml_dir / "dune"
        dune_file.write_text("(executable (name foo))")

        assert not server_is_fresh(binary)

    def test_checks_mli_interface_files(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A newer .mli file also triggers rebuild."""
        monkeypatch.setattr(c2c_mcp, "ROOT", tmp_path)
        ocaml_dir = tmp_path / "ocaml"
        ocaml_dir.mkdir()
        binary = tmp_path / "server.exe"
        binary.write_bytes(b"old binary")
        old_time = time.time() - 100
        os.utime(binary, (old_time, old_time))
        mli = ocaml_dir / "my_module.mli"
        mli.write_text("val x : int")

        assert not server_is_fresh(binary)

    def test_returns_true_when_all_sources_older(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Binary is fresh when all source files are older."""
        monkeypatch.setattr(c2c_mcp, "ROOT", tmp_path)
        ocaml_dir = tmp_path / "ocaml"
        ocaml_dir.mkdir()
        old_time = time.time() - 200
        for name in ("a.ml", "b.mli", "dune"):
            src = ocaml_dir / name
            src.write_text("content")
            os.utime(src, (old_time, old_time))
        binary = tmp_path / "server.exe"
        binary.write_bytes(b"fresh binary")

        assert server_is_fresh(binary)

    def test_ignores_ocaml_cli_sources(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A newer ocaml/cli source does not make the server binary appear stale."""
        monkeypatch.setattr(c2c_mcp, "ROOT", tmp_path)
        ocaml_dir = tmp_path / "ocaml"
        ocaml_dir.mkdir()
        cli_dir = ocaml_dir / "cli"
        cli_dir.mkdir()
        binary = tmp_path / "server.exe"
        binary.write_bytes(b"old binary")
        old_time = time.time() - 100
        os.utime(binary, (old_time, old_time))
        cli_src = cli_dir / "c2c_cli.ml"
        cli_src.write_text("let () = ()")

        assert server_is_fresh(binary)
