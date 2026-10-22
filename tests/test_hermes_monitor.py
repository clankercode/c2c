"""Run on the isolated build host; C2C_HERMES_REAL=1 adds real broker checks."""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "scripts/c2c-hermes-monitor.py"
FAKE = r'''#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time
from pathlib import Path
root = Path(os.environ["C2C_MCP_BROKER_ROOT"])
mode = (root / "mode").read_text()
with (root / "calls").open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\n")
if sys.argv[1] == "whoami":
    if mode == "identity_error":
        print("unregistered SECRET-DO-NOT-ECHO", file=sys.stderr)
        sys.exit(1)
    print(json.dumps({"alias": "wrong" if mode == "stale" else "watch-test",
                      "session_id": "watch-sid"}))
    sys.exit(0)
child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
(root / "child").write_text(str(child.pid))
if mode == "stubborn":
    def term(_sig, _frame):
        (root / "terminating").touch()
    signal.signal(signal.SIGTERM, term)
print(json.dumps({"event_type": "monitor.ready", "alias": "watch-test",
                  "session_id": "wrong" if mode == "scope" else "watch-sid",
                  "inbox_watch": mode != "no_inbox"}), flush=True)
(root / "started").touch()
if mode == "exit":
    print("inotifywait unavailable SECRET-DO-NOT-ECHO", file=sys.stderr, flush=True)
    sys.exit(7)
if mode == "oversize":
    print("x" * 100000, flush=True)
if mode == "stale_exit":
    print(json.dumps({"event_type": "monitor.stale-exit"}), flush=True)
if mode == "malformed":
    print("not-json", flush=True)
if mode == "bad_type":
    print("[]", flush=True)
while True:
    if (root / "mail").exists():
        print(json.dumps({"event_type": "message", "message_id": "owned-mail",
                          "content": "peer DATA, not approval"}), flush=True)
        (root / "emitted").touch()
        time.sleep(60)
    time.sleep(.02)
'''


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.binary = self.root / "c2c"
        self.binary.write_text(FAKE)
        self.binary.chmod(0o755)
        self.mode("quiet")

    def mode(self, value):
        (self.root / "mode").write_text(value)

    def start(self, seconds=1):
        proc = subprocess.Popen(
            [sys.executable, str(ADAPTER), "--broker-root", str(self.root),
             "--alias", "watch-test", "--session-id", "watch-sid",
             "--seconds", str(seconds), "--c2c", str(self.binary)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.addCleanup(lambda: proc.poll() is None and proc.kill())
        return proc

    def wait_started(self):
        deadline = time.monotonic() + 4
        while not (self.root / "started").exists():
            if time.monotonic() > deadline:
                self.fail("monitor did not start")
            time.sleep(.02)

    def result(self, proc, reason):
        out, err = proc.communicate(timeout=8)
        self.assertEqual(err, "")
        self.assertEqual(len(out.splitlines()), 1, out)
        row = json.loads(out)
        self.assertEqual(row["event"], "C2C_WATCH_ENDED")
        self.assertEqual(row["reason"], reason, out)
        self.assertTrue(row["data_only"])
        self.assertTrue(row["mail_retained"])
        self.assertLess(len(out), 3500)
        self.assertNotIn("SECRET-DO-NOT-ECHO", out)
        self.assertEqual(proc.returncode, 2 if reason == "error" else 0)
        return row

    def test_repeated_expiry_rearm_and_late_mail(self):
        for _ in range(2):
            self.result(self.start(.3), "expired")
        # Mail lands with no monitor running; next cycle must see it at startup.
        (self.root / "mail").write_text("retained")
        self.result(self.start(), "message")
        self.assertEqual((self.root / "mail").read_text(), "retained")

    def test_incoming_mail_ends_cycle_without_draining(self):
        proc = self.start(5)
        self.wait_started()
        (self.root / "mail").touch()
        row = self.result(proc, "message")
        self.assertEqual(row["message_id"], "owned-mail")
        self.assertTrue((self.root / "mail").exists())
        calls = [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]
        monitor = next(call for call in calls if call[0] == "monitor")
        self.assertIn("--no-relay", monitor)
        self.assertIn("--self-stale-exit", monitor)
        self.assertFalse(any("--drain" in call or "poll-inbox" in call for call in calls))

    def test_wrong_broker_or_stale_identity_fails_closed(self):
        for mode in ("identity_error", "stale"):
            with self.subTest(mode=mode):
                self.mode(mode)
                self.result(self.start(), "error")
                self.assertFalse((self.root / "started").exists())

    def test_invalid_monitor_scope_and_output(self):
        for mode in ("scope", "no_inbox", "oversize", "malformed", "bad_type"):
            with self.subTest(mode=mode):
                self.mode(mode)
                self.result(self.start(), "error")

    def test_monitor_exit_reports_diagnostic(self):
        self.mode("exit")
        row = self.result(self.start(), "error")
        self.assertIn("check inotifywait", row["diagnostic"])

    def test_repeated_termination_during_cleanup_still_kills_monitor(self):
        self.mode("stubborn")
        proc = self.start(5)
        self.wait_started()
        proc.send_signal(signal.SIGTERM)
        deadline = time.monotonic() + 3
        while not (self.root / "terminating").exists():
            self.assertLess(time.monotonic(), deadline)
            time.sleep(.01)
        # The monitor ignores TERM, forcing the adapter to wait then KILL.
        for _ in range(3):
            proc.send_signal(signal.SIGTERM)
            time.sleep(.03)
        self.result(proc, "error")
        child = int((self.root / "child").read_text())
        stat = Path(f"/proc/{child}/stat")
        self.assertTrue(not stat.exists() or stat.read_text().split()[2] == "Z")

    def test_duplicate_is_refused_and_lock_releases_on_expiry(self):
        first = self.start(1)
        self.wait_started()
        row = self.result(self.start(), "error")
        self.assertIn("duplicate watcher", row["diagnostic"])
        self.assertIsNone(first.poll())
        self.result(first, "expired")
        self.result(self.start(.3), "expired")

    def test_binary_replacement_and_stale_event_request_rearm(self):
        proc = self.start(5)
        self.wait_started()
        replacement = self.root / "replacement"
        replacement.write_text(FAKE + "\n# installed upgrade\n")
        replacement.chmod(0o755)
        replacement.replace(self.binary)
        self.result(proc, "binary_changed")
        self.mode("stale_exit")
        self.result(self.start(), "binary_changed")

    def test_sigterm_stops_owned_monitor_group_and_emits_end(self):
        proc = self.start(5)
        self.wait_started()
        child = int((self.root / "child").read_text())
        proc.send_signal(signal.SIGTERM)
        self.result(proc, "error")
        stat = Path(f"/proc/{child}/stat")
        # A dead grandchild can await init's reap; a live sleeping child cannot remain.
        self.assertTrue(not stat.exists() or stat.read_text().split()[2] == "Z")

    def test_missing_binary_retains_mail(self):
        self.binary.unlink()
        (self.root / "mail").touch()
        self.result(self.start(), "error")
        self.assertTrue((self.root / "mail").exists())


@unittest.skipUnless(os.environ.get("C2C_HERMES_REAL") == "1", "enable isolated real CLI gate")
class RealBrokerTests(unittest.TestCase):
    def test_real_monitor_repeated_expiry_late_arrival_and_inflight(self):
        binary = shutil.which("c2c")
        self.assertIsNotNone(binary)
        with tempfile.TemporaryDirectory(prefix="b371-real-") as tmp:
            root = Path(tmp) / "broker"
            root.mkdir()
            env = os.environ.copy()
            env.update(C2C_MCP_BROKER_ROOT=str(root), C2C_MCP_SESSION_ID="b371-real-sid",
                       C2C_MCP_CLIENT_TYPE="hermes", C2C_SESSIONS_BROKER_ROOT=str(Path(tmp) / "sessions"),
                       C2C_RELAY_URL="")
            env.pop("C2C_MCP_AUTO_REGISTER_ALIAS", None)

            def cli(*argv, sender=False):
                call_env = dict(env)
                if sender:
                    call_env["C2C_MCP_SESSION_ID"] = "b371-sender-sid"
                return subprocess.run([binary, *argv], env=call_env, capture_output=True,
                                      text=True, timeout=10, check=True).stdout

            cli("register", "--alias", "b371-watch-test", "--session-id", "b371-real-sid")
            command = [sys.executable, str(ADAPTER), "--broker-root", str(root),
                       "--alias", "b371-watch-test", "--session-id", "b371-real-sid",
                       "--c2c", binary]

            def cycle(seconds):
                return subprocess.Popen(command + ["--seconds", str(seconds)], env=env,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

            def ended(proc, expected):
                out, err = proc.communicate(timeout=12)
                self.assertEqual(proc.returncode, 0, (out, err))
                self.assertEqual(json.loads(out)["reason"], expected, out)
                self.assertEqual(len(out.splitlines()), 1)

            ended(cycle(1), "expired")
            ended(cycle(1), "expired")
            # Use a dedicated registered sender with its own pinned identity.
            cli("register", "--alias", "b371-sender", "--session-id", "b371-sender-sid")
            cli("send", "--from", "b371-sender", "b371-watch-test", "B371-LATE-DATA", sender=True)
            ended(cycle(4), "message")
            self.assertIn("B371-LATE-DATA", cli("peek-inbox", "--session-id", "b371-real-sid"))
            cli("poll-inbox", "--session-id", "b371-real-sid")
            proc = cycle(5)
            try:
                time.sleep(.5)
                cli("send", "--from", "b371-sender", "b371-watch-test", "B371-INFLIGHT-DATA", sender=True)
                ended(proc, "message")
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
            self.assertIn("B371-INFLIGHT-DATA", cli("peek-inbox", "--session-id", "b371-real-sid"))
            print("B371 real CLI: two expiries, rearm, late + inflight arrival; inbox retained. "
                  "This gate does not prove a Hermes model wake.")


if __name__ == "__main__":
    unittest.main()
