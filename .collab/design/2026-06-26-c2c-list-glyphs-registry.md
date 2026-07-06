# Design — `c2c list-glyphs`: canonical TUI glyph registry + `--dev` help flag

**Date:** 2026-06-26 · **Branch:** `cli-list-glyphs` (off `origin/master` b75c019a)
**Author:** (Max-driven session)

## Motivation

pi-c2c (and future clients) hardcode the c2c TUI glyph vocabulary (message
direction, broker route, liveness, subagent-registration). c2c should be the
**single source of truth**: a `c2c list-glyphs` subcommand emits a
pretty-printed JSON registry that a client can fetch at launch to render c2c
lines consistently — descriptions included so agents can also use the glyphs
in their own output. Today the values live in
`pi-c2c/src/ui/{compact-message,tool-renderers,compact-subagent-registration}.ts`;
this command must reproduce them **byte-for-byte** so swapping pi-c2c to fetch
them changes nothing visually.

## Hard constraint — always runnable, regardless of session

pi-c2c spawns `c2c` with `env: process.env` (`pi-c2c/src/c2c-bin.ts:88`). If the
host session exports a session-id env var, `is_agent_session ()`
(`ocaml/cli/c2c_commands.ml:114`) returns true and `filter_commands`
(`c2c_commands.ml:118`) **drops Tier3/Tier4 commands from the dispatchable
cmdliner group** — i.e. they become *unrunnable*, not merely unlisted. Therefore
`list-glyphs` MUST NOT be a Tier3/Tier4 command. It is read-only and side-effect
free → classify it **Tier1** (always in the group, always runnable).

"Hidden from help by default" is thus **decoupled from the tier filter** and
handled purely in the help-text layer (below).

## Surface

```
c2c list-glyphs            # pretty JSON registry to stdout, exit 0
c2c list-glyphs --compact  # single-line JSON (optional convenience; Yojson.Safe.to_string)
```

- Always runnable in any session (Tier1).
- **Omitted** from the curated `c2c commands` listing and from the
  `tier_grouped_man` block in `c2c --help` **unless `--dev` is present.**
- A new global `--dev` flag reveals dev/hidden entries in those curated
  listings. Implement by mirroring the existing `--all`/`is_all` argv pre-scan
  in `fast_path_commands` (`c2c.ml:12068`) and `commands_by_safety_cmd`
  (`c2c.ml:315`), plus the `commands_man` text (`c2c.ml:11946`).
- Hiding mechanism: a small `hidden_unless_dev : string list = ["list-glyphs"]`
  set, orthogonal to the tier map. The curated renderers skip names in this set
  unless `--dev` (or `--all`) was passed. This keeps the command Tier1/runnable
  while de-emphasising it in help.
- **Open impl detail (implementer resolves in code):** cmdliner auto-generates a
  `COMMANDS` block in `c2c --help` listing every group member with its `~doc`.
  Determine whether this CLI already suppresses/curates that (it hand-rolls
  `tier_grouped_man`). Preferred: give `list-glyphs` a terse `~doc` like
  `"(dev) emit the canonical TUI glyph registry as JSON"` and, if cmdliner still
  auto-lists it, that's acceptable — the curated `c2c commands` listing is the
  contract that must hide it by default. Do NOT contort the tier filter to hide
  it (that breaks runnability).

## JSON schema (v1) — exact values

`schema_version: 1`. Top-level keys: `description`, `ascii_fallback`, `colors`,
`container`, `actions`, `directions`, `routes`, `liveness`,
`subagent_registration`, `message_sources`. Each glyph entry carries `glyph`,
`ascii` (fallback), an optional semantic `color`, and a `description`
(meaning/intent). Values below are authoritative (copied from pi-c2c):

| group | key | glyph | ascii | color | meaning |
|---|---|---|---|---|---|
| container | (line marker) | `⧓` | `o` | accent | leads every collapsed c2c line: `⧓ c2c.<action> · …` |
| container | channel | `c2c` | `c2c` | accent | the channel token |
| container | separator | ` · ` | ` . ` | borderMuted | field separator |
| direction | incoming | `▼` | `v` | success | a message arriving at this session (`recv`) |
| direction | outgoing | `▲` | `^` | accent | a message leaving this session (`send`) |
| direction | broadcast | `✶` | `*` | warning | a 1:N broadcast (`send_all` / `recv-all`) |
| direction | status | `●` | `o` | borderMuted | a peer status/runtime envelope (not chat) |
| arrow | incoming | `←` | `<-` | (dir color) | points at the receiver |
| arrow | outgoing | `→` | `->` | (dir color) | points at the target |
| route | local | `⌂` | `[local]` | success (green) | via your per-repo home broker (same repo+machine) |
| route | sessions | `◎` | `[sessions]` | borderMuted (grey) | via the cross-repo sessions broker (a *known* route) |
| route | relay | `⇄` | `[relay]` | accent (cyan) | via the public/remote relay (cross-machine); relay aliases are full addresses `<name>@<hosthash>` |
| route | **unknown** | `◌` | `[?]` | borderMuted (grey) | route could NOT be determined from the message alone (e.g. an inbound bare alias with no `@<host>` suffix). Distinct from `sessions`, which asserts the cross-repo broker. NEW glyph — see note below. |
| liveness | alive | `●` | `o` | success | peer currently reachable |
| liveness | dead | `○` | `o` | muted | registered but not currently reachable |
| subagent | container | `⧓` | `o` | accent | leads a subagent-registration line |
| subagent | fork | `↳` | `->` | (theme) | a subagent forked under a parent |
| subagent | mapping | `→` | `=>` | (theme) | maps subagent → parent alias |
| subagent | bullet | `›` | `>` | (theme) | list-item separator |

- `actions` (the `c2c.<action>` token): `recv` (inbound 1:1), `send` (outbound
  1:1), `recv-all` (inbound broadcast), `send-all` (outbound broadcast),
  `send-room` (outbound room), `status` (peer status update). Each with a
  one-line description.
- `colors`: map of semantic name → human description
  (`success`=green/home·alive, `accent`=cyan/relay·outgoing,
  `warning`=amber/broadcast, `borderMuted`=grey/neutral·unknown-route,
  `muted`=dim/dead). These are pi theme color *names*, not RGB — clients map
  them to their own palette.
- `ascii_fallback`: `{ env: "PI_C2C_ASCII", value: "1", description: "when set,
  clients substitute the `ascii` field" }`. (Env name is pi-c2c's; documented so
  clients know the established convention. c2c itself only emits the data.)
- `message_sources`: `["local","sessions","relay","spool","unknown"]` — the
  telemetry `MessageSource` enum (`pi-c2c/src/telemetry.ts:9`); `spool` =
  delivered from the local spool/outbox after a transient failure; `unknown` =
  source not recorded.

### Route-glyph determination (document in the registry `description`s)

- For an **outgoing** send the route is known from the actual delivery mechanism
  (`via` = relay|sessions|local) → exact glyph.
- For an **incoming** message the client infers the route from the sender alias:
  a full address `<name>@<12-hex-hosthash>` ⇒ `relay` (`⇄`); otherwise it cannot
  tell and should use the **`unknown` (`◌`)** route. (Historically pi-c2c
  defaulted this case to `sessions`/`◎` — which is why a bare-aliased relay send
  showed `▼◎` not `▼⇄`; the new `unknown` glyph disambiguates "couldn't tell"
  from "actually via the sessions broker.") Capture this in the
  `routes.unknown.description` and a top-level `notes` string so consumers
  reproduce the inference. **pi-c2c `routeForAlias` follow-up:** switch its
  bare-alias fallback from `sessions` → `unknown` (separate pi-c2c change, out of
  scope for this c2c slice; flag it in the runbook).

## Implementation plan

1. New module `ocaml/glyphs.ml` (+ `Glyphs` in `ocaml/dune:46` `c2c_mcp` lib
   `modules`): pure data + `to_json : unit -> Yojson.Safe.t`. Keeping it in the
   lib (not CLI-only) lets tests and any future MCP surface reuse it.
2. `ocaml/cli/c2c_glyphs_cmd.ml`: `list_glyphs_cmd` (a `--compact` flag)
   using `print_json` / `Yojson.Safe.to_string`; wrap as
   `list_glyphs = Cmd.v (Cmd.info "list-glyphs" ~doc:"(dev) …") list_glyphs_cmd`;
   append `C2c_glyphs_cmd.list_glyphs` to `all_cmds`.
3. `--dev` global flag + `hidden_unless_dev` set: thread through
   `fast_path_commands` (12068), `commands_by_safety_cmd` (315), `commands_man`
   (11946). `list-glyphs` NOT added to `command_tier_map` → defaults Tier2 →
   runnable everywhere (acceptable); OR explicitly map Tier1. Either keeps it
   runnable — do NOT map Tier3/4.
4. Tests `ocaml/cli/test_c2c_list_glyphs.ml` (model: `test_c2c_onboarding.ml`):
   JSON parses; exact glyph chars for a sample of each group; command runs +
   exits 0 under BOTH empty and non-empty `C2C_MCP_SESSION_ID` (proves
   always-runnable); `c2c commands` hides it without `--dev` and shows it with.
   Wire `(test ...)` in `ocaml/cli/dune`.
5. Runbook `.collab/runbooks/c2c-glyphs.md`: the human reference, pointing at
   `c2c list-glyphs` as the machine-readable source of truth.

## Verification

- `dune build -j 2` clean in THIS worktree.
- `c2c list-glyphs | python3 -c 'import json,sys; json.load(sys.stdin)'` ok.
- Glyph values diff-clean vs the pi-c2c TS constants.
- `C2C_MCP_SESSION_ID=x c2c list-glyphs` still exits 0 (always-runnable).
- `c2c commands` omits `list-glyphs`; `c2c commands --dev` includes it.

--- SUMMARY ---

- **What:** a new `c2c list-glyphs` subcommand emitting a pretty JSON registry
  of the c2c TUI glyph vocabulary (direction/route/liveness/subagent + ascii
  fallbacks + semantic colors + action tokens + message-sources), each with a
  meaning/intent description. c2c becomes the source of truth; pi-c2c can later
  fetch instead of hardcoding.
- **Key correctness constraint:** the command must be **always runnable** (pi-c2c
  invokes it with the host session env, which can flip `is_agent_session`). So it
  is Tier1/Tier2 (never filtered from the dispatch group), and "hidden from help"
  is done in the help-text layer via a `hidden_unless_dev` set + a new global
  `--dev` flag (mirroring the existing `--all` argv pre-scan), NOT via the tier
  filter.
- **Exact values:** the three existing routes + all direction/liveness/subagent
  glyphs are copied byte-for-byte from pi-c2c so the switch is visually
  invisible. **One additive change:** a NEW `unknown` route glyph `◌` (`[?]`,
  grey) for "route could not be determined" — distinct from `sessions`/`◎`. The
  inbound bare-alias case should map to `unknown`, not `sessions` (pi-c2c
  `routeForAlias` follow-up, out of scope here).
- **Deliverables:** `ocaml/glyphs.ml` (data+JSON), cmdliner wrapper, `--dev`
  flag + hidden set, Alcotest coverage (incl. always-runnable + help-hiding),
  and `.collab/runbooks/c2c-glyphs.md`.
- **Open impl detail:** whether cmdliner's auto `COMMANDS` block also needs
  suppression — implementer resolves in code; the curated `c2c commands` listing
  is the contract.
