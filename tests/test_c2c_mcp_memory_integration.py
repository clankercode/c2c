"""Integration tests for c2c MCP server memory_* tools (#331).

Catches the #326 + #327 bug class in regression form by exercising the
real OCaml MCP server binary via stdio JSON-RPC. Same harness pattern
as `tests/test_c2c_mcp_channel_integration.py` — when those tests
trust their fixture, these inherit the same trust.

Coverage MVP (per Cairn's coord-side framing):

- `memory_list`:
  * `shared_with_me=true` returns entries from peer dirs whose
    frontmatter `shared_with` contains caller; rendered `alias`
    field is the **owner's alias** (not the caller's). This is the
    semantic locked in by #326's resolution — without an explicit
    test, future renames could silently invert it again.
  * `shared_with_me=false` (default) returns caller's own entries.
  * Empty memory dir returns empty list.
- `memory_write`:
  * Basic write succeeds; file lands at canonical path.
  * `shared_with: ["alice", "bob"]` (JSON list form) writes
    frontmatter correctly + triggers handoff DM via #286 path.
  * `shared_with: "alice,bob"` (comma-string form) parses
    identically.
  * `shared: true` SKIPS targeted handoff (no DM to listed
    aliases). This is the #285 global-vs-targeted precedence rule:
    when an entry is globally shared the audience is everyone, so a
    per-recipient DM is noise. The "skipped" assertion is what
    catches a future regression that conflates the two paths.
  * Empty `shared_with` is silent no-op for handoff.

The handoff-fired assertion verifies via the **recipient inbox** not
the broker.log — works against any binary build, gets stronger once
#327 is on origin/master (which adds a parallel broker.log assertion
target). One test (`test_handoff_logs_to_broker_log`) exercises the
#327 logging directly as a smoke for the diagnostic surface.
"""
from __future__ import annotations

import json
import os
import select
import subprocess
import time
from pathlib import Path

from tests.conftest import spawn_tracked

import pytest

REPO = Path(__file__).resolve().parents[1]
MCP_SERVER_EXE = REPO / "_build" / "default" / "ocaml" / "server" / "c2c_mcp_server.exe"

pytestmark = pytest.mark.skipif(
    not MCP_SERVER_EXE.exists(),
    reason=f"MCP server binary not built: {MCP_SERVER_EXE}",
)


# --- JSON-RPC harness (mirrors test_c2c_mcp_channel_integration.py) ---


def send_jsonrpc(proc: subprocess.Popen, obj: dict) -> None:
    line = json.dumps(obj) + "\n"
    proc.stdin.write(line)
    proc.stdin.flush()


def read_jsonrpc(proc: subprocess.Popen, timeout: float = 5.0) -> dict:
    ready, _, _ = select.select([proc.stdout], [], [], timeout)
    if not ready:
        raise TimeoutError("No response from MCP server within timeout")
    line = proc.stdout.readline()
    if not line:
        raise EOFError("MCP server closed stdout")
    return json.loads(line)


def start_server(
    broker_root: str, session_id: str,
    *, alias: str = "", cwd: str | None = None,
) -> subprocess.Popen:
    """Spawn an MCP server.

    cwd: critical for memory_* tests. The server resolves memory dir
    via `git rev-parse --git-common-dir` from its CWD; a per-test repo
    cwd ensures memory writes land in the test's tmp tree, not the
    real repo's `.c2c/memory/`. Channel-delivery / auto-drain disabled
    by default for predictable poll-based tests.
    """
    env = {
        **os.environ,
        "C2C_MCP_BROKER_ROOT": broker_root,
        "C2C_MCP_SESSION_ID": session_id,
        "C2C_MCP_CHANNEL_DELIVERY": "0",
        "C2C_MCP_AUTO_DRAIN_CHANNEL": "0",
        "C2C_MCP_AUTO_REGISTER_ALIAS": alias,
        "C2C_MCP_AUTO_JOIN_ROOMS": "",
        "C2C_MCP_INBOX_WATCHER_DELAY": "0",
    }
    return spawn_tracked(
        [str(MCP_SERVER_EXE)], cwd=cwd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        text=True,
        bufsize=1,
    )


def initialize(proc: subprocess.Popen) -> dict:
    send_jsonrpc(proc, {
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "test-harness-331", "version": "0.0.1"},
        },
    })
    return read_jsonrpc(proc)


def call_tool(proc: subprocess.Popen, name: str, arguments: dict, *, rpc_id: int = 100) -> dict:
    send_jsonrpc(proc, {
        "jsonrpc": "2.0", "id": rpc_id, "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    })
    return read_jsonrpc(proc)


def tool_result_json(resp: dict) -> dict:
    """Extract the JSON-encoded result body from a tools/call response."""
    assert "result" in resp, f"unexpected response: {resp}"
    text = resp["result"]["content"][0]["text"]
    return json.loads(text)


def register(proc: subprocess.Popen, session_id: str, alias: str) -> dict:
    """Call register tool. Returns the raw tools/call response.
    The result text is a plain string ("registered <alias>"), not
    JSON — so we don't try to parse it."""
    return call_tool(proc, "register", {
        "session_id": session_id, "alias": alias,
    }, rpc_id=10)


def shutdown(proc: subprocess.Popen) -> None:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)


@pytest.fixture
def broker_dir(tmp_path: Path) -> Path:
    d = tmp_path / "broker"
    d.mkdir()
    return d


@pytest.fixture
def memory_root(tmp_path: Path) -> Path:
    """Per-test repo root with .c2c/memory/ structure.

    The MCP server's memory_write resolves the memory dir via
    `git rev-parse --git-common-dir | dirname` — same logic as
    the cold-boot hook. We chdir into a per-test repo so writes
    land in a tmp path, not the real repo's `.c2c/memory/`.
    """
    # Init a minimal git repo so git rev-parse succeeds
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "master"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.email", "t@t"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "t"], cwd=repo, check=True)
    (repo / "README").write_text("test\n")
    subprocess.run(["git", "add", "README"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=repo, check=True)
    # Pre-create .c2c/memory/ to work around the existing OCaml mkdir_p
    # bug (it catches EEXIST but not ENOENT, so a fresh repo without
    # .c2c/ trips on memory_write). Real repos always have .c2c/ so
    # this only bites tests with a fresh fixture root.
    (repo / ".c2c" / "memory").mkdir(parents=True)
    return repo


# --- helpers ---


def _read_inbox_archive(broker_dir: Path, alias: str) -> list[dict]:
    """Read the recipient's inbox archive (post-drain history)."""
    path = broker_dir / "archive" / f"{alias}.jsonl"
    if not path.exists():
        return []
    rows = []
    for line in path.read_text().splitlines():
        if line.strip():
            rows.append(json.loads(line))
    return rows


def _read_pending_inbox(broker_dir: Path, session_id: str) -> list[dict]:
    """Read messages sitting in inbox waiting to be polled."""
    path = broker_dir / f"{session_id}.inbox.json"
    if not path.exists():
        return []
    return json.loads(path.read_text())


def _read_broker_log(broker_dir: Path) -> list[dict]:
    path = broker_dir / "broker.log"
    if not path.exists():
        return []
    rows = []
    for line in path.read_text().splitlines():
        if line.strip():
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return rows


def _start_pair(broker_dir: Path, repo: Path,
                a_session: str, a_alias: str,
                b_session: str, b_alias: str) -> tuple[subprocess.Popen, subprocess.Popen]:
    """Two registered sessions sharing the same broker + repo root.

    Both spawn under the same CWD so their memory_write resolves to
    the same `.c2c/memory/` tree.
    """
    cwd = str(repo)
    procs = []
    for session, alias in [(a_session, a_alias), (b_session, b_alias)]:
        env = {
            **os.environ,
            "C2C_MCP_BROKER_ROOT": str(broker_dir),
            "C2C_MCP_SESSION_ID": session,
            "C2C_MCP_CHANNEL_DELIVERY": "0",
            "C2C_MCP_AUTO_DRAIN_CHANNEL": "0",
            "C2C_MCP_AUTO_REGISTER_ALIAS": alias,
            "C2C_MCP_AUTO_JOIN_ROOMS": "",
            "C2C_MCP_INBOX_WATCHER_DELAY": "0",
        }
        proc = spawn_tracked(
            [str(MCP_SERVER_EXE)], cwd=cwd,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, text=True, bufsize=1,
        )
        time.sleep(0.15)  # let auto-register settle
        procs.append(proc)
    for proc, sess, ali in [(procs[0], a_session, a_alias),
                            (procs[1], b_session, b_alias)]:
        initialize(proc)
        register(proc, sess, ali)
    return procs[0], procs[1]


# --- memory_list tests ---


class TestMemoryListSelf:
    """memory_list with shared_with_me=false (default) returns own entries."""

    def test_empty_state_returns_empty_array(self, broker_dir: Path, memory_root: Path) -> None:
        """No entries written yet → list returns []."""
        proc = start_server(str(broker_dir), "session-self-empty",
                            alias="alice-empty", cwd=str(memory_root))
        try:
            time.sleep(0.15)
            initialize(proc)
            register(proc, "session-self-empty", "alice-empty")
            result = tool_result_json(call_tool(proc, "memory_list", {}))
            assert result == [], f"expected empty array, got {result!r}"
        finally:
            shutdown(proc)

    def test_own_entries_listed_after_write(self, broker_dir: Path, memory_root: Path) -> None:
        """Write one entry, confirm it appears in subsequent list."""
        proc = start_server(str(broker_dir), "session-self-write",
                            alias="alice-write", cwd=str(memory_root))
        try:
            time.sleep(0.15)
            initialize(proc)
            register(proc, "session-self-write", "alice-write")
            write_resp = tool_result_json(call_tool(proc, "memory_write", {
                "name": "first-note",
                "description": "my first memory",
                "content": "hello",
            }))
            assert write_resp.get("saved") == "first-note"
            list_resp = tool_result_json(call_tool(proc, "memory_list", {}))
            names = [e.get("name") for e in list_resp]
            assert "first-note" in names, f"first-note missing from {names}"
            # The alias field on own entries is the caller's alias.
            for entry in list_resp:
                if entry.get("name") == "first-note":
                    assert entry.get("alias") == "alice-write", \
                        f"expected own-entry alias 'alice-write', got {entry.get('alias')!r}"
        finally:
            shutdown(proc)


class TestMemoryListSharedWithMe:
    """memory_list shared_with_me=true returns entries from PEER dirs.

    Locks in the #326 resolution: returned `alias` field is the
    **owner's alias**, not the caller's. Without this assertion a
    future rename could silently re-invert the semantic.
    """

    def test_returns_entries_from_peer_dirs(self, broker_dir: Path, memory_root: Path) -> None:
        proc_a, proc_b = _start_pair(broker_dir, memory_root,
                                     "s-share-a", "alice-share",
                                     "s-share-b", "bob-share")
        try:
            # alice writes a note shared_with bob
            tool_result_json(call_tool(proc_a, "memory_write", {
                "name": "alice-to-bob",
                "description": "ping for bob",
                "shared_with": ["bob-share"],
                "content": "shared content",
            }))
            # bob lists shared_with_me=true
            shared_resp = tool_result_json(call_tool(proc_b, "memory_list", {
                "shared_with_me": True,
            }))
            names = [e.get("name") for e in shared_resp]
            assert "alice-to-bob" in names, \
                f"shared_with_me did not return peer entry; got {names}"
            entry = next(e for e in shared_resp if e.get("name") == "alice-to-bob")
            # Critical assertion (#326 resolution): alias is OWNER, not caller.
            assert entry.get("alias") == "alice-share", \
                f"expected alias=owner ('alice-share'), got {entry.get('alias')!r}"
        finally:
            shutdown(proc_a)
            shutdown(proc_b)

    def test_excludes_entries_not_targeted_at_caller(self, broker_dir: Path, memory_root: Path) -> None:
        """alice writes shared_with carol; bob's shared_with_me must NOT include it."""
        proc_a, proc_b = _start_pair(broker_dir, memory_root,
                                     "s-excl-a", "alice-excl",
                                     "s-excl-b", "bob-excl")
        try:
            tool_result_json(call_tool(proc_a, "memory_write", {
                "name": "alice-to-carol",
                "shared_with": ["carol-not-bob"],
                "content": "for carol only",
            }))
            shared_resp = tool_result_json(call_tool(proc_b, "memory_list", {
                "shared_with_me": True,
            }))
            names = [e.get("name") for e in shared_resp]
            assert "alice-to-carol" not in names, \
                f"bob saw entry not shared with him: {names}"
        finally:
            shutdown(proc_a)
            shutdown(proc_b)


# --- memory_write tests ---


class TestMemoryWriteHandoff:
    """memory_write with shared_with triggers #286 send-memory handoff DM
    to each recipient. Verified via inbox archive (works any binary)
    + broker.log entry (stronger assertion when #327 is in build)."""

    def test_handoff_dm_arrives_in_recipient_inbox(self, broker_dir: Path, memory_root: Path) -> None:
        proc_a, proc_b = _start_pair(broker_dir, memory_root,
                                     "s-handoff-a", "alice-h",
                                     "s-handoff-b", "bob-h")
        try:
            tool_result_json(call_tool(proc_a, "memory_write", {
                "name": "handoff-note",
                "description": "for bob",
                "shared_with": ["bob-h"],
                "content": "handoff body",
            }))
            # Bob polls — handoff DM should be there.
            time.sleep(0.2)  # let enqueue settle
            poll_resp = tool_result_json(call_tool(proc_b, "poll_inbox", {}))
            handoff = [m for m in poll_resp
                       if "memory shared with you" in m.get("content", "")]
            assert len(handoff) >= 1, \
                f"no handoff DM in bob's inbox; got {poll_resp!r}"
            assert "alice-h" in handoff[0]["content"], \
                f"DM doesn't name the author: {handoff[0]!r}"
            assert "handoff-note" in handoff[0]["content"], \
                f"DM doesn't name the entry: {handoff[0]!r}"
        finally:
            shutdown(proc_a)
            shutdown(proc_b)

    def test_shared_with_comma_string_parses_same_as_list(self, broker_dir: Path, memory_root: Path) -> None:
        """MCP wrapper accepts shared_with as either JSON list or
        comma-separated string. Both must produce the same handoff
        DMs — closes the arg-coercion-gap hypothesis from #326/#327
        analysis."""
        proc_a, proc_b = _start_pair(broker_dir, memory_root,
                                     "s-comma-a", "alice-c",
                                     "s-comma-b", "bob-c")
        try:
            # Pass shared_with as comma-string, not list.
            tool_result_json(call_tool(proc_a, "memory_write", {
                "name": "comma-note",
                "shared_with": "bob-c",
                "content": "comma body",
            }))
            time.sleep(0.2)
            poll_resp = tool_result_json(call_tool(proc_b, "poll_inbox", {}))
            handoff = [m for m in poll_resp
                       if "memory shared with you" in m.get("content", "")
                       and "comma-note" in m.get("content", "")]
            assert len(handoff) >= 1, \
                f"comma-string shared_with didn't fire handoff: {poll_resp!r}"
        finally:
            shutdown(proc_a)
            shutdown(proc_b)

    def test_globally_shared_skips_targeted_handoff(self, broker_dir: Path, memory_root: Path) -> None:
        """When shared:true, the entry is global (audience = everyone),
        so per-recipient targeted handoff DMs would be noise. The
        #285 global-vs-targeted precedence rule says global wins:
        no DMs fire even if shared_with is also populated. This
        assertion is what catches a future regression that conflates
        the two paths (e.g. an or-condition becoming and-condition,
        or a mistakenly-removed early-return)."""
        proc_a, proc_b = _start_pair(broker_dir, memory_root,
                                     "s-global-a", "alice-g",
                                     "s-global-b", "bob-g")
        try:
            tool_result_json(call_tool(proc_a, "memory_write", {
                "name": "global-note",
                "shared": True,
                "shared_with": ["bob-g"],  # global wins per #285; this list is ignored
                "content": "global content",
            }))
            time.sleep(0.2)
            poll_resp = tool_result_json(call_tool(proc_b, "poll_inbox", {}))
            handoff = [m for m in poll_resp
                       if "memory shared with you" in m.get("content", "")
                       and "global-note" in m.get("content", "")]
            assert len(handoff) == 0, \
                f"globally-shared entry incorrectly fired targeted handoff: {handoff!r}"
        finally:
            shutdown(proc_a)
            shutdown(proc_b)

    def test_empty_shared_with_no_handoff_attempt(self, broker_dir: Path, memory_root: Path) -> None:
        """Private entry (no shared_with) should not trigger any handoff."""
        proc_a, proc_b = _start_pair(broker_dir, memory_root,
                                     "s-empty-a", "alice-e",
                                     "s-empty-b", "bob-e")
        try:
            tool_result_json(call_tool(proc_a, "memory_write", {
                "name": "private-note",
                "content": "private",
            }))
            time.sleep(0.2)
            poll_resp = tool_result_json(call_tool(proc_b, "poll_inbox", {}))
            assert poll_resp == [] or all(
                "private-note" not in m.get("content", "") for m in poll_resp
            ), f"bob received handoff for a private entry: {poll_resp!r}"
        finally:
            shutdown(proc_a)
            shutdown(proc_b)

    def test_handoff_logs_to_broker_log(self, broker_dir: Path, memory_root: Path) -> None:
        """#327 diagnostic: every handoff attempt logs a structured
        line to broker.log. Without this surface the 12:02 silent
        failure had no broker-side trace; with it, the next failure
        self-documents."""
        proc_a, proc_b = _start_pair(broker_dir, memory_root,
                                     "s-blog-a", "alice-bl",
                                     "s-blog-b", "bob-bl")
        try:
            tool_result_json(call_tool(proc_a, "memory_write", {
                "name": "logged-handoff",
                "shared_with": ["bob-bl"],
                "content": "for bob",
            }))
            time.sleep(0.2)
            log_rows = _read_broker_log(broker_dir)
            handoff_rows = [r for r in log_rows
                            if r.get("event") == "send_memory_handoff"
                            and r.get("name") == "logged-handoff"]
            assert handoff_rows, \
                f"no send_memory_handoff entry in broker.log: " \
                f"{[r.get('event') for r in log_rows]}"
            row = handoff_rows[0]
            assert row.get("from") == "alice-bl", row
            assert row.get("to") == "bob-bl", row
            assert row.get("ok") is True, row
        finally:
            shutdown(proc_a)
            shutdown(proc_b)
