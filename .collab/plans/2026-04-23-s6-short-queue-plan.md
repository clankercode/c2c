# S6: Short-queue + Auth-gated History Backfill

## Overview

Implement the observer short-queue (in-memory ring buffer per binding) and auth-gated history backfill for mobile phone clients. When a phone reconnects after being offline, it sends `since_ts` to replay missed messages.

## Components

### 1. ShortQueue Module

Create `ocaml/relay_short_queue.ml`:

```ocaml
(* Ring buffer for short-term message storage per binding *)
type message = {
  ts : float;
  from_alias : string;
  to_alias : string;
  room_id : string option;
  content : string;  (* encrypted envelope JSON *)
}

module ShortQueue : sig
  type t
  val create : unit -> t
  val push : t -> binding_id:string -> message -> unit
  val get_after : t -> binding_id:string -> since_ts:float -> message list
  val get_range : t -> binding_id:string -> since_ts:float -> until_ts:float -> message list
  val cleanup : t -> older_than:float -> int  (* returns count removed *)
  val clear : t -> binding_id:string -> unit
end
```

- Ring buffer: max 1000 msgs OR messages older than 1 hour are evicted
- Thread-safe with Mutex per binding_id

### 2. ObserverSession Refactor

The observer session loop (relay.ml:3221) currently just echoes "observer_receipt". Refactor to:

```ocaml
(* Inside observer session loop *)
| Some (`Text msg) ->
  (* Parse incoming message - could be a JSON command like {"type":"reconnect","since_ts":1234567890} *)
  (match parse_observer_message msg with
   | `Reconnect { since_ts } ->
     (* Replay from short queue *)
     let msgs = ShortQueue.get_after short_queue ~binding_id ~since_ts in
     List.iter (fun msg ->
       Relay_ws_frame.Session.send_text session (json_of_message msg)
     ) msgs;
     loop ()
   | `Ping ->
     Relay_ws_frame.Session.send_text session "{\"type\":\"pong\"}" >>= loop
   | _ ->
     (* Forward to broker as normal message *)
     forward_to_broker msg >>= fun () ->
     loop ())
```

### 3. History Backfill

When `since_ts` precedes short queue start time (gap detected):

```ocaml
(* Request history from broker *)
let gap_start = ShortQueue.oldest_ts short_queue ~binding_id in
if since_ts < gap_start then
  let history = request_broker_history ~binding_id ~since_ts ~limit:500 ~max_age:86400 in
  (* Filter by C6 authorization scope *)
  let filtered = auth_filter_history history ~binding_id ~phone_alias in
  List.iter (fun msg ->
    Relay_ws_frame.Session.send_text session (json_of_message msg)
  ) filtered
```

### 4. C6 Authorization Scoping

When returning history, filter by:

```ocaml
let auth_filter_history ~messages ~binding_id ~phone_alias ~joined_rooms =
  List.filter (fun msg ->
    msg.to_alias = phone_alias ||
    (msg.room_id <> None && List.mem msg.room_id joined_rooms) ||
    (* machine_binding check - if msg is from a machine bound to this phone *)
    is_bound_machine msg.from_alias binding_id
  ) messages
```

### 5. I8 Broker-Offline Handling

```ocaml
(* In observer session *)
match forward_to_broker msg with
| Error `Broker_unreachable ->
  (* Buffer on relay for up to 5 minutes *)
  Buffer.add buffered_messages msg;
  Relay_ws_frame.Session.send_text session "{\"event\":\"broker_offline\"}";
  (* After 5 min, send 503 *)
  Lwt.async (fun () ->
    Lwt_unix.sleep 300.0 >>= fun () ->
    if Buffer.length buffered_messages > 0 then
      Relay_ws_frame.Session.close_with ~code:1008 ~reason:"broker_offline" () session
    else Lwt.return_unit)
| Ok () -> loop ()
```

## Files to Modify

| File | Changes |
|------|---------|
| `ocaml/relay_short_queue.ml` | New - ring buffer module |
| `ocaml/relay.ml` | Add ShortQueue.t to relay state, refactor observer session loop, add history backfill, add C6 filtering |
| `ocaml/relay_ws_frame.ml` | No changes needed |

## Tasks

- [ ] **Task 1**: Create `ShortQueue` module with ring buffer (1000 msgs or 1h TTL)
- [ ] **Task 2**: Add `short_queue` to relay state and Observer session
- [ ] **Task 3**: Implement reconnect replay with `since_ts`
- [ ] **Task 4**: Implement gap detection and broker history backfill request
- [ ] **Task 5**: Implement C6 authorization scoping filter
- [ ] **Task 6**: Implement I8 broker-offline handling
- [ ] **Task 7**: Add tests
- [ ] **Task 8**: Commit and get coordinator review

## Tests

- Drop-and-reconnect replays from short queue
- Ring overflow drops oldest messages
- Bounded backfill (500 msgs / 24h)
- Cross-machine scope isolation (phone-A cannot read machine-B history)
- Broker-offline buffering and 503 after 5min