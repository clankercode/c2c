import io
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import scripts.c2c_tmux as c2c_tmux


class C2CTmuxTests(unittest.TestCase):
    def test_alias_is_alive_true_when_matching_alive_row_exists(self):
        payload = '[{"alias":"demo","alive":true},{"alias":"other","alive":false}]'
        completed = mock.Mock(stdout=payload)
        with mock.patch.object(c2c_tmux.subprocess, 'run', return_value=completed):
            self.assertTrue(c2c_tmux.alias_is_alive('demo'))

    def test_alias_is_alive_false_when_missing_or_not_alive(self):
        payload = '[{"alias":"demo","alive":false},{"alias":"other","alive":true}]'
        completed = mock.Mock(stdout=payload)
        with mock.patch.object(c2c_tmux.subprocess, 'run', return_value=completed):
            self.assertFalse(c2c_tmux.alias_is_alive('demo'))
            self.assertFalse(c2c_tmux.alias_is_alive('missing'))

    def test_launch_rejects_duplicate_alive_alias_before_tmux_use(self):
        args = c2c_tmux.build_parser().parse_args(['launch', 'opencode', '-n', 'demo'])
        stderr = io.StringIO()
        with mock.patch.dict(os.environ, {'TMUX': '1'}, clear=False):
            with mock.patch.object(c2c_tmux, 'alias_is_alive', return_value=True):
                with mock.patch.object(c2c_tmux, 'tmux') as tmux_mock:
                    with mock.patch('sys.stderr', stderr):
                        rc = c2c_tmux.cmd_launch(args)
        self.assertEqual(rc, 1)
        self.assertIn("alias 'demo' is already alive", stderr.getvalue())
        tmux_mock.assert_not_called()

    def test_send_accepts_multi_word_literal_text_then_enter(self):
        args = c2c_tmux.build_parser().parse_args(['send', 'demo', 'hello', 'world'])

        with mock.patch.object(c2c_tmux, '_resolve_target', return_value=('%7', True, False)):
            with mock.patch.object(c2c_tmux, 'ENTER_HELPER', Path('/no/such/helper')):
                with mock.patch.object(c2c_tmux, 'tmux') as tmux_mock:
                    rc = c2c_tmux.cmd_send(args)

        self.assertEqual(rc, 0)
        tmux_mock.assert_has_calls([
            mock.call('send-keys', '-l', '-t', '%7', 'hello world', capture=False),
            mock.call('send-keys', '-t', '%7', 'Enter', capture=False),
        ])


# --------------------------------------------------------------- supervise


class SuperviseManifestTests(unittest.TestCase):
    def test_parse_full_manifest(self):
        text = """
[supervisor]
poll_interval_s = 5
backoff_base_s = 10
backoff_max_s = 120
session = "swarm"

[[agent]]
alias = "coordinator1"
client = "claude"
role = "coordinator"
cwd = "/repo"

[[agent]]
alias = "coder1"
client = "opencode"
extra = ["--auto", "--foo"]
"""
        specs, opts = c2c_tmux.parse_supervise_manifest(text)
        self.assertEqual(opts['poll_interval_s'], 5.0)
        self.assertEqual(opts['backoff_base_s'], 10.0)
        self.assertEqual(opts['backoff_max_s'], 120.0)
        self.assertEqual(opts['session'], 'swarm')
        self.assertEqual([s.alias for s in specs], ['coordinator1', 'coder1'])
        self.assertEqual(specs[0].role, 'coordinator')
        self.assertEqual(specs[0].cwd, '/repo')
        self.assertEqual(specs[1].extra, ['--auto', '--foo'])

    def test_parse_applies_defaults_and_empty_session_is_none(self):
        text = """
[supervisor]
session = ""

[[agent]]
alias = "a1"
client = "kimi"
"""
        specs, opts = c2c_tmux.parse_supervise_manifest(text)
        self.assertEqual(opts['poll_interval_s'], c2c_tmux.DEFAULT_SUPERVISE_OPTS['poll_interval_s'])
        self.assertIsNone(opts['session'])
        self.assertEqual(specs[0].role, '')
        self.assertEqual(specs[0].extra, [])

    def test_parse_empty_manifest_yields_no_specs(self):
        specs, opts = c2c_tmux.parse_supervise_manifest('')
        self.assertEqual(specs, [])
        self.assertEqual(opts, dict(c2c_tmux.DEFAULT_SUPERVISE_OPTS))

    def test_parse_rejects_agent_missing_client(self):
        text = '[[agent]]\nalias = "a1"\n'
        with self.assertRaises(ValueError):
            c2c_tmux.parse_supervise_manifest(text)

    def test_parse_rejects_agent_missing_alias(self):
        text = '[[agent]]\nclient = "claude"\n'
        with self.assertRaises(ValueError):
            c2c_tmux.parse_supervise_manifest(text)


class SuperviseBackoffTests(unittest.TestCase):
    def test_first_attempt_uses_base(self):
        self.assertEqual(c2c_tmux.backoff_delay(1, 30.0, 300.0), 30.0)

    def test_exponential_growth(self):
        self.assertEqual(c2c_tmux.backoff_delay(2, 30.0, 300.0), 60.0)
        self.assertEqual(c2c_tmux.backoff_delay(3, 30.0, 300.0), 120.0)
        self.assertEqual(c2c_tmux.backoff_delay(4, 30.0, 300.0), 240.0)

    def test_capped_at_max(self):
        self.assertEqual(c2c_tmux.backoff_delay(5, 30.0, 300.0), 300.0)
        self.assertEqual(c2c_tmux.backoff_delay(10, 30.0, 300.0), 300.0)

    def test_base_above_cap_is_capped(self):
        self.assertEqual(c2c_tmux.backoff_delay(1, 500.0, 300.0), 300.0)


def _spec(alias, client='claude'):
    return c2c_tmux.SuperviseSpec(alias=alias, client=client)


class SuperviseDecideTests(unittest.TestCase):
    def test_live_alias_is_not_respawned_and_backoff_resets(self):
        specs = [_spec('a1')]
        state = {'a1': {'fail_count': 3, 'next_attempt_ts': 999.0}}
        to_respawn, new_state = c2c_tmux.decide_respawns(
            specs, {'a1'}, state, now=100.0, base_s=30.0, cap_s=300.0
        )
        self.assertEqual(to_respawn, [])
        self.assertNotIn('a1', new_state)  # backoff cleared on recovery

    def test_dead_alias_first_attempt_respawns_and_seeds_backoff(self):
        specs = [_spec('a1')]
        to_respawn, new_state = c2c_tmux.decide_respawns(
            specs, set(), {}, now=100.0, base_s=30.0, cap_s=300.0
        )
        self.assertEqual([s.alias for s in to_respawn], ['a1'])
        self.assertEqual(new_state['a1']['fail_count'], 1)
        self.assertEqual(new_state['a1']['next_attempt_ts'], 130.0)

    def test_dead_alias_within_backoff_window_is_not_respawned(self):
        specs = [_spec('a1')]
        state = {'a1': {'fail_count': 1, 'next_attempt_ts': 130.0}}
        to_respawn, new_state = c2c_tmux.decide_respawns(
            specs, set(), state, now=120.0, base_s=30.0, cap_s=300.0
        )
        self.assertEqual(to_respawn, [])
        self.assertEqual(new_state['a1'], state['a1'])  # untouched

    def test_dead_alias_after_backoff_window_respawns_and_grows(self):
        specs = [_spec('a1')]
        state = {'a1': {'fail_count': 1, 'next_attempt_ts': 130.0}}
        to_respawn, new_state = c2c_tmux.decide_respawns(
            specs, set(), state, now=130.0, base_s=30.0, cap_s=300.0
        )
        self.assertEqual([s.alias for s in to_respawn], ['a1'])
        self.assertEqual(new_state['a1']['fail_count'], 2)
        self.assertEqual(new_state['a1']['next_attempt_ts'], 130.0 + 60.0)

    def test_stale_alias_removed_from_manifest_is_dropped_from_state(self):
        specs = [_spec('a1')]
        state = {'a1': {'fail_count': 1, 'next_attempt_ts': 200.0},
                 'gone': {'fail_count': 2, 'next_attempt_ts': 200.0}}
        _, new_state = c2c_tmux.decide_respawns(
            specs, {'a1'}, state, now=100.0, base_s=30.0, cap_s=300.0
        )
        self.assertNotIn('gone', new_state)

    def test_mixed_live_and_dead(self):
        specs = [_spec('live1'), _spec('dead1'), _spec('dead2')]
        to_respawn, _ = c2c_tmux.decide_respawns(
            specs, {'live1'}, {}, now=100.0, base_s=30.0, cap_s=300.0
        )
        self.assertEqual({s.alias for s in to_respawn}, {'dead1', 'dead2'})


class SuperviseTickTests(unittest.TestCase):
    def test_tick_respawns_only_dead_aliases(self):
        specs = [_spec('live1'), _spec('dead1')]
        calls: list[str] = []

        new_state = c2c_tmux.run_supervise_tick(
            specs, {},
            live_fn=lambda: {'live1'},
            respawn_fn=lambda s: calls.append(s.alias) or True,
            now=100.0, base_s=30.0, cap_s=300.0,
        )
        self.assertEqual(calls, ['dead1'])
        self.assertIn('dead1', new_state)
        self.assertNotIn('live1', new_state)

    def test_dry_run_does_not_call_respawn_but_advances_state(self):
        specs = [_spec('dead1')]
        calls: list[str] = []

        new_state = c2c_tmux.run_supervise_tick(
            specs, {},
            live_fn=lambda: set(),
            respawn_fn=lambda s: calls.append(s.alias) or True,
            now=100.0, base_s=30.0, cap_s=300.0,
            dry_run=True,
        )
        self.assertEqual(calls, [])  # no real launch in dry-run
        self.assertEqual(new_state['dead1']['fail_count'], 1)

    def test_live_aliases_filters_to_alive_rows(self):
        payload = ('[{"alias":"up","alive":true},'
                   '{"alias":"down","alive":false},'
                   '{"alias":null,"alive":true}]')
        completed = mock.Mock(stdout=payload)
        with mock.patch.object(c2c_tmux.subprocess, 'run', return_value=completed):
            self.assertEqual(c2c_tmux.live_aliases(), {'up'})

    def test_respawn_agent_refuses_outside_tmux(self):
        with mock.patch.dict(os.environ, {}, clear=True):  # no TMUX
            with mock.patch.object(c2c_tmux, 'tmux') as tmux_mock:
                ok = c2c_tmux._respawn_agent(_spec('a1'))
        self.assertFalse(ok)
        tmux_mock.assert_not_called()


class SuperviseCmdTests(unittest.TestCase):
    def test_cmd_supervise_once_dry_run_reads_manifest(self):
        import tempfile

        manifest = (
            '[supervisor]\npoll_interval_s = 1\n\n'
            '[[agent]]\nalias = "dead1"\nclient = "claude"\n'
        )
        with tempfile.NamedTemporaryFile('w', suffix='.toml', delete=False) as fh:
            fh.write(manifest)
            path = fh.name
        try:
            args = c2c_tmux.build_parser().parse_args(
                ['supervise', '--manifest', path, '--once', '--dry-run']
            )
            with mock.patch.object(c2c_tmux, 'live_aliases', return_value=set()):
                with mock.patch.object(c2c_tmux, '_respawn_agent') as respawn_mock:
                    rc = c2c_tmux.cmd_supervise(args)
            self.assertEqual(rc, 0)
            respawn_mock.assert_not_called()  # dry-run never launches
        finally:
            os.unlink(path)

    def test_cmd_supervise_missing_manifest_returns_1(self):
        args = c2c_tmux.build_parser().parse_args(
            ['supervise', '--manifest', '/no/such/supervise.toml', '--once']
        )
        rc = c2c_tmux.cmd_supervise(args)
        self.assertEqual(rc, 1)
