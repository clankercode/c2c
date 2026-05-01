# Kimi notifier: replace tmux-scrape idle detection with statefile-based check

- **Filed**: 2026-05-01T01:54:00Z by coordinator1 (Cairn-Vigil)
- **Driver**: Max directive 2026-05-01 — *"with kimi agents, we should
  do some things in an order: fix statefile active/idle detection;
  only send `[c2c] check inbox` heartbeat reminder when the agent is
  idle. right now, `[c2c] check inbox` is sent regardless of idle/busy,
  and it gets stuck as a queued message."*
- **Severity**: HIGH (UX defect; observed live in lumi-test +
  tyyni-test sessions today)

## Symptom

Live kimi `state.json` files for active sessions show:

```json
"custom_title": "[c2c] check inbox",
"title_generated": false,
```

The wake-keys text is **typed into kimi's input box but never
submitted** because the agent loop was busy when send-keys fired. The
heuristic in `c2c_kimi_notifier.ml:tmux_pane_is_idle` returned "idle"
when kimi was actually mid-step.

Net effect:

- Real DM gets queued in input as `[c2c] check inbox <body>` text or
  as a stuck-pending input the operator has to manually clear.
- Subsequent wakes either pile on top of the stuck input OR get
  skipped because `Thinking…` happens to be on screen now.
- LLM-sink agent-turn injection still happens at next turn boundary,
  but the input-box pollution looks alarming and confuses operators.

## Current implementation

`ocaml/c2c_kimi_notifier.ml` lines 269–282:

```ocaml
let tmux_pane_is_idle ~pane =
  let tail = tmux_capture_tail ~pane in
  if tail = "" then true  (* no info → assume idle, send wake *)
  else
    let busy_markers = [ "Thinking"; "Tool:"; "elapsed_steps="; "permission" ] in
    not (List.exists ... busy_markers)
```

**Failure modes**:

1. The 4 markers don't cover every kimi busy state — between `Tool:`
   completion and the next API call, the screen can show neither
   marker for ~100ms, but the agent loop is still busy (about to
   start the next step).
2. Tmux capture-pane sees only what's currently on screen. If the
   pane was scrolled into copy-mode, capture is stale.
3. Falls open on capture failure, which is the wrong side to fail
   when the cost is "stuck input pollution."

## Proposed fix — statefile-based idle detection

Kimi-cli writes `wire.jsonl` per session at
`<KIMI_SHARE_DIR>/sessions/<wh>/<sid>/wire.jsonl`. Every TurnBegin /
Step / Tool / Done event appends a line. Disk-observable, no scraping.

**Idle iff `mtime(wire.jsonl)` is older than threshold (default 2s).**

Combined check (both must pass):

```ocaml
let kimi_session_is_idle ~session_dir ~now ~threshold_s =
  let wire = Filename.concat session_dir "wire.jsonl" in
  match (try Some (Unix.stat wire).Unix.st_mtime with _ -> None) with
  | None -> true  (* no wire file → not actively writing → idle *)
  | Some mtime -> now -. mtime > threshold_s

let tmux_pane_is_idle_v2 ~pane ~session_dir ~now =
  kimi_session_is_idle ~session_dir ~now ~threshold_s:2.0
  && not (tmux_pane_has_pending_wake ~pane)
```

Where `tmux_pane_has_pending_wake` greps the captured pane for
`[c2c] check inbox` in the input-box region (i.e. the bottom couple
of lines after the `── input ──` divider). If our previous wake-text
is still sitting there waiting to be submitted, **don't fire another
wake** — that's the loop where they pile up.

### Pseudocode for the wake gate

```ocaml
let maybe_wake ~pane ~session_dir ~now =
  if tmux_pane_has_pending_wake ~pane then
    log "[kimi-notifier] skipping wake — prior wake-text still in input box";
  else if not (kimi_session_is_idle ~session_dir ~now ~threshold_s:2.0) then
    log "[kimi-notifier] skipping wake — wire.jsonl mtime < 2s ago (busy)";
  else
    tmux_wake ~pane
```

The notifier already knows the `session_id` (resolves it for the
notification dir). Path computation is the same root + `wire.jsonl`
suffix.

## Slice plan

**Slice 1 — statefile idle detection** (~50 LoC + ~50 LoC test):
1. Add `kimi_session_is_idle` helper (`Unix.stat` + mtime arithmetic).
2. Add `tmux_pane_has_pending_wake` (capture-tail + grep for
   `[c2c] check inbox` in the bottom 4 lines).
3. Replace the body of `tmux_pane_is_idle` with the AND of the
   existing busy-marker check, the wire-mtime check, and the
   pending-wake check.
4. Log skips with a short reason so notifier.log shows when wakes
   are correctly suppressed.
5. Test: feed mock pane content + mock wire-mtime to assert
   skip/fire behavior.

**Slice 2 (optional) — backoff on stuck wake** (~30 LoC):
If `[c2c] check inbox` is detected in the input box and persists
longer than 30s, send tmux `C-u` (unix-line-discard) to clear the
input, then re-fire the wake. This recovers from the steady-state
stuck case rather than just observing it.

**Slice 3 (optional, larger) — kimi-cli upstream PR**:
Add a `runtime_state.json` (or update existing `state.json`'s
`wire_mtime`) so external observers don't have to stat
`wire.jsonl` directly. Defer until after Slices 1+2 prove the
disk-observation pattern.

## Side question Max raised

> *"On that note, is there a kimi setting to change the default queue
> msg / interrupt behavior?"*

Surveyed `kimi_cli/ui/shell/` source:

- No top-level config knob found for "what happens when input is
  typed during a busy turn." Kimi's prompt-toolkit-based shell
  buffers the keystrokes; submit-on-Enter only takes effect when
  control returns to the prompt event loop (between turns).
- Closest controls: `[loop_control]` block in `~/.kimi/config.toml`
  has `max_steps_per_turn`, `max_retries_per_step`, etc — these
  bound when control returns, but don't change input-buffer
  semantics.
- There IS a `KeyboardInterrupt` path (`kimi_cli/ui/shell/__init__.py:206`
  — slash-command interruption) and a `cleanup(is_interrupt=True)` in
  visualize.py for live-view tear-down — but these are operator-
  initiated (Ctrl-C), not auto-fire-on-input.
- **Conclusion**: there's no built-in "interrupt on new input" mode
  to flip. The right c2c-side behavior is *don't send the keystrokes
  while busy* (this slice), rather than relying on kimi to handle
  in-flight input gracefully.

A future upstream PR could add `[input] interrupt_on_paste = true`
or similar, but that's a kimi-cli feature request, not a c2c slice.

## Crush deprecation note (separate Max directive)

Max also said: *"crush is now a deprecated client, we don't need to
worry about supporting it."*

Action items:
- Drop Crush from `.collab/design/2026-05-01-e2e-verification-checklist-per-client.md` (§Clients in scope item 5).
- Remove Crush column from `docs/clients/feature-matrix.md` (or mark it explicitly DEPRECATED with a header note).
- Light pass on `c2c install crush` / `c2c start crush` to confirm they still warn-or-refuse (#404 was "Deprecate Crush support" — verify that landed completely).
- No removal of code in this pass — just docs/checklist drop.

This is a single small slice (~30 LoC docs + verification) that any
peer can pick up; will not block the kimi-idle slice above.

## Recommended owner + ordering

- **Slice 1** (kimi idle detection): jungle-coder (familiar with
  tmux/PTY plumbing from #488 / #561) OR willow-coder if she takes the
  kimi-hook allowlist slice — either way, single-author single-PASS.
- **Slice 2 / 3**: hold until Slice 1 lands and is observed in the
  field.
- **Crush docs drop**: any peer; cedar-coder good fit if she returns
  (docs-hygiene cache from `#560`).

## Cross-references

- `ocaml/c2c_kimi_notifier.ml:252-288` — current heuristic
- `.collab/runbooks/kimi-notification-store-delivery.md` §"Agent
  doesn't see the message at idle" — operator-facing description of
  the wake heuristic; will need an addendum after Slice 1 lands
- `.collab/findings/2026-05-01T01-47-18Z-coordinator1-kimi-hook-over-forwards-every-shell-call.md` — sister kimi-UX defect

— Cairn-Vigil
