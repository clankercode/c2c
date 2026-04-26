# #303 — channel-push DM ordering: trace + hypotheses

stanza-coder, 2026-04-26 ~09:42 UTC. Investigation slice. No code yet.

## Symptom (Cairn 2026-04-26)

> Rooms always push but DMs sometimes only via poll. Investigate why
> and align.

User-visible: a room broadcast surfaces in the recipient's transcript
as a `<c2c event="message">` tag near-real-time, every time. A DM
sometimes only shows up when the recipient explicitly calls
`poll_inbox` (or when Claude Code's PostToolUse hook drains the
inbox at the end of an unrelated tool call).

## Path map

Both DM and room messages land in the SAME per-recipient inbox file
`<broker_root>/<session_id>.inbox.json` and flip the same lock
(`with_inbox_lock`). Differences live downstream of enqueue:

### DM path
1. `Broker.enqueue_message t ~from_alias ~to_alias ~content
   ?(deferrable=false) ?(ephemeral=false) ()` —
   `ocaml/c2c_mcp.ml:1298`.
2. Resolves `to_alias → session_id`, takes inbox lock, appends
   message.
3. Default `deferrable=false`. Caller can override via the MCP `send`
   tool's `deferrable` parameter.

### Room path
1. `Broker.send_room t ~from_alias ~room_id ~content` —
   `ocaml/c2c_mcp.ml:2404`.
2. Dedup check, history append, then `fan_out_room_message`
   (`ocaml/c2c_mcp.ml:2068`) iterates members.
3. Per member: same `with_inbox_lock` + append, with `to_alias`
   tagged `<alias>#<room_id>` and **`deferrable=false` hardcoded**.

### Push delivery (channel-notification)
- In-process MCP server: `start_inbox_watcher`
  (`ocaml/server/c2c_mcp_server.ml:151`) ticks every 1.0s, detects
  inbox-file size growth, sleeps `C2C_MCP_INBOX_WATCHER_DELAY`
  (default **5.0s**), then calls `drain_inbox_push`.
- `drain_inbox_push` (`ocaml/c2c_mcp.ml:1545`) keeps deferrable
  messages in the inbox, removes non-deferrable, returns the
  removed set.
- For each removed message, watcher emits a JSON-RPC notification
  `notifications/claude/channel` — surfaces as `<c2c>` in
  recipient transcript via `--dangerously-load-development-channels`.
- Gated by `C2c_capability.Claude_channel` having been negotiated
  in `initialize` (Claude Code only emits the cap with the dev
  channel flag).

### PostToolUse-hook delivery (parallel path, Claude Code only)
- `c2c-inbox-hook-ocaml` (`ocaml/tools/c2c_inbox_hook.ml`) runs at
  end of every tool call. Calls `drain_inbox_push` on the same
  inbox, prints each message as
  `<c2c event="message" ...>...</c2c>` to stdout. Claude Code
  inserts this into the transcript adjacent to the tool result.
- This is the path that wins races during active work — fires
  every tool call vs the watcher's 1+5s loop.

### Poll path
- Explicit `mcp__c2c__poll_inbox` or `c2c poll-inbox`.
- Calls `drain_inbox`, returns ALL messages (deferrable included),
  archives non-ephemeral. This is the only fallback that fires for
  deferrable messages.

## Hypotheses

### H1 (most likely): race between hook and watcher; differential trigger

Both DMs and room broadcasts reach the same drain path. Difference
is **when the recipient is most likely to be working**:

- DM: usually arrives mid-conversation. Recipient is actively doing
  tool calls. PostToolUse hook fires **before** the watcher's 5s
  delay elapses. Hook drains the message, emits the `<c2c>` tag
  attached to the tool result. **No channel-notification ever
  emitted** because `drain_inbox_push` already returned [].
- Room broadcast: often arrives when recipient is idle (broadcasts
  fire to many at once, and not all members are working at any
  given moment). Hook doesn't fire (no tool calls). Watcher's 5s
  delay completes, `drain_inbox_push` finds the message, emits via
  channel-notification.

**Result**: DMs surface "via tool result" rather than "via push";
rooms surface "via push." Both surface as `<c2c>` tags in the
transcript, but the perceived latency and association differ:
- Hook-delivered `<c2c>` lands attached to a tool response (could
  be seconds after the message arrived if the tool was already
  running).
- Channel-notification-delivered `<c2c>` lands as its own
  notification ASAP (within ~5s of arrival).

If this hypothesis is right, the symptom is **not a delivery bug**
— both are delivered. It's a **path-divergence UX issue** where
working agents see DMs delayed-bundled and idle agents see rooms
real-time-pushed.

### H2 (less likely): a DM-specific deferrable default

If a sender uses `mcp__c2c__send` with `deferrable=true` (legitimately
or by accident), the watcher and the hook both skip it. Only
`poll_inbox` returns it. Rooms can't be deferrable —
`fan_out_room_message` hardcodes `false`. So any deferrable DM is
"poll-only" by design.

Plausibility: low for the general report (Cairn would have noticed
the pattern), but high for specific surprise cases. Worth ruling out
by checking actual delivery_mode in inbox archive.

### H3 (cap/negotiation skew): channel cap not always present

If a recipient's session didn't negotiate `Claude_channel` in
initialize, the watcher's drain branch is skipped — only the hook
and explicit polls deliver. That'd affect DMs and rooms equally
though. Doesn't explain the asymmetry. Rule out.

### H4 (hook-only-on-tool-use timing edge): idle recipient, room watcher fires faster than next-DM watcher

Stretch hypothesis: maybe the watcher's poll loop is amortized in a
way that lets later-arriving DMs miss the size-grew detection. Not
seeing how given the implementation is `last_size + 1s sleep`. Rule
out.

## Plan to verify (no code yet)

Run a controlled probe:

1. Send recipient (idle) a DM. Observe whether channel-notification
   fires (watcher path) vs nothing fires (hook didn't run, watcher
   gated by something).
2. Send recipient (idle) a room broadcast. Observe channel-notification.
3. Send recipient (active, mid-tool-call) a DM. Observe whether
   `<c2c>` lands at end of tool call (hook) or as its own
   notification (watcher).
4. Read `<broker_root>/archive/<session_id>.jsonl` to see
   timestamps and ordering.
5. Check `c2c stats --alias <recipient>` for delivery-mode counters
   if they exist; otherwise add lightweight instrumentation.

If H1 is confirmed, the fix is **align both paths** so the user
perception matches reality:

- Option A: tighten the watcher delay (lower default below 5s) —
  but that defeats the "let preferred paths win" rationale.
- Option B: make the hook NOT consume push messages — leave them
  for the watcher to emit as proper channel-notifications, and
  have the hook emit only on `<c2c event="hook-flush">` or similar
  marker that signals "agent was working when these arrived." But
  this re-introduces the original problem of agents missing
  delivery if they don't tool-call.
- Option C: have the hook emit messages via a synthesized
  channel-notification format (same `<c2c>` envelope shape, same
  timing semantics), so the user can't tell which path delivered
  it. **This is the alignment.** Currently the hook prints an
  envelope to stdout and Claude Code attaches it to the tool
  output; the watcher emits a separate JSON-RPC notification.
  Different surfaces; different rendering. If we unify the
  rendering so both produce the SAME shape of `<c2c>` tag at the
  SAME visual position, user perception aligns and the
  hook-vs-watcher race becomes invisible — which is what we
  want.

If H2 is confirmed, the fix is **document deferrable-default more
prominently** + check whether any caller is accidentally setting it.

## Out of scope for this slice

- Fixing #305 (mcp__c2c__send doesn't expose ephemeral) — separate
  ticket, blocks remediation but not investigation.
- Cross-host push semantics over the relay — local first.
- Rewriting the watcher delay to a per-message smarter algorithm.

## Probe results (2026-04-26 ~09:48 UTC)

Five probes, two recipients (test-agent / OpenCode, idle; stanza /
Claude Code, active mid-tool-call). All probes used the live broker.

| # | Sender | Recipient | Type | deferrable | Surface in transcript |
|---|---|---|---|---|---|
| 1 | stanza | test-agent (idle, OC) | DM | false | `<c2c event="message" source="broker">` (push, OC plugin) |
| 2 | stanza | test-agent (idle, OC) | Room broadcast | false (forced) | `<c2c event="message" source="broker">` (push, OC plugin) |
| 3 | galaxy | stanza (active, CC) | DM | false | `<channel source="c2c">` (push, channel-notification) |
| 4 | galaxy | stanza (active, CC) | Room broadcast | false (forced) | `<channel source="c2c">` (push, channel-notification) |
| 5 | stanza | test-agent (idle, OC) | DM | **true** | **NOT pushed**; inbox drained later via `poll_inbox` |

### Findings

1. **Both DMs and rooms push identically when `deferrable=false`.**
   Probes 1–4 all surfaced via the harness's push path within ~5–10s
   of arrival, regardless of message type or recipient activity.
2. **The harness rendering differs by client.** OpenCode's plugin
   prints `<c2c event="message" source="broker">` from its monitor
   subprocess; Claude Code with dev channels renders the
   `notifications/claude/channel` JSON-RPC as
   `<channel source="c2c">`. Same broker behavior, different surface
   shapes.
3. **`deferrable=true` is the actual cause of "only via poll."**
   Probe 5: an MCP `send` with `deferrable:true` writes to the inbox,
   but `drain_inbox_push` (in `ocaml/c2c_mcp.ml`) filters it out, so
   the watcher and the PostToolUse hook both skip it. The next
   `poll_inbox` (or the deliver daemon's idle flush) returns it.
4. **Rooms never use `deferrable=true`.** `fan_out_room_message`
   hardcodes `deferrable=false`. On the origin/master baseline of
   this slice, the only production sender that opts into
   `deferrable=true` is `ocaml/relay_nudge.ml` (relay nudges). User
   opt-in is via the MCP `send` tool with `deferrable:true`.

   Forward-compat note: additional deferrable opters-in may exist
   on local master ahead of origin. In particular, the forthcoming
   send-memory handoff (#286) uses `~deferrable:true` on its broker
   DM; once that lands on origin, both this doc and the CLAUDE.md
   one-liner should be updated to list it explicitly. The audit
   tracked under #307 covers re-checking the full set after each
   origin push.

### Revised diagnosis

The observed symptom is **not a bug** in the broker or the push
path. It is `deferrable=true` working as designed: low-priority
DMs don't push, they wait for poll. Because rooms never use the
flag, they always push.

User perception "rooms always push but DMs sometimes only via poll"
maps to: "rooms never opt into low-priority delivery; DMs sometimes
do (relay-nudge today; user opt-in via MCP `send`; future
send-memory handoff once #286 lands on origin)."

H1 (path-divergence-as-UX) was partially right — different harnesses
do render the surface differently — but H2 (deferrable opt-in) is
the load-bearing answer. The original render-alignment fix is not
needed.

## Recommendation

No alignment-of-render fix needed. Three smaller follow-ups:

1. **Document the deferrable contract more loudly.** CLAUDE.md
   doesn't really call out the user-perceived consequence; the MCP
   tool description does. A one-liner under "Key Architecture Notes"
   would be enough: "`deferrable=true` means no push; recipient must
   `poll_inbox` (or hit idle flush) to see it."
2. **Diagnostic: `c2c doctor delivery-mode`** — given an alias,
   show a histogram from inbox archive of how many recent messages
   arrived via push vs poll vs hook. Makes the deferrable
   distribution visible. Optional / nice-to-have.
3. **Audit deferrable senders.** Origin-baseline today: just
   `relay_nudge.ml`. If its nudges are actually high-priority (would
   I be sad if I missed one for 30 min?), they should drop
   `deferrable=true`. Once #286 lands on origin, the send-memory
   handoff is the second site to evaluate — Cairn and I dogfooded
   it on local master and the substrate-reaches-back behavior
   depended on the broker DM pushing promptly, so the deferrable
   choice there is worth re-thinking. Tracked under #307.

## What this slice ships

This design doc, with the probe data above, as a single artifact —
research, no production code change. Recommendation #1 (CLAUDE.md
one-liner) can piggyback as a small edit in this slice or split off.

— stanza-coder, 2026-04-26
