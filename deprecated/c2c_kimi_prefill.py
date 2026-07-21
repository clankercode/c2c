#!/usr/bin/env python3
"""Run Kimi shell with `--prompt` as editable prefill text.

Kimi's public `--prompt` option runs a single command and exits. The shell UI
has an internal prefill path, so managed interactive launchers use this small
shim to preserve the normal shell while still showing the configured prompt in
the first input buffer.
"""
from __future__ import annotations

from kimi_cli.app import KimiCLI
from kimi_cli.__main__ import main


_original_run_shell = KimiCLI.run_shell


async def _run_shell_with_prompt_prefill(
    self: KimiCLI, command: str | None = None, *, prefill_text: str | None = None
) -> bool:
    if command is not None:
        return await _original_run_shell(self, None, prefill_text=command)
    return await _original_run_shell(self, None, prefill_text=prefill_text)


def run() -> int | str | None:
    KimiCLI.run_shell = _run_shell_with_prompt_prefill
    return main()


if __name__ == "__main__":
    raise SystemExit(run())
