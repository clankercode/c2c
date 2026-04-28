# Managed-session `c2c git` shim

The `c2c git` subcommand is a thin wrapper around the real `git` binary
(resolved via `Git_helpers.find_real_git`). Inside a managed session — one
launched by `c2c start <client>` with `C2C_MCP_AUTO_REGISTER_ALIAS` set —
the shim auto-attributes commits to the agent's alias so the swarm can
distinguish who wrote what.

## Default behaviour

When `git.attribution=true` in `.c2c/config.toml` (the default) and the
caller did NOT pass `--author=…`, the shim prepends the following pairs to
the child env before `Unix.execve`:

```
GIT_AUTHOR_NAME=<alias>
GIT_AUTHOR_EMAIL=<alias>@c2c.im
```

It also re-runs `git -c gpg.format=ssh -c user.signingkey=… -S` for
`commit` / `tag` when `git.sign=true` and a per-alias ed25519 SSH key
exists under the broker's `keys/` dir.

## Operator override (#367)

Earlier shim versions PREPENDED the alias-default pair unconditionally.
Because env-array position picks the first match, that meant any
operator-set `GIT_AUTHOR_NAME` (whether via `GIT_AUTHOR_NAME=… c2c git
commit …` or an ambient `export`) was silently shadowed — and the only
escape hatch was calling `/usr/bin/git` directly.

After #367 the shim checks the parent environment first and **only injects
defaults for variables not already set**. So:

```bash
# Default attribution — uses alias.
c2c git commit -m "fix: thing"

# Override just the name; email still falls through to alias default.
GIT_AUTHOR_NAME="Pair Programmer" c2c git commit -m "..."

# Full override; shim injects nothing for author.
GIT_AUTHOR_NAME="Max" GIT_AUTHOR_EMAIL=max@amaroo.com c2c git commit -m "..."

# `--author=` still suppresses the overlay entirely (pre-existing
# behaviour via `has_author_flag`).
c2c git commit --author="Max <max@amaroo.com>" -m "..."
```

Signing config is unchanged: it keys off the alias regardless of the
author override, so a re-attributed commit still gets signed by the
managed session's key. That is intentional — provenance of WHO ran the
shim is independent of WHO is named in the trailer.

## Implementation pointer

`ocaml/cli/c2c_git_shim.ml` — pure helper `build_author_overlay`.
Called from the `git_cmd` Cmdliner term in `ocaml/cli/c2c.ml`. Tests in
`ocaml/cli/test_c2c_git_shim.ml`.
