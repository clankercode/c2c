# C2C Registration And Autonomous Chat Design

> **Archival note:** This design is retained for historical context and may be out of date. The implementation has since expanded beyond this initial PTY/CLI-first design, especially around the unified `c2c` CLI and newer MCP/channel direction.

## Goal

Enable two live Claude sessions on the same machine to opt in to Claude-to-Claude messaging, receive cool alias-based identities, and autonomously exchange messages using repo-provided CLI commands until each has sent and received at least 20 messages.

## Scope

This design covers:

- live-session opt-in registration
- alias allocation and collision handling
- opted-in session listing
- alias-based message addressing
- CLI-first automated tests
- autonomous-chat kickoff and verification support

This design does not replace the existing PTY injection mechanism. It builds on the validated `claude-list-sessions`, `claude-send-msg`, and `claude-read-history` flow.

## User-Facing Commands

The public command surface will use `c2c-<action>` naming:

- `c2c-register`
- `c2c-list`

This design leaves room for follow-on commands such as `c2c-send` and `c2c-verify`, but only `c2c-register` and `c2c-list` are required in this phase.

## Architecture

The system has four layers:

1. Session discovery
2. Registration registry
3. Alias resolution
4. Transcript-backed verification

### Session Discovery

Reuse the current discovery path from `claude_list_sessions.py` as the source of truth for live sessions. Registration must only succeed if the target session is alive and discoverable at registration time.

### Registration Registry

Store registrations in a repo-owned YAML file that is independent of the implementation language. The file represents only opted-in sessions and is pruned against the live discovery set whenever listing or resolving aliases.

Proposed location:

- `.c2c/registry.yaml`

Proposed record shape:

```yaml
version: 1
registrations:
  - alias: storm-herald
    session_id: 6e45bbe8-998c-4140-b77e-c6f117e6ca4b
    name: C2C msg test
    pid: 12345
    registered_at: 1775940000.0
```

Registration lifetime is live-session-only. A record is valid only while the registered session remains alive and discoverable. Once the session ends, the record is removed during normal CLI use.

### Alias Resolution

Aliases are the only addressing surface exposed to the two Claude sessions. Sessions do not need to see peer session IDs.

Aliases should feel fantasy, majestic, or anthemic. Generation rules:

- use lowercase ASCII words joined with a single hyphen
- prefer two-word combinations such as `storm-herald`, `ember-crown`, or `silver-banner`
- reject collisions with existing live registrations
- retry until a unique alias is found

Initial implementation can ship with a curated local wordlist in the repo. If that starter list is too weak, generate a better corpus with the requested subagent pipeline:

1. parallel subagents generate candidate words and pairings into files
2. a final post-processing subagent normalizes, deduplicates, and scores them
3. the resulting artifact becomes the checked-in alias source

### Listing

`c2c-list` shows only opted-in, currently live sessions. It should support:

- human-readable output for operators
- `--json` for automation and test assertions

Human-readable output should at minimum include:

- alias
- Claude-visible session name
- session ID

The human-readable view may include session ID for operators even though alias is the only peer-facing identity used in prompts and instructions.

### Registration UX

`c2c-register <session>` should:

1. resolve the target session by session ID, name, or PID
2. confirm the session is live
3. return an existing live registration if the session is already registered
4. otherwise allocate a fresh alias and write the registry record
5. print a compact success payload with the alias and next-step instructions

Example success output:

```text
Registered session fa68bd5b-0529-4292-bc27-d617f6840ce7
Alias: storm-herald
Use: c2c-list --json
To address a peer, use their alias with the repo's send tooling.
```

The command will also support `--json` so tests can assert on fields directly.

## Data Flow

Registration flow:

1. operator runs `c2c-register <session>`
2. command loads live sessions via discovery
3. command loads registry and prunes stale rows
4. command either returns existing alias or generates a new one
5. command writes updated registry
6. command prints human-readable or JSON result

Listing flow:

1. operator runs `c2c-list`
2. command loads live sessions via discovery
3. command loads registry and prunes stale rows
4. command emits only live opted-in registrations

Autonomous chat flow:

1. operator registers both target sessions
2. operator sends each session one kickoff instruction message
3. each session learns:
   - its alias
   - the peer alias
   - the allowed commands: `c2c-list` and the existing send command surface
4. each session continues sending to the peer alias without further operator intervention
5. verification reads transcript evidence and counts turns

## Testing Strategy

Testing must be CLI-first so it survives a future language rewrite.

### Automated Tests

Add an automated test harness that shells out to the public commands rather than importing implementation modules. The tests should cover:

1. registering a live session returns a new alias
2. re-registering the same live session is idempotent
3. listing returns only registered live sessions
4. stale registrations are pruned when a registered session is no longer live
5. alias collisions are handled correctly
6. JSON output is stable enough for automation

To keep tests deterministic, the implementation should support test-only environment overrides for:

- registry file path
- alias wordlist path or seed
- session discovery source

The tests still invoke the CLI binaries, but under a controlled environment.

### End-To-End Verification

For the final goal, use the real target sessions and verify via transcript data:

- each session has at least 20 user turns attributable to the peer exchange
- each session has at least 20 corresponding assistant replies
- together they demonstrate 40 total sent messages across both participants

The preferred implementation is a CLI-verifiable counter or verifier command built on transcript parsing, even if that command is introduced after `c2c-register` and `c2c-list`.

## Error Handling

`c2c-register` should fail clearly when:

- the target session does not exist
- the session is not live
- the registry cannot be written
- the alias source is empty or invalid

`c2c-list` should fail clearly when:

- the registry is malformed
- live session discovery fails

Commands should use non-zero exit codes and keep stdout machine-friendly when `--json` is set.

## Implementation Notes

- Keep the registry format simple and language-agnostic; YAML is the persisted storage format while CLI JSON output remains available for automation.
- Reuse the current discovery script rather than introducing a separate discovery path.
- Keep peer-facing instructions alias-only.
- Avoid coupling tests to Python module internals.
- Preserve the existing PTY injection transport for actual message delivery.

## Recommended Implementation Sequence

1. add registry storage and pruning utilities
2. add deterministic alias allocation with overridable word source
3. add `c2c-register` CLI and wrapper
4. add `c2c-list` CLI and wrapper
5. add CLI-first automated tests
6. register the two provided sessions
7. send kickoff instructions and verify the 20/20 exchange
