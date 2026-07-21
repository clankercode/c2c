"""Path shim for retired legacy-Python tests.

These tests were moved out of ``tests/`` during the OCaml migration (the root
``c2c_*.py`` product surface is now deprecated; the ``c2c`` OCaml binary is
canonical). They are intentionally **not** part of the default ``pytest tests/``
run.

The legacy modules they import now live one directory up (``deprecated/``); this
shim puts that directory and the repo root on ``sys.path`` so the imports still
resolve if you run these tests directly (``pytest deprecated/tests/``).

Caveat: a handful of these tests use fixtures/options defined in the live
``tests/conftest.py`` (``scenario``, ``spawn_tracked``, ``--force-test-env``).
Those are not auto-wired here — copy ``tests/conftest.py`` alongside, or add the
live ``tests/`` dir as a rootdir, if you resurrect them.
"""

import pathlib
import sys

_repo = pathlib.Path(__file__).resolve().parents[2]
for _p in (str(_repo), str(_repo / "deprecated")):
    if _p not in sys.path:
        sys.path.insert(0, _p)
