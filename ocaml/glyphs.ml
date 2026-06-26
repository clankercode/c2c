(* glyphs.ml — canonical c2c TUI glyph registry.

   The single source of truth for the c2c TUI glyph vocabulary (message
   direction, broker route, liveness, subagent-registration, action tokens,
   semantic colors, ascii fallbacks). Emitted as JSON by `c2c list-glyphs`
   so any client (pi-c2c today; future clients tomorrow) can fetch the
   vocabulary at launch instead of hardcoding it, and render c2c lines
   consistently.

   Values are copied byte-for-byte from pi-c2c's TS constants
   (`pi-c2c/src/ui/{compact-message,tool-renderers,
   compact-subagent-registration}.ts`) so swapping pi-c2c to fetch them
   changes nothing visually. The ONE additive change is the NEW `unknown`
   route glyph `◌` (`[?]`) for "route could not be determined from the
   message alone" — distinct from `sessions`/`◎`. See the design doc
   `.collab/design/2026-06-26-c2c-list-glyphs-registry.md`.

   This module is pure data + `to_json`. No deps beyond yojson. Keep it in
   the c2c_mcp lib (not CLI-only) so tests and any future MCP surface can
   reuse it.

   NOTE: this file is UTF-8; the glyph string literals below are the exact
   codepoints — do not "fix" them to ascii. *)

let schema_version = 1

(* Build a glyph entry: { glyph, ascii, [color,] description }. The color
   field is omitted entirely when None (matching pi-c2c, where some glyphs
   inherit the surrounding direction/theme color). Field order: glyph,
   ascii, color, description. *)
let glyph ?color ~ascii ~description g : Yojson.Safe.t =
  let fields = [ ("glyph", `String g); ("ascii", `String ascii) ] in
  let fields =
    match color with Some c -> fields @ [ ("color", `String c) ] | None -> fields
  in
  `Assoc (fields @ [ ("description", `String description) ])

(* An action token (the `c2c.<action>` field): no glyph, just a token +
   meaning. *)
let action ~token ~description : Yojson.Safe.t =
  `Assoc [ ("token", `String token); ("description", `String description) ]

(* A message-source enum value: name + meaning. *)
let source ~description : Yojson.Safe.t =
  `Assoc [ ("description", `String description) ]

let colors : Yojson.Safe.t =
  `Assoc
    [ ("success", `String "green — home route, alive peer, incoming message")
    ; ("accent", `String "cyan — relay route, outgoing message, line marker / channel token")
    ; ("warning", `String "amber — broadcast (1:N)")
    ; ("borderMuted", `String "grey — neutral, field separator, status envelope, unknown route")
    ; ("muted", `String "dim — dead / unreachable peer")
    ]

let ascii_fallback : Yojson.Safe.t =
  `Assoc
    [ ("env", `String "PI_C2C_ASCII")
    ; ("value", `String "1")
    ; ( "description"
      , `String
          "when this env var is set, clients substitute the `ascii` field for \
           the `glyph` field on every entry. The env name is pi-c2c's \
           established convention; c2c itself only emits the data." )
    ]

let container : Yojson.Safe.t =
  `Assoc
    [ ( "line_marker"
      , glyph "⧓" ~ascii:"o" ~color:"accent"
          ~description:
            "leads every collapsed c2c line: `⧓ c2c.<action> · …`" )
    ; ( "channel"
      , glyph "c2c" ~ascii:"c2c" ~color:"accent"
          ~description:"the channel token shown after the line marker" )
    ; ( "separator"
      , glyph " · " ~ascii:" . " ~color:"borderMuted"
          ~description:"field separator between collapsed-line fields" )
    ]

let directions : Yojson.Safe.t =
  `Assoc
    [ ( "incoming"
      , glyph "▼" ~ascii:"v" ~color:"success"
          ~description:"a message arriving at this session (`recv`)" )
    ; ( "outgoing"
      , glyph "▲" ~ascii:"^" ~color:"accent"
          ~description:"a message leaving this session (`send`)" )
    ; ( "broadcast"
      , glyph "✶" ~ascii:"*" ~color:"warning"
          ~description:"a 1:N broadcast (`send_all` / `recv-all`)" )
    ; ( "status"
      , glyph "●" ~ascii:"o" ~color:"borderMuted"
          ~description:"a peer status / runtime envelope (not chat)" )
    ; ( "arrows"
      , `Assoc
          [ ( "incoming"
            , glyph "←" ~ascii:"<-"
                ~description:
                  "points at the receiver; inherits the direction color" )
          ; ( "outgoing"
            , glyph "→" ~ascii:"->"
                ~description:
                  "points at the target; inherits the direction color" )
          ] )
    ]

let routes : Yojson.Safe.t =
  `Assoc
    [ ( "local"
      , glyph "⌂" ~ascii:"[local]" ~color:"success"
          ~description:
            "delivered via your per-repo home broker (same repo + machine)" )
    ; ( "sessions"
      , glyph "◎" ~ascii:"[sessions]" ~color:"borderMuted"
          ~description:
            "delivered via the cross-repo sessions broker — a *known* route, \
             asserted from the actual delivery mechanism" )
    ; ( "relay"
      , glyph "⇄" ~ascii:"[relay]" ~color:"accent"
          ~description:
            "delivered via the public / remote relay (cross-machine); relay \
             aliases are full addresses `<name>@<hosthash>`" )
    ; ( "unknown"
      , glyph "◌" ~ascii:"[?]" ~color:"borderMuted"
          ~description:
            "route could NOT be determined from the message alone (e.g. an \
             inbound bare alias with no `@<host>` suffix). Distinct from \
             `sessions`, which asserts the cross-repo broker. For an outgoing \
             send the route is known from the delivery mechanism; for an \
             incoming message a full address `<name>@<12-hex-hosthash>` \
             implies `relay`, otherwise the client cannot tell and should use \
             this `unknown` glyph." )
    ]

let liveness : Yojson.Safe.t =
  `Assoc
    [ ( "alive"
      , glyph "●" ~ascii:"o" ~color:"success"
          ~description:"peer currently reachable" )
    ; ( "dead"
      , glyph "○" ~ascii:"o" ~color:"muted"
          ~description:"registered but not currently reachable" )
    ]

let subagent_registration : Yojson.Safe.t =
  `Assoc
    [ ( "container"
      , glyph "⧓" ~ascii:"o" ~color:"accent"
          ~description:"leads a subagent-registration line" )
    ; ( "fork"
      , glyph "↳" ~ascii:"->"
          ~description:"a subagent forked under a parent (theme color)" )
    ; ( "mapping"
      , glyph "→" ~ascii:"=>"
          ~description:"maps a subagent to its parent alias (theme color)" )
    ; ( "bullet"
      , glyph "›" ~ascii:">"
          ~description:"list-item separator (theme color)" )
    ]

let actions : Yojson.Safe.t =
  `Assoc
    [ ("recv", action ~token:"recv" ~description:"inbound 1:1 message")
    ; ("send", action ~token:"send" ~description:"outbound 1:1 message")
    ; ("recv-all", action ~token:"recv-all" ~description:"inbound broadcast (received via send_all)")
    ; ("send-all", action ~token:"send-all" ~description:"outbound broadcast (send_all)")
    ; ("send-room", action ~token:"send-room" ~description:"outbound room message")
    ; ("status", action ~token:"status" ~description:"peer status / runtime update (not chat)")
    ]

let message_sources : Yojson.Safe.t =
  `Assoc
    [ ("local", source ~description:"delivered via the local per-repo home broker")
    ; ("sessions", source ~description:"delivered via the cross-repo sessions broker")
    ; ("relay", source ~description:"delivered via the public / remote relay (cross-machine)")
    ; ("spool", source ~description:"delivered from the local spool / outbox after a transient failure")
    ; ("unknown", source ~description:"source not recorded")
    ]

let notes : string =
  "Route inference: for an OUTGOING send the route is known from the actual \
   delivery mechanism (via = relay | sessions | local) and maps to the exact \
   route glyph. For an INCOMING message the client infers the route from the \
   sender alias — a full address `<name>@<12-hex-hosthash>` implies `relay` \
   (⇄); otherwise the route cannot be determined and the client should use the \
   `unknown` route (◌). Historically pi-c2c defaulted the bare-alias case to \
   `sessions`/◎, which made a bare-aliased relay send show ▼◎ instead of ▼⇄; \
   the `unknown` glyph disambiguates \"couldn't tell\" from \"actually via the \
   sessions broker\"."

let to_json () : Yojson.Safe.t =
  `Assoc
    [ ("schema_version", `Int schema_version)
    ; ( "description"
      , `String
          "Canonical c2c TUI glyph registry: the message-direction, broker-route, \
           liveness, and subagent-registration vocabulary clients use to render \
           c2c lines consistently. Each glyph entry carries `glyph` (the unicode \
           char), `ascii` (a fallback when PI_C2C_ASCII is set), an optional \
           semantic `color` name, and a `description` of its meaning/intent." )
    ; ("ascii_fallback", ascii_fallback)
    ; ("colors", colors)
    ; ("container", container)
    ; ("actions", actions)
    ; ("directions", directions)
    ; ("routes", routes)
    ; ("liveness", liveness)
    ; ("subagent_registration", subagent_registration)
    ; ("message_sources", message_sources)
    ; ("notes", `String notes)
    ]
