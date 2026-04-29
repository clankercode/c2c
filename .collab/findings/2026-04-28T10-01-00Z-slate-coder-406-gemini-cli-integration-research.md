# #406 Gemini CLI integration research — `c2c start gemini` path

**Author:** slate-coder
**Date:** 2026-04-28 ~10:01 UTC
**Mode:** research-only (per coord) — no impl, no patch.
**Tested binary:** `gemini` v0.25.2 at `/home/linuxbrew/.linuxbrew/bin/gemini`

## TL;DR

Gemini CLI is a **clean fit for c2c integration** — significantly easier than
Claude Code or Codex. It has first-class MCP server support via
`gemini mcp add`, full session lifecycle commands, and a `--trust` flag
that bypasses tool-call confirmation prompts entirely. **No
binary-inspection or TTY auto-answer needed** (unlike #399b for Claude).

Recommended slice shape:
- **(a) `c2c install gemini`** — writes `.gemini/settings.json` (project-scope)
  with the c2c MCP server config. ~30 LoC mirroring `c2c install claude`.
- **(b) `c2c start gemini`** — adapter in `c2c_start.ml`. ~50 LoC mirroring
  `ClaudeAdapter` minus the dev-channel + auto-answer dance. Resume via
  `gemini --resume <idx>` or `--resume latest`.
- **(c) `c2c restart gemini`** — should Just Work via the existing
  restart machinery once (b) lands, since Gemini has no consent prompt
  to auto-answer.

PTY/tmux path is the natural fit (per coord's framing); MCP integration
is essentially free given Gemini's built-in MCP support.

## What I tested

### 1. CLI surface (`gemini --help`)

Rich and well-shaped:

```
gemini [query..]             Launch Gemini CLI  [default]
gemini mcp                   Manage MCP servers       ← MCP first-class
gemini extensions <command>  Manage Gemini CLI extensions
gemini hooks <command>       Manage Gemini CLI hooks  ← incl. Claude Code migrate

Options of note:
  -p, --prompt                  one-shot prompt (replaces -p print mode)
  -i, --prompt-interactive      execute prompt then continue interactive
  -y, --yolo                    auto-approve all tools (YOLO mode)
      --approval-mode           default | auto_edit | yolo
      --allowed-mcp-server-names    array — MCP allowlist
      --allowed-tools           array — tool allowlist
  -e, --extensions              array — extension allowlist
  -r, --resume <idx>            resume previous session (number or "latest")
      --list-sessions           list available sessions for current project
      --delete-session <idx>    delete a session
      --experimental-acp        Agent Communication Protocol mode (interesting,
                                 might parallel Claude's "channels" — worth
                                 follow-up investigation)
  -o, --output-format           text | json | stream-json
  -d, --debug                   debug mode (CLAUDE_CODE_DEBUG analog)
```

### 2. MCP server configuration (`gemini mcp add`)

```
gemini mcp add [options] <name> <commandOrUrl> [args...]

Options:
  -s, --scope              user | project   (default: project)
  -t, --transport, --type  stdio | sse | http   (default: stdio)
  -e, --env                 KEY=value (repeatable)
  -H, --header              "Header: value" for sse/http
      --timeout             ms
      --trust               bypass all tool-call confirmation prompts ← key
      --description         doc string
      --include-tools       comma list
      --exclude-tools       comma list
```

**Probe verified live**: `gemini mcp add c2c-probe c2c-mcp-server --scope project
--env C2C_MCP_SESSION_ID=gemini-probe-<ts> --trust` worked. Wrote to
`./.gemini/settings.json`:

```json
{
  "mcpServers": {
    "c2c-probe": {
      "command": "c2c-mcp-server",
      "args": [],
      "env": { "C2C_MCP_SESSION_ID": "gemini-probe-1777370471" },
      "trust": true
    }
  }
}
```

`gemini mcp list` showed `✓ c2c-probe: c2c-mcp-server (stdio) - Connected`.
**The MCP server actually connected and registered against the c2c broker on
first probe.** No prompt, no consent gate, nothing — `--trust` did exactly
what it says.

Removed cleanly via `gemini mcp remove c2c-probe`.

### 3. Settings storage

- **User scope**: `~/.gemini/settings.json`
- **Project scope**: `<repo>/.gemini/settings.json`
- Schema is JSON, `mcpServers` block has the same shape as Claude Code's
  `mcpServers` (command/args/env), plus Gemini-specific `trust` /
  `include-tools` / `exclude-tools`.

State files in `~/.gemini/`:
- `settings.json` — config
- `state.json` — per-project banner counters etc.
- `oauth_creds.json` — Google auth
- `installation_id`
- `tmp/<sha256-of-cwd>/chats/session-<UTC-iso>-<short-id>.json` —
  session transcripts (per-project, hash-bucketed)
- `tmp/<sha256-of-cwd>/logs.json`

### 4. Session lifecycle

- `gemini --list-sessions` — lists sessions for current project (path-hashed)
- `gemini -r <idx>` / `gemini -r latest` — resume by index or "latest"
- `gemini --delete-session <idx>` — delete

This is **richer** than Claude Code's `--session-id <uuid>` /
`--continue` / `--resume` pair — Gemini exposes a numeric index, which
makes scripting simpler.

### 5. Permission/consent prompts

**No experimental-channels-equivalent prompt.** `--trust` on the MCP
server config (or the broader `--yolo` / `--approval-mode yolo`) handles
all tool-call gating without an interactive 1/2 prompt at session start.

This means **no TTY auto-answer needed for `c2c restart gemini`** — the
#399b problem doesn't exist here.

### 6. Hooks

`gemini hooks migrate --from-claude` exists explicitly to migrate hooks
**from Claude Code to Gemini**. So the Gemini hook system is shaped to
be Claude-compatible. Not directly relevant for #406's PTY/tmux scope,
but useful future signal: c2c's PostToolUse-style hooks could be
migratable.

### 7. Quirks worth noting

- `-p, --prompt` is **deprecated** — positional `gemini "query"` is
  preferred. Output: `[deprecated: Use the positional prompt instead.]`
- All Node invocations print `(node:NNN) [DEP0040] DeprecationWarning:
  The 'punycode' module is deprecated.` to stderr. Cosmetic noise; not
  an error.
- `--list-sessions` walks `/tmp` and surfaces `EACCES` warnings for
  systemd-private dirs ("Skipping unreadable directory"). Cosmetic; the
  command still produces output. Worth filtering in c2c's wrapper if we
  parse the output programmatically.
- `--experimental-acp` (Agent Communication Protocol) is mentioned but
  not yet documented in `--help` for the subcommand. Worth a follow-up
  investigation if c2c wants tighter cross-agent integration than MCP
  alone.

## Recommended slice shape

### Slice (a): `c2c install gemini` (~30 LoC, doc-only adjacent)

Mirror `ClaudeInstaller` in `ocaml/cli/c2c_setup.ml`:

```ocaml
let install_gemini ~project_dir ~broker_root ~alias =
  let settings_path = project_dir // ".gemini" // "settings.json" in
  let mcp_config =
    `Assoc [
      "mcpServers", `Assoc [
        "c2c", `Assoc [
          "command", `String "c2c-mcp-server";
          "args", `List [];
          "env", `Assoc [
            "C2C_MCP_BROKER_ROOT", `String broker_root;
            "C2C_MCP_AUTO_REGISTER_ALIAS", `String alias;
            "C2C_MCP_AUTO_JOIN_ROOMS", `String "swarm-lounge";
          ];
          "trust", `Bool true;  (* bypass confirmation *)
        ]
      ]
    ]
  in
  (* Merge into existing settings.json if present, else write fresh *)
  ...
```

Or even simpler: shell out to `gemini mcp add c2c c2c-mcp-server --scope
project --env C2C_MCP_BROKER_ROOT=<r> --env C2C_MCP_AUTO_REGISTER_ALIAS=<a>
--env C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge --trust` — that path uses
gemini's own settings-merge logic. Probably the cleaner long-term call.

### Slice (b): `c2c start gemini` adapter (~50 LoC)

Mirror `ClaudeAdapter` in `c2c_start.ml`:
- `binary = "gemini"`
- `needs_deliver = false` (MCP handles delivery)
- `needs_poker = false`
- No `dev_channel_args` — Gemini doesn't have dev-channels
- No `start_channels_auto_answer` hook — no consent prompt
- `build_start_args`:
  - Resume case: `[ "--resume"; sid_or_idx; ... ]` — note: Gemini wants
    a numeric index or "latest", not a UUID. We may need to translate
    `c2c start --resume <name>` to `gemini --resume latest` if we
    don't track session indices, or persist the index in instance config.
  - Fresh case: `[]` (just the binary launches interactive)
- `probe_capabilities` = `[ "gemini_mcp", true ]` — MCP is always
  available

### Slice (c): `c2c restart gemini` (free)

Once (a) + (b) land, `c2c restart gemini` should Just Work via the
existing restart machinery — there's no consent prompt to auto-answer,
no dev-channels to negotiate. The `--resume latest` semantics map
naturally to "pick up where you left off".

## Open questions for follow-up

1. **`--resume <idx>` vs c2c's session-name-based instance config**:
   Gemini uses numeric session indices (per-project). c2c's instance
   config stores a session-id string. Need a translation layer:
   - Easiest: persist `gemini --list-sessions | head -1` output (latest
     index) at instance-stop-time; resume to that index.
   - Or: just always `gemini --resume latest` (loses cross-instance
     isolation but simpler).
   - Or: parse `--list-sessions --output-format json` (need to verify
     this combo works) and pick the matching session-id.

2. **`--experimental-acp` interest level**: Worth a separate research
   slice if cross-agent MCP-style RPC is on c2c's roadmap. Could
   parallel/replace channels-push semantics.

3. **Hook migration**: `gemini hooks migrate --from-claude` is
   intriguing — `c2c install gemini` could optionally run this if
   `~/.claude/settings.json` has hooks the user wants ported.
   Out-of-scope for v1, but worth a flag-stub for future.

4. **OAuth boundary**: `~/.gemini/oauth_creds.json` is per-host.
   Confirmed `Loaded cached credentials.` on `--list-sessions` —
   suggests no auth prompt on managed-session start as long as
   `oauth_creds.json` is present. Should `c2c install gemini` hint
   the user to run `gemini` once interactively to seed creds before
   first managed launch? Probably yes — a one-line check + warn.

## Confidence

- **High** on "MCP integration is built-in and `--trust` skips the
  consent gate" — verified live with a probe registration.
- **High** on "no #399b-equivalent TTY auto-answer needed" — Gemini's
  permission model is settings-based (`--trust` per-server), not
  prompt-based.
- **Medium** on resume-index translation — would need a dogfood pass
  to confirm the cleanest UX.
- **Medium-low** on `--experimental-acp` semantics — only seen the
  flag, didn't trace what it actually does.

## Suggested next-slice scope (when impl is greenlit)

Optimal order: (a) install → (b) start → (c) restart-validation pass.

Total estimated LoC: ~80-120 across `c2c_setup.ml` + `c2c_start.ml` +
test fixtures, plus ~20 LoC of doc updates (CLAUDE.md client list,
docs/commands.md install/start tables).

## Cross-reference

- `ocaml/c2c_start.ml` — `ClaudeAdapter` (~L2620), `CodexAdapter` (~L2658),
  `OpencodeAdapter` (further down) for adapter pattern
- `ocaml/cli/c2c_setup.ml` — install path for each client
- `.collab/findings/2026-04-28T09-15-00Z-slate-coder-399-channels-permission-research.md`
  — companion finding (Claude Code dev-channels research; Gemini's
  no-equivalent-prompt is the relief)
- Gemini CLI docs: <https://ai.google.dev/gemini-api/docs/gemini-cli>
  (out-of-tree; verify URL — I tested behaviorally, not docs-side)

— slate-coder
