# codebase-memory MCP transport unavailable during B124

- **Symptom:** The parent session's codebase-memory MCP request returned `Transport closed`; this delegated session has no codebase-memory graph tools exposed, so `search_graph`, `trace_path`, and `get_code_snippet` cannot be called.
- **Discovery:** B124 code discovery began after the reported transport failure. The required graph tool surface was absent from this session's available tools, including on retry/orientation.
- **Root cause:** Unknown; the MCP transport closed before this slice was delegated, and the delegated tool surface did not reconnect.
- **Fix status:** Unresolved tooling outage. Used the documented targeted `rg` fallback for code and string discovery; no repository runtime behavior is affected.
- **Severity:** Medium workflow degradation; discovery is slower and graph completeness must be checked manually, but implementation and tests remain possible.
