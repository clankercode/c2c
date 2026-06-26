# Design: pi vs opencode chess over c2c (e2e)

Status: approved (brainstorm 2026-06-26). Slice continues on branch
`e2e-pi-opencode-model` (extends the pi/opencode e2e framework added there).

## Goal

A live e2e where **pi (White)** and **opencode (Black)** play a full game of
chess against each other, communicating moves over c2c. There is **no central
referee**: each agent keeps its OWN private board (via a chess CLI on its OWN
temp file) and never reads the opponent's file. When the two boards desync,
the agents **argue over c2c** and try to reconcile; if they can't agree, they
**mutually declare a stalemate** and stop. The game always terminates (real
result OR mutual-stalemate), which is what lets the test pass without depending
on mimo's chess strength — the real dogfood is the bidirectional c2c
conversation + conflict resolution.

## Components

### 1. Chess CLI — `scripts/c2c_chess.py`
Pure-python, **python-chess** backend, operates on a caller-supplied private
JSON state file. Self-contained; invoked by agents via the absolute path given
in their kickoff prompt (`python3 /abs/scripts/c2c_chess.py <cmd> <file> ...`).
Promotable to a `c2c chess` subcommand later.

State file (JSON): `{ "moves": [<uci>...], "ended_by_agreement": bool }`. The
board is rebuilt from `moves` via python-chess on every call (no FEN drift).

Commands (exit 0 = ok; non-zero = error with reason on stderr):
- `new <file>` — fresh game.
- `move <file> <move>` — apply SAN or UCI; **exit 2 + reason** if illegal; on
  success prints new FEN + side to move.
- `legal <file> <move>` — exit 0 if legal, 1 if not.
- `moves <file>` — list all legal moves (UCI), so a weak model can stay legal.
- `board <file>` — ASCII board + FEN + side to move + ply count.
- `status <file>` — JSON: `turn` (w/b), `is_game_over`, `result`
  (checkmate/stalemate/insufficient_material/seventyfive_moves/fivefold/none),
  `ended_by_agreement`, `ply`.
- `declare-stalemate <file>` — set `ended_by_agreement=true`.

Output is line-oriented + JSON (for `status`) so both the agents and the test
can parse it. `--help` lists commands. Has its own unit tests (deterministic,
no agents): legality, illegal rejection, game-over detection, agreement flag,
SAN+UCI parsing, persistence round-trip.

### 2. Kickoff / role prompt
Injected as the opening c2c DM (and/or a compiled role). Each agent is told:
- its color and that it is playing a real game vs the opponent alias;
- the EXACT CLI command and **its own private state file path** (the test
  dictates the paths so it can observe them);
- use **UCI** in DMs: `MOVE e2e4` (unambiguous; easiest for weak models);
- the protocol:
  - On your turn: `moves` → pick a legal one → `move` your file → DM
    `MOVE <uci>`.
  - On receiving `MOVE <uci>`: apply to your file. If illegal on your board:
    DM `DISPUTE: <uci> — <reason>` and argue briefly (≤ a few exchanges).
  - Can't reconcile → `declare-stalemate` your file + DM `STALEMATE-AGREED`.
  - On game end (checkmate/draw/agreement) → DM `GAME OVER: <result>`.
  - Never read the opponent's file.

### 3. e2e test — `tests/test_c2c_chess_e2e.py`
Gated `C2C_TEST_CHESS_E2E=1`; skips if python-chess / pi / opencode / tmux
absent.
- `new` both private files (`<workdir>/white.chess.json`, `black.chess.json`).
- Launch pi (white) + opencode (black) via the framework adapters on a
  **dedicated tmux socket** (see §4), with the chess kickoff.
- DM White the opening nudge ("you are White, make the first move").
- Poll a long cap (`C2C_CHESS_TIMEOUT_S`, default ~900s) for a **terminal
  state**: either private file's `status` reports `is_game_over` or
  `ended_by_agreement`, OR a `GAME OVER` / `STALEMATE-AGREED` DM in the broker.
- Assert a terminal result was reached. Capture both final boards + the move
  log + transcripts as artifacts. Fail cleanly (not hang) if a pane dies.

### 4. tmux isolation (framework change)
Today an opencode launch took the shared tmux server down with it. Add optional
`tmux -L <socket>` support to `TmuxDriver` (a `socket` ctor arg; every `tmux`
invocation gets `-L <socket>` when set). The chess test uses a dedicated socket
(e.g. `c2c-chess-e2e`) so a server crash cannot kill the user's main sessions.
Existing tests keep the default socket (no behavior change). Unit-test that the
`-L` flag is threaded through start/send/capture/stop.

## Risks / non-goals
- **Convergence depends on c2c auto-delivery waking both agents** (inbound DM →
  agent acts → replies). This is exactly the project group-goal; if either
  client doesn't auto-act, the game stalls → the test times out. Acceptable for
  a gated, manual live test; the mutual-stalemate escape bounds a desync but not
  a dead-agent stall (timeout handles that).
- Real LLM tokens, long; **manual-run only**, never in the default suite.
- Not asserting chess *quality* — only that a refereed-by-each-side game over
  c2c reaches a terminal state.

## Live status (2026-06-26)

Built + unit-tested (CLI 13 tests, tmux socket 2 tests, full suite 77 passed).
Live validation so far:
- pi (White) launches + registers cleanly on the isolated `-f /dev/null` socket;
  the chess CLI, kickoff via referee alias, and terminal-polling all work.
- The dedicated-socket isolation works ONLY with `-f /dev/null` — without it,
  tmux-resurrect/continuum auto-restore clones the operator's sessions onto the
  socket and hangs `new-session` (finding:
  `.collab/findings/2026-06-26T11-20-00Z-tmux-continuum-breaks-L-socket-isolation.md`).
- **Not yet achieved: a full live game.** opencode (Black) managed-start does
  not stay up on the isolated server — its pane dies and `wait_for_init` times
  out (pi is fine). This is the same opencode managed-start fragility seen in
  the pi/opencode slice (`test_opencode_smoke_model_override`). FOLLOW-UP:
  diagnose `c2c start opencode` on a `-f /dev/null` tmux server (does it need
  the user's tmux config? more boot time? a different model flag path?). The
  full game remains a manual exercise until opencode launch is reliable here.

## Relay variants (added 2026-06-26)

The local chess test routes via the local per-repo broker. Requested follow-on:
relay-routed variants. Player-variant matrix requested: (a) controller-driven,
(b) real pi vs opencode, (c) pi using ONLY its native `c2c_pi_*` tools.

- **(a) Controller-driven chess over the public relay — DONE + LIVE-VALIDATED.**
  `tests/test_c2c_chess_relay_e2e.py` (gated `C2C_TEST_RELAY_CHESS_E2E=1`).
  Registers two aliases on the relay (`C2C_RELAY_URL`, default relay.c2c.im;
  point at a local POW-off relay to avoid prod), plays a first-legal-move game
  where every ply is a real `c2c relay dm send` (POW) → relay → `relay dm poll`
  round-trip, asserting per-ply FEN-equality (the relay carried the move). Ran
  10/10 plies through relay.c2c.im, boards synced, ~12s.
- **(b) real pi vs opencode over relay — NOT BUILT.** Compounds the unresolved
  live blockers: opencode managed-start (already failing locally) + both clients
  autonomously sending/polling via relay. Deferred until the local agent game
  works.
- **(c) pi-native-tools-only over relay — BLOCKED by a relay bug (found here).**
  A live probe showed pi DOES receive relay DMs into its transcript (inbound
  works), and pi DID try to reply via `c2c_pi_send` — but the relay rejects the
  send: `verified signer "<name>" does not match body from_alias "<name>@<host>"`.
  pi-c2c sends as its full relay address (`deriveRelayAlias` = `<name>@<host>`),
  which the relay's signer check rejects on same-host (the only working relay
  path). Decisively reproduced via the CLI. Finding:
  `.collab/findings/2026-06-26T12-15-00Z-relay-send-full-address-alias-signature-mismatch.md`.
  Fix is either a relay-side normalize (OCaml + prod deploy) or a pi-c2c change
  (pass the bare alias for same-host). Variant C cannot pass until one lands.
  (The machine-id-in-transcript request was delivered for variant (a): the
  relay transcript now records full `<alias>@<host>` addresses.)

## Test plan
- `c2c_chess.py` unit tests (deterministic, no agents) — full coverage of the
  CLI + state manager.
- `TmuxDriver` `-L` socket unit test.
- The live chess e2e itself (gated, manual).
