# B111 finding: anonymous relay room directory exposes member aliases

## Severity

High privacy metadata disclosure.

## Symptom and discovery

During B111's public-relay audit, the canonical OCaml relay's unauthenticated
`GET /list_rooms` response was found to contain a `members` array for each
listed room, not just the advertised room ID and member count.

## Root cause

`Relay_server_auth.auth_decision` explicitly permits `/list_rooms` without
authentication. Both relay stores filter the directory to `public` and
`gated` visibility, then query every matching `room_members.alias` and
serialize it as `members`; `handle_list_rooms` returns that structure without
per-caller redaction. Thus any Internet caller can correlate aliases with a
public or gated room whenever one exists.

## Impact

Public/gated room membership is public metadata. This also weakens the
quickstart's broad reading of "no public directory of aliases": `/list` is
not anonymously public, but room-directory responses can still disclose
aliases. The live relay returned an empty directory during the audit, so the
behavior was established from canonical source and local test fixtures rather
than a live populated-room scrape.

## Recommended fix status

Open. Make anonymous directory rows omit `members` (return only room ID,
visibility, and count), and return a roster only to a valid Ed25519 member if
that feature is needed. Add an HTTP-level regression test for anonymous
public/gated rows. See the full, evidence-backed B111 audit in
`.collab/research/2026-07-11T02-25-00Z-B111-public-relay-exposure-audit.md`.
