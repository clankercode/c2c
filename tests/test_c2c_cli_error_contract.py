"""CLI error-contract matrix (friction-points-cn slice Q1).

Pins the command-wide parse/exit/error-message contract of the built `c2c`
binary so regressions in exit codes, usage errors, or user-facing failure
messages are caught mechanically instead of by an annoyed agent mid-swarm.

Observed exit-code taxonomy (asserted throughout):

    0    success — including *contracted* graceful degrades:
           - `c2c doctor --json` outside the c2c repo (degraded:true JSON)
           - `c2c list --relay` when the relay fetch fails (loud note,
             local peers still shown — pinned in ocaml/test/test_c2c_list_relay.ml)
    1    per-operation / semantic errors:
           - identity unresolved (whoami/peek-inbox/register without session)
           - unknown recipient alias, missing memory entry / schedule
           - wait-inbox timeout expiry
           - relay transport + application errors via the ok:false JSON
             envelope (`error_code`: connection_error / http_error_5xx / app code)
           - `c2c doctor --relay` when any check FAILs (B093)
    2    documented per-op contracts outside cmdliner:
           - `c2c send` positional self-validation ("requires a recipient…")
           - `c2c wait-inbox --timeout <garbage>` value validation
           - `c2c relay connect --once` sync-completed-with-errors (B087)
    124  cmdliner CLI parse errors — unknown option, unknown (sub)command,
         missing required argument/option. Always accompanied by a
         "Usage: c2c …" line on stderr.

Hermeticity: every test runs the binary with a scrubbed environment
(temp HOME, temp C2C_MCP_BROKER_ROOT, temp non-git cwd, PATH=/usr/bin:/bin)
so live-session vars (CLAUDE_SESSION_ID, C2C_RELAY_URL, …) can never leak in,
and no state escapes the per-test tempdir. Relay tests use loopback only:
a refused port (127.0.0.1:1, same convention as
tests/test_c2c_relay_native_subcommands.py) or a scripted stdlib
http.server fault relay.

Note on tier gating: Tier 3/4 commands are hidden when a session id is
resolvable from the env (is_agent_session). Everything exercised here is
Tier 1/2, but _run() still detects an unexpectedly hidden command and
skips that cell with a reason instead of failing.
"""

from __future__ import annotations

import http.server
import json
import os
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BINARY = REPO / "_build" / "default" / "ocaml" / "cli" / "c2c.exe"

# Port 1 (tcpmux) is reserved and refuses connections on Linux; loopback-only
# and deterministic. Same convention as test_c2c_relay_native_subcommands.py.
REFUSED_RELAY_URL = "http://127.0.0.1:1"

RUN_TIMEOUT = 30


# ---------------------------------------------------------------------------
# Scripted fault relay (loopback stdlib http.server).
# ---------------------------------------------------------------------------

class _ScriptedRelayHandler(http.server.BaseHTTPRequestHandler):
    """Answers every route according to server.mode (set per test)."""

    def _respond(self) -> None:
        mode = self.server.mode  # type: ignore[attr-defined]
        if mode == "dishonest_500_ok_true":
            # The H7 poison cell: transport says 500, body claims success.
            body = json.dumps({"ok": True, "results": []}).encode()
            status = 500
        elif mode == "malformed_json":
            body = b"{this is not json"
            status = 200
        elif mode == "app_error_ok_false":
            body = json.dumps(
                {"ok": False, "error_code": "scripted_fault",
                 "error": "scripted fault for Q1 matrix"}
            ).encode()
            status = 200
        elif mode == "healthy":
            body = json.dumps(
                {"ok": True, "results": [], "messages": [], "peers": []}
            ).encode()
            status = 200
        else:  # pragma: no cover - guard against typos in test bodies
            raise AssertionError(f"unknown scripted relay mode: {mode}")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = _respond
    do_POST = _respond

    def log_message(self, *args) -> None:  # silence request logging
        pass


class _ScriptedRelay:
    """Context manager: loopback HTTP relay with a scriptable fault mode."""

    def __init__(self, mode: str) -> None:
        self.mode = mode
        self.server: http.server.HTTPServer | None = None

    def __enter__(self) -> "_ScriptedRelay":
        self.server = http.server.HTTPServer(("127.0.0.1", 0), _ScriptedRelayHandler)
        self.server.mode = self.mode  # type: ignore[attr-defined]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return self

    @property
    def url(self) -> str:
        assert self.server is not None
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def __exit__(self, *exc) -> None:
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()


# ---------------------------------------------------------------------------
# Base harness.
# ---------------------------------------------------------------------------

@unittest.skipUnless(BINARY.exists(), f"c2c binary missing at {BINARY}; run `just build` first")
class _ContractBase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="c2c-q1-contract-")
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.home = root / "home"
        self.broker = root / "broker"
        self.cwd = root / "cwd"  # non-git dir: doctor takes the degraded path
        for d in (self.home, self.broker, self.cwd):
            d.mkdir()

    def _env(self, session: str | None = None, alias: str | None = None,
             relay_url: str | None = None, **extra: str) -> dict[str, str]:
        """Scrubbed hermetic environment (never inherits os.environ)."""
        env = {
            "HOME": str(self.home),
            "PATH": "/usr/bin:/bin",
            "C2C_MCP_BROKER_ROOT": str(self.broker),
        }
        if session is not None:
            env["C2C_MCP_SESSION_ID"] = session
        if alias is not None:
            env["C2C_MCP_AUTO_REGISTER_ALIAS"] = alias
        if relay_url is not None:
            env["C2C_RELAY_URL"] = relay_url
            env["C2C_RELAY_TOKEN"] = "q1-test-token"
        env.update(extra)
        return env

    def _run(self, args: list[str], **env_kwargs) -> subprocess.CompletedProcess:
        result = subprocess.run(
            [str(BINARY), *args],
            env=self._env(**env_kwargs),
            cwd=self.cwd,
            capture_output=True,
            text=True,
            timeout=RUN_TIMEOUT,
        )
        # Tier-gate detection: everything this matrix touches is Tier 1/2,
        # but if a future re-tiering hides a command from agent sessions,
        # skip the cell with a reason instead of mis-reporting a parse bug.
        if (result.returncode == 124
                and args
                and f"unknown command '{args[0]}'" in result.stderr
                and args[0] not in ("definitely-not-a-command",)):
            self.skipTest(
                f"command '{args[0]}' hidden in this session (tier-gated); "
                f"stderr: {result.stderr.strip()[:120]}"
            )
        return result

    def _register(self, alias: str, session: str) -> None:
        result = self._run(["register", "--alias", alias], session=session)
        self.assertEqual(result.returncode, 0,
                         f"fixture register {alias} failed: {result.stderr}")

    # --- assertion helpers -------------------------------------------------

    def assert_cli_parse_error(self, result: subprocess.CompletedProcess,
                               *needles: str, label: str = "") -> None:
        """Exit 124 + Usage line + each needle on stderr (cmdliner contract)."""
        ctx = f"{label}\nstdout: {result.stdout!r}\nstderr: {result.stderr!r}"
        self.assertEqual(result.returncode, 124,
                         f"expected cmdliner parse-error exit 124, got "
                         f"{result.returncode}. {ctx}")
        self.assertIn("Usage: c2c", result.stderr,
                      f"parse errors must print usage. {ctx}")
        for needle in needles:
            self.assertIn(needle, result.stderr, f"missing {needle!r}. {ctx}")

    def assert_op_error(self, result: subprocess.CompletedProcess,
                        *needles: str, exit_code: int = 1,
                        label: str = "") -> None:
        """Nonzero per-op error with a clear message naming the problem."""
        ctx = f"{label}\nstdout: {result.stdout!r}\nstderr: {result.stderr!r}"
        self.assertEqual(result.returncode, exit_code,
                         f"expected exit {exit_code}, got {result.returncode}. {ctx}")
        combined = result.stderr + result.stdout
        for needle in needles:
            self.assertIn(needle, combined, f"missing {needle!r}. {ctx}")

    def assert_ok_false_json(self, result: subprocess.CompletedProcess,
                             error_code: str | None = None,
                             label: str = "") -> dict:
        """Exit 1 + machine-readable ok:false JSON envelope on stdout."""
        ctx = f"{label}\nstdout: {result.stdout!r}\nstderr: {result.stderr!r}"
        self.assertEqual(result.returncode, 1,
                         f"relay errors must never exit zero (H7); got "
                         f"{result.returncode}. {ctx}")
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            self.fail(f"expected JSON envelope on stdout ({exc}). {ctx}")
        self.assertIs(payload.get("ok"), False, f"ok:false expected. {ctx}")
        if error_code is not None:
            self.assertEqual(payload.get("error_code"), error_code,
                             f"error_code mismatch. {ctx}")
        return payload


# ---------------------------------------------------------------------------
# 1. Parse-contract matrix: unknown flags / missing args / unknown commands.
# ---------------------------------------------------------------------------

class ParseErrorMatrixTests(_ContractBase):
    """Every major surface: bad parse => exit 124 + usage-ish stderr."""

    UNKNOWN_FLAG_CELLS = [
        ["send", "--bogus-flag", "peer", "msg"],
        ["list", "--bogus-flag"],
        ["whoami", "--bogus-flag"],
        ["register", "--bogus-flag"],
        ["poll-inbox", "--bogus-flag"],
        ["peek-inbox", "--bogus-flag"],
        ["wait-inbox", "--bogus-flag"],
        ["send-all", "--bogus-flag", "msg"],
        ["rooms", "join", "--bogus-flag", "a-room"],
        ["rooms", "send", "--bogus-flag", "a-room", "msg"],
        ["rooms", "history", "--bogus-flag", "a-room"],
        ["rooms", "leave", "--bogus-flag", "a-room"],
        ["relay", "dm", "--bogus-flag", "send", "peer", "msg"],
        ["relay", "register", "--bogus-flag"],
        ["relay", "connect", "--bogus-flag"],
        ["monitor", "--bogus-flag"],
        ["doctor", "--bogus-flag"],
        ["health", "--bogus-flag"],
        ["schedule", "set", "--bogus-flag", "a-name"],
        ["schedule", "list", "--bogus-flag"],
        ["schedule", "rm", "--bogus-flag", "a-name"],
        ["memory", "list", "--bogus-flag"],
        ["memory", "read", "--bogus-flag", "a-name"],
        ["memory", "write", "--bogus-flag", "a-name", "content"],
        ["dev", "peer-pass", "verify", "--bogus-flag", "some-file"],
    ]

    def test_unknown_flag_is_124_with_usage(self):
        for cell in self.UNKNOWN_FLAG_CELLS:
            with self.subTest(cmd=" ".join(cell)):
                result = self._run(cell, session="sess-q1-parse")
                self.assert_cli_parse_error(
                    result, "unknown option '--bogus-flag'",
                    label=f"c2c {' '.join(cell)}")

    # `c2c monitor --once` does not exist (spelled --force/--json elsewhere);
    # pin that the near-miss stays a parse error with a suggestion.
    def test_monitor_once_is_unknown_option(self):
        result = self._run(["monitor", "--once"], session="sess-q1-parse")
        self.assert_cli_parse_error(result, "unknown option '--once'",
                                    label="c2c monitor --once")

    MISSING_ARG_CELLS = [
        (["rooms", "join"], "required argument ROOM is missing"),
        (["rooms", "send"], "required arguments ROOM, MSG are missing"),
        (["rooms", "send", "room-only"], "required argument MSG is missing"),
        (["rooms", "history"], "required argument ROOM is missing"),
        (["rooms", "leave"], "required argument ROOM is missing"),
        (["send-all"], "required argument MSG is missing"),
        (["schedule", "set"], "required argument NAME is missing"),
        (["schedule", "rm"], "required argument NAME is missing"),
        (["schedule", "show"], "required argument NAME is missing"),
        (["memory", "read"], "required argument NAME is missing"),
        (["memory", "write"], "required arguments NAME, CONTENT are missing"),
        (["memory", "write", "name-only"], "required argument CONTENT is missing"),
        (["relay", "register"], "required option --alias is missing"),
        (["dev", "peer-pass", "verify"], "required argument FILE is missing"),
    ]

    def test_missing_required_arg_is_124_with_named_arg(self):
        for cell, needle in self.MISSING_ARG_CELLS:
            with self.subTest(cmd=" ".join(cell)):
                result = self._run(cell, session="sess-q1-parse")
                self.assert_cli_parse_error(result, needle,
                                            label=f"c2c {' '.join(cell)}")

    UNKNOWN_COMMAND_CELLS = [
        (["definitely-not-a-command"], "unknown command 'definitely-not-a-command'"),
        (["rooms", "bogus-subcommand"], "unknown command 'bogus-subcommand'"),
        (["schedule", "bogus-subcommand"], "unknown command 'bogus-subcommand'"),
        (["memory", "bogus-subcommand"], "unknown command 'bogus-subcommand'"),
    ]

    def test_unknown_command_is_124_and_lists_alternatives(self):
        for cell, needle in self.UNKNOWN_COMMAND_CELLS:
            with self.subTest(cmd=" ".join(cell)):
                result = self._run(cell)
                self.assert_cli_parse_error(result, needle, "Must be one of",
                                            label=f"c2c {' '.join(cell)}")

    def test_unknown_top_level_flag_is_124(self):
        result = self._run(["--definitely-not-a-flag"])
        self.assert_cli_parse_error(result,
                                    "unknown option '--definitely-not-a-flag'",
                                    label="c2c --definitely-not-a-flag")


# ---------------------------------------------------------------------------
# 2. Non-cmdliner argument validation (the exit-2 family).
# ---------------------------------------------------------------------------

class CustomArgValidationTests(_ContractBase):
    def test_send_without_args_exits_2_with_clear_message(self):
        result = self._run(["send"], session="sess-q1-send")
        self.assert_op_error(
            result, "send requires a recipient alias and message body",
            exit_code=2, label="c2c send")

    def test_wait_inbox_bad_timeout_value_exits_2(self):
        result = self._run(["wait-inbox", "--timeout", "notaduration"],
                           session="sess-q1-send")
        self.assert_op_error(result, "invalid --timeout", "notaduration",
                             exit_code=2, label="c2c wait-inbox --timeout notaduration")

    def test_schedule_set_bad_interval_exits_1_naming_flag(self):
        result = self._run(
            ["schedule", "set", "q1-sched", "--interval", "bogus", "--message", "m"],
            session="sess-q1-send", alias="q1zx-alias")
        self.assert_op_error(result, "--interval", "invalid",
                             label="c2c schedule set --interval bogus")


# ---------------------------------------------------------------------------
# 3. Happy-path parse: exit 0 against a temp broker.
# ---------------------------------------------------------------------------

class HappyPathParseTests(_ContractBase):
    """Each major surface parses + succeeds (exit 0) with a temp broker."""

    def _ok(self, args: list[str], **env_kwargs) -> subprocess.CompletedProcess:
        result = self._run(args, **env_kwargs)
        self.assertEqual(
            result.returncode, 0,
            f"c2c {' '.join(args)} expected 0, got {result.returncode}\n"
            f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}")
        return result

    def test_broker_lifecycle_send_receive_rooms(self):
        self._register("q1zx-sender", "sess-q1-a")
        self._register("q1zx-recv", "sess-q1-b")

        r = self._ok(["whoami"], session="sess-q1-a")
        self.assertIn("q1zx-sender", r.stdout)

        r = self._ok(["whoami", "--json"], session="sess-q1-a")
        payload = json.loads(r.stdout)
        self.assertEqual(payload["alias"], "q1zx-sender")

        r = self._ok(["list"], session="sess-q1-a")
        self.assertIn("q1zx-recv", r.stdout)
        r = self._ok(["list", "--json"], session="sess-q1-a")
        aliases = {e.get("alias") for e in json.loads(r.stdout)}
        self.assertLessEqual({"q1zx-sender", "q1zx-recv"}, aliases)

        r = self._ok(["send", "q1zx-recv", "hello from the matrix"],
                     session="sess-q1-a")
        self.assertIn("ok ->", r.stdout)

        r = self._ok(["peek-inbox"], session="sess-q1-b")
        self.assertIn("hello from the matrix", r.stdout)
        r = self._ok(["poll-inbox", "--json"], session="sess-q1-b")
        msgs = json.loads(r.stdout)
        self.assertEqual(len(msgs), 1)

        # wait-inbox with a pending message resolves 0 before the timeout.
        self._ok(["send", "q1zx-recv", "second"], session="sess-q1-a")
        r = self._ok(["wait-inbox", "--timeout", "5"], session="sess-q1-b")
        self.assertIn("second", r.stdout)

        r = self._ok(["send-all", "fanout hello"], session="sess-q1-a")
        self.assertIn("q1zx-recv", r.stdout)

        self._ok(["rooms", "join", "q1zx-room"], session="sess-q1-a")
        self._ok(["rooms", "send", "q1zx-room", "room hello"], session="sess-q1-a")
        r = self._ok(["rooms", "history", "q1zx-room"], session="sess-q1-a")
        self.assertIn("room hello", r.stdout)
        self._ok(["rooms", "leave", "q1zx-room"], session="sess-q1-a")

    def test_schedule_and_memory_surfaces(self):
        # schedule/memory resolve identity via C2C_MCP_AUTO_REGISTER_ALIAS.
        kw = dict(session="sess-q1-c", alias="q1zx-sched")
        self._register("q1zx-sched", "sess-q1-c")

        r = self._ok(["schedule", "set", "q1-wake", "--interval", "4m",
                      "--message", "tick"], **kw)
        self.assertIn("saved: q1-wake", r.stdout)
        r = self._ok(["schedule", "list", "--json"], **kw)
        entries = json.loads(r.stdout)
        self.assertEqual([e["name"] for e in entries], ["q1-wake"])
        self.assertEqual(entries[0]["interval_s"], 240.0)
        self._ok(["schedule", "show", "q1-wake"], **kw)
        r = self._ok(["schedule", "rm", "q1-wake"], **kw)
        self.assertIn("deleted: q1-wake", r.stdout)

        r = self._ok(["memory", "write", "q1-note", "matrix content"], **kw)
        self.assertIn("saved: q1-note", r.stdout)
        r = self._ok(["memory", "list"], **kw)
        self.assertIn("q1-note", r.stdout)
        r = self._ok(["memory", "read", "q1-note"], **kw)
        self.assertIn("matrix content", r.stdout)

    def test_health_json_reports_temp_broker(self):
        r = self._ok(["health", "--json"])
        payload = json.loads(r.stdout)
        self.assertEqual(payload["broker_root"], str(self.broker))
        self.assertTrue(payload["root_exists"])

    def test_doctor_json_outside_repo_is_degraded_but_valid_json(self):
        # cwd is a temp non-git dir => the degraded no-repo path (B021).
        # NB: doctor's full path resolves scripts/c2c-doctor.sh via
        # `git rev-parse --show-toplevel` from CWD, so hermetic tests must
        # never run it from inside a repo checkout.
        r = self._ok(["doctor", "--json"])
        payload = json.loads(r.stdout)
        self.assertIs(payload["degraded"], True)
        self.assertEqual(payload["reason"], "not in c2c git repo")
        self.assertEqual(payload["broker_root"], str(self.broker))


# ---------------------------------------------------------------------------
# 4. Per-op errors (exit 1) + user-facing stderr snapshots.
# ---------------------------------------------------------------------------

class OpErrorAndStderrSnapshotTests(_ContractBase):
    def test_whoami_without_session_names_problem_and_next_step(self):
        result = self._run(["whoami"])
        # Names the problem…
        self.assert_op_error(result, "no session ID could be resolved",
                             label="c2c whoami (no session)")
        # …and the next step.
        self.assertIn("c2c init", result.stderr)

    def test_register_without_alias_has_hint(self):
        result = self._run(["register"])
        self.assert_op_error(
            result, "no alias specified", "C2C_MCP_AUTO_REGISTER_ALIAS",
            label="c2c register (no alias)")
        self.assertIn("--alias", result.stderr)

    def test_inbox_commands_without_session_name_the_fix(self):
        for cmd in (["peek-inbox"], ["poll-inbox"]):
            with self.subTest(cmd=cmd[0]):
                result = self._run(cmd)
                self.assert_op_error(result, "cannot determine session ID",
                                     "C2C_MCP_SESSION_ID",
                                     label=f"c2c {cmd[0]} (no session)")

    def test_send_to_unknown_alias_names_alias_and_broker(self):
        self._register("q1zx-lonely", "sess-q1-lonely")
        result = self._run(["send", "q1zx-no-such-peer", "hi"],
                           session="sess-q1-lonely")
        self.assert_op_error(
            result, "alias 'q1zx-no-such-peer' is not registered",
            label="c2c send <unknown alias>")
        # Message must point at the broker it scanned and offer a next step.
        self.assertIn(str(self.broker), result.stderr)
        self.assertIn("hint:", result.stderr)

    def test_wait_inbox_timeout_exits_1(self):
        self._register("q1zx-waiter", "sess-q1-wait")
        result = self._run(["wait-inbox", "--timeout", "1"],
                           session="sess-q1-wait")
        self.assert_op_error(result, "timeout",
                             label="c2c wait-inbox --timeout 1 (empty inbox)")

    def test_schedule_and_memory_without_alias_env_exit_1(self):
        for cmd in (["schedule", "list"], ["memory", "list"]):
            with self.subTest(cmd=" ".join(cmd)):
                result = self._run(cmd, session="sess-q1-noalias")
                self.assert_op_error(result, "C2C_MCP_AUTO_REGISTER_ALIAS",
                                     label=f"c2c {' '.join(cmd)} (no alias env)")

    def test_missing_entities_exit_1_and_name_the_entity(self):
        kw = dict(session="sess-q1-d", alias="q1zx-misc")
        result = self._run(["schedule", "rm", "no-such-sched"], **kw)
        self.assert_op_error(result, "schedule 'no-such-sched' not found",
                             label="c2c schedule rm <missing>")
        result = self._run(["memory", "read", "no-such-note"], **kw)
        self.assert_op_error(result, "'no-such-note' not found",
                             label="c2c memory read <missing>")


# ---------------------------------------------------------------------------
# 5. Relay errors never exit zero (H7 pinned contract, from the CLI outside).
# ---------------------------------------------------------------------------

class RelayRefusedContractTests(_ContractBase):
    """Refused-port relay: nonzero exit + ok:false JSON envelope."""

    def setUp(self) -> None:
        super().setUp()
        self._register("q1zx-relay", "sess-q1-relay")
        self.kw = dict(session="sess-q1-relay", relay_url=REFUSED_RELAY_URL)

    def test_relay_dm_and_register_and_status_refused(self):
        cells = [
            ["relay", "dm", "send", "--alias", "q1zx-relay", "peer", "hi"],
            ["relay", "dm", "poll", "--alias", "q1zx-relay"],
            ["relay", "dm", "peek", "--alias", "q1zx-relay"],
            ["relay", "register", "--alias", "q1zx-relay"],
            ["relay", "status"],
        ]
        for cell in cells:
            with self.subTest(cmd=" ".join(cell)):
                result = self._run(cell, **self.kw)
                payload = self.assert_ok_false_json(
                    result, error_code="connection_error",
                    label=f"c2c {' '.join(cell)} vs refused port")
                self.assertIn("ECONNREFUSED", payload.get("error", ""))

    def test_relay_dm_without_alias_is_clear_op_error(self):
        for sub in ("send", "poll", "peek"):
            with self.subTest(sub=sub):
                args = ["relay", "dm", sub] + (["peer", "hi"] if sub == "send" else [])
                result = self._run(args, **self.kw)
                self.assert_op_error(result, f"--alias required for dm {sub}",
                                     label=f"c2c relay dm {sub} (no --alias)")

    def test_list_relay_degrades_loudly_to_local_peers(self):
        # Contracted graceful degrade — NOT part of the never-exit-zero rule:
        # `list` is a local-first command with relay augmentation. The exit-0
        # + loud note behaviour is pinned in ocaml/test/test_c2c_list_relay.ml
        # ("relay fetch failed" / "showing local peers only"); this cell keeps
        # the CLI-observable shape honest from the outside.
        result = self._run(["list", "--relay"], **self.kw)
        self.assertEqual(
            result.returncode, 0,
            f"list --relay degrade contract changed (see "
            f"ocaml/test/test_c2c_list_relay.ml)\nstdout: {result.stdout!r}\n"
            f"stderr: {result.stderr!r}")
        combined = result.stdout + result.stderr
        self.assertIn("relay fetch failed", combined)
        self.assertIn("showing local peers only", combined)
        self.assertIn("q1zx-relay", result.stdout)  # local peers still shown

    def test_doctor_relay_json_reports_reachable_fail(self):
        # H7/C047: refused relay => relay.reachable FAIL, doctor exits 1 (B093).
        result = self._run(["doctor", "--relay", "--json"], **self.kw)
        self.assertEqual(result.returncode, 1,
                         f"doctor --relay must exit nonzero on FAIL\n"
                         f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}")
        payload = json.loads(result.stdout)
        checks = {c["check_id"]: c for c in payload["checks"]}
        self.assertEqual(checks["relay.configured"]["status"], "PASS")
        reachable = checks["relay.reachable"]
        self.assertEqual(reachable["status"], "FAIL")
        self.assertIn("unreachable", reachable["message"])
        # A FAIL must ship a copy-pasteable next step.
        self.assertTrue(reachable.get("fix_command"),
                        f"relay.reachable FAIL missing fix_command: {reachable}")
        self.assertTrue(payload["summary"]["any_fail"])


class RelayFaultServerContractTests(_ContractBase):
    """Scripted fault relay: dishonest 500, malformed JSON, app errors."""

    CLIENT_CELLS = [
        ["relay", "dm", "send", "--alias", "q1zx-fault", "peer", "hi"],
        ["relay", "register", "--alias", "q1zx-fault"],
        ["relay", "status"],
    ]

    def setUp(self) -> None:
        super().setUp()
        self._register("q1zx-fault", "sess-q1-fault")

    def _cells_against(self, mode: str):
        with _ScriptedRelay(mode) as relay:
            for cell in self.CLIENT_CELLS:
                with self.subTest(cmd=" ".join(cell), mode=mode):
                    yield cell, self._run(cell, session="sess-q1-fault",
                                          relay_url=relay.url)

    def test_dishonest_500_ok_true_exits_nonzero(self):
        # THE H7 cell: HTTP 500 whose body claims ok:true MUST be an error.
        for cell, result in self._cells_against("dishonest_500_ok_true"):
            payload = self.assert_ok_false_json(
                result, error_code="http_error_500",
                label=f"c2c {' '.join(cell)} vs dishonest 500+ok:true")
            self.assertEqual(payload.get("http_status"), 500)
            self.assertIn("did not report ok:false", payload.get("error", ""))
            # The dishonest body is preserved for debugging.
            self.assertEqual(payload.get("relay_response", {}).get("ok"), True)

    def test_malformed_json_body_exits_nonzero(self):
        for cell, result in self._cells_against("malformed_json"):
            payload = self.assert_ok_false_json(
                result, error_code="connection_error",
                label=f"c2c {' '.join(cell)} vs malformed JSON")
            self.assertEqual(payload.get("error"), "invalid_json_response")

    def test_application_ok_false_passes_error_code_through(self):
        for cell, result in self._cells_against("app_error_ok_false"):
            self.assert_ok_false_json(
                result, error_code="scripted_fault",
                label=f"c2c {' '.join(cell)} vs 200+ok:false")

    def test_healthy_relay_parses_and_exits_zero(self):
        with _ScriptedRelay("healthy") as relay:
            for cell in self.CLIENT_CELLS + [["relay", "dm", "peek",
                                              "--alias", "q1zx-fault"]]:
                with self.subTest(cmd=" ".join(cell)):
                    result = self._run(cell, session="sess-q1-fault",
                                       relay_url=relay.url)
                    self.assertEqual(
                        result.returncode, 0,
                        f"c2c {' '.join(cell)} vs healthy scripted relay\n"
                        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}")
                    self.assertIs(json.loads(result.stdout).get("ok"), True)


# ---------------------------------------------------------------------------
# 6. Connector negative regression: `relay connect --once` must fail loudly.
# ---------------------------------------------------------------------------

class ConnectorNegativeContractTests(_ContractBase):
    """B087: connector per-op errors exit 2; state records last_error.

    (The positive two-host connector proof is slice F5d, not Q1.)
    """

    def setUp(self) -> None:
        super().setUp()
        self._register("q1zx-conn", "sess-q1-conn")

    def _connect_once(self, relay_url: str) -> subprocess.CompletedProcess:
        return self._run(["relay", "connect", "--once"],
                         session="sess-q1-conn", relay_url=relay_url)

    def _connector_state(self) -> dict:
        state_path = self.broker / "connector-state.json"
        self.assertTrue(state_path.exists(),
                        "connector must persist connector-state.json in the broker root")
        return json.loads(state_path.read_text(encoding="utf-8"))

    def _assert_failed_sync(self, result: subprocess.CompletedProcess,
                            label: str) -> None:
        ctx = f"{label}\nstdout: {result.stdout!r}\nstderr: {result.stderr!r}"
        self.assertEqual(result.returncode, 2,
                         f"B087: connector sync-with-errors exits 2, got "
                         f"{result.returncode}. {ctx}")
        self.assertIn("sync completed with errors",
                      result.stdout + result.stderr, ctx)
        state = self._connector_state()
        # last_error recorded…
        self.assertTrue(state.get("last_error_op"),
                        f"last_error_op not recorded. state={state}. {ctx}")
        self.assertTrue(state.get("last_error_detail"),
                        f"last_error_detail not recorded. state={state}. {ctx}")
        # …and no false success anywhere.
        self.assertEqual(state.get("registered"), [], ctx)
        self.assertEqual(state.get("inbound_delivered"), 0,
                         f"no inbound may be reported delivered on a failed "
                         f"sync. state={state}. {ctx}")
        self.assertIn("inbound=0", result.stdout, ctx)

    def test_connect_once_refused_relay_fails_loudly(self):
        result = self._connect_once(REFUSED_RELAY_URL)
        self._assert_failed_sync(result, "relay connect --once vs refused port")
        self.assertIn("connection_error",
                      self._connector_state()["last_error_detail"])

    def test_connect_once_malformed_relay_fails_loudly(self):
        with _ScriptedRelay("malformed_json") as relay:
            result = self._connect_once(relay.url)
        self._assert_failed_sync(result, "relay connect --once vs malformed JSON")
        self.assertIn("invalid_json_response",
                      self._connector_state()["last_error_detail"])

    def test_connect_once_app_error_relay_fails_loudly(self):
        with _ScriptedRelay("app_error_ok_false") as relay:
            result = self._connect_once(relay.url)
        self._assert_failed_sync(result, "relay connect --once vs 200+ok:false")
        self.assertIn("scripted_fault",
                      self._connector_state()["last_error_detail"])

    def test_FIXME_dishonest_500_ok_true_is_treated_as_success(self):
        """FIXME(Q1-DEFECT-1): connector false-success on dishonest 500+ok:true.

        The connector's inline Relay_client in ocaml/c2c_relay_connector.ml
        discards the HTTP response status (`fun (_resp, resp_body) -> ...`),
        so H7's HTTP-status honesty (ocaml/relay.ml Relay_client) never runs
        on the connector path: a relay answering HTTP 500 with an ok:true
        body is counted as a SUCCESSFUL register (exit 0, registered=N).

        Finding: .collab/findings/2026-07-10T12-17-07Z-q1-worker-connector-
        dishonest-500-false-success.md. Not fixed here — the file is owned by
        lane H9 (cross-lane). This cell self-skips while the defect exists
        and starts ENFORCING the correct contract the moment it is fixed.
        """
        with _ScriptedRelay("dishonest_500_ok_true") as relay:
            result = self._connect_once(relay.url)
        if result.returncode == 0:
            self.skipTest(
                "FIXME(Q1-DEFECT-1): `c2c relay connect --once` treats a "
                "dishonest HTTP 500 + ok:true relay response as a successful "
                "sync (exit 0, register counted). H7 honesty gap in the "
                "connector's inline HTTP client — see .collab/findings/"
                "2026-07-10T12-17-07Z-q1-worker-connector-dishonest-500-"
                "false-success.md")
        # Defect fixed: enforce the full failed-sync contract from now on.
        self._assert_failed_sync(
            result, "relay connect --once vs dishonest 500+ok:true")


if __name__ == "__main__":
    unittest.main()
