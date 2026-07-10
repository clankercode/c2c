# Signed relay peek omits inbox ownership authorization

Severity: **critical**

## Symptom

An authenticated caller can non-destructively read a different known/predictable
`node_id/session_id` inbox even though the equivalent signed poll is rejected.

## Discovery

T2 compared adjacent HTTP handlers. `handle_poll_inbox` checks the verified
alias against `alias_of_session` (`ocaml/relay.ml:3168-3183`), while
`handle_peek_inbox` receives no `verified_alias` and reads the requested inbox
directly (`:3185-3192`; route at `:4451-4455`). No victim/attacker negative test
was found.

## Root cause

B096 added a read path by copying the storage operation without copying the
signed-owner authorization boundary. Non-destructive is a delivery semantic,
not permission to weaken read authorization.

## Fix status

Open and independently dispatchable. Pass verified identity into peek, reuse
poll's owner check, decide whether unsigned peek is permitted at all, and test
victim/attacker requests against both in-memory and SQLite relay backends.
Durable cursors/acks remain deferred under I004 and are not part of this hotfix.
