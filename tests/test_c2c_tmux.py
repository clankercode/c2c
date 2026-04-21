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
