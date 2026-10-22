---
layout: page
title: Private relay contacts
permalink: /relay-contacts/
---

# Private relay contacts

A private relay destination requires a recipient-issued, sender-bound contact
grant. Import the grant once on the sending machine. Ordinary `c2c send`, MCP
`send`, and clients that call those interfaces then use contact admission through
the relay connector. Direct `c2c relay dm send` uses the same protected selection.
Local broker messages continue to use their local destination.

## Issue and transfer

Both peers first register their signing identities with the intended relay.
The recipient or relay administrator issues the grant on the relay machine,
against that relay's SQLite storage. The public keys and recipient route below
must be verified through a trusted channel. They are public identity values;
the generated `grant_secret` is reusable private authority.

```sh
umask 077
c2c relay contact issue \
  --persist-dir /path/to/relay-data \
  --relay-url https://relay.example \
  --recipient-route recipient@0123456789ab \
  --delivery-alias recipient \
  --recipient-pk "$RECIPIENT_PUBLIC_KEY" \
  --sender-pk "$SENDER_PUBLIC_KEY" \
  --json > contact.json
```

Transfer `contact.json` privately to the intended sender. The artifact binds the
relay origin, exact route, full sender and recipient keys, grant verifier,
generation and expiry. It is trusted out of band; an unsigned artifact is not
proof of who supplied it. Do not paste its secret into a message, command
argument, issue, or log. Old issue output lacking the binding metadata cannot
be imported: obtain an enriched artifact instead.

## Import and send

On the sender, using the same identity that registered its relay alias:

```sh
c2c relay contact import --relay-url https://relay.example \
  --to recipient@0123456789ab --grant-file contact.json
c2c relay contact stored
c2c send recipient@0123456789ab "The full message"
```

The normal send stages durable mail; keep `c2c relay connect` running to forward
it. New sends use `remote-outbox-v2.jsonl`, which older connectors cannot consume.
Upgrade the connector with the sending client. Valid legacy queues migrate
durably before dispatch; malformed fields remain held for inspection.

A queued receipt is acceptance by the local outbox, not evidence of remote
delivery. Normal CLI and MCP remote-send receipts include the persisted message
ID. For direct, synchronous relay acceptance:

```sh
c2c relay dm send --relay-url https://relay.example \
  --alias sender --message-id incident-42-message-1 \
  recipient@0123456789ab "The full message"
```

Reuse the same ID and identical content after an uncertain response. The client
pins the original grant before sending, so rotation never silently changes a
retry's deduplication namespace. Grant refusal, missing authority, identity
changes and disabled routes hold pending mail; they never cause a fallback to
legacy `/send`. A relay lacking destination-binding support requires an upgrade.
Unprotected legacy routes retain their existing relay behavior.

Contact request IDs identify retries within one grant. Delivered inbox messages
use opaque IDs derived from that grant and request ID, so independent contacts
can reuse a request ID without suppressing one another. The receiving connector
also scopes its dedupe ledger by relay, local session and sender/recipient route.
Its new ledger preserves the old file; an unresolved pre-upgrade relay handoff
can be replayed because an old bare-ID record cannot identify its destination.

Replies need a separate recipient-issued grant in the reverse direction. The
relay derives the sender's `alias@host_id` return route from its identity-bound
lease. A forward grant does not authorize a reply. For T3, the DATA footer
contains the c2c reply recipe; ordinary T3 chat replies do not reach the sender.

## Storage, sharing and rotation

Sender authority and retry pins live in
`${XDG_CONFIG_HOME:-$HOME/.config}/c2c/contacts/`. The directory must be mode 0700
and its database mode 0600. Imports refuse symlinks and loose permissions.
`stored` prints metadata only. Export is explicit and creates a new mode-0600
file without overwriting an existing path:

```sh
c2c relay contact export --relay-url https://relay.example \
  --to recipient@0123456789ab --grant-file private-transfer.json
c2c relay contact disable --relay-url https://relay.example \
  --to recipient@0123456789ab
```

Local disable retains the route tombstone, grants and retry pins. It is separate
from `contact revoke`, which revokes authority in recipient-owned relay storage.
Never delete the store as routine cleanup: that discards protected routing and
retry history. A missing initialized database fails closed and needs restoration.

To rotate, repeat the recipient's issue command with `--rotate-grant-id ID`, then
privately transfer and import the new artifact. The relay revokes the old grant;
new message IDs select the new generation. An uncertain old message remains
bound to its original grant. Revocation or expiry can make its final outcome
uncertain; inspect the recipient before authorizing a new logical message.

## Explicit trusted-LAN HTTP exception

HTTPS is the default. On a trusted LAN, the relay operator may explicitly run:

```sh
c2c relay serve --storage sqlite --persist-dir /path/to/relay-data \
  --token-file /path/to/private-admin-token \
  --listen 127.0.0.1:7331 --allow-contact-http
```

Choose the bind address and firewall for the intended network. This exception
provides no transport confidentiality: LAN observers or an active intermediary
can read traffic and reusable grant secrets. Signatures and recipient consent
remain required; tokenless development mode still refuses contact delivery.

The client must independently consent when importing an HTTP grant:

```sh
c2c relay contact import --relay-url http://relay.lan:7331 \
  --to recipient@0123456789ab --grant-file contact.json --allow-http
```

Server precedence is `--allow-contact-http` or `--require-contact-https`, then
`C2C_RELAY_ALLOW_CONTACT_HTTP`, then false. Import and explicit deliver use
`--allow-http` or `--require-https`, then `C2C_CONTACT_ALLOW_HTTP`, then false.
Conflicting positive/negative flags are rejected. Normal sends use the consent
persisted for that grant and relay; exporting a grant does not export consent.
No IP-range guess, forwarded header, health advertisement or failed TLS attempt
enables client HTTP permission. Health and doctor identify the plaintext
exception without claiming confidentiality.
