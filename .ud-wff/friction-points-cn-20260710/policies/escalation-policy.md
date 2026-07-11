# Escalation Policy

Escalation tries lower levels first before escalating upward.

A worker first records the blocker and tries safe local resolution within its task scope. If unresolved, it escalates to the coordinator with evidence, attempted fixes, and the specific decision needed.

Escalate to a human for safety triggers, destructive or irreversible actions, unclear product decisions, major scope tradeoffs, custom user-defined conditions, or exhausted model/subagent escalation.
