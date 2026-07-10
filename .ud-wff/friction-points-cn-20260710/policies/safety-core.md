# Safety Core

Safety classification is non-delegatable and ambiguity escalates.

Default escalation triggers:

- destructive or irreversible actions
- secrets, production data, user data, money, legal, force-push, or deletion
- product or specification decisions with no good objective default
- major scope tradeoffs
- exhausted subagent or model escalation

Fail closed: stop before irreversible action, persist the pending escalation, and wait for human direction when no safe default exists.
