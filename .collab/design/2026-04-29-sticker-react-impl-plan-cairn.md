# Implementation Plan: `c2c sticker react` — emoji reactions on messages

- author: cairn-line (OCaml engineer subagent)
- date: 2026-04-29
- status: plan — not implemented
- design doc: `.collab/design/2026-04-29-stickers-reactions-cairn.md`
- target: 4 worktree slices, peer-PASS between each

## 0. Anchors in the existing tree (single source of truth)

- `ocaml/cli/c2c_stickers.ml` — envelope type, signing, storage, CLI (~396 LOC)
- `ocaml/cli/c2c_stickers.mli` — public surface (~103 LOC)
- `ocaml/cli/c2c.ml:9888` — `C2c_stickers.sticker_group` mounted into top-level dispatch
- `ocaml/cli/dune:3` — module list (no edit needed for this slice)
- `ocaml/c2c_mcp.mli:204` — `Broker.enqueue_message ~from_alias ~to_alias ~content ?deferrable ?ephemeral`
- `ocaml/c2c_mcp.mli:237` — `archive_entry { ae_drained_at; ae_from_alias; ae_to_alias; ae_content; ae_deferrable; ae_drained_by }` — **no message_id field**
- `ocaml/c2c_relay_connector.ml:290,305,319` — relay outbox carries `message_id`; not surfaced into archive
- `ocaml/relay.ml ~230` — relay-layer message_id (for de-dup; uniqueness)
- `.c2c/stickers/registry.json` — closed set; 9 entries, all positive

Three friction points already visible:
1. `archive_entry` has no `message_id`. Slice 3 must add it (or cross-reference relay log).
2. `sticker_envelope.version` is hardcoded `1`; bumping to `2` for `target_msg_id` is the cleanest schema move.
3. Existing canonical_blob does NOT include `version` despite reading it (line 98 prepends it via `string_of_int env.version`). Wait — it does. Good. Adding `target_msg_id` to the canonical blob is therefore safe and verifiable across versions.

## 1. Slice S1 — schema + envelope extension (data layer only)

**Goal:** Add `target_msg_id : string option` to envelope; bump version to 2;
keep verification compatible with v1 envelopes on disk.

### Files to modify

- `ocaml/cli/c2c_stickers.ml` — envelope record, canonical_blob, envelope_to_json,
  envelope_of_json, create_and_store, format_sticker
- `ocaml/cli/c2c_stickers.mli` — add `target_msg_id : string option;` to record
- `ocaml/test/test_stickers.ml` (new) — golden tests, sign-and-verify roundtrip

### Function signature changes

```ocaml
type sticker_envelope = {
  version : int;                  (* 1 = legacy, 2 = with target_msg_id *)
  from_ : string;
  to_ : string;
  sticker_id : string;
  note : string option;
  target_msg_id : string option;  (* NEW — None for peer-addressed stickers *)
  scope : scope;
  ts : string;
  nonce : string;
  sender_pk : string;
  signature : string;
}

val create_and_store :
  from_:string ->
  to_:string ->
  sticker_id:string ->
  note:string option ->
  ?target_msg_id:string ->        (* NEW optional *)
  scope:scope ->
  identity:Relay_identity.t ->
  unit ->
  (sticker_envelope, string) result
```

### Canonical blob (back-compat strategy)

```
v1 (legacy): "1|from|to|sticker_id|note_or_empty|scope|ts|nonce"
v2 (new):    "2|from|to|sticker_id|note_or_empty|scope|ts|nonce|target_msg_id_or_empty"
```

`canonical_blob` switches on `env.version`. v1 envelopes verify exactly as
before; v2 envelopes always sign the new tail field (empty string when
`target_msg_id = None`, so peer-addressed v2 stickers are still well-defined).
**Do NOT** retroactively re-sign existing on-disk v1 envelopes — verify them in
v1 mode forever.

### Test cases

- `roundtrip_v1_envelope` — load legacy v1 fixture from `test/fixtures/sticker_v1.json`, verify Ok
- `roundtrip_v2_peer_addressed` — version=2, target_msg_id=None, sign + verify
- `roundtrip_v2_reaction` — version=2, target_msg_id=Some "abc123", sign + verify
- `tamper_target_msg_id` — flip target_msg_id post-sign, verify Error
- `json_decoder_missing_target_msg_id` — v2 JSON without the field decodes with `None` (forward-compat)

### LoC estimate: ~80 LOC src + ~120 LOC tests = ~200 LOC

### Out of scope

No CLI surface change, no broker changes, no archive index. Pure data.

---

## 2. Slice S2 — `sticker react` + `sticker reactions` CLI

**Goal:** Two new subcommands. `react` constructs a v2 envelope with
`target_msg_id`, stores locally, and *also* enqueues a DM to the original
sender with a `<c2c event="reaction" .../>` body.

### Files to modify

- `ocaml/cli/c2c_stickers.ml` — `sticker_react_cmd`, `sticker_reactions_cmd`,
  add to `sticker_group` cmd list
- `ocaml/cli/c2c_stickers.mli` — no public-surface change beyond what S1 added
- `ocaml/cli/c2c_history.ml` — new helper `find_message_by_id : alias:string -> id_prefix:string -> archive_entry option` (matches first-8-char prefix; ambiguity → Error)
- `ocaml/test/test_stickers_react.ml` (new) — integration test using `C2C_REGISTRY_PATH`

### Function signatures

```ocaml
(* private to c2c_stickers.ml *)
val resolve_target_message :
  alias:string -> id_or_prefix:string ->
  (Broker.archive_entry, string) result

val build_reaction_xml :
  from_alias:string -> target_msg_id:string -> sticker_id:string -> emoji:string -> string

val by_msg_index_path : alias:string -> msg_id:string -> string
val append_to_by_msg_index : alias:string -> env:sticker_envelope -> unit
val load_by_msg_index : alias:string -> msg_id:string -> sticker_envelope list
```

### CLI surface

```
c2c sticker react <msg-id-or-prefix> <sticker-id> [--note STR]
c2c sticker reactions <msg-id-or-prefix>
```

`react` flow:
1. Resolve current alias (`C2C_MCP_AUTO_REGISTER_ALIAS`).
2. `resolve_target_message ~alias ~id_or_prefix` — find original sender + full id.
3. `create_and_store ~target_msg_id:(Some full_id) ~to_:sender ~scope:`Private`.
4. Append envelope path to `.c2c/stickers/<sender>/by-msg/<full-id>.json`.
   *Wait — this is the SENDER's index, on the RECIPIENT's machine.* Re-think:
   the index lives at the **reactor's** machine under
   `.c2c/stickers/<reactor>/by-msg-out/<full-id>.json`. The original sender's
   aggregator merges via the wall on their side once they receive the DM.
5. `Broker.enqueue_message broker ~from_alias ~to_alias:sender ~content:reaction_xml ()` (no `~deferrable`, default false).

### Test cases

- `react_creates_envelope_with_target` — given a fixture archive, react and verify env on disk has `target_msg_id`
- `react_enqueues_dm_to_original_sender` — broker fixture, observe enqueue call
- `react_unknown_msg_id_errors_helpfully` — error string mentions "did you poll-inbox?"
- `react_ambiguous_prefix_errors` — two messages share same 8-char prefix → Error
- `reactions_aggregates_by_msg_id` — two reactions to same msg from different senders both surface
- `react_deferrable_is_false` — assert the enqueue does NOT set `~deferrable:true`

### LoC estimate: ~150 LOC src + ~180 LOC tests = ~330 LOC

### Risks

- **archive_entry has no message_id.** Mitigation: extend `archive_entry` with
  `ae_message_id : string option` *as part of this slice* (record-extension
  patch in `ocaml/c2c_mcp.mli` + `ocaml/c2c_mcp.ml`). Backward-compat for old
  archives = field is None. This bleeds beyond "CLI only" but is unavoidable;
  call it out in the slice's commit message and the peer-PASS DM.
- Cross-host reactions (post-#379): `target_msg_id` is the relay-assigned id
  and globally unique already. If the recipient's host doesn't recognize the
  reaction event tag, it dead-letters consistently with #379 behaviour.

---

## 3. Slice S3 — MCP tool + inbox id surfacing + `--last`

**Goal:** Make reactions usable from inside an MCP session without flipping to
the CLI.

### Files to modify

- `ocaml/c2c_mcp.ml` — register `sticker_react` MCP tool (calls into S2
  helpers); update `poll_inbox`/`peek_inbox` JSON output to include
  `message_id_short` per envelope (already in JSON path, but add to the
  CLI text rendering)
- `ocaml/c2c_mcp.mli` — declare new tool
- `ocaml/cli/c2c.ml:837` — `poll_inbox_cmd` text formatter shows `[abc12345] from peer: ...`
- `ocaml/cli/c2c_stickers.ml` — `--last <peer>` flag for `react`: resolves to
  most recent archive entry from `peer`
- `ocaml/test/test_mcp_sticker_react.ml` (new)

### MCP tool spec

```
mcp__c2c__sticker_react
  args: { target_msg_id: string, sticker_id: string, note?: string }
  returns: { ok: true, envelope_path: string, dm_enqueued: true } | { ok: false, error: string }
```

`to_` is derived from the target message's archive entry (sender). The tool
errors if the caller has no archive match for `target_msg_id`.

### Test cases

- `mcp_sticker_react_happy_path` — JSON-RPC roundtrip
- `mcp_sticker_react_unknown_msg_id` — returns `ok: false` with helpful message
- `cli_react_last_peer_resolves_latest` — `--last cairn` picks most recent
- `poll_inbox_text_includes_8char_prefix` — golden render

### LoC estimate: ~120 LOC src + ~150 LOC tests = ~270 LOC

### E2E in tmux (post-build, pre-peer-PASS)

`scripts/c2c_tmux.py` driven flow (per CLAUDE.md "live-peer tests"):
1. Pane A (cairn-line): `c2c send jungle "ping #427"`
2. Pane B (jungle): `c2c poll-inbox` — observe `[<id>] from cairn-line: ping #427`
3. Pane B: `mcp__c2c__sticker_react { target_msg_id: "<id>", sticker_id: "on-point" }`
4. Pane A: `c2c poll-inbox` — observe inline reaction line
5. Pane A: `c2c sticker reactions <id>` — see jungle's 🎯

### Risks

- MCP tool must not block on missing archive — if `archive_entry` lookup fails
  (cold session, lost archive), return a clear error rather than silently
  enqueuing a DM with no anchor.
- Don't re-emit channel notifications for reaction DMs to avoid noise loops;
  reactions ride the existing channel-push path with their own event tag.

---

## 4. Slice S4 — Room reactions (optional v1)

**Goal:** `c2c sticker react --room <room-id> --last <sticker-id>` reacts to
the most recent room message; `room_history` annotates inline.

### Files to modify

- `ocaml/cli/c2c_rooms.ml` — `room_history` formatter accepts a reactions
  index lookup
- `ocaml/c2c_mcp.ml` — `fan_out_room_message` invoked with reaction body
- `ocaml/cli/c2c_stickers.ml` — `--room` + `--last` flag combination

### Test cases

- `room_react_broadcasts_to_all_members`
- `room_history_annotates_with_reactions`
- `room_react_does_not_double_archive` (room-event semantics differ from DMs)

### LoC estimate: ~100 LOC src + ~100 LOC tests = ~200 LOC

### Decision gate

**Ship S4 only if S3 lands clean with budget remaining.** Otherwise punt to
v1.1 — room reactions are nice-to-have; DM reactions are the primary v1 win.

---

## 5. Dependency graph

```
S1 (schema) ──► S2 (CLI react/reactions) ──► S3 (MCP + inbox-id)
                          │                         │
                          └──────────────► S4 (room reactions, optional)
```

S2 depends on S1 (envelope shape). S3 depends on S2 (CLI helpers).
S4 depends on S2 + S3 (broadcast machinery + inbox-id surfacing).

**No slice may be skipped.** S1 is the riskiest because it touches signed
data; it MUST land + soak before S2 builds atop it.

## 6. Risk register

| # | Risk | Severity | Mitigation |
|---|------|---|---|
| 1 | v1 envelopes on disk break under v2 verifier | HIGH | Version-switched `canonical_blob`; golden test in S1 |
| 2 | `archive_entry` has no `message_id` field | HIGH | Extend record in S2, default None for legacy archives |
| 3 | Reaction DM loop (A reacts to B's reaction to A's msg) | MED | Reactions never trigger reactions; UI suppresses "react" button on event=reaction |
| 4 | Signing key reuse between peer-pass + sticker-react | LOW | Already shared via `C2c_signing_helpers`; same risk profile as today |
| 5 | Cross-host (post-#379) reactions dead-letter on old relays | MED | Relay capability bit `supports_reactions=true`; fall back to text DM `<sticker_id>` |
| 6 | `target_msg_id` collision (8-char prefix ambiguity) | LOW | CLI errors on ambiguous prefix; MCP tool requires full id |
| 7 | Schema migration of registry.json (reaction-only kinds) | MED | Slice S1 does NOT touch registry; widening palette is a separate slice (v1.1) |
| 8 | `by-msg` index gets out of sync with envelopes on disk | LOW | Index regenerable from envelopes; treat as cache, never source of truth |
| 9 | Old MCP clients (no `sticker_react` tool) silently fail | LOW | Doctor check: warn if client lacks tool; fall back to CLI path |

## 7. Peer-PASS criteria (per slice)

Per CLAUDE.md #427 Pattern 8: build-clean rc captured **inside the slice's
own worktree** in the artifact's `criteria_checked` list.

Each slice's peer-PASS DM must include:
- `build-clean-IN-slice-worktree-rc=0`
- `just test-one -k "sticker"` (or relevant pattern) green
- For S2/S3: a tmux E2E transcript snippet from `scripts/tui-snapshot.sh`
- For S1: golden-file diffs showing v1 envelopes still verify

## 8. Slice-1 ship readiness

S1 is **ready to spec into a worktree now**: pure data-layer change, no broker
or CLI surface, two well-bounded files, golden tests pin behaviour, and the
back-compat strategy is unambiguous (version-switched canonical_blob).

---

## 9. Open questions deferred from design doc

1. **Open vs closed registry palette** — defer to v1.1; v1 ships with existing
   9 entries (some already work for both appreciation and reaction, e.g.
   `on-point`, `good-catch`, `insight`).
2. **Unreact / tombstone semantics** — explicit non-goal in v1.
3. **Rate limiting** — slot it into S2's `append_to_by_msg_index` as a tuple
   uniqueness check `(target_msg_id, sticker_id, sender)`.
4. **`c2c react` top-level alias** — defer; reduce surface area for v1.

## 10. Subagent stub

- status: DONE
- output: this file
- in-progress marker: `.collab/research/SUBAGENT-IN-PROGRESS-sticker-react-plan.md`
  (caller may delete)
