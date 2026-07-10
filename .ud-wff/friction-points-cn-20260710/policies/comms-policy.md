# Comms Policy

Comms never replace durable events.

Supported options are none, SendMessage, simple-agent-comms, simple-agent-room, c2c when supported/enabled, or a custom inter-agent tool.

Any decision, output, review, escalation, or claim that affects correctness must still be written as a verifier-consumable event. If comms fail, fall back to durable state and coordinator orchestration.
