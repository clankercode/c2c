# c2c XML envelope — sender role attribute

**Task:** #107. **Status:** draft. **Author:** jungle-coder.
**Depends on:** c2c_mcp.ml changes (blocked — file is in Max's active edit set).

## Goal

Add a `role` attribute to the `<c2c event="message" ...>` XML envelope so recipients can distinguish between human operators and agents, and know what permissions a sender has.

Use case: when a user (human) chats to their agents, the agents should see the user has elevated permissions. Regular agents sending messages don't have this attribute.

## Current envelope shape

```xml
<c2c event="message" from="alice" alias="jungle-coder" source="broker" reply_via="c2c_send" action_after="continue">
hello jungle!
</c2c>
```

## Proposed envelope shape

```xml
<c2c event="message" from="alice" alias="jungle-coder" source="broker" reply_via="c2c_send" action_after="continue" role="human">
hello jungle!
</c2c>
```

Or, to express permissions directly:

```xml
<c2c event="message" from="alice" alias="jungle-coder" source="broker" reply_via="c2c_send" action_after="continue" role="operator">
hello jungle!
</c2c>
```

## Role values

| Value | Meaning |
|-------|---------|
| (absent) | Regular agent sender (default) |
| `human` | Human operator (real person at a terminal) |
| `operator` | Swarm coordinator or operator with elevated privileges |
| `admin` | Repo admin (future) |

The `role` attribute is omitted for regular agents (backward-compatible for recipients that don't understand it).

## Where role comes from

The sender's role must be determined at the point where the envelope is formatted. Options:

1. **From registration schema** — add `role` to the registration record. The broker looks it up when formatting the envelope for delivery. Requires: `c2c_mcp.ml` changes to the registration type and `deliver_inbox`/`format_envelope` to look it up.

2. **From role file** — the agent's `compatible_clients`/`role_class` frontmatter field already exists. An agent's role (primary/subagent/all) is already in the system. This is already in the role file and could be looked up at envelope-formatter time.

3. **From client type** — human operators typically use `claude` CLI (not an agent). But we can't reliably distinguish since agents also run on `claude`. Client type alone is insufficient.

**Recommended: Option 1 + 2 combined.** The registration stores the role (derived from the role file's `role_class` on startup). The broker looks up the sender's registration and reads the role field when formatting the outbound envelope.

## Files to change

### OCaml

1. **`ocaml/c2c_mcp.ml`** (BLOCKED — in Max's active edit set)
   - Add `role : string option` to the `message` record type
   - Update all message construction sites to accept/propagate `role`
   - Update `format_envelope` in `c2c_wire_bridge.ml` and inbox hook to include `role` attribute

2. **`ocaml/c2c_wire_bridge.ml`** (fair game)
   - `format_envelope` signature changes to accept `role : string option`
   - Add `role` attribute to XML output when `Some r`

3. **`ocaml/tools/c2c_inbox_hook.ml`** (fair game)
   - Same changes as wire_bridge

4. **`ocaml/cli/c2c.ml`** (fair game)
   - The `drain_inbox` → envelope formatter needs `role`

5. **`ocaml/c2c_role.ml`** (fair game)
   - Already parses `role_class` from role files
   - Need a way to look up role by alias at runtime (likely via the registry)

### Registration schema

6. **Registration (`c2c_mcp.ml` or registry)**
   - Add `role` field to registration record
   - Populate from role file on `c2c start` or first registration

## Open questions

1. **How does a human operator send a message?** Currently all senders are agents via MCP. A human using `c2c send` CLI directly would need the CLI to emit the `role` attribute somehow. The CLI doesn't know if the caller is a human or an agent — it just sends. Should the CLI auto-detect from `C2C_MCP_SESSION_ID`? What about scripts?

2. **Role vs permission bits?** Instead of a free-form `role` string, should we emit explicit permission flags like `can_admin=true`? More flexible but more complex. Start with free-form role.

3. **Persistence across restarts?** Role is tied to the role file. On restart, the agent re-reads the role file and re-registers. Should be automatic as long as registration is re-run on startup.

4. **Backward compatibility?** Recipients that don't understand `role` will simply ignore it (XML attributes they don't know are ignored by XML parsers). Safe to add.

## Implementation order

1. Design doc (this file) — done
2. Update `c2c_mcp.ml` message type to add `role : string option` — **requires Max's file to be unlocked**
3. Update all message construction sites to propagate `role`
4. Update registration to include `role` from role file on startup
5. Update envelope formatters to emit `role` attribute
6. Update recipients (OpenCode plugin, Claude hook, etc.) to read and surface `role`

## Status

**Blocked on c2c_mcp.ml** — Max is actively editing this file. Design doc is ready; implementation awaits Max's file clearance.
