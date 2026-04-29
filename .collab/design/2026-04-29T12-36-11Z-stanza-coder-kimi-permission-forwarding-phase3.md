# Kimi Permission Forwarding — Phase 3 (kimi-as-peer parity)

**Author**: stanza-coder
**Date**: 2026-04-29
**Status**: Design / research-only — implementation owner TBD (#142 family)
**Related**: #478 (auto-approve `mcp__c2c__*`), kimi `--afk` flag (#469 / `3fbcec8e`),
permission DM auto-reject finding 2026-04-29 (coordinator1+birch-coder)

---

## TL;DR

Kimi managed sessions today either prompt locally (operator must press 1/2/3/4 in
the kimi pane) or are run with `--afk` which auto-approves *everything*. Neither
fits the swarm goal: a coordinator dispatching kimi as a worker has no visibility
into pending approvals, and `--afk` removes review entirely. Phase 3 forwards
each pending approval to the swarm so an authorized peer can decide remotely,
with an audit trail.

**Recommended path** (3 bullets):
1. **Skip tmux-scrape**, go directly to kimi-cli's existing `WireServer` JSON-RPC
   stdio surface (`kimi --wire`). It already broadcasts every `ApprovalRequest`
   externally and accepts `ApprovalResponse` to resolve them — no kimi-cli patch
   required. We previously had a `kimi --wire` bridge for delivery; we
   deprecated it for the notification-store path, but **the wire server is
   still the right transport for control-plane ApprovalRequest / Response** and
   can run alongside the notification-store delivery daemon.
2. **Re-use c2c's existing permission-DM mechanism** (`open_pending_reply` /
   `check_pending_reply`) as the swarm-side surface — same TTL, audit, and
   reviewer model that opencode/codex permission flows already use. The
   *bridge* is a new `c2c-kimi-permission-forwarder` daemon (sibling to the
   notifier) that subscribes to kimi's wire stream, opens a pending-reply for
   each `ApprovalRequest`, and writes the supervisor's verdict back via
   `ApprovalResponse`. **Important**: address the existing in-window auto-reject
   bug (finding 2026-04-29 coordinator1+birch) before relying on this path in
   anger.
3. **Phased rollout: A = bridge daemon + manual DM-ack via existing
   `c2c send` to the supervisor; B = structured permission room +
   `c2c kimi-approve <perm-id>` CLI; C = signed approvals (peer-PASS-style) for
   cross-trust-boundary ops.** No kimi-cli upstream patch needed at any phase.

---

## 1. Findings — kimi-cli's permission internals

Kimi already has a fully-structured permission runtime exposed via JSON-RPC on
stdio. This is the most important finding of this research: **we do not need
tmux-scrape, filesystem polling, or an upstream patch**. The work upstream is
already done and is wire-compatible with what c2c needs.

### 1.1 Approval runtime (in-process)

`kimi_cli/approval_runtime/runtime.py` (ApprovalRuntime class, file installed at
`/home/xertrov/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/approval_runtime/runtime.py`):

- `ApprovalRuntime.create_request(...)` — `runtime.py:61` — called when kimi
  encounters a tool-call requiring approval. Stores an `ApprovalRequestRecord`
  (id, tool_call_id, sender, action, description, display, source) and
  publishes via two channels:
  - In-process subscribers (`subscribe()` callbacks).
  - **The wire hub** (`_publish_wire_request`, `runtime.py:206`) — serialises
    the request into a `kimi_cli.wire.types.ApprovalRequest` and pushes onto the
    `RootWireHub`'s broadcast queue.
- `ApprovalRuntime.resolve(request_id, response, feedback)` — `runtime.py:129`
  — accepts `"approve" | "approve_for_session" | "reject"` plus optional
  feedback string. Wakes whoever is `await`-ing on the request and emits an
  `ApprovalResponse` over the wire hub.
- `ApprovalRuntime.list_pending()` — `runtime.py:183` — current pending queue,
  oldest-first.
- `cancel_by_source(...)` — `runtime.py:163` — bulk-cancel for lifecycle
  events (e.g. background agent dies).

### 1.2 Wire types

`kimi_cli/wire/types.py:276-345`:

```python
class ApprovalRequest(BaseModel):
    id: str
    tool_call_id: str
    sender: str           # tool name, e.g. "Bash"
    action: str           # short verb, e.g. "execute"
    description: str      # human-readable summary
    source_kind: Literal["foreground_turn", "background_agent"] | None
    source_id: str | None
    agent_id: str | None
    subagent_type: str | None
    display: list[DisplayBlock]   # rich rendering blocks (code, diff, etc.)

class ApprovalResponse(BaseModel):
    request_id: str
    response: Literal["approve", "approve_for_session", "reject"]
    feedback: str = ""    # used to instruct the model on rejection
```

### 1.3 Wire transport

`kimi_cli/wire/server.py` (1060 LoC) is a JSON-RPC 2.0 server over **stdio**
(`acp.stdio_streams`, `server.py:113`). Lifecycle:

- Boot: kimi launched with `--wire` runs `WireServer.serve()`, which
  subscribes the wire client (over stdio) to the `RootWireHub` and replays
  the per-session `wire.jsonl` log.
- Every `ApprovalRequest` published by the runtime hub flows out as a
  `JSONRPCRequestMessage` (method `"request"`, payload type
  `ApprovalRequest`).
- The wire client replies via a `JSONRPCSuccessResponse` carrying an
  `ApprovalResponse`. `WireServer._dispatch_response` decodes and calls
  `_approval_runtime.resolve(...)` (`server.py:934`).

**Auto-cancel on disconnect**: `server.py:540` — when the wire client
disconnects, every pending request is auto-rejected with `"reject"`. This is a
constraint our forwarder must respect: *the bridge must hold a stable wire
connection for the lifetime of the kimi session*, otherwise pending approvals
get auto-rejected on every reconnect.

### 1.4 Persistent log

`wire.jsonl` per session (`session.py:175`,
`session.py:218`, `session.py:262`) records every wire message, headed with a
`{"type":"metadata","protocol_version":"..."}` line. Path:
`<KIMI_SHARE_DIR>/sessions/<workspace-md5>/<session-uuid>/wire.jsonl`.

This means the bridge has a **secondary recovery path**: if it crashes and
reconnects, it can iterate `wire.jsonl` to find unresolved
`ApprovalRequest`s — but cannot resolve them via the file (the file is a log,
not a control surface; resolution must go through the live wire connection).

### 1.5 `--afk` and `auto_approve_actions`

`kimi_cli/soul/approval.py:107-148`. State stored in
`session_state.SessionState` (`session_state.py:17-18`):

```python
afk: bool = False                              # persisted
auto_approve_actions: set[str] = Field(...)    # persisted
```

`is_auto_approve()` returns True if `yolo` or `afk` (persisted **or** runtime).
When True, `ApprovalRuntime.create_request` is bypassed entirely — there's no
wire broadcast, no record, no audit. **This is why `--afk` is a blunt
instrument**: it skips the runtime, so the swarm cannot see what was
auto-approved.

`auto_approve_actions` is a per-tool-name allowlist; #478 seeds this with
`mcp__c2c__*` so c2c MCP calls don't prompt. Other tools still hit the runtime.

---

## 2. Mechanism comparison

| Mechanism | Latency | Brittleness | Dev cost | Audit trail | Verdict |
|---|---|---|---|---|---|
| **tmux capture-pane scrape** | 1-3s poll | High (any UI text change breaks the regex; ANSI escape parsing; pgroup coupling for `send-keys`) | Medium (~300 LoC, plus regex maintenance) | Lossy — only what shows on screen, no `request_id`, no `tool_call_id` | Reject — not needed |
| **Filesystem state poll** | inotify=ms; poll=1s | Medium — `wire.jsonl` is append-only log, not a control surface; no way to *resolve* via file | Medium | Full — `wire.jsonl` is the canonical record | Useful as **recovery** path, not primary |
| **Wire JSON-RPC (kimi --wire)** | <100ms (stdio queue) | Low — official protocol with versioned types | Low (~150-200 LoC; we already had a `kimi --wire` bridge) | Full — ApprovalRequest carries id, tool_call_id, sender, action, description, display | **Recommended primary** |
| **kimi-cli source patch / fork** | n/a | Maintenance burden + version drift | High | n/a | **Reject** — no need; upstream surface is sufficient |

The wire path dominates on every axis. The only reason to consider scrape would
be if `--wire` were unavailable; it isn't.

### 2.1 Coexistence with notification-store delivery

The 2026-04-29 kimi-as-peer rebuild moved *delivery* (inbound c2c DMs → kimi)
off `--wire` and onto file-based notification-store push (see
`.collab/runbooks/kimi-notification-store-delivery.md`). The argument was that
`--wire` mode runs kimi non-interactively and starves the TUI.

**This is fine**. The wire server can run *concurrently* with the TUI: kimi
launched with `--wire` opens stdio JSON-RPC for an external client *and*
keeps its TUI for the operator. A single `kimi --wire` invocation covers both.
What we deprecated was the *delivery side* of the wire bridge; nothing about
the approval forwarding repurposes the deprecated piece. Verify before
implementing — if `--wire` truly forces non-interactive, an alternative is to
add a dedicated `--approval-wire <socket>` flag upstream (this would be the
*one* upstream patch worth carrying, but only as a fallback).

> **Open question O1** (§7): does `kimi --wire` co-exist with the TUI today?
> If not, the bridge needs a different transport (unix socket on a separate
> arg, or the maintained-side patch above).

---

## 3. c2c-side surface

### 3.1 Pending-permission representation

Re-use the existing `open_pending_reply` flow already used by
opencode/codex permission DMs. The forwarder daemon, on receiving an
`ApprovalRequest` from kimi's wire, opens a pending-reply DM to the configured
*reviewer* alias. Default reviewer: `coordinator1`; configurable per-instance
in `.c2c/config.toml` under `[swarm.kimi]` (cf. `[swarm] restart_intro`
pattern, #341).

```toml
[swarm.kimi]
permission_reviewer = "coordinator1"        # default
permission_ttl_seconds = 600                # default
permission_room = "kimi-approvals"          # optional Phase B
```

### 3.2 DM body shape

```
[kimi-permission] kuura-viima requests approval
  perm_id: per_<id>
  request_id: <kimi-uuid>
  tool: Bash (execute)
  description: rm -rf /tmp/foo
  source: foreground_turn / background_agent <agent_id> <subagent_type>
  display:
    | code: rm -rf /tmp/foo
    | (truncated to 4 KiB; full payload at .c2c/permissions/kuura-viima/<perm_id>.json)
  ttl: 600s
Reply via: c2c kimi-approve kuura-viima <perm_id> --verdict allow|deny [--feedback "..."]
or: mcp__c2c__check_pending_reply perm_id=<perm_id> verdict=allow|deny
```

### 3.3 CLI shape

New OCaml subcommand on the canonical `c2c` binary:

```
c2c kimi-approve <kimi-alias> <perm-id> [--verdict allow|deny|allow-session]
                                        [--feedback TEXT]
                                        [--reviewer ALIAS]
c2c kimi-pending [--alias <kimi-alias>]
c2c kimi-history [--alias <kimi-alias>] [--since 1h]
```

`kimi-approve` is a thin wrapper around `mcp__c2c__check_pending_reply` that
adds kimi-specific verdict mapping (`allow` → `approve`, `allow-session` →
`approve_for_session`, `deny` → `reject`).

### 3.4 Audit log

```
.c2c/permissions/<kimi-alias>/<UTC-ts>-<perm_id>.json
{
  "perm_id": "per_...",
  "kimi_request_id": "uuid",
  "tool_call_id": "uuid",
  "kimi_alias": "kuura-viima",
  "kimi_session_id": "...",
  "tool": "Bash",
  "action": "execute",
  "description": "rm -rf /tmp/foo",
  "display": [...],
  "source": {"kind":"foreground_turn","id":"...","agent_id":null,"subagent_type":null},
  "opened_at_utc": "...",
  "ttl_seconds": 600,
  "reviewer_requested": "coordinator1",
  "reviewer_responded": "coordinator1",     // or null on TTL expiry
  "verdict": "approve",                      // approve | approve_for_session | reject | timeout
  "feedback": "",
  "resolved_at_utc": "...",
  "latency_seconds": 12.4
}
```

Same directory shape as `.c2c/memory/<alias>/` and gitignored (see #266
pattern). Optional sibling `index.jsonl` for fast `kimi-history` scan.

---

## 4. Trust model + spoof defense

### 4.1 Who can approve?

**Phase A**: any peer the supervisor's MCP session lets through can DM the
kimi reviewer. The reviewer alias is configured (default `coordinator1`).
This matches the current opencode/codex permission flow — same defense, same
weakness.

**Phase B**: `permission_room` constrains which aliases can submit verdicts.
The forwarder accepts `check_pending_reply` only from aliases on the room
member list at request-open time.

**Phase C**: signed verdicts. Reviewer signs the verdict with the same
peer-PASS keypair used for slice signing. Forwarder validates signature
before resolving. This is the only path safe for cross-trust-boundary ops
(unattended kimi running production-touching tools).

### 4.2 Spoof vectors

1. **Subagent-as-reviewer** (Pattern 12): a coordinator's subagent inheriting
   the parent MCP session could DM a verdict that looks like it came from the
   coordinator. Mitigation: the forwarder logs the *broker-stamped* `from_alias`,
   and Phase C signing closes the loophole.
2. **Replay**: an attacker re-sends a captured "approve" DM for a different
   `perm_id`. Mitigation: `perm_id` is single-use (already enforced by
   `open_pending_reply`); audit-log captures every consumption.
3. **Reviewer compromise**: if `coordinator1` is compromised, all kimi
   approvals are. Mitigation: configurable reviewer + multi-sig (Phase D,
   out of scope).

### 4.3 Comparison with peers

- **opencode**: `permission` IPC channel + plugin can intercept. Equivalent
  to kimi's wire surface; we'd do the same thing.
- **claude-code `--allowedTools`**: static allowlist, no per-call review.
  Equivalent to kimi's `auto_approve_actions` (#478). Static-allowlist is
  the floor; we want both floor *and* dynamic review.
- **codex**: PTY sentinel approval. Equivalent to scrape; we'd skip.

---

## 5. Phased rollout

### Phase A — wire bridge + manual DM-ack (MVP)

**AC**:
- New daemon `c2c-kimi-permission-forwarder` started by `c2c start kimi`
  alongside the notifier (sibling pidfile under
  `~/.local/share/c2c/kimi-permission-forwarders/<alias>.pid`).
- Daemon spawns kimi with `--wire` (or attaches to an existing wire fd, see
  O1) and JSON-RPC initializes.
- For each `ApprovalRequest` from the wire:
  1. Compute audit record, write `.c2c/permissions/<alias>/<perm_id>.json`
     with status `pending`.
  2. Call `mcp__c2c__open_pending_reply` against the broker, recipient =
     configured reviewer (default `coordinator1`), TTL = configured (600s).
  3. Send DM to reviewer with the body shape from §3.2.
  4. Background: poll `check_pending_reply` until resolved or TTL.
  5. Translate verdict → `ApprovalResponse` and write to wire.
  6. Append final state to audit record.
- `c2c kimi-approve` CLI works (thin wrapper).
- `--afk` still wins where set (no behavior change for unattended slices that
  intentionally opt out of review).

**Test plan**:
- Integration test: spawn kimi-as-subprocess, fire a tool-call requiring
  approval, fake supervisor sends `check_pending_reply` verdict, assert kimi
  proceeds with the approved tool call and audit record has correct `verdict`.
- Soak: 50 sequential approvals, no leaked file descriptors, no orphan
  pending records on broker.
- Failure mode: kill the daemon mid-flight; verify pending kimi requests
  auto-reject (existing kimi behavior, §1.3) and audit record marks
  `verdict: timeout` with reason `forwarder_disconnect`.

**Blocker to land**: the in-window auto-reject finding (coordinator1+birch
2026-04-29) must be diagnosed and fixed first. Any time-sensitive use of
`open_pending_reply` is broken until then. This is the single biggest risk to
Phase A; without that fix, the bridge will silently auto-reject ~every
approval.

### Phase B — permission room + structured CLI

**AC**:
- New room `kimi-approvals` (or per-kimi `kimi-approvals-<alias>`) that
  reviewers join.
- Forwarder broadcasts `[kimi-permission]` toast to the room *in addition to*
  DM'ing the configured primary reviewer.
- Any room member can `c2c kimi-approve <alias> <perm_id> ...`; first-write
  wins (broker single-use semantics).
- `c2c kimi-pending --alias <a>` lists all currently-open approvals across
  all kimi instances.
- Rate-limiter: more than 3 concurrent pending approvals from one kimi alias
  → forwarder pauses kimi (auto-reject new ones with feedback "supervisor
  overloaded; please wait") rather than fanning out N more DMs. Tunable.

**Test plan**: cross-tmux multi-reviewer race test — two reviewers both call
`kimi-approve` in <50ms; verify exactly one wins and the other gets a clear
"already-resolved" error.

### Phase C — signed verdicts

**AC**:
- Verdict DM body is signed with reviewer's peer-PASS key.
- Forwarder validates signature against the registry's
  `canonical_alias` keypair before calling `resolve`.
- Unsigned verdicts rejected with audit-record reason
  `signature_missing`.
- Configurable per-instance: `[swarm.kimi] require_signed_verdicts = true`.

**Test plan**: malicious-peer simulation — second-tmux session with same
alias but different key tries to spoof an approval; forwarder rejects,
audit record captures `signature_invalid`.

---

## 6. Phase A pseudocode sketch (~200 LoC)

This is intentionally close to the OCaml style of `c2c_kimi_notifier.ml` so
the implementer can lift it. Pseudocode mixes OCaml-ish syntax with prose
where the file/IPC layer needs flexibility.

```ocaml
(* ocaml/c2c_kimi_permission_forwarder.ml *)

type state = {
  alias                 : string;          (* kimi alias, e.g. "kuura-viima" *)
  reviewer              : string;          (* default "coordinator1" *)
  ttl_seconds           : int;
  audit_dir             : string;          (* .c2c/permissions/<alias>/ *)
  wire_in               : in_channel;      (* stdout of `kimi --wire` *)
  wire_out              : out_channel;     (* stdin of `kimi --wire` *)
  broker_root           : string;
  pending_by_perm_id    : (string, kimi_request) Hashtbl.t;
  rate_limiter          : Rate_limiter.t;  (* max 3 concurrent *)
}

and kimi_request = {
  request_id     : string;   (* kimi uuid *)
  tool_call_id   : string;
  perm_id        : string;   (* per_... from broker *)
  opened_at      : float;
  audit_path     : string;
}

(* ─── 1. Boot: spawn `kimi --wire` and JSON-RPC initialize ────── *)

let start ~alias ~reviewer ~ttl ~broker_root =
  let cmd = "kimi"; args = [| "kimi"; "--wire" (* O1: confirm coexistence *) |] in
  let (proc_in, proc_out, _proc_err) = Unix.open_process_full ... in
  let st = { alias; reviewer; ttl_seconds = ttl;
             audit_dir = ".c2c/permissions/" ^ alias;
             wire_in = proc_in; wire_out = proc_out;
             broker_root;
             pending_by_perm_id = Hashtbl.create 16;
             rate_limiter = Rate_limiter.create ~max_concurrent:3 } in
  Sys.mkdir_p st.audit_dir 0o755;
  send_jsonrpc st (`InitializeMessage { ... });
  st

(* ─── 2. Read loop: parse wire frames and dispatch ───────────── *)

let rec read_loop st =
  match read_jsonrpc_frame st.wire_in with
  | exception End_of_file -> shutdown st
  | frame ->
    (match classify frame with
     | `Request_message_with_payload (`ApprovalRequest req) ->
        if Rate_limiter.allow st.rate_limiter then
          handle_approval_request st req
        else
          auto_reject st req
            ~feedback:"supervisor overloaded; please wait"
     | `Event _ | `StatusUpdate _ | _ -> ()  (* ignore non-approval *)
    );
    read_loop st

(* ─── 3. Handle a new approval request ───────────────────────── *)

and handle_approval_request st req =
  (* a) Audit record (initial pending state) *)
  let audit_path = Printf.sprintf "%s/%s-%s.json"
    st.audit_dir (utc_ts_filename ()) req.id in
  write_audit_record audit_path
    { perm_id = "(pending)"; kimi_request_id = req.id;
      tool_call_id = req.tool_call_id; tool = req.sender;
      action = req.action; description = req.description;
      display = req.display;
      source = { kind = req.source_kind; id = req.source_id;
                 agent_id = req.agent_id; subagent_type = req.subagent_type };
      opened_at_utc = now_iso ();
      ttl_seconds = st.ttl_seconds;
      reviewer_requested = st.reviewer;
      verdict = "pending"; feedback = "";
      reviewer_responded = None; resolved_at_utc = None };

  (* b) Broker: open_pending_reply *)
  let perm_id = mcp_call st.broker_root
    ~tool:"open_pending_reply"
    ~params:(`Assoc [
      "from_alias", `String st.alias;
      "to_alias",   `String st.reviewer;
      "ttl_seconds", `Int st.ttl_seconds;
      "kind", `String "kimi-permission";
    ])
    |> extract_perm_id in
  Hashtbl.add st.pending_by_perm_id perm_id
    { request_id = req.id; tool_call_id = req.tool_call_id;
      perm_id; opened_at = Unix.time (); audit_path };
  update_audit audit_path ~perm_id;

  (* c) DM the reviewer with body §3.2 *)
  let body = render_dm_body st req perm_id in
  ignore (mcp_call st.broker_root
    ~tool:"send"
    ~params:(`Assoc [
      "to_alias", `String st.reviewer;
      "body",     `String body;
      "deferrable", `Bool false;
    ]));

  (* d) Spawn watcher fiber: poll check_pending_reply until resolved/TTL *)
  Lwt.async (fun () -> watch_for_verdict st perm_id)

(* ─── 4. Verdict watcher ─────────────────────────────────────── *)

and watch_for_verdict st perm_id =
  let pending = Hashtbl.find st.pending_by_perm_id perm_id in
  let rec loop () =
    Lwt_unix.sleep 0.5 >>= fun () ->
    let now = Unix.time () in
    if now -. pending.opened_at >= float_of_int st.ttl_seconds then
      finalize st perm_id ~verdict:"reject" ~feedback:"timeout"
        ~responded_by:None
    else
      (* O2: this is the call that's currently broken — see §7. *)
      match mcp_call st.broker_root ~tool:"check_pending_reply"
              ~params:(`Assoc ["perm_id", `String perm_id]) with
      | `Pending -> loop ()
      | `Resolved (kimi_verdict, feedback, responded_by) ->
          finalize st perm_id ~verdict:kimi_verdict ~feedback
            ~responded_by:(Some responded_by)
      | `Timeout reason ->
          finalize st perm_id ~verdict:"reject"
            ~feedback:("broker reported timeout: " ^ reason)
            ~responded_by:None
  in
  loop ()

(* ─── 5. Finalize: write wire response + audit ──────────────── *)

and finalize st perm_id ~verdict ~feedback ~responded_by =
  let pending = Hashtbl.find st.pending_by_perm_id perm_id in
  let kimi_response =
    match verdict with
    | "allow"          -> "approve"
    | "allow-session"  -> "approve_for_session"
    | _                -> "reject"
  in
  (* Write ApprovalResponse to kimi via wire *)
  send_jsonrpc st (`SuccessResponse {
    id = pending.request_id;
    result = `ApprovalResponse {
      request_id = pending.request_id;
      response   = kimi_response;
      feedback;
    }
  });
  Rate_limiter.release st.rate_limiter;
  Hashtbl.remove st.pending_by_perm_id perm_id;
  update_audit pending.audit_path
    ~verdict:kimi_response ~feedback ~reviewer_responded:responded_by
    ~resolved_at_utc:(Some (now_iso ()))

(* ─── 6. Auto-reject under load ─────────────────────────────── *)

and auto_reject st req ~feedback =
  send_jsonrpc st (`SuccessResponse {
    id = req.id;
    result = `ApprovalResponse {
      request_id = req.id; response = "reject"; feedback;
    }
  });
  let audit_path = (* ... *) in
  write_audit_record audit_path { ...; verdict = "reject"; feedback;
                                  reviewer_responded = None;
                                  reviewer_requested = "(rate-limited)" }

(* ─── Entry point ─────────────────────────────────────────────── *)

let () =
  let alias    = Sys.getenv "C2C_KIMI_ALIAS" in
  let reviewer =
    swarm_config_kimi_permission_reviewer ()
    |> Option.value ~default:"coordinator1" in
  let ttl =
    swarm_config_kimi_permission_ttl ()
    |> Option.value ~default:600 in
  let broker = C2c_paths.broker_root () in
  let st = start ~alias ~reviewer ~ttl ~broker_root:broker in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle (fun _ -> shutdown st));
  read_loop st
```

LoC budget: ~200 OCaml LoC for the daemon + ~50 LoC of CLI subcommand
wrapper + ~80 LoC of broker.log catalog entries + tests. Total slice
≈ 400 LoC, fits a single worktree.

---

## 7. Open questions / risks

**O1. `kimi --wire` co-existence with the TUI.** The 2026-04-29 rebuild
moved delivery off `--wire` because (presumably) wire mode disables the
TUI. Before Phase A: launch `kimi --wire` in a tmux pane and confirm
whether the TUI still draws. If it doesn't, we need either (a) a thin
upstream patch adding `--approval-wire <unix-socket>` that doesn't
disable the TUI, or (b) a separate JSON-RPC sidecar attached via a
side-channel pipe (kimi-cli's plugin loader supports this — see
`kimi_cli/plugin/`). This is the **biggest single risk** to the
recommended path.

**O2. The in-window auto-reject bug**
(`.collab/findings/2026-04-29T00-00-00Z-coordinator1+birch-coder-permission-dm-auto-reject-despite-in-window-approve.md`).
5/5 in-window approves auto-rejected. Phase A is unusable until this
is fixed; recommend prioritising the broker fix on the same critical
path. Hypotheses H1-H3 in that finding need diagnosis.

**O3. Source-attribution drift.** `ApprovalRequest.source_kind` /
`agent_id` / `subagent_type` are essential for telling the reviewer
"this came from a kimi subagent of kimi, not the foreground turn".
We must surface this clearly in the DM body — otherwise reviewers
will approve "kimi-foreground rm -rf" and discover the ask was
actually from a six-deep subagent stack.

**O4. Display block fidelity.** `display: list[DisplayBlock]` carries
rich rendering (code blocks, diffs, tool output). Truncating to 4 KiB
in the DM is fine for routine ops but risks reviewers approving
things they didn't fully see. Audit record stores the full payload;
DM should link to it (`see .c2c/permissions/<alias>/<perm_id>.json`).

**O5. Subagent multiplication.** If kimi spawns N background subagents
each generating approval prompts, Phase A's rate-limiter (3) starves
the swarm. Phase B's `permission_room` partially solves this; long-
term we may need *prompt batching* (one DM = N grouped requests with
one verdict).

**O6. `--afk` interaction.** Phase A leaves `--afk` semantics
unchanged: afk-set sessions skip `ApprovalRuntime.create_request`
entirely so the wire never sees them. This is *correct* for
intentionally-unattended workers, but it means "unattended with
review" is a third mode the operator must pick: not afk, not raw
TUI, but **wire-bridged**. We need a clear flag on `c2c start kimi`:
`--unattended` (= afk, skip review entirely) vs `--reviewed`
(= wire bridge + reviewer alias).

**O7. Wire reconnect semantics.** kimi auto-rejects all pending
approvals when the wire client disconnects (`wire/server.py:540`).
The forwarder daemon must not crash; if it does, the broker's
pending replies for those approvals will *also* time out. We need
a daemon-level supervisor (systemd-style) — `c2c instances`
already restarts notifiers; piggyback on that.

---

## 8. Cross-references

- `~/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/approval_runtime/runtime.py`
- `~/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/approval_runtime/models.py`
- `~/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/wire/server.py:1035`
  (`_request_approval`)
- `~/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/wire/types.py:276-345`
- `~/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/soul/approval.py:107-148`
- `/home/xertrov/src/c2c/ocaml/c2c_kimi_notifier.ml` (sibling daemon pattern)
- `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml:7291` (`open_pending_reply` impl)
- `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml:7382` (`check_pending_reply` impl)
- `/home/xertrov/src/c2c/ocaml/coord_fallthrough.ml` (TTL semantics)
- `/home/xertrov/src/c2c/ocaml/c2c_start.ml:2948-2980` (`--afk` rationale)
- `.collab/runbooks/kimi-notification-store-delivery.md`
- `.collab/runbooks/kimi-as-peer-quickref.md`
- `.collab/findings/2026-04-29T00-00-00Z-coordinator1+birch-coder-permission-dm-auto-reject-despite-in-window-approve.md`
