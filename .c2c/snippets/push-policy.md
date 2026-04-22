## Push Policy

**Do NOT push to origin directly.** coordinator1 is the gate.

### When to Push

Push only when something needs to be live — a relay change peers need, a website fix, or a hotfix unblocking the swarm.

"Feature finished + tests green" is NOT a reason to push. Local install validates that, and 15 minutes later is free.

### How to Push

1. Commit locally at full speed
2. DM coordinator1 with the SHAs + what needs deploying
3. coordinator1 decides if the deploy is warranted

### Urgent Hotfixes

Urgent hotfix to the production relay blocking the whole swarm — flag in `swarm-lounge` first, then DM coordinator1.

### Post-Deploy Validation

After a Railway deploy, run `./scripts/relay-smoke-test.sh` to validate the new relay.
