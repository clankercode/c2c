# Kimi Wire Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an experimental Kimi Wire bridge that can deliver queued c2c inbox messages through Kimi's Wire `prompt` surface without PTY injection.

**Architecture:** Add a focused Python module, `c2c_kimi_wire_bridge.py`, with four independent units: Wire JSON-RPC client, Wire turn-state tracker, c2c spool/config helpers, and a small CLI. Add a thin wrapper `c2c-kimi-wire-bridge`. Use fake Wire subprocesses in tests so unit verification never depends on a live Kimi model call.

**Tech Stack:** Python 3.14 standard library, newline-delimited JSON-RPC 2.0, existing `c2c_poll_inbox.py` file fallback functions, `unittest`/`pytest`.

---

## File Structure

- Create `c2c_kimi_wire_bridge.py`
  - `WireState`: tracks active/idle state from Wire event notifications.
  - `format_c2c_envelope()` and `format_prompt()`: render broker messages for Kimi.
  - `C2CSpool`: durable JSON spool for messages drained before Wire prompt succeeds.
  - `build_kimi_mcp_config()`: creates explicit c2c MCP config dictionaries.
  - `WireClient`: sends/receives JSON-RPC lines to a Kimi Wire process.
  - CLI `main()`: `--dry-run`, `--once`, `--json`.
- Create `c2c-kimi-wire-bridge`
  - wrapper that execs `python3 "$SCRIPT_DIR/c2c_kimi_wire_bridge.py" "$@"`.
- Create `tests/test_c2c_kimi_wire_bridge.py`
  - focused unit tests for state, formatting, spool, config, JSON-RPC framing,
    dry-run, and fake once delivery.
- Modify `tests/test_c2c_cli.py`
  - only if needed to include the wrapper/module in install/copy fixtures.
  - Do not touch existing Kimi wake tests unless the file is clean.
- Modify `c2c_install.py`
  - add wrapper installation only after the CLI is stable.

## Task 1: Wire State And Message Formatting

**Files:**
- Create: `c2c_kimi_wire_bridge.py`
- Create: `tests/test_c2c_kimi_wire_bridge.py`

- [ ] **Step 1: Write failing tests for `WireState` and formatting**

Add:

```python
import unittest

import c2c_kimi_wire_bridge as bridge


class WireStateTests(unittest.TestCase):
    def test_turn_begin_and_end_toggle_active_state(self):
        state = bridge.WireState()

        state.apply_message({
            "jsonrpc": "2.0",
            "method": "event",
            "params": {"type": "TurnBegin", "payload": {"user_input": "hi"}},
        })
        self.assertTrue(state.turn_active)

        state.apply_message({
            "jsonrpc": "2.0",
            "method": "event",
            "params": {"type": "TurnEnd", "payload": {}},
        })
        self.assertFalse(state.turn_active)

    def test_steer_input_marks_consumed(self):
        state = bridge.WireState()
        state.apply_message({
            "jsonrpc": "2.0",
            "method": "event",
            "params": {"type": "SteerInput", "payload": {"user_input": "wake"}},
        })
        self.assertEqual(state.steer_inputs, ["wake"])


class FormattingTests(unittest.TestCase):
    def test_formats_c2c_envelope(self):
        msg = {
            "from_alias": "codex",
            "to_alias": "kimi-wire",
            "content": "hello",
        }
        text = bridge.format_c2c_envelope(msg)

        self.assertIn('<c2c event="message"', text)
        self.assertIn('from="codex"', text)
        self.assertIn('alias="kimi-wire"', text)
        self.assertIn('source="broker"', text)
        self.assertIn("hello", text)

    def test_formats_multiple_messages_as_one_prompt(self):
        prompt = bridge.format_prompt([
            {"from_alias": "a", "to_alias": "k", "content": "one"},
            {"from_alias": "b", "to_alias": "k", "content": "two"},
        ])

        self.assertIn("one", prompt)
        self.assertIn("two", prompt)
        self.assertIn("\n\n", prompt)
```

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
python -m pytest tests/test_c2c_kimi_wire_bridge.py -q
```

Expected: fail with `ModuleNotFoundError: No module named 'c2c_kimi_wire_bridge'`.

- [ ] **Step 3: Add minimal implementation**

Create `c2c_kimi_wire_bridge.py` with:

```python
#!/usr/bin/env python3
from __future__ import annotations

import html
from typing import Any


class WireState:
    def __init__(self) -> None:
        self.turn_active = False
        self.steer_inputs: list[str] = []

    def apply_message(self, message: dict[str, Any]) -> None:
        if message.get("method") != "event":
            return
        params = message.get("params") or {}
        event_type = params.get("type")
        payload = params.get("payload") or {}
        if event_type == "TurnBegin":
            self.turn_active = True
        elif event_type == "TurnEnd":
            self.turn_active = False
        elif event_type == "SteerInput":
            user_input = payload.get("user_input")
            if isinstance(user_input, str):
                self.steer_inputs.append(user_input)


def _xml_attr(value: object) -> str:
    return html.escape(str(value or ""), quote=True)


def format_c2c_envelope(message: dict[str, Any]) -> str:
    sender = _xml_attr(message.get("from_alias") or "unknown")
    alias = _xml_attr(message.get("to_alias") or "")
    content = str(message.get("content") or "")
    return (
        f'<c2c event="message" from="{sender}" alias="{alias}" '
        'source="broker" action_after="continue">\n'
        f"{content}\n"
        "</c2c>"
    )


def format_prompt(messages: list[dict[str, Any]]) -> str:
    return "\n\n".join(format_c2c_envelope(message) for message in messages)
```

- [ ] **Step 4: Run tests to verify GREEN**

Run:

```bash
python -m pytest tests/test_c2c_kimi_wire_bridge.py -q
```

Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add c2c_kimi_wire_bridge.py tests/test_c2c_kimi_wire_bridge.py
git commit -m "feat(kimi): add Wire state and envelope formatting"
```

## Task 2: Spool And MCP Config Helpers

**Files:**
- Modify: `c2c_kimi_wire_bridge.py`
- Modify: `tests/test_c2c_kimi_wire_bridge.py`

- [ ] **Step 1: Write failing tests for spool/config**

Add:

```python
from pathlib import Path
import tempfile


class SpoolTests(unittest.TestCase):
    def test_spool_append_replace_and_clear(self):
        with tempfile.TemporaryDirectory() as tmp:
            spool = bridge.C2CSpool(Path(tmp) / "kimi.spool.json")

            spool.append([{"content": "one"}])
            spool.append([{"content": "two"}])
            self.assertEqual([m["content"] for m in spool.read()], ["one", "two"])

            spool.replace([{"content": "three"}])
            self.assertEqual([m["content"] for m in spool.read()], ["three"])

            spool.clear()
            self.assertEqual(spool.read(), [])


class ConfigTests(unittest.TestCase):
    def test_build_kimi_mcp_config_has_explicit_c2c_env(self):
        cfg = bridge.build_kimi_mcp_config(
            broker_root=Path("/broker"),
            session_id="kimi-wire",
            alias="kimi-wire",
            mcp_script=Path("/repo/c2c_mcp.py"),
        )

        env = cfg["mcpServers"]["c2c"]["env"]
        self.assertEqual(env["C2C_MCP_BROKER_ROOT"], "/broker")
        self.assertEqual(env["C2C_MCP_SESSION_ID"], "kimi-wire")
        self.assertEqual(env["C2C_MCP_AUTO_REGISTER_ALIAS"], "kimi-wire")
        self.assertEqual(env["C2C_MCP_AUTO_JOIN_ROOMS"], "swarm-lounge")
        self.assertEqual(env["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")
```

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
python -m pytest tests/test_c2c_kimi_wire_bridge.py -q
```

Expected: fail with missing `C2CSpool` and `build_kimi_mcp_config`.

- [ ] **Step 3: Add implementation**

Add to `c2c_kimi_wire_bridge.py`:

```python
import json
import os
import tempfile
from pathlib import Path


class C2CSpool:
    def __init__(self, path: Path) -> None:
        self.path = path

    def read(self) -> list[dict[str, Any]]:
        if not self.path.exists():
            return []
        raw = self.path.read_text(encoding="utf-8").strip()
        if not raw:
            return []
        loaded = json.loads(raw)
        return [item for item in loaded if isinstance(item, dict)] if isinstance(loaded, list) else []

    def replace(self, messages: list[dict[str, Any]]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.path.parent, prefix=self.path.name + ".", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(messages, handle)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(tmp, self.path)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def append(self, messages: list[dict[str, Any]]) -> None:
        self.replace([*self.read(), *messages])

    def clear(self) -> None:
        self.replace([])


def build_kimi_mcp_config(
    *, broker_root: Path, session_id: str, alias: str, mcp_script: Path
) -> dict[str, Any]:
    return {
        "mcpServers": {
            "c2c": {
                "type": "stdio",
                "command": "python3",
                "args": [str(mcp_script)],
                "env": {
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                    "C2C_MCP_SESSION_ID": session_id,
                    "C2C_MCP_AUTO_REGISTER_ALIAS": alias,
                    "C2C_MCP_AUTO_JOIN_ROOMS": "swarm-lounge",
                    "C2C_MCP_AUTO_DRAIN_CHANNEL": "0",
                },
            }
        }
    }
```

- [ ] **Step 4: Run tests to verify GREEN**

Run:

```bash
python -m pytest tests/test_c2c_kimi_wire_bridge.py -q
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add c2c_kimi_wire_bridge.py tests/test_c2c_kimi_wire_bridge.py
git commit -m "feat(kimi): add Wire bridge spool and MCP config helpers"
```

## Task 3: Wire JSON-RPC Client

**Files:**
- Modify: `c2c_kimi_wire_bridge.py`
- Modify: `tests/test_c2c_kimi_wire_bridge.py`

- [ ] **Step 1: Write failing tests for request framing**

Add:

```python
import io


class WireClientTests(unittest.TestCase):
    def test_initialize_writes_jsonrpc_request(self):
        stdin = io.StringIO()
        stdout = io.StringIO('{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n')
        client = bridge.WireClient(stdin=stdin, stdout=stdout)

        result = client.initialize()

        written = json.loads(stdin.getvalue().strip())
        self.assertEqual(written["method"], "initialize")
        self.assertEqual(written["params"]["protocol_version"], "1.9")
        self.assertEqual(result["protocol_version"], "1.9")

    def test_prompt_writes_user_input(self):
        stdin = io.StringIO()
        stdout = io.StringIO('{"jsonrpc":"2.0","id":"1","result":{"status":"finished"}}\n')
        client = bridge.WireClient(stdin=stdin, stdout=stdout)

        result = client.prompt("hello")

        written = json.loads(stdin.getvalue().strip())
        self.assertEqual(written["method"], "prompt")
        self.assertEqual(written["params"]["user_input"], "hello")
        self.assertEqual(result["status"], "finished")
```

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
python -m pytest tests/test_c2c_kimi_wire_bridge.py -q
```

Expected: fail with missing `WireClient`.

- [ ] **Step 3: Add minimal client**

Add:

```python
class WireClient:
    def __init__(self, *, stdin, stdout) -> None:
        self.stdin = stdin
        self.stdout = stdout
        self._next_id = 1
        self.state = WireState()

    def _request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        request_id = str(self._next_id)
        self._next_id += 1
        request = {
            "jsonrpc": "2.0",
            "method": method,
            "id": request_id,
            "params": params,
        }
        self.stdin.write(json.dumps(request) + "\n")
        self.stdin.flush()
        while True:
            line = self.stdout.readline()
            if not line:
                raise RuntimeError(f"wire closed before response to {method}")
            message = json.loads(line)
            self.state.apply_message(message)
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(json.dumps(message["error"]))
                return message.get("result") or {}

    def initialize(self) -> dict[str, Any]:
        return self._request(
            "initialize",
            {
                "protocol_version": "1.9",
                "client": {"name": "c2c-kimi-wire-bridge", "version": "0"},
                "capabilities": {"supports_question": False},
            },
        )

    def prompt(self, user_input: str) -> dict[str, Any]:
        return self._request("prompt", {"user_input": user_input})

    def steer(self, user_input: str) -> dict[str, Any]:
        return self._request("steer", {"user_input": user_input})
```

- [ ] **Step 4: Run tests to verify GREEN**

Run:

```bash
python -m pytest tests/test_c2c_kimi_wire_bridge.py -q
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add c2c_kimi_wire_bridge.py tests/test_c2c_kimi_wire_bridge.py
git commit -m "feat(kimi): add minimal Wire JSON-RPC client"
```

## Task 4: CLI Dry-Run And Fake Once Delivery

**Files:**
- Modify: `c2c_kimi_wire_bridge.py`
- Create: `c2c-kimi-wire-bridge`
- Modify: `tests/test_c2c_kimi_wire_bridge.py`

- [ ] **Step 1: Write failing tests for CLI behavior**

Add:

```python
class CLITests(unittest.TestCase):
    def test_dry_run_outputs_launch_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            rc, output = bridge.run_main_capture([
                "--session-id", "kimi-wire",
                "--alias", "kimi-wire",
                "--broker-root", str(Path(tmp) / "broker"),
                "--work-dir", tmp,
                "--dry-run",
                "--json",
            ])

        self.assertEqual(rc, 0)
        payload = json.loads(output)
        self.assertEqual(payload["session_id"], "kimi-wire")
        self.assertIn("--wire", payload["launch"])
        self.assertTrue(payload["dry_run"])

    def test_once_delivers_spooled_message_with_fake_wire(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            spool = bridge.C2CSpool(Path(tmp) / "spool.json")
            spool.append([{"from_alias": "codex", "to_alias": "kimi-wire", "content": "hello"}])
            stdin = io.StringIO()
            stdout = io.StringIO(
                '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
                '{"jsonrpc":"2.0","id":"2","result":{"status":"finished"}}\n'
            )

            result = bridge.deliver_once(
                wire=bridge.WireClient(stdin=stdin, stdout=stdout),
                spool=spool,
                broker_root=broker_root,
                session_id="kimi-wire",
                timeout=1.0,
            )

        self.assertEqual(result["delivered"], 1)
        self.assertEqual(spool.read(), [])
        self.assertIn("hello", stdin.getvalue())
```

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
python -m pytest tests/test_c2c_kimi_wire_bridge.py -q
```

Expected: fail with missing `run_main_capture` and `deliver_once`.

- [ ] **Step 3: Implement CLI and delivery**

Add:

```python
import argparse
import contextlib
import sys

ROOT = Path(__file__).resolve().parent


def default_spool_path(broker_root: Path, session_id: str) -> Path:
    return broker_root.parent / "kimi-wire" / f"{session_id}.spool.json"


def deliver_once(
    *, wire: WireClient, spool: C2CSpool, broker_root: Path, session_id: str, timeout: float
) -> dict[str, Any]:
    wire.initialize()
    messages = spool.read()
    if not messages:
        source, fresh = c2c_poll_inbox.poll_inbox(
            broker_root=broker_root,
            session_id=session_id,
            timeout=timeout,
            force_file=True,
            allow_file_fallback=True,
        )
        if fresh:
            spool.append(fresh)
        messages = spool.read()
    if not messages:
        return {"ok": True, "delivered": 0}
    wire.prompt(format_prompt(messages))
    delivered = len(messages)
    spool.clear()
    return {"ok": True, "delivered": delivered}


def build_launch(command: str, work_dir: Path, mcp_config_file: Path) -> list[str]:
    return [command, "--wire", "--yolo", "--work-dir", str(work_dir), "--mcp-config-file", str(mcp_config_file)]


def run_main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Deliver c2c inbox messages through Kimi Wire.")
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--alias")
    parser.add_argument("--broker-root", type=Path, default=c2c_poll_inbox.default_broker_root())
    parser.add_argument("--work-dir", type=Path, default=ROOT)
    parser.add_argument("--command", default="kimi")
    parser.add_argument("--spool-path", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args(argv)
    alias = args.alias or args.session_id
    spool_path = args.spool_path or default_spool_path(args.broker_root, args.session_id)
    launch = build_launch(args.command, args.work_dir, Path("<generated-mcp-config>"))
    if args.dry_run:
        payload = {"ok": True, "dry_run": True, "session_id": args.session_id, "alias": alias, "launch": launch, "spool_path": str(spool_path)}
        print(json.dumps(payload) if args.json else payload)
        return 0
    raise SystemExit("--once live subprocess launch is implemented after fake delivery tests")


def run_main_capture(argv: list[str]) -> tuple[int, str]:
    import io
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        rc = run_main(argv)
    return rc, buffer.getvalue()


def main(argv: list[str] | None = None) -> int:
    return run_main(sys.argv[1:] if argv is None else argv)
```

Also import `c2c_poll_inbox`.

Create `c2c-kimi-wire-bridge`:

```bash
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/c2c_kimi_wire_bridge.py" "$@"
```

- [ ] **Step 4: Run tests to verify GREEN**

Run:

```bash
python -m pytest tests/test_c2c_kimi_wire_bridge.py -q
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add c2c_kimi_wire_bridge.py c2c-kimi-wire-bridge tests/test_c2c_kimi_wire_bridge.py
git commit -m "feat(kimi): add Wire bridge dry-run and fake once delivery"
```

## Task 5: Wrapper Installation And Docs

**Files:**
- Modify: `c2c_install.py`
- Modify: `tests/test_c2c_cli.py` only if no peer edits remain in that file.
- Modify: `docs/overview.md`
- Modify: `docs/client-delivery.md`

- [ ] **Step 1: Write failing install/docs tests if fixture file is clean**

If `tests/test_c2c_cli.py` has no unrelated peer edits, add `c2c-kimi-wire-bridge`
and `c2c_kimi_wire_bridge.py` to the install/copy fixture lists and assert the
wrapper exists after `c2c install`.

Run:

```bash
python -m pytest tests/test_c2c_cli.py -k 'install or copy_cli_checkout' -q
```

Expected: fail until `c2c_install.py` includes the wrapper.

- [ ] **Step 2: Install wrapper**

Add `"c2c-kimi-wire-bridge"` to `WRAPPERS` in `c2c_install.py`.

- [ ] **Step 3: Update docs**

In `docs/client-delivery.md` and `docs/overview.md`, describe Kimi delivery as:

- MCP polling is the baseline.
- Kimi Wire bridge is experimental preferred native delivery.
- direct PTS wake is fallback for manual TUI sessions and remains not the main
  correctness layer.

- [ ] **Step 4: Verify**

Run:

```bash
python -m pytest tests/test_c2c_kimi_wire_bridge.py -q
python -m pytest tests/test_c2c_cli.py -k 'install or copy_cli_checkout or kimi' -q
python -m py_compile c2c_kimi_wire_bridge.py
git diff --check
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add c2c_install.py tests/test_c2c_cli.py docs/overview.md docs/client-delivery.md
git commit -m "docs(kimi): document experimental Wire bridge delivery"
```

## Self-Review

- Spec coverage: Tasks cover the design's first implementation slice: Wire
  framing, state tracking, MCP config, spool safety, dry-run, fake once
  delivery, wrapper, and docs. Active-turn `steer` delivery is represented by
  the client method and state tracking, but live active-turn delivery is
  intentionally left for a later slice after idle prompt delivery is proven.
- Placeholder scan: no task says TBD/TODO/fill in details. Each code step has
  concrete code and commands.
- Type consistency: names used across tasks are consistent:
  `WireState`, `WireClient`, `C2CSpool`, `build_kimi_mcp_config`,
  `format_c2c_envelope`, `format_prompt`, `deliver_once`, `run_main_capture`.
