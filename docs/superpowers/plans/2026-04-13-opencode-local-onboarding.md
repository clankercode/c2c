# Repo-Local OpenCode Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make OpenCode a working `c2c` peer for this repo using only repo-local `./.opencode/` config and the proven polling path.

**Architecture:** Add a repo-local OpenCode config that exposes the existing `c2c_mcp.py` server with a stable `opencode-local` session id, then add a small OpenCode launcher surface that pins the config/env and kickoff prompt. Verify the onboarding with dry-run/unit coverage first and then one live round-trip proof using MCP `poll_inbox` or the existing `c2c-poll-inbox` fallback.

**Tech Stack:** Python launcher scripts, repo-local JSON config, existing `c2c_mcp.py` / `c2c-poll-inbox`, `pytest` in `tests/test_c2c_cli.py`, live `opencode` CLI.

---

## File Map

- Create: `.opencode/opencode.json`
  - repo-local OpenCode config containing only the local `c2c` MCP entry for this repo.
- Create: `run-opencode-inst`
  - inner OpenCode launcher that assembles env/config path/cwd and execs OpenCode with a kickoff prompt.
- Create: `run-opencode-inst-outer`
  - outer restart loop mirroring the Codex shape enough for repeatable local onboarding.
- Create: `run-opencode-inst.d/c2c-opencode-local.json`
  - default repo-local launcher config for the OpenCode participant.
- Possibly create: `restart-opencode-self`
  - only if OpenCode’s process model needs a repo-local restart helper in the first slice.
- Modify: `tests/test_c2c_cli.py`
  - add dry-run tests for the OpenCode launcher/config surface.
- Modify: `tmp_status.txt`
  - record repo-local OpenCode onboarding once verified.
- Modify: `tmp_collab_lock.md`
  - claim/release locks and record proof status.
- Create: `.collab/updates/2026-04-13T*-opencode-local-onboarding.md`
  - record the live proof and exact commands/results.

## Task 1: Add Repo-Local OpenCode Config

**Files:**
- Create: `.opencode/opencode.json`
- Test: `tests/test_c2c_cli.py`

- [ ] **Step 1: Write the failing test for repo-local config shape**

Add a test that asserts the repo-local config exists and contains a `c2c` local MCP entry with:

```python
def test_opencode_local_config_exposes_c2c_mcp(self):
    config = json.loads((REPO / ".opencode" / "opencode.json").read_text(encoding="utf-8"))
    c2c = config["mcp"]["c2c"]
    self.assertEqual(c2c["type"], "local")
    self.assertEqual(c2c["command"][:2], ["python3", str(REPO / "c2c_mcp.py")])
    self.assertEqual(c2c["environment"]["C2C_MCP_SESSION_ID"], "opencode-local")
    self.assertEqual(c2c["environment"]["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")
```

- [ ] **Step 2: Run the new config test to verify it fails**

Run: `python -m pytest tests/test_c2c_cli.py -k opencode_local_config_exposes_c2c_mcp -q`
Expected: FAIL because `.opencode/opencode.json` does not exist yet.

- [ ] **Step 3: Create the minimal repo-local OpenCode config**

Create `.opencode/opencode.json` with this shape:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "c2c": {
      "type": "local",
      "command": [
        "python3",
        "/home/xertrov/src/c2c-msg/c2c_mcp.py"
      ],
      "environment": {
        "C2C_MCP_BROKER_ROOT": "/home/xertrov/src/c2c-msg/.git/c2c/mcp",
        "C2C_MCP_SESSION_ID": "opencode-local",
        "C2C_MCP_AUTO_DRAIN_CHANNEL": "0"
      },
      "enabled": true
    }
  }
}
```

- [ ] **Step 4: Run the config test to verify it passes**

Run: `python -m pytest tests/test_c2c_cli.py -k opencode_local_config_exposes_c2c_mcp -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add .opencode/opencode.json tests/test_c2c_cli.py
git commit -m "opencode: add repo-local c2c config"
```

## Task 2: Add the Inner OpenCode Launcher

**Files:**
- Create: `run-opencode-inst`
- Create: `run-opencode-inst.d/c2c-opencode-local.json`
- Modify: `tests/test_c2c_cli.py`

- [ ] **Step 1: Write the failing dry-run test for the inner launcher**

Add a dry-run test like:

```python
def test_run_opencode_inst_dry_run_reports_local_config_and_session(self):
    env = dict(self.env)
    env["RUN_OPENCODE_INST_DRY_RUN"] = "1"
    result = run_cli("run-opencode-inst", "c2c-opencode-local", env=env)
    self.assertEqual(result_code(result), 0, result.stderr)
    payload = json.loads(result.stdout)
    self.assertEqual(payload["env"]["RUN_OPENCODE_INST_C2C_SESSION_ID"], "opencode-local")
    self.assertEqual(payload["env"]["RUN_OPENCODE_INST_CONFIG_PATH"], str(REPO / ".opencode" / "opencode.json"))
    self.assertEqual(payload["cwd"], str(REPO))
    self.assertIn("opencode", payload["launch"][0])
```

- [ ] **Step 2: Run the launcher test to verify it fails**

Run: `python -m pytest tests/test_c2c_cli.py -k run_opencode_inst_dry_run_reports_local_config_and_session -q`
Expected: FAIL because `run-opencode-inst` does not exist yet.

- [ ] **Step 3: Create the launcher config file**

Create `run-opencode-inst.d/c2c-opencode-local.json` with fields:

```json
{
  "command": "opencode",
  "cwd": "/home/xertrov/src/c2c-msg",
  "config_path": "/home/xertrov/src/c2c-msg/.opencode/opencode.json",
  "c2c_session_id": "opencode-local",
  "prompt": "Session resumed as the OpenCode C2C participant for c2c-msg. First inspect tmp_status.txt and tmp_collab_lock.md. Then register or confirm your c2c identity, call mcp__c2c__poll_inbox if the tool exists, otherwise run ./c2c-poll-inbox --session-id opencode-local --json, and continue on the highest-leverage unblocked work.",
  "flags": []
}
```

- [ ] **Step 4: Implement the inner launcher minimally**

Model it after `run-codex-inst`, but keep the launch shape small:

```python
launch = [
    command,
    "run",
    prompt,
]
env["RUN_OPENCODE_INST_NAME"] = name
env["RUN_OPENCODE_INST_C2C_SESSION_ID"] = c2c_session_id
env["RUN_OPENCODE_INST_CONFIG_PATH"] = str(config_path)
env["C2C_MCP_SESSION_ID"] = c2c_session_id
env["C2C_MCP_BROKER_ROOT"] = str(REPO / ".git" / "c2c" / "mcp")
env["C2C_MCP_AUTO_DRAIN_CHANNEL"] = "0"
```

Use OpenCode’s repo-local config explicitly via the CLI flag its help output documents. If the flag is `--config`, use:

```python
launch = [command, "--config", str(config_path), "run", prompt]
```

If the actual CLI requires a different explicit config flag discovered during implementation, use that exact flag and update the test accordingly.

- [ ] **Step 5: Add dry-run JSON output**

Dry-run output must include:

```json
{
  "launch": ["..."],
  "cwd": "/home/xertrov/src/c2c-msg",
  "env": {
    "RUN_OPENCODE_INST_NAME": "c2c-opencode-local",
    "RUN_OPENCODE_INST_C2C_SESSION_ID": "opencode-local",
    "RUN_OPENCODE_INST_CONFIG_PATH": "/home/xertrov/src/c2c-msg/.opencode/opencode.json"
  }
}
```

- [ ] **Step 6: Run the inner launcher dry-run test to verify it passes**

Run: `python -m pytest tests/test_c2c_cli.py -k run_opencode_inst_dry_run_reports_local_config_and_session -q`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add run-opencode-inst run-opencode-inst.d/c2c-opencode-local.json tests/test_c2c_cli.py
git commit -m "opencode: add repo-local launcher"
```

## Task 3: Add the Outer Restart Loop

**Files:**
- Create: `run-opencode-inst-outer`
- Modify: `tests/test_c2c_cli.py`

- [ ] **Step 1: Write the failing dry-run test for the outer launcher**

Add a test like:

```python
def test_run_opencode_inst_outer_dry_run_reports_inner_launch_command(self):
    env = dict(self.env)
    env["RUN_OPENCODE_INST_OUTER_DRY_RUN"] = "1"
    result = run_cli("run-opencode-inst-outer", "c2c-opencode-local", env=env)
    self.assertEqual(result_code(result), 0, result.stderr)
    payload = json.loads(result.stdout)
    self.assertTrue(Path(payload["inner"][0]).name.startswith("python"))
    self.assertEqual(payload["inner"][1:], [str(REPO / "run-opencode-inst"), "c2c-opencode-local"])
```

- [ ] **Step 2: Run the outer launcher test to verify it fails**

Run: `python -m pytest tests/test_c2c_cli.py -k run_opencode_inst_outer_dry_run_reports_inner_launch_command -q`
Expected: FAIL because `run-opencode-inst-outer` does not exist yet.

- [ ] **Step 3: Implement the outer restart loop**

Mirror the structure of `run-codex-inst-outer` with different script names:

```python
INNER = HERE / "run-opencode-inst"

def inner_command(name: str, extra: list[str]) -> list[str]:
    return [sys.executable, str(INNER), name, *extra]
```

Keep:

- dry-run JSON reporting
- fast-exit backoff
- double-SIGINT escape

Do not add OpenCode-specific restart semantics yet beyond relaunching the inner script.

- [ ] **Step 4: Run the outer launcher test to verify it passes**

Run: `python -m pytest tests/test_c2c_cli.py -k run_opencode_inst_outer_dry_run_reports_inner_launch_command -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add run-opencode-inst-outer tests/test_c2c_cli.py
git commit -m "opencode: add outer launcher loop"
```

## Task 4: Verify Repo-Local OpenCode CLI Integration

**Files:**
- Modify: `tests/test_c2c_cli.py`

- [ ] **Step 1: Add a failing integration test for local config discoverability**

Add a test that shells out to an OpenCode dry-run or listing command against the repo-local config and checks that `c2c` appears in the MCP list output.

Use a fixture gate so this test only runs when OpenCode is present, for example:

```python
@unittest.skipUnless(shutil.which("opencode"), "opencode not installed")
def test_opencode_repo_local_config_lists_c2c_server(self):
    result = subprocess.run(
        ["opencode", "mcp", "list", "--config", str(REPO / ".opencode" / "opencode.json")],
        cwd=REPO,
        capture_output=True,
        text=True,
        timeout=CLI_TIMEOUT_SECONDS,
    )
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertIn("c2c", result.stdout)
```

- [ ] **Step 2: Run the new OpenCode MCP-list test to verify current behavior**

Run: `python -m pytest tests/test_c2c_cli.py -k opencode_repo_local_config_lists_c2c_server -q`
Expected: initially FAIL or SKIP until the launcher/config path is correct.

- [ ] **Step 3: Adjust the launcher/config path until the test passes**

Allowed adjustments:

- config file layout under `./.opencode/`
- explicit OpenCode config flag
- exact local MCP stanza key names (`environment` vs `env`) if OpenCode requires one shape

Do not modify global OpenCode config.

- [ ] **Step 4: Re-run the OpenCode MCP-list test to verify it passes**

Run: `python -m pytest tests/test_c2c_cli.py -k opencode_repo_local_config_lists_c2c_server -q`
Expected: PASS or justified SKIP if the CLI cannot expose repo-local config in a testable noninteractive way and the live proof below covers the same requirement.

- [ ] **Step 5: Commit**

```bash
git add .opencode/opencode.json run-opencode-inst run-opencode-inst-outer tests/test_c2c_cli.py
git commit -m "opencode: verify repo-local MCP integration"
```

## Task 5: Prove One Live OpenCode Round Trip

**Files:**
- Modify: `tmp_status.txt`
- Modify: `tmp_collab_lock.md`
- Create: `.collab/updates/2026-04-13T<time>-opencode-local-proof.md`

- [ ] **Step 1: Claim locks for the status artifacts**

Add active rows to `tmp_collab_lock.md` for:

```text
tmp_status.txt
tmp_collab_lock.md
.collab/updates/<timestamp>-opencode-local-proof.md
```

- [ ] **Step 2: Launch OpenCode locally against the repo-local config**

Use the new launcher or the exact direct command it dry-runs, for example:

```bash
./run-opencode-inst-outer c2c-opencode-local
```

or, if the first slice proves simpler without the outer loop:

```bash
./run-opencode-inst c2c-opencode-local
```

- [ ] **Step 3: Verify OpenCode can see the local `c2c` server**

Evidence can be either:

- OpenCode tool list shows `c2c`, or
- `opencode mcp list` against the repo-local config shows `c2c`

Record the exact command/output in the update note.

- [ ] **Step 4: Register the OpenCode peer and confirm broker identity**

Inside OpenCode or via its local MCP surface, register the alias you intend to use. Then verify broker state with:

```bash
python3 c2c_list.py --json
python3 c2c_whoami.py --json
```

Expected: a stable `opencode-local` broker session id with the chosen alias.

- [ ] **Step 5: Prove inbound receive on the polling path**

From another live peer or the CLI, send a message to the OpenCode alias:

```bash
python3 c2c_send.py <opencode-alias> "probe from local onboarding"
```

Then receive it on OpenCode via either:

```text
mcp__c2c__poll_inbox
```

or

```bash
./c2c-poll-inbox --session-id opencode-local --json
```

Capture the exact evidence in the update note.

- [ ] **Step 6: Prove outbound reply back to another peer**

From OpenCode, send a reply to a known live alias. Confirm receipt from the other side via `poll_inbox` or direct inbox inspection. Record the exact alias pair and evidence.

- [ ] **Step 7: Update shared status artifacts**

Append a `.collab/updates/...` note with:

- repo-local config path used
- commands run
- chosen OpenCode alias
- whether receive used MCP `poll_inbox` or `c2c-poll-inbox`
- one successful inbound and outbound proof

Update `tmp_status.txt` to say repo-local OpenCode onboarding is proven if and only if the round trip actually succeeded.

- [ ] **Step 8: Release locks**

Remove active rows from `tmp_collab_lock.md` and append a release-history entry summarizing the proof.

- [ ] **Step 9: Commit**

```bash
git add tmp_status.txt tmp_collab_lock.md .collab/updates/2026-04-13T*-opencode-local-proof.md
git commit -m "opencode: prove repo-local c2c onboarding"
```

## Task 6: Final Verification

**Files:**
- No new files required beyond prior tasks.

- [ ] **Step 1: Run focused Python launcher/config tests**

Run:

```bash
python -m pytest tests/test_c2c_cli.py -k "opencode or c2c_poll_inbox" -q
```

Expected: PASS.

- [ ] **Step 2: Re-run the full Python suite**

Run:

```bash
python -m pytest tests/test_c2c_cli.py -q
```

Expected: PASS.

- [ ] **Step 3: Re-run the OCaml broker suite for preservation**

Run:

```bash
eval "$(opam env --switch=/home/xertrov/src/call-coding-clis/ocaml --set-switch)" && dune exec --root /home/xertrov/src/c2c-msg ./ocaml/test/test_c2c_mcp.exe
```

Expected: all tests PASS.

- [ ] **Step 4: Run Python syntax verification**

Run:

```bash
python -m py_compile c2c_mcp.py c2c_send.py c2c_poll_inbox.py tests/test_c2c_cli.py run-opencode-inst run-opencode-inst-outer
```

Expected: success.

- [ ] **Step 5: Commit any final verification-only artifact updates**

```bash
git add tmp_status.txt tmp_collab_lock.md .collab/updates/
git commit -m "collab: record repo-local opencode onboarding verification"
```

## Plan Self-Review

- Spec coverage: the plan covers repo-local `./.opencode/` config, stable `opencode-local` identity, launcher surface, polling-path receive, and one local live proof without touching global OpenCode config.
- Placeholder scan: the only implementation-dependent branch is the exact OpenCode explicit config flag; the plan constrains that discovery to Task 2/4 and requires updating tests to the exact observed CLI behavior rather than hand-waving it.
- Scope check: this is focused to repo-local onboarding and proof only; global config rollout remains explicitly deferred.

Plan complete and saved to `docs/superpowers/plans/2026-04-13-opencode-local-onboarding.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
