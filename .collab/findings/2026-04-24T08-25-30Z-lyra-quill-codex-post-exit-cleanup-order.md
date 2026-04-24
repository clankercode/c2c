# Codex outer cleanup could be skipped by post-exit terminal write

- Symptom: after a failed codex shutdown repro, outer/inner/deliver processes were all gone but pidfiles remained in the instance dir.
- Root cause hypothesis: outer loop reached post-exit reporting but got interrupted before cleanup_and_exit, likely by fragile tty/job-control state around the final resume-hint write.
- Fix status: moved cleanup_and_exit before the final resume-hint print in ocaml/c2c_start.ml so stale pidfiles/sidecars are torn down even if the terminal write path is still unsafe.
