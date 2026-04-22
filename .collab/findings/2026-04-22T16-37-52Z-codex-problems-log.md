# Problems Log

## Claude development channels broken under `c2c start`

- Symptom: running `claude --dangerously-load-development-channels server:c2c`
  directly from the shell worked, but `c2c start claude` did not expose the
  same behavior.
- How discovered: traced `c2c start` into [`ocaml/c2c_start.ml`] and added a
  failing OCaml regression test for `prepare_launch_args`.
- Root cause: the managed Claude argv was malformed. It always routed
  `server:c2c` through `--channels`, and the intended development-channel flag
  was emitted as `" --dangerously-load-development-channels"` with a leading
  space, so the real flag never appeared in argv.
- Fix status: fixed in `ocaml/c2c_start.ml`. Managed Claude launches now emit
  only `--dangerously-load-development-channels server:c2c`, even when
  `.c2c/config.toml` has `enable_channels = true`.
- Severity: high. This silently disabled the development-channel delivery path
  for every managed Claude session launched via `c2c start`.

## `just build` fails inside the sandbox

- Symptom: `just build` failed immediately with `Read-only file system (os
  error 30)` while trying to create `/run/user/1000/just/...`.
- How discovered: attempted the repo-preferred build flow after fixing the
  launcher bug.
- Root cause: in this Codex sandbox, `just` wants a temp/runtime path outside
  the writable roots.
- Fix status: worked around locally by using the repo-documented fallback
  compile path: `opam exec -- dune build -j1`.
- Severity: medium. It blocks the preferred recipe path under sandboxed agent
  execution, but does not affect normal host builds.
