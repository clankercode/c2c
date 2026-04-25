# Stats S4 Token/Cost Data Design

**Status:** draft for peer/coordinator review  
**Owner:** lyra-quill  
**Scope:** design only; no implementation in this slice

## Goal

Add token and cost columns to `c2c stats` without pretending every client can
report the same data today. The output should be useful for coordinator/Max
cost analysis while preserving data provenance and marking unknown values as
unknown, not zero.

## Current State

`c2c stats` already reports aliases, liveness, message counts, compaction count,
registration time, last activity, JSON output, and sitrep append. Slice 4 in
`DRAFT-agent-stats-command.md` is still open and explicitly calls for a
per-client investigation.

OpenCode has the most complete path:

- `data/opencode-plugin/c2c.ts` keeps `context_usage` in plugin state:
  `tokens_input`, `tokens_output`, `tokens_cache_read`, `cost_usd`,
  `completed_turns`.
- `message.updated` accumulates assistant turn usage from `info.tokens` and
  `info.cost`.
- `c2c oc-plugin stream-write-statefile` persists plugin state into
  `~/.local/share/c2c/instances/<name>/oc-plugin-state.json`.

Known caveat: `.collab/findings/2026-04-23T02-50-00Z-lyra-quill-statefile-token-counts-bug.md`
shows OpenCode `tokens_input` / `tokens_output` were not trustworthy in at
least one live run because `info.tokens` appeared empty. `tokens_cache_read` and
`completed_turns` did move, so usage fields need confidence metadata.

Claude and Codex do not currently have a normalized per-instance statefile usage
schema in this repo. `scripts/cc-quota` provides coarse Claude quota data, but
not reliable per-agent/per-session token totals.

## Proposed Data Model

Add optional token usage fields to `agent_stats`:

```ocaml
type usage_confidence = Unknown | Estimated | Reported

type token_usage =
  { tokens_input : int option
  ; tokens_output : int option
  ; tokens_cache_read : int option
  ; cost_usd : float option
  ; completed_turns : int option
  ; source : string option
  ; confidence : usage_confidence
  }
```

`None` means not available. Do not render missing fields as `0`, because that
would falsely imply a client consumed no tokens.

## Source Resolution

v1 should read only local statefiles:

1. Resolve instance state path:
   `~/.local/share/c2c/instances/<alias>/oc-plugin-state.json`.
2. Parse `state.context_usage`.
3. If at least one usage field is present, attach `source =
   "opencode-statefile"` and `confidence = Reported`.
4. If the statefile is missing or has no `context_usage`, attach
   `confidence = Unknown`.

Do not call external quota commands from `c2c stats` v1. They are slower,
client-specific, and may be machine-level rather than agent-level.

## Output

Markdown adds one compact column:

```markdown
| toks in/out | cost | usage source |
| 124k / 18k | $0.42 | opencode-statefile |
| n/a | n/a | unknown |
```

JSON adds structured fields:

```json
{
  "tokens_input": 124000,
  "tokens_output": 18000,
  "tokens_cache_read": 220000,
  "cost_usd": 0.42,
  "completed_turns": 17,
  "usage_source": "opencode-statefile",
  "usage_confidence": "reported"
}
```

For unknown values, JSON fields should be `null`, not omitted. This keeps
dashboard consumers stable.

## Implementation Slices

### S4a: read and expose statefile usage

- Add `read_usage_from_statefile ~alias`.
- Extend `agent_stats` with `token_usage`.
- Add markdown/JSON output fields.
- Tests: fixture statefile with full `context_usage`, missing statefile,
  malformed statefile, and partial usage.

### S4b: OpenCode event/schema hardening

- Update `docs/opencode-plugin-statefile-protocol.md` to include
  `context_usage` in the stable schema.
- Add TS unit tests for `message.updated` payload variants:
  `tokens.input/output`, `tokens.cache.read`, missing tokens, and cost.
- Decide whether missing `tokens.input/output` should downgrade confidence to
  `estimated` / `unknown` even if cache/cost moved.

### S4c: Claude/Codex follow-up

Add client-specific emitters only after we identify reliable per-session usage
sources. Until then, Claude/Codex show `n/a`.

## Acceptance Criteria for S4a

1. `c2c stats` markdown shows token/cost columns with `n/a` for missing data.
2. `c2c stats --json` includes stable nullable usage fields.
3. OpenCode statefile fixture populates token/cost fields.
4. Missing or malformed statefile does not fail stats.
5. No external quota command is executed.

## Risks

- OpenCode token fields may be incomplete in real events; use confidence/source
  fields and tests to avoid overstating accuracy.
- Alias-to-instance-name may diverge for some managed sessions. v1 should use
  alias path first and leave any broader instance registry mapping as a later
  slice.
- Machine-level quota data is tempting but would pollute per-agent stats; keep
  it out until it can be attributed.
