# RESULT — B179 rename auto re-register/rebind relay identity

**Branch:** `fix/bl-b179`  
**Status:** implemented, tested, committed (not merged; `bl done` not run)  
**Commit:** `f09de6a2beb09bb49e267344c105090f326712d1`  
**Full SHA:** `f09de6a2beb09bb49e267344c105090f326712d1`

## Problem

After `c2c rename`, local alias worked but the relay identity binding stayed
on the old alias. First post-rename `c2c monitor` relay peek failed TERMINAL:

```
unauthorized: alias "<new>" has no identity binding
```

Operators had to discover and run `c2c relay register --alias=<new>` manually.

## Fix

On successful local rename (CLI + MCP), best-effort rebind:

1. If no relay URL configured → `relay_rebind.status = skipped` (local-only).
2. If configured → signed register of **new** alias with the **same** Ed25519
   identity (`c2c relay register` path).
3. On failure → local rename still succeeds; output includes
   `next_step: "c2c relay register --alias=<new>"` (copy-pasteable).
4. Old alias lease state: **dual-bind until TTL** (defined; not silently
   abandoned without documentation).

### Key files

| File | Role |
|------|------|
| `ocaml/relay_rename_rebind.ml` (+ `.mli`) | Shared rebind helper |
| `ocaml/cli/c2c_rename_cmd.ml` | CLI surfaces rebind + human output |
| `ocaml/c2c_identity_handlers.ml` | MCP rename uses `rebind_lwt` (no nested `Lwt_main.run`) |
| `ocaml/c2c_mcp.ml` | MCP tool description documents B179 |
| `ocaml/test/test_relay_rename_rebind.ml` | Live loopback + skip + next_step + e2e |
| `.collab/design/2026-07-13-b140-atomic-alias-rename.md` | Design table updated |

### `relay_rebind` JSON shape

```json
{ "status": "ok|skipped|error",
  "new_alias": "...",
  "relay_url": "...",          // when known
  "old_alias_lease": "dual_bind_until_ttl",
  "next_step": "c2c relay register --alias=<new>",  // on error
  "error": "...",              // on error
  "reason": "..." }            // on skip
```

## Tests (all green)

```
test_relay_rename_rebind.exe          6/6 OK
test_c2c_cli.exe init_name_hardening 10 OK  (CLI rename happy path + relay_rebind skipped)
test_c2c_cli.exe list 7               OK  (help documents auto-rebind)
test_c2c_mcp.exe broker 129-139      11/11 OK  (B140 rename suite incl. MCP tools/call rename)
```

## Review (self: pirfl + review-and-fix lens)

| Check | Verdict |
|-------|---------|
| Acceptance: auto re-register when relay configured | PASS |
| Acceptance: copy-pasteable next step when cannot | PASS |
| Acceptance: old lease defined (dual-bind TTL) | PASS |
| Acceptance: surface success/failure in rename output | PASS (JSON + human) |
| Both CLI + MCP surfaces | PASS |
| No rollback of local rename on relay failure | PASS |
| No `Lwt_main.run` inside MCP Lwt path | PASS (`rebind_lwt`) |
| Short timeout (5s) so dead relay cannot hang rename | PASS |
| Docs/help drift | PASS (CLI man, MCP description, B140 design) |
| Bus-not-RPC | N/A (register is identity binding, not approval) |

## Not done (per instructions)

- No merge to master
- No `bl done B179`
- No push / deploy

## Operator note after install

```
just bi   # or just install-all — rebuild + install required for live agents
```
