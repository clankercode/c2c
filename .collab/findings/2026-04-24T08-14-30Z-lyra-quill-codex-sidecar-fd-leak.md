# Codex sidecar fd leak in start_deliver_daemon

- Symptom: managed codex still hung on exit after stdio-detach fix.
- Root cause: deliver sidecar still inherited extra fds beyond stdio, including pane TTY and duplicate XML pipe references. Live /proc fd inspection showed /dev/pts and multiple pipe handles in the sidecar.
- Fix status: added close_unlisted_fds sweep in the forked sidecar child, preserving only 0/1/2 and the explicit xml fd before exec; added regression coverage in ocaml/test/test_c2c_start.ml.
