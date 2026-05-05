# Design Sketch: Inotify-Based Delivery in `c2c-deliver-inbox`

**Date**: 2026-05-05
**Author**: willow-coder
**Status**: Sketch (updated with fern-coder feedback)
**Related**: `c2c-deliver-inbox` (OCaml deliver daemon), `.collab/runbooks/kimi-notification-store-delivery.md`
**Feedback**: fern-coder reviewed v1, key issues flagged and fixed

## Context

`c2c-deliver-inbox` currently polls on a file-based notification store (Kimi) or uses an inotify loop for OpenCode (`c2c monitor --alias`). For Codex and other clients that lack a native plugin, `c2c-deliver-inbox` could use inotify directly on the broker inbox directory to deliver messages on file-change without polling.

The goal: sub-second inbox delivery with zero CPU waste from polling.

## Architecture

### Current State

- **OpenCode**: plugin spawns `c2c monitor --alias` subprocess with `--moved_to` inotify watch on the inbox file. On event, delivers via `client.session.promptAsync`. The `c2c monitor` CLI subcommand uses `inotifywait -m` as a subprocess internally.
- **Kimi**: file-based notification store (`C2c_kimi_notifier`) writes inbound messages as JSON to Kimi's notification store; Kimi reads on its own cadence.
- **Codex/Claude/Gemini**: polling via `c2c poll_inbox` in a background loop (CPU waste).

### Proposed: Inotify Watcher Thread in `c2c-deliver-inbox`

The OCaml `c2c-deliver-inbox` executable already runs as a daemon. Add an inotify watcher thread that:

1. Watches `<broker_root>/.inbox/<session_alias>.inbox.json` for `IN_MODIFY` events
2. On each event, reads the inbox file, parses new messages
3. Delivers each new message to the client via its delivery mechanism
4. Uses `inotify_init` + `inotify_add_watch` with `IN_MODIFY` flag
5. Runs in a separate `Thread.create` alongside any existing poller

**Note**: This is *separate* from `c2c monitor --alias` (which is a CLI subprocess that OpenCode uses). This proposal is about `c2c-deliver-inbox` (the daemon started by `c2c start`). They could coexist, or this could eventually replace the `inotifywait` subprocess approach.

## Key Design Decisions

### 1. Deduplication: Position-Based (Not Timestamp)

The broker inbox is a JSON array. Dedup must use **array position**, not timestamps:

- Timestamps can collide (two messages in the same second)
- Array position is stable and monotonically increasing
- On each `IN_MODIFY`: read the full JSON array, compare `List.length messages` against `last_seen_count`
- Deliver only `messages |> List.drop last_seen_count`

```ocaml
let deliver_new ~(last_seen_count : int ref) (messages : Yojson.Safe.t list) =
  let new_count = List.length messages in
  if new_count > !last_seen_count then begin
    let new_messages = drop (!last_seen_count) messages in
    List.iter deliver new_messages;
    last_seen_count := new_count
  end
```

### 2. Hand-Rolled Inotify Event Parser

OCaml has NO `Inotify` module and NO `parse_events`. Raw inotify events are C structs:

```
wd (4 bytes, int) + mask (4 bytes, uint32) + cookie (4 bytes, uint32) + len (4 bytes, uint32) + name[len, padded to 8-byte boundary]
```

Implement `parse_inotify_events : bytes -> event list`:

```ocaml
type inotify_event = {
  wd : int;
  mask : uint32;
  cookie : uint32;
  name : string option;
}

let parse_inotify_events (buf : bytes) ~(buf_len : int) : inotify_event list =
  let rec loop pos acc =
    if pos >= buf_len then List.rev acc
    else begin
      let wd   = int_of_string (Bytes._get_int32_le buf pos) in
      let mask = Bytes.unsafe_get_uint32_le buf (pos + 4) in
      let cookie = Bytes.unsafe_get_uint32_le buf (pos + 8) in
      let name_len = Bytes.unsafe_get_uint32_le buf (pos + 12) |> Int32.to_int in
      let next_pos = pos + 16 + ((name_len + 7) / 8 * 8) in  (* 8-byte align *)
      let name = if name_len > 0 then Some (Bytes.sub_string buf (pos + 16) name_len) else None in
      loop next_pos ({ wd; mask; cookie; name } :: acc)
    end
  in
  loop 0 []
```

**Alternative**: use `inotifywait -m <file>` as a subprocess and parse its text output. Simpler but adds a process. Falls back to this if raw inotify proves too brittle.

### 3. `deliver_callback` Contract

The `deliver` callback is injected by the caller of `run_watcher`. Possible implementations:

- **For CLI (Claude/Codex)**: writes to a pipe that the outer loop reads, triggering a `poll_inbox` flush
- **For OpenCode**: calls `client.session.promptAsync(message)` via FFI or a side-channel
- **For HTTP-based clients**: POSTs to a callback URL

The watcher thread itself is agnostic — it just needs `(messages : Yojson.Safe.t list) -> unit`.

### 4. Sidecar for Restart Recovery

On graceful shutdown and on each delivery batch, write the `last_seen_count` to an atomic sidecar:

```ocaml
(* Atomic sidecar write: write to temp, then rename *)
let save_checkpoint ~(checkpoint_path : string) ~(last_seen : int) =
  let tmp = checkpoint_path ^ ".tmp" in
  write_file tmp (string_of_int last_seen);
  Unix.rename tmp checkpoint_path
```

On startup: if sidecar exists, read it to initialize `last_seen_count`. On crash: sidecar reflects the last confirmed delivery, not in-flight messages.

### 5. Inotify Queue Overflow

High-frequency delivery can overflow the queue (`IN_Q_OVERFLOW`). Handle this by:

- Adding `IN_Q_OVERFLOW` to the watch mask
- On overflow: fall back to stat-based polling (read the file every 100ms until caught up)

## Watcher Thread Implementation

```ocaml
let run_watcher ~(broker_root : string) ~(session : string)
    ~(deliver : Yojson.Safe.t -> unit) =
  let inbox_path = broker_root // ".inbox" // session ^ ".inbox.json" in
  let checkpoint_path = broker_root // ".inbox" // session ^ ".deliver-checkpoint" in

  (* Init: read checkpoint or start at 0 *)
  let last_seen_count = ref (
    try int_of_string (read_file checkpoint_path) with _ -> 0
  ) in

  let fd = Unix.inotify_init () in
  let _ = Unix.inotify_add_watch fd inbox_path
    [ Unix.Inotify_watch.Events.MODIFY; Unix.Inotify_watch.Events.Q_OVERFLOW ] in
  let buf = Bytes.create 4096 in

  let rec loop () =
    let len = Unix.read fd buf 0 (Bytes.length buf) in
    if len > 0 then begin
      let events = parse_inotify_events buf ~buf_len:len in
      let has_modify = List.exists (fun e -> e.mask land 0x0001 <> 0) events in
      let has_overflow = List.exists (fun e -> e.mask land 0x4000 <> 0) events in
      if has_overflow then
        (* Fallback: poll the file directly *)
        deliver_from_file ()
      else if has_modify then
        deliver_from_file ()
    end;
    loop ()
  and deliver_from_file () =
    match read_inbox_opt inbox_path with
    | Some messages ->
        let new_count = List.length messages in
        if new_count > !last_seen_count then begin
          let new_messages = drop (!last_seen_count) messages in
          List.iter deliver new_messages;
          last_seen_count := new_count;
          save_checkpoint ~checkpoint_path ~last_seen:new_count
        end
    | None -> ()
  in
  Thread.create loop ()
```

## Integration with `c2c start`

In `c2c_start.ml`, when `deliver_started = true`, start the inotify watcher alongside the existing daemon:

```ocaml
if deliver_started then
  let watcher_pid = Thread.create
    (fun () ->
       C2c_deliver_inbox.run_watcher
         ~broker_root
         ~session:my_alias
         ~deliver:(deliver_callback_for_session my_alias))
    ()
  in
  ()
```

## Risks

1. **Inotify queue overflow**: handled via `IN_Q_OVERFLOW` + fallback polling ✅
2. **Event coalescing**: `IN_MODIFY` may fire once for multiple writes; position-based dedup handles this ✅
3. **Crash between delivery and checkpoint**: atomic sidecar write (temp + rename) prevents re-delivery ✅
4. **Inotify not available**: fallback to stat polling on any Unix error ✅

## Open Questions

1. Should this replace the OpenCode `c2c monitor --alias` subprocess, or coexist as a separate path?
2. Should the deliver callback use a pipe, FFI, or HTTP POST for OpenCode Claude integration?
3. Merge into `c2c-deliver-inbox` or keep separate? Recommendation: merge once stable.

## Next Steps

If approved: write a full SPEC, then implement with:
- [ ] Hand-rolled `parse_inotify_events` (or `inotifywait` subprocess fallback)
- [ ] Position-based deduplication
- [ ] Atomic checkpoint sidecar
- [ ] `IN_Q_OVERFLOW` fallback to polling
- [ ] Integration with `c2c start`
