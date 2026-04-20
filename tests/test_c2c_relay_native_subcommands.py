"""Regression guards for the native OCaml `c2c relay` subcommands.

`c2c relay status`, `list`, `rooms list`, and `gc --once` no longer
shell out to Python for the common path — they talk directly to the
relay server via `Relay_client` in `ocaml/relay.ml`. These tests make
sure a regression that re-introduces the Python shellout would be
visible.

The test pokes the binary at an unreachable URL and asserts the JSON
error envelope surfaces (`error_code: connection_error`), which only
the native OCaml client emits. The Python fallback path raises
`requests.ConnectionError` and prints a non-JSON traceback, so
stringent JSON shape matching is sufficient to distinguish.

See commits bbaf8e8 (status), b7a789b (list), 6a1f8cb (rooms list + gc).
"""

import json
import os
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BINARY = REPO / "_build" / "default" / "ocaml" / "cli" / "c2c.exe"

# Port 1 is reserved (tcpmux) and refuses connections on Linux; 127.0.0.1
# keeps the test localhost-only and deterministic.
DEAD_URL = "http://127.0.0.1:1"


class NativeRelaySubcommandTests(unittest.TestCase):
    def setUp(self):
        if not BINARY.exists():
            self.skipTest(
                f"c2c binary missing at {BINARY}; "
                "run `dune build ./ocaml/cli/c2c.exe` first"
            )

    def _run(self, *args):
        return subprocess.run(
            [str(BINARY), "relay", *args, "--relay-url", DEAD_URL],
            env={**os.environ, "C2C_RELAY_URL": "", "C2C_RELAY_TOKEN": ""},
            capture_output=True,
            text=True,
            timeout=10,
        )

    def _assert_native_connection_error(self, result, subcmd_desc):
        # Native path exits 1 and prints a JSON envelope; Python shellout
        # would either traceback (non-zero, non-JSON) or succeed (0).
        self.assertEqual(
            result.returncode,
            1,
            f"{subcmd_desc}: expected exit 1 on unreachable URL "
            f"(got {result.returncode})\nstdout: {result.stdout}\n"
            f"stderr: {result.stderr}",
        )
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            self.fail(
                f"{subcmd_desc}: native path must emit JSON to stdout, "
                f"got non-JSON (decode error: {exc}).\nstdout: "
                f"{result.stdout!r}\nstderr: {result.stderr!r}"
            )
        self.assertEqual(payload.get("ok"), False, f"{subcmd_desc}: ok=false expected")
        self.assertEqual(
            payload.get("error_code"),
            "connection_error",
            f"{subcmd_desc}: Relay_client surfaces connection_error; a "
            f"different error_code suggests the subcommand regressed to "
            f"the Python shellout. Payload: {payload}",
        )

    def test_relay_status_native(self):
        self._assert_native_connection_error(self._run("status"), "relay status")

    def test_relay_list_native(self):
        self._assert_native_connection_error(self._run("list"), "relay list")

    def test_relay_rooms_list_native(self):
        self._assert_native_connection_error(
            self._run("rooms", "list"), "relay rooms list"
        )

    def test_relay_gc_once_native(self):
        self._assert_native_connection_error(
            self._run("gc", "--once"), "relay gc --once"
        )

    def test_relay_rooms_history_native(self):
        self._assert_native_connection_error(
            self._run("rooms", "history", "--room", "swarm-lounge"),
            "relay rooms history --room swarm-lounge",
        )

    def test_relay_rooms_join_native(self):
        self._assert_native_connection_error(
            self._run("rooms", "join", "--room", "r", "--alias", "a"),
            "relay rooms join",
        )

    def test_relay_rooms_leave_native(self):
        self._assert_native_connection_error(
            self._run("rooms", "leave", "--room", "r", "--alias", "a"),
            "relay rooms leave",
        )

    def test_relay_rooms_send_native(self):
        self._assert_native_connection_error(
            self._run("rooms", "send", "--room", "r", "--alias", "a", "hello", "world"),
            "relay rooms send",
        )


if __name__ == "__main__":
    unittest.main()
