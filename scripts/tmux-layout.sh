#!/usr/bin/env bash
# tmux-layout.sh — apply an explicit COLSxROWS grid layout to the current
# tmux window. tmux's built-in `tiled` picks grid orientation from window
# aspect ratio and won't let you force, say, 3x2 vs 2x3. This does.
#
# Usage:
#   tmux-layout.sh <COLS>x<ROWS>    e.g. tmux-layout.sh 3x2
#
# Must be run from inside tmux (uses $TMUX). Pane count must equal COLS*ROWS.
# Preserves current pane order (left-to-right, top-to-bottom by pane_index).

set -euo pipefail

[ -n "${TMUX:-}" ] || { echo "tmux-layout: not inside a tmux session" >&2; exit 2; }

arg="${1:-}"
if ! [[ "$arg" =~ ^([0-9]+)x([0-9]+)$ ]]; then
  echo "usage: $0 <COLS>x<ROWS>  (e.g. 3x2)" >&2
  exit 2
fi
cols="${BASH_REMATCH[1]}"
rows="${BASH_REMATCH[2]}"
want=$((cols * rows))

read -r W H <<<"$(tmux display -p '#{window_width} #{window_height}')"
have=$(tmux display -p '#{window_panes}')

if [ "$have" -ne "$want" ]; then
  echo "tmux-layout: window has $have panes but ${cols}x${rows} needs $want" >&2
  exit 3
fi

# Ordered pane indices as they appear in the window tree
mapfile -t idxs < <(tmux list-panes -F '#{pane_index}')

python3 - "$W" "$H" "$cols" "$rows" "${idxs[@]}" <<'PY'
import sys, subprocess
W, H, cols, rows = map(int, sys.argv[1:5])
idxs = [int(x) for x in sys.argv[5:]]

# Pane sizes (borders take 1 row/col each between panes)
def split(total, n):
    inner = total - (n - 1)          # subtract borders
    base, extra = divmod(inner, n)
    return [base + (1 if i < extra else 0) for i in range(n)]

cw = split(W, cols)
rh = split(H, rows)

# Column left edges
xs = []
x = 0
for i, w in enumerate(cw):
    xs.append(x)
    x += w + 1  # border

# Row top edges
ys = []
y = 0
for i, h in enumerate(rh):
    ys.append(y)
    y += h + 1

# Build column groups: each column is a vertical stack ([]) of `rows` panes.
# Panes fill in row-major (left-to-right, top-to-bottom by pane_index).
col_groups = []
k = 0
for ci in range(cols):
    cx, cwi = xs[ci], cw[ci]
    pane_entries = []
    for ri in range(rows):
        ry, rhi = ys[ri], rh[ri]
        pane_entries.append(f"{cwi}x{rhi},{cx},{ry},{idxs[ri*cols + ci]}")
    col_groups.append(f"{cwi}x{H},{cx},0[" + ",".join(pane_entries) + "]")

payload = f"{W}x{H},0,0{{" + ",".join(col_groups) + "}"

csum = 0
for c in payload.encode():
    csum = ((csum >> 1) | ((csum & 1) << 15)) & 0xFFFF
    csum = (csum + c) & 0xFFFF
layout = f"{csum:04x},{payload}"

subprocess.run(["tmux", "select-layout", layout], check=True)
print(layout)
PY
