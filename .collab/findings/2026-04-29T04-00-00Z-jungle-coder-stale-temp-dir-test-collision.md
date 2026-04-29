# Stale `/tmp/c2c-mcp-*` temp dirs interfere with test runs

## Symptom
`dune exec test_c2c_mcp.exe` in a worktree showed 2 test failures
(161: lazy-create Ed25519, 163: register rejects x25519 mismatch) with:

```
[exception] Unix.Unix_error(Unix.EEXIST, "mkdir", "/tmp/c2c-mcp-399ed649")
  Raised by primitive operation at with_temp_dir in test_c2c_mcp.ml
```

The same two tests were failing every run despite the worktree being
clean and the code being unchanged from a passing state.

## Discovery
`ls /tmp/c2c-mcp-*` showed two stale directories:
- `/tmp/c2c-mcp-1fd248dd/x25519-keys`
- `/tmp/c2c-mcp-399ed649/x25519-keys`

These are leftover from prior test runs where `with_temp_dir`'s cleanup
(`rm -rf`) apparently didn't complete (killed process, signal, etc.).

## Root Cause
`with_temp_dir` in `test_c2c_mcp.ml`:

```ocaml
let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in  (* /tmp *)
  let dir = Filename.concat base (Printf.sprintf "c2c-mcp-%06x" (Random.bits ())) in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> Sys.command (Printf.sprintf "rm -rf %s" dir) |> ignore)
    (fun () -> f dir)
```

`Random.bits ()` is a 30-bit int (OCaml's `Random.bits`). With 6 hex
digits (`%06x`) the space is 0x000000–0xFFFFFF (16.7M). Probability of
collision on any single run with 2 pre-existing dirs is ~2/16.7M ≈
1-in-8M. Collisions are rare but the directories are persistent, so a
collision eventually happens.

## Fix Status
Not yet fixed. Options:
1. **Use a UUID or process-unique suffix** instead of `Random.bits` —
   e.g. `Uuidm.v4_gen Random.State.default` or include `Unix.getpid()`
   in the suffix.
2. **Guard with `mkdir` + `~mask:0o700` + `~create:true` + `~perms:0o755`
   and catch `EEXIST`** — retry with a new random suffix.
3. **Best-effort cleanup on startup** — scan `/tmp/c2c-mcp-*` on test
   binary startup and `rm -rf` any belonging to dead PIDs.

Option 2 is the cleanest fix with no API change to `with_temp_dir`.

## Severity
Low for normal development (collisions are rare). Medium for CI/automated
runs where the same `/tmp` is reused across many test invocations without
host reboot. High for parallel test execution (multiple alcotest processes
could race on the same hex suffix).

## Reported
2026-04-29 by jungle-coder during peer-PASS review of slate's
`slice/crit-2-cross-host-divergence-test` (SHA 3e376511).
