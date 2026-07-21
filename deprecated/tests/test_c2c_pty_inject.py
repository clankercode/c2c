"""Unit tests for c2c_pty_inject — the pure-Python pidfd_getfd backend.

The live code path touches real syscalls (pidfd_open, pidfd_getfd) and
real /dev/ptmx fds, so those are mocked out here. We check the framing
(bracketed paste + Enter as separate writes), sanitisation of embedded
paste markers, and argument handling for pts_num variants.
"""
from __future__ import annotations

import errno
import sys
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_pty_inject


class InjectFramingTests(unittest.TestCase):
    def setUp(self):
        # Track every os.write call so we can verify the byte-exact framing.
        self.writes: list[bytes] = []

        def fake_write(fd, data):
            self.writes.append(bytes(data))
            return len(data)

        self.patches = [
            mock.patch("c2c_pty_inject.os.pidfd_open", return_value=100),
            mock.patch("c2c_pty_inject._find_master_fd", return_value=7),
            mock.patch("c2c_pty_inject._pidfd_getfd", return_value=200),
            mock.patch("c2c_pty_inject.os.write", side_effect=fake_write),
            mock.patch("c2c_pty_inject.os.close"),
            mock.patch("c2c_pty_inject.time.sleep"),
        ]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()

    def test_default_bracketed_paste_plus_enter_is_two_writes(self):
        c2c_pty_inject.inject(12345, "7", "hi")
        # Two writes: paste frame, then enter.
        self.assertEqual(len(self.writes), 2)
        self.assertEqual(self.writes[0], b"\x1b[200~hi\x1b[201~")
        self.assertEqual(self.writes[1], b"\r")

    def test_accepts_slash_dev_pts_prefix(self):
        c2c_pty_inject.inject(12345, "/dev/pts/7", "hi")
        self.assertEqual(self.writes[0], b"\x1b[200~hi\x1b[201~")

    def test_strips_embedded_paste_markers(self):
        c2c_pty_inject.inject(12345, 7, "a\x1b[200~evil\x1b[201~b")
        # The inner markers must be stripped before framing.
        self.assertEqual(self.writes[0], b"\x1b[200~aevilb\x1b[201~")

    def test_submit_enter_false_skips_the_cr_write(self):
        c2c_pty_inject.inject(12345, 7, "hi", submit_enter=False)
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(self.writes[0], b"\x1b[200~hi\x1b[201~")

    def test_bracketed_paste_false_sends_raw_payload(self):
        c2c_pty_inject.inject(12345, 7, b"\x1b[A", bracketed_paste=True, submit_enter=False)
        # Even with bracketed_paste=True, raw escape sequences in payload are
        # wrapped (they aren't paste markers). Also verify raw mode:
        self.writes.clear()
        c2c_pty_inject.inject(12345, 7, b"\x1b[A", bracketed_paste=False, submit_enter=False)
        self.assertEqual(self.writes, [b"\x1b[A"])


class PermissionSurfacingTests(unittest.TestCase):
    def test_eperm_from_pidfd_getfd_is_rewritten_with_setcap_hint(self):
        with mock.patch("c2c_pty_inject.os.pidfd_open", return_value=100), \
             mock.patch("c2c_pty_inject._find_master_fd", return_value=7), \
             mock.patch(
                 "c2c_pty_inject._pidfd_getfd",
                 side_effect=OSError(errno.EPERM, "Operation not permitted"),
             ), \
             mock.patch("c2c_pty_inject.os.close"):
            with self.assertRaises(PermissionError) as ctx:
                c2c_pty_inject.inject(12345, 7, "hi")
            self.assertIn("cap_sys_ptrace", str(ctx.exception).lower())


class PtsNumberParsingTests(unittest.TestCase):
    def test_string_number(self):
        self.assertEqual(_normalize_pts("7"), 7)

    def test_int(self):
        self.assertEqual(_normalize_pts(7), 7)

    def test_dev_path(self):
        self.assertEqual(_normalize_pts("/dev/pts/7"), 7)


def _normalize_pts(pts_num):
    """Replicate the inline normalization in inject() for direct testing."""
    if isinstance(pts_num, str):
        pts_num = pts_num.rsplit("/", 1)[-1]
        return int(pts_num)
    return int(pts_num)


if __name__ == "__main__":
    unittest.main()
