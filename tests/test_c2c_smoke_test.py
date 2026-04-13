"""Tests for c2c_smoke_test end-to-end broker smoke test."""
from __future__ import annotations

import json
from pathlib import Path
from unittest import mock

import sys
REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_smoke_test


class TestSmokeResult:
    def test_passed_when_all_checks_ok(self) -> None:
        r = c2c_smoke_test.SmokeResult()
        r.add("a", True)
        r.add("b", True)
        assert r.passed

    def test_failed_when_any_check_fails(self) -> None:
        r = c2c_smoke_test.SmokeResult()
        r.add("a", True)
        r.add("b", False, "something went wrong")
        assert not r.passed

    def test_to_dict_structure(self) -> None:
        r = c2c_smoke_test.SmokeResult()
        r.add("mycheck", True, "detail here")
        d = r.to_dict()
        assert "ok" in d
        assert "elapsed_ms" in d
        assert isinstance(d["elapsed_ms"], int)
        assert d["checks"] == [{"name": "mycheck", "ok": True, "detail": "detail here"}]


class TestRunSmoke:
    def test_passes_with_valid_broker_root(self, tmp_path: Path) -> None:
        broker_root = tmp_path / "smoke-broker"
        broker_root.mkdir()
        result = c2c_smoke_test.run_smoke(broker_root)
        assert result.passed, f"smoke test failed: {result.to_dict()}"

    def test_fails_when_broker_root_missing(self, tmp_path: Path) -> None:
        broker_root = tmp_path / "nonexistent"
        result = c2c_smoke_test.run_smoke(broker_root)
        assert not result.passed
        check_names = [name for name, _, _ in result.checks]
        assert "broker-root-exists" in check_names
        ok_map = {name: ok for name, ok, _ in result.checks}
        assert not ok_map["broker-root-exists"]

    def test_delivery_check_validates_content(self, tmp_path: Path) -> None:
        """The delivery check must match the exact marker, not just any message."""
        broker_root = tmp_path / "smoke-broker"
        broker_root.mkdir()

        # Intercept _run to inject a wrong message content into poll
        original_run = c2c_smoke_test._run

        call_count = [0]

        def fake_run(args, env, *, session_id=None):
            call_count[0] += 1
            proc = original_run(args, env, session_id=session_id)
            # On the poll call (second _run call after send), inject wrong content
            if "poll-inbox" in args:
                import subprocess as sp
                return sp.CompletedProcess(
                    args,
                    0,
                    json.dumps({
                        "session_id": "smoke-session-b",
                        "source": "broker",
                        "count": 1,
                        "messages": [
                            {
                                "from_alias": "smoke-a",
                                "to_alias": "smoke-b",
                                "content": "WRONG-CONTENT",
                            }
                        ],
                    }),
                    "",
                )
            return proc

        with mock.patch.object(c2c_smoke_test, "_run", side_effect=fake_run):
            result = c2c_smoke_test.run_smoke(broker_root)

        assert not result.passed
        ok_map = {name: ok for name, ok, _ in result.checks}
        assert not ok_map.get("delivery", True), "delivery should fail on wrong content"

    def test_json_output(self, capsys) -> None:
        result = c2c_smoke_test.SmokeResult()
        result.add("check1", True, "all good")
        c2c_smoke_test.print_result(result, as_json=True)
        captured = capsys.readouterr()
        data = json.loads(captured.out)
        assert "ok" in data
        assert "elapsed_ms" in data
        assert "checks" in data
        assert data["ok"] is True

    def test_text_output_shows_pass(self, capsys) -> None:
        result = c2c_smoke_test.SmokeResult()
        result.add("check1", True)
        c2c_smoke_test.print_result(result, as_json=False)
        captured = capsys.readouterr()
        assert "PASSED" in captured.out
        assert "check1" in captured.out


class TestMain:
    def test_main_returns_zero_on_pass(self) -> None:
        rc = c2c_smoke_test.main([])
        assert rc == 0

    def test_main_json_flag(self, capsys) -> None:
        rc = c2c_smoke_test.main(["--json"])
        assert rc == 0
        captured = capsys.readouterr()
        data = json.loads(captured.out)
        assert data["ok"] is True

    def test_main_with_explicit_broker_root(self, tmp_path: Path) -> None:
        broker_root = tmp_path / "explicit"
        rc = c2c_smoke_test.main(["--broker-root", str(broker_root)])
        assert rc == 0
        assert broker_root.is_dir()

    def test_main_returns_nonzero_on_failure(self) -> None:
        # Patch run_smoke to return a failing result
        failing = c2c_smoke_test.SmokeResult()
        failing.add("broker-root-exists", False, "forced failure")
        with mock.patch.object(c2c_smoke_test, "run_smoke", return_value=failing):
            rc = c2c_smoke_test.main([])
        assert rc == 1
