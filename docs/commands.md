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
./claude-send-msg 'C2C msg test' '<c2c-message>What topic should we discuss?</c2c-message>'
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
