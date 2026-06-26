# IMPL-REPORT: 4-level room visibility

## Final HEAD
- SHA: `87cc02c0df7e32cfd677a932d1761b5110b0b77e`
- Branch: `room-visibility-4level`
- Commits (3, author Max Kaye <m@xk.io>):
  - `6962b0f1` feat(rooms): 4-level visibility — core
  - `00c85744` test(rooms): 4-level visibility coverage
  - `87cc02c0` docs(rooms): 4-level visibility

SPEC file left untracked (not committed) as instructed.

## Build / test command results (run from worktree, dune -j 2)
| Command | Result |
|---------|--------|
| `dune build --root "$PWD" -j 2 @ocaml/all` | rc=0 (clean; warnings-as-errors) |
| `dune exec ./ocaml/test/test_c2c_mcp.exe` | Test Successful, 388 tests run, 0 failed |
| `dune exec ./ocaml/test/test_c2c_room_handlers.exe` | Test Successful, 28 tests run, 0 failed |
| `dune exec ./ocaml/test/test_relay.exe` | 43 passed, 0 failed |
| `C2C_BIN=… pytest tests/test_relay_signed_room_ops_gate.py -q` | 12 passed, 1 skipped |

## Model implemented
2x2 of listed-ness x join-gating: `Public | Unlisted | Gated | Private`.
- OLD `Public` -> `Public` (unchanged)
- OLD `Private` -> `Unlisted` (rename; unlisted + open join/read)
- OLD `Invite_only` -> `Private` (rename; unlisted + invite-gated)
- NEW `Gated` = listed for discovery (roster redacted to non-members) + invite-gated join + member-gated read.
Wire strings: `public`/`unlisted`/`gated`/`private`; `invite`/`invite_only`/`invite-only` parse to `Private` at every parse site.

## Files changed
Core (commit 1):
- ocaml/c2c_mcp_helpers.ml — variant + doc comment
- ocaml/c2c_mcp.mli — variant + invite_only comment
- ocaml/c2c_broker.ml — room_visibility_to_json/of_json (4 arms + synonyms); join-gate `invite_gated = Gated||Private`, reject string "requires an invite…"
- ocaml/c2c_room_handlers.ml — list_rooms filter (Gated redacted-to-non-member via shared `redacted_roster`; Unlisted hidden; Private as old Invite_only); room_history read-gate (shared `is_member_read`); set_room_visibility parse + serialize (4 arms)
- ocaml/c2c_mcp_helpers_post_broker.ml — 4 serialize arms
- ocaml/c2c_mcp.ml — list_rooms / set_room_visibility / send_room_invite tool descriptions + property doc
- ocaml/relay.ml — canonical_visibility (4 + synonyms→private) + doc block; InMemory & Sqlite list_rooms (public+gated); HTTP join-gate (open_join public/unlisted); error strings; HTML landing help
- ocaml/cli/c2c.ml — list match arm (4); `--visibility` docv + doc
- ocaml/cli/c2c_rooms.ml — all to-string/label arms; parse sites + error strings; arg docs; visibility cmd info
- ocaml/cli/c2c_watch_render.ml — abbrev pub/unl/gat/prv

Tests (commit 2):
- ocaml/test/test_relay.ml — canonical_visibility (4+synonyms); list_rooms public+gated listed / unlisted+private hidden (InMemory+Sqlite); NEW join-gating tests (InMemory + Sqlite) via `relay_admitted` predicate (mirrors HTTP gate) + is_invited/invite_to_room; ported create/override/set-visibility tests
- ocaml/test/test_c2c_mcp.ml — ported Invite_only→Gated/Private; legacy "invite" short-form now reads Private; NEW: gated listed-to-non-member roster-redacted, gated history blocks non-member, unlisted hidden-but-open-join+read
- ocaml/test/test_c2c_room_handlers.ml — visibility string passthrough cases (added private/unlisted/gated); header comment
- ocaml/cli/test_c2c_watch_render.ml — Invite_only→Private fixture
- tests/test_relay_signed_room_ops_gate.py — second signed identity; NEW gated-listed-but-uninvited-rejected, unlisted-not-listed-but-second-joins; public→gated stays listed; public→private hides; docstrings

Docs (commit 3):
- docs/connect.md, docs/communication-tiers.md, docs/overview.md, docs/relay-quickstart.md, docs/architecture.md, docs/commands.md — 2x2 table + 4-level wording; gated/private need an invite today (knock/request-to-join = backlog B004, not yet built).

## Deviations / notes
- **Relay join-gating tests (OCaml) use a predicate helper, not the HTTP handler.** The relay backend `join_room` (InMemory/Sqlite) does NOT gate by invite — the admission gate lives in the HTTP `handle_join_room`. The OCaml relay test exercises the gate's data-layer building blocks (`room_visibility_of` + `is_invited` + `invite_to_room`) through a local `relay_admitted` predicate that mirrors the handler's `open_join || is_invited`. The end-to-end HTTP gate (uninvited rejected for gated, open for unlisted) is covered for real in the Python e2e via signed `/join_room` with a second identity. This is the most faithful coverage achievable at each layer's granularity.
- **Docs left intentionally unchanged:** docs/changelog.md:114 (historical release entry) and docs/docker-testing.md:104 (descriptive test-name reference "invite-only ACL"). Other `docs/c2c-research/*` and `docs/superpowers/specs/*` are internal/historical research docs, not public level-enumerations.
- **Pre-existing build noise:** `ocaml/relay_e2e.ml` emits partial-match/redundant-case warnings printed as text during `@ocaml/all`; these are pre-existing, unrelated to this change, and do not fail the build (rc=0).
- No spec items left incomplete.
