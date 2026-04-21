---
author: planner1
ts: 2026-04-21T08:30:00Z
severity: medium
status: ALREADY IMPLEMENTED — c2c_wire_bridge.ml + c2c_wire_daemon.ml + CLI wired up; c2c start kimi uses needs_wire_daemon=true
---

# Wire Daemon OCaml Port — Implementation Spec

## Background

`c2c wire-daemon` is the preferred Kimi delivery path (no PTY, no terminal hacks).
It currently lives entirely in Python (`c2c_kimi_wire_bridge.py` + `c2c_wire_daemon.py`).
The OCaml CLI has no `wire-daemon` subcommand — `c2c wire-daemon start` gets "unknown command".

Ref: `.collab/findings/2026-04-21T06-32-00Z-coder2-expert-wire-daemon-ocaml-port-needed.md`

---

## Scope

Four modules:
1. **Wire JSON-RPC client** — talk to `kimi --wire` over stdio
2. **Durable spool** — persist messages between drain and Wire prompt (crash-safe)
3. **Deliver loop** — drain broker inbox → spool → Wire prompt → clear spool
4. **Daemon lifecycle** — start/stop/status/list with pidfiles

---

## 1. Wire JSON-RPC Client

Kimi's Wire protocol is newline-delimited JSON-RPC 2.0 over stdin/stdout.

```ocaml
(* ocaml/c2c_wire.ml *)

type wire_client = {
  ic: in_channel;
  oc: out_channel;
  mutable next_id: int;
}

let create ~ic ~oc = { ic; oc; next_id = 1 }

let request client method_ params =
  let id = string_of_int client.next_id in
  client.next_id <- client.next_id + 1;
  let msg = `Assoc [
    ("jsonrpc", `String "2.0");
    ("method",  `String method_);
    ("id",      `String id);
    ("params",  params);
  ] in
  output_string client.oc (Yojson.Safe.to_string msg ^ "\n");
  flush client.oc;
  (* Read lines until we get our response id *)
  let rec loop () =
    let line = input_line client.ic in
    let resp = Yojson.Safe.from_string line in
    let resp_id = Yojson.Safe.Util.(resp |> member "id" |> to_string_option) in
    if resp_id = Some id then begin
      (match Yojson.Safe.Util.(resp |> member "error") with
       | `Null -> ()
       | err -> failwith ("wire error: " ^ Yojson.Safe.to_string err));
      Yojson.Safe.Util.(resp |> member "result")
    end else loop ()
  in
  loop ()

let initialize client =
  request client "initialize" (`Assoc [
    ("protocol_version", `String "1.9");
    ("client", `Assoc [("name", `String "c2c-wire-daemon"); ("version", `String "0")]);
    ("capabilities", `Assoc [("supports_question", `Bool false)]);
  ]) |> ignore

let prompt client text =
  request client "prompt" (`Assoc [("user_input", `String text)]) |> ignore
```

---

## 2. Message Envelope Format

Must match Python's `format_c2c_envelope()`:

```ocaml
let xml_attr s =
  (* Escape XML attribute value characters *)
  let buf = Buffer.create (String.length s) in
  String.iter (fun c -> match c with
    | '"' -> Buffer.add_string buf "&quot;"
    | '&' -> Buffer.add_string buf "&amp;"
    | '<' -> Buffer.add_string buf "&lt;"
    | '>' -> Buffer.add_string buf "&gt;"
    | c   -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

let format_envelope ~from_alias ~to_alias ~content =
  Printf.sprintf
    {|<c2c event="message" from="%s" alias="%s" source="broker" action_after="continue">
%s
</c2c>|}
    (xml_attr from_alias)
    (xml_attr to_alias)
    content

let format_prompt messages =
  String.concat "\n\n" (List.map (fun msg ->
    let from_alias = Yojson.Safe.Util.(msg |> member "from_alias" |> to_string_option |> Option.value ~default:"unknown") in
    let to_alias   = Yojson.Safe.Util.(msg |> member "to_alias"   |> to_string_option |> Option.value ~default:"") in
    let content    = Yojson.Safe.Util.(msg |> member "content"    |> to_string_option |> Option.value ~default:"") in
    format_envelope ~from_alias ~to_alias ~content
  ) messages)
```

---

## 3. Durable Spool

Path: `<broker_root>/../kimi-wire/<session_id>.spool.json`

Messages written to spool BEFORE Wire prompt, cleared AFTER success.
If process crashes between drain and prompt, spool is replayed on next run.

```ocaml
type spool = { path: string }

let spool_path ~broker_root ~session_id =
  let parent = Filename.dirname broker_root in
  Filename.concat (Filename.concat parent "kimi-wire")
    (session_id ^ ".spool.json")

let spool_read s =
  if not (Sys.file_exists s.path) then []
  else
    let ic = open_in s.path in
    let content = really_input_string ic (in_channel_length ic) in
    close_in ic;
    match Yojson.Safe.from_string (String.trim content) with
    | `List msgs -> List.filter_map (function `Assoc _ as m -> Some m | _ -> None) msgs
    | _ -> []
    | exception _ -> []

let spool_write s msgs =
  (* Atomic: write to tmp, fsync, rename *)
  let dir = Filename.dirname s.path in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let tmp = s.path ^ ".tmp" in
  let oc = open_out tmp in
  output_string oc (Yojson.Safe.to_string (`List msgs));
  flush oc;
  let fd = Unix.descr_of_out_channel oc in
  Unix.fsync fd;
  close_out oc;
  Unix.rename tmp s.path

let spool_clear s =
  (try Unix.unlink s.path with Unix.Unix_error (Unix.ENOENT, _, _) -> ())
```

---

## 4. Deliver Once

```ocaml
let deliver_once ~wire ~spool ~broker_root ~session_id ~timeout:_ =
  initialize wire;
  let msgs = spool_read spool in
  let msgs =
    if msgs <> [] then msgs
    else begin
      (* drain broker inbox directly via broker API, not CLI *)
      let fresh = C2c_broker.poll_inbox_file ~broker_root ~session_id in
      if fresh <> [] then spool_write spool fresh;
      fresh
    end
  in
  if msgs = [] then 0
  else begin
    prompt wire (format_prompt msgs);
    let n = List.length msgs in
    spool_clear spool;
    n
  end
```

**Note**: `C2c_broker.poll_inbox_file` reads `<broker_root>/<session_id>.inbox.json`
directly (same as `poll_inbox --force-file`), bypassing the MCP server. This avoids
circular dependencies.

---

## 5. Daemon Lifecycle

Pidfiles at: `~/.local/share/c2c/wire-daemons/<session_id>/daemon.pid`

### Subcommands

```
c2c wire-daemon start --session-id <id> [--alias <name>] [--interval <s>] [--kimi-command <cmd>]
c2c wire-daemon stop  --session-id <id>
c2c wire-daemon status [--session-id <id>] [--json]
c2c wire-daemon list [--json]
```

### Start flow

1. Check existing pidfile — fail if already running
2. Fork + setsid (double-fork for true daemon)
3. Redirect stdin/stdout/stderr (stdout/stderr → `<state_dir>/daemon.log`)
4. Write pidfile
5. Spawn `kimi --wire` subprocess
6. Run poll loop: every N seconds, `deliver_once`; if Wire dies, respawn

### Stop flow

1. Read pidfile → send SIGTERM
2. Wait up to 5s; send SIGKILL if needed
3. Remove pidfile

### List/Status

Read all pidfiles in `~/.local/share/c2c/wire-daemons/`, check PID liveness.

```json
{
  "session_id": "kimi-session-abc",
  "alias": "kimi-alice",
  "pid": 12345,
  "alive": true,
  "started_at": 1776712345.0,
  "interval_s": 10
}
```

---

## 6. CLI Integration

In `ocaml/cli/c2c.ml`, add a `wire-daemon` subcommand group:

```
c2c wire-daemon start --session-id kimi-session-abc --alias kimi-alice --interval 10
c2c wire-daemon stop  --session-id kimi-session-abc
c2c wire-daemon status --json
c2c wire-daemon list --json
```

Also: after OCaml port, update `c2c start kimi` (c2c_start.ml) to use
`wire-daemon start` instead of `needs_deliver=true` (PTY notify daemon).

---

## 7. Cross-Impl Parity Test

Add `test_wire_daemon_parity.py` (or OCaml test equivalent):
- Feed same `inbox.json` content to both Python `deliver_once` and OCaml `deliver_once`
- Assert identical `format_prompt` output (same XML envelopes, same concatenation)
- Test spool read/write/clear cycle matches

---

## 8. Dune Configuration

New file `ocaml/c2c_wire.ml` — add to `ocaml/dune` under `(library ...)` or `(executable ...)`.

Dependencies: `yojson`, `unix`, `threads.posix` (if using threaded poll).

---

## Acceptance Criteria

1. `c2c wire-daemon start --session-id <id>` spawns background daemon, writes pidfile
2. `c2c wire-daemon stop --session-id <id>` terminates daemon cleanly
3. `c2c wire-daemon list --json` shows all running daemons with PID + alive status
4. Daemon polls broker inbox every N seconds (default 10), delivers via Wire `prompt`
5. Spool survives crash: on restart, pending messages are retried before fresh drain
6. `format_prompt` output is byte-identical to Python `format_prompt` for same input (parity test)
7. `c2c start kimi` uses wire-daemon instead of PTY notify daemon

---

## Related

- `c2c_kimi_wire_bridge.py` — Python reference implementation
- `c2c_wire_daemon.py` — Python daemon lifecycle reference
- `.collab/findings/2026-04-21T06-32-00Z-coder2-expert-wire-daemon-ocaml-port-needed.md`
- `ocaml/c2c_start.ml` — kimi start path (needs_deliver=true to be replaced)
