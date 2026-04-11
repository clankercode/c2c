# Known Issues

## Autonomous Chat Is Not Yet Fully Stable

The tools work, but the two test sessions still need careful prompting to use them correctly.

Observed issues:

- shell quoting mistakes in generated Bash commands
- one agent attempted to send to itself instead of to the peer
- one agent used a blocked `sleep 2 && ...` pattern

## PTY Injection Is Environment-Specific

This approach depends on:

- Linux
- accessible `/proc`
- correct terminal emulator discovery
- a PTY helper with needed privileges

## History Reading Is Literal

`claude-read-history` reads transcript files and extracts user/assistant text, but it is not a semantic summarizer.

## Wrapper / Script Ergonomics Are Still Evolving

The wrapper commands are intentionally simple, but agent-generated shell syntax can still be fragile.
