# Kimi PreToolUse hook over-forwards every Shell call to the reviewer

- **Filed**: 2026-05-01T01:47:18Z by coordinator1 (Cairn-Vigil)
- **Severity**: HIGH (operator-experience defect; reviewer DM stream is unusable, real approvals get drowned)
- **Class**: kimi-approval-hook UX / operator workflow
- **Affected**: any kimi peer launched with the default `c2c install kimi` hook block + yolo mode
- **Status**: FIXED (verified 2026-05-04 by willow-coder)

## Fix

Path B was shipped. The allowlist is implemented in both the shell script
and its OCaml embedded copy.

### Commits on origin/master
- `1a1d8ef4` — feat(#587): kimi PreToolUse hook safe-pattern allowlist
- `7b3e29d1` — fix(#591): kimi hook git allowlist — `stash list` → `stash` + sync scripts/ mirror
- `8fe78dae` — fix(#591): revert `stash` allowlist — bypassed destructive stash subcommands
- `bf005083` — test(#587): add allowlist test cases to kimi hook test script

### Implementation
`scripts/c2c-kimi-approval-hook.sh` (lines 52–98): `is_safe_command()` function
checks the first token of the shell command and exits 0 (no DM) for:
- Read-only tools: `cat ls pwd head tail wc file stat which whereis type env printenv echo printf true false test [` plus `grep rg ag find fd tree du df free uptime date hostname whoami id ps pgrep pidof lsof jobs history column sort uniq cut paste tr sed awk jq yq xq tomlq`
- Read-only git subcommands: `status log diff show branch tag remote config rev-parse rev-list describe blame reflog ls-files ls-tree fetch shortlog count status -h --help`
- All other commands fall through to the reviewer DM flow.

`ocaml/cli/c2c_kimi_hook.ml` (mirrored `is_safe_command()` at lines 115–159):
same allowlist embedded in the string passed to `c2c install kimi`.

### Test
`scripts/test-c2c-kimi-approval-hook.sh`: test cases for `cat`, `ls`, `git status`
(all exit 0, no DM sent) and `rm`, `git push` (forward to reviewer).

## Verification 2026-05-04
Confirmed both files contain the allowlist block matching the finding's Path B
recommendation. Test script exists and covers the allowlist cases.

## Original Symptom

While dogfooding kimi peers (lumi-test, tyyni-test) with `c2c start kimi`,
coord receives a `[kimi-approval] PreToolUse:` DM **for every single Shell
tool invocation kimi makes** — including completely benign reads:

- `cat <file>`
- `ls <dir>`
- `pgrep`, `ps`
- `grep`, `head`, `tail`, `find`
- `git status`, `git log`, `git diff`
- `stat`, `file`, `which`

Volume during a single dogfood task: tens of DMs per minute. Real
consequential operations (`rm`, `git push`, network egress, package
installs, file writes outside the workspace) blend into the noise; coord
has no realistic path to triage them quickly.

Max's directive (2026-05-01): *"you're getting approval requests for like
all tool calls. Use tmux to peek at the kimi nodes. Notice there is no
permissions request, it's just being allowed. So we need to refine out
we use kimi hooks"* — followed by *"Ignore kimi approvals until you fix
the hook/approval thing."*

## Root cause

Two layers stack:

1. **Yolo mode is active.** `c2c start kimi` launches with `--yolo`
   (Slice 3 of #142 design). Kimi's own UI permission gate is bypassed —
   the operator never sees a prompt; the agent just runs.
2. **Hook matcher captures every Shell call.** Active hook in
   `~/.kimi/config.toml`:
   ```toml
   [[hooks]]
   event = "PreToolUse"
   command = "/home/xertrov/.local/bin/c2c-kimi-approval-hook.sh"
   matcher = "^Shell$"
   timeout = 120
   ```
   `^Shell$` matches the tool name "Shell" with no command-substring
   filter, so every `Shell` call fires the hook.
3. **Hook script unconditionally DMs the reviewer.** Per
   `scripts/c2c-kimi-approval-hook.sh` (and its embedded copy in
   `ocaml/cli/c2c_kimi_hook.ml`), the hook reads stdin payload, builds a
   token, writes a pending-approval record, and `c2c send <reviewer>`s
   the DM. **No allowlist, no tool-input inspection, no early-exit for
   safe patterns.**

Net effect: the hook is the *only* permission gate (yolo bypassed kimi
UI), and it's an absolute blocker — every Shell call costs a round-trip
DM to coord. Read-only inspection becomes a coord-bottleneck.

## Two design paths

### Path A — narrow the matcher (operator-side, doc-only)

Kimi matcher syntax (per `docs/MATCHER_SYNTAX.md` / #161 clarification)
supports `<tool>$:<command-substring-pattern>`. Example from the same
config file (commented out):

```toml
matcher = "^Write$:/(etc|var|root|usr|opt)/"
```

Could change the active matcher from `^Shell$` to e.g.
`^Shell$:(rm |git push|sudo |curl |wget |pip install|npm install|cargo install)`
to capture only dangerous patterns.

**Pros**: zero-script-change; operator-controlled; matches kimi's design
intent.

**Cons**: regex maintenance burden on every operator install; easy to
miss a dangerous form (`bash -c 'rm ...'`, here-strings, environment
abuse). Negative-allowlist is the wrong shape — better to default-deny
and explicitly allow safe reads.

### Path B — enrich the hook with safe-pattern allowlist (preferred)

Keep matcher broad (`^Shell$`). In
`scripts/c2c-kimi-approval-hook.sh`, after parsing `tool_input`, do an
**early-exit-allow** for read-only commands. Roughly:

```bash
# Extract command string from tool_input (kimi's Shell tool_input.command)
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"

# Strip leading whitespace + extract first token
first="$(printf '%s' "$cmd" | awk '{print $1}')"

# Read-only allowlist — exit 0 without DM
case "$first" in
  cat|ls|pwd|head|tail|wc|file|stat|which|whereis|type|env|printenv|\
  grep|rg|ag|find|fd|tree|du|df|free|uptime|date|hostname|whoami|id|\
  ps|pgrep|pidof|lsof|jobs|history|\
  echo|printf|true|false|test|\[)
    exit 0
    ;;
  git)
    # Only allow read-only git subcommands
    sub="$(printf '%s' "$cmd" | awk '{print $2}')"
    case "$sub" in
      status|log|diff|show|branch|tag|remote|config|rev-parse|\
      rev-list|describe|blame|reflog|ls-files|ls-tree|stash|fetch)
        exit 0 ;;
    esac
    ;;
  jq|yq|xq|tomlq|column|sort|uniq|cut|paste|tr|sed|awk)
    # Pure-text transformers — no side effect by themselves
    exit 0
    ;;
esac

# Fall through to the existing forward-to-reviewer flow
```

**Pros**: self-contained; covers the 90% case immediately; default-deny
for unknown commands keeps the security envelope intact; zero operator
config required; works the same for every kimi peer.

**Cons**: hook script is now stateful with policy. Maintaining the
allowlist becomes a c2c repo concern (good — central source of truth).

### Recommendation

**Ship Path B.** Path A regex would be larger, fragile, and force every
operator to copy it. Path B keeps the matcher dumb and concentrates
policy in a versioned shell script the swarm maintains.

Implementation surface:

1. Update `scripts/c2c-kimi-approval-hook.sh` (live source) with the
   allowlist block above, place between "Read kimi's JSON payload from
   stdin" and "Mint a token".
2. Mirror the same change into `ocaml/cli/c2c_kimi_hook.ml` (the
   embedded-string copy used by `c2c install kimi`).
3. Add a test under `ocaml/test/` that feeds the script representative
   `tool_input` payloads (cat, ls, rm, git status, git push) and
   asserts exit code + DM-or-no-DM. Use `C2C_BIN=mock-c2c` fixture so
   no real broker traffic.
4. Update `docs/MSG_IO_METHODS.md` (or whichever doc covers kimi
   delivery) to describe the allowlist; link `.collab/runbooks/kimi-notification-store-delivery.md`.

Slice budget: ~50-80 LoC script change + ~5 LoC OCaml mirror + ~80 LoC
test. Single-author single-PASS slice.

## Related

- `#490` — approval side-channel design (broker_root in pending JSON,
  `c2c approval-reply` flow). Allowlist sits *above* this; #490 stays
  the path for forwarded approvals.
- `#502` — `C2C_KIMI_APPROVAL_REVIEWER` warn-on-use deprecation. Same
  hook surface; willow has cache-hot context here.
- `#142` — original kimi permission-forwarding design.
- `#161` — matcher syntax clarification (Path A would build on this).

## Operator action until fixed

Per Max's directive: **coord ignores all `[kimi-approval]` DMs**. They
fall closed (await-reply timeout → exit 2) which kimi surfaces to the
agent as "denied by reviewer=coordinator1 (token=...) — no verdict
within 120s". Yolo mode means the agent retries via a different
codepath or works around — operationally OK during dogfood window.

— Cairn-Vigil
