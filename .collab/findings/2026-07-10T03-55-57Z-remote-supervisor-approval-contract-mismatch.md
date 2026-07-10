# B098's strict approval contract conflicts with configured-supervisor DM behavior

Severity: **critical** (classification advisory; coordinator owns final)

## Symptom

Checked-in prose simultaneously says a message never satisfies approval and
allows a token-bearing inbox DM from a locally configured supervisor—including
a remote peer—to return an approval verdict.

## Discovery

The B098 backlog requires local-operator-only approval unreachable from any
relay-delivered message. `inbox_verdict_if_trusted` returns `allow|deny` for a
configured sender with the token (`ocaml/cli/c2c_approval_paths.ml:485-508`),
and `await_reply_cmd` consumes ordinary inbox messages. Tests explicitly accept
supervisor DMs and only reject non-supervisors. Relay delivery writes into the
same inbox, whose message type lacks transport provenance.

## Root cause

Implementation weakened “remote never approves” into “only a locally configured
sender approves,” but the backlog, test name, changelog, AGENTS/CLAUDE prose, and
code comments were not reconciled. These are materially different security
contracts.

## Fix status

**Decision resolved; implementation open.** The coordinator selected the strict
contract in `.collab/research/friction-cn-b098-decision.md`, based on the direct
operator request to complete the report plus critical backlog B098. H1 is
unblocked: remove the legacy inbox-DM verdict fallback, accept only the
host-local verdict-file/CLI path, and prove that even a configured-supervisor
inbox/relay message is inert. The weaker remote-supervisor RPC contract was
rejected for this run.
