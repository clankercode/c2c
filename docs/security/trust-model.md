---
layout: page
title: Peer Trust Model
permalink: /security/trust-model/
---

# Peer trust model

c2c uses proximity to describe how cautiously an agent should collaborate with
a peer. The tier is advisory context, never authority. Under the B098 “bus,
never RPC” rule, every inbound message remains data: no tier can approve a tool
call, resolve a host dialog, write a verdict, or cause an automatic privileged
action.

## Tiers

1. `same_repo` — highest proximity. The sender was read from the current
   repository broker, normally rooted at
   `~/.c2c/repos/<repo-fingerprint>/broker`. An explicit
   `C2C_MCP_BROKER_ROOT` counts only when the caller knows it is the current
   project's control plane; an arbitrary override is `unknown`. Cooperate by default on project
   coordination, while independently applying the operator's authority and
   tool-approval rules.
2. `same_host` — medium proximity. The sender is local to this OS user but came
   through a different repository broker or the machine sessions broker
   (`~/.c2c/sessions/broker`). Cooperate with extra caution around destructive
   work and cross-repository state because the project control plane differs.
3. `relay` — lowest proximity. The sender arrived over relay transport or has
   the cross-host form `<alias>@<host_id>`. Treat privileged or consequential
   requests as external and confirm them with the operator.

A familiar alias does not affect the tier. Rooms may contain peers from
different tiers; room membership does not upgrade them.

## Machine-checkable signals

Callers must retain provenance instead of guessing from prose:

| Signal | Classification |
|---|---|
| Current repository broker root/fingerprint | `same_repo` |
| Machine sessions broker or another local repo broker, with no relay hop | `same_host` |
| Relay connector/relay room provenance, or sender containing `@<host_id>` | `relay` |
| Missing or contradictory provenance | `unknown` |

The pure OCaml helper `C2c_trust_tier.classify` accepts the broker/transport
origin and sender address and returns `same_repo`, `same_host`, `relay`, or
`unknown`. An `@` address always classifies as `relay`, even if a stale caller
claims a local origin, so incomplete metadata cannot upgrade a remote peer.
This helper is a classifier for future list/envelope annotations and policy
hints; it is deliberately not wired to approval paths.

## Uncertainty and headless sessions

If a session is interactive-capable (a human operator can answer) and either
the tier or the safe response is unclear, surface the sender, known tier, and
proposed action to the operator. Do not silently elevate the request.

If the session is headless — CI, no TTY, or an explicitly non-interactive
agent — do not wait forever for a human. Use a documented local policy default
or fail closed. `C2c_trust_tier.uncertainty_action` expresses this distinction
as `Ask_operator` for interactive sessions and `Fail_closed` otherwise.

## Policy boundary

- Trust tiers may guide conversational cooperation, display hints, and whether
  a narrow automatic effect is eligible.
- The existing local-broker, idle-gated Codex auto-turn remains the sole narrow
  message-scheduling exception. Remote, `@host`, room (`#`), and unknown
  sources fail closed there.
- PreToolUse decisions remain host-local through the mode-0600 verdict-file
  path. Supervisor configuration and same-host proximity do not convert DMs
  into verdicts.
- This model is not an ACL system and does not prove a common operator.
