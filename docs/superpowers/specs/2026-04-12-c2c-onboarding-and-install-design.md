# C2C Onboarding, Install, And Live-Path Fix Design

## Goal

Make the `c2c-*` tools directly usable by the Claude sessions through the normal user `PATH`, add a self-service `c2c-whoami` command, have `c2c-register` proactively notify the registered session, and fix the live-path bug that caused `c2c-list` to return no opted-in sessions after successful registration.

## Scope

This design covers:

- user-local install of `c2c-*` commands
- `c2c-whoami`
- registration onboarding message delivery
- debugging and fixing the current live registry/list mismatch
- CLI-first automated tests for the new behavior

This design does not change the core alias-based send or transcript verification model already implemented.

## Problem Statement

Two gaps remain before the live autonomous chat run is trustworthy:

1. Claude sessions need `c2c-*` commands available on their normal shell `PATH`.
2. The live run exposed a correctness issue: `c2c-register` succeeded for two live sessions, but `c2c-list --json` returned an empty list immediately afterward.

In addition, the current UX requires too much operator memory. A newly registered session should be told what happened and how to continue.

## User-Facing Commands

Add two new commands:

- `c2c-install`
- `c2c-whoami`

Existing commands remain:

- `c2c-register`
- `c2c-list`
- `c2c-send`
- `c2c-verify`

## Architecture

The follow-up slice has four parts:

1. Live-path bug fix
2. User-local install surface
3. Self-service identity and tutorial command
4. Registration-triggered onboarding message

### 1. Live-Path Bug Fix

The immediate priority is to identify why live registrations were not visible through `c2c-list`.

Likely failure classes:

- registry path mismatch between commands
- a worktree/main-checkout path discrepancy
- pruning logic removing valid registrations because live session IDs did not match the stored data
- command wrappers resolving different Python files or different default data paths

The fix must be evidence-driven. Before changing behavior, inspect:

- the exact registry file being written by `c2c-register`
- the exact registry file being read/pruned by `c2c-list`
- the live session IDs returned to each command

Once fixed, `c2c-register` followed by `c2c-list --json` in the same environment must return the newly registered sessions.

### 2. User-Local Install

`c2c-install` installs user-facing wrappers into a stable per-user bin directory:

- target: `~/.local/bin`

Behavior:

1. verify the target directory exists or create it
2. install or update wrappers/symlinks for:
   - `c2c-register`
   - `c2c-list`
   - `c2c-send`
   - `c2c-verify`
   - `c2c-whoami`
3. point those commands at the chosen repo checkout
4. print a short success message and PATH guidance if `~/.local/bin` is not currently on `PATH`

The install should be idempotent.

Preferred implementation: lightweight wrapper scripts in `~/.local/bin` that exec the repo-local scripts. This is more explicit and easier to update than symlinks when paths move.

### 3. `c2c-whoami`

`c2c-whoami` tells a Claude session who it is in the C2C system.

Resolution behavior:

- accept an optional explicit session selector
- if no selector is provided, infer from current environment when possible
- if multiple live sessions could match, fail clearly and ask for session ID or PID

Output should include:

- alias
- session name
- session ID
- registration status
- short tutorial text

Human-readable example:

```text
Alias: storm-ember
Session: C2C-s2
Session ID: d5722f5b-6355-4f2f-a712-39e9a113fc06
Registered: yes

What is C2C?
C2C lets opted-in Claude sessions on this machine message each other by alias.

Common commands:
- c2c-list
- c2c-send <alias> <message...>
- c2c-verify

Typical flow:
1. Run c2c-list to see other opted-in sessions.
2. Send a message with c2c-send <alias> <message...>.
3. Use c2c-verify to inspect transcript-backed progress.
```

Also support `--json` for tests and automation.

### 4. Registration Self-Notify

After `c2c-register` succeeds, it should send a short onboarding message into the newly registered session.

That message should say:

- you are now registered for C2C
- your alias is `<alias>`
- run `c2c-whoami` for current details and the tutorial
- run `c2c-list` to see other opted-in sessions
- use `c2c-send <alias> <message...>` to talk to a peer

This message should contain onboarding only. It should not list current peers directly.

To avoid repeated noise, re-registering an already registered live session should not resend onboarding unless an explicit `--notify` or similar option is added later. For this slice, the simplest rule is:

- send onboarding only on first successful registration of the current live session

## Data Flow

Install flow:

1. operator runs `c2c-install`
2. command writes or updates user-local wrappers in `~/.local/bin`
3. command prints PATH status and next steps

Registration flow:

1. operator runs `c2c-register <session>`
2. command resolves live session and updates registry
3. command sends onboarding message to that same session if newly registered
4. command returns alias details

Whoami flow:

1. session runs `c2c-whoami`
2. command resolves the live session and registration record
3. command prints alias, session details, and tutorial

## Testing Strategy

Keep tests CLI-first for public behavior, with focused unit tests only where external PTY delivery must be mocked.

Automated coverage should include:

1. `c2c-install` creates or updates wrappers in a test-local install dir
2. installed wrappers resolve to the expected repo checkout
3. `c2c-whoami --json` returns alias/session/tutorial data for a registered session
4. `c2c-register` sends onboarding only for a new registration
5. re-registering the same live session is still idempotent and does not resend onboarding
6. the live-path bug reproduction now passes: register two sessions, then list returns those same opted-in sessions

To make install tests safe and deterministic, support test-only environment overrides for:

- install target directory
- home directory or user bin path
- sessions fixture path
- registry path

## Error Handling

`c2c-install` should fail clearly when:

- the install target cannot be created or written
- a wrapper cannot be updated

`c2c-whoami` should fail clearly when:

- the session is not registered
- the session cannot be uniquely identified

`c2c-register` should still fail clearly when:

- the target session is missing
- session name is ambiguous
- the onboarding injection fails

For onboarding failures, prefer returning a non-zero exit because the user explicitly asked for registration to perform that message delivery.

## Recommended Implementation Sequence

1. reproduce and fix the `c2c-register` / `c2c-list` live mismatch
2. add failing tests for install and `whoami`
3. implement `c2c-install`
4. implement `c2c-whoami`
5. extend `c2c-register` to send onboarding on first registration
6. rerun the full CLI suite
7. verify installed commands on the real machine
8. resume the live autonomous chat run
