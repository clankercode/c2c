#!/usr/bin/env python3
"""Tests for c2c_pts_inject.py — direct PTS write helper."""
from __future__ import annotations

import os
import unittest
from unittest import mock

import c2c_pts_inject


class C2CPTSInjectUnitTests(unittest.TestCase):
    def test_inject_writes_bulk_text_and_crlf(self):
        with (
            mock.patch("os.open", return_value=7) as mock_open,
            mock.patch("os.write") as mock_write,
            mock.patch("os.close") as mock_close,
        ):
            c2c_pts_inject.inject("0", "hello world")

        mock_open.assert_called_once_with("/dev/pts/0", os.O_WRONLY | os.O_NOCTTY)
        mock_write.assert_has_calls([
            mock.call(7, b"hello world"),
            mock.call(7, b"\r\n"),
        ])
        mock_close.assert_called_once_with(7)

    def test_inject_character_delay_writes_one_char_at_a_time(self):
        with (
            mock.patch("os.open", return_value=7) as mock_open,
            mock.patch("os.write") as mock_write,
            mock.patch("os.close") as mock_close,
            mock.patch("time.sleep") as mock_sleep,
        ):
            c2c_pts_inject.inject("5", "ab", char_delay=0.001)

        mock_open.assert_called_once_with("/dev/pts/5", os.O_WRONLY | os.O_NOCTTY)
        mock_write.assert_has_calls([
            mock.call(7, b"a"),
            mock.call(7, b"b"),
            mock.call(7, b"\r\n"),
        ])
        self.assertEqual(mock_sleep.call_count, 2)
        mock_close.assert_called_once_with(7)

    def test_inject_no_crlf_omits_trailing_newline(self):
        with (
            mock.patch("os.open", return_value=7),
            mock.patch("os.write") as mock_write,
            mock.patch("os.close"),
        ):
            c2c_pts_inject.inject("0", "plain", crlf=False)

        mock_write.assert_called_once_with(7, b"plain")

    def test_inject_missing_pts_raises(self):
        with (
            mock.patch("pathlib.Path.exists", return_value=False),
            self.assertRaises(RuntimeError) as ctx,
        ):
            c2c_pts_inject.inject("99", "test")
        self.assertIn("PTS device does not exist", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
