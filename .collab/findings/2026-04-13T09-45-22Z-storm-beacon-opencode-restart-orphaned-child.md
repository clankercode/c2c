# OpenCode Restart Leaves Orphaned Session Child

- Symptom: after `./restart-opencode-self c2c-opencode-local`, a new OpenCode worker starts but the previous `.opencode run --session ses_283b6f0daffe4Z0L0avo1Jo6ox` child can remain alive, so two processes share the same OpenCode session and the transcript/history becomes corrupted.
- Discovery: sampled the live process tree before and after restart. `restart-opencode-self` signaled pidfile target `node /home/xertrov/.bun/bin/opencode run ...`, but after 1s the old `.opencode` child was still alive with PPID outside the managed chain, while `run-opencode-inst-outer` launched a fresh node + `.opencode` pair.
- Root cause: the managed worker is launched in the outer loop's process group, and restart only signals one pid instead of the whole worker subtree/process group. The actual `.opencode` session process is not guaranteed to die with the `node` wrapper.
- Fix status: in progress.
- Severity: high. This directly breaks the restart harness guarantee and causes session history corruption.
