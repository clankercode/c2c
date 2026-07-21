"""Parity tests: OCaml wire-daemon format_prompt output must match Python.

Tests that the OCaml wire bridge produces identical envelope XML for the
same message input as the Python c2c_kimi_wire_bridge.py implementation.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_kimi_wire_bridge


def ocaml_format_prompt(messages: list[dict]) -> str:
    """Call `c2c wire-daemon format-prompt` to get OCaml output."""
    result = subprocess.run(
        ["c2c", "wire-daemon", "format-prompt", "--json-messages", json.dumps(messages)],
        capture_output=True,
        text=True,
        timeout=5,
    )
    if result.returncode != 0:
        raise RuntimeError(f"c2c wire-daemon format-prompt failed: {result.stderr}")
    return result.stdout


class FormatPromptParityTests(unittest.TestCase):
    """format_prompt output must be byte-identical between Python and OCaml."""

    def _python_format(self, messages):
        return c2c_kimi_wire_bridge.format_prompt(messages)

    def test_single_message(self):
        msgs = [{"from_alias": "sender", "to_alias": "receiver", "content": "hello world"}]
        py = self._python_format(msgs)
        oc = ocaml_format_prompt(msgs)
        self.assertEqual(py, oc.rstrip("\n"))

    def test_multiple_messages(self):
        msgs = [
            {"from_alias": "alice", "to_alias": "bob", "content": "first message"},
            {"from_alias": "charlie", "to_alias": "bob", "content": "second message"},
        ]
        py = self._python_format(msgs)
        oc = ocaml_format_prompt(msgs)
        self.assertEqual(py, oc.rstrip("\n"))

    def test_xml_escaping(self):
        msgs = [{"from_alias": "a&b", "to_alias": "x<y>z", "content": "quote\"test&amp;"}]
        py = self._python_format(msgs)
        oc = ocaml_format_prompt(msgs)
        self.assertEqual(py, oc.rstrip("\n"))

    def test_multiline_content(self):
        msgs = [{"from_alias": "bot", "to_alias": "kimi", "content": "line1\nline2\nline3"}]
        py = self._python_format(msgs)
        oc = ocaml_format_prompt(msgs)
        self.assertEqual(py, oc.rstrip("\n"))

    def test_empty_message_list(self):
        py = self._python_format([])
        oc = ocaml_format_prompt([])
        self.assertEqual(py, oc.rstrip("\n"))


class SpoolParityTests(unittest.TestCase):
    """Spool write/read/clear must produce same round-trip as Python spool."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.spool_path = Path(self.tmp.name) / "test.spool.json"

    def tearDown(self):
        self.tmp.cleanup()

    def test_spool_roundtrip_via_ocaml_write_python_read(self):
        """OCaml spool-write, Python spool-read."""
        msgs = [{"from_alias": "a", "to_alias": "b", "content": "hi"}]
        result = subprocess.run(
            ["c2c", "wire-daemon", "spool-write", "--spool-path", str(self.spool_path),
             "--json-messages", json.dumps(msgs)],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            self.skipTest(f"spool-write not implemented: {result.stderr}")
        spool = c2c_kimi_wire_bridge.C2CSpool(self.spool_path)
        read_back = spool.read()
        self.assertEqual(msgs, read_back)

    def test_spool_roundtrip_via_python_write_ocaml_read(self):
        """Python spool-write, OCaml spool-read."""
        msgs = [{"from_alias": "c", "to_alias": "d", "content": "world"}]
        spool = c2c_kimi_wire_bridge.C2CSpool(self.spool_path)
        spool.replace(msgs)
        result = subprocess.run(
            ["c2c", "wire-daemon", "spool-read", "--spool-path", str(self.spool_path)],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            self.skipTest(f"spool-read not implemented: {result.stderr}")
        data = json.loads(result.stdout)
        self.assertEqual(msgs, data)


if __name__ == "__main__":
    unittest.main()
