# Findings: #154 c2c completion bash/zsh/pwsh

**Date:** 2026-04-24
**Author:** galaxy-coder
**Status:** Implemented, committed at `<SHA>` (pending commit)

## Background

Item #154: add `c2c completion [shell]` for bash, zsh, and fish. When shell is omitted, detect from `$SHELL`.

## Decision

Fish shell is not supported by cmdliner 2.1.0 — only bash, zsh, and pwsh. Implemented bash, zsh, pwsh only.

## Implementation

Added `completion_cmd` to `ocaml/cli/c2c.ml`:

- `c2c completion` — auto-detects shell from `$SHELL` env var
- `c2c completion --shell bash` — generates bash completion script
- `c2c completion --shell zsh` — generates zsh completion script
- `c2c completion --shell pwsh` — generates PowerShell completion script

Delegates to `cmdliner tool-completion --standalone-completion <shell> c2c` which is bundled with cmdliner 2.1.0.

Shell detection logic:
- `*.bash` → `bash`
- `*.zsh` → `zsh`
- `*.pwsh` / `*.powershell` → `pwsh`
- Falls back to error with usage message if `$SHELL` is unset/unrecognized

Path resolution for cmdliner binary:
1. `OPAM_SWITCH_PREFIX/bin/cmdliner` if `OPAM_SWITCH_PREFIX` is set
2. `$HOME/.opam/c2c/bin/cmdliner` as fallback

Fish excluded — cmdliner 2.1.0 doesn't support it. If fish support is needed, upstream cmdliner would need to add it, or a custom fish completion script would need to be written.

## Usage

```bash
# bash
source <(c2c completion bash)
# or install permanently:
c2c completion bash > /etc/bash_completion.d/c2c

# zsh
source <(c2c completion zsh)
# or install to fpath:
c2c completion zsh > ~/.zfunc/_c2c

# PowerShell
c2c completion pwsh > ~/Documents/PowerShell/Completions/c2c.ps1
```

## Test results

- `c2c completion --shell bash` → 84 lines of bash completion script
- `c2c completion --shell zsh` → 86 lines of zsh completion script
- `c2c completion --shell pwsh` → 201 lines of PowerShell completion script
- `c2c completion --help` → man page generated correctly ($$SHELL warning is cosmetic only)
- `c2c completion --shell fish` → error: "unknown shell 'fish'. Supported: bash, zsh, pwsh"

## Residual

- Fish not supported — cmdliner upstream limitation
- `$$SHELL` in help text produces cmdliner warnings (cosmetic, doesn't affect functionality)
