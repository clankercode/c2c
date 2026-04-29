# cc-quota — Claude Code quota tracker setup

`scripts/cc-quota` reads the most-recent statusline input JSON to
report 5h / 7d quota usage + cost. It does NOT poll the API — it
parses what Claude Code itself wrote out via the `statusLine` hook.

## Required: statusline input archiver

The hook writes one JSON document per turn to
`$CLAUDE_CONFIG_DIR/sl_out/$session_id/input.json` (and a
`last.json` mirror). `cc-quota` reads `last.json` to find the
current session's usage block.

**You MUST add this snippet to your Claude Code statusline command**
(in `$CLAUDE_CONFIG_DIR/settings.json` under `"statusLine"`, or
wherever your statusline shell runs). Without it, the `sl_out/`
directory stays empty and `cc-quota` returns no data.

```sh
# --- archive/copy statusline input for processing ---
session_id=$(echo "$input" | jq -r '.session_id') # | tee -a ~/.sl-debug.log)
CC_PROFILE=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
CC_STATUSLINE_OUT_DIR="$CC_PROFILE/sl_out/$session_id"
CC_STATUSLINE_OUT_FILE="$CC_STATUSLINE_OUT_DIR/input.json"
sl_out_f="$CC_STATUSLINE_OUT_FILE"
mkdir -p "$CC_STATUSLINE_OUT_DIR"
echo "$input" > "$CC_PROFILE/sl_out/last.json"
echo "$input" > $sl_out_f
# ---
```

Where `$input` is whatever your statusline script reads from stdin
(Claude Code pipes the JSON in as the first argument or stdin —
follow your existing statusline convention; the snippet assumes
`$input` already holds the document).

## Verify

```sh
cc-quota                # should print 5h/7d/cost lines
ls $CLAUDE_CONFIG_DIR/sl_out/  # should show one dir per recent session + last.json
```

If you see "no statusline input found" or empty output, the snippet
is not wired in.

## Notes

- The snippet is pure shell — no jq for the writes themselves, only
  for `session_id` extraction. If you don't have `jq`, swap to
  `python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["session_id"])'`
  or similar.
- Coordinator sessions arm a `cc-quota tick (5m)` Monitor that calls
  `cc-quota` every 5 minutes and posts notifications for usage
  updates. Without the snippet, that Monitor reports stale or empty.
