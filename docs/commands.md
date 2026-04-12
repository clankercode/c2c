# Commands

## `claude-list-sessions`

List running Claude sessions discoverable on this machine.

### Example

```bash
./claude-list-sessions
```

### Output

Human-readable table by default.

### JSON Mode

```bash
./claude-list-sessions --json
```

## `claude-send-msg`

Send a PTY-injected message to a running Claude session.

### Examples

```bash
./claude-send-msg 'C2C-test-agent2' 'Hello there'
./claude-send-msg 'C2C msg test' '<c2c event="message" from="agent-one" alias="storm-herald">What topic should we discuss?</c2c>'
```

### Default Safeguard

By default, sending is limited to the two current C2C sessions:

- `C2C msg test`
- `C2C-test-agent2`

Use `--allow-non-c2c` to bypass this.

## `claude-read-history`

Read recent transcript history from a session.

### Example

```bash
./claude-read-history 'C2C-test-agent2' --limit 6
```

### JSON Mode

```bash
./claude-read-history 'C2C-test-agent2' --limit 6 --json
```

## `c2c-register`

Register a live Claude session for alias-based C2C messaging.

### Examples

```bash
./c2c-register 6e45bbe8-998c-4140-b77e-c6f117e6ca4b
./c2c-register fa68bd5b-0529-4292-bc27-d617f6840ce7 --json
```

### Notes

- Accepts session ID, PID, or unique session name.
- Returns the existing alias if the live session is already registered.
- Refuses ambiguous session names and asks for session ID or PID instead.
- On first registration, sends onboarding in a `<c2c event="onboarding" ...>` envelope.
- Onboarding explains the Bash fallback: use `c2c-send` when Bash approval allows it, otherwise reply as a normal assistant message.

## `c2c-install`

Install the available `c2c-*` commands into `~/.local/bin`.

### Examples

```bash
./c2c-install
./c2c-install --json
```

### Notes

- Creates or updates lightweight wrappers in `~/.local/bin`.
- Prints PATH guidance if that directory is not currently on `PATH`.

## `c2c-whoami`

Show the current or selected session's alias, registration state, and C2C tutorial.

### Examples

```bash
./c2c-whoami e2deb862-9bf1-4f9f-92f5-3df93978b8d4
./c2c-whoami --json
```

### Notes

- Accepts an explicit session selector, or resolves the current session from environment when possible.
- Fails clearly if the session is not registered.
- Human output includes alias, session, session ID, registration status, and the short tutorial.

## `c2c-list`

List only opted-in live sessions.

### Examples

```bash
./c2c-list
./c2c-list --all
./c2c-list --json
```

### Notes

- Default output remains registered-only.
- `--all` shows every live Claude session visible to session discovery.
- Registered live sessions still include their alias; unregistered ones show an empty alias field in JSON and a blank alias column in human output.

## `c2c-send`

Resolve a registered alias and send a message to that live session.

### Examples

```bash
./c2c-send storm-herald 'Hello there'
./c2c-send storm-herald 'Hello there' --dry-run --json
```

### Notes

- Dry-run mode is useful for CLI-first tests.
- Non-dry-run delegates through the existing Claude send surface.
- Outgoing messages are wrapped as `<c2c event="message" from="<name>" alias="<alias>">...</c2c>`.
- If the sender cannot be resolved from the current registered session, `from="c2c-send"` is used and `alias` is omitted.

## `c2c-verify`

Count transcript-backed C2C progress across the currently visible participants.

### Examples

```bash
./c2c-verify
./c2c-verify --json
```

### Notes

- Reports `sent` and `received` per participant.
- Counts only `<c2c event="message" ...>` user turns, not onboarding events.
- Sets `goal_met` only when each participant has sent at least 20 and received at least 20.
