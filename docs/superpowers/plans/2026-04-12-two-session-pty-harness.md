# Two-Session PTY Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a minimal Python harness that can launch fresh Claude sessions, discover the new sessions, inject short prompts or keys, read transcript-backed progress, and support repeatable two-session C2C verification.

**Architecture:** Add one focused Python script, `claude_pty_harness.py`, that reuses existing modules for session discovery and PTY prompt injection instead of rebuilding those primitives. Keep the first version script-local and JSON-oriented, then verify it with focused unit tests driven by fixtures and mocks.

Live validation note: freshly launched PTY sessions often do not write discoverable session metadata until the PTY receives an initial interaction. A single immediate `Enter` was not reliable; a retry about 1 second later was. Treat that as part of launch readiness rather than a manual debugging step.

**Tech Stack:** Python 3, `subprocess`, existing repo modules (`claude_list_sessions.py`, `claude_send_msg.py`, `claude_read_history.py`), `unittest`, mock-based tests.

Verification note: channel-backed validation should distinguish between broker enqueue, broker drain, and transcript-visible receiver delivery. Live runs showed enqueue and drain can succeed while Claude still fails to surface the inbound message in the receiver transcript.

---

### Task 1: Add Harness Tests For Discovery And Waiting

**Files:**
- Modify: `tests/test_c2c_cli.py`
- Create: no new files
- Test: `tests/test_c2c_cli.py`

- [ ] **Step 1: Add imports for the new harness module**

```python
import claude_pty_harness
```

Place the import with the other repo-local imports near the top of `tests/test_c2c_cli.py`.

- [ ] **Step 2: Add a failing test for filtering newly launched sessions**

```python
    def test_harness_new_sessions_since_filters_by_pid_and_name(self):
        sessions = [
            {"pid": 100, "name": "old", "session_id": "old-id"},
            {"pid": 200, "name": "C2C-s1", "session_id": "new-1"},
            {"pid": 220, "name": "C2C-s2", "session_id": "new-2"},
        ]

        rows = claude_pty_harness.new_sessions_since(
            sessions,
            baseline_pids={100},
            expected_names={"C2C-s1", "C2C-s2"},
        )

        self.assertEqual([row["session_id"] for row in rows], ["new-1", "new-2"])
```

- [ ] **Step 3: Add a failing test for awaiting transcript text**

```python
    def test_harness_wait_for_transcript_text_succeeds(self):
        transcript = Path(self.temp_dir.name) / "session.jsonl"
        transcript.write_text(
            json.dumps(
                {
                    "type": "assistant",
                    "message": {"content": [{"type": "text", "text": "ready ok"}]},
                }
            )
            + "\n",
            encoding="utf-8",
        )

        session = {"transcript": str(transcript), "session_id": "s1", "name": "C2C-s1"}

        matched = claude_pty_harness.wait_for_transcript_text(
            session,
            needle="ready ok",
            timeout_seconds=0.01,
            poll_interval_seconds=0.001,
        )

        self.assertTrue(matched)
```

- [ ] **Step 4: Add a failing test for JSON prompt injection wrapper**

```python
    @mock.patch("claude_pty_harness.send_message_to_session")
    def test_harness_send_prompt_uses_existing_injector(self, send_message_to_session_mock):
        send_message_to_session_mock.return_value = {"ok": True}
        session = {"session_id": "s1", "name": "C2C-s1"}

        result = claude_pty_harness.send_prompt(session, "hi")

        self.assertEqual(result, {"ok": True})
        send_message_to_session_mock.assert_called_once()
```

- [ ] **Step 5: Run the new tests to verify they fail**

Run: `python3 -m pytest tests/test_c2c_cli.py -k "harness_" -v`

Expected: FAIL with missing `claude_pty_harness` functions.

### Task 2: Implement Minimal Harness Core

**Files:**
- Create: `claude_pty_harness.py`
- Modify: no existing files unless a tiny helper is truly necessary
- Test: `tests/test_c2c_cli.py`

- [ ] **Step 1: Add the initial harness module skeleton**

```python
#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import time

from claude_list_sessions import load_sessions
from claude_send_msg import send_message_to_session


def new_sessions_since(sessions, baseline_pids, expected_names=None):
    rows = [row for row in sessions if row.get("pid") not in baseline_pids]
    if expected_names:
        rows = [row for row in rows if row.get("name") in expected_names]
    return sorted(rows, key=lambda row: (row.get("pid", 0), row.get("session_id", "")))


def send_prompt(session, prompt):
    return send_message_to_session(session, prompt)


def load_transcript_text(transcript_path):
    with open(transcript_path, encoding="utf-8") as handle:
        return handle.read()


def wait_for_transcript_text(session, needle, timeout_seconds, poll_interval_seconds=0.5):
    deadline = time.time() + timeout_seconds
    transcript_path = session.get("transcript", "")
    while time.time() < deadline:
        if transcript_path:
            try:
                if needle in load_transcript_text(transcript_path):
                    return True
            except OSError:
                pass
        time.sleep(poll_interval_seconds)
    return False
```

- [ ] **Step 2: Add a minimal launcher for two Claude sessions**

```python
def launch_claude(name, cwd, extra_args):
    command = ["claude", "--dangerously-skip-permissions", "--print", "--output-format", "text"]
    command.extend(extra_args)
    return subprocess.Popen(command, cwd=cwd)


def launch_two(cwd, names, extra_args, settle_seconds=2.0):
    baseline = load_sessions(with_terminal_owner=True)
    baseline_pids = {row.get("pid") for row in baseline}
    processes = [launch_claude(name, cwd, extra_args) for name in names]
    time.sleep(settle_seconds)
    sessions = load_sessions(with_terminal_owner=True)
    discovered = new_sessions_since(sessions, baseline_pids, expected_names=set(names))
    return {
        "launched_pids": [process.pid for process in processes],
        "sessions": discovered,
    }
```

Keep this minimal even if later launches need refinement.

- [ ] **Step 3: Add a simple JSON CLI surface**

```python
def main(argv=None):
    parser = argparse.ArgumentParser(description="Launch and steer Claude PTY sessions.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    send_prompt_parser = subparsers.add_parser("send-prompt")
    send_prompt_parser.add_argument("session_id")
    send_prompt_parser.add_argument("prompt")

    args = parser.parse_args(argv)
    sessions = load_sessions(with_terminal_owner=True)
    sessions_by_id = {row.get("session_id"): row for row in sessions}

    if args.command == "send-prompt":
        print(json.dumps(send_prompt(sessions_by_id[args.session_id], args.prompt), indent=2))
        return 0

    raise AssertionError("unreachable")
```

Do not widen the CLI beyond what is needed to support the immediate two-session workflow.

- [ ] **Step 4: Run the targeted tests to verify they pass**

Run: `python3 -m pytest tests/test_c2c_cli.py -k "harness_" -v`

Expected: PASS

### Task 3: Add Key Injection And Snapshot Support

**Files:**
- Modify: `claude_pty_harness.py`
- Test: `tests/test_c2c_cli.py`

- [ ] **Step 1: Add a failing test for key injection command shaping**

```python
    @mock.patch("claude_pty_harness.subprocess.run")
    def test_harness_send_key_uses_pty_inject(self, run_mock):
        session = {"tty": "/dev/pts/9", "terminal_pid": "111"}

        claude_pty_harness.send_key(session, "Enter")

        run_mock.assert_called_once()
```

- [ ] **Step 2: Add a failing test for transcript snapshot extraction**

```python
    def test_harness_snapshot_returns_recent_transcript_tail(self):
        transcript = Path(self.temp_dir.name) / "snapshot.jsonl"
        transcript.write_text("line1\nline2\nline3\n", encoding="utf-8")
        session = {"transcript": str(transcript)}

        snapshot = claude_pty_harness.snapshot_transcript(session, max_lines=2)

        self.assertEqual(snapshot, "line2\nline3")
```

- [ ] **Step 3: Implement the minimal helpers**

```python
PTY_INJECT = "/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject"


def send_key(session, key):
    tty = session.get("tty", "")
    if not tty.startswith("/dev/pts/"):
        raise ValueError("session has no pts tty")
    terminal_pid = str(session.get("terminal_pid", ""))
    if not terminal_pid:
        raise ValueError("session has no terminal pid")
    pts_num = tty.rsplit("/", 1)[-1]
    key_payload = "\n" if key == "Enter" else key
    subprocess.run([PTY_INJECT, terminal_pid, pts_num, key_payload], check=True, capture_output=True, text=True)


def snapshot_transcript(session, max_lines=40):
    transcript_path = session.get("transcript", "")
    if not transcript_path:
        return ""
    with open(transcript_path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    return "\n".join(lines[-max_lines:])
```

- [ ] **Step 4: Expose the helpers through the harness CLI**

```python
    snapshot_parser = subparsers.add_parser("snapshot")
    snapshot_parser.add_argument("session_id")
    snapshot_parser.add_argument("--max-lines", type=int, default=40)

    send_key_parser = subparsers.add_parser("send-key")
    send_key_parser.add_argument("session_id")
    send_key_parser.add_argument("key")
```

Then return JSON payloads for both commands.

- [ ] **Step 5: Run the targeted tests again**

Run: `python3 -m pytest tests/test_c2c_cli.py -k "harness_" -v`

Expected: PASS

### Task 4: Add Repeatable Launch And Verification Coverage

**Files:**
- Modify: `tests/test_c2c_cli.py`
- Modify: `claude_pty_harness.py`
- Test: `tests/test_c2c_cli.py`

- [ ] **Step 1: Add a failing test for `launch-two` CLI output shape using mocks**

```python
    @mock.patch("claude_pty_harness.time.sleep")
    @mock.patch("claude_pty_harness.subprocess.Popen")
    @mock.patch("claude_pty_harness.load_sessions")
    def test_harness_launch_two_returns_new_sessions(self, load_sessions_mock, popen_mock, _sleep_mock):
        process_one = mock.Mock(pid=501)
        process_two = mock.Mock(pid=502)
        popen_mock.side_effect = [process_one, process_two]
        load_sessions_mock.side_effect = [
            [{"pid": 100, "session_id": "old", "name": "old"}],
            [
                {"pid": 100, "session_id": "old", "name": "old"},
                {"pid": 501, "session_id": "s1", "name": "C2C-s1"},
                {"pid": 502, "session_id": "s2", "name": "C2C-s2"},
            ],
        ]

        payload = claude_pty_harness.launch_two(
            cwd="/home/xertrov/tmp",
            names=["C2C-s1", "C2C-s2"],
            extra_args=["--model", "haiku"],
            settle_seconds=0,
        )

        self.assertEqual(payload["launched_pids"], [501, 502])
        self.assertEqual([row["session_id"] for row in payload["sessions"]], ["s1", "s2"])
```

- [ ] **Step 2: Implement the `launch-two` subcommand**

```python
    launch_two_parser = subparsers.add_parser("launch-two")
    launch_two_parser.add_argument("cwd")
    launch_two_parser.add_argument("name_one")
    launch_two_parser.add_argument("name_two")
    launch_two_parser.add_argument("extra_args", nargs=argparse.REMAINDER)
```

Return the `launch_two(...)` payload as JSON.

- [ ] **Step 3: Add a failing test for transcript wait timeout behavior**

```python
    def test_harness_wait_for_transcript_text_times_out(self):
        transcript = Path(self.temp_dir.name) / "empty.jsonl"
        transcript.write_text("", encoding="utf-8")
        session = {"transcript": str(transcript), "session_id": "s1"}

        matched = claude_pty_harness.wait_for_transcript_text(
            session,
            needle="missing",
            timeout_seconds=0.01,
            poll_interval_seconds=0.001,
        )

        self.assertFalse(matched)
```

- [ ] **Step 4: Run the full harness-focused test group**

Run: `python3 -m pytest tests/test_c2c_cli.py -k "harness_" -v`

Expected: PASS

### Task 5: Verify The Harness Against Real Session Tooling

**Files:**
- Modify: no files unless verification reveals a minimal required fix
- Test: live commands only

- [ ] **Step 1: Run the harness snapshot command against a live session**

Run: `python3 claude_pty_harness.py snapshot 6e45bbe8-998c-4140-b77e-c6f117e6ca4b --max-lines 10`

Expected: JSON output with a non-empty recent transcript tail.

- [ ] **Step 2: Run the harness prompt injection command against a live session**

Run: `python3 claude_pty_harness.py send-prompt 6e45bbe8-998c-4140-b77e-c6f117e6ca4b "Reply ok"`

Expected: JSON output with `"ok": true`.

- [ ] **Step 3: If channel confirmation is needed on a fresh session, verify key injection**

Run: `python3 claude_pty_harness.py send-key 6e45bbe8-998c-4140-b77e-c6f117e6ca4b Enter`

Expected: JSON output confirming the injection command completed.

- [ ] **Step 4: Re-run targeted tests after live verification**

Run: `python3 -m pytest tests/test_c2c_cli.py -k "harness_" -v`

Expected: PASS

## Self-Review

- Spec coverage: the plan covers launch, discovery, prompt injection, key injection, transcript snapshots, and transcript-based waiting. The later alias registration and autonomous chat run are intentionally left for execution after the harness exists.
- Placeholder scan: removed generic placeholders and kept concrete file paths, code, and commands in each task.
- Type consistency: the plan consistently uses `session` dicts with `session_id`, `pid`, `tty`, `terminal_pid`, and `transcript`, matching the existing session metadata shape.

Plan complete and saved to `docs/superpowers/plans/2026-04-12-two-session-pty-harness.md`. Two execution options:

1. Subagent-Driven (recommended) - I dispatch a fresh subagent per task, review between tasks, fast iteration

2. Inline Execution - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
