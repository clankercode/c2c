# PTY injection findings (local machine, 2026-04-11)

## Scope / current state

Relevant live Claude sessions found on this machine:

- `C2C msg test` — PID `2002626` — session `e2deb862-9bf1-4f9f-92f5-3df93978b8d4` — stdin/stdout PTY `/dev/pts/11`
- `C2C-test-agent2` — PID `2009124` — session `d5722f5b-6355-4f2f-a712-39e9a113fc06` — stdin/stdout PTY `/dev/pts/19`
- Current Claude in this repo — PID `2600119` — session `f235530d-4fc5-4a09-a730-21f6e71ccd23` — PTY `/dev/pts/20`
- Another live Claude — PID `2687870` — session `150a299c-3e77-4b39-95e4-6a06b2bc1c1e` — PTY `/dev/pts/8`

All are under one Ghostty single-instance terminal process:

- Ghostty PID: `30593`
- Matching master fds in Ghostty:
  - `pts/11` -> `/proc/30593/fd/458` with `tty-index: 11`
  - `pts/19` -> `/proc/30593/fd/1941` with `tty-index: 19`
  - `pts/20` -> `/proc/30593/fd/2195` with `tty-index: 20`
  - `pts/8` -> `/proc/30593/fd/2277` with `tty-index: 8`

Machine/kernel state relevant to injection:

- Kernel: `6.19.10-arch1-1`
- `kernel.yama.ptrace_scope = 1`
- `apps/ma_adapter_claude/priv/pty_inject` already has `cap_sys_ptrace=ep`

That means `pidfd_getfd()` via the helper should be usable here, while arbitrary same-user fd duplication would normally be blocked by Yama.

## Exact bytes to write

For a message `MSG`, the reliable sequence is:

1. Write this to the PTY **master** fd:

   - bytes: `1b 5b 32 30 30 7e` + `UTF-8(MSG)` + `1b 5b 32 30 31 7e`
   - string form: `\x1b[200~MSG\x1b[201~`

2. Wait about `200 ms`
3. Write Enter separately:

   - bytes: `0d`
   - string form: `\r`

Example for `MSG = hi`:

- first write: `1b 5b 32 30 30 7e 68 69 1b 5b 32 30 31 7e`
- second write after delay: `0d`

This is exactly what `/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject.c` does.

## Should bracketed paste work?

Probably yes, on these live Claude sessions.

Evidence:

- `/home/xertrov/src/claude-code/src/ink/components/App.tsx` enables bracketed paste on startup by writing `EBP`.
- `/home/xertrov/src/claude-code/src/ink/termio/dec.ts` defines `EBP = CSI ? 2004 h` and `DBP = CSI ? 2004 l`.
- `/home/xertrov/src/claude-code/src/ink/parse-keypress.ts` and `/home/xertrov/src/claude-code/src/hooks/usePasteHandler.ts` explicitly parse `CSI 200~` / `CSI 201~` and mark the input as pasted.
- meta-agent's current PTY design and live tests are built around this exact mechanism.

Important nuance: there are two designs in `meta-agent` docs.

- Older adoption doc claims one atomic write `\e[200~MSG\e[201~\r` is enough.
- Newer PTY design + actual helper implementation uses **two writes with a 200 ms delay before Enter**.

On this machine, the newer design is the safer one to trust.

## /dev/pts/N vs /proc/<pid>/fd/0 vs PTY master

### Most likely to work

Write to the **existing PTY master fd**, duplicated from Ghostty via `pidfd_getfd()`.

On this machine that means duplicating one of Ghostty's `/dev/ptmx` fds whose `fdinfo` has the matching `tty-index`.

### Unlikely / wrong target

- Writing to `/dev/pts/N`
- Writing to `/proc/<claude-pid>/fd/0`

These both refer to the **slave** side. Per the newer `meta-agent` PTY design, slave writes go to terminal output/display, not the input queue Claude reads from.

### Also not the right approach

Opening `/proc/<terminal-pid>/fd/<masterfd>` when it links to `/dev/ptmx` is not enough. Re-opening `/dev/ptmx` allocates a **new** PTY pair instead of duplicating the existing master. The docs call this out explicitly.

## Terminal mode/state that can block or delay processing

### Likely OK right now

For all live target sessions, `stty -a -F /proc/<pid>/fd/0` shows a raw-ish mode:

- `-icanon`
- `-echo`
- `-isig`
- `-iexten`
- `extproc`

This looks consistent with Ink's active input handling and should not itself block bracketed paste processing.

### Things that can still prevent useful handling

1. Claude is not at a normal prompt / waiting-for-input state
   - mid-response streaming
   - status dialog or other local-command UI
   - a different modal screen consuming input

2. Bracketed paste mode has been disabled
   - if the Ink app unmounted or shut down raw mode, `CSI 200~...201~` may not be recognized as paste

3. Enter arrives too early
   - if `\r` is sent immediately, Ink may process Enter before the pasted text is committed
   - this is why the helper waits `200 ms`

4. Message contains raw paste markers
   - `\x1b[200~` or `\x1b[201~` inside the message body can corrupt framing
   - meta-agent sanitizes these out first

5. Wrong side of the PTY pair
   - slave writes can appear visually but not become input

## How to verify delivery

Best verification path on this machine:

1. Inject a unique marker prompt, e.g. `Reply with exactly: PTY_DELIVERY_12345`
2. Verify a new `type: "user"` entry containing that marker appears in the session JSONL transcript
3. Then verify the assistant response with the same marker appears

Relevant transcript files:

- `/home/xertrov/.claude/projects/-home-xertrov-tmp/e2deb862-9bf1-4f9f-92f5-3df93978b8d4.jsonl`
- `/home/xertrov/.claude/projects/-home-xertrov-tmp/d5722f5b-6355-4f2f-a712-39e9a113fc06.jsonl`

This matches `/home/xertrov/src/meta-agent/test/e2e/live_pty_injection_test.exs`, which verifies PTY injection by searching the JSONL for a marker.

Secondary verification:

- visually watch the target terminal and confirm the pasted text appears and submits

## Current repo-specific conclusions

### `meta-agent`

`/home/xertrov/src/meta-agent` is directly relevant and currently has the strongest local evidence:

- design doc: `/home/xertrov/src/meta-agent/docs/injection-pty-design.md`
- Claude PTY injector: `/home/xertrov/src/meta-agent/apps/ma_adapter_claude/lib/ma_adapter_claude/injection/pty.ex`
- helper: `/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject.c`
- live e2e verification: `/home/xertrov/src/meta-agent/test/e2e/live_pty_injection_test.exs`

### `c2c-msg`

There is a likely bug in `/home/xertrov/src/c2c-msg/c2c_relay.py`:

- it writes to the slave path returned from `/proc/<pid>/fd/1`
- and it places `\r` **inside** the bracketed-paste region before `\x1b[201~`

Current code there is:

- `\x1b[200~{message}\r\x1b[201~`

Safer framing is:

- first write: `\x1b[200~{message}\x1b[201~`
- delay ~200 ms
- second write: `\r`

and it should go to the duplicated **master** fd, not `/dev/pts/N`.

## Concrete minimal experiment plan

1. Target `C2C-test-agent2` first.
   - Claude PID: `2009124`
   - slave PTY: `/dev/pts/19`
   - Ghostty master fd owner: PID `30593`, fd `1941`
   - transcript: `/home/xertrov/.claude/projects/-home-xertrov-tmp/d5722f5b-6355-4f2f-a712-39e9a113fc06.jsonl`

2. Use the existing helper from `meta-agent` rather than inventing a new injector.

3. Inject exactly:
   - paste write: `\x1b[200~Reply with exactly: PTY_DELIVERY_<RAND>\x1b[201~`
   - wait `200 ms`
   - enter write: `\r`

4. Immediately inspect the JSONL for the marker.
   - first confirm a new user message line exists
   - then confirm assistant echoed the exact marker

5. If that fails, test the failure modes in this order:
   - target session was not actually idle / waiting for input
   - Enter timing too short
   - bracketed paste disabled in that UI state
   - wrong fd / wrong terminal ancestor chosen

6. Do **not** spend time on `/dev/pts/19` or `/proc/2009124/fd/0` writes unless you are explicitly demonstrating failure; they are less likely than master-fd injection on this machine.
