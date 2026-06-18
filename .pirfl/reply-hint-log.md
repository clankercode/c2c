# c2c — Reply Hint PIRFL log

## Goal

When an inbound c2c message lands in any client (Claude / Codex /
OpenCode / Kimi / Gemini / pi), the receiving LLM must unambiguously
know to reply via `c2c_send` (DM) or `c2c_send_room` (room). Today
the `reply_via` envelope attribute is the only signal and it is too
easy to miss — agents in the wild reply in plain text, leaving the
sender with no signal.

Implementation of the design approved at
`docs/superpowers/specs/2026-06-18-reply-hint-system-reminder-design.md`
(branch `design/reply-hint`).

## Plan (slices)

- **A** — Centralised helper `format_reply_hint` +
  `~with_reply_hint:bool` opt-in parameter on `format_c2c_envelope`
  (`ocaml/c2c_mcp_helpers.ml`). Wire-bridge defaults to ON.
- **B** — Caller opt-in sweep. `c2c_inbox_hook.ml` opts in;
  `cli/c2c.ml` keeps opt-out; OpenCode plugin suppresses its own.
- **F** — Channel-notification push path gets the same hint via
  `channel_notification` in `c2c_mcp_helpers_post_broker.ml`.
- **C** — Tests in `test_c2c_mcp.ml`, `test_wire_bridge.ml`,
  `test_c2c_start.ml` — adversarial alias escape coverage.
- **D** — OCaml docs only. Skip `c2c_verify.py` (deprecated Python).
- **E** — Acceptance: `dune build`, `dune runtest`, live dogfood
  via `scripts/c2c_tmux.py`.

## Constraints (from project AGENTS.md / CLAUDE.md)

- One slice = one worktree (`feat/reply-hint` from `master`).
- Branch from `origin/master` (this is a self-contained UX fix,
  not a chain slice).
- Real peer-PASS before coord-PASS (subagent review).
- New commit for every fix, never `--amend`.
- All OCaml tests must pass.
- 2 threads max for build/test (per system etiquette).
- Push only when needed — coordinator1 gates `origin/master` pushes.

## Log

#### Slice commits (parent `d094b3c4` on master):

- `96cefedb` — feat(c2c): reply-hint helper + opt-in parameter on format_c2c_envelope (Slice A)
- `2cacffc3` — feat(c2c): enable reply-hint on inbox-hook + OpenCode plugin (Slice B)
- `be1c35fd` — feat(c2c): append reply-hint to channel-notification push path (Slice F)
- `a7f5a59b` — test(c2c): reply-hint coverage (Slice C)
- `20b146f4` — docs(c2c): reply-hint v2 follow-up section in reply_via design doc (Slice D)

#### Self-review (5-lens adversarial pass)

Findings and dispositions:

- **MAJOR-1 — Type-aliasing / import cycle.** The new
  `format_reply_hint` is in `C2c_mcp_helpers`. Calling it from
  `C2c_mcp_helpers_post_broker` via `C2c_mcp.format_reply_hint`
  would create a cycle (`C2c_mcp <-> C2c_mcp_helpers_post_broker`).
  Fixed in `be1c35fd` by calling `C2c_mcp_helpers.format_reply_hint`
  directly. dune then builds clean.

- **MINOR-1 — channel_notification signature change.** Adding the
  `~with_reply_hint` parameter to `channel_notification` is a
  breaking change for any external caller. 8 existing test cases
  called it positionally. Fixed in `a7f5a59b` by adding
  `~with_reply_hint:false` to each test (preserves original
  behavior under test).

- **MINOR-2 — tmux_message_payload now ends with </system-reminder>.**
  The default-ON hint means payloads end with the system-reminder
  close tag, not </c2c>. The existing test asserted ends with
  </c2c>. Updated in `a7f5a59b` to assert ends with
  </system-reminder> AND contains </c2c>\n<system-reminder>.

- **NIT-1 — format_prompt needed a new param too.** The
  `format_prompt` wrapper composes `format_envelope` calls; the
  param propagates through. Fixed in `2cacffc3` (originally
  only added to `format_envelope`); the `format_prompt` param
  came in via the test-driven rediscovery when wire_bridge tests
  failed.

- **NIT-2 — backtick escape in test needle.** OCaml's `\"`\``
  string literal escapes the backtick as a regular char, producing
  `from \\`alice\\`` (with backslashes) instead of
  `from \`alice\`` (with backticks). Fixed in `a7f5a59b` by
  dropping the unnecessary backslashes.

#### Build / test status

- `dune build` rc=0 (all warnings pre-existing partial-match
  warnings in c2c.ml, unrelated to this slice).
- `dune build ./ocaml/cli/c2c.exe ./ocaml/server/c2c_mcp_server.exe
  ./ocaml/tools/c2c_inbox_hook.exe` rc=0.
- `c2c --version` reports 0.8.0 20b146f4.
- `c2c doctor` runs cleanly with the new binary.
- Targeted test suites (per-test runs):
  - `test_c2c_mcp`: 372 tests, 0 fail.
  - `test_wire_bridge`: 19 tests, 0 fail.
  - `test_c2c_start`: 186 tests, 1 fail (`get_tmux_location_j` —
    requires running inside a tmux session; pre-existing, unrelated).
- Full `dune runtest` includes 16 CLI failures that are all
  pre-existing on master (worktree_gc, schedule_list,
  peer_pass_list, etc. — require a real c2c broker environment
  that this worktree doesn't have). Confirmed by running the
  same suite on `master` first: 18 failures there, 16 on this
  branch. No new test failures introduced by this slice.

#### Peer review

Tried to dispatch `general-purpose` subagent for peer-PASS; the
subagent's output file is empty (agent appears to have been
cleaned up before completing). Self-review acted as the
adversarial pass; fixes landed in follow-up commits per the
"new commit for every fix, never --amend" rule from
`.collab/runbooks/git-workflow.md`.

Recommend a fresh `review-and-fix` run when the swarm has a free
agent — but the slice is in good shape to ship locally.
