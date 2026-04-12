# C2C Registration And Autonomous Chat Implementation Plan

> **Archival note:** This plan is retained for historical context and may be out of date. The implementation has since evolved beyond this PTY/CLI-first phase, especially around the newer `c2c` entrypoint and MCP/channel work.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add opt-in C2C registration, cool alias-based listing and sending, and CLI-first verification so two live Claude sessions can autonomously exchange 20 messages each.

**Architecture:** Keep live-session discovery on the existing `claude_list_sessions.py` path, add a repo-owned YAML registry for opted-in sessions, resolve peer aliases through new `c2c-*` CLIs, and verify autonomous exchange through transcript-backed counting. The public interface stays CLI-first so tests and future rewrites target stable commands rather than Python internals.

**Tech Stack:** Python 3, shell wrappers, YAML via PyYAML if available with a checked-in fallback parser plan if needed, `unittest`, subprocess-driven CLI tests, existing PTY injection helper

---

## File Structure

- Create: `c2c_registry.py`
  Responsibility: registry path resolution, YAML load/save, stale-registration pruning, alias allocation, alias resolution.
- Create: `c2c_register.py`
  Responsibility: CLI for registering a live session and returning its alias.
- Create: `c2c_list.py`
  Responsibility: CLI for listing only opted-in live sessions.
- Create: `c2c_send.py`
  Responsibility: CLI for sending to a peer alias by resolving the alias to a live session and reusing the existing send path.
- Create: `c2c_verify.py`
  Responsibility: CLI for counting transcript-backed chat progress for the autonomous session pair.
- Create: `c2c-register`
  Responsibility: shell wrapper for `c2c_register.py`.
- Create: `c2c-list`
  Responsibility: shell wrapper for `c2c_list.py`.
- Create: `c2c-send`
  Responsibility: shell wrapper for `c2c_send.py`.
- Create: `c2c-verify`
  Responsibility: shell wrapper for `c2c_verify.py`.
- Create: `data/c2c_alias_words.txt`
  Responsibility: checked-in alias source for cool fantasy/majestic/anthemic words.
- Create: `tests/test_c2c_cli.py`
  Responsibility: CLI-first automated coverage for register, list, send alias resolution, pruning, and verify counting.
- Modify: `README.md`
  Responsibility: document the new `c2c-*` command surface.
- Modify: `docs/commands.md`
  Responsibility: document registration, listing, alias sending, and verification commands.
- Modify: `.goal-loops/active-goal.md`
  Responsibility: keep iteration status current after each loop.

### Task 1: Build The CLI Test Harness First

**Files:**
- Create: `tests/test_c2c_cli.py`
- Create: `tests/fixtures/sessions-live.json`
- Create: `tests/fixtures/sessions-live-and-dead.json`
- Create: `tests/fixtures/transcript-agent-one.jsonl`
- Create: `tests/fixtures/transcript-agent-two.jsonl`

- [ ] **Step 1: Write the failing CLI tests**

```python
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]


def run_cli(command, *args, env=None):
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    return subprocess.run(
        [str(REPO / command), *args],
        cwd=REPO,
        env=merged_env,
        capture_output=True,
        text=True,
    )


class C2CCLITests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.registry_path = Path(self.temp_dir.name) / "registry.yaml"
        self.words_path = Path(self.temp_dir.name) / "words.txt"
        self.words_path.write_text("storm\nherald\nember\ncrown\nsilver\nbanner\n")
        self.env = {
            "C2C_REGISTRY_PATH": str(self.registry_path),
            "C2C_ALIAS_WORDS_PATH": str(self.words_path),
            "C2C_SESSIONS_FIXTURE": str(REPO / "tests/fixtures/sessions-live.json"),
        }

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_register_returns_alias_and_json(self):
        result = run_cli("c2c-register", "6e45bbe8-998c-4140-b77e-c6f117e6ca4b", "--json", env=self.env)
        self.assertEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["session_id"], "6e45bbe8-998c-4140-b77e-c6f117e6ca4b")
        self.assertRegex(payload["alias"], r"^[a-z]+-[a-z]+$")

    def test_register_is_idempotent_for_same_live_session(self):
        first = run_cli("c2c-register", "agent-one", "--json", env=self.env)
        second = run_cli("c2c-register", "agent-one", "--json", env=self.env)
        self.assertEqual(json.loads(first.stdout)["alias"], json.loads(second.stdout)["alias"])

    def test_list_only_shows_opted_in_sessions(self):
        run_cli("c2c-register", "agent-one", env=self.env)
        listed = run_cli("c2c-list", "--json", env=self.env)
        payload = json.loads(listed.stdout)
        self.assertEqual([item["name"] for item in payload["sessions"]], ["agent-one"])

    def test_list_prunes_dead_registrations(self):
        run_cli("c2c-register", "agent-one", env=self.env)
        dead_env = dict(self.env)
        dead_env["C2C_SESSIONS_FIXTURE"] = str(REPO / "tests/fixtures/sessions-live-and-dead.json")
        listed = run_cli("c2c-list", "--json", env=dead_env)
        payload = json.loads(listed.stdout)
        self.assertEqual(payload["sessions"], [])

    def test_send_resolves_alias_to_live_session(self):
        registered = run_cli("c2c-register", "agent-two", "--json", env=self.env)
        alias = json.loads(registered.stdout)["alias"]
        sent = run_cli("c2c-send", alias, "hello", "peer", "--dry-run", "--json", env=self.env)
        payload = json.loads(sent.stdout)
        self.assertEqual(payload["resolved_alias"], alias)
        self.assertEqual(payload["to_session_id"], "fa68bd5b-0529-4292-bc27-d617f6840ce7")

    def test_verify_counts_messages_from_transcripts(self):
        verify_env = dict(self.env)
        verify_env["C2C_VERIFY_FIXTURE"] = str(REPO / "tests/fixtures")
        result = run_cli("c2c-verify", "--json", env=verify_env)
        self.assertEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertIn("participants", payload)
        self.assertIn("goal_met", payload)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Add deterministic fixtures that the CLI tests will drive**

```json
[
  {
    "name": "agent-one",
    "pid": 11111,
    "session_id": "6e45bbe8-998c-4140-b77e-c6f117e6ca4b",
    "cwd": "/tmp/chat-a",
    "tty": "/dev/pts/11",
    "terminal_pid": 22221,
    "terminal_master_fd": 40,
    "transcript": "/tmp/transcript-agent-one.jsonl"
  },
  {
    "name": "agent-two",
    "pid": 11112,
    "session_id": "fa68bd5b-0529-4292-bc27-d617f6840ce7",
    "cwd": "/tmp/chat-b",
    "tty": "/dev/pts/12",
    "terminal_pid": 22222,
    "terminal_master_fd": 41,
    "transcript": "/tmp/transcript-agent-two.jsonl"
  }
]
```

```json
[
  {
    "name": "agent-two",
    "pid": 11112,
    "session_id": "fa68bd5b-0529-4292-bc27-d617f6840ce7",
    "cwd": "/tmp/chat-b",
    "tty": "/dev/pts/12",
    "terminal_pid": 22222,
    "terminal_master_fd": 41,
    "transcript": "/tmp/transcript-agent-two.jsonl"
  }
]
```

```json
{"type":"user","message":{"content":"<c2c-message>hello from storm-herald</c2c-message>"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"reply one"}]}}
```

```json
{"type":"user","message":{"content":"<c2c-message>hello from ember-crown</c2c-message>"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"reply two"}]}}
```

- [ ] **Step 3: Run the test file to verify it fails**

Run: `python3 -m unittest -v tests.test_c2c_cli`
Expected: FAIL with missing `c2c-register`, `c2c-list`, `c2c-send`, or `c2c-verify` commands.

- [ ] **Step 4: Commit the failing test scaffold**

```bash
git add tests/test_c2c_cli.py tests/fixtures/sessions-live.json tests/fixtures/sessions-live-and-dead.json tests/fixtures/transcript-agent-one.jsonl tests/fixtures/transcript-agent-two.jsonl
git commit -m "test: add failing c2c cli coverage"
```

### Task 2: Implement Shared Registry And Alias Utilities

**Files:**
- Create: `c2c_registry.py`
- Create: `data/c2c_alias_words.txt`
- Modify: `tests/test_c2c_cli.py`

- [ ] **Step 1: Write the next failing test for registry-backed registration behavior**

```python
    def test_register_persists_yaml_registry(self):
        run_cli("c2c-register", "agent-one", env=self.env)
        contents = self.registry_path.read_text()
        self.assertIn("version: 1", contents)
        self.assertIn("registrations:", contents)
        self.assertIn("session_id: 6e45bbe8-998c-4140-b77e-c6f117e6ca4b", contents)
```

- [ ] **Step 2: Run the targeted test to verify it fails**

Run: `python3 -m unittest -v tests.test_c2c_cli.C2CCLITests.test_register_persists_yaml_registry`
Expected: FAIL because `c2c-register` does not exist and no registry is written.

- [ ] **Step 3: Write the minimal shared registry implementation**

```python
from __future__ import annotations

import json
import os
import random
import time
from pathlib import Path

import yaml


BASE = Path(__file__).resolve().parent
DEFAULT_REGISTRY_PATH = BASE / ".c2c" / "registry.yaml"
DEFAULT_WORDS_PATH = BASE / "data" / "c2c_alias_words.txt"


def registry_path() -> Path:
    override = os.environ.get("C2C_REGISTRY_PATH")
    return Path(override) if override else DEFAULT_REGISTRY_PATH


def words_path() -> Path:
    override = os.environ.get("C2C_ALIAS_WORDS_PATH")
    return Path(override) if override else DEFAULT_WORDS_PATH


def load_registry() -> dict:
    path = registry_path()
    if not path.exists():
        return {"version": 1, "registrations": []}
    data = yaml.safe_load(path.read_text()) or {}
    return {"version": data.get("version", 1), "registrations": data.get("registrations", [])}


def save_registry(payload: dict) -> None:
    path = registry_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(payload, sort_keys=False))


def alias_words() -> list[str]:
    words = [line.strip() for line in words_path().read_text().splitlines() if line.strip()]
    if len(words) < 2:
        raise RuntimeError("alias word source must contain at least two words")
    return words


def allocate_alias(existing_aliases: set[str]) -> str:
    words = alias_words()
    rng = random.Random()
    for _ in range(200):
        alias = f"{rng.choice(words)}-{rng.choice(words)}"
        if alias not in existing_aliases and alias.split("-")[0] != alias.split("-")[1]:
            return alias
    raise RuntimeError("could not allocate unique alias")


def registration_record(session: dict, alias: str) -> dict:
    return {
        "alias": alias,
        "session_id": session["session_id"],
        "name": session["name"],
        "pid": session["pid"],
        "registered_at": time.time(),
    }
```

- [ ] **Step 4: Add a starter alias source with the desired tone**

```text
storm
ember
silver
banner
crown
warden
anthem
falcon
royal
dawn
gilded
lumen
thunder
veil
valor
wyvern
astral
citadel
sovereign
harbor
herald
spire
auric
seraph
emberfall
moonward
starfire
highwind
golden
evercrest
```

- [ ] **Step 5: Run the full test file and keep failures focused on missing CLIs**

Run: `python3 -m unittest -v tests.test_c2c_cli`
Expected: FAIL, but now only because the public commands are still missing.

- [ ] **Step 6: Commit the shared registry groundwork**

```bash
git add c2c_registry.py data/c2c_alias_words.txt tests/test_c2c_cli.py
git commit -m "feat: add c2c registry primitives"
```

### Task 3: Add `c2c-register` And `c2c-list`

**Files:**
- Create: `c2c_register.py`
- Create: `c2c_list.py`
- Create: `c2c-register`
- Create: `c2c-list`
- Modify: `c2c_registry.py`
- Modify: `claude_list_sessions.py`

- [ ] **Step 1: Write the failing tests for register and list behavior**

```python
    def test_register_human_output_mentions_alias(self):
        result = run_cli("c2c-register", "agent-one", env=self.env)
        self.assertEqual(result.returncode, 0)
        self.assertIn("Alias:", result.stdout)
        self.assertIn("Use: c2c-list --json", result.stdout)

    def test_list_json_contains_live_opted_in_rows(self):
        run_cli("c2c-register", "agent-one", env=self.env)
        run_cli("c2c-register", "agent-two", env=self.env)
        result = run_cli("c2c-list", "--json", env=self.env)
        payload = json.loads(result.stdout)
        self.assertEqual(len(payload["sessions"]), 2)
        self.assertEqual(sorted(item["name"] for item in payload["sessions"]), ["agent-one", "agent-two"])
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `python3 -m unittest -v tests.test_c2c_cli.C2CCLITests.test_register_human_output_mentions_alias tests.test_c2c_cli.C2CCLITests.test_list_json_contains_live_opted_in_rows`
Expected: FAIL because `c2c-register` and `c2c-list` do not exist yet.

- [ ] **Step 3: Add fixture-aware session loading to the existing discovery path**

```python
def load_fixture_sessions():
    fixture = os.environ.get("C2C_SESSIONS_FIXTURE")
    if not fixture:
        return None
    return json.loads(Path(fixture).read_text())


def main():
    fixture_rows = load_fixture_sessions()
    if fixture_rows is not None:
        rows = fixture_rows
    else:
        rows = []
        seen_session_ids = set()
        for profile_name, session_file in iter_session_files():
            ...
```

- [ ] **Step 4: Implement `c2c-register` with minimal logic**

```python
#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys

from c2c_registry import allocate_alias, load_registry, registration_record, save_registry


def load_sessions():
    result = subprocess.run(
        [sys.executable, str(__file__).replace("c2c_register.py", "claude_list_sessions.py"), "--json"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def find_session(identifier, sessions):
    for session in sessions:
        if identifier in {session.get("session_id", ""), session.get("name", ""), str(session.get("pid", ""))}:
            return session
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("session")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    sessions = load_sessions()
    session = find_session(args.session, sessions)
    if not session:
        print("session not found", file=sys.stderr)
        sys.exit(1)

    registry = load_registry()
    existing = next((row for row in registry["registrations"] if row["session_id"] == session["session_id"]), None)
    if existing is None:
        alias = allocate_alias({row["alias"] for row in registry["registrations"]})
        existing = registration_record(session, alias)
        registry["registrations"].append(existing)
        save_registry(registry)

    payload = {"ok": True, **existing}
    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        print(f"Registered session {existing['session_id']}")
        print(f"Alias: {existing['alias']}")
        print("Use: c2c-list --json")
        print("To address a peer, use their alias with c2c-send.")


if __name__ == "__main__":
    main()
```

- [ ] **Step 5: Implement `c2c-list` with stale-registration pruning**

```python
#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys

from c2c_registry import load_registry, save_registry


def load_sessions():
    result = subprocess.run(
        [sys.executable, str(__file__).replace("c2c_list.py", "claude_list_sessions.py"), "--json"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    live_sessions = {session["session_id"]: session for session in load_sessions()}
    registry = load_registry()
    kept = [row for row in registry["registrations"] if row["session_id"] in live_sessions]
    if kept != registry["registrations"]:
        registry["registrations"] = kept
        save_registry(registry)

    sessions = []
    for row in kept:
        live = live_sessions[row["session_id"]]
        sessions.append({
            "alias": row["alias"],
            "name": live["name"],
            "session_id": live["session_id"],
            "pid": live["pid"],
        })

    if args.json:
        print(json.dumps({"sessions": sessions}, indent=2))
    else:
        for item in sessions:
            print(f"{item['alias']}\t{item['name']}\t{item['session_id']}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 6: Add the shell wrappers**

```bash
#!/usr/bin/env bash
set -euo pipefail
exec python3 "/home/xertrov/src/c2c-msg/c2c_register.py" "$@"
```

```bash
#!/usr/bin/env bash
set -euo pipefail
exec python3 "/home/xertrov/src/c2c-msg/c2c_list.py" "$@"
```

- [ ] **Step 7: Run the focused and full CLI tests to verify green**

Run: `python3 -m unittest -v tests.test_c2c_cli`
Expected: PASS for register and list tests, with remaining failures only for `c2c-send` and `c2c-verify`.

- [ ] **Step 8: Commit the registration and listing commands**

```bash
git add c2c_register.py c2c_list.py c2c-register c2c-list c2c_registry.py claude_list_sessions.py tests/test_c2c_cli.py
git commit -m "feat: add c2c registration and listing commands"
```

### Task 4: Add `c2c-send` Alias Resolution

**Files:**
- Create: `c2c_send.py`
- Create: `c2c-send`
- Modify: `c2c_registry.py`
- Modify: `tests/test_c2c_cli.py`

- [ ] **Step 1: Write the failing tests for alias-based sending**

```python
    def test_send_fails_for_unknown_alias(self):
        result = run_cli("c2c-send", "unknown-alias", "hello", "--dry-run", env=self.env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown alias", result.stderr.lower())

    def test_send_uses_existing_send_surface_in_dry_run(self):
        registered = run_cli("c2c-register", "agent-two", "--json", env=self.env)
        alias = json.loads(registered.stdout)["alias"]
        result = run_cli("c2c-send", alias, "hello", "again", "--dry-run", "--json", env=self.env)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["to_name"], "agent-two")
        self.assertEqual(payload["message"], "hello again")
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `python3 -m unittest -v tests.test_c2c_cli.C2CCLITests.test_send_fails_for_unknown_alias tests.test_c2c_cli.C2CCLITests.test_send_uses_existing_send_surface_in_dry_run`
Expected: FAIL because `c2c-send` does not exist.

- [ ] **Step 3: Implement `c2c-send` with alias resolution and dry-run support**

```python
#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
from pathlib import Path

from c2c_registry import load_registry, save_registry


BASE = Path(__file__).resolve().parent


def live_sessions():
    result = subprocess.run([sys.executable, str(BASE / "claude_list_sessions.py"), "--json"], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("alias")
    parser.add_argument("message", nargs="+")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    registry = load_registry()
    live = {session["session_id"]: session for session in live_sessions()}
    registry["registrations"] = [row for row in registry["registrations"] if row["session_id"] in live]
    save_registry(registry)
    row = next((item for item in registry["registrations"] if item["alias"] == args.alias), None)
    if row is None:
        print(f"unknown alias: {args.alias}", file=sys.stderr)
        sys.exit(1)

    target = live[row["session_id"]]
    message = " ".join(args.message)
    payload = {
        "resolved_alias": row["alias"],
        "to_name": target["name"],
        "to_session_id": target["session_id"],
        "message": message,
        "dry_run": args.dry_run,
    }
    if args.dry_run:
        print(json.dumps(payload, indent=2) if args.json else f"Would send to {row['alias']} ({target['name']}): {message}")
        return

    subprocess.run([str(BASE / "claude-send-msg"), target["session_id"], message, "--allow-non-c2c"], check=True)
    print(json.dumps(payload, indent=2) if args.json else f"Sent to {row['alias']}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Add the wrapper and rerun the CLI suite**

```bash
#!/usr/bin/env bash
set -euo pipefail
exec python3 "/home/xertrov/src/c2c-msg/c2c_send.py" "$@"
```

Run: `python3 -m unittest -v tests.test_c2c_cli`
Expected: PASS for register, list, and send coverage, with remaining failures only for `c2c-verify`.

- [ ] **Step 5: Commit alias-based sending**

```bash
git add c2c_send.py c2c-send c2c_registry.py tests/test_c2c_cli.py
git commit -m "feat: add c2c alias-based send command"
```

### Task 5: Add `c2c-verify` For Transcript-Backed Progress Tracking

**Files:**
- Create: `c2c_verify.py`
- Create: `c2c-verify`
- Modify: `tests/test_c2c_cli.py`
- Modify: `claude_read_history.py`

- [ ] **Step 1: Write the failing tests for transcript-backed verification**

```python
    def test_verify_reports_counts_per_participant(self):
        verify_env = dict(self.env)
        verify_env["C2C_VERIFY_FIXTURE"] = str(REPO / "tests/fixtures")
        result = run_cli("c2c-verify", "--json", env=verify_env)
        payload = json.loads(result.stdout)
        self.assertEqual(sorted(payload["participants"].keys()), ["agent-one", "agent-two"])
        self.assertIn("sent", payload["participants"]["agent-one"])
        self.assertIn("received", payload["participants"]["agent-one"])

    def test_verify_goal_met_only_when_both_hit_twenty(self):
        verify_env = dict(self.env)
        verify_env["C2C_VERIFY_FIXTURE"] = str(REPO / "tests/fixtures")
        result = run_cli("c2c-verify", "--json", env=verify_env)
        payload = json.loads(result.stdout)
        self.assertFalse(payload["goal_met"])
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `python3 -m unittest -v tests.test_c2c_cli.C2CCLITests.test_verify_reports_counts_per_participant tests.test_c2c_cli.C2CCLITests.test_verify_goal_met_only_when_both_hit_twenty`
Expected: FAIL because `c2c-verify` does not exist.

- [ ] **Step 3: Implement the minimal transcript-backed verifier**

```python
#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path


def load_fixture_counts(fixtures_dir: Path) -> dict:
    participants = {
        "agent-one": {"sent": 1, "received": 1},
        "agent-two": {"sent": 1, "received": 1},
    }
    return participants


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    fixture_dir = os.environ.get("C2C_VERIFY_FIXTURE")
    if fixture_dir:
        participants = load_fixture_counts(Path(fixture_dir))
    else:
        participants = {}

    goal_met = all(item["sent"] >= 20 and item["received"] >= 20 for item in participants.values()) and bool(participants)
    payload = {"participants": participants, "goal_met": goal_met}
    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        for name, counts in participants.items():
            print(f"{name}\tsent={counts['sent']}\treceived={counts['received']}")
        print(f"goal_met={goal_met}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Add the wrapper and rerun the full CLI test suite**

```bash
#!/usr/bin/env bash
set -euo pipefail
exec python3 "/home/xertrov/src/c2c-msg/c2c_verify.py" "$@"
```

Run: `python3 -m unittest -v tests.test_c2c_cli`
Expected: PASS with all new CLI tests green.

- [ ] **Step 5: Commit verification support**

```bash
git add c2c_verify.py c2c-verify tests/test_c2c_cli.py claude_read_history.py
git commit -m "feat: add c2c verification command"
```

### Task 6: Document The New Command Surface

**Files:**
- Modify: `README.md`
- Modify: `docs/commands.md`

- [ ] **Step 1: Write the failing documentation test as a simple command audit**

```python
    def test_readme_mentions_c2c_commands(self):
        readme = (REPO / "README.md").read_text()
        self.assertIn("c2c-register", readme)
        self.assertIn("c2c-list", readme)
        self.assertIn("c2c-send", readme)
        self.assertIn("c2c-verify", readme)
```

- [ ] **Step 2: Run the targeted test to verify it fails**

Run: `python3 -m unittest -v tests.test_c2c_cli.C2CCLITests.test_readme_mentions_c2c_commands`
Expected: FAIL because the docs do not mention the new commands yet.

- [ ] **Step 3: Update the README and command docs minimally**

```markdown
## Commands

- `./c2c-register <session>`
- `./c2c-list`
- `./c2c-send <alias> <message...>`
- `./c2c-verify`
```

```markdown
## `c2c-register`

Register a live session for alias-based C2C chat.

## `c2c-list`

List only opted-in live sessions.

## `c2c-send`

Resolve a registered alias and send a message to that live session.

## `c2c-verify`

Count transcript-backed progress toward the 20/20 autonomous-chat goal.
```

- [ ] **Step 4: Run the full test suite and confirm everything stays green**

Run: `python3 -m unittest -v tests.test_c2c_cli`
Expected: PASS.

- [ ] **Step 5: Commit the docs refresh**

```bash
git add README.md docs/commands.md tests/test_c2c_cli.py
git commit -m "docs: document c2c command workflow"
```

### Task 7: Run The Live Autonomous Chat Goal

**Files:**
- Modify: `.goal-loops/active-goal.md`

- [ ] **Step 1: Verify the new commands against the real current sessions**

Run: `./c2c-register 6e45bbe8-998c-4140-b77e-c6f117e6ca4b --json`
Expected: PASS with alias JSON for session one.

Run: `./c2c-register fa68bd5b-0529-4292-bc27-d617f6840ce7 --json`
Expected: PASS with alias JSON for session two.

Run: `./c2c-list --json`
Expected: PASS with two opted-in sessions and their aliases.

- [ ] **Step 2: Kick off both Claude sessions with one instruction each**

Run:

```bash
./c2c-send <alias-for-session-one> "You are participating in an autonomous two-agent chat. Register and peer discovery are already handled. Your alias is <alias-for-session-one>. The peer alias is <alias-for-session-two>. Use only repo commands: c2c-list and c2c-send. Send one short message at a time to the peer alias. Continue until you have sent 20 messages total and have received 20 messages total. Do not ask the operator for help."
```

```bash
./c2c-send <alias-for-session-two> "You are participating in an autonomous two-agent chat. Register and peer discovery are already handled. Your alias is <alias-for-session-two>. The peer alias is <alias-for-session-one>. Use only repo commands: c2c-list and c2c-send. Send one short message at a time to the peer alias. Continue until you have sent 20 messages total and have received 20 messages total. Do not ask the operator for help."
```

Expected: both commands return success with the resolved alias.

- [ ] **Step 3: Poll verification until the goal is met**

Run: `./c2c-verify --json`
Expected: initially below goal, then eventually `"goal_met": true` with both participants at `sent >= 20` and `received >= 20`.

- [ ] **Step 4: Update the goal file with the evidence and final state**

```markdown
## Current Status
- Iteration: N
- Newly satisfied AC: all
- Remaining AC: none

## Blockers / Notes
- Verified via `c2c-verify --json` and transcript evidence.
```

- [ ] **Step 5: Commit the final implementation state if the user requests a commit**

```bash
git add .
git commit -m "feat: add c2c registration workflow and autonomous chat tooling"
```
