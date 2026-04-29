# Operator-staged approval — brainstorm (stanza, 2026-04-29)

Spawned from the pending-permissions audit
(`.collab/research/2026-04-29-stanza-coder-pending-permissions-audit.md`)
"Note on framing": the existing pending_reply mechanism is a
**request-reply binding registry**, not a human-in-the-loop gate. This
doc explores what a real operator gate would look like.

## 1. Use cases

Sorted by current-friction and how clearly they want a *human* (not
just "another agent supervisor"):

- **Push to `origin/master`** — Cairn manually gates today; runbook
  rule "coordinator gates all pushes" is enforced by social contract.
  A staged-approval surface would make the gate mechanical.
- **`mcp__c2c__sweep`** — explicitly forbidden during active swarm ops
  (drops managed sessions); footgun-by-default. Gating it through Max
  would have prevented the 2026-04-13 storm-ember incident.
- **`c2c restart-self` / `restart <peer>` / `stop_self`** for peers
  not your own — coord1 has authority today by social contract; staged
  approval would let *anyone* request a peer restart and Max approves.
- **Production relay deploys** (Railway $) — push that triggers a 15min
  Docker build. Today the gate is "DM coord1 with SHA"; could be
  formalised.
- **Promoting a finding/runbook/role to `docs/`** (publish-by-default
  Jekyll) — current hygiene rule "default to `.collab/`" is advisory.
- **Spending tokens on minimax/video skills, web fetches against $-API
  endpoints, or invoking other paid MCPs.**
- **Deleting / `git reset --hard` / shared-tree mutation** — already
  flagged in CLAUDE.md as require-checking-with-team.
- **Cross-repo writes** once relay/remote topology lands — anything
  that mutates state outside the local tree.

The unifying property: *irreversible, expensive, or socially-load-bearing*.
"Send a DM" never needs a gate; "push to master" always does.

## 2. Surface options

**(a) DM-based ("ask coord1 / ask max").** Already how this works
informally. Format: agent sends `<approve perm_id="...">` style envelope
to a designated approver; broker waits for reply.
- Pros: zero new infra; reuses delivery mechanism; works on every
  client; offline-tolerant (broker buffers).
- Cons: humans-in-DMs is what we're trying to escape; approval mixed
  with chatter; no structured audit; no batch UI.

**(b) TUI panel in the existing tmux swarm layout.** A `c2c approvals`
TUI pane that lists pending ops, shows diff/cmd/cwd/agent, and offers
`a/d/?` keybinds. Lives alongside the swarm panes Max already watches.
- Pros: matches Max's actual workflow (`scripts/c2c_tmux.py` already
  the lingua franca); structured; greppable history; offline = queue
  fills until Max reconnects.
- Cons: tmux-only; doesn't help if Max is on phone; new code surface
  (~moderate — Bubble Tea-style or just a polling printf loop).

**(c) Web UI on the relay (`https://approvals.c2c.im`) + push.**
Operator clicks approve from anywhere. Auth via personal token or
GitHub OAuth.
- Pros: out-of-band (works when Max is mobile); persistent log;
  could fan out to multiple approvers later.
- Cons: real auth/CSRF/transport problem; requires relay change ($);
  defers approval into "I'll do it later" purgatory.

**Pick: (a)+(b).** DM-based is the substrate (broker primitive);
TUI is a thin client on top that polls and renders. Web UI is
post-MVP — file the design but don't build until DM+TUI proves the
pattern.

## 3. State machine

```
PENDING ──approve──> APPROVED ──executed──> DONE
   │                     │
   ├──deny─────> DENIED  └──exec-fails──> FAILED
   ├──ttl─────> EXPIRED
   └──cancel──> CANCELLED   (requester withdraws)
```

- **TTL**: default 30min for pushes, 5min for restarts/sweeps; tunable
  per-op-type. Same lazy-expiry pattern as pending_permissions.
- **Operator absence**: TTL fires → EXPIRED → requester gets denial
  with reason="ttl"; agent decides retry vs give up. Critical: do NOT
  default-approve on absence.
- **Once approved**, broker executes in-process or returns a one-shot
  capability token the requester redeems within ~60s; token bound to
  `(perm_id, op-fingerprint)` so the agent can't swap the op after
  approval.
- **Idempotency**: same perm_id approved twice = second approval is
  a no-op; same perm_id used twice to redeem = second redeem fails.

## 4. Identity

Three layers, pick combination by deployment:

- **OS-level (MVP).** Broker runs as Max's user; the TUI client
  connecting via the local broker socket *is* Max by construction. Same
  trust boundary as the rest of c2c today.
- **Designated approver alias** (e.g. `coordinator1`, or a literal
  `human:max` reserved alias). Operator's MCP/CLI session registers as
  that alias; approval = a DM/tool call from that session. Inherits
  c2c's existing alias-spoofing protections (M3+M4).
- **Ed25519 signature** (post-MVP). Approval message signed with a key
  whose pubkey is in `.c2c/config.toml [approvers]`. Required once relay
  carries approvals across hosts — local-socket trust dissolves the
  moment it goes over the wire.

Avoid shared-secret: rotates poorly, leaks into logs.

## 5. Failure modes

- **Operator approves a malicious op.** Out of scope for the broker —
  this is the "trust the human" assumption. Mitigation: show the *full*
  op (cmd, env, cwd, diff for git ops) in the approval prompt; default
  to deny on TUI timeout; second-eye approval (k-of-n) for high-stakes
  classes like `push` if/when ed25519 lands.
- **Compromised agent floods the queue.** Per-alias cap (e.g. 5 open),
  global cap (e.g. 100), exponential backoff after deny. Borrow Slice C
  from the audit. Operator sees flood as N entries from same alias and
  can `c2c approvals ban <alias>` for the session.
- **Race: agent approved-then-revoked.** Capability token has its own
  short TTL; if revoked, broker returns deny on redeem.
- **Operator approves wrong op due to UI confusion.** Show
  `op-fingerprint` (sha256 of canonical op repr) prominently; agent
  echoes it in the request and the TUI renders side-by-side.
- **Approval forgery (cross-session).** Mitigated by §4; the approval
  RPC must be authenticated to the approver alias.
- **Broker crash mid-approval.** Persist `(perm_id, state, decision)`
  before executing, reload on restart, expose `c2c approvals replay`.
  Same `<broker_root>/approvals.json` shape as `pending_permissions.json`.

## 6. Relationship to existing pending_reply

**Layered, not generalised.** The existing mechanism is purely about
*alias-binding* of replies for an agent-to-agent permission DM cycle.
Operator-staged approval is a different abstraction: a **two-party
contract** between agent and human, where the broker is the escrow.

Pragmatic shape: a new `Broker.approval_*` API and
`<broker_root>/approvals.json`, with the **same lock + cap + audit
hardening** the audit recommends for pending_permissions (Slices A/C/D).
Don't try to unify schemas now — the requester/supervisor field shapes
diverge (supervisors-list vs single-approver-class), and the lifecycle
differs (request_reply lifecycle is "until the supervisor agent
replies"; approval lifecycle is "until human reacts or TTL"). Build
both on a shared `pending_state.ml` module if/when a third pattern
lands. YAGNI today.

The `op-fingerprint` idea *could* fold back into pending_permissions as
"prove the supervisor saw the same op the requester sent" — a nice
hardening but not required for MVP.

## 7. MVP scope (Phase 1)

Goal: make `c2c push` (and only `c2c push`) gated through Max via TUI,
with DM as a fallback.

1. New broker tools: `request_approval(op_kind, op_payload, fingerprint)
   → perm_id`; `decide_approval(perm_id, decision, reason?)`;
   `redeem_approval(perm_id, fingerprint) → token | error`.
2. New broker file: `<broker_root>/approvals.json`, locked, capped,
   audited (apply audit Slices A+C+D from day one — don't repeat the
   pending_permissions hardening backlog).
3. New CLI: `c2c approvals list|approve|deny|tail` — operator-side. The
   `tail` subcommand is what the TUI wraps.
4. `c2c push` integration: instead of running `git push`, the wrapper
   calls `request_approval(op_kind="git_push", op_payload={remote, ref,
   sha, head_summary}, fingerprint=sha256(payload))`, blocks on
   `redeem_approval`, then runs the push only after token returns OK.
5. Approver identity: OS-level only (designated alias `coordinator1`
   or `human:max`, configured in `.c2c/config.toml [approvers]`).
6. TUI: minimal — `c2c approvals tail` prints incoming with the
   fingerprint, prompts for `a/d/skip`, sends decision DM. Bubble Tea
   later.

That's it. ~3-4 commits, one slice. Use the existing
pending_permissions hardening work as the template.

Phase 2 candidates (do not build yet): web UI; ed25519 signatures;
k-of-n approval; integrating sweep/restart-self; auto-approve rules
("approve any push from coord1 of <50 LoC docs-only"); cross-repo via
relay.

## 8. Open questions for Max

1. **Is Cairn currently doing this work and would she welcome
   automation, or does she value the manual gate as a sanity check?**
   If the latter, MVP is wasted — better to harden pending_permissions
   and wait. (Tentative: she has standing push authority; an automated
   gate routed to *her*, not Max, is more likely the win.)
2. **Approver = Max only, or Max + designated agent (e.g. coord1)?**
   If coord1 can approve, this is more "delegation" than
   "operator-in-the-loop"; changes the threat model.
3. **Should `c2c push` block synchronously, or queue + come back later?**
   Synchronous is simpler; queue lets the agent move on. Coord workflow
   suggests queue.
4. **Default-deny on TTL, or default-approve on operator-quiet?**
   I assumed default-deny; want to confirm.
5. **Web UI in scope, or ruthlessly avoid until DM+TUI shows demand?**
6. **Does this absorb / replace the "push readiness" check in
   `c2c doctor`, or layer on top?** Doctor classifies; approval
   decides — feels orthogonal but worth confirming.
7. **Naming**: "approval" vs "gate" vs "consent" vs "permission" (ugh,
   collides with pending_permissions)? Naming ambiguity here will
   confuse future readers.
8. **k-of-n in scope ever?** If yes, ed25519 needs to land earlier;
   shapes Phase 1 token format.

---

*Read-only brainstorm — no code, no commits. If Max wants to proceed,
next step is a SPEC under `.collab/design/` for Phase 1 (steps 1-6
above) before any worktree.*
