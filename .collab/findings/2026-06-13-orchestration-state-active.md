# Orchestration state — ACTIVE — c2c watch TUI build (resume after compaction)

Local/gitignored (`.collab/findings/` is gitignored here). Orchestrator = main
Claude session, Max-driven, **Ultracode ON**. Updated 2026-06-14 (B0 done, B1 in flight).

## ✅ COMPLETE (2026-06-15) — all of B0→B5 + e2e + final review DONE, merged to LOCAL master.
master is at `313543a4` (fast-forward, 11 commits ahead of origin/master). Every slice
Codex peer-PASSed individually; e2e (OCaml round-trip DM→inbox + room→history, +tmux smoke
`just watch-e2e`) added; final whole-feature Codex review PASS after fixing a real
wide-Unicode exact-width bug (disp_width now uses Uucp.Break.tty_width_hint — no new dep;
+wrap_content hang fix) and stale help text. Tests: render 19, state 17, data 13, e2e 5.
NOT pushed — flagged to Max (lambda-term enlarges Railway closure; c2c watch is a local
Tier3 operator tool, no deploy reason). Worktree `.worktrees/wt-c2c-watch` still present
(no scratch) — safe to `git worktree remove` once Max confirms.

## MISSION: build `c2c watch` TUI, slices B0→B5, in ONE worktree
Max greenlit the full build ("complete B0 and B1 ... B5"). Spec:
`.collab/design/2026-06-13-c2c-watch/{00-README,01-c2c-watch-spec}.md`.

- **Worktree:** `/home/xertrov/src/c2c/.worktrees/wt-c2c-watch`, branch `feat/c2c-watch`
  (off master @245dcaae). All slices are sequential commits on this ONE branch.
- **Merge plan:** accumulate B0–B5 on `feat/c2c-watch`; merge the WHOLE branch to
  local master at the END with `C2C_COORDINATOR=1` (main-tree commit is shim-guarded).
  **Do NOT push** — local-only operator tool + lambda-term enlarges the Railway/Pages
  opam closure → coordinator-gated. Flag the push decision to Max at the end.

## SLICE STATUS
- **B0 ✅ DONE + peer-PASSed** @ `56afa863` (parent `270107dc`). lambda-term dep +
  `c2c watch` registered (Tier3) + raw-mode skeleton + bulletproof teardown +
  golden test. Review chain caught 3 real teardown defects (missing rmcup ESC[?1049l
  on sync path; 2 signal-race windows: handlers installed too late / finalizer
  restored handlers before terminal). All fixed. Codex independent verdict PASS
  (`/tmp/b0-codex-verdict2.txt`). Build rc=0, golden 2/2.
- **B1 ✅ DONE + peer-PASSed** @ `603c1c28` (parent `56afa863`). Data layer
  `c2c_watch_data.ml` + `test_c2c_watch_data.ml` (7 tests). build_snapshot over Broker
  reads, #room filter (`String.contains to_alias '#'`), orphan union (registry ∪
  archive/*.jsonl ∪ *.inbox.json stems), liveness passthrough, empty-room default,
  ds_inflight (undrained inbox). Workflow `wae6nxi9o` 3 lenses ALL refuted:false. Nits
  folded: vacuous list-string assertion → real rv_history projection; read_limit=1000
  documented as v1 cap for B3. Independent rebuild rc=0, test 7/7 rc=0. Codex PASS
  (`/tmp/b1-codex-verdict.txt`).
  Types (for B2-B5 render): peer_row {pr_alias; pr_session_id; pr_liveness; pr_role;
  pr_last_activity; pr_dnd; pr_compacting; pr_client_type}. dm_shard {ds_session_id;
  ds_owner_alias(None=orphan); ds_entries; ds_inflight; ds_is_orphan}. room_view
  {rv_info; rv_history}. snapshot {peers; shards; rooms; broker_root}.
  `C2c_watch_data.build_snapshot : Broker.t -> snapshot`. NOTE room_message is TOP-LEVEL
  `C2c_mcp.room_message` (NOT Broker-scoped).
- **B2 ✅ DONE + peer-PASSed** @ `ba08cd7c` (feature `db4f75ff` + fix `ba08cd7c`, parent
  `603c1c28`). Peers tab: c2c_watch_state.ml (pure state machine + clamp_counts) + grew
  c2c_watch_render.ml (pure `render`, `cell` separator helper, narrow-term title guard) +
  wired snapshot/render/poll-loop/`--interval` into c2c_watch.ml. Workflow `wpb2famz4`
  3 lenses all refuted:false; **but Codex peer-review FAILed db4f75ff with 3 REAL bugs my
  lenses missed** → fixed in ba08cd7c, Codex re-review PASS (`/tmp/b2-codex-verdict2.txt`).
  Build rc=0, render 5/5, state 11/11. Live tmux QA (tui-snapshot.sh): roster renders
  against live broker, nav/refresh/clean-teardown all verified; QA also caught a
  column-separator bug (fixed).
  **LESSON for B3+ verify lenses (3 bugs the lenses missed):** (1) process-derived state
  (liveness) goes STALE under mtime-gating — a verify lens must ask "is freshness of
  /proc-derived state preserved by the refresh model?" not just "is mtime-gating present";
  (2) invariants must hold under DATA changes not just key EVENTS — selection clamp must be
  data-driven (clamp after every snapshot rebuild), not only event-driven; (3) exact-width/
  degenerate-size contracts need NARROW-terminal tests (cols 8/20/40), not just 80×24.
  Bake these into B3/B4/B5 lens prompts. Codex (different model) earns its keep — peer-PASS
  ≠ self-review/subagent-review.
- **B2 (historical in-flight note)** — Workflow task `wpb2famz4` (runId `wf_a46816e9-119`, scriptPath
  `/home/xertrov/.claude-w/projects/-home-xertrov-src-c2c--worktrees-wt-c2c-watch/574c00d6-a4fc-43c8-9656-0a235a3000b6/workflows/scripts/c2c-watch-b2-peers-wf_a46816e9-119.js`).
  Peers tab: NEW c2c_watch_state.ml (pure state machine, event variant, apply ~list_len
  clamp) + grow c2c_watch_render.ml (add pure `render ~cols ~rows ~snapshot ~state`,
  keep render_empty_frame) + wire snapshot+state+render+poll/mtime loop (Lwt.pick) +
  `--interval` into c2c_watch.ml + golden tests (populated + quiet) + state tests.
  Hard constraints enforced in prompt: render pure (refreshed_label from state, no
  clock/env), plain-text (no ANSI), B0 teardown UNREGRESSED, LTerm confined to
  c2c_watch.ml, DMs/Rooms = placeholder (no B3/B4 work), 80×24 goldens utf8-width.
  ON COMPLETION: triage 3 verdicts (render-golden / state-machine / loop-teardown),
  independent rebuild rc + run test_c2c_watch_render + test_c2c_watch_state exes,
  **tmux live QA** (run worktree-built c2c.exe watch in a tmux pane, snapshot, verify
  roster renders + r refresh + q clean teardown — spec §9 "tested in the wild" gate),
  fix blockers (NEW commit), commit B2, Codex peer-PASS (file-write verdict), then B3.
- **B3 ✅ DONE + peer-PASSed** @ `cce264bc` (parent `ba08cd7c`). DMs tab, RENDER-ONLY
  (data/state/loop untouched). Two-pane shard-list + chronological detail, orphan ⚠ +
  derived label, in-flight tail, overflow keeps-newest + "(N older hidden)" entry-count
  marker. Workflow `w2ikugqqb` Lens A+C passed; **Lens B caught an ORDER BLOCKER** (render
  assumed ds_entries oldest-first, but read_archive is newest-first → would've hidden the
  NEWEST msgs on overflow). FIXED pre-commit: List.rev ds_entries for display, fixtures
  rebuilt newest-first, +test_dms_overflow + test_dms_out_of_range_sel. Codex peer-PASS
  (`/tmp/b3-codex-verdict.txt`). Build rc=0, render 9/9, state 11/11. Live tmux QA: DMs
  tab renders 8 real shards (orphan badge, counts, two-pane) + clean teardown.
  **B3 LESSON (reinforces B2): VERIFY data-layer ORDER at the source, never assume.**
  read_archive=newest-first, read_room_history=OLDEST-first (see API facts) — they DIFFER.
- **B3 (historical in-flight note)** — Workflow task `w2ikugqqb` (runId `wf_105bb4a8-7b5`, scriptPath
  `/home/xertrov/.claude-w/projects/-home-xertrov-src-c2c--worktrees-wt-c2c-watch/574c00d6-a4fc-43c8-9656-0a235a3000b6/workflows/scripts/c2c-watch-b3-dms-wf_105bb4a8-7b5.js`).
  DMs tab — **RENDER-ONLY** (B1 dm_shard + B2 dms_sel/clamp already suffice; NO state/
  loop/data change). Two-pane shard-list + detail, orphan ⚠ + derived label (from entry
  to_alias), in-flight tail rows, detail overflow = newest-fit + "(N older hidden)",
  #room already filtered by B1. Goldens: dms_populated + dms_empty + extend
  render_dimensions to populated-DMs at narrow sizes. Verify lenses carry the 3 B2
  lessons. ON COMPLETION: triage 3 verdicts, independent rebuild + run render+state exes,
  tmux live QA (DMs tab against live broker: shard list + detail + orphan + teardown),
  fix blockers (NEW commit), commit B3, Codex peer-PASS (file-write verdict), then B4.
- **B4 ✅ DONE + peer-PASSed** @ `0c4e7154` (parent `cce264bc`). Rooms tab, RENDER-ONLY
  (reuses B3 dms_split_widths/wrap_content/dms_detail_clip). Two-pane room-list + canonical
  history, member tristate (A●/D○/U?), pub/inv, empty="(no history)". rv_history is
  OLDEST-FIRST → rendered AS-IS (NO List.rev — opposite of B3, applied correctly). Workflow
  `wf_2584e01c-371` (resumed after org-limit hit the verify lenses) 3 lenses refuted:false;
  Codex peer-PASS (no findings). Build rc=0, render 15/15, state 11/11. Live tmux QA: Rooms
  tab renders real swarm-lounge (tristate + "(no history)") + clean teardown.
- **B5 🔄 IN FLIGHT** — Workflow task `ws4fz0pe5` (runId `wf_6de1e997-420`, scriptPath
  `/home/xertrov/.claude-p/projects/-home-xertrov-src-c2c--worktrees-wt-c2c-watch/574c00d6-a4fc-43c8-9656-0a235a3000b6/workflows/scripts/c2c-watch-b5-send-wf_6de1e997-420.js`).
  SEND path — the FINAL + ONLY state-mutating slice. Touches ALL 4 modules: data send
  wrappers (send_dm/send_room_message, NEVER raise, catch Invalid_argument→Send_failed,
  guard self-send), state (compose_target + focus=Input + AppendChar/Backspace + begin/
  cancel_compose), loop (FOCUS-AWARE keys — typing must not nav; Enter=compose/submit;
  --as flag default "operator"), render (compose line + caret + status). Error surface
  (§4.3) is the #1 risk — lenses hammer it. Broker facts verified: enqueue_message/send_room
  signatures, "operator" NOT reserved (valid sender), self-send guard at c2c.ml:504.
  ON COMPLETION: triage 3 verdicts, independent rebuild + run all 3 test exes, **tmux live
  QA = a REAL send to a live peer** (spec §9 gate — verify ✓ sent + recipient got it), fix
  blockers (NEW commit), commit B5, Codex peer-PASS, then MERGE feat/c2c-watch → local
  master (C2C_COORDINATOR=1) and flag the push decision to Max (do NOT push).
- **B4 (historical in-flight note)** — Workflow task `wamb75oul` (runId `wf_2584e01c-371`, scriptPath
  `/home/xertrov/.claude-w/projects/-home-xertrov-src-c2c--worktrees-wt-c2c-watch/574c00d6-a4fc-43c8-9656-0a235a3000b6/workflows/scripts/c2c-watch-b4-rooms-wf_2584e01c-371.js`).
  Rooms tab — RENDER-ONLY (B1 build_rooms + B2 rooms_sel/clamp suffice; reuses B3's
  dms_split_widths/wrap_content/dms_detail_clip). Two-pane room-list + canonical history
  timeline, member tristate (A●/D○/U?), visibility pub/inv, empty room="(no history)".
  **KEY: rv_history is OLDEST-FIRST → render AS-IS, NO List.rev** (opposite of B3's archive;
  the order fact is in the prompt + a dedicated Lens A check). Goldens: rooms_populated +
  rooms_empty + history-order + overflow + out-of-range + dimensions. ON COMPLETION:
  triage 3 verdicts, independent rebuild + run render+state exes, tmux live QA (Rooms tab
  against live broker — swarm-lounge etc.), fix blockers (NEW commit), commit B4, Codex
  peer-PASS, then B5.
- **B5 pending** (#50). Send (--from/--as default 'operator'; in-process enqueue_message/
  send_room; full Invalid_argument/sr_warning error surface; the ONLY state-mutating slice;
  input line + Enter→send; needs state + loop changes — NOT render-only). Then merge
  feat/c2c-watch → local master with C2C_COORDINATOR=1; do NOT push — flag to Max.

## DECISIONS (locked by Max)
- Send identity: `--as <alias>` flag, default reserved `operator` identity.
- DM view: per-shard in v1; merged A↔B conversation view deferred to v2.
- opam pin: exact `lambda-term = 3.4.0`, `zed >= 3.2.0 < 4.0` (in dune-project).
- Goldens 80×24; refresh poll+mtime 1.0s (`--interval`); mosaic = documented Plan-B only.

## BUILD MECHANICS
- In-worktree build: `bash -lc 'eval "$(opam env)"; dune build --root /home/xertrov/src/c2c/.worktrees/wt-c2c-watch -j2'` (switch `c2c`, OCaml 5.4.1; lambda-term 3.4.0 + zed 3.2.3 installed). Limit -j2 (system etiquette).
- Run a slice's golden/unit test cleanly (avoid the aggregate): build the exe, then
  `cd <wt>/ocaml/cli && <wt>/_build/default/ocaml/cli/test_<name>.exe` (the test reads
  cwd-relative fixtures; running from ocaml/cli resolves them).
- **PRE-EXISTING unrelated failure:** `test_c2c_peer_pass` reviewer_is_author / trailer
  email (git 2.54.0 interpret-trailers env) FAILS on this box → pollutes full
  `@ocaml/cli/runtest` rc=1. Do NOT attribute to slices; scope build-clean to the slice's own test.
- lambda-term `META` says version 3.2.0 but opam pkg version is **3.4.0** (cosmetic
  unbumped lib-version string; the `= 3.4.0` pin is valid). Non-issue.

## PEER-PASS = CODEX (independent; workflow verifiers are my subagents, don't count)
Pattern: `cd <wt>; ccc --yolo @cx-reviewer "<bounded prompt>"` FOREGROUND (timeout
600000). **ccc/codex final chat message is NOT captured non-interactively** (finding:
`2026-06-14-ccc-codex-background-final-message-not-captured.md`). WORKAROUND that
works: instruct codex to write its verdict to a FILE via shell as its FINAL action
(`printf '%s\n' 'VERDICT: PASS|FAIL' '...' > /tmp/<f>.txt`), then `cat` it. Tell codex
it CANNOT build (sandbox lacks cohttp-lwt-unix) → orchestrator supplies build rc.
Codex earns its keep (found the 2 B0 signal-race windows the inline verifiers missed).

## WORKFLOW APPROACH (per slice)
`Workflow(implement: 1 opus agent writes code+tests in worktree, builds green →
verify: 3 parallel opus skeptic lenses)`. Always `model:'opus'` explicit (fable
broken). Then orchestrator: independent rebuild rc + fix blockers (new commit, never
amend) + commit + Codex peer-PASS. Stay in loop between slices (serial chain).

## BROKER API FACTS (confirmed from ocaml/c2c_mcp.mli — for B2–B5)
- `Broker.create ~root:string -> t`; `Broker.root : t -> string`.
- `list_registrations : t -> registration list`; `registration_liveness_state : registration -> liveness_state` (Alive|Dead|Unknown). registration sparse fields: session_id, alias, pid(int opt), dnd(bool), client_type(str opt), compacting(compacting opt), last_activity_ts(float opt), role(str opt), canonical_alias(str opt).
- `read_archive : t -> session_id -> limit:int -> archive_entry list` (**NEWEST-FIRST** — it List.rev's the oldest-first file on read, "reverse to get newest-first" c2c_broker.ml ~:2465. My earlier "oldest-first" note was WRONG; B3 blocker. A consumer wanting chat order must List.rev it.). archive_entry = {ae_drained_at; ae_from_alias; ae_to_alias; ae_content; ae_deferrable; ae_drained_by; ae_message_id(str opt)}.
- `read_inbox : t -> session_id -> C2c_mcp.message list`. message = {from_alias; to_alias; content; deferrable; reply_via; enc_status; ts; ephemeral; message_id(str opt)}.
- `list_rooms : t -> room_info list`. room_info = {ri_room_id; ri_member_count; ri_members; ri_alive_member_count; ri_dead_member_count; ri_unknown_member_count; ri_member_details; ri_visibility(Public|Invite_only); ri_invited_members}.
- `read_room_history : t -> room_id -> limit:int -> ?since:float -> unit -> room_message list` (trailing unit; [] common). **OLDEST-FIRST / newest-last** — UNLIKE read_archive: it keeps the newest `limit` entries but in chronological order (no final reverse), c2c_broker.ml :3791. So B4 renders rv_history AS-IS (no List.rev); overflow keeps the TAIL (newest). room_message = {rm_from_alias; rm_room_id; rm_content; rm_ts}.
- Layout: root/archive/<sid>.jsonl, root/<sid>.inbox.json, root/rooms/, root/registry.json.
- SEND (B5): `enqueue_message t ~from_alias ~to_alias ~content ?deferrable ?ephemeral ()`; `send_room ?tag t ~from_alias ~room_id ~content -> send_room_result{sr_delivered_to;sr_skipped;sr_ts;sr_warning}`. Raises Invalid_argument (unknown/dead/reserved-from). resolve_alias ?override (c2c.ml:149); resolve_broker_root (c2c_utils.ml:25).

## B2 RENDER FACTS
- `C2c_history.format_timestamp (float):string` (c2c_history.ml:10); `format_entry ?headers (archive_entry):string list` (:26).
- `Banner.pad_right (s)(n)` (Banner.ml:37); `Banner.visible_width (s)` (:43) is **BYTE-based** (over-counts multibyte/box-drawing glyphs) → for display width use a UTF-8 codepoint counter (B0's test did this; box glyphs ─│┌┐└┘ are 3 bytes / 1 column).

## MODULE PLAN
B0: c2c_watch.ml (lambda-term app, ONLY LTerm module) + c2c_watch_render.ml (pure
render→string) ✅. B1: c2c_watch_data.ml. B2: c2c_watch_state.ml (pure state machine)
+ grow render + wire Peers tab + poll loop into c2c_watch.ml. Add each new module to
ocaml/cli/dune (modules) + a mirrored test stanza as created (don't add nonexistent modules).

## INTEGRATION SITES (B0 already wired)
dune:3 (modules: ...c2c_watch c2c_watch_render), dune:4 (libraries +lambda-term),
c2c.ml all_cmds (~:12321, `C2c_watch.watch_cmd` before `help`), c2c_commands.ml
command_tier_map (`"watch", Tier3`). try_fast_path NOT touched (watch falls through).

## OPS
- Heartbeat Monitor: `bxwfkv6x2` (4.5m, persistent). (Re-armed after the org-spend-limit
  pause killed `bd2bbcvnj`; the B4 verify lenses also died on the limit + were resumed via
  {scriptPath, resumeFromRunId}.) NOTE: after the resume the workflow session dir is
  `5d11a38f-...` (was `574c00d6-...`) — task outputs may land under either.
- Org Claude spend-limit was hit earlier (killed a workflow); Max raised it ("We're
  good now"). If subagents fail with "monthly spend limit" again → attn Max, preserve
  worktree state, don't burn budget.
- This session has NO C2C_MCP_SESSION_ID (orchestrator, not a registered peer).
- Tasks: #45 B0 completed; #46 B1 in_progress; #47 B2, #48 B3, #49 B4, #50 B5 pending.
- DON'T go idle after launching bg work: a Workflow's completion notification
  re-invokes me (proven). Heartbeat is keepalive, not the primary re-invoke.
