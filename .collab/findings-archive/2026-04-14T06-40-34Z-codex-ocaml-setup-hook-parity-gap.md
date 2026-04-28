# OCaml setup hook parity gap

- **Symptom:** the OCaml CLI `c2c setup` path does not write the Claude
  Code PostToolUse inbox hook, while the Python
  `c2c_configure_claude_code.py` helper does.
- **How I found it:** `cc-zai-spire-walker` called out that onboarding via
  OCaml setup leaves the hook unset, which means the client can start without
  automatic inbox delivery behavior configured.
- **Root cause:** the OCaml setup path and the Python configure helper are not
  fully in parity yet.
- **Fix status:** fixed by commit 3409579 — `setup claude` now writes PostToolUse hook.
- **Severity:** medium. This affects new-agent onboarding and can make the
  system feel less automatic than the docs imply.
