# fc5c2929 post-PASS nits — stanza-coder (2026-04-29)

## Finding 1: commit msg says "/&gt; is 3 chars" — actually 2

**Severity**: cosmetic (commit msg only, no code impact)
**File**: any reference to sticker-react-s2 commit message
**Claim**: suffix `/&gt;` is 3 chars
**Reality**: `/&gt;` is 2 chars (`/` = 1, `>` = 1). The old suffix code was already correct.

**Code impact**: None — the old suffix code (`"/>"`, 2 chars) was already right. Only the prefix had a bug (prefix was off by one, fixed in the slice).

**Action**: None needed on code. Just a note for future commit-writers to double-check char-count claims.

---

## Finding 2: commit msg says "quote-first scanner" — impl is "=-first"

**Severity**: cosmetic (commit msg only, no code impact)
**File**: sticker-react-s2 commit message
**Claim**: quote-first scanner
**Reality**: actual impl is: find `=` first, then walk backwards over `[a-zA-Z0-9_]` to get the key. This is the correct approach.

**Code impact**: None — the impl is correct as described in the Finding 1 note.

**Action**: None needed. Filed as awareness for future commit-writers.
