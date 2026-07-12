# c2c Rooms Dogfood Findings (mm27, 2026-06-12)

## What Worked Well

- `c2c rooms create` / `join` / `leave` / `delete` all function correctly
- Room history is stored and retrieved correctly, including with `--limit` and `--since`
- Empty room history shows clean "(no history)" message
- Unicode, actual newlines, special chars (`<>&"'`), and very long messages all work
- `--json` output is machine-readable and consistent across all subcommands
- `c2c rooms visibility` get/set works
- `c2c rooms members` lists members with session IDs
- Delete correctly refuses non-empty rooms; `--force` works for legacy rooms
- `c2c rooms --help` is comprehensive and covers all subcommands
- Help text is generally clear and actionable

---

## Issues

### Sev1: Sending to a room you're not a member of silently succeeds with message lost

**Symptom:** After `leave`, sending to that room reports success but message is permanently lost.

**Command + output:**
```
$ c2c rooms leave bakeoff-mm27-roomtest
Left room bakeoff-mm27-roomtest (0 members remaining)
$ c2c rooms send bakeoff-mm27-roomtest "This should fail since I left"
Sent to room bakeoff-mm27-roomtest (0 delivered, 0 skipped)
```

**Root cause guess:** `rooms_send` does not check sender membership before enqueuing. The history does record the message (seen when re-joining), but no delivery receipts are issued. This means a sender can post to any room by name, even after leaving.

**Suggested fix:** Return exit code 1 and an error message when the sender is not a current member of the target room.

---

### Sev1: Sending to a non-existent room silently succeeds and creates ghost room

**Symptom:** Typoing a room name creates a ghost room with no members; the message is lost.

**Command + output:**
```
$ c2c rooms send nonexistent-room-xyz "hello"
Sent to room nonexistent-room-xyz (0 delivered, 0 skipped)
$ c2c rooms list
swarm-lounge (1 members)
nonexistent-room-xyz (0 members)   ← ghost room
```

**Root cause guess:** `rooms_send` auto-creates the room on send if it doesn't exist (probably via `get_or_create` on the room). No validation that the room exists or that the sender has any connection to it.

**Suggested fix:** Return error "room does not exist" when sending to a room that has no members and the sender is not in it.

---

### Sev2: "0 delivered, 0 skipped" is confusing in 1-person rooms (sender not counted as delivered)

**Symptom:** Sending to a room where you ARE the only member still shows "0 delivered, 0 skipped" which looks broken.

**Command + output:**
```
$ c2c rooms send bakeoff-mm27-roomtest "Hello from bakeoff-mm27-roomtest!"
Sent to room bakeoff-mm27-roomtest (0 delivered, 0 skipped)
```

**Root cause guess:** Delivery logic excludes the sender from the delivered count (correct for broadcast semantics), but in a 1-person room this means 0. The message IS in history.

**Suggested fix:** Either (a) show "(delivered to N, excluding sender)" or (b) show "(1 delivered)" since the sender IS a member and the message is stored. Or document this as intentional and change output to "queued in room (N members, message stored)".

---

### Sev2: `c2c rooms my-rooms` does not exist as a CLI command

**Symptom:** AGENTS.md and MCP tool `c2c_my_rooms` exist, but `c2c rooms my-rooms` returns an error.

**Command + output:**
```
$ c2c rooms my-rooms
c2c: unknown command `my-rooms`. Must be one of create, delete, history, invite, join, leave, list, members, send, tail or visibility.
```

**Root cause guess:** The CLI rooms subcommands don't include a `my-rooms` equivalent of `c2c_my_rooms` MCP.

**Suggested fix:** Add `c2c rooms mine` (or `my-rooms`) subcommand that returns rooms where the current session is a member.

---

### Sev2: `--fail`/`--blocking`/`--urgent` tags don't appear in own history view

**Symptom:** Sending with `--fail` shows in history as plain message with no FAIL marker.

**Command + output:**
```
$ c2c rooms send bakeoff-mm27-roomtest --fail "This is a FAIL test"
Sent to room bakeoff-mm27-roomtest (0 delivered, 0 skipped)
$ c2c rooms history bakeoff-mm27-roomtest --limit 1
[2026-06-11 17:40] <mm27-roomtest> This is a FAIL test
```

**Root cause guess:** Tags are only prepended at recipient inbox delivery time, not stored in history. Sender's own history view is tag-free.

**Suggested fix:** Either (a) store the tag in history so it's visible to all including sender, or (b) document that tags are recipient-side only and sender sees plain message in history.

---

### Sev2: Messages from non-members appear in room history

**Symptom:** After leaving a room, a message sent to it still appears in history when re-joining.

**Command + output:**
```
$ c2c rooms leave bakeoff-mm27-roomtest
Left room bakeoff-mm27-roomtest (0 members remaining)
$ c2c rooms send bakeoff-mm27-roomtest "This should fail since I left"
Sent to room bakeoff-mm27-roomtest (0 delivered, 0 skipped)
$ c2c rooms join bakeoff-mm27-roomtest --history-limit 0
Joined room bakeoff-mm27-roomtest (1 members)
$ c2c rooms history bakeoff-mm27-roomtest
...
[2026-06-11 17:39] <mm27-roomtest> This should fail since I left
```

**Root cause guess:** The history stores all messages regardless of sender membership at send time. The leave event is recorded but doesn't retroactively purge prior messages from the sender.

**Suggested fix:** Either prevent non-members from posting (see Sev1 fix above), or add a "system" message in history noting the sender was not a member at send time.

---

### Sev3: `c2c rooms` (no subcommand) shows generic help, not a summary

**Symptom:** Running `c2c rooms` with no arguments shows the same help as `c2c rooms --help`, rather than a brief usage summary or list of rooms the user is in.

**Command + output:**
```
$ c2c rooms
[help text - identical to c2c rooms --help]
```

**Root cause guess:** No default handler for `c2c rooms` with no subcommand; falls through to `--help`.

**Suggested fix:** Make `c2c rooms` with no args equivalent to `c2c rooms my-rooms` (after adding that command), showing rooms the user is a member of.

---

### Sev3: "0 delivered, 0 skipped" on send to 0-member room could be clearer

**Symptom:** Sending to a ghost/empty room shows same "0 delivered, 0 skipped" as sending from a 1-person room.

**Command + output:**
```
$ c2c rooms send nonexistent-room-xyz "hello"
Sent to room nonexistent-room-xyz (0 delivered, 0 skipped)
```

**Root cause guess:** Same delivery counter logic applies regardless of room state.

**Suggested fix:** Add context like "(room has no members)" when member count is 0.

---

## Summary

| Severity | Count |
|----------|-------|
| Sev1 (broken) | 2 |
| Sev2 (wrong/missing) | 4 |
| Sev3 (friction) | 2 |

**Overall verdict:** Rooms feature is functional and well-documented, but has 2 critical silent-failure bugs where messages are lost without any error indication. The "0 delivered, 0 skipped" output is a persistent source of confusion across multiple scenarios and should be improved even when behavior is technically correct.
