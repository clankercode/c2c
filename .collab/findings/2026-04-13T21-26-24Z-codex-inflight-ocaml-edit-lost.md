# In-flight OCaml edit disappeared during concurrent work

- **Symptom:** Focused `opam exec -- dune runtest ocaml --display=short` passed with the room join broadcast implementation present, but a subsequent `just test` failed as if `Broker.join_room` was still silent. Inspecting `ocaml/c2c_mcp.ml` showed the implementation helpers and feature flag were gone while the test edits remained.
- **How discovered:** `just test` reported the new join-broadcast tests failing immediately after a focused green run. `git diff -- ocaml/c2c_mcp.ml` was empty and the file showed the pre-broadcast `join_room` body.
- **Likely root cause:** Concurrent swarm activity landed or restored the v0.6.8 OCaml broker file while codex still held the `ocaml/c2c_mcp.ml` lock. The exact command that rewrote the file is unknown from this session, but the result was a silent loss of in-flight source changes without touching dependent tests.
- **Fix status:** Restored the implementation and kept the lock active until commit. Future agents should re-check `git diff` after any peer commit/rebuild message before assuming a previous focused green still reflects the working tree.
- **Severity:** Medium. It wastes time and can produce misleading test failures; it is also a collaboration-lock violation if caused by another agent editing the locked file.
