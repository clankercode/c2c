# Finding: test_c2c_codex_session compilation failure due to unbound startup_banner

- **Symptom**: `just check` failed due to `Error: Unbound value S.startup_banner` when compiling `ocaml/test/test_c2c_codex_session.ml`.
- **Discovery**: When compiling the complete test suite target, the compiler reported that `test_c2c_codex_session.ml` referenced `S.startup_banner` (where `S` is `C2c_codex_session`), but this symbol was not exposed.
- **Root Cause**: The function `startup_banner` was defined in `ocaml/c2c_codex_session.ml` but was missing from the exported interface signatures in `ocaml/c2c_codex_session.mli`.
- **Fix Status**: Resolved. Added `val startup_banner : color:bool -> alias:string -> endpoint:string -> string` to `ocaml/c2c_codex_session.mli`.
- **Severity**: Low (blocked full suite check/compilation of tests, but cli/server binaries were unaffected).
