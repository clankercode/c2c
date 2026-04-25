# #171 git-workflow dogfooding — pre-commit hook + rebase-base check

## Status
Draft — 2026-04-25

## Motivation
The swarm has hit direct-to-master commits 4+ times in one day (galaxy, stanza, jungle-coder). The rule is documented in CLAUDE.md but gets bypassed under time pressure. We need mechanical enforcement.

## Component 1: Pre-commit Hook

### What it does
Installed by `c2c install` (or `c2c install git-hook`), this hook runs before every `git commit`. It checks:
- The target branch (the one being committed TO)
- Whether `C2C_COORDINATOR=1` is set in the environment

### Behavior
| Condition | Outcome |
|-----------|---------|
| Target branch is `master` or `main`, `C2C_COORDINATOR` unset | **BLOCKED** — exit 1, print warning |
| Target branch is `master` or `main`, `C2C_COORDINATOR=1` | **BYPASSED** — commit allowed, add `Bypassed-pre-commit-hook: coordinator` trailer |
| Target branch is anything else | **ALLOWED** — no check |

### Bypass trailer
When `C2C_COORDINATOR=1` is set, the hook passes `--no-verify` to git commit AND appends a trailer:
```
Bypassed-pre-commit-hook: coordinator
```
This makes bypass visible in `git log --format=fuller` and `git log --oneline --format="%h %s%n%B"` so coordinator reviews can see who bypassed and when.

### Installation
- `c2c install git-hook` — installs hook to `.git/hooks/pre-commit` in the repo root
- Hook path determined via `git rev-parse --git-common-dir` so it works from any worktree
- Re-running `c2c install git-hook` overwrites the existing hook
- Hook is a standalone shell script in the repo (e.g. `.c2c/hooks/pre-commit.sh`) with the actual logic; `.git/hooks/pre-commit` is a symlink or wrapper

### Environment variable
- `C2C_COORDINATOR=1` — required to bypass. Set by the coordinator's shell/profile, not committed anywhere.
- Peers never have it set by default.

### Error message (blocked case)
```
[c2c hook] BLOCKED: direct-to-master commit detected.
Target branch: master
Set C2C_COORDINATOR=1 to bypass (coordinators only).
See: https://c2c.im/docs/workflow#coordinator-approval
```

## Component 2: Rebase-base Check (peer-PASS gate)

### What it does
Before requesting a peer-PASS, the author must verify their branch is based on current master (not stale).

### Command
```bash
c2c doctor --check-rebase-base
# or
git fetch origin master && git merge-base --is-ancestor origin/master HEAD && echo "BASE OK" || echo "STALE — rebase required"
```

### Behavior
| Condition | Outcome |
|-----------|---------|
| `HEAD` is descendant of `origin/master` | Prints `BASE OK`, exits 0 |
| `HEAD` is NOT descendant of `origin/master` | Prints `STALE — run: git rebase origin/master`, exits 1 |

### Integration
- Document as mandatory pre-peer-PASS step in CLAUDE.md
- `c2c doctor` output includes "rebase-base" check status
- Pre-commit hook does NOT check this (it's about the branch target, not the commits being made)

## Implementation Notes

### Hook script location
```
.c2c/hooks/pre-commit.sh        — actual hook logic (versioned)
.git/hooks/pre-commit           — installed hook (symlink or copy)
```

### Hook content (shell)
```sh
#!/usr/bin/env bash
# c2c pre-commit hook — blocks direct-to-master unless C2C_COORDINATOR=1
set -euo pipefail

BRANCH=$(git symbolic-ref HEAD 2>/dev/null | sed 's|refs/heads/||') || true
PROTECTED="^(master|main)$"

if [[ "$BRANCH" =~ $PROTECTED ]] && [[ "${C2C_COORDINATOR:-}" != "1" ]]; then
  echo "[c2c hook] BLOCKED: direct-to-master commit detected." >&2
  echo "Target branch: $BRANCH" >&2
  echo "Set C2C_COORDINATOR=1 to bypass (coordinators only)." >&2
  exit 1
fi

# Bypass: append trailer to commit message file ($1 = commit message file)
if [[ "${C2C_COORDINATOR:-}" == "1" ]]; then
  MSG_FILE="${1:-}"
  if [[ -n "$MSG_FILE" ]] && [[ -f "$MSG_FILE" ]]; then
    echo "Bypassed-pre-commit-hook: coordinator" >> "$MSG_FILE"
  fi
fi
# Fall through — commit proceeds normally, trailer in message file
```

### Rebase-base check implementation
In OCaml (for `c2c doctor --check-rebase-base`):
```ocaml
let check_rebase_base () =
  let master_tip = git_rev_parse "origin/master" in
  let head_tip = git_rev_parse "HEAD" in
  match is_ancestor ~ancestor:master_tip ~descendant:head_tip with
  | true -> Printf.printf "BASE OK\n"; 0
  | false -> Printf.printf "STALE — run: git rebase origin/master\n"; 1
```

## Files to create/modify
1. `.c2c/hooks/pre-commit.sh` — new, versioned hook script
2. `ocaml/cli/c2c_setup.ml` — add `install_git_hook` subcommand
3. `ocaml/cli/c2c_doctor.ml` — add `--check-rebase-base` flag
4. `AGENTS.md` / `CLAUDE.md` — document pre-commit hook requirement and rebase-base check

## Scope
- OCaml implementation (matches rest of c2c CLI)
- Works across all worktrees (hook in `.c2c/hooks/` is per-repo, shared via git-common-dir)
- Does NOT enforce commit message format (that's a separate concern)
- Does NOT auto-install the hook for existing agents (requires `c2c install git-hook`)
