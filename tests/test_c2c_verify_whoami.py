import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_prune
import c2c_verify
import c2c_whoami
from c2c_registry import load_registry, save_registry


AGENT_ONE_SESSION_ID = "6e45bbe8-998c-4140-b77e-c6f117e6ca4b"
AGENT_TWO_SESSION_ID = "fa68bd5b-0529-4292-bc27-d617f6840ce7"


class C2CVerifyUnitTests(unittest.TestCase):
    def test_main_passes_min_messages_to_explicit_broker_verify(self):
        payload = {"participants": {}, "goal_met": False, "source": "broker"}
        stdout = io.StringIO()
        with (
            mock.patch(
                "c2c_verify.verify_progress_broker", return_value=payload
            ) as verify_mock,
            mock.patch("sys.stdout", stdout),
        ):
            rc = c2c_verify.main(["--broker", "--min-messages", "3", "--json"])

        self.assertEqual(rc, 0)
        verify_mock.assert_called_once_with(
            None, alive_only=False, min_messages=3
        )
        self.assertEqual(json.loads(stdout.getvalue()), payload)

    def test_resolve_transcript_path_prefers_sessions_fixture_directory(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture_path = Path(temp_dir) / "fixtures" / "sessions-live.json"
            fixture_path.parent.mkdir(parents=True)
            transcript_path = fixture_path.parent / "nested" / "transcript.jsonl"
            transcript_path.parent.mkdir(parents=True)
            transcript_path.write_text("", encoding="utf-8")

            with tempfile.TemporaryDirectory() as other_dir:
                with (
                    mock.patch.dict(
                        os.environ,
                        {"C2C_SESSIONS_FIXTURE": str(fixture_path)},
                        clear=False,
                    ),
                    mock.patch("os.getcwd", return_value=other_dir),
                ):
                    resolved = c2c_verify.resolve_transcript_path(
                        "nested/transcript.jsonl"
                    )

        self.assertEqual(resolved, transcript_path)

    def test_resolve_transcript_path_preserves_relative_structure_under_fixture_root(
        self,
    ):
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture_root = Path(temp_dir)
            transcript_path = fixture_root / "nested" / "history" / "transcript.jsonl"
            transcript_path.parent.mkdir(parents=True)
            transcript_path.write_text("", encoding="utf-8")

            with mock.patch.dict(
                os.environ, {"C2C_VERIFY_FIXTURE": str(fixture_root)}, clear=False
            ):
                resolved = c2c_verify.resolve_transcript_path(
                    "nested/history/transcript.jsonl"
                )

        self.assertEqual(resolved, transcript_path)

    def test_verify_progress_disambiguates_duplicate_participant_names(self):
        sessions = [
            {"name": "shared-agent", "session_id": "11111111-aaaa", "transcript": "a"},
            {"name": "shared-agent", "session_id": "22222222-bbbb", "transcript": "b"},
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(
                {
                    "registrations": [
                        {"session_id": "11111111-aaaa", "alias": "storm-herald"},
                        {"session_id": "22222222-bbbb", "alias": "ember-crown"},
                    ]
                },
                registry_path,
            )

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_verify.load_sessions", return_value=sessions),
                mock.patch(
                    "c2c_verify.summarize_transcript",
                    side_effect=[
                        {"sent": 2, "received": 3},
                        {"sent": 4, "received": 5},
                    ],
                ),
            ):
                payload = c2c_verify.verify_progress()

        self.assertEqual(
            payload["participants"],
            {
                "shared-agent (11111111)": {"sent": 2, "received": 3},
                "shared-agent (22222222)": {"sent": 4, "received": 5},
            },
        )

    def test_verify_progress_sets_goal_met_only_when_all_participants_meet_threshold(
        self,
    ):
        sessions = [
            {"name": "agent-one", "session_id": "11111111-aaaa", "transcript": "a"},
            {"name": "agent-two", "session_id": "22222222-bbbb", "transcript": "b"},
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(
                {
                    "registrations": [
                        {"session_id": "11111111-aaaa", "alias": "storm-herald"},
                        {"session_id": "22222222-bbbb", "alias": "ember-crown"},
                    ]
                },
                registry_path,
            )

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_verify.load_sessions", return_value=sessions),
                mock.patch(
                    "c2c_verify.summarize_transcript",
                    side_effect=[
                        {"sent": 20, "received": 20},
                        {"sent": 20, "received": 20},
                        {"sent": 20, "received": 20},
                        {"sent": 19, "received": 20},
                    ],
                ),
            ):
                met_payload = c2c_verify.verify_progress()
                not_met_payload = c2c_verify.verify_progress()

        self.assertTrue(met_payload["goal_met"])
        self.assertFalse(not_met_payload["goal_met"])

    def test_verify_progress_ignores_unregistered_live_sessions(self):
        sessions = [
            {
                "name": "agent-one",
                "session_id": AGENT_ONE_SESSION_ID,
                "transcript": "a",
            },
            {
                "name": "agent-two",
                "session_id": AGENT_TWO_SESSION_ID,
                "transcript": "b",
            },
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(
                {
                    "registrations": [
                        {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
                    ]
                },
                registry_path,
            )

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_verify.load_sessions", return_value=sessions),
                mock.patch(
                    "c2c_verify.summarize_transcript",
                    side_effect=[
                        {"sent": 2, "received": 3},
                        {"sent": 99, "received": 99},
                    ],
                ) as summarize,
            ):
                payload = c2c_verify.verify_progress()

        self.assertEqual(
            payload["participants"], {"agent-one": {"sent": 2, "received": 3}}
        )
        summarize.assert_called_once_with("a")

    def test_verify_progress_ignores_missing_transcript_when_session_not_registered(
        self,
    ):
        sessions = [
            {
                "name": "agent-one",
                "session_id": AGENT_ONE_SESSION_ID,
                "transcript": "a",
            },
            {"name": "agent-two", "session_id": AGENT_TWO_SESSION_ID},
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(
                {
                    "registrations": [
                        {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
                    ]
                },
                registry_path,
            )

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_verify.load_sessions", return_value=sessions),
                mock.patch(
                    "c2c_verify.summarize_transcript",
                    return_value={"sent": 1, "received": 4},
                ) as summarize,
            ):
                payload = c2c_verify.verify_progress()

        self.assertEqual(
            payload["participants"], {"agent-one": {"sent": 1, "received": 4}}
        )
        summarize.assert_called_once_with("a")

    def test_summarize_transcript_counts_queued_replies(self):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            transcript_path = Path(handle.name)
            handle.write(
                '{"type":"user","message":{"content":"<c2c event=\\"message\\" from=\\"storm-herald\\" alias=\\"storm-herald\\">one</c2c>"}}\n'
            )
            handle.write(
                '{"type":"user","message":{"content":"<c2c event=\\"message\\" from=\\"storm-herald\\" alias=\\"storm-herald\\">two</c2c>"}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"text","text":"reply one"}]}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"text","text":"reply two"}]}}\n'
            )

        try:
            self.assertEqual(
                c2c_verify.summarize_transcript(str(transcript_path)),
                {"sent": 2, "received": 2},
            )
        finally:
            transcript_path.unlink(missing_ok=True)


class C2CWhoamiUnitTests(unittest.TestCase):
    def test_current_session_identifier_uses_direct_parent_claude_process(self):
        def read_text(path_self):
            if str(path_self) == "/proc/4000/comm":
                return "claude\n"
            if str(path_self) == "/proc/3000/comm":
                return "bash\n"
            if str(path_self) == "/proc/5000/comm":
                return "python3\n"
            raise FileNotFoundError(str(path_self))

        with (
            mock.patch.dict(
                os.environ, {"C2C_SESSION_ID": "", "C2C_SESSION_PID": ""}, clear=False
            ),
            mock.patch("c2c_whoami.os.getpid", return_value=5000),
            mock.patch(
                "c2c_whoami.parent_process_chain",
                return_value=[5000, 4000, 3000],
            ),
            mock.patch(
                "c2c_whoami.Path.read_text", autospec=True, side_effect=read_text
            ),
            mock.patch(
                "c2c_whoami.child_processes",
                side_effect=[[], [], []],
            ),
        ):
            self.assertEqual(c2c_whoami.current_session_identifier(), "4000")

    def test_current_session_identifier_uses_single_claude_child_of_parent_shell(self):
        with (
            mock.patch.dict(
                os.environ, {"C2C_SESSION_ID": "", "C2C_SESSION_PID": ""}, clear=False
            ),
            mock.patch("c2c_whoami.os.getpid", return_value=5000),
            mock.patch(
                "c2c_whoami.parent_process_chain",
                return_value=[5000, 4000, 3000],
            ),
            mock.patch(
                "c2c_whoami.child_processes",
                side_effect=[[], [(11111, "claude")], []],
            ),
        ):
            self.assertEqual(c2c_whoami.current_session_identifier(), "11111")

    def test_current_session_identifier_fails_when_parent_chain_has_multiple_claude_children(
        self,
    ):
        with (
            mock.patch.dict(
                os.environ, {"C2C_SESSION_ID": "", "C2C_SESSION_PID": ""}, clear=False
            ),
            mock.patch("c2c_whoami.os.getpid", return_value=5000),
            mock.patch(
                "c2c_whoami.parent_process_chain",
                return_value=[5000, 4000],
            ),
            mock.patch(
                "c2c_whoami.child_processes",
                return_value=[(11111, "claude"), (22222, "claude")],
            ),
        ):
            with self.assertRaisesRegex(
                ValueError, "could not resolve current session uniquely"
            ):
                c2c_whoami.current_session_identifier()

    def test_summarize_transcript_does_not_count_assistant_after_unrelated_user_turn(
        self,
    ):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            transcript_path = Path(handle.name)
            handle.write(
                '{"type":"user","message":{"content":"<c2c event=\\"message\\" from=\\"storm-herald\\" alias=\\"storm-herald\\">one</c2c>"}}\n'
            )
            handle.write(
                '{"type":"user","message":{"content":"follow-up outside c2c"}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"text","text":"general reply"}]}}\n'
            )

        try:
            self.assertEqual(
                c2c_verify.summarize_transcript(str(transcript_path)),
                {"sent": 0, "received": 1},
            )
        finally:
            transcript_path.unlink(missing_ok=True)

    def test_summarize_transcript_counts_reply_after_tool_use_and_tool_result(self):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            transcript_path = Path(handle.name)
            handle.write(
                '{"type":"user","message":{"content":"<c2c event=\\"message\\" from=\\"storm-herald\\" alias=\\"storm-herald\\">one</c2c>"}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"lookup","input":{}}]}}\n'
            )
            handle.write(
                '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"ok"}]}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"text","text":"reply after tool"}]}}\n'
            )

        try:
            self.assertEqual(
                c2c_verify.summarize_transcript(str(transcript_path)),
                {"sent": 1, "received": 1},
            )
        finally:
            transcript_path.unlink(missing_ok=True)

    def test_summarize_transcript_ignores_onboarding_events(self):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            transcript_path = Path(handle.name)
            handle.write(
                '{"type":"user","message":{"content":"<c2c event=\\"onboarding\\" from=\\"c2c-register\\" alias=\\"storm-herald\\">welcome</c2c>"}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"text","text":"thanks"}]}}\n'
            )
            handle.write(
                '{"type":"user","message":{"content":"<c2c event=\\"message\\" from=\\"storm-herald\\" alias=\\"storm-herald\\">hello</c2c>"}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"text","text":"reply"}]}}\n'
            )

        try:
            self.assertEqual(
                c2c_verify.summarize_transcript(str(transcript_path)),
                {"sent": 1, "received": 1},
            )
        finally:
            transcript_path.unlink(missing_ok=True)


class C2CVerifyBrokerTests(unittest.TestCase):
    """Tests for verify_progress_broker() — broker-archive-based cross-client verify."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.broker_root = Path(self.temp_dir.name) / "broker"
        self.archive_dir = self.broker_root / "archive"
        self.archive_dir.mkdir(parents=True)
        self.registry_path = self.broker_root / "registry.json"

    def tearDown(self):
        self.temp_dir.cleanup()

    def _write_registry(self, registrations: list[dict]) -> None:
        self.registry_path.write_text(json.dumps(registrations), encoding="utf-8")

    def _write_archive(self, filename: str, messages: list[dict]) -> None:
        path = self.archive_dir / filename
        path.write_text(
            "\n".join(json.dumps(m) for m in messages) + "\n",
            encoding="utf-8",
        )

    def test_empty_broker_returns_empty_participants(self):
        self._write_registry([])
        result = c2c_verify.verify_progress_broker(self.broker_root)
        self.assertEqual(result["participants"], {})
        self.assertFalse(result["goal_met"])
        self.assertEqual(result["source"], "broker")

    def test_received_count_from_own_archive(self):
        self._write_registry([{"alias": "agent-a", "session_id": "sess-a"}])
        msgs = [
            {
                "from_alias": "agent-b",
                "to_alias": "agent-a",
                "content": "hi",
                "drained_at": 1.0,
            }
        ]
        self._write_archive("sess-a.jsonl", msgs * 5)
        result = c2c_verify.verify_progress_broker(self.broker_root)
        self.assertEqual(result["participants"]["agent-a"]["received"], 5)

    def test_archive_keyed_by_alias_fallback(self):
        """Named sessions (e.g. codex-local) may have archive file named after alias."""
        self._write_registry([{"alias": "codex", "session_id": "codex-local"}])
        msgs = [
            {
                "from_alias": "agent-a",
                "to_alias": "codex",
                "content": "hi",
                "drained_at": 1.0,
            }
        ]
        # Archive file is named after session_id (codex-local.jsonl)
        self._write_archive("codex-local.jsonl", msgs * 3)
        result = c2c_verify.verify_progress_broker(self.broker_root)
        self.assertEqual(result["participants"]["codex"]["received"], 3)

    def test_sent_count_from_cross_archive_scan(self):
        self._write_registry(
            [
                {"alias": "agent-a", "session_id": "sess-a"},
                {"alias": "agent-b", "session_id": "sess-b"},
            ]
        )
        # agent-b archive: agent-a sent 4 messages to agent-b
        msgs_b = [
            {
                "from_alias": "agent-a",
                "to_alias": "agent-b",
                "content": "hi",
                "drained_at": 1.0,
            }
        ] * 4
        # agent-a archive: agent-b sent 2 messages to agent-a
        msgs_a = [
            {
                "from_alias": "agent-b",
                "to_alias": "agent-a",
                "content": "hey",
                "drained_at": 2.0,
            }
        ] * 2
        self._write_archive("sess-a.jsonl", msgs_a)
        self._write_archive("sess-b.jsonl", msgs_b)
        result = c2c_verify.verify_progress_broker(self.broker_root)
        self.assertEqual(result["participants"]["agent-a"]["sent"], 4)
        self.assertEqual(result["participants"]["agent-b"]["sent"], 2)

    def test_c2c_system_messages_excluded_from_sent(self):
        self._write_registry([{"alias": "agent-a", "session_id": "sess-a"}])
        msgs = [
            {
                "from_alias": "c2c-system",
                "to_alias": "agent-a@swarm-lounge",
                "content": "{}",
                "drained_at": 1.0,
            }
        ] * 10
        self._write_archive("sess-a.jsonl", msgs)
        result = c2c_verify.verify_progress_broker(self.broker_root)
        # c2c-system messages should not count toward any sent tally
        self.assertEqual(result["participants"]["agent-a"]["sent"], 0)

    def test_goal_met_when_both_thresholds_reached(self):
        self._write_registry([{"alias": "agent-a", "session_id": "sess-a"}])
        # 20 messages received, 20 messages "sent" (appearing as from_alias in other archives)
        received = [
            {
                "from_alias": "agent-b",
                "to_alias": "agent-a",
                "content": "hi",
                "drained_at": 1.0,
            }
        ] * 20
        self._write_archive("sess-a.jsonl", received)
        # Simulate agent-a's sent messages appearing in agent-b's archive
        sent_as_from = [
            {
                "from_alias": "agent-a",
                "to_alias": "agent-b",
                "content": "yo",
                "drained_at": 2.0,
            }
        ] * 20
        self._write_archive("sess-b.jsonl", sent_as_from)
        result = c2c_verify.verify_progress_broker(self.broker_root)
        self.assertEqual(result["participants"]["agent-a"]["sent"], 20)
        self.assertEqual(result["participants"]["agent-a"]["received"], 20)
        self.assertTrue(result["goal_met"])

    def test_goal_not_met_when_only_received_threshold_reached(self):
        self._write_registry([{"alias": "agent-a", "session_id": "sess-a"}])
        received = [
            {
                "from_alias": "agent-b",
                "to_alias": "agent-a",
                "content": "hi",
                "drained_at": 1.0,
            }
        ] * 20
        self._write_archive("sess-a.jsonl", received)
        result = c2c_verify.verify_progress_broker(self.broker_root)
        self.assertEqual(result["participants"]["agent-a"]["received"], 20)
        self.assertEqual(result["participants"]["agent-a"]["sent"], 0)
        self.assertFalse(result["goal_met"])

    def test_falls_back_to_yaml_registry_when_json_absent(self):
        # No registry.json — falls back to load_registry() (Python YAML)
        with mock.patch("c2c_verify.load_registry") as mock_load:
            mock_load.return_value = {
                "registrations": [{"alias": "agent-z", "session_id": "sess-z"}]
            }
            result = c2c_verify.verify_progress_broker(self.broker_root)
        self.assertIn("agent-z", result["participants"])

    def test_alive_only_filters_dead_registrations(self):
        # Pass pid without pid_start_time — broker_registration_is_alive returns True
        # if /proc/<pid> exists and pid_start_time is not an int.
        self._write_registry(
            [
                {"alias": "live-agent", "session_id": "sess-live", "pid": os.getpid()},
                {"alias": "dead-agent", "session_id": "sess-dead", "pid": 99999999},
            ]
        )
        result = c2c_verify.verify_progress_broker(self.broker_root, alive_only=True)
        # dead-agent has a nonexistent PID → excluded
        self.assertIn("live-agent", result["participants"])
        self.assertNotIn("dead-agent", result["participants"])

    def test_alive_only_false_includes_dead_registrations(self):
        self._write_registry(
            [
                {"alias": "live-agent", "session_id": "sess-live", "pid": os.getpid()},
                {"alias": "dead-agent", "session_id": "sess-dead", "pid": 99999999},
            ]
        )
        result = c2c_verify.verify_progress_broker(self.broker_root, alive_only=False)
        self.assertIn("live-agent", result["participants"])
        self.assertIn("dead-agent", result["participants"])


class C2CPruneUnitTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.registry_path = Path(self.temp_dir.name) / "registry.yaml"
        self.stale_session_id = "dead0000-0000-0000-0000-000000000000"

    def tearDown(self):
        self.temp_dir.cleanup()

    def _seed_registry(self):
        """Seed 3 registrations: agent-one, agent-two (live), and one stale."""
        registry = {
            "registrations": [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"},
                {"session_id": AGENT_TWO_SESSION_ID, "alias": "ember-crown"},
                {"session_id": self.stale_session_id, "alias": "silver-banner"},
            ]
        }
        save_registry(registry, self.registry_path)
        return registry

    def _mock_load_sessions(self):
        """Return only agent-one as live; agent-two and stale are dead."""
        return [
            {"session_id": AGENT_ONE_SESSION_ID, "name": "agent-one"},
        ]

    def test_prune_removes_stale_entries_from_yaml(self):
        self._seed_registry()

        with (
            mock.patch.dict(os.environ, {"C2C_REGISTRY_PATH": str(self.registry_path)}),
            mock.patch("c2c_prune.load_sessions", side_effect=self._mock_load_sessions),
        ):
            rc = c2c_prune.main([])

        self.assertEqual(rc, 0)
        registry = load_registry(self.registry_path)
        session_ids = [r["session_id"] for r in registry["registrations"]]
        self.assertEqual(session_ids, [AGENT_ONE_SESSION_ID])

    def test_prune_dry_run_does_not_mutate(self):
        self._seed_registry()

        with (
            mock.patch.dict(os.environ, {"C2C_REGISTRY_PATH": str(self.registry_path)}),
            mock.patch("c2c_prune.load_sessions", side_effect=self._mock_load_sessions),
        ):
            rc = c2c_prune.main(["--dry-run"])

        self.assertEqual(rc, 0)
        registry = load_registry(self.registry_path)
        session_ids = [r["session_id"] for r in registry["registrations"]]
        self.assertEqual(len(session_ids), 3)
        self.assertIn(AGENT_ONE_SESSION_ID, session_ids)
        self.assertIn(AGENT_TWO_SESSION_ID, session_ids)
        self.assertIn(self.stale_session_id, session_ids)

    def test_prune_reports_removed_entries_in_json(self):
        self._seed_registry()

        with (
            mock.patch.dict(os.environ, {"C2C_REGISTRY_PATH": str(self.registry_path)}),
            mock.patch("c2c_prune.load_sessions", side_effect=self._mock_load_sessions),
            mock.patch("sys.stdout", new_callable=io.StringIO) as mock_stdout,
        ):
            rc = c2c_prune.main(["--json"])

        self.assertEqual(rc, 0)
        payload = json.loads(mock_stdout.getvalue())
        self.assertEqual(payload["count"], 2)
        self.assertFalse(payload["dry_run"])
        removed_aliases = sorted(entry["alias"] for entry in payload["pruned"])
        self.assertEqual(removed_aliases, ["ember-crown", "silver-banner"])
        removed_session_ids = sorted(entry["session_id"] for entry in payload["pruned"])
        self.assertEqual(
            removed_session_ids,
            sorted([AGENT_TWO_SESSION_ID, self.stale_session_id]),
        )


if __name__ == "__main__":
    unittest.main()
