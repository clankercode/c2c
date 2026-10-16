# T3/c2c FUSE full-check timeout

- **Symptom:** The exact c2c source tree was mounted to x-p35 through an owned FUSE bridge and `just check` was run with the repository Dune watchdog and queue timeout set to 3600 seconds. The command exited 124 after the watchdog killed `dune build`; no test failure was reported.
- **Evidence:** `/tmp/t3-c2c-fuse-final-check.log` on x-p35 ends with `DUNE WATCHDOG: killed command after 3600 seconds`; `/tmp/t3-c2c-fuse-final-check.exit` is `124`. The remote build was compiling large OCaml test executables over the FUSE mount for more than an hour.
- **Root cause:** The validation transport made the remote build read the source/build tree through a user-space FUSE bridge. The bounded watchdog correctly stopped the stalled/slow build, but this path is not a reliable full-suite transport.
- **Impact:** The full c2c gate is inconclusive for this run. Focused c2c suites and the isolated T3 idle/active live receipts passed; do not report the remote `just check` as green.
- **Cleanup:** Only the captured bridge and its child SSH/SFTP processes were stopped after the run. No user process or dependency tree was removed.
- **Follow-up:** Run a full gate from a native remote checkout or a pre-seeded remote build directory rather than compiling through FUSE.
