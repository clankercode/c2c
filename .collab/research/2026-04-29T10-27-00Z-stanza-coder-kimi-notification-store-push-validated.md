# Kimi notification-store push delivery — VALIDATED

- **Date:** 2026-04-29 10:27 UTC
- **Author:** stanza-coder
- **Status:** PROBE COMPLETE — design path forward
- **Cross-references:**
  - Root-cause finding: `b6455d8e` (`c2c-start-kimi-spawns-double-process.md`)
  - Sibling findings: `ae671eb5` (role wizard), `fedb23a2` (slate author leak)
  - Birch's reconciliation: `.collab/research/2026-04-29-kimi-dual-process-independent-verify-birch.md`

## TL;DR

Kimi-cli's notification subsystem (`kimi_cli/notifications/`) is a
file-based push pathway that c2c can drive directly. **Validated
end-to-end:** writing a hand-crafted `event.json` + `delivery.json`
into a running kimi's session notification store causes the kimi TUI
to render a toast within ~3s (shell-sink, fully idle-capable) AND
the agent's LLM context receives a `<notification>...</notification>`
user-turn message at the next agent turn (LLM-sink).

Replaces the `c2c-kimi-wire-bridge` approach entirely. **No
subprocess. No JSON-RPC. No dual-agent. No PATH leaks.**

## Architecture (validated)

```
~/.kimi/sessions/<workspace-hash>/<session-id>/
  ├── context.jsonl                        ← kimi's conversation history
  └── notifications/                       ← per-session notification store
      └── <notification-id>/
          ├── event.json                   ← NotificationEvent (schema below)
          └── delivery.json                ← NotificationDelivery (sink states)
```

**NotificationEvent schema** (`kimi_cli/notifications/models.py`):
```json
{
  "version": 1,
  "id": "string [a-z0-9]{2,20}",
  "category": "task|agent|system",
  "type": "string (free-form, e.g. c2c-dm)",
  "source_kind": "string (origin descriptor)",
  "source_id": "string",
  "title": "string",
  "body": "string (the actual message body)",
  "severity": "info|success|warning|error",
  "created_at": "float (epoch seconds)",
  "payload": {},
  "targets": ["llm", "wire", "shell"],
  "dedupe_key": null | "string"
}
```

**NotificationDelivery schema:**
```json
{
  "sinks": {
    "<sink-name>": {
      "status": "pending|claimed|acked",
      "claimed_at": null | <float>,
      "acked_at": null | <float>
    }
  }
}
```

## The three sinks

| Sink     | Watcher                              | Idle-deliverable? | Use for c2c |
|----------|--------------------------------------|-------------------|-------------|
| `shell`  | continuous async (1s poll)           | ✅                | toast to operator |
| `llm`    | drained at agent turn boundary       | ⚠️ (needs wake)   | inject into agent context |
| `wire`   | drained at agent turn boundary       | ⚠️ (mostly redundant) | (skip for c2c) |

The shell-sink watcher is started in `kimi_cli/ui/shell/__init__.py:394`
as a background async task — runs at idle. The LLM-sink is drained inside
`kimi_cli/soul/kimisoul.py:965` `deliver_pending("llm", ...)` which is
called per agent turn (between user input and agent reply, or between
tool calls).

## Probe procedure (replicable)

1. **Spawn probe kimi**:
   ```
   tmux send-keys -t 0:2.4 "C2C_MCP_BROKER_ROOT=$ROOT c2c start kimi -n probe" Enter
   ```
2. **Find session id**: peek the TUI banner — `Session: <UUID>`. Or check
   `kimi.log` for `Created new session: <UUID>`. (NOTE: this UUID differs
   from the `resume_session_id` in c2c's instance metadata; it's the actual
   kimi internal session id.)
3. **Find session dir**: `~/.kimi/sessions/<workspace-hash>/<session-id>/`.
   The workspace-hash is per-cwd (md5 or similar). For c2c's repo it's
   `f331b46a50c55c2ba466a5fcfa980fc2`.
4. **Write notification**:
   ```bash
   ndir=~/.kimi/sessions/<wh>/<sid>/notifications/<nid>
   mkdir -p "$ndir"
   cat > "$ndir/event.json" <<EOF
   {"version":1,"id":"<nid>","category":"agent","type":"c2c-dm",
    "source_kind":"<sender-alias>","source_id":"<sender-alias>",
    "title":"<short>","body":"<DM body>","severity":"info",
    "created_at":<epoch>,"payload":{},
    "targets":["llm","shell"],"dedupe_key":null}
   EOF
   cat > "$ndir/delivery.json" <<EOF
   {"sinks":{
     "llm":{"status":"pending","claimed_at":null,"acked_at":null},
     "shell":{"status":"pending","claimed_at":null,"acked_at":null}
   }}
   EOF
   ```
5. **Observe**:
   - Within ~3s the TUI bottom shows the toast `• <title>` (shell-sink fires)
   - delivery.json updates: `shell.status` → `acked` with `acked_at` timestamp
   - LLM-sink stays `pending` until next agent turn
6. **Wake the agent** (if idle):
   ```
   tmux send-keys -t 0:2.4 "[c2c-wake] check inbox" Enter
   ```
7. **Verify**: agent's first reasoning chain references the notification
   bodies; delivery.json `llm.status` → `acked`.

## Test results (2026-04-29 20:22 — 20:25 UTC)

- **probe1c2c**: written to wrong session-id (de28782e wasn't created
  yet — kimi banner-displayed id). Sat in 41a9d03c-... and 619a4dad-...
  but those weren't the FG TUI's session. Result: never delivered to
  agent. **Lesson**: must pin the right session-id at write time.
- **probe2fg**: written correctly to `de28782e/notifications/probe2fg/`.
  Shell-sink fired toast immediately. LLM-sink stayed pending until
  wake-prompt.
- **probe3all**: same as probe2fg, with all three sink targets. Toast
  fired within 3s. After `tmux send-keys -t 0:2.4 "hello" Enter`, agent
  processed BOTH probe2fg AND probe3all in its first reasoning chain.

Final delivery state for probe3all:
```
shell:  acked  (acked_at: 1777458298.08, 3s after write)
wire:   acked  (acked_at: 1777458347.55, 49s, turn-driven)
llm:    acked  (acked_at: 1777458347.69, 49s, turn-driven)
```

## Implementation plan for c2c-kimi-notifier (replaces wire-bridge)

**Files to modify** (estimate):

- `ocaml/c2c_wire_bridge.ml` → `ocaml/c2c_kimi_notifier.ml` (rename + rewrite)
  - Drop `kimi --wire` subprocess spawn (~50 LoC removed)
  - Add session-dir resolution from instance metadata + kimi.log
  - Add `event.json` + `delivery.json` writer
  - Add tmux-wake send-keys helper (when target kimi is idle)
- `ocaml/c2c_wire_daemon.ml` → `ocaml/c2c_kimi_deliver_daemon.ml` (mostly compatible)
  - Wraps the new notifier in the same `start_daemon` shell
- `ocaml/c2c_start.ml`:
  - line 4074-4079 — replace `start_wire_daemon` call with `start_kimi_deliver_daemon`
  - kimi `client_config` (line 1203) — same shape, different deliverable

**Wake-trigger heuristic:**
- Capture pane scrollback (`tmux capture-pane -t <pane> -p | tail -3`)
- Match on `── input ──` followed by an empty input area = idle
- Match on `Thinking...` or `Tool: ...` = busy → don't wake; rely on natural drain
- Skip wake if pane shows a permission prompt or other modal

**Session-id discovery** (open question):
- Option (a): parse `~/.kimi/logs/kimi.log` for `Created new session: <UUID>` (line emitted at startup); pick the most recent matching the inner kimi pid
- Option (b): symlink `~/.local/share/c2c/instances/<alias>/active-session-id` written by kimi-launcher (requires upstream change)
- Option (c): use lsof on the inner kimi's open files; the context.jsonl path reveals the session-id
- Recommend (a) for v1 (no upstream change), (b) for v2 (cleaner)

**Open questions:**

1. **Multi-session per alias.** The dual-agent bug means there are
   currently TWO active kimi sessions per c2c instance. Writing to
   only the FG-TUI session is correct, but discovery must pick the
   FG (not the BG wire-bridge subprocess's session). Cleanest path:
   fix the dual-agent first (delete the wire-bridge spawn), THEN
   write the notifier. The notifier replaces wire-bridge anyway.

2. **Wake-trigger pollution.** `tmux send-keys "[c2c-wake] check inbox"`
   makes a visible input line in the kimi pane. Could explore:
   - Bracketed paste with a known prefix the agent recognizes + ignores in display
   - A `kimi --session <id> --prompt ""` invocation (NEW process, but
     short-lived single-shot — would still register with broker briefly,
     could be partially mitigated by registering as transient session-id)
   - Custom escape sequence kimi-cli could ignore but wake on (upstream)

3. **Operator-typing collision.** If the operator is mid-typing when
   c2c sends a wake prompt, the strings concatenate. Mitigation: detect
   "input area has user typing" via pane capture before send-keys; defer
   if so.

4. **Crashed-kimi recovery.** If kimi crashes, notifications stay in the
   store. On respawn, kimi reads the existing notifications/ dir and
   replays them (per the `recover()` path in NotificationManager). This
   is good — c2c doesn't need crash-recovery logic.

## Recommendation

Ship Option G (notification-store push + tmux wake) as the kimi delivery
path. Delete the wire-bridge for kimi entirely. Architecture is cleaner,
operationally observable (toasts!), and removes the dual-agent root cause.

Estimated impl: ~200 LoC OCaml + ~50 LoC test. One slice. Ready to start
once design is approved.
