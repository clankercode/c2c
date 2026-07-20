# Design sketch: machine-wide delivery service (#35)

Status: **sketch for review** (Max to steer scope/phasing before build). Distills
the #35 proposal into a concrete, phased implementation and shows how it closes
the issues currently deferred *to* it. Not a commitment — the open questions at
the end are real decisions.

## Goal (unchanged from #35)
Replace N per-client, unsupervised wake daemons with **one supervised,
machine-wide singleton** that owns delivery for every local session via
**per-client endpoint adapters**. Mail wakes the agent (external push, no
model-initiated poll) — and the single supervised owner makes arming,
supervision, staleness, reaping, and health *one* thing instead of N.

## Reuse, don't invent — the relay-connector is the template
The relay connector is already a machine-wide supervised singleton with a
machine lock + self-heal: `ocaml/cli/c2c_relay_managed.ml`, `c2c start
relay-connect` (B200/B235). The delivery service should be built as a sibling of
that — same supervision/lock/restart/doctor scaffolding — not new infra.
Working title: `c2c start deliver-service` / `c2c_deliver_managed.ml`.

## Shape
```
broker (rendezvous, already machine-wide)
   │  sessions register {alias, session_id, client_type, cwd, pid, ENDPOINT}
   ▼
deliver-service (supervised singleton, machine lock)
   │  watches broker inboxes; for each new message → route to endpoint adapter
   ├─ kimi adapter      → POST {rest_base}/api/v1/sessions/{sid}/prompts (+bearer)
   ├─ codex adapter     → app-server WS thread/inject_items (+ gated auto-turn, B098)
   ├─ agy adapter       → agentapi send-message
   └─ opencode adapter  → deliver-watch/sidecar target
```

### Endpoint registration (extends what registration already carries)
Add an optional `delivery_endpoint` to the broker registration record:
```
delivery_endpoint = {
  kind : "kimi" | "codex" | "agy" | "opencode";
  <adapter-specific fields, e.g. kimi: {rest_base, session_id, bearer_ref};
                                    codex: {ws_url, thread_id};
                                    agy:   {agentapi_url};
                                    opencode: {sidecar_target} }
}
```
The managed launcher (`c2c start <client>`) writes it at register time (it
already resolves most of these to arm today's per-client daemon). A vanilla
session's hook writes what it can. **Bearer/secrets by reference** (a path or
keyring id), never inline in the registry.

### Adapter interface
```
module type DELIVERY_ADAPTER = sig
  val kind : string
  (* liveness of the endpoint itself (server up? thread attached?) — a
     PRECONDITION distinct from "message delivered", per the e2e wake bar *)
  val probe : endpoint -> [ `Live | `Dead of string | `Unknown ]
  (* push one message; MUST be idempotent-safe and B098-preserving (peer DATA
     never upgraded to user-role / never resolves an approval) *)
  val deliver : endpoint -> message -> (unit, string) result
end
```
The existing per-client push code (`C2c_kimi_notifier` REST POST, the codex
app-server `inject_items`, `c2c_agy_deliver`, opencode sidecar) is refactored
*behind* this interface — same wire behavior, one owner calling it.

## How it closes the deferred issues (the payoff)
- **#27 runtime deaf-detection** — the service supervises the delivery path, so a
  dead loop/bridge is *known* (probe → `Dead`), not false-healthy. It can mark
  the recipient delivery-unavailable at the broker so the **sender** sees it
  (issue #27 option 2, done out-of-session — the one place it *can* be done when
  no in-session process survives).
- **#42 uuid-mint leak / inverse leak** — "reaping comes for free": a watch-set
  rebuilt each tick has no per-session daemon to orphan. The service drops a
  watcher when its session is gone; there is no long-lived per-alias process to
  outlive its TUI and eat mail. Closes the exact class #42 could only *surface*.
- **#59 Grok/Kimi ghost decay** — the service knows each endpoint's liveness by
  probe, so a row can decay on *probed-dead endpoint* rather than a TTL that
  can't tell live-idle from dead. Removes the #51 carve-out safely (decay backed
  by real liveness, not session age).
- **#9 never-armed notifier** — arming is no longer one-shot per session; the
  singleton watches the broker and delivers to any registered endpoint, so a
  session can't be "registered but never armed".
- **#50 doctor** — one delivery-health surface (service up? each endpoint
  probing live?) replaces the per-client DEAF checks.

## Phasing (incremental — never big-bang the working paths)
1. **Scaffold** the supervised singleton off the relay-connector template
   (lock, self-heal, `c2c start deliver-service`, doctor stub). No adapters yet.
2. **One adapter end-to-end (kimi first** — REST is the simplest probe+push, and
   #9/#42 hurt most there). Run it *alongside* the existing notifier behind a
   flag; compare. Prove the wake e2e (the #35 plan).
3. **Migrate kimi** off the per-alias daemon once the service adapter is proven;
   delete the daemon path. Reaping (#42) lands here.
4. **codex / agy / opencode adapters** one at a time, each alongside-then-migrate.
5. **Retire** per-client supervision + fold #59 decay onto probed-liveness.

Each phase is independently shippable and reversible; the working per-client
path stays until its adapter is proven in the wild (dogfood bar).

## Open questions for Max (the real decisions)
- **Scope now vs later:** build the full service, or just phase 1–2 (scaffold +
  kimi) to prove the shape and retire the worst daemon (#9/#42)? Rec: phase 1–2
  first — highest pain relief, smallest blast radius.
- **Secret handling:** how does the service get each endpoint's bearer? By-ref to
  the same store the launcher uses? (Must not centralize secrets in the registry.)
- **B098 boundary:** the service is a new machine-wide component that *pushes*
  peer DATA into sessions. Confirm the invariant survives centralization — the
  codex gated auto-turn is the only sanctioned scheduling effect and must remain
  the *adapter's* concern, not the service core's.
- **Cross-UID / remote:** endpoint registration must stay same-UID/local for now
  (the #48 threat-model note); a machine-wide pusher must not become a
  cross-UID injection surface.
- **Relationship to the relay connector:** one supervised process with two roles,
  or two siblings? Rec: sibling singletons sharing the supervision lib, distinct
  locks — delivery is local-endpoint, relay is network-transport.
