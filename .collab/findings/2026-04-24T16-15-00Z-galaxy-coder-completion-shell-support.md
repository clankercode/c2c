# Findings: c2c completion shell support

**Date:** 2026-04-24
**Author:** galaxy-coder
**Status:** Complete — implementation committed

## Summary

Added `c2c completion [bash|zsh|pwsh]` command that delegates to `cmdliner tool-completion --standalone-completion <shell> c2c` to generate shell completion scripts.

## Approach

- OCaml `c2c completion` subcommand that pipes cmdliner output to stdout
- Shell detection from `$SHELL` env var (bash/zsh/pwsh)
- `cmdliner_bin()` helper uses `OPAM_SWITCH_PREFIX` if set, falls back to `~/.opam/c2c/bin/cmdliner`
- Fish completion not supported by cmdliner 2.1.0 — only bash, zsh, pwsh

## Implementation

- Added `completion_cmd` in `ocaml/cli/c2c.ml`
- Shell detection via `detect_shell()` function
- Error handling for unknown shells and cmdliner failures
- Added to `all_cmds` list

## Verified

- `c2c completion --shell bash` → 84 lines of bash completion script
- `c2c completion --shell zsh` → 86 lines of zsh completion script
- `c2c completion --shell pwsh` → 201 lines of PowerShell completion script
- `c2c completion --help` → shows correct documentation

## Usage

```bash
# bash: source directly or install to completion dir
source <(c2c completion bash)
c2c completion bash > ~/.bash_completion.d/c2c

# zsh
source <(c2c completion zsh)
c2c completion zsh > ~/.zfunc/_c2c

# pwsh
c2c completion pwsh > ~/.local/share/powershell/Modules/c2c-completion.ps1
```

## Notes

- cmdliner 2.1.0 generates the actual completion logic — c2c just pipes it through
- Fish is not supported by cmdliner 2.1.0 (only bash, zsh, pwsh)
- User must have `cmdliner` available (bundled with c2c's opam switch)
