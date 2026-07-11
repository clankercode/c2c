#!/usr/bin/env python3
"""Offline TEETH-TEST for the T004 harness assertion helpers.

A draft-preservation proof is worthless if its checks pass regardless of the real
draft/cursor state. This test proves the opposite: the byte-exact-draft compare
(`assert_draft_preserved`), the empty-composer check (`assert_empty_preserved`),
the bottom-most-`›` `composer_block` selection, and the relative-cursor
derivation all FAIL when they must and PASS only when the draft+cursor are truly
preserved. No codex, no tmux, no network, no quota — pure logic over synthetic
terminal snapshots. Run: `python3 scripts/test-draft-preservation-assertions.py`
(exit 0 iff every teeth-case holds)."""
import importlib.util
import sys
import tempfile
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "t004h", Path(__file__).resolve().parent / "codex-draft-preservation-e2e.py")
_m = importlib.util.module_from_spec(_spec)
sys.modules["t004h"] = _m
_spec.loader.exec_module(_m)
H = _m.DraftPreservationHarness

FAILS: list[str] = []


def expect(name: str, cond: bool):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        FAILS.append(name)


def snap(frame: str, cursor: tuple[int, int]) -> dict:
    start, region = H.composer_block(frame)
    rel = (cursor[0], (cursor[1] - start) if start is not None else None)
    return {"tag": "t", "frame": frame, "cursor": cursor, "composer": region,
            "composer_start": start, "rel_cursor": rel, "path": ""}


# A bare harness instance (bypass __init__ — no port/broker/tmux needed).
h = H.__new__(H)
h.run_dir = Path(tempfile.mkdtemp(prefix="t004-teeth-"))
h.results = []
h._snap_n = 0


def run_assert(fn, name, before, after) -> bool:
    """Call an assertion helper and return its recorded ok flag."""
    n0 = len(h.results)
    fn(name, before, after)
    return h.results[n0][1]


# ---- fixtures -------------------------------------------------------------
# A frame whose BOTTOM composer holds a 2-line draft, with a transcript echo of a
# previously-submitted message ALSO starting with '›' higher up (the exact trap
# composer_block must avoid).
def draft_frame(l1, l2, *, chrome_pad=0):
    top = ["  Tip: rotating chrome"] + [""] * chrome_pad
    transcript = ["› a previously submitted message", "  (in the transcript)", ""]
    composer = [f"› {l1}", f"  {l2}", "", "  · Context 0% used ·"]
    return "\n".join(top + transcript + composer)


DL1 = "café ☕ 日本語 DRAFT_MARKER_QZX"
DL2 = "second líne ✓ 🚀 do_not_lose_me"

# locate the composer's '›' row so we can place a realistic cursor on line 2
_frame = draft_frame(DL1, DL2)
_cstart, _ = H.composer_block(_frame)
CUR_L2 = (23, _cstart + 1)   # cursor mid-way along composer line 2

# ---- 1. composer_block selects the BOTTOM-most '›' (never the transcript echo)
start, region = H.composer_block(_frame)
expect("composer_block picks bottom composer (not transcript echo)",
       region == [f"› {DL1}", f"  {DL2}"])

# ---- 2. draft preserved: identical composer + rel-cursor => PASS
before = snap(_frame, CUR_L2)
after_same = snap(_frame, CUR_L2)
expect("draft_preserved PASSES when composer+cursor identical",
       run_assert(h.assert_draft_preserved, "same", before, after_same) is True)

# ---- 3. TEETH: one changed byte in the draft => FAIL
after_1byte = snap(draft_frame(DL1, DL2.replace("do_not_lose_me", "do_not_lose_mE")), CUR_L2)
expect("draft_preserved FAILS on a single changed draft byte",
       run_assert(h.assert_draft_preserved, "onebyte", before, after_1byte) is False)

# ---- 4. TEETH: a dropped multibyte char in the draft => FAIL
after_drop = snap(draft_frame(DL1.replace("日本語", "日本"), DL2), CUR_L2)
expect("draft_preserved FAILS on a dropped multibyte char",
       run_assert(h.assert_draft_preserved, "dropmb", before, after_drop) is False)

# ---- 5. TEETH: cursor moved within the composer (draft text identical) => FAIL
after_curmove = snap(_frame, (24, _cstart + 1))
expect("draft_preserved FAILS when the cursor moves within the composer",
       run_assert(h.assert_draft_preserved, "curmove", before, after_curmove) is False)

# ---- 6. chrome shift is TOLERATED but rel-cursor still tracks the real position:
#         pad chrome above so the whole composer shifts DOWN by 1 absolute row;
#         cursor absolute row shifts +1 too; composer bytes + rel-cursor unchanged.
shifted_frame = draft_frame(DL1, DL2, chrome_pad=1)
sh_start, _ = H.composer_block(shifted_frame)
after_shift = snap(shifted_frame, (23, sh_start + 1))
expect("draft_preserved PASSES under pure chrome shift (abs row moves, rel stable)",
       run_assert(h.assert_draft_preserved, "shift", before, after_shift) is True
       and before["cursor"] != after_shift["cursor"]           # absolute DID move
       and before["rel_cursor"] == after_shift["rel_cursor"])  # relative did NOT

# ---- 7. TEETH: chrome shift that ALSO moves the draft cursor within the line
#         (abs row +1 AND col changes) must still FAIL — rel-cursor is not fooled.
after_shift_move = snap(shifted_frame, (25, sh_start + 1))
expect("draft_preserved FAILS when chrome shift masks a real cursor move",
       run_assert(h.assert_draft_preserved, "shiftmove", before, after_shift_move) is False)

# ---- empty-composer checks -------------------------------------------------
def empty_frame(*, chrome_pad=0):
    top = ["  Tip: rotating chrome"] + [""] * chrome_pad
    transcript = ["› a previously submitted message", "  (transcript)", ""]
    composer = ["› Explain this codebase", "", "  · Context 0% used ·"]  # placeholder only
    return "\n".join(top + transcript + composer)


ef = empty_frame()
e_start, _ = H.composer_block(ef)
empty_before = snap(ef, (2, e_start))          # cursor at prompt start
# an UNCHANGED empty composer (captured settled) => PASS
empty_after_ok = snap(empty_frame(), (2, H.composer_block(empty_frame())[0]))
expect("empty_preserved PASSES when the empty composer is unchanged",
       run_assert(h.assert_empty_preserved, "empty-ok", empty_before, empty_after_ok) is True)

# the byte-exact empty check is deliberately CONSERVATIVE: if the rotating
# placeholder changed mid-window it FAILS-SAFE (never a false pass). Prove it
# does not silently accept a differing composer region.
ef_rot = empty_frame().replace("Explain this codebase", "Write tests for @filename")
empty_after_rot = snap(ef_rot, (2, H.composer_block(ef_rot)[0]))
expect("empty_preserved FAILS-SAFE on any composer-region change (no false pass)",
       run_assert(h.assert_empty_preserved, "empty-rot", empty_before, empty_after_rot) is False)

# ---- 8. TEETH: text inserted into the empty composer => FAIL
typed = empty_frame().replace("› Explain this codebase", "› injected text HERE")
typed_start = H.composer_block(typed)[0]
empty_after_typed = snap(typed, (18, typed_start))   # cursor advanced past inserted text
expect("empty_preserved FAILS when text is inserted into the composer",
       run_assert(h.assert_empty_preserved, "empty-typed", empty_before, empty_after_typed) is False)

# ---- 9. TEETH: a second composer line appears (multi-line insert) => FAIL
twoline = "\n".join(["  Tip", "› first inserted line", "  second inserted line", "",
                     "  · Context 0% used ·"])
tl_start = H.composer_block(twoline)[0]
empty_after_2l = snap(twoline, (2, tl_start))
expect("empty_preserved FAILS when a second composer line appears",
       run_assert(h.assert_empty_preserved, "empty-2line", empty_before, empty_after_2l) is False)

# ---------------------------------------------------------------------------
print(f"\n{len(FAILS)} teeth-case failure(s)" if FAILS else
      "\nALL TEETH-CASES HOLD — the draft/cursor checks fail exactly when the draft "
      "or cursor differs, and pass only when both are truly preserved.")
sys.exit(1 if FAILS else 0)
