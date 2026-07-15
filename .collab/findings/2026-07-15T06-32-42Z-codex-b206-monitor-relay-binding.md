# B206 monitor relay-binding root cause

## Symptom

Fresh Grok and other CLI-first aliases start a local `c2c monitor`, print a
relay peek target, then immediately receive `unauthorized: alias ... has no
identity binding`. Relay watch disables while the local inbox watch survives.

## Root cause

The client install/SessionStart path deliberately registers the session only
in its repository broker. A direct relay inbox is a separate security domain:
`c2c relay register --alias A` binds `A` and `cli-A/cli-A` to the machine's
Ed25519 key. `decide_relay_watch` previously checked only relay URL + resolved
alias, so it advertised and started the direct watcher without evidence of
that binding. The relay correctly rejected the signed peek; retrying cannot
create the missing binding.

## Product fix

Monitor now makes a short, signed, non-mutating `/list` preflight. The exact
missing-binding response leaves relay watch off with one actionable status;
local monitoring remains independent. No alias is silently bound.

`--register-relay-alias` is the explicit one-shot bootstrap. It reuses the
canonical signed `relay register` operation and is allowed only when the alias
comes from `--alias`, the auto-register environment, or this session's broker
registration; a machine identity exists; the connector does not own the alias;
and no custom relay key was requested. This prevents a machine-global fallback
alias from being accidentally claimed and keeps connector registration under
the connector's control.

## Duplicate-line investigation

There is one relay thread creation site and the hard-terminal path is guarded
by `terminal_logged`. The per-broker/per-alias monitor lock also refuses a
second live process for the same alias. A read-only live-process check on
2026-07-15 found one process for each reported Grok alias, including
`grok-arch-osprey-qsnz`; other monitor processes belonged to distinct aliases
and repositories. No second in-process log path was found. The duplicated paste
is therefore consistent with host capture/display duplication, not two relay
loops. The B206 preflight also removes the multi-line terminal cascade for the
expected unbound-alias case.
