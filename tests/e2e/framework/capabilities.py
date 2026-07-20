from __future__ import annotations

# Shared capability names used by the Python E2E framework.
# Keep these aligned with the OCaml vocabulary where equivalents exist.

CLAUDE_CHANNEL = "claude_channel"
# Historical: upstream codex removed --xml-input-fd. Kept only so older scenario
# unit tests can still use the string as a dummy capability key.
CODEX_XML_FD = "codex_xml_fd"
# Managed codex primary path is app-server (hooks fallback), not XML sideband.
CODEX_MANAGED = "codex_managed"
CODEX_HEADLESS_THREAD_ID_FD = "codex_headless_thread_id_fd"
OPENCODE_PLUGIN = "opencode_plugin"
OPENCODE_PLUGIN_ACTIVE = "opencode_plugin_active"
PTY_INJECT = "pty_inject"
KIMI_WIRE = "kimi_wire"
AGY_AGENTAPI = "agy_agentapi"
PI_C2C = "pi_c2c"
