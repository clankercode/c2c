# Finding/Follow-up: `tmux_target_info.tmux_pane_id` type field never written

**Filed**: 2026-05-01
**Agent**: cedar-coder (from test-agent's peer-PASS review of #523)
**Status**: Non-blocking; separate follow-up

## Context

`type tmux_target_info` in `c2c_start.ml` (line 1770) and `c2c_start.mli` (line 57):

```ocaml
type tmux_target_info = { tmux_location : string; tmux_pane_id : string }
```

`tmux_pane_id` field is:
- **Parsed** by `parse_tmux_target_info` from a `tmux display -p '#{pane_id}'` command
- **Written** by `write_tmux_target_info` to `tmux.json`, but ONLY `session` was ever written — `pane_id` was always absent from the JSON output
- **Read back** by no function — `read_tmux_location_opt` only reads `session`

After #523, `write_tmux_target_info` only writes `session` (dead fields removed). But the type + parser still carry `tmux_pane_id`.

## Fix scope

1. Remove `tmux_pane_id` from `type tmux_target_info` in both `.mli` and `.ml`
2. Remove `parse_tmux_target_info` — only used to produce `tmux_target_info` values which are then written (and now only `session` matters)
3. Remove `parse_tmux_target_info` callers if any (grep `parse_tmux_target_info` in OCaml)
4. Update callers of `tmux_target_info` to construct without `pane_id`

Or alternatively: keep `parse_tmux_target_info` but discard `pane_id` from the constructed record.

## Related

- #523 removed dead fields from write side
- This is type-level cleanup after write-side cleanup
