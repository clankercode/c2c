# SPEC: 4-level room visibility (public / unlisted / gated / private)

Replaces the 3-level model (`public` / `private` / `invite_only`). **No DB cutover/migration** — relay will be redeployed; old persisted rooms may flip meaning, that's accepted.

## Semantic model (2×2)

|              | open-join   | invite-gated |
|--------------|-------------|--------------|
| **listed**   | `public`    | `gated`      |
| **unlisted** | `unlisted`  | `private`    |

- **public**   = listed + open join + open read
- **unlisted** = NOT listed + open join + open read
- **gated**    = listed + invite-gated join + member-gated read
- **private**  = NOT listed + invite-gated join + member-gated read

`listed` ⇒ appears in `list_rooms`. `invite-gated` ⇒ join requires being on the invite list; history read requires membership.

## Local-broker variant rename (`room_visibility`)

OLD `Public | Private | Invite_only` → NEW `Public | Unlisted | Gated | Private`

- OLD `Public`       → `Public`   (unchanged)
- OLD `Private`      → `Unlisted` (rename; SAME semantics = unlisted+open)
- OLD `Invite_only`  → `Private`  (rename; SAME semantics = unlisted+invite)
- NEW `Gated`        (listed + invite-gated)

So existing `Invite_only` behavior is preserved EXACTLY under the new name `Private`; existing `Private` behavior is preserved EXACTLY under the new name `Unlisted`. Only genuinely-new code path is `Gated`.

## Canonical / wire strings

`"public"` / `"unlisted"` / `"gated"` / `"private"`.

Parse synonyms (back-compat, every parse site): `"invite" | "invite_only" | "invite-only"` → **Private** (these old tokens meant unlisted+invite = new private). Old `"private"` string now parses to **Private** (new meaning) — accepted, no special handling.

## Per-site changes (exhaustive — build is warnings-as-errors, so a missed match arm fails compilation)

### ocaml/relay.ml
1. `canonical_visibility` (~88): accept `public|unlisted|gated|private`, plus `invite|invite_only|invite-only → "private"`; unknown → `None`. Update the doc-comment block (~79-87) to the 4-level model.
2. InMemory `list_rooms` (~1294): list when `visibility = "public" || visibility = "gated"` (was: skip unless `"public"`).
3. Sqlite `list_rooms` (~2345): `SELECT room_id FROM rooms WHERE visibility IN ('public','gated')`.
4. join-gate (~4202): `let open_join = visibility = "public" || visibility = "unlisted" in let admitted = open_join || is_invited`. (gated & private both require invite.) Update the nearby comments (~4196, error string ~4208 "invite-only" → "requires an invite").
5. Error strings (~4181, ~4226): `"visibility must be \"public\", \"unlisted\", \"gated\", or \"private\""`.
6. HTML help (~3236-3238): update the `<code>` list + "Only public rooms appear…" → "Only public and gated rooms appear in /list_rooms; unlisted and private rooms stay reachable by id but never listed."

### ocaml/c2c_mcp_helpers.ml (~104) + ocaml/c2c_mcp.mli (~176)
`type room_visibility = Public | Unlisted | Gated | Private`. Update the doc comment (~101-103) to the 4-level semantics.

### ocaml/c2c_broker.ml
1. `room_visibility_to_json` (~3330): Public→"public", Unlisted→"unlisted", Gated→"gated", Private→"private".
2. `room_visibility_of_json` (~3335): `"unlisted"→Unlisted`, `"gated"→Gated`, `"private"→Private`, `"invite"|"invite_only"|"invite-only"→Private`, `_→Public`.
3. join-gate (~3470): `let invite_gated = meta.visibility = Gated || meta.visibility = Private in if invite_gated && not already_member then if not (List.mem alias meta.invited_members) then invalid_arg (...)`. Update reject string to "…requires an invite and '…' is not on the invite list".

### ocaml/c2c_room_handlers.ml
1. `list_rooms` filter (~248). Behavior per variant:
   - `Public  -> Some r`
   - `Unlisted -> if is_member then Some r else None`
   - `Gated -> if is_member then Some r else Some { r with ri_members=[]; ri_member_details=[]; ri_invited_members=[]; ri_alive_member_count=0; ri_dead_member_count=0; ri_unknown_member_count=0 }` — i.e. LISTED to everyone (room_id + ri_member_count retained for discovery) but roster redacted for non-members.
   - `Private -> ` EXACTLY the old `Invite_only` branch (member→Some r; invited-not-joined→redacted Some; unrelated→None).
   Update the doc comment block (~223-231) to describe all four.
2. `room_history` read-gate (~311):
   - `Public -> true`
   - `Unlisted -> true` (open read)
   - `Gated -> ` membership check (same as old Invite_only branch)
   - `Private -> ` membership check (same as old Invite_only branch)
   Factor the membership check so Gated and Private share it.
3. `set_room_visibility` parse (~386): add `"unlisted"→Unlisted`, `"gated"→Gated`; keep `"private"→Private`; `"invite"|"invite_only"|"invite-only"→Private`. Preserve current fallback for unknown input (do not change validation strictness).
4. serialize arm (~414): 4 arms.

### ocaml/c2c_mcp_helpers_post_broker.ml (~595)
4 arms Public/Unlisted/Gated/Private → matching strings.

### ocaml/c2c_mcp.ml (tool descriptions/schema)
- `list_rooms` description (~88): rewrite to 4-level (public+gated listed; gated roster redacted for non-members; unlisted hidden from non-members; private hidden, with invited-pre-join redacted rows).
- `set_room_visibility` description (~120): "public = listed + open join; unlisted = unlisted + open join; gated = listed + invite-gated join; private = unlisted + invite-gated join. Only existing room members can change visibility."
- property doc (~122): "One of 'public', 'unlisted', 'gated', or 'private'."
- `send_room_invite` description (~116): update "invite-only rooms" → "gated and private rooms".

### ocaml/c2c_mcp.mli (~532) — comment "invite_only" → "gated/private".

### ocaml/cli/c2c.ml
- (~3413) match arm Invite_only → 4 arms.
- (~4927) `--visibility` arg: `~docv:"public|unlisted|gated|private"` and doc: "Room visibility: 'public' (listed + open join), 'unlisted' (unlisted + open join), 'gated' (listed + invite-gated join), or 'private' (unlisted + invite-gated join). Required for set-visibility; optional for join, where it applies only when the join creates the room."

### ocaml/cli/c2c_rooms.ml
- All to-string match arms (~342-344, ~395-397, ~588-590, ~743-745, ~754-756): 4 arms each.
- All label arms (~355-357, ~408-410): Public→"" / Unlisted→" [unlisted]" / Gated→" [gated]" / Private→" [private]".
- Parse sites (~574, ~710): add `"unlisted"→Unlisted`, `"gated"→Gated`, keep `"private"→Private`, synonyms `invite*→Private`; update error strings (~577, ~713) to "Use 'public', 'unlisted', 'gated', or 'private'."
- Arg docs (~560, ~684-685, ~689): 4-level wording; (~689) "For invite_only rooms" → "For gated and private rooms".
- `rooms_visibility` cmd info (~782): "(public, unlisted, gated, or private)".

### ocaml/cli/c2c_watch_render.ml (~543)
Abbrev: `Public→"pub"`, `Unlisted→"unl"`, `Gated→"gat"`, `Private→"prv"`. Update the comment (~540-541).

## Docs (docs/*.md)
Update every place that enumerates the 3 levels to the 4-level model with the 2×2 table above. Known files: `docs/connect.md`, `docs/relay-quickstart.md`, `docs/commands.md`, `docs/overview.md`, `docs/architecture.md`, `docs/communication-tiers.md`. Grep `git grep -ln "invite_only\|invite-only\|unlisted" docs/` to find all. Mention `gated` requires an invite to join today (knock/request-to-join is backlog B004, not yet built).

## Tests (must build + pass; warnings-as-errors)

Rename existing wire values, and ADD coverage for the new cells. Aim:

### ocaml/test/test_relay.ml
- Update `canonical_visibility_normalizes` for the 4 canonical values + synonyms (invite*→private).
- `list_rooms` now returns public AND gated; hides unlisted AND private. (InMemory + Sqlite.)
- ADD: gated join is invite-gated (uninvited rejected, invited admitted); unlisted join is OPEN (uninvited admitted) but NOT listed; private join invite-gated + NOT listed. (InMemory + Sqlite.)
- Keep create-on-join / no-override-after-create tests, ported to new values.

### ocaml/test/test_c2c_mcp.ml
- Port existing private/invite_only tests to Unlisted/Private names.
- ADD: `gated` room is LISTED via list_rooms to a non-member (roster redacted), join rejected for uninvited / accepted for invited, room_history blocked for non-member.
- ADD: `unlisted` room hidden from non-member list_rooms but a non-member can JOIN it (open join) and read history.
- Keep: `private` hidden from non-member list, invite-gated join, member-gated history.

### ocaml/test/test_c2c_room_handlers.ml
- Update any visibility match/value references to the new variants.

### tests/test_relay_signed_room_ops_gate.py (SignedRoomVisibilityE2ETests)
- Update signed-join values. ADD a `gated` case: signed join --visibility=gated by creator → room IS listed; a second (non-invited) signed identity join is REJECTED; an unlisted room is NOT listed but a second identity joins OK. Keep set_visibility test (now e.g. public→gated still listed, or public→private hides).

## Build + test commands (run from the worktree)
- Build: `opam exec -- dune build --root "$PWD" -j 2 @ocaml/all`  (rc must be 0)
- OCaml: `opam exec -- dune exec --root "$PWD" ./ocaml/test/test_c2c_mcp.exe` and `./ocaml/test/test_c2c_room_handlers.exe` and `./ocaml/test/test_relay.exe` (0 failed)
- Python e2e: `C2C_BIN="$PWD/_build/default/ocaml/cli/c2c.exe" python3 -m pytest tests/test_relay_signed_room_ops_gate.py -q`
