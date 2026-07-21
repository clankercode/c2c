#!/usr/bin/env python3
"""Tests for c2c_sweep_dryrun.py — especially the provisional-expired classification."""
from __future__ import annotations

import json
import os
import tempfile
import time
import unittest
from pathlib import Path

from c2c_sweep_dryrun import analyze, is_provisional_expired


class IsProvisionalExpiredTests(unittest.TestCase):
    def _reg(self, **kw):
        base = {
            "session_id": "test-session",
            "alias": "test-alias",
            "pid": None,
            "confirmed_at": None,
            "registered_at": time.time() - 3600,  # 1 hour ago by default
            "client_type": "claude",
        }
        base.update(kw)
        return base

    def test_expired_when_old_and_pid_none(self):
        reg = self._reg(registered_at=time.time() - 3600)
        self.assertTrue(is_provisional_expired(reg, timeout_s=1800))

    def test_not_expired_when_recent(self):
        reg = self._reg(registered_at=time.time() - 60)
        self.assertFalse(is_provisional_expired(reg, timeout_s=1800))

    def test_not_expired_when_pid_set(self):
        reg = self._reg(pid=12345, registered_at=time.time() - 9999)
        self.assertFalse(is_provisional_expired(reg, timeout_s=1800))

    def test_not_expired_when_confirmed(self):
        reg = self._reg(confirmed_at=time.time(), registered_at=time.time() - 9999)
        self.assertFalse(is_provisional_expired(reg, timeout_s=1800))

    def test_not_expired_for_human_client(self):
        reg = self._reg(client_type="human", registered_at=time.time() - 9999)
        self.assertFalse(is_provisional_expired(reg, timeout_s=1800))

    def test_not_expired_when_no_registered_at(self):
        reg = self._reg(registered_at=None)
        self.assertFalse(is_provisional_expired(reg, timeout_s=1800))


class AnalyzeProvisionalExpiredTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def _write_registry(self, regs):
        (self.root / "registry.json").write_text(json.dumps(regs))

    def test_expired_provisional_counted_separately(self):
        expired_reg = {
            "session_id": "expired-session",
            "alias": "expired-alias",
            "pid": None,
            "confirmed_at": None,
            "registered_at": time.time() - 9000,  # > 1800s
        }
        live_reg = {
            "session_id": "live-session",
            "alias": "live-alias",
            "pid": None,
            "confirmed_at": None,
            "registered_at": time.time() - 60,  # recent
        }
        self._write_registry([expired_reg, live_reg])

        report = analyze(self.root)
        self.assertEqual(report["totals"]["provisional_expired"], 1)
        self.assertEqual(report["totals"]["legacy_pidless"], 1)
        self.assertEqual(len(report["provisional_expired_regs"]), 1)
        self.assertEqual(report["provisional_expired_regs"][0]["session_id"], "expired-session")

    def test_expired_provisional_counted_in_dropped_if_swept(self):
        expired_reg = {
            "session_id": "expired-session",
            "alias": "expired-alias",
            "pid": None,
            "confirmed_at": None,
            "registered_at": time.time() - 9000,
        }
        self._write_registry([expired_reg])

        report = analyze(self.root)
        self.assertIn("expired-session", [
            *[r["session_id"] for r in report["dead_regs"]],
            *[r["session_id"] for r in report["provisional_expired_regs"]],
        ])
        self.assertGreaterEqual(report["totals"]["dropped_if_swept"], 1)

    def test_no_provisional_expired_when_all_recent(self):
        recent_reg = {
            "session_id": "recent-session",
            "alias": "recent-alias",
            "pid": None,
            "confirmed_at": None,
            "registered_at": time.time() - 60,
        }
        self._write_registry([recent_reg])

        report = analyze(self.root)
        self.assertEqual(report["totals"]["provisional_expired"], 0)
        self.assertEqual(report["totals"]["legacy_pidless"], 1)

    def test_env_var_controls_timeout(self):
        reg = {
            "session_id": "borderline-session",
            "alias": "borderline",
            "pid": None,
            "confirmed_at": None,
            "registered_at": time.time() - 120,  # 2 minutes ago
        }
        self._write_registry([reg])

        os.environ["C2C_PROVISIONAL_SWEEP_TIMEOUT"] = "60"
        try:
            report = analyze(self.root)
            self.assertEqual(report["totals"]["provisional_expired"], 1)
        finally:
            del os.environ["C2C_PROVISIONAL_SWEEP_TIMEOUT"]


if __name__ == "__main__":
    unittest.main()
