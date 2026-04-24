# Phase 1 Implementation: Extract `c2c_setup.ml`

## What to extract

From `ocaml/cli/c2c.ml`, extract lines **4799–5935** (the "install/setup" section) to new file `ocaml/cli/c2c_setup.ml`.

## Exact range

```
4799  let find_ocaml_server_path = ...
4814  let json_read_file = ...
4821  (* --- install: self ...)
4823  let do_install_self = ...
4905  (* --- subcommand: init ...)
4907  (* --- subcommand: setup ...)
4909  let alias_words = ...
4911  let generate_alias = ...
4917  let generate_session_id = ...
4933  let json_write_file = ...
4940  let json_write_file_or_dryrun = ...
4947  let mkdir_or_dryrun = ...
4953  let default_alias_for_client = ...
4961  (* --- setup: Codex ...)
4963  let c2c_tools_list = ...
4971  let setup_codex = ...
5043  (* --- setup: Kimi ...)
5045  let setup_kimi = ...
5094  (* --- setup: OpenCode ...)
5096  let setup_opencode = ...
5247  (* --- setup: Claude PostToolUse hook ...)
5249  let claude_hook_script = ...
5275  let configure_claude_hook = ...
5339  (* --- PATH detection helper ...)
5341  let which_binary = ...
5353  (* --- install: claude ...)
5355  let setup_claude = ...
5527  (* --- install: crush ...)
5529  let setup_crush = ...
5585  (* --- install: shared dispatcher ...)
5587  let resolve_mcp_server_paths = ...
5608  let canonical_install_client = ...
5613  let known_clients = ...
5614  let install_subcommand_clients = ...
5617  let init_configurable_clients = ...
5619  let detect_client_prefixes = ...
5620  let start_clients = ...
5623  let do_install_client = ...
5653  (* --- install: detection + TUI *)
5655  let self_installed_path = ...
5660  let client_configured = ...
5731  let detect_installation = ...
5740  let prompt_yn = ...
5752  let prompt_channel_delivery = ...
5763  let run_install_tui = ...
5846  (* --- install: Cmdliner wiring *)
5848  let install_common_args = ...
5866  let install_self_subcmd = ...
5885  let install_client_subcmd = ...
5903  let install_all_subcmd = ...
5930  let install_default_term = ...
```

Line 5937 onward (`repo_config_path`, etc.) STAYS in `c2c.ml`.

## Cross-module dependencies

Functions in `c2c_setup.ml` reference these from `c2c.ml`:
- `json_flag` (line 311)
- `resolve_claude_dir` (line 30)
- `resolve_broker_root` (from `C2c_start`, imported as `C2c_start.resolve_broker_root`)
- `current_c2c_command` (line 318)

## What to do in `c2c.ml` after extraction

1. **Delete** lines 4799–5935 (the extracted block)
2. **Add** to top of `c2c_setup.ml`:
   ```ocaml
   (* Extracted setup/install helpers — migrated from c2c.ml *)
   ```
3. **Add** to `c2c_setup.ml`:
   - `open C2c_start` at top (for `resolve_broker_root`)
   - External references: `json_flag`, `resolve_claude_dir`, `current_c2c_command`

   Since these are in the same compilation unit, add:
   ```ocaml
   (* References to c2c.ml definitions needed here *)
   external json_flag : bool Cmdliner.Term.t = "json_flag"
   external resolve_claude_dir : unit -> string = "resolve_claude_dir"
   external current_c2c_command : unit -> string = "current_c2c_command"
   ```

   Actually, `external` declarations are for C bindings. Instead, just reference them directly since all files in the same dune executable are compiled together. Add to top of c2c_setup.ml:
   ```ocaml
   (* These are defined in c2c.ml and available in the same executable *)
   ```

4. **Update** the `install` command group (stays in c2c.ml at ~line 6236):
   - It references `install_self_subcmd`, `install_all_subcmd`, `install_client_subcmd`, `install_subcommand_clients`
   - These will now be `C2c_setup.install_*` — update references

5. **Update** `print_enriched_landing` (line 9936) — it calls `detect_installation ()`:
   - Change to `C2c_setup.detect_installation ()`

6. **Update** `init_cmd` (around line 6034) — it calls `do_install_client`:
   - Change to `C2c_setup.do_install_client`

## OCaml compilation unit rules

All `.ml` files in the same `executable` block in dune are compiled into a single module. Types and values defined in `c2c_setup.ml` are accessible from `c2c.ml` (and vice versa) without any `open` or `include` needed — just use them directly.

So the key changes are:
- Create `c2c_setup.ml` with the extracted code
- Delete lines 4799–5935 from `c2c.ml`
- Update call sites in `c2c.ml` that reference extracted functions

## Steps

1. Create `c2c_setup.ml` with header + extracted code
2. Delete extracted block from `c2c.ml`
3. Build (`just build`) — expect compilation errors from unresolved names
4. Fix errors: update `print_enriched_landing`, `init_cmd`, and `install` group to use `C2c_setup.*`
5. Verify build passes
6. Run `just test` to confirm no regressions
7. Commit with LOC-before/after counts

## LOC targets

- `c2c.ml`: 10208 - 1137 = ~9071 LOC after extraction
- `c2c_setup.ml`: ~1137 new LOC
