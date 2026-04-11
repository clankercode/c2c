# C2C CLI And Approval Note

## Goal

Make `c2c` the canonical entrypoint so permission approval can target a single real command prefix, while keeping the existing `c2c-*` wrappers as compatibility shims.

## Scope

- add `c2c <subcommand>` entrypoint
- keep `c2c-send`, `c2c-list`, `c2c-whoami`, `c2c-verify`, `c2c-install`, and `c2c-register` as thin delegating shims
- add opt-in auto-approval support for a safe allowlist of day-to-day subcommands
- explicitly exclude `register` from auto-approval
- investigate and reduce repeated session-discovery work during `c2c send`
- add regression tests for dispatch, allowlist matching, disabled-by-default behavior, and the send-path session-loading regression

## Decisions

- canonical CLI shape: `c2c <subcommand>`
- compatibility: keep `c2c-*` wrappers for now
- auto-approval default: off
- auto-approval allowlist: `send`, `list`, `whoami`, `verify`
- auto-approval exclusion: `register`
- fake lookalikes such as `c2c-but-i-just-named-it-that` must not match

## Implementation Order

1. Add failing tests for `c2c` dispatch and shim behavior.
2. Add failing tests for the allowlist matcher and disabled-by-default approval settings.
3. Add a regression test that `c2c send` does not repeatedly reload live sessions just to resolve sender metadata and sendability.
4. Implement the `c2c` entrypoint and convert wrappers to delegate to it.
5. Implement the approval allowlist helpers and opt-in config path.
6. Reduce send-path session discovery duplication by passing already loaded session data through the send flow.
7. Update install output and docs to prefer `c2c <subcommand>`.

## Live Trial Note

For the next `C2C-s1` / `C2C-s2` trial, instruct both agents to include their current counts in every message, for example `sent=3 received=2 | hello`.
