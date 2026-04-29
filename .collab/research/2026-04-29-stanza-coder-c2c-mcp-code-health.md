# c2c_mcp.ml code-health audit — 2026-04-29

stanza-coder. File: `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml` (6466 LOC).
Read-only audit; no code modified.

## Top recommendations (ranked by leverage)

### 1. Split the `handle_tool_call` mega-dispatch (4474–6280, ~1800 LOC)

`handle_tool_call` is one `match tool_name with ...` chain with 35+ arms.
Top per-handler LOC:

- `send` 239 LOC (4728–4967)
- `register` 211 LOC (4476–4687)
- `debug` 131 LOC (5037–5168)
- `memory_list` 119 LOC (5968–6087)
- `memory_read` 109 LOC (6088–6197)
- `poll_inbox` 87 LOC (5169–5256)
- `tail_log` 47, `sweep` 40, `room_history` 54, `list_rooms` 56...

Recommendation: extract each arm into a `handle_<tool>` function,
keep dispatch as a thin name→fun lookup. Group by topic into a few
sub-modules: `Mcp_handlers_send`, `_rooms`, `_memory`, `_admin`,
`_session`. Reviewing a 200-line `send` patch in isolation is a lot
easier than scrolling past 400 unrelated LOC.

Effort: **6–10 h** total, can be sliced (one handler per worktree).
First slice — extract the 3 memory handlers (~340 LOC) — is a great
1.5–2 h win because they share helpers (#2 below). Each extraction
is mechanical; risk is mostly capture of free vars (`broker`,
`session_id_override`).

### 2. Deduplicate `memory_base_dir` + `entry_path` across the 3 memory handlers (5969–5993, 6089–6113, 6199–6223)

Both helpers are textually identical, defined three times — ~25 LOC
each, ~75 LOC of pure duplication. Lift to top-level
`Memory_helpers` (or just `let memory_base_dir alias = ...` near line
~3700 with the other helpers). The first definition at 5984 is even
flagged unused (warning 26 `entry_path`) because it's shadowed by the
later `entry_path` defined inside `parse_frontmatter`'s scope —
reading it I found there's no actual call site in `memory_list` for
the 5984 copy.

Effort: **45 min**. Extract once, delete two copies, run
`just test-one -k memory`.

### 3. `with_resolved_session` helper — kill the 14× boilerplate

`resolve_session_id ?session_id_override arguments` appears 14 times,
`Broker.touch_session broker ~session_id` 14 times — almost always
paired (4477, 5021, 5181, 5438, 5466, 5498/5499, 5537/5538,
5607/5608, 5772/5773, 5806/5807, 5834/5835, 5869...). The triple
nested-match pattern at line 4354 / 5002 / 5925 (current_session_id
fallback) repeats too.

Proposed helper near line 4350:

```
let with_session ?session_id_override broker arguments f =
  let session_id = resolve_session_id ?session_id_override arguments in
  Broker.touch_session broker ~session_id;
  f ~session_id
```

Plus an Lwt-aware variant for the handlers that return `Lwt.t`. This
also makes "session-required vs session-optional" handlers
syntactically obvious (they call `with_session` vs not), which
addresses an entire class of "forgot to touch_session" bugs.

Effort: **2–3 h** including audit+rewrite of all 14 sites.

### 4. `tool_ok` / `tool_err` smart constructors

50 raw `tool_result ~content:... ~is_error:...` call sites (35
ok, 15 err). The `tool_result` definition is at line 290.
Add:

```
let tool_ok content   = tool_result ~content ~is_error:false
let tool_err content  = tool_result ~content ~is_error:true
let tool_ok_json j    = tool_ok (Yojson.Safe.to_string j)
```

Bonus: the existing `missing_sender_alias_result` /
`missing_member_alias_result` (4370–4386) become two-liners.
Reading `Lwt.return (tool_err "register rejected: ...")` is much
faster than parsing the labelled-arg form. **Negligible perf cost
(inlinable), high readability win.**

Effort: **1.5 h** including replace_all + check.

### 5. Magic numbers → named constants (top of file)

Spotted:

- `600.0` permission TTL fallback (5845, 5846) — `default_permission_ttl_s`
- `300.0` docker lease TTL (1048) — already named, good ✓
- `300.0` compacting stale-after (1461) — already named ✓
- `3600.0` `pidless_keep_window_s` (1306) — named ✓
- `1800` provisional expire mentioned at 1300 in comment — verify it's
  named where used
- `4096` Buffer.create (957, 5343, plus more) — named `default_buf_cap`
- File modes `0o600` / `0o644` / `0o755` are pervasive (~30
  sites). Already centralised semantically (archives → 0o600,
  locks → 0o644, dirs → 0o755). Leave them; renaming buys nothing.

Real wins are only `default_permission_ttl_s` and the two `4096`
buffer sizes. Effort: **20 min**. *Most "magic numbers" here are
already named or are well-understood Unix mode bits — don't over-extract.*

### 6. Pre-existing build warnings — investigate

Actual warnings observed via `touch ocaml/c2c_mcp.ml && dune build`
(stated line numbers in the prompt drift; file is 6466 LOC):

- **`c2c_mcp.ml:873` warning 26** `unused-var id` —
  `Relay_identity.load_or_create_at` is called for its **side effect**
  (creates SSH key files on disk); the returned id is never used.
  Benign, but should be `let _ = ...` or `ignore (...)` to make the
  intent explicit. **5 min.**

- **`c2c_mcp.ml:5984` warning 26** `unused-var entry_path` — confirms
  finding #2: the first of the three duplicated copies is dead.
  Resolved by deduplication. **0 min (subsumed by #2).**

- **`c2c_mcp.ml:3633–3673` warning 8 `partial-match` + 3672 warning
  11 `redundant-case`** (`decrypt_message_for_push`). Duplicated at
  5203–5247 (poll_inbox inline decrypt). Outer match on `env.enc`
  with `"plain" | "box-x25519-v1" | _` — exhaustive at runtime, but
  the type system thinks `""` is uncovered. The inner `| _ -> content`
  (3672) is "redundant" because earlier arms already return `content`
  on every fallback. **Benign**, but the right fix is #7 below
  (collapse both blocks into one helper).

- **`c2c_mcp.ml:4474` warning 16** `unerasable-optional-argument`
  on `?session_id_override`. Low value; leave it, ergonomic call
  sites cost nothing.

### 7. Two near-identical decrypt blocks (3619–3675 and 5183–5247) — DRY

Lines 3619–3675 (`decrypt_message_for_push`, ~57 LOC) and 5183–5247
(inline inside `poll_inbox`, ~65 LOC) implement the same
plain/box-x25519-v1 decrypt+verify+pin flow. The only difference is
the return shape (`content` vs `content * enc_status option`). Lift
to one helper that returns the tuple; the push site can throw away
the status. Bug-fix surface today: any envelope-format change must
be edited twice.

Effort: **1.5–2 h**. Highest *correctness* leverage of the list.

## Leave-it-alone notes

- The `tool_definitions` block (3712–3865) is long (~150 LOC) but
  it's a flat declarative schema list — splitting it just spreads
  the canonical "what tools exist" answer across files. **Keep as-is.**
- `auto_register_impl` (4139–4279, 140 LOC) and
  `managed_session_id_from_codex_thread` (4020–4069) read linearly;
  splitting buys little.
- Unix file modes (0o600/0o644/0o755) — well understood, don't
  bikeshed into named constants.
- The 22 distinct `tool_result ~content ... ~is_error:true/false`
  formulations actually carry meaningful per-call detail (printf
  templates etc.); only the constructor noise should be removed
  (#4), not the messages themselves.

## Summary table

| # | Win | Effort | Risk | Type |
|---|-----|--------|------|------|
| 1 | Split mega-dispatch | 6–10 h | low (mechanical) | reviewability |
| 2 | Dedup memory helpers | 0.75 h | very low | DRY + warning fix |
| 3 | `with_session` helper | 2–3 h | low | readability + bugproofing |
| 4 | `tool_ok`/`tool_err` ctors | 1.5 h | trivial | readability |
| 5 | Named constants | 0.3 h | trivial | clarity |
| 6 | Warnings (unused id, partial-match) | 0.1 + 1.5 h | low | hygiene |
| 7 | Unify two decrypt blocks | 1.5–2 h | medium (crypto path) | correctness |

Suggested **first slice** for a single coder session:
**#2 + #4 + #5 + #6 unused-var fix** → ~3.5 h, ~150 LOC delta,
clears 2 warnings, no behaviour change. Lands a clean baseline
before tackling #1 / #7.

— stanza-coder, 2026-04-29
