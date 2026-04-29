**Author:** stanza-coder

# CLAUDE.md staleness audit 2026-04-28

## Summary
- Sections audited: 8 (top-of-file goal, Development Rules, Doc hygiene, Ephemeral DMs, Wake-up, Per-agent memory, Key Architecture Notes, Python Scripts deprecated)
- Issues found: **5 high / 7 med / 4 low**
- Recommended trim: ~2.0k chars (mostly the trailing `# test` lines, the `claude_send_msg.py` block, and dup PTY/managed-session paragraphs)
- Recommended add: ~0.6k chars (corrected env-var defaults, missing `c2c doctor delivery-mode --json`, brief `c2c init` mention, `[swarm]`/`[default_binary]` config callout)

## Contradictions / actively-wrong (high)

- **line 3**: `"the Python scripts are still useful"` — out of date. The legacy Python scripts that this whole top-paragraph was about (`c2c_registry.py`, `c2c_verify.py`, `claude_send_msg.py`) are **gone from `scripts/`** as of today (verified via `ls scripts/`). Only `c2c_tmux.py` and a handful of helper shell scripts remain. The OCaml side is the source of truth, period — soften this to "a few helper Python scripts remain in `scripts/` (mostly `c2c_tmux.py`); everything else has moved to OCaml."

- **line 188**: `"The server now defaults to `0` (safe). Even if set to `1`, auto-drain only fires when…"` — **wrong about the broker default**. `ocaml/server/c2c_mcp_server_inner.ml:81-86` shows `auto_drain_channel_enabled` returns `channel_delivery_enabled ()` (which defaults to **true**) when the env var is unset. The "safe default" only holds because **`c2c start` and `c2c install` explicitly write `C2C_MCP_AUTO_DRAIN_CHANNEL=0`** into managed clients (verified at `ocaml/c2c_start.ml:1150,2101,2233`, `ocaml/cli/c2c_setup.ml:461`, `ocaml/c2c_wire_bridge.ml:149`). Suggested fix: rephrase to *"`c2c install` and `c2c start` both write `C2C_MCP_AUTO_DRAIN_CHANNEL=0` for safety; the broker itself still defaults to ON, so a hand-rolled MCP config without the install path could re-introduce the footgun."*

- **line 328**: `"C2C_MCP_INBOX_WATCHER_DELAY (default 5.0)"` — **wrong default**. Source at `ocaml/server/c2c_mcp_server_inner.ml:88-94` shows `| None -> 2.0`. Either the code regressed or the doc is stale; either way the doc currently lies about a load-bearing timing constant. Fix to `(default 2.0)` and either update the rationale or fix the code.

- **lines 65–74**: The "scripts/* canonical harness" paragraph references **four scripts that don't exist**: `scripts/c2c-tmux-enter.sh`, `scripts/c2c-tmux-exec.sh`, `scripts/tmux-layout.sh`, `scripts/tui-snapshot.sh`. Only `scripts/c2c-swarm.sh`, `scripts/c2c_tmux.py`, and `scripts/relay-smoke-test.sh` are present. This sends agents on a dead-link goose-chase right when they're about to run a live-peer test. Trim to the two that exist; refer the rest to `scripts/c2c_tmux.py` (which subsumes enter/exec/layout/snapshot via `peek/keys/exec/layout`).

- **line 320**: `"PTY injection (deprecated but still useful): `claude_send_msg.py`…"` — `scripts/claude_send_msg.py` **does not exist** in the tree. Whole paragraph is stale narration of a script that was removed. Either delete (preferred — agents don't need to know the deprecated PTY-master mechanism) or relocate to a `.collab/findings-archive/` reminiscence.

## Stale references (med)

- **line 234–248**: "Never call `mcp__c2c__sweep`" block is still framed around `run-(kimi|codex|opencode|crush|claude)-inst-outer` outer-loop scripts. Those scripts are **gone** (no `run-*-inst*` matches in `scripts/`). Both the `pgrep` snippet and the prose ("if using the old `run-*-inst-outer` scripts, the outer loop stays alive") describe extinct architecture. The sweep-is-dangerous warning is still valid for `c2c start`-supervised sessions, but the paragraph needs rewriting around `c2c instances` / `c2c stop` not the run-scripts. Replace `pgrep -af "run-…-inst-outer"` with `c2c instances`.

- **line 240**: `"./c2c dead-letter --replay (Python shim only; the installed OCaml binary does not support --replay)"` — needs verification; `c2c dead-letter` is now in the OCaml CLI (it shows under Tier 1 in `c2c --help`). Worth a one-line check whether `--replay` landed; either way the "Python shim only" caveat is suspicious now that the Python registry/verify shims are gone.

- **line 322**: `"c2c_verify.py counts these markers in transcripts."` — `scripts/c2c_verify.py` does not exist. Either the verifier moved into OCaml (likely `c2c verify`, which is a Tier 1 command) or the line is dead. Replace with `c2c verify`.

- **line 317**: `"Registry is hand-rolled YAML (c2c_registry.py)."` — `scripts/c2c_registry.py` does not exist. Registry is now OCaml; the "Do NOT use a YAML library" warning is still valid as a constraint on OCaml-side code, but the citation file is wrong. Point at the OCaml registry module (likely `ocaml/registry/*.ml`) instead.

- **line 274–289**: The `Monitor` heartbeat snippets are fine, but the "Do NOT arm `c2c monitor --all` when channels push is on — duplicates every message" warning at line 291 is high-value and could move higher. Consider: this is the kind of footgun that hits new agents on day-one.

- **line 232**: `"The old harness scripts (run-claude-inst-outer, etc.) still work but are deprecated"` — they don't still work because they're not present. Drop this sentence.

- **line 240**: secondary — `mcp__c2c__list` and `mcp__c2c__peek_inbox` are correct as of the deferred-tools list, good.

## Missing critical info (med)

- **`[default_binary]` config table — currently described only in prose at line 217**: `.c2c/config.toml` shows a real `[default_binary]` table with TOML semantics. Worth a single line under Key Architecture Notes referencing it as the canonical override mechanism (priority `--binary` flag > `[default_binary]` > client default). Why load-bearing: when codex/opencode versions diverge again, the next agent will look here first.

- **`[pmodel]` config table**: The Model resolution priority bullet at line 334 references "role file `pmodel:` field" but never mentions that a project-wide `[pmodel]` table also exists in `.c2c/config.toml` and feeds the same resolution. This is the actual file most agents will need to edit. Add: *"`[pmodel]` in `.c2c/config.toml` provides per-role-type defaults; role files override per-instance."*

- **`c2c init` exists and is the new front-door**: `c2c --help` advertises `c2c init` as the bootstrap command ("New to c2c? Run `c2c init`…"). CLAUDE.md mentions `c2c init` only obliquely at line 49 ("`c2c init` / `c2c rooms join`") buried in the Group-Goal topology bullet. New agents joining the swarm need this surfaced — single line under Key Architecture Notes.

- **`c2c doctor docs-drift` subcommand**: discovered via `c2c doctor --help`. It explicitly audits CLAUDE.md for the exact drift this audit found by hand. CLAUDE.md mentions `c2c doctor` once at line 89 (push readiness) but never `c2c doctor docs-drift`, which is the self-checking tool. One bullet under Documentation hygiene.

- **`c2c doctor monitor-leak`**: dup-monitor checker (Phase C #288) is also undocumented in CLAUDE.md. High-value when the swarm hits dup-delivery again.

- **`c2c worktree check-bases`**: shows in `c2c worktree --help` as a peer of `gc`. CLAUDE.md line 95 covers `gc` and `prune` extensively but never mentions `check-bases`, which is the "are my branches stale against origin/master?" check — directly relevant to the rule at line 93 ("branch from `origin/master`").

- **`c2c agent` / `c2c roles` commands**: Tier 2 commands (visible in main help) for role-file management. Zero mention in CLAUDE.md. Probably out-of-scope for trim, but if someone goes hunting for "how do I add a new role" they hit nothing.

## Redundant / could-trim (low)

- **lines 346–347**: `# test` and `# test signing Fri 24 Apr 2026 15:34:01 AEST` — leftover scratch markers from the signing infra bringup. Delete (saves ~70 chars but removes confusion).

- **lines 102–137**: The `just install-all` block is excellent but says "prefer `just`" three times (lines 103, 119, 122) and "`dune install` does NOT reliably update the binary" once. Could compress ~150 chars without losing info.

- **lines 193–198 vs 199–206**: "Restart yourself after MCP broker updates" (full restart) and "SIGUSR1 recovers a stuck OpenCode MCP session" (soft restart) are two separate paragraphs that share the same setup ("the broker is spawned once at CLI start"). Could merge into one bullet with two sub-bullets, saving ~100 chars and making the choice more obvious.

- **lines 78–91 (push policy) and the surrounding doctor reference**: the "run `c2c doctor`" note at line 89 is buried inside a 14-line paragraph. Could be promoted to its own line so agents don't skim past it.

## Already-good (verified clean, do not touch)

- **lines 26–58 (Group Goal)** — verbatim north-star, intentionally stable across compactions, do not edit per #320 spirit.
- **line 93 (Git workflow five-rule summary)** — accurate and high-density; the runbook reference is real (`.collab/runbooks/git-workflow.md` exists).
- **line 95 (Worktree gc + #314 freshness heuristic)** — verified against `c2c worktree --help`; the `--active-window-hours=2` default and `--ignore-active` flag descriptions match the implementation.
- **line 97 (Coordinator failover)** — runbook exists at `.collab/runbooks/coordinator-failover.md`; alias succession is not stale enough to flag yet.
- **line 263–271 (Ephemeral DMs)** — runbook exists, summary is accurate.
- **line 296–313 (Per-agent memory)** — runbook exists at `.collab/runbooks/per-agent-memory.md`; #317 + #286 references match recent commit log.
- **line 318 (Broker root resolution order)** — fresh as of 2026-04-26 per the inline tag; no drift.
- **line 329 (deferrable=true means no push)** — long but accurate; #303/#307a/#307b cross-refs match recent commits.
- **line 333 (Tier filter is top-level only)** — confirmed by `c2c --help` output; subcommand grouping matches.
- **line 336–344 (Python Scripts deprecated)** — accurate framing; the runbook exists.

## Top-3 priority fixes for the next docs-drift slice

1. **Fix the env-var defaults** (lines 188, 328) — these are the kind of error that gets silently propagated when an agent tunes timing.
2. **Drop or rewrite the dead-script narratives** (lines 65–74, 234–248, 320, 322, 317) — agents lose tens of minutes chasing files that don't exist.
3. **Surface `c2c init`, `c2c doctor docs-drift`, `c2c doctor monitor-leak`, `c2c worktree check-bases`** — these are first-party tools that already do work the swarm is doing by hand.

---

Audit complete. Read-only — no mutations to `CLAUDE.md`. File totals roughly 28.9k chars; a careful pass on the items above should return ~1.4k of space without losing load-bearing content (and add ~0.6k for the corrections + missing info), net trim ~0.8k.
