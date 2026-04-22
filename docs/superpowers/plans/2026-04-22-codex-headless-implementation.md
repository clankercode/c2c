# Codex Headless Managed Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `c2c start codex-headless` as a managed client that launches `codex-turn-start-bridge`, uses one durable XML user-message lane for broker delivery and operator steering, and persists an opaque Codex `thread_id` for resume.

**Architecture:** Reuse the existing Codex-family launch and XML delivery path instead of creating a parallel implementation. `codex-headless` differs from `codex` only at the process boundary: the inner binary is `codex-turn-start-bridge`, bridge stdin is owned by a single durable writer, and resume ids are opaque thread ids rather than UUIDs. Upstream `--thread-id-fd` support is required for full resume; until that lands, runtime should fail fast with a clear error instead of degrading silently.

**Tech Stack:** OCaml (`ocaml/c2c_start.ml`, `ocaml/cli/c2c.ml`), Python deliver daemon (`c2c_deliver_inbox.py`), Python `unittest`, tmux integration tests, existing Codex fork request docs.

---

## File Structure

**Core launcher**
- Modify: `ocaml/c2c_start.ml`
  - Add `codex-headless` as a managed client.
  - Special-case opaque `resume_session_id` handling for headless.
  - Wire bridge stdin, thread-id handoff pipe, and operator queue path.
  - Add code comments explaining v1 constraints:
    - `--approval-policy never` until bridge approval handoff exists
    - headless resume ids are opaque thread ids, not UUIDs
    - one writer owns bridge stdin to preserve spool durability
- Modify: `ocaml/c2c_start.mli`
  - Update client docs and function docs for `codex-headless`.

**CLI/install surface**
- Modify: `ocaml/cli/c2c.ml`
  - Accept `codex-headless` in install/init/start-facing client lists.
  - Alias `install codex-headless` to shared Codex setup.
  - Keep help text and error strings consistent.

**Durable XML writer**
- Modify: `c2c_deliver_inbox.py`
  - Keep the deliver daemon as the single owner of bridge stdin.
  - Add an operator-queue input path that merges into the existing XML spool.
  - Preserve spool-on-failure semantics for both broker and operator messages.

**Tests**
- Modify: `tests/test_c2c_start.py`
  - Add fast deterministic tests for client registration, arg generation, opaque resume ids, and headless-specific fail-fast behavior.
- Modify: `tests/test_c2c_cli.py`
  - Add install alias coverage for `codex-headless`.
- Modify: `tests/test_c2c_deliver_inbox.py`
  - Add single-writer/operator-queue tests.
- Create: `tests/test_c2c_codex_headless_tmux.py`
  - Add capability-gated live smoke coverage.

**Docs**
- Modify: `docs/commands.md`
- Modify: `docs/client-delivery.md`
- Modify: `docs/overview.md`

**Reference docs already written**
- Existing upstream request: `/home/xertrov/x-game-src/refs/codex/THREAD_ID_HANDOFF.md`
- Existing upstream request: `/home/xertrov/x-game-src/refs/codex/APPROVAL_FLOW_REQ.md`

## Upstream Dependency Note

`codex-turn-start-bridge` in XML mode does not call `thread/start` or `thread/resume`
until it has read the first `<message type="user">...</message>` from stdin.
That means:

- `c2c start codex-headless` must not block startup waiting for a thread id
- thread-id persistence must be **lazy**
- the first real broker/operator message is what triggers thread creation or resume

Plan for this explicitly. Do **not** inject a synthetic bootstrap message in v1.

## Task 1: CLI Alias And Client List

**Files:**
- Modify: `tests/test_c2c_cli.py`
- Modify: `tests/test_c2c_start.py`
- Modify: `ocaml/cli/c2c.ml`

- [ ] **Step 1: Write the failing tests**

Add these tests:

```python
# tests/test_c2c_cli.py
def test_install_codex_headless_aliases_to_codex_setup(self):
    result = run_cli("c2c", "install", "codex-headless", "--json", env=self.env)
    self.assertEqual(result.returncode, 0)
    payload = json.loads(result.stdout)
    self.assertEqual(payload["client"], "codex")

# tests/test_c2c_start.py
def test_supported_clients_include_codex_headless(self):
    self.assertIn("codex-headless", self.c2c_start.SUPPORTED_CLIENTS)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
python3 -m unittest \
  tests.test_c2c_cli.C2CCLITests.test_install_codex_headless_aliases_to_codex_setup \
  tests.test_c2c_start.C2CStartUnitTests.test_supported_clients_include_codex_headless \
  -v
```

Expected: failure because `codex-headless` is not accepted yet.

- [ ] **Step 3: Implement the minimal CLI aliasing**

Update `ocaml/cli/c2c.ml` so `codex-headless` is treated as an alias of `codex`
for install/init, but remains a distinct client everywhere else:

```ocaml
let canonical_install_client client =
  match String.lowercase_ascii client with
  | "codex-headless" -> "codex"
  | other -> other

let known_clients = [ "claude"; "codex"; "codex-headless"; "opencode"; "kimi"; "crush" ]

let do_install_client ?(channel_delivery=false) ~output_mode ~client ~alias_opt ~broker_root_opt ~target_dir_opt ~force () =
  let client = canonical_install_client client in
  match client with
  | "claude" -> setup_claude ~output_mode ~root ~alias_val ~alias_opt ~server_path ~mcp_command ~force ~channel_delivery
  | "codex" -> setup_codex ~output_mode ~root ~alias_val ~server_path
  | "kimi" -> setup_kimi ~output_mode ~root ~alias_val ~server_path
  | "opencode" -> setup_opencode ~output_mode ~root ~alias_val ~server_path ~target_dir_opt ~force ()
  | "crush" -> setup_crush ~output_mode ~root ~alias_val ~server_path
  | _ -> failwith "unreachable: client validated earlier"
```

Also update the help/error text so `codex-headless` appears in accepted client
lists for `install`, `init`, and `start`.

- [ ] **Step 4: Run the targeted tests and a compile check**

Run:

```bash
python3 -m unittest \
  tests.test_c2c_cli.C2CCLITests.test_install_codex_headless_aliases_to_codex_setup \
  tests.test_c2c_start.C2CStartUnitTests.test_supported_clients_include_codex_headless \
  -v
just build
```

Expected:
- both tests: `OK`
- `just build`: success

- [ ] **Step 5: Commit**

```bash
git add ocaml/cli/c2c.ml tests/test_c2c_cli.py tests/test_c2c_start.py
git commit -m "feat: add codex-headless cli alias"
```

## Task 2: Codex-Family Launcher Entry And Opaque Resume IDs

**Files:**
- Modify: `tests/test_c2c_start.py`
- Modify: `ocaml/c2c_start.ml`
- Modify: `ocaml/c2c_start.mli`

- [ ] **Step 1: Write the failing tests**

Add headless launcher tests:

```python
def test_cmd_start_initial_headless_config_uses_empty_resume_id(self):
    broker_root = Path(self.temp_dir.name) / "broker"
    with (
        mock.patch.object(self.c2c_start, "bridge_supports_thread_id_fd", return_value=True),
        mock.patch.object(self.c2c_start, "run_outer_loop", return_value=0),
    ):
        rc = self.c2c_start.cmd_start("codex-headless", "headless-proof", [], broker_root)
    self.assertEqual(rc, 0)
    cfg = self.c2c_start.load_instance_config("headless-proof")
    self.assertEqual(cfg["resume_session_id"], "")

def test_codex_headless_launch_args_force_bridge_flags(self):
    broker_root = Path(self.temp_dir.name) / "broker"
    args = self.c2c_start.prepare_launch_args(
        "headless-proof",
        "codex-headless",
        ["--model", "gpt-5"],
        broker_root,
        resume_session_id="thread-abc",
    )
    self.assertEqual(
        args,
        [
            "--stdin-format", "xml",
            "--codex-bin", "codex",
            "--approval-policy", "never",
            "--thread-id", "thread-abc",
            "--model", "gpt-5",
        ],
    )

def test_codex_headless_session_id_override_accepts_opaque_thread_id(self):
    broker_root = Path(self.temp_dir.name) / "broker"
    with (
        mock.patch.object(self.c2c_start, "bridge_supports_thread_id_fd", return_value=True),
        mock.patch.object(self.c2c_start, "run_outer_loop", return_value=0) as mock_loop,
    ):
        rc = self.c2c_start.cmd_start(
            "codex-headless",
            "headless-proof",
            [],
            broker_root,
            session_id_override="thread-opaque-123",
        )
    self.assertEqual(rc, 0)
    self.assertEqual(mock_loop.call_args.kwargs["resume_session_id"], "thread-opaque-123")

def test_saved_headless_resume_id_is_not_regenerated_as_uuid(self):
    inst_dir = self.instances_dir / "headless-proof"
    inst_dir.mkdir(parents=True, exist_ok=True)
    (inst_dir / "config.json").write_text(json.dumps({
        "name": "headless-proof",
        "client": "codex-headless",
        "session_id": "headless-proof",
        "resume_session_id": "thread-still-opaque",
        "alias": "headless-proof",
        "extra_args": [],
        "created_at": 0,
        "broker_root": str(Path(self.temp_dir.name) / "broker"),
        "auto_join_rooms": "swarm-lounge",
    }), encoding="utf-8")
    with (
        mock.patch.object(self.c2c_start, "bridge_supports_thread_id_fd", return_value=True),
        mock.patch.object(self.c2c_start, "run_outer_loop", return_value=0) as mock_loop,
    ):
        rc = self.c2c_start.cmd_start("codex-headless", "headless-proof", [], Path(self.temp_dir.name) / "broker")
    self.assertEqual(rc, 0)
    self.assertEqual(mock_loop.call_args.kwargs["resume_session_id"], "thread-still-opaque")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
python3 -m unittest \
  tests.test_c2c_start.C2CStartUnitTests.test_cmd_start_initial_headless_config_uses_empty_resume_id \
  tests.test_c2c_start.C2CStartUnitTests.test_codex_headless_launch_args_force_bridge_flags \
  tests.test_c2c_start.C2CStartUnitTests.test_codex_headless_session_id_override_accepts_opaque_thread_id \
  tests.test_c2c_start.C2CStartUnitTests.test_saved_headless_resume_id_is_not_regenerated_as_uuid \
  -v
```

Expected: failures because `codex-headless` is still unknown and the UUID-only
resume handling rejects opaque ids.

- [ ] **Step 3: Implement the Codex-family launcher entry**

Add a client entry and special-case `prepare_launch_args`/`cmd_start`:

```ocaml
Stdlib.Hashtbl.add clients "codex-headless"
  { binary = "codex-turn-start-bridge"; deliver_client = "codex-headless";
    needs_deliver = true; needs_wire_daemon = false; needs_poker = false;
    poker_event = None; poker_from = None; extra_env = [] };

| "codex-headless" ->
    [ "--stdin-format"; "xml";
      "--codex-bin"; "codex";
      "--approval-policy"; "never" ]
    @ (match resume_session_id with Some sid when String.trim sid <> "" -> [ "--thread-id"; sid ] | _ -> [])
    @ extra_args
```

Update validation in `cmd_start` so `codex-headless` stores an opaque
`resume_session_id` instead of forcing UUID semantics:

```ocaml
let initial_resume_session_id ~client ~session_id_override =
  match client, session_id_override with
  | "codex-headless", None -> ""
  | "codex-headless", Some sid -> sid
  | _, Some sid -> sid
  | _, None -> Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ())

| Some sid when client = "codex-headless" ->
    if String.trim sid = "" then begin
      Printf.eprintf "error: --session-id for codex-headless must be a non-empty thread id\n%!";
      exit 1
    end
```

Add code comments at the branch points:

```ocaml
(* codex-headless stores the Codex bridge thread id here. It is opaque and
   intentionally not UUID-validated like Claude/Codex TUI resume ids. *)
```

```ocaml
(* Keep headless on approval-policy=never until the bridge exposes a machine-
   readable approval handoff. See APPROVAL_FLOW_REQ.md in the Codex fork. *)
```

When calling `run_outer_loop`, normalize the persisted empty-string sentinel
back to `None` so the first launch omits `--thread-id` cleanly:

```ocaml
let launch_resume_session_id =
  match client, cfg.resume_session_id with
  | "codex-headless", sid when String.trim sid = "" -> None
  | _, sid -> Some sid
```

- [ ] **Step 4: Run the targeted tests and `just build`**

Run:

```bash
python3 -m unittest \
  tests.test_c2c_start.C2CStartUnitTests.test_cmd_start_initial_headless_config_uses_empty_resume_id \
  tests.test_c2c_start.C2CStartUnitTests.test_codex_headless_launch_args_force_bridge_flags \
  tests.test_c2c_start.C2CStartUnitTests.test_codex_headless_session_id_override_accepts_opaque_thread_id \
  tests.test_c2c_start.C2CStartUnitTests.test_saved_headless_resume_id_is_not_regenerated_as_uuid \
  -v
just build
```

Expected:
- tests: `OK`
- `just build`: success

- [ ] **Step 5: Commit**

```bash
git add ocaml/c2c_start.ml ocaml/c2c_start.mli tests/test_c2c_start.py
git commit -m "feat: add codex-headless launch args and opaque resume ids"
```

## Task 3: Thread-ID Handoff Capability And Lazy Persistence

**Files:**
- Modify: `tests/test_c2c_start.py`
- Modify: `ocaml/c2c_start.ml`
- Modify: `ocaml/c2c_start.mli`

- [ ] **Step 1: Write the failing tests**

Add capability and lazy-persistence tests:

```python
def test_codex_headless_requires_thread_id_handoff_capability(self):
    with mock.patch.object(self.c2c_start, "bridge_supports_thread_id_fd", return_value=False):
        buf = io.StringIO()
        with mock.patch("sys.stderr", buf):
            rc = self.c2c_start.cmd_start("codex-headless", "headless-proof", [], Path(self.temp_dir.name) / "broker")
    self.assertEqual(rc, 1)
    self.assertIn("--thread-id-fd", buf.getvalue())

def test_codex_headless_start_does_not_block_waiting_for_first_thread_id(self):
    broker_root = Path(self.temp_dir.name) / "broker"
    with (
        mock.patch.object(self.c2c_start, "bridge_supports_thread_id_fd", return_value=True),
        mock.patch.object(self.c2c_start, "run_outer_loop", return_value=0) as mock_loop,
    ):
        rc = self.c2c_start.cmd_start("codex-headless", "headless-proof", [], broker_root)
    self.assertEqual(rc, 0)
    self.assertIsNone(mock_loop.call_args.kwargs["resume_session_id"])
```

Add one state-update test that exercises the persistence callback/helper:

```python
def test_persist_headless_thread_id_updates_config(self):
    cfg = {
        "name": "headless-proof",
        "client": "codex-headless",
        "session_id": "headless-proof",
        "resume_session_id": "",
        "alias": "headless-proof",
        "extra_args": [],
        "created_at": 0,
        "broker_root": str(Path(self.temp_dir.name) / "broker"),
        "auto_join_rooms": "swarm-lounge",
    }
    self.c2c_start.write_instance_config("headless-proof", cfg)
    self.c2c_start.persist_headless_thread_id("headless-proof", "thread-new")
    saved = self.c2c_start.load_instance_config("headless-proof")
    self.assertEqual(saved["resume_session_id"], "thread-new")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
python3 -m unittest \
  tests.test_c2c_start.C2CStartUnitTests.test_codex_headless_requires_thread_id_handoff_capability \
  tests.test_c2c_start.C2CStartUnitTests.test_codex_headless_start_does_not_block_waiting_for_first_thread_id \
  tests.test_c2c_start.C2CStartUnitTests.test_persist_headless_thread_id_updates_config \
  -v
```

Expected: failures because the capability check/helper does not exist yet.

- [ ] **Step 3: Implement handoff detection and lazy persistence**

Add a bridge capability probe and a config update helper:

```ocaml
let bridge_supports_thread_id_fd (binary_path : string) : bool =
  command_help_contains binary_path "--thread-id-fd"

let persist_headless_thread_id ~(name : string) ~(thread_id : string) : unit =
  match load_config_opt name with
  | None -> ()
  | Some cfg ->
      write_config { cfg with resume_session_id = thread_id }
```

In the outer loop:

```ocaml
let thread_id_pipe =
  if client = "codex-headless" then Some (Unix.pipe ~cloexec:false ()) else None
```

Pass `--thread-id-fd 5` only for `codex-headless`, and read the JSON handoff
asynchronously. Persist it when it arrives, but do **not** block startup on it.

Use an explicit code comment for the XML-prelude nuance:

```ocaml
(* In XML mode the bridge does not start/resume a thread until it sees the first
   <message>. So headless startup cannot wait for a thread-id handoff here; we
   persist it lazily when the bridge emits it after the first real input. *)
```

Be explicit in the launch path that the persisted empty-string sentinel means
"no thread id yet" and must not become `--thread-id ""`:

```ocaml
let launch_resume_session_id =
  match client, cfg.resume_session_id with
  | "codex-headless", sid when String.trim sid = "" -> None
  | _, sid -> Some sid
```

- [ ] **Step 4: Run the targeted tests and `just build`**

Run:

```bash
python3 -m unittest \
  tests.test_c2c_start.C2CStartUnitTests.test_codex_headless_requires_thread_id_handoff_capability \
  tests.test_c2c_start.C2CStartUnitTests.test_codex_headless_start_does_not_block_waiting_for_first_thread_id \
  tests.test_c2c_start.C2CStartUnitTests.test_persist_headless_thread_id_updates_config \
  -v
just build
```

Expected:
- tests: `OK`
- `just build`: success

- [ ] **Step 5: Commit**

```bash
git add ocaml/c2c_start.ml ocaml/c2c_start.mli tests/test_c2c_start.py
git commit -m "feat: persist codex-headless thread ids lazily"
```

## Task 4: Single-Writer Durable XML Queue In The Deliver Daemon

**Files:**
- Modify: `tests/test_c2c_deliver_inbox.py`
- Modify: `c2c_deliver_inbox.py`

- [ ] **Step 1: Write the failing tests**

Add tests for the new operator queue path:

```python
def test_deliver_once_xml_output_merges_operator_queue_before_write(self):
    with tempfile.TemporaryDirectory() as temp_dir:
        broker_root = Path(temp_dir) / "broker"
        broker_root.mkdir()
        queue_path = broker_root.parent / "codex-headless" / "headless-proof.operator-queue.json"
        queue_path.parent.mkdir(parents=True, exist_ok=True)
        queue_path.write_text(json.dumps([
            {"content": "operator says hello", "from_alias": "local", "to_alias": "headless-proof"}
        ]), encoding="utf-8")
        read_fd, write_fd = os.pipe()
        try:
            result = c2c_deliver_inbox.deliver_once(
                broker_root=broker_root,
                session_id="headless-proof",
                client="codex-headless",
                terminal_pid=None,
                pts=None,
                xml_output_fd=write_fd,
                operator_queue_path=queue_path,
            )
        finally:
            os.close(write_fd)
            payload = os.read(read_fd, 65536).decode("utf-8")
            os.close(read_fd)
    self.assertEqual(result["delivered"], 1)
    self.assertIn("operator says hello", payload)

def test_deliver_once_xml_output_keeps_operator_queue_on_write_failure(self):
    with tempfile.TemporaryDirectory() as temp_dir:
        broker_root = Path(temp_dir) / "broker"
        broker_root.mkdir()
        queue_path = broker_root.parent / "codex-headless" / "headless-proof.operator-queue.json"
        queue_path.parent.mkdir(parents=True, exist_ok=True)
        queue_path.write_text(json.dumps([
            {"content": "operator says hello", "from_alias": "local", "to_alias": "headless-proof"}
        ]), encoding="utf-8")
        read_fd, write_fd = os.pipe()
        os.close(read_fd)
        os.close(write_fd)
        with self.assertRaises(OSError):
            c2c_deliver_inbox.deliver_once(
                broker_root=broker_root,
                session_id="headless-proof",
                client="codex-headless",
                terminal_pid=None,
                pts=None,
                xml_output_fd=write_fd,
                operator_queue_path=queue_path,
            )
        queued = json.loads(queue_path.read_text(encoding="utf-8"))
        self.assertEqual(queued[0]["content"], "operator says hello")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
python3 -m unittest \
  tests.test_c2c_deliver_inbox.C2CDeliverInboxLoopTests.test_deliver_once_xml_output_merges_operator_queue_before_write \
  tests.test_c2c_deliver_inbox.C2CDeliverInboxLoopTests.test_deliver_once_xml_output_keeps_operator_queue_on_write_failure \
  -v
```

Expected: failures because `operator_queue_path` and merge logic do not exist.

- [ ] **Step 3: Implement the operator queue and single-writer merge**

Add helpers:

```python
def stage_operator_queue_into_xml_spool(*, operator_queue_path: Path, spool: C2CSpool) -> list[dict[str, Any]]:
    queued = _read_message_list(operator_queue_path)
    if not queued:
        return spool.read()
    staged = spool.read()
    spool.replace([*staged, *queued])
    c2c_poll_inbox.atomic_write_json(operator_queue_path, [])
    return [*staged, *queued]
```

Extend `deliver_once(...)`:

```python
if xml_output_fd is not None:
    spool = C2CSpool(default_xml_spool_path(broker_root, session_id))
    messages = spool.read()
    if operator_queue_path is not None:
        messages = stage_operator_queue_into_xml_spool(
            operator_queue_path=operator_queue_path,
            spool=spool,
        )
    if not messages:
        messages = stage_inbox_into_xml_spool(
            broker_root=broker_root,
            session_id=session_id,
            spool=spool,
        )
```

Add a short code comment here:

```python
# codex-headless and codex TUI both rely on one durable XML writer. Operator
# steering is queued here instead of writing directly to the live fd so crash
# recovery keeps the same at-least-once behavior as broker delivery.
```

Also add a short unblocker comment near the new queue merge helper:

```python
# Temporary unblocker: headless reuses the existing Python XML deliver path so
# codex and codex-headless keep one delivery contract while the OCaml port
# catches up.
```

- [ ] **Step 4: Run the targeted tests and the existing XML-spool tests**

Run:

```bash
python3 -m unittest \
  tests.test_c2c_deliver_inbox.C2CDeliverInboxLoopTests.test_deliver_once_xml_output_merges_operator_queue_before_write \
  tests.test_c2c_deliver_inbox.C2CDeliverInboxLoopTests.test_deliver_once_xml_output_keeps_operator_queue_on_write_failure \
  tests.test_c2c_deliver_inbox.C2CDeliverInboxLoopTests.test_deliver_once_xml_output_spools_and_clears_after_success \
  tests.test_c2c_deliver_inbox.C2CDeliverInboxLoopTests.test_deliver_once_xml_output_keeps_spool_on_write_failure \
  -v
```

Expected: all tests `OK`.

- [ ] **Step 5: Commit**

```bash
git add c2c_deliver_inbox.py tests/test_c2c_deliver_inbox.py
git commit -m "feat: add single-writer operator queue for codex headless"
```

## Task 5: Bridge Stdin Wiring And Minimal Headless Console

**Files:**
- Modify: `tests/test_c2c_start.py`
- Modify: `ocaml/c2c_start.ml`
- Modify: `ocaml/c2c_start.mli`

- [ ] **Step 1: Write the failing tests**

Add launcher tests for the queue path and headless-mode daemon wiring:

```python
def test_start_deliver_daemon_passes_operator_queue_path_for_codex_headless(self):
    with mock.patch("c2c_start.subprocess.Popen") as popen:
        self.c2c_start._start_deliver_daemon(
            "headless-proof",
            "codex-headless",
            Path("/tmp/broker"),
            xml_output_fd=4,
            operator_queue_path=Path("/tmp/headless-proof.operator-queue.json"),
        )
    argv = popen.call_args.args[0]
    self.assertIn("--xml-output-fd", argv)
    self.assertIn("--operator-queue-path", argv)

def test_codex_headless_rejects_reserved_extra_args(self):
    broker_root = Path(self.temp_dir.name) / "broker"
    buf = io.StringIO()
    with mock.patch("sys.stderr", buf):
        rc = self.c2c_start.cmd_start(
            "codex-headless",
            "headless-proof",
            ["--approval-policy", "on-request"],
            broker_root,
        )
    self.assertEqual(rc, 1)
    self.assertIn("--approval-policy", buf.getvalue())
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
python3 -m unittest \
  tests.test_c2c_start.C2CStartUnitTests.test_start_deliver_daemon_passes_operator_queue_path_for_codex_headless \
  tests.test_c2c_start.C2CStartUnitTests.test_codex_headless_rejects_reserved_extra_args \
  -v
```

Expected: failures because the launcher has no operator-queue path and no
reserved-flag rejection yet.

- [ ] **Step 3: Implement headless stdin ownership and console**

In `ocaml/c2c_start.ml`:

```ocaml
let reserved_headless_flags =
  [ "--stdin-format"; "--codex-bin"; "--thread-id"; "--approval-policy" ]

let reject_reserved_headless_flags extra_args =
  match List.find_opt (fun arg -> List.mem arg reserved_headless_flags) extra_args with
  | Some flag ->
      Printf.eprintf "error: %s is managed by c2c for codex-headless\n%!" flag;
      exit 1
  | None -> ()
```

Create a pipe for bridge stdin, but keep the daemon as the only writer owner:

```ocaml
let headless_stdin_pipe =
  if client = "codex-headless" then Some (Unix.pipe ~cloexec:false ()) else None
```

Dup the read end onto child stdin in the child branch. Pass the write end to the
deliver daemon as `--xml-output-fd`. Add an `operator_queue_path` like:

```ocaml
let operator_queue_path name = instance_dir name // "operator-queue.json"
```

In the parent, if stdin is a TTY and the client is `codex-headless`, run a
small loop that appends operator messages to the queue file:

```ocaml
let append_operator_message ~queue_path ~text =
  let message =
    `Assoc [ ("from_alias", `String "local");
             ("to_alias", `String name);
             ("content", `String text) ]
  in
  (* read existing queue JSON list, append, atomic rewrite *)
```

Handle `/help`, `/status`, and `/quit` locally. Add a code comment above the
queue write helper:

```ocaml
(* Do not write operator steering directly to bridge stdin. The deliver daemon
   owns that fd so operator and broker messages share one crash-safe path. *)
```

- [ ] **Step 4: Run the targeted tests and `just build`**

Run:

```bash
python3 -m unittest \
  tests.test_c2c_start.C2CStartUnitTests.test_start_deliver_daemon_passes_operator_queue_path_for_codex_headless \
  tests.test_c2c_start.C2CStartUnitTests.test_codex_headless_rejects_reserved_extra_args \
  -v
just build
```

Expected:
- tests: `OK`
- `just build`: success

- [ ] **Step 5: Commit**

```bash
git add ocaml/c2c_start.ml ocaml/c2c_start.mli tests/test_c2c_start.py
git commit -m "feat: wire codex-headless bridge stdin through durable writer"
```

## Task 6: Docs And Fast Regression Coverage

**Files:**
- Modify: `docs/commands.md`
- Modify: `docs/client-delivery.md`
- Modify: `docs/overview.md`
- Modify: `tests/test_c2c_cli.py`
- Modify: `tests/test_c2c_start.py`
- Modify: `tests/test_c2c_deliver_inbox.py`

- [ ] **Step 1: Write the failing regression/docs tests**

Add one doc-facing/CLI regression test if needed:

```python
def test_start_help_mentions_codex_headless(self):
    result = run_cli("c2c", "start", "--help", env=self.env)
    self.assertEqual(result.returncode, 0)
    self.assertIn("codex-headless", result.stdout)
```

If the test harness already snapshots help text elsewhere, add the assertion in
that existing test instead of duplicating it.

- [ ] **Step 2: Run the regression test**

Run:

```bash
python3 -m unittest \
  tests.test_c2c_cli.C2CCLITests.test_start_help_mentions_codex_headless \
  -v
```

Expected: failure because help/docs do not mention `codex-headless` yet.

- [ ] **Step 3: Update docs with the unblocker-path constraints**

Add doc text that matches the code exactly:

```md
- `c2c start codex-headless` launches `codex-turn-start-bridge` in XML mode.
- V1 uses `--approval-policy never` because the bridge does not yet expose a
  machine-readable approval handoff.
- Broker delivery and local steering share one durable XML writer path.
- Resume depends on a persisted opaque bridge `thread_id`.
```

Use the same phrasing in:

- `docs/commands.md`
- `docs/client-delivery.md`
- `docs/overview.md`

Do not claim:

- rich live transcript output
- guardian approvals
- PTY fallback for headless

- [ ] **Step 4: Run the regression test and the standard quick suite**

Run:

```bash
python3 -m unittest \
  tests.test_c2c_cli.C2CCLITests.test_start_help_mentions_codex_headless \
  tests.test_c2c_start \
  tests.test_c2c_deliver_inbox \
  -v
just build
```

Expected:
- tests: `OK`
- `just build`: success

- [ ] **Step 5: Commit**

```bash
git add docs/commands.md docs/client-delivery.md docs/overview.md tests/test_c2c_cli.py tests/test_c2c_start.py tests/test_c2c_deliver_inbox.py
git commit -m "docs: describe codex-headless unblocker path"
```

## Task 7: Live Smoke Test (Capability-Gated)

**Files:**
- Create: `tests/test_c2c_codex_headless_tmux.py`
- Modify: `scripts/c2c_tmux.py` only if a helper is genuinely missing

- [ ] **Step 1: Write the live smoke test first**

Create a capability-gated tmux test:

```python
import json
import subprocess
import time
from pathlib import Path

import pytest

from scripts import c2c_tmux

def bridge_supports_thread_id_fd() -> bool:
    result = subprocess.run(
        ["codex-turn-start-bridge", "--help"],
        capture_output=True,
        text=True,
        check=False,
    )
    return "--thread-id-fd" in result.stdout

@pytest.mark.tmux
def test_codex_headless_smoke_resume_id_persists(tmp_path):
    if not bridge_supports_thread_id_fd():
        pytest.xfail("updated codex-turn-start-bridge with --thread-id-fd not present yet")
    # launch through the repo tmux helper, send one steering line,
    # wait for config.json to gain a non-empty resume_session_id, then restart
```

- [ ] **Step 2: Run the test to verify the current behavior**

Run:

```bash
python3 -m pytest tests/test_c2c_codex_headless_tmux.py -q -k smoke
```

Expected:
- `XFAIL` when the updated bridge is not installed
- or failure if the launch/persistence wiring is still incomplete

- [ ] **Step 3: Implement the minimum live assertions**

Use existing tmux helpers and assert:

```python
args = c2c_tmux.build_parser().parse_args(
    ["launch", "codex-headless", "-n", "headless-proof", "--new-window"]
)
assert c2c_tmux.cmd_launch(args) == 0

cfg = json.loads(config_path.read_text(encoding="utf-8"))
assert cfg["resume_session_id"]
```

On restart, assert the saved thread id is reused and not replaced with a UUID:

```python
assert restarted_cfg["resume_session_id"] == first_thread_id
```

Also send one operator line through tmux to prove the queue path works:

```python
pane = c2c_tmux.find_alias_pane("headless-proof")
c2c_tmux.tmux("send-keys", "-t", pane, "say hello from operator", capture=False)
c2c_tmux.tmux("send-keys", "-t", pane, "Enter", capture=False)
```

- [ ] **Step 4: Run the live smoke test and install the binaries**

Run:

```bash
python3 -m pytest tests/test_c2c_codex_headless_tmux.py -q -k smoke
just install-all
```

Expected:
- `XFAIL` or `PASS`, never a hanging test
- `just install-all`: success

- [ ] **Step 5: Commit**

```bash
git add tests/test_c2c_codex_headless_tmux.py
git commit -m "test: add codex-headless tmux smoke coverage"
```

## Self-Review

### Spec coverage

- Separate managed client surface: covered by Tasks 1 and 2.
- Shared Codex install semantics: covered by Task 1.
- Single durable XML lane for broker + operator steering: covered by Tasks 4 and 5.
- Minimal operator console: covered by Task 5.
- Opaque `thread_id` persistence and reuse: covered by Tasks 2, 3, and 7.
- V1 `--approval-policy never` with code comments/doc comments explaining why: covered by Tasks 2 and 6.
- Live verification path: covered by Task 7.

### Placeholder scan

- No `TODO`, `TBD`, or “implement later” placeholders remain.
- Deferred features are named explicitly as non-goals or capability-gated behavior.

### Type consistency

- `resume_session_id` is consistently treated as an opaque thread id for `codex-headless`.
- `codex-headless` is the client name everywhere; install canonicalization is only for shared Codex setup.
- “single durable writer” consistently means the deliver daemon owns bridge stdin and operator input is queued.
