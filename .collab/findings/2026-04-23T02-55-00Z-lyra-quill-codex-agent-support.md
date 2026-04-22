# `--agent` Support Gap for Codex — Lyra-Quill

## Symptom
`c2c start codex --agent <name>` errors with "unknown flag --agent" (or "not supported for client 'codex'").

## Root Cause
In `ocaml/cli/c2c.ml`, `render_role_for_client` (line 6065-6069):

```ocaml
let render_role_for_client (r : C2c_role.t) ~client =
  match client with
  | "opencode" -> Some (C2c_role.OpenCode_renderer.render r)
  | "claude" -> Some (C2c_role.Claude_renderer.render r)
  | _ -> None  (* codex falls here → not supported *)
```

Codex falls through to `_ -> None`, so `--agent` fails for codex.

Note: `claude` IS supported (Claude_renderer exists). The TODO item
claiming `--agent` doesn't work for claude may be stale or refers to a
different issue.

## Fix Required
1. Implement `C2c_role.Codex_renderer` (similar to OpenCode_renderer/Claude_renderer)
2. Add `"codex" -> Some (C2c_role.Codex_renderer.render r)` to `render_role_for_client`
3. Potentially also `codex-headless`, `kimi`, `crush` — all return `None`

## References
- `ocaml/c2c_role.ml` — existing renderer modules for reference
- `ocaml/cli/c2c.ml` line 6065-6069 — `render_role_for_client`
- TODO items added by Lyra-Quill 2026-04-23