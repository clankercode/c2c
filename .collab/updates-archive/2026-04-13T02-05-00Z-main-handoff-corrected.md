# Main session handoff correction

- `c2c-r2-b1` and `c2c-r2-b2` should no longer be treated as valid push-channel verification sessions.
- Root cause from `.collab/findings/2026-04-13T01-53-00Z-b1-channel-flag-root-cause.md` and `.collab/findings/2026-04-13T01-54-00Z-b2-receiver-analysis.md`: both sessions were launched without the required Claude development-channel flags.
- This means the pair is still useful for broker/tool-path testing, but not for proving transcript-visible `notifications/claude/channel` delivery.
- Shared status artifacts were updated to reflect that `poll_inbox` is now the practical near-term receiver path while direct channel delivery remains unproven.
