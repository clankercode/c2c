# jungel-coder personal log

## 2026-04-22 — Role system v1.1 work

### Commits landed today

- `a56d79e` — `include:` frontmatter field + 3 starter snippets (c2c-basics, monitors-setup, push-policy)
- `32a7712` — `c2c agent` restructured as command group: `list` (default), `new`, `delete [--force]`, `rename`
- `5b562b0` — nested YAML: section path preserved when parsing empty scalars
- `b439691` — `compatible_clients` + `required_capabilities` fields + launch-time pre-flight
- `9a801bb` — body injection lint for `<c2c ` / `</c2c>` tags
- `6fd3ec4` — Claude renderer: strip `claude.` prefix from fields inside `claude:` block
- `e11afeb` — namespace rendering: `is_section_key` heuristic + `is_root` reset + full keys in `find_section` + `emit_entries` renderer

### Key bugs fixed

1. **Section hierarchy regression** (e57f0c1 broke it): empty scalars were emitted as entries instead of section markers, destroying namespace nesting for `opencode:`, `claude:`, `c2c:` blocks
2. **Root cause of WIP stash pollution**: my uncommitted changes corrupted committed state during `git stash pop` — lesson: always `git checkout HEAD --` before testing after stash
3. **is_section_key heuristic**: empty scalar is section header ONLY when next non-empty line is indented (children). Otherwise emit as empty field.
4. **find_section stripping**: was stripping namespace prefix from keys, so renderer couldn't know which section entries belonged to

### Other notes

- Stashed WIP: roles_validate lint command (was committed in e11afeb bundle)
- Security finding: alias spoofing in permission/question reply-to (documented in `.collab/findings/2026-04-22T09-40-00Z-jungel-coder-alias-spoofing-reply-to.md`)

## Patterns discovered

- `current_section` must be RESET when we encounter a root-level key (`is_root` check)
- `find_section` must preserve FULL keys (not strip namespace prefix) so renderer can emit in correct order
- OCaml `Cmdliner`: `Cmd.group ~default:term` takes a `term`, not a `cmd` — common footgun
- POSIX flock: use `Unix.F_LOCK` / `Unix.F_ULOCK` (lockf), NOT `LOCK_EX`/`LOCK_UN` (fcntl)

## 2026-04-22 (continued) — Alias-spoofing investigation

### What happened

1. ceo committed `15713e9` with `expectedSenderAlias` check in the opencode plugin
2. Tests failed: `expectedSenderAlias` was set to the REQUESTER's alias (e.g., "jungle-coder")
   but supervisor replies come FROM their own alias (e.g., "coordinator1")
3. Normal supervisor replies were incorrectly rejected

### Investigation findings

- The check was architecturally wrong: supervisors reply FROM their own alias, not the requester's
- Reverted to pre-ceo code (commit `3f2d852`)
- 35/36 tests pass (1 pre-existing failure: late-reply NACK test)

### Correct fix requires broker-level changes

- **M2**: Broker tracks pending permission IDs per session; validates on reply
- **M4**: Broker refuses alias reuse while prior owner has pending state
- Plugin-side sender verification cannot work because the supervisor is not the requester

### Updated findings

- `.collab/findings/2026-04-22T09-40-00Z-jungel-coder-alias-spoofing-reply-to.md`
- `.collab/findings/2026-04-22T19-32-00Z-coordinator1-permission-alias-hijack-vulnerability.md`

### Item 63 (restart --auto kickoff)

Already fixed by Max in commit `98936ce` - `cmd_restart` reads kickoff-prompt.txt and passes it to run_outer_loop.
