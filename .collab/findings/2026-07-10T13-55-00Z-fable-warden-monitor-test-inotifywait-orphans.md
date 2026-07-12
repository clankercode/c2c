# Monitor tests leak orphaned inotifywait watchers (20 found in one worktree)

- **Symptom**: `c2c dev worktree gc --clean` refused to remove
  `.worktrees/friction-j3-monitor-ndjson` — REFUSE: active cwd. The holder
  was an `inotifywait -m ... /tmp/tmpXXXX/mcp/archive /tmp/tmpXXXX/mcp`
  process. Killing it revealed a queue: **20 orphaned inotifywait
  processes** (PPID 1, ages up to 6.5h), each with cwd in the J3 worktree,
  each watching a DIFFERENT already-deleted `/tmp/tmpXXXX/mcp` temp dir.
- **Discovery**: friction-cn closure cleanup, 2026-07-10 ~23:50 AEST.
- **Root cause (likely)**: monitor-related tests (J3's monitor NDJSON work
  and/or its review runs) spawn the `c2c monitor` inotify watcher against a
  temp broker root, and the test/harness exits without killing the watcher
  child. `inotifywait -m` never exits on its own even after the watched
  dirs are deleted (it holds the inode watches). One orphan leaked per test
  run.
- **Fix status**: NOT fixed — symptom cleaned up (all 20 killed, worktree
  removed). Needs a slice: whichever test-support/monitor code spawns
  inotifywait must reap it (kill on test teardown, or watcher should exit
  when all watched dirs vanish / parent dies — e.g. prctl PDEATHSIG or a
  parent-pid poll).
- **Severity**: low-medium (resource leak: fd/watch handles + one process
  per test run; blocks worktree GC via the cwd-holder check; silent).
- **Repro hint**: run the monitor watcher tests, then
  `pgrep -a inotifywait` and check for watchers on deleted /tmp dirs.
