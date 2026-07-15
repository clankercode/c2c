# Finding: `whoami` / send must not present a known-wrong or borrowed identity as truth

**UTC:** 2026-07-13T13:13:32Z  
**Reporter:** `grok-uranium-ring-5csk` (Grok; operator Max)  
**Severity:** High for swarm trust / authorship; Medium for single-client UX  
**Status:** open — design + fix needed  
**Related:** agy CLI-first support, sticky alias / session hijack, `c2c init` statefile fallback, B137 nested-theft, B172 codex thread map

## Symptom

When an agent (dogfood: interactive **agy**) ran `c2c whoami` without a clean client-bound session, c2c printed a **plausible, fully formatted identity** that was **not** that agent's identity — specifically a sticky **`codex-yew-spout-s4m7`** registration. The agent then `c2c send` stamped that **codex-** alias as the author of an “agy pong.”

Operators and models read the human whoami block as authoritative. Showing a wrong alias in the same layout as a correct one **looks like success**. That is worse than failing: it trains agents to act under someone else’s name.

Operator note (Max): when we show the “default profile / fallback” style resolution and the wrong alias, **we should never present something we know is wrong as if it were correct.** Prefer an **error with instructions** on how to fix or proceed. **All c2c errors should include how to fix / how to proceed.**

## Discovery

1. Grok peer injected a wake probe into a live agy conversation via `agy agentapi send-message` (wake worked).
2. agy ran `c2c whoami` after tool permission was granted.
3. Output presented alias `codex-yew-spout-s4m7` (and related relay framing) as if it were this shell’s identity.
4. agy replied on the broker **from** `codex-yew-spout-s4m7` with body claiming to be agy / agentapi pong.
5. Recipients (and monitors) saw a codex peer, not an `agy-*` peer — authorship lie, not a hard failure.

## Root cause (suspected / partial)

Identity resolution in CLI helpers prefers session-id lookup, then falls through to soft fallbacks that can adopt **another client’s** registration without hard failure:

- **`session_id_from_statefile`** (`c2c_cli_helpers.ml`): if the process has no session env, a broker statefile from `c2c init` can supply a **prior session** that is still registered — with only a one-line stderr *note* (`session resolved from … (c2c init fallback)`). Human `whoami` still prints that alias as primary truth.
- **`resolve_alias`**: if session id is missing or not registered, falls back to `C2C_MCP_AUTO_REGISTER_ALIAS` / env auto-alias, or even uses a bare sid as sender label rather than always failing closed for non-coordinator shells.
- **Codex-specific adoption paths** (B172 sole-alive app-server / thread maps): intended for codex tool shells; dangerous if a non-codex shell inherits enough env/cwd context to land in the same resolution path.
- **No client-prefix check**: nothing refuses “I am running as client X but resolved alias has prefix Y” (e.g. agy shell → `codex-*` alias).

Net: when confidence is low or provenance is “borrowed default,” we still **print success-shaped identity**.

## Desired behavior

1. **Never present known-wrong / low-confidence identity as success.**
   - If identity came only from init statefile fallback, sole-alive guess, foreign-prefix match, or auto-alias without a session registration for *this* process → **error (nonzero)** for interactive/human whoami and for send, not a normal “alias: …” success block.
2. **Errors must include proceed/fix instructions** (operator + agent pasteable). Examples:
   ```
   error: cannot determine a trustworthy identity for this shell
     resolved_candidate: codex-yew-spout-s4m7  (source: c2c init statefile fallback)
     problem: fallback is not bound to this process's session; client prefix mismatch if you intended agy

   How to fix:
     1. Register this session explicitly:
          c2c init --alias agy-<name>     # or: c2c register --alias agy-… --session-id <sid>
     2. Ensure client env is set for this harness (no borrowed session):
          # agy: unique C2C_MCP_SESSION_ID per conversation; do not inherit CODEX_*/CLAUDE_*
     3. Re-check:
          c2c whoami
     4. Only then send:
          c2c send <peer> "…"

   Advanced: inspect statefile under the broker root; remove stale fallback if it points at another client.
   ```
3. **Prefix / client mismatch:** if we can detect intended client (`agy` / `codex` / `claude` / `grok` via env, install markers, or explicit flag) and the resolved alias’s reserved prefix disagrees → hard error with rename/re-register instructions (ties to agy plan: always `agy-`).
4. **JSON mode:** same rules — empty alias or `"error"` object with `fix_steps[]`, never silent wrong alias.
5. **Broader product rule:** every user-visible error path in c2c CLI should ship **what failed + how to fix or how to proceed** (not just “error: …”). Audit siblings of whoami (send, register, rename, monitor self-id) for success-shaped wrong-state.

## Suggested fix sketch

| Area | Change |
|---|---|
| `session_id_from_statefile` | Treat as **untrusted** for whoami/send unless matched to an env session id *or* operator passes an explicit “use fallback” flag; otherwise error with fix steps |
| `c2c_whoami_cmd` | If alias is None, or provenance is fallback/ambiguous, exit 1 with instructions (already does for no session id; extend to wrong-confidence cases) |
| `resolve_alias` (send path) | Fail closed when would send under borrowed identity; do not stamp foreign alias |
| Client prefix guard | Optional `expected_prefix` / `client_type` on registration; refuse cross-prefix adoption |
| UX copy | Shared helper: `identity_error ~reason ~candidate ~steps` so all identity failures look the same |

## Workaround (today)

- Before send: require alias prefix to match intended client (`agy-*` for Antigravity).
- Do not run bare `c2c whoami`/`send` in a shell that has no client session env; run `c2c init --alias <correct-prefix-…>` first.
- Remove or ignore stale broker session statefile if it binds another client’s session.
- For agy deliver design: force fresh `C2C_MCP_SESSION_ID` + `agy-` mint at SessionStart (see agy support plan).

## Severity rationale

Wrong-but-pretty identity breaks swarm attribution, approval mental models (“codex said X”), and debugging. Silent success under a peer’s name is a **safety-adjacent** bug (bus-not-RPC still holds, but operators trust aliases for routing and blame).

## References

- Dogfood: agy conversation `6007fa72-0f2c-4500-a97a-525ea0c43a6e`; pong body claimed agentapi success while `from` was `codex-yew-spout-s4m7`.
- Code: `ocaml/cli/c2c_cli_helpers.ml` (`session_id_from_statefile`, `resolve_alias`); `ocaml/cli/c2c_whoami_cmd.ml`.
- Plan: `~/.gemini/antigravity-cli/brain/6007fa72-0f2c-4500-a97a-525ea0c43a6e/agy_support_plan.md` (agy- prefix + session isolation).
