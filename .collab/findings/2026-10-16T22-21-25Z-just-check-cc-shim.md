# `just check` can select the Claude Code `cc` shim

- **Symptom:** `just check` failed before project checks because `cc -std=c11` was handled by `/home/xertrov/.local/bin/cc` (Claude Code), which rejected the compiler flag.
- **Root cause:** the machine-local executable shim precedes `/usr/bin/cc` on `PATH`.
- **Resolution:** reran the unchanged check with `PATH=/usr/bin:/bin:/home/xertrov/.cargo/bin`; the relay-supervisor tests, code-generation checks, broker catalog check, docs command check, and full `just check` completed with `CHECK_RC=0`.
- **Scope:** environment-only; no repository source change was required.
