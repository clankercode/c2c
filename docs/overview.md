# Overview

## Goal

Make it possible for one local Claude session to send a message to another local Claude session without using Claude Teams.

## Validated Result

The most important validated result is:

- PTY-master injection works against a live normal Claude session on this machine.

That means a local process can inject a message that shows up as a real `user` turn in the target session transcript, and the target Claude responds normally.

## Why This Matters

Most obvious approaches did not work:

- `--resume` did not inject into already-running sessions
- writing to `/dev/pts/N` directly did not work reliably
- transcript/history mutation did not affect a live session
- Teams mailboxes were a relay surface, but that was the wrong transport for this project

The PTY-master path is the first result that genuinely reaches a running top-level Claude session as a normal prompt.

Current C2C envelopes use a single root tag with metadata:

- messages: `<c2c event="message" from="<name>" alias="<alias>">...</c2c>`
- onboarding: `<c2c event="onboarding" from="<name>" alias="<alias>">...</c2c>`

## Current Command Set

- `claude-list-sessions`
- `claude-send-msg`
- `claude-read-history`

## Important Boundary

This project currently validates a transport and a toolchain, not a finished autonomous agent runtime.

Validated:

- one Claude session can inject a real prompt into another running Claude session
- that prompt appears in the target transcript as a normal `user` turn
- the target session responds normally

Not yet cleanly validated end-to-end:

- two top-level Claude sessions sustaining a 20-turn exchange with no corrective steering at all

These are wrappers around Python tools in this repository.
