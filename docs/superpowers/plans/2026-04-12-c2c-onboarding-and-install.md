# C2C Onboarding And Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the live registration/list mismatch, install `c2c-*` commands into `~/.local/bin`, add `c2c-whoami`, and make `c2c-register` self-notify the registered session with onboarding guidance.

**Architecture:** First, debug and fix the live-path mismatch so registration and listing share the same registry and pruning behavior. Then add a small user-local install command, a `whoami` identity/tutorial command, and a registration-time onboarding message that reuses the existing send surface. Keep all public behavior CLI-first and covered by tests.

**Tech Stack:** Python 3, shell wrappers, stdlib file/path handling, existing PTY send surface, `unittest`, subprocess-driven CLI tests

---

## File Structure

- Create: `c2c_install.py`
  Responsibility: install or update user-local wrappers in `~/.local/bin` or a test override path.
- Create: `c2c_whoami.py`
  Responsibility: resolve the current or explicit session and print alias, status, and tutorial.
- Create: `c2c-install`
  Responsibility: shell wrapper for `c2c_install.py`.
- Create: `c2c-whoami`
  Responsibility: shell wrapper for `c2c_whoami.py`.
- Modify: `c2c_register.py`
  Responsibility: send onboarding notification only for newly registered live sessions.
- Modify: `c2c_list.py`
  Responsibility: fix the live listing bug if the root cause is there.
- Modify: `c2c_registry.py`
  Responsibility: expose any shared helpers needed for whoami/list/debugging.
- Modify: `claude_list_sessions.py`
  Responsibility: expose fixture/source metadata only if required for root-cause-safe path handling.
- Modify: `tests/test_c2c_cli.py`
  Responsibility: CLI-first red/green coverage for install, whoami, onboarding notification, and the register/list live-bug reproduction.
- Modify: `README.md`
  Responsibility: document `c2c-install` and `c2c-whoami`.
- Modify: `docs/commands.md`
  Responsibility: document install/whoami and registration onboarding behavior.

### Task 1: Reproduce And Fix The Live Register/List Mismatch

**Files:**
- Modify: `tests/test_c2c_cli.py`
- Modify: `c2c_list.py`
- Modify: `c2c_register.py`
- Modify: `c2c_registry.py`
- Modify: `claude_list_sessions.py` (only if root cause requires it)

- [ ] **Step 1: Write the failing regression test for the live mismatch shape**

```python
    def test_list_returns_recently_registered_sessions_in_same_environment(self):
        first = self.invoke_cli("c2c-register", "agent-one", "--json")
        second = self.invoke_cli("c2c-register", "agent-two", "--json")
        self.assertEqual(result_code(first), 0)
        self.assertEqual(result_code(second), 0)

        listed = self.invoke_cli("c2c-list", "--json")
        payload = json.loads(listed.stdout)
        self.assertEqual(
            sorted(item["session_id"] for item in payload["sessions"]),
            [
                "6e45bbe8-998c-4140-b77e-c6f117e6ca4b",
                "fa68bd5b-0529-4292-bc27-d617f6840ce7",
            ],
        )
```

- [ ] **Step 2: Run the targeted test and gather live-path evidence if it fails**

Run: `python3 -m unittest tests.test_c2c_cli.C2CCLITests.test_list_returns_recently_registered_sessions_in_same_environment`
Expected: If it fails, inspect which registry path each command uses and which live sessions are seen before changing code.

- [ ] **Step 3: Fix the root cause minimally**

```python
# Example shape only; implement the actual root cause fix you verified.
def list_registered_sessions() -> list[dict]:
    sessions = load_sessions()
    sessions_by_id = {session["session_id"]: session for session in sessions}

    def mutate_registry(registry: dict) -> list[dict]:
        registry["registrations"] = [
            row
            for row in registry.get("registrations", [])
            if row.get("session_id") in sessions_by_id
        ]
        return [
            {
                "alias": row["alias"],
                "name": sessions_by_id[row["session_id"]].get("name", ""),
                "session_id": row["session_id"],
            }
            for row in registry["registrations"]
        ]

    return update_registry(mutate_registry)
```

- [ ] **Step 4: Re-run the targeted test and the full suite**

Run: `python3 -m unittest tests.test_c2c_cli`
Expected: PASS.

### Task 2: Add `c2c-install`

**Files:**
- Create: `c2c_install.py`
- Create: `c2c-install`
- Modify: `tests/test_c2c_cli.py`

- [ ] **Step 1: Write the failing install tests**

```python
    def test_install_writes_user_local_wrappers(self):
        install_dir = Path(self.temp_dir.name) / "bin"
        env = dict(self.env)
        env["C2C_INSTALL_BIN_DIR"] = str(install_dir)

        result = self.invoke_cli("c2c-install", "--json", env=env)

        self.assertEqual(result_code(result), 0)
        payload = json.loads(result.stdout)
        self.assertEqual(sorted(payload["installed_commands"]), [
            "c2c-install",
            "c2c-list",
            "c2c-register",
            "c2c-send",
            "c2c-verify",
            "c2c-whoami",
        ])
        self.assertTrue((install_dir / "c2c-register").exists())

    def test_install_reports_path_guidance_when_bin_not_on_path(self):
        install_dir = Path(self.temp_dir.name) / "bin"
        env = dict(self.env)
        env["C2C_INSTALL_BIN_DIR"] = str(install_dir)
        env["PATH"] = "/usr/bin"

        result = self.invoke_cli("c2c-install", env=env)

        self.assertEqual(result_code(result), 0)
        self.assertIn("not currently on PATH", result.stdout)
```

- [ ] **Step 2: Run the targeted tests to verify RED**

Run: `python3 -m unittest tests.test_c2c_cli.C2CCLITests.test_install_writes_user_local_wrappers tests.test_c2c_cli.C2CCLITests.test_install_reports_path_guidance_when_bin_not_on_path`
Expected: FAIL because `c2c-install` does not exist yet.

- [ ] **Step 3: Implement the minimal installer**

```python
#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path


COMMANDS = [
    "c2c-install",
    "c2c-list",
    "c2c-register",
    "c2c-send",
    "c2c-verify",
    "c2c-whoami",
]


def install_bin_dir() -> Path:
    override = os.environ.get("C2C_INSTALL_BIN_DIR")
    if override:
        return Path(override)
    return Path.home() / ".local" / "bin"


def write_wrapper(target_dir: Path, command: str, repo_root: Path) -> None:
    wrapper = target_dir / command
    wrapper.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        f'exec "{repo_root / command}" "$@"\n',
        encoding="utf-8",
    )
    wrapper.chmod(0o755)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Install c2c commands into a user-local bin directory.")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parent
    target_dir = install_bin_dir()
    target_dir.mkdir(parents=True, exist_ok=True)
    for command in COMMANDS:
        write_wrapper(target_dir, command, repo_root)

    payload = {
        "bin_dir": str(target_dir),
        "installed_commands": COMMANDS,
        "bin_on_path": str(target_dir) in os.environ.get("PATH", "").split(os.pathsep),
    }
    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        print(f"Installed c2c commands into {target_dir}")
        if not payload["bin_on_path"]:
            print(f"{target_dir} is not currently on PATH")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Add the shell wrapper and re-run tests**

```bash
#!/usr/bin/env bash
set -euo pipefail
exec python3 "$(dirname "$0")/c2c_install.py" "$@"
```

Run: `python3 -m unittest tests.test_c2c_cli`
Expected: PASS.

### Task 3: Add `c2c-whoami`

**Files:**
- Create: `c2c_whoami.py`
- Create: `c2c-whoami`
- Modify: `tests/test_c2c_cli.py`
- Modify: `c2c_registry.py`

- [ ] **Step 1: Write the failing `whoami` tests**

```python
    def test_whoami_json_reports_alias_and_registration_status(self):
        self.invoke_cli("c2c-register", "agent-one", env=self.env)

        result = self.invoke_cli("c2c-whoami", "agent-one", "--json", env=self.env)

        self.assertEqual(result_code(result), 0)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["name"], "agent-one")
        self.assertEqual(payload["session_id"], AGENT_ONE_SESSION_ID)
        self.assertEqual(payload["registered"], True)
        self.assertRegex(payload["alias"], r"^[a-z]+-[a-z]+$")
        self.assertIn("tutorial", payload)

    def test_whoami_human_output_includes_tutorial(self):
        self.invoke_cli("c2c-register", "agent-one", env=self.env)

        result = self.invoke_cli("c2c-whoami", "agent-one", env=self.env)

        self.assertEqual(result_code(result), 0)
        self.assertIn("What is C2C?", result.stdout)
        self.assertIn("c2c-send <alias> <message...>", result.stdout)
```

- [ ] **Step 2: Run the targeted tests to verify RED**

Run: `python3 -m unittest tests.test_c2c_cli.C2CCLITests.test_whoami_json_reports_alias_and_registration_status tests.test_c2c_cli.C2CCLITests.test_whoami_human_output_includes_tutorial`
Expected: FAIL because `c2c-whoami` does not exist yet.

- [ ] **Step 3: Implement the minimal `whoami` command**

```python
#!/usr/bin/env python3
import argparse
import json
import sys

from c2c_registry import find_registration_by_session_id, load_registry
from claude_list_sessions import find_session, load_sessions


def tutorial_text() -> list[str]:
    return [
        "What is C2C?",
        "C2C lets opted-in Claude sessions on this machine message each other by alias.",
        "Common commands:",
        "- c2c-list",
        "- c2c-send <alias> <message...>",
        "- c2c-verify",
    ]


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Show the current C2C identity and tutorial.")
    parser.add_argument("session")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    session = find_session(args.session, load_sessions())
    if session is None:
        print(f"session not found: {args.session}", file=sys.stderr)
        return 1

    registration = find_registration_by_session_id(load_registry(), session["session_id"])
    payload = {
        "name": session.get("name", ""),
        "session_id": session["session_id"],
        "registered": registration is not None,
        "alias": registration.get("alias") if registration else None,
        "tutorial": tutorial_text(),
    }
    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    print(f"Alias: {payload['alias'] or '<unregistered>'}")
    print(f"Session: {payload['name']}")
    print(f"Session ID: {payload['session_id']}")
    print(f"Registered: {'yes' if payload['registered'] else 'no'}")
    print()
    for line in tutorial_text():
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Add the shell wrapper and re-run the suite**

```bash
#!/usr/bin/env bash
set -euo pipefail
exec python3 "$(dirname "$0")/c2c_whoami.py" "$@"
```

Run: `python3 -m unittest tests.test_c2c_cli`
Expected: PASS.

### Task 4: Make `c2c-register` Send Onboarding Once

**Files:**
- Modify: `c2c_register.py`
- Modify: `tests/test_c2c_cli.py`
- Modify: `claude_send_msg.py` only if a shared helper is needed

- [ ] **Step 1: Write the failing onboarding tests**

```python
class C2CRegisterNotificationTests(unittest.TestCase):
    def test_register_sends_onboarding_for_new_registration(self):
        session = {"name": "agent-one", "pid": 11111, "session_id": AGENT_ONE_SESSION_ID}
        registration = {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}

        with (
            mock.patch("c2c_register.load_sessions", return_value=[session]),
            mock.patch("c2c_register.register_session", return_value=(session, registration, True)),
            mock.patch("c2c_register.claude_send_msg.send_message_to_session") as send_message,
        ):
            result = c2c_register.main(["agent-one"])

        self.assertEqual(result, 0)
        send_message.assert_called_once()

    def test_register_does_not_resend_onboarding_for_existing_registration(self):
        session = {"name": "agent-one", "pid": 11111, "session_id": AGENT_ONE_SESSION_ID}
        registration = {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}

        with (
            mock.patch("c2c_register.load_sessions", return_value=[session]),
            mock.patch("c2c_register.register_session", return_value=(session, registration, False)),
            mock.patch("c2c_register.claude_send_msg.send_message_to_session") as send_message,
        ):
            result = c2c_register.main(["agent-one"])

        self.assertEqual(result, 0)
        send_message.assert_not_called()
```

- [ ] **Step 2: Run the targeted tests to verify RED**

Run: `python3 -m unittest tests.test_c2c_cli.C2CRegisterNotificationTests`
Expected: FAIL because onboarding send behavior does not exist yet.

- [ ] **Step 3: Implement new-registration notification minimally**

```python
def onboarding_message(alias: str) -> str:
    return (
        "You are now registered for C2C.\n"
        f"Your alias is {alias}.\n"
        "Run c2c-whoami for your current details and tutorial.\n"
        "Run c2c-list to see other opted-in sessions.\n"
        "Use c2c-send <alias> <message...> to talk to a peer."
    )


def register_session(identifier: str) -> tuple[dict, dict, bool]:
    ...
    registration_was_new = False

    def mutate_registry(registry: dict) -> dict:
        nonlocal registration_was_new
        existing = find_registration_by_session_id(registry, session_id)
        if existing is not None:
            return existing
        registration_was_new = True
        ...

    registration = update_registry(mutate_registry)
    return session, registration, registration_was_new


def main(argv=None) -> int:
    ...
    session, registration, registration_was_new = register_session(args.session)
    if registration_was_new:
        claude_send_msg.send_message_to_session(session, onboarding_message(registration["alias"]))
```

- [ ] **Step 4: Re-run the suite**

Run: `python3 -m unittest tests.test_c2c_cli`
Expected: PASS.

### Task 5: Document Install And Whoami Workflow

**Files:**
- Modify: `README.md`
- Modify: `docs/commands.md`

- [ ] **Step 1: Write the failing docs audit test**

```python
    def test_readme_mentions_install_and_whoami(self):
        readme = (REPO / "README.md").read_text(encoding="utf-8")
        self.assertIn("c2c-install", readme)
        self.assertIn("c2c-whoami", readme)
```

- [ ] **Step 2: Run the targeted test to verify RED**

Run: `python3 -m unittest tests.test_c2c_cli.C2CCLITests.test_readme_mentions_install_and_whoami`
Expected: FAIL until docs are updated.

- [ ] **Step 3: Update the docs minimally**

```markdown
- `./c2c-install`
- `./c2c-whoami <session>`
```

```markdown
## `c2c-install`

Install `c2c-*` commands into `~/.local/bin`.

## `c2c-whoami`

Show the current alias, registration status, and the C2C tutorial.
```

- [ ] **Step 4: Run the full suite again**

Run: `python3 -m unittest tests.test_c2c_cli`
Expected: PASS.

### Task 6: Verify The Live Tooling Path And Resume The Autonomous Run

**Files:**
- Modify: `.goal-loops/active-goal.md`

- [ ] **Step 1: Install the commands for the current user**

Run: `./c2c-install`
Expected: wrappers installed under `~/.local/bin` and PATH guidance printed if needed.

- [ ] **Step 2: Verify live registration/listing/whoami**

Run: `~/.local/bin/c2c-register <live-session-id> --json`
Expected: alias JSON and onboarding sent on first registration.

Run: `~/.local/bin/c2c-list --json`
Expected: registered live sessions visible.

Run: `~/.local/bin/c2c-whoami <live-session-id> --json`
Expected: alias, registration state, tutorial payload.

- [ ] **Step 3: Resume the autonomous run**

Run one kickoff send per live session using the new installed command surface.

Expected: the sessions can self-serve with `c2c-whoami`, discover peers with `c2c-list`, and continue messaging via `c2c-send`.

- [ ] **Step 4: Poll verification until goal is met**

Run: `~/.local/bin/c2c-verify --json`
Expected: eventually both target participants reach `sent >= 20` and `received >= 20`.
