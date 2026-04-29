# Design: refactor `c2c_mcp.ml` mega-dispatch

stanza-coder, 2026-04-29 — design only, no code changes.
File under review: `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml`
Audit receipt: `.collab/research/2026-04-29-stanza-coder-c2c-mcp-code-health.md` §1

---

## 1. Current state

The MCP tool dispatch is a single `match tool_name with ...` chain
inside `handle_tool_call` at `c2c_mcp.ml:4992`, terminating at line
`6869` (the final `| _ ->` unknown-tool fallback). The chain spans
roughly **1880 LOC**.

- Top-level arms (distinct tool names): **34**
  (`register`, `list`, `send`, `send_all`, `whoami`, `debug`,
  `poll_inbox`, `peek_inbox`, `history`, `tail_log`, `server_info`,
  `sweep`, `prune_rooms`, `set_dnd`, `dnd_status`, `join_room`,
  `leave_room`, `delete_room`, `send_room`, `list_rooms`,
  `my_rooms`, `room_history`, `send_room_invite`,
  `set_room_visibility`, `open_pending_reply`,
  `check_pending_reply`, `set_compact`, `clear_compact`,
  `stop_self`, `memory_list`, `memory_read`, `memory_write`).
- Plus inner sub-dispatches inside `debug` (`send_msg_to_self`,
  `send_raw_to_self`, `get_env`) and inside `set_room_visibility`
  on the `mode` arg.
- Average arm length: **~55 LOC** (1880 / 34). The five fattest:
  `send` 239, `register` 211, `debug` 131, `memory_list` 119,
  `memory_read` 109. Median ~40 LOC.
- `handle_tool_call` itself is one function with no top-level
  refactoring boundary: every arm reads from `~broker`,
  `~session_id_override`, `~tool_name`, `~arguments` directly out
  of the closure. Many arms also call module-level helpers
  (`resolve_session_id`, `alias_for_current_session_or_argument`,
  `optional_string_member`, `tool_result`, …) defined ~600 LOC
  upstream.

### Repeated boilerplate patterns

Counted over the dispatch body:

| Pattern | Sites | Notes |
|---|---|---|
| `resolve_session_id ?session_id_override arguments` | 14 | Almost always immediately followed by `Broker.touch_session broker ~session_id`. See audit §3. |
| `Broker.touch_session broker ~session_id` | 14 | Pair-bound with the line above. |
| `current_session_id ()` triple-nested fallback (override → env → error) | 3+ | Same shape repeated verbatim in `peek_inbox`, `history`, `my_rooms`. |
| `optional_string_member "<key>" arguments` arg-extraction | ~50 | Plus `string_member`, `string_member_any`, `bool_of_arg`, `int_opt_member`. |
| `tool_result ~content:... ~is_error:true/false` | 50 | 35 ok, 15 err. Audit §4 proposes `tool_ok` / `tool_err` smart constructors. |
| `Lwt.return (tool_result …)` wrap | every arm | All arms return `_ Lwt.t`. |
| Hand-rolled `try … match Yojson.Safe.Util.member k arguments with \| `Bool b -> b \| _ -> default` | ~8 | One per "optional bool field". `send` alone has 3 (`deferrable`, `ephemeral`, plus the `tag` string variant). |
| `missing_sender_alias_result` / `missing_member_alias_result` | ~10 | Mostly fine — already extracted — but the surrounding `match alias_for_current_session_or_argument …` is repeated. |
| Permission/identity guards (reserved alias check, impersonation check, casefold lookup) | concentrated in `register`/`send`/`join_room` | Not generic; flagged here because they're often the *reason* an arm is large. |

The combined effect: every arm spends 8–25 LOC doing argument
extraction + session resolution + permission checks **before** the
broker call, then 5–15 LOC formatting the response, with maybe 5–60
LOC of actual logic in the middle. The signal-to-noise ratio in the
dispatch body is low.

---

## 2. Goals & non-goals

### Goals

- **Less boilerplate per arm.** Argument extraction + session
  resolution + response-shaping should each appear once, not 34
  times.
- **Easier to add a new tool.** Today: scroll to ~line 6800 in
  `c2c_mcp.ml`, copy a similar arm, edit fields, hope you didn't
  forget `Broker.touch_session`. After: a single function (or
  module) plus one registration line.
- **Single place for arg validation.** Typed decoder per common
  argument shape (`alias`, `session_id`, `room_id`, `message_id`,
  `to_alias`/`alias` fallback) so a typo'd field name fails the
  same way every time.
- **Clearer ownership / topical grouping.** Send/poll/inbox vs
  rooms vs memory vs admin vs session-lifecycle — these are five
  feature areas, currently interleaved alphabetically-ish.
- **Per-tool unit testability.** Today, every test goes through
  the full JSON-RPC `tools/call` envelope. After: each handler
  callable with `(broker, session_id, args_json) → Lwt result`.

### Non-goals

- **Do NOT change externally observable JSON shapes.** Every tool
  must return byte-identical (or semantically-identical) JSON
  before/after. The 276-test broker suite is the contract.
- **Do NOT break existing tools.** The `unknown tool` fallback
  must still exist; tool names + their argument names are wire
  contract.
- **Do NOT rewrite the broker logic.** This refactor stays above
  `Broker.*` — the inside of each arm changes shape but not
  semantics.
- **Do NOT change the dispatch entrypoint signature.**
  `handle_tool_call ~broker ~session_id_override ~tool_name
  ~arguments` is called from `handle_request` (line 7022) and the
  RPC log path (line 7036) — that signature is the public surface
  of this module. The refactor is internal.
- **Do NOT introduce a build-system change** (preprocessor,
  ppx_deriving, codegen). Plain OCaml; minimum churn.
- **Do NOT change Tier filtering** — that's enforced at the CLI
  level (`c2c.ml`), not inside the MCP dispatch.

---

## 3. Design options surveyed

### Option A — Per-tool handler functions in a registry

Each arm becomes a top-level function in `c2c_mcp.ml` (or a few
sub-modules):

```ocaml
let handle_send ~broker ~session_id_override ~arguments : tool_result Lwt.t =
  …current body of the "send" arm…

let handle_poll_inbox ~broker ~session_id_override ~arguments =
  …current body of the "poll_inbox" arm…
```

Dispatch becomes:

```ocaml
let tool_registry : (string * tool_handler) list = [
  "register",            handle_register;
  "send",                handle_send;
  "send_all",            handle_send_all;
  "poll_inbox",          handle_poll_inbox;
  …
]

let handle_tool_call ~broker ~session_id_override ~tool_name ~arguments =
  match List.assoc_opt tool_name tool_registry with
  | Some f -> f ~broker ~session_id_override ~arguments
  | None ->
      Lwt.return (tool_result
        ~content:("unknown tool: " ^ tool_name) ~is_error:true)
```

Where `tool_handler` is the alias

```ocaml
type tool_handler =
  broker:Broker.t ->
  session_id_override:string option ->
  arguments:Yojson.Safe.t ->
  tool_result Lwt.t
```

**Pros**
- Every handler is reviewable in isolation (a 200-LOC `send` patch
  no longer scrolls past 400 LOC of unrelated arms).
- Adding a tool: write the function, add one line to the registry.
- Handlers are directly callable from unit tests without going
  through JSON-RPC.
- Low-churn migration: each arm move is mechanical.
- No new abstractions for callers to learn — just functions.

**Cons**
- Tool name appears twice (definition + registry line). Drift
  risk is low because the registry is the source of truth and a
  missing entry surfaces as `unknown tool`.
- Arms that share local bindings (e.g. the inline helper in
  `debug` for choosing a sub-mode) need each become first-class —
  not a real downside, just a one-time cleanup.

### Option B — Module-per-tool with a `TOOL_HANDLER` signature

```ocaml
module type TOOL_HANDLER = sig
  val name : string
  val handle :
    broker:Broker.t ->
    session_id_override:string option ->
    arguments:Yojson.Safe.t ->
    tool_result Lwt.t
end

module Tool_send : TOOL_HANDLER = struct
  let name = "send"
  let handle ~broker ~session_id_override ~arguments = …
end

let tool_registry : (module TOOL_HANDLER) list = [
  (module Tool_register); (module Tool_send); …
]
```

**Pros**
- Strongest isolation — each tool gets its own file
  (`mcp_tool_send.ml`), own test file (`test_mcp_tool_send.ml`),
  own helper bindings without polluting top-level.
- Future evolution (per-tool metadata: tier, schema, capabilities)
  goes in the module signature naturally.
- Slice ownership maps onto file ownership.

**Cons**
- Heavier per-tool boilerplate (module declaration, 1st-class
  module pack).
- 34 new files in `ocaml/`. Cognitive cost when `grep`-ing for
  cross-tool patterns.
- First-class modules in a list is a slightly less idiomatic
  OCaml pattern; reviewers unfamiliar with it will pause.
- Migration is heavier per tool than Option A.

### Option C — Shared decoders + thin arms (keep central `match`)

Don't restructure the dispatch. Instead, kill the noise inside
each arm:

```ocaml
type send_args = { to_alias: string; content: string;
                   deferrable: bool; ephemeral: bool;
                   tag: string option }

let decode_send_args args : (send_args, string) result = …

(* in dispatch *)
| "send" ->
    (match decode_send_args arguments with
     | Error e -> Lwt.return (tool_err ("send: " ^ e))
     | Ok a ->
         with_session ?session_id_override broker arguments
           (fun ~session_id -> Send_logic.handle ~broker ~session_id a))
```

Plus the helpers from audit §3 / §4: `with_session`, `tool_ok`,
`tool_err`.

**Pros**
- Smallest blast radius — the `match` keeps its current shape.
- Decoders are independently unit-testable.
- Doesn't preclude Option A later — in fact it sets it up: the
  decoders + business-logic functions are exactly what Option A's
  `handle_*` functions would call.

**Cons**
- The `match` itself stays ~1900 LOC. Even with thin arms, end-to-end
  readability of the dispatch is bounded by file length.
- Doesn't deliver the per-tool unit-test surface (tests still go
  through `handle_tool_call` to exercise the dispatch routing).

### Option D — Effect-handler chain / monadic pipeline

E.g. an Lwt-friendly `Reader`-style monad threading `broker`,
`session_id`, `arguments`, returning a `tool_result`. Or
delimited-continuation style with OCaml 5 effects.

**Dismissed.** OCaml's stdlib ergonomics for monadic stacking are
unfriendly (no `let%bind` without ppx); effects in OCaml 5 are
fine for runtime but a big readability tax for 34 mostly-flat
handlers. Pays infrastructure cost without solving the readability
problem.

---

## 4. Recommendation: phased C-then-A

**Land Option C first (1–2 slices), then move to Option A
(several slices grouped by feature area).**

Rationale:

- C alone delivers the highest leverage-per-LOC: `with_session`,
  `tool_ok` / `tool_err`, and 4–5 typed decoders covering the most
  common arg shapes will visibly thin the dispatch without moving
  any code. This matches the audit's recommended **first slice**
  (audit §1 + §3 + §4).
- C makes A trivial: once decoders exist, an Option A handler is
  literally `decode + business + format` — three lines for the
  outer shape of any handler.
- A alone risks landing 34 mechanical-but-still-large files
  before the boilerplate has been removed; reviewers would have to
  re-grep the same patterns 34 times.
- Option B's per-module structure can be reconsidered after A
  lands and we know which tools have grown enough metadata
  (schema, tier, capability gates) to justify the module shape.
  Today none of them do.

### Edge cases the recommendation handles

- **Tools that share state mid-arm** (e.g. `register` updates
  rooms after computing `old_alias_opt`): handled in Option A by
  letting the handler hold whatever local bindings it needs —
  it's just a function.
- **Tools that need raw JSON** (`debug` reaches into `arguments`
  for an opcode field; `set_room_visibility` reads `mode`): the
  decoder layer is opt-in. A handler that needs raw JSON just
  takes `~arguments` and uses it directly.
- **Tools with sub-dispatch** (`debug`'s
  `send_msg_to_self`/`send_raw_to_self`/`get_env`): keep the
  sub-`match` inside `handle_debug`. The mega-dispatch refactor
  doesn't propagate inward.
- **Lwt-aware vs sync helpers**: `with_session` needs an
  Lwt-returning variant (call `f` returning `_ Lwt.t`). Provide
  both, naming convention `with_session_lwt`.

---

## 5. Migration plan

Each phase is one or more slices, each landed under
`.worktrees/<slice>/`, peer-reviewed (`review-and-fix`),
coord-cherry-picked. Tests must pass at every commit boundary.

### Phase 0 — capture baseline (pre-refactor)

- Run the full broker test suite: `just test`.
- Capture `dune build 2>&1 | tee /tmp/c2c-mcp-warnings-pre.txt`.
- Snapshot a representative subset of MCP RPC responses to a
  fixture file (e.g. drive 5–10 tools through `c2c debug
  send_raw_to_self` style probe and stash the JSON outputs). This
  becomes the "observably-equivalent" anchor for §6.

### Phase 1 — Option C foundation (small, low-risk)

Slice 1a: helpers (audit §3 §4 §5)
  - Add `with_session`, `with_session_lwt`.
  - Add `tool_ok`, `tool_err`, `tool_ok_json`.
  - Replace 14 `resolve_session_id` + `Broker.touch_session`
    sites; replace 50 `tool_result ~content:... ~is_error:...`
    sites.
  - Land `default_permission_ttl_s` named constant.
  - **Net diff**: ~150 LOC removed, ~50 added; warning 26
    cleared on `entry_path`.
  - **Risk**: very low (mechanical replace_all + grep audit).

Slice 1b: typed decoders for the 5 most-common arg shapes
  - `decode_alias_args` (covers `alias`, `to_alias`, fallback
    list).
  - `decode_room_args` (covers `room_id`, `mode`).
  - `decode_message_args` (covers `content`, `tag`, `deferrable`,
    `ephemeral`).
  - `decode_pending_perm_args` (covers `permission_id`).
  - `decode_memory_args` (covers `name`, `body`, `shared`,
    `shared_with`).
  - Each decoder is a `Yojson.Safe.t -> (record, string) result`.
  - Apply only at sites where the decode is unambiguous; leave
    custom-shape arms (`debug`, `set_room_visibility`) alone.
  - **Net diff**: ~200 LOC added (decoders + tests), ~250 removed
    (per-arm extraction).
  - **Risk**: low. Decoders are pure; unit-tested in isolation.

### Phase 2 — Option A pilot, ONE feature area

Slice 2: extract memory handlers (`memory_list`, `memory_read`,
`memory_write`, ~340 LOC)
  - Audit §1 calls this out as the natural first slice (~1.5–2h).
  - Move the three arms into `let handle_memory_*` functions
    above the dispatch (or into `Mcp_handlers_memory.ml` if we're
    ready to commit to sub-modules — see Phase 4).
  - Add registry list pattern locally for these three; the rest
    of the dispatch keeps its `match` until later phases land.
  - **Acceptance**: memory tests (`just test-one -k memory`) pass
    bit-identical. Manually drive `mcp__c2c__memory_list` from a
    live session, diff JSON against pre-refactor snapshot.
  - **Risk**: low. Memory handlers have no cross-tool state.

### Phase 3 — extend Option A by feature area

Each slice = one feature area, one worktree, one PR-equivalent.
Order chosen by independence + size:

1. **Stickers / pending-permissions** (`open_pending_reply`,
   `check_pending_reply`, `peer_pass_*`, `relay_pin_*` —
   anything in the permissions/pinning space). Self-contained
   state.
2. **Rooms** (`join_room`, `leave_room`, `delete_room`,
   `send_room`, `list_rooms`, `my_rooms`, `room_history`,
   `send_room_invite`, `set_room_visibility`, `prune_rooms`).
   ~9 arms, ~400 LOC. Big readability win.
3. **Inbox + history** (`poll_inbox`, `peek_inbox`, `history`,
   `tail_log`, `server_info`, `sweep`).
4. **Session lifecycle** (`set_dnd`, `dnd_status`, `set_compact`,
   `clear_compact`, `stop_self`, `pin_rotate`).
5. **Send + identity** (`register`, `send`, `send_all`, `whoami`,
   `list`, `debug`). Save for last because `register` and `send`
   are the two largest, most-tested arms — moving them benefits
   most from the patterns established earlier.

Each slice: extract handlers, add to registry, delete the old
arms from the central `match`, run `just test`, peer-PASS,
coord-cherry-pick.

### Phase 4 — optional Option B layering

Only if a concrete need materialises (per-tool metadata,
capability gates, tier annotations on the tool itself rather than
the CLI surface). Otherwise: stop at Phase 3. Don't bikeshed 34
files into existence without a reason.

---

## 6. Test strategy

The 276 broker tests are the contract. They drive `handle_request`
through the JSON-RPC envelope, which calls `handle_tool_call`,
which dispatches into each arm. They observe JSON output. **They
should pass unchanged through every phase of this refactor.**
That's the primary gate.

Supplementary checks:

- **Phase 0 snapshot.** Capture sample JSON outputs from a
  representative tool set before any refactor, store under
  `test/fixtures/mcp_dispatch_baseline/`. Replay after each phase
  and `diff` byte-for-byte. Differences trigger an immediate halt
  and root-cause investigation.
- **Per-handler unit tests.** Once Option A lands, each
  `handle_<tool>` is directly callable with a synthetic broker.
  Add lightweight unit tests covering at least the happy path +
  one error path per handler. These run in milliseconds and catch
  regressions before the integration suite.
- **Decoder unit tests** (Phase 1b). Exercise each decoder with
  malformed JSON, missing fields, type mismatches, empty strings.
- **`dune build` warning count.** Must monotonically decrease
  through the refactor (never increase). Phase 1a fixes warning
  26; Phase 2+ should not introduce new warnings.
- **Manual live-peer smoke** at the end of each phase: spawn a
  tmux peer via `scripts/c2c_tmux.py`, drive every refactored
  tool from it, confirm responses are normal. Required by
  CLAUDE.md "If it's not tested in the wild, it's not done!"

---

## 7. Risks & open questions

- **Performance: `List.assoc_opt` vs `match`.** With 34 entries
  and string keys, `List.assoc_opt` is O(n) string comparisons
  per dispatch — a few hundred nanoseconds. The compiled `match`
  is also a linear chain of string comparisons (OCaml does not
  generate a perfect hash for string match). Difference is below
  the noise floor of any real broker call (which does file I/O).
  If we ever care, swap `List.assoc_opt` for `Hashtbl.find_opt`
  in 30 seconds. **Verdict: negligible.**
- **Sub-tool name collisions.** None today (the only inner
  dispatches are inside `debug` on a `kind` field, scoped). Add a
  guard: registry construction asserts unique tool names at
  startup.
- **Tier filter interaction.** Tier filtering is enforced at the
  CLI command level in `c2c.ml`, not inside the MCP dispatch.
  This refactor doesn't touch Tier. *Open*: if MCP ever grows
  tool-level tiering (Tier per `mcp__c2c__*`), the per-tool
  registry is the natural place for it (each entry could be
  `(name, tier, handler)`). Note for future, do not implement
  speculatively.
- **`experimental.*` capability hooks.** The MCP `initialize`
  flow already negotiates capabilities (e.g.
  `experimental.claude/channel`). Tool-level capability gating
  could naturally attach to a registry entry. Today it isn't
  needed; revisit only if a new tool requires it.
- **Window where dispatch is partly migrated.** During Phase 3,
  some tools live as `handle_<tool>` functions and others as `|
  "<tool>" ->` arms. The dispatch becomes a hybrid:

  ```ocaml
  match List.assoc_opt tool_name registry with
  | Some f -> f …
  | None ->
      match tool_name with
      | "<unmigrated_tool>" -> …
      | _ -> Lwt.return (unknown_tool …)
  ```

  Acceptable per-slice landing cost. Document the hybrid in a
  short comment at the dispatch site.
- **`session_id_override` is ergonomically awkward** (warning 16
  on the optional argument, audit §6). Per audit, leave alone for
  this refactor. Could be revisited in a separate slice.
- **Open Q: should we add a `pre_dispatch_hook` for
  cross-cutting concerns** (RPC logging, metrics, audit)? Not
  needed today — `log_rpc` already runs after dispatch in
  `handle_request`. Note as future work, do not implement now.

---

## 8. Receipts

- Audit: `.collab/research/2026-04-29-stanza-coder-c2c-mcp-code-health.md` §1, §3, §4.
- Source under refactor: `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml` lines 4992–6869 (mega-dispatch); helpers at 4860–4900, 290 (`tool_result`).
- Related design (none directly cover the dispatch shape today):
  - `.collab/design/2026-04-26T09-42-29Z-stanza-coder-303-channel-push-dm-ordering.md` — touches `send` arm semantics (deferrable flag).
  - `.collab/design/2026-04-29-432-slice-b-pending-perms-auth-stanza.md` — recent additions to `open_pending_reply` / `check_pending_reply` arms.
- CLAUDE.md ground rules respected: no JSON-shape change (wire
  contract), Tier filter unchanged (top-level CLI only), tests
  remain the gate. Migration is sliceable per
  `.collab/runbooks/branch-per-slice.md`.

— stanza-coder, 2026-04-29
