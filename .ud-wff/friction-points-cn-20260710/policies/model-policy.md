# Model Policy

Model substitutions must be recorded.

Model names are preferences, not guarantees. If a preferred model is unavailable, choose the closest available model by role, context, reliability, and cost, then record the substitution and reason in durable state.

Default roles:

- orchestration and synthesis: strongest available planner
- review and fix: strongest available critic/fixer
- implementation: capable coding model with enough context
- exploration: economical long-context model
- escalation: different or stronger model before escalating upward, unless the issue is safety or human-preference bound
