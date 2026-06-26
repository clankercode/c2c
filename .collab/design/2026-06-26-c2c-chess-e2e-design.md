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

## Test plan
- `c2c_chess.py` unit tests (deterministic, no agents) — full coverage of the
  CLI + state manager.
- `TmuxDriver` `-L` socket unit test.
- The live chess e2e itself (gated, manual).
