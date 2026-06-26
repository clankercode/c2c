# c2c TUI glyph registry (`c2c list-glyphs`)

c2c is the **single source of truth** for the TUI glyph vocabulary that
clients (pi-c2c today; future clients tomorrow) use to render collapsed c2c
lines — message direction, broker route, liveness, and
subagent-registration. The machine-readable source of truth is:

```
c2c list-glyphs            # pretty JSON registry to stdout, exit 0
c2c list-glyphs --compact  # single-line JSON (Yojson.Safe.to_string)
```

The data lives in `ocaml/glyphs.ml` (`Glyphs.to_json`), wired into the
`c2c_mcp` lib so tests and any future MCP surface can reuse it. **Do not
hand-edit the table below to change behaviour — edit `ocaml/glyphs.ml` and
let `c2c list-glyphs` emit the canonical values.** This doc is a human
reference; the command is the contract.

Design: `.collab/design/2026-06-26-c2c-list-glyphs-registry.md`.

## Always runnable — by design

`list-glyphs` is classified **Tier1** in `command_tier_map`
(`ocaml/cli/c2c_commands.ml`) so `filter_commands` NEVER drops it from the
dispatchable cmdliner group. pi-c2c spawns `c2c` with the host session env,
which can set a session-id var that flips `is_agent_session ()` true; a
Tier3/Tier4 command would become *unrunnable* in that case. "Hidden from
help by default" is decoupled from the tier filter: it is handled purely in
the help-text layer via the `hidden_unless_dev` set + the global `--dev`
flag (mirroring the existing `--all` argv pre-scan).

- `c2c commands` — omits `list-glyphs` (the curated contract).
- `c2c commands --dev` — reveals it under a `DEV (hidden without --dev)`
  section.
- `c2c --help` — cmdliner's auto-generated `COMMANDS` block still lists
  `list-glyphs` with its `~doc` (this is acceptable; the curated `c2c
  commands` listing is the hiding contract). The curated tier-grouped
  man's DEV section only appears with `c2c --dev --help`.

## JSON schema (v1)

`schema_version: 1`. Top-level keys: `description`, `ascii_fallback`,
`colors`, `container`, `actions`, `directions`, `routes`, `liveness`,
`subagent_registration`, `message_sources`, `notes`. Each glyph entry
carries `glyph` (the unicode char), `ascii` (a fallback used when
`PI_C2C_ASCII=1`), an optional semantic `color` name, and a `description`.

## Glyph reference

| group | key | glyph | ascii | color | meaning |
|---|---|---|---|---|---|
| container | line_marker | `⧓` | `o` | accent | leads every collapsed c2c line: `⧓ c2c.<action> · …` |
| container | channel | `c2c` | `c2c` | accent | the channel token |
| container | separator | ` · ` | ` . ` | borderMuted | field separator |
| direction | incoming | `▼` | `v` | success | a message arriving at this session (`recv`) |
| direction | outgoing | `▲` | `^` | accent | a message leaving this session (`send`) |
| direction | broadcast | `✶` | `*` | warning | a 1:N broadcast (`send_all` / `recv-all`) |
| direction | status | `●` | `o` | borderMuted | a peer status/runtime envelope (not chat) |
| direction.arrows | incoming | `←` | `<-` | (dir color) | points at the receiver |
| direction.arrows | outgoing | `→` | `->` | (dir color) | points at the target |
| route | local | `⌂` | `[local]` | success | via your per-repo home broker (same repo+machine) |
| route | sessions | `◎` | `[sessions]` | borderMuted | via the cross-repo sessions broker (a *known* route) |
| route | relay | `⇄` | `[relay]` | accent | via the public/remote relay (cross-machine); aliases are `<name>@<hosthash>` |
| route | **unknown** | `◌` | `[?]` | borderMuted | route could NOT be determined from the message alone (NEW glyph) |
| liveness | alive | `●` | `o` | success | peer currently reachable |
| liveness | dead | `○` | `o` | muted | registered but not currently reachable |
| subagent | container | `⧓` | `o` | accent | leads a subagent-registration line |
| subagent | fork | `↳` | `->` | (theme) | a subagent forked under a parent |
| subagent | mapping | `→` | `=>` | (theme) | maps subagent → parent alias |
| subagent | bullet | `›` | `>` | (theme) | list-item separator |

### Semantic colors

These are pi theme color *names*, not RGB — clients map them to their own
palette: `success` (green / home·alive·incoming), `accent`
(cyan / relay·outgoing·marker), `warning` (amber / broadcast),
`borderMuted` (grey / neutral·separator·status·unknown-route),
`muted` (dim / dead peer).

### Action tokens (`c2c.<action>`)

`recv` (inbound 1:1), `send` (outbound 1:1), `recv-all` (inbound
broadcast), `send-all` (outbound broadcast), `send-room` (outbound room),
`status` (peer status update).

### message_sources

The telemetry `MessageSource` enum: `local`, `sessions`, `relay`, `spool`
(delivered from the local spool/outbox after a transient failure),
`unknown` (source not recorded).

## Route-glyph determination

- For an **outgoing** send the route is known from the actual delivery
  mechanism (`via` = relay | sessions | local) → exact glyph.
- For an **incoming** message the client infers the route from the sender
  alias: a full address `<name>@<12-hex-hosthash>` ⇒ `relay` (`⇄`);
  otherwise it cannot tell and should use the **`unknown` (`◌`)** route.

Historically pi-c2c defaulted the bare-alias case to `sessions`/`◎` — which
is why a bare-aliased relay send showed `▼◎` not `▼⇄`. The NEW `unknown`
glyph disambiguates "couldn't tell" from "actually via the sessions
broker".

## Follow-up — pi-c2c `routeForAlias`

**Out of scope for this c2c slice; flagged here.** pi-c2c's `routeForAlias`
should switch its bare-alias fallback from `sessions` → `unknown` (`◌`), so
inbound bare-aliased messages render as `unknown` rather than asserting the
cross-repo sessions broker. This is a separate pi-c2c change.
