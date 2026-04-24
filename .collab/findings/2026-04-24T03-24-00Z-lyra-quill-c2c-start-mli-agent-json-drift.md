## `c2c_start.mli` drift blocked install-all

- Symptom:
  `just install-all` failed before installation with an interface mismatch between `ocaml/c2c_start.ml` and `ocaml/c2c_start.mli`.

- How it was discovered:
  The final install step for the Codex MCP identity fix failed during dune build, even though the focused MCP/CLI tests were already green.

- Root cause:
  `prepare_launch_args` in `ocaml/c2c_start.ml` already accepts `?agent_json`, but the `.mli` declaration still had the older signature without that optional argument.

- Fix status:
  Fixed in working tree by updating `ocaml/c2c_start.mli` to match the implementation signature and doc comment.

- Severity:
  Medium. Unrelated to Codex identity directly, but it blocks `just install-all`, so no OCaml change can be made live until it is fixed.
