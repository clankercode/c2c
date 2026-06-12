# Plan Review — Feature B: Name Hardening (blocklist) + Nonce Suffix

**Reviewer:** minimax-coding-plan/MiniMax-M3
**Reviewed:** 2026-06-12
**Plan under review:** `.collab/design/2026-06-12-feat-name-nonce-plan.md` @ 0f1854d0
**Research context:** `.collab/research/2026-06-12-three-feature-investigations.md` §B
**Verdict:** **NEEDS-REWORK** (one critical UX bug + one architectural misdiagnosis)
**Scope:** READ-ONLY. No plan, code, build, or commit changes. Findings only.

---

## TL;DR

The plan is mostly well-anchored and follows Max's locked decisions correctly on the
auto-gen-only nonce boundary. However it has:

1. A **CRITICAL bug**: the blocklist rejects the very aliases that the auto-gen path
   produces, breaking `c2c setup <client>` for every supported client.
2. A **WRONG diagnosis**: the "module cycle" risk flagged in B1 does not actually exist
   in the current dep graph — the proposed mitigation is over-engineered.
3. Several **boundary / coverage** gaps that the reviewer's checklist will catch but
   the plan does not enumerate.
4. Minor **doc-inventory** mis-count (AGENTS.md is a symlink, not a duplicate).

The other slices (B3 output, B4 tests+docs) are sound; the rework is concentrated in B1+B2.

---

## 1. Evidence Check — Anchor Verification

All file:line anchors in the plan were cross-checked against the worktree HEAD
(`.worktrees/wt-feat-name-nonce` @ `0f1854d0` = plan commit, tree @ `8c2f5f51`).
Branch `feat/name-nonce` ✓.

| Plan anchor | Actual location | Status |
|---|---|---|
| `c2c_broker.ml:1681-1687` (reserved list + predicate) | `let reserved_system_aliases = ["c2c"; "c2c-system"]` at 1681; `is_reserved_system_alias` at 1683-1687 | ✓ confirmed |
| `c2c_broker.ml:1871` (`Broker.register` signature) | opens at 1871; `is_reserved_system_alias alias` guard at 1872 | ✓ confirmed |
| `c2c_broker.ml:1843` (`suggest_alias_prime`) | line 1843 confirmed | ✓ |
| `c2c_broker.ml:1886` (casefold-eviction `List.partition`) | line 1886 confirmed; compares `alias_casefold reg.alias = alias_casefold alias` | ✓ |
| `c2c_start.ml:1578` (`supported_clients`) | `let supported_clients = Stdlib.Hashtbl.fold ...` at 1578 | ✓ |
| `c2c_start.ml:2466/2477` (`generate_alias` / `default_name`) | confirmed; `:2467` is `Random.self_init ()` | ✓ |
| `c2c_setup.ml:186/199/246` | `generate_alias` / `generate_alias_easy` / `default_alias_for_client` all confirmed | ✓ |
| `c2c_name.ml:8` (`is_valid`) | confirmed; 1..64, `[A-Za-z0-9._-]`, no leading dot | ✓ |
| `c2c_mcp.ml:30-38` (register tool def) | confirmed (5 properties: `alias`, `session_id`, `role`, `tmux_location`) | ✓ |
| `c2c_identity_handlers.ml:45-50` (reserved + is_valid) | confirmed; line 45-50 emits `tool_err` for both checks | ✓ |
| `c2c.ml:2857` (register alias arg) | line 2855 is `let register_cmd`; 2857 is the alias opt — close enough but the "register" identifier is at 2855; the actual `Broker.register` call is at 2901 | minor off-by-2 |
| `c2c.ml:6682` (init alias arg) | `let alias_opt_arg` at 6681-6683 | ✓ |
| `c2c.ml:6779` (init auto-pick eprintf) | confirmed | ✓ |
| `c2c.ml:8977` (start alias arg) | confirmed | ✓ |
| `c2c.ml:9152` (start auto-pick eprintf) | confirmed | ✓ |
| `c2c.ml:2914` (register epilog) | confirmed; `Printf.printf "registered %s (session %s)\n"` | ✓ |
| `c2c.ml:6934` (init epilog) | confirmed; `Printf.printf "  alias:    %s\n" alias` | ✓ |
| `c2c.ml:9849` (`uuid_v4`) | confirmed; uses `hex_chars = "0123456789abcdef"` (good — same lowercase convention) | ✓ |
| `c2c_setup.ml:1527` (install auto-pick) | confirmed; inside `do_install_client`, prints `[c2c setup] no --alias given; auto-picked alias=%s` (note: the label says "c2c setup" — looks intentional, not install) | ✓ |
| `c2c_setup.ml:441, 526` (Codex, Kimi epilogs) | confirmed; both `Printf.printf "  alias:       %s\n" alias_val` | ✓ |
| `c2c_setup.ml:1785` (install alias arg) | confirmed; `[ "alias"; "a" ]` | ✓ |
| `test_c2c_mcp.ml:2171` (suggested_alias is prime-suffixed) | confirmed; expects `"storm-beacon-2"` | ✓ |
| `test_c2c_name.ml` (`is_valid` cases) | exists at `ocaml/test/test_c2c_name.ml`; 7 valid + 9 invalid cases; the plan B4 should mention this file is unaffected by nonce (explicit-arg) but the format check is already exercised there | confirmed |
| `test_c2c_start.ml:3754-3800` (default_name / generate_alias_378) | confirmed; `default_name` test asserts "no client prefix"; `generate_alias_378` asserts no same-word doubling | ✓ |
| Doc invariant: `CLAUDE.md:268` and `AGENTS.md:268` | **AGENTS.md is a symlink to CLAUDE.md** (in main tree, worktree, and `.worktrees/wt-feat-name-nonce/`); the line content is the "**Alias pool** is 128 words..." architecture note | ✓ confirmed but mis-counted (see §5) |
| Doc invariant: `docs/commands.md:994` | confirmed; the line "Aliases are short lowercase words (e.g., `storm-beacon`, `tide-runner`) drawn from the cartesian product of a 128-word pool..." | ✓ but the two "duplicated" lines say different things (see §5) |

### Additional anchors discovered that the plan does not mention

| Site | Why it matters |
|---|---|
| `ocaml/cli/c2c_agent.ml:458` (`eph-<role>-<suffix>`) and `:733` (`eph-refine-<name>-<suffix>`) | Both call `C2c_start.generate_alias ()` to build **instance names** for ephemeral agent sessions. Auto-gen function; will be uniformly nonced by the plan. Plan should enumerate these. |
| `ocaml/cli/c2c.ml:6763-6766` (init auto-pick selector) | `c2c init` chooses between `C2c_setup.generate_alias_easy` / `C2c_setup.default_alias_for_client` / `C2c_setup.generate_alias` based on `use_easy` and `client_resolved`. All three paths covered by the plan's "modify the generate_* functions" approach — no code change at this site required, but the plan should call out the dispatch. |
| `ocaml/c2c_broker.ml:1102` (c2c_broker references C2c_start.instances_dir in a comment) | Comment-only reference, no code dep. Confirms there's no current `c2c_broker → C2c_start` import — relevant to §2 below. |
| `ocaml/c2c_start.ml:1414` (c2c_start references c2c_broker.ml in a comment) | Comment-only. Confirms no current `c2c_start → c2c_broker` import. |
| `ocaml/c2c_broker.ml:2093, 3036, 3844` (other `is_reserved_system_alias` usages) | Plan only notes line 1872, but the same check fires at `enqueue_message` (2093), `send` (3036), and the `is_system_alias` in the message-render path (3844). Adding `is_banned_alias` is in the chokepoint (good), but the *other* `is_reserved_system_alias` callers may also want the blocklist once `C2c` ever evolves to a relay that validates from-side aliases pre-enqueue. **Out of scope for this plan** — flag for follow-up. |
| `ocaml/c2c_mcp_helpers_post_broker.ml:816-819` (`auto_register_alias` reads `C2C_MCP_AUTO_REGISTER_ALIAS`) | This is the env-supplied auto path the plan correctly identifies as bare. Note: the plan's B2 `no_nonce` MCP arg is **effectively dead** because the MCP register handler's "auto-gen" never produces a pool name — it reads the env var verbatim. See §6. |

### Seed-state note (slice B2)

- `c2c_start.ml:2467` calls `Random.self_init ()` at the start of every `generate_alias` call. (Idempotent; cheap; safe.)
- `c2c_setup.ml:186` `generate_alias` does **not** call `Random.self_init ()`; comment at 182-184 says the caller is responsible.
- I could not find a literal `setup_register` function in `c2c_setup.ml` — the comment at 184 references a function that doesn't exist (or has been renamed). I did **not** find a `Random.self_init` call anywhere in `c2c_setup.ml` either.
- Practical implication: when `c2c setup` / `c2c install` runs in a fresh OCaml runtime that hasn't been seeded, the nonce will be deterministic. The plan should mandate `Random.self_init ()` in the new nonce function (or at minimum, an idempotent `Random.self_init ()` at the top of `c2c_setup.ml`'s `generate_alias`, since it's already re-seeded on every call in `c2c_start.ml`).

---

## 2. Module-Cycle Risk — **DIAGNOSIS IS WRONG**

The plan (B1) warns:
> ⚠️ Dependency note: `c2c_broker.ml` referencing `C2c_start` may create a module cycle.
> VERIFY build order; if cyclic, hoist the supported-clients list into a low-level
> module (e.g. `c2c_name.ml` or a new `c2c_blocklist.ml`) that both depend on. Resolve
> cleanly — do not introduce a cycle.

### Evidence

Code-level references (not comments):

```
$ rg "C2c_broker\." ocaml/c2c_start.ml           # → 0 matches
$ rg "C2c_start\." ocaml/c2c_broker.ml           # → 0 matches
$ rg "C2c_name\."   ocaml/c2c_broker.ml          # → 0 matches
```

Both `C2c_broker` and `C2c_start` are in the **same** OCaml library `c2c_mcp`
(`ocaml/dune:29-32`, `(wrapped false)`, single compilation unit). The `(modules ...)`
listing includes both `C2c_name`, `C2c_broker`, and `C2c_start` in that textual
order, but order in `(modules ...)` only matters for `-open` / first-module-init
semantics, not for forward references. OCaml allows forward references between
modules in a single library.

### What this means

- **Adding `C2c_start.supported_clients` (or any subset) to `c2c_broker.ml` would
  create a one-way dep: `c2c_broker → C2c_start`.** That is **not a cycle**. It is
  well-formed: `C2c_start` is unaware of `C2c_broker`, and there is no second
  reverse arrow.
- The "hoist into `c2c_name.ml` or a new `c2c_blocklist.ml`" mitigation is
  **over-engineered**. It is a fine architectural choice on independence grounds
  (decoupling `c2c_broker` from CLI machinery), but it is not required for
  build correctness.

### Recommendation

- **If the slice author prefers the independence story** (broker module should not
  import CLI machinery), go ahead and hoist. `c2c_name.ml` is the wrong home
  (it's a format validator, not a policy table); a new `c2c_blocklist.ml` or
  extending `c2c_name.ml` with a `banned_aliases` set is the right shape.
- **If the slice author wants minimal churn**, just `open C2c_start` (or
  `let blocked = C2c_start.supported_clients @ ["gpt"; "assistant"; "gemini";
  "crush"]`) in `c2c_broker.ml`. The dep is one-way and safe.
- Either way, **the AC "no module cycle introduced" should be checked with
  `dune build` inside the worktree** (the plan's final step), not by predicting
  in advance. A `ocamldep` graph dump is the right verification tool, not prose.

### Side note: real existing dep `c2c_setup → C2c_start`

`c2c_setup.ml:251` calls `C2c_start.generate_alias ()`. So `c2c_setup` already
depends on `C2c_start`. This is fine and unrelated — just noting that `C2c_start`
is already a "mid-level" module (consumed by setup, would-be-consumed by broker).
The plan should treat it as such.

---

## 3. Auto-Gen-Only Boundary — **CRITICAL BUG IN THE PLAN**

This is the most important finding. The plan's blocklist + auto-gen combination
produces a contradiction that breaks the most common `c2c setup` invocation.

### The contradiction

1. **Blocklist contents** (per Max's locked decisions + research):
   `["gpt"; "assistant"; "gemini"; "crush"]` plus
   `C2c_start.supported_clients` = `["claude"; "codex"; "opencode"; "kimi"; "tmux"; ...]`
   (the Hashtbl-derived list).
2. **Blocklist match** (per Max's locked decisions + research):
   "casefolded full-equality OR first-hyphen-segment equality" — i.e. reject if
   `first_segment(alias) ∈ blocked`.
3. **Auto-gen function** `default_alias_for_client` at
   `c2c_setup.ml:246-252`:
   ```
   let default_alias_for_client client =
     let client = ... lowercase_ascii ... in
     let suffix = C2c_start.generate_alias () in
     Printf.sprintf "%s-%s" client suffix
   ```
   Produces: `codex-ember-frost`, `claude-river-stone`, `kimi-cedar-pine`, …
4. **Auto-gen function** `generate_alias` (c2c_start.ml:2466, c2c_setup.ml:186)
   produces bare two-word names. **First segment is a random word** — could be
   anything in the 128-word pool, but the probability of hitting a banned
   prefix is **5/128 ≈ 4%** per call (and 16,384 pair combinations → ~660
   banned first-segment names out of 16,384 = 4%).

### What breaks

- **`c2c setup codex` (no `--alias`)** → auto-picks `codex-ember-frost` →
  first segment `codex` ∈ blocklist → **rejected at `Broker.register:1872`** →
  user sees "register rejected: 'codex-ember-frost' starts with banned 'codex'".
  **Every invocation fails.**
- Same for `c2c setup claude`, `c2c setup opencode`, `c2c setup kimi`,
  `c2c setup gemini` (if added). Every one breaks.
- For **bare two-word auto-gen** (`generate_alias`), 4% of generated names will
  have a banned first segment. With 16,384 pairs and a 128-word pool, ~660 names
  hit the blocklist. That's a 4% rejection rate on `c2c init` (no `--client`).
  For `c2c init --client codex` (uses `default_alias_for_client`), it's 100%.

This is a **fatal UX bug** in the current plan. The user-facing impact is:
"the auto-name we just generated for you is illegal; try again" — for the
default `c2c setup <client>` flow.

### Required rework (pick one)

**(a) Auto-gen exemption**: skip the blocklist check when the alias was just
produced by one of the auto-gen functions. Implementation: thread a
`?from_auto_gen:bool` (or a `?origin:[`Explicit | `AutoGen]`) through
`Broker.register`, default `Explicit`, and set `AutoGen` at every call site
that follows a generate_* call. **Recommended — preserves the "block
`claude` explicit" guarantee.**

**(b) Strip the client prefix** from `default_alias_for_client` so it returns
just `generate_alias ()` (e.g. `ember-frost-nonce` instead of
`codex-ember-frost-nonce`). Loses the "this was a codex instance" affordance
in the alias. **Not recommended** — that prefix is operational signal.

**(c) Blocklist exemption for `<client>-<word>-<word>` pattern**: in the
blocklist predicate, allow names whose first segment is in `supported_clients`
AND that have at least 2 hyphen-separated segments. This blocks `claude`
explicit but allows `claude-ember-frost`. **Hacky** — bakes client-name
knowledge into the blocklist predicate.

**(d) Move `default_alias_for_client` to use a different prefix** that is
**not** in the blocklist — e.g. use `c-<client>-<word>-<word>` (with `c-` as
a marker) or the client name's first letter: `c-ember-frost`. Then first
segment is `c` (not blocked). Slightly awkward; preserves the "codex"-style
information but in a different position.

The plan's decision matrix should pick one. I recommend **(a)** as the
cleanest, but it requires touching all the call sites that pass an auto-gen
alias — so the plan's B2 call-site list needs to be expanded to:

- `c2c_setup.ml:1525-1528` (install auto-pick)
- `c2c.ml:6763-6766` (init's three-way auto-pick)
- `c2c.ml:9151-9152` (start's default_name, used as instance name)
- `c2c_agent.ml:458, 733` (ephemeral agent / refine)
- Anywhere else a `C2c_start.generate_alias ()` or `C2c_setup.generate_alias`
  return value reaches `Broker.register`

… and threading the `?from_auto_gen` (or equivalent) flag through to the
chokepoint.

### Why the plan missed this

The plan's design reasoning is sound for the **nonce** boundary: "nonce goes
inside generate_alias, so any caller of generate_alias gets a nonced name".
The plan's design for the **blocklist** is also individually sound: "block
`claude`, `codex`, etc. so users don't squat on client names". But the two
designs interact: when the auto-gen path itself produces names whose first
segment is a blocked name, the auto-gen breaks. This is a **cross-feature
interaction** the plan doesn't analyze.

### Related: role `c2c.alias` and env-supplied names

The plan correctly keeps these BARE. The chokepoint check at `Broker.register`
will still see them. So:

- A role pinned `c2c.alias: claude` would be rejected by the blocklist
  (first segment `claude` ∈ blocked). This is a **desired behavior** — a
  role template trying to claim a blocked alias should fail loudly.
- A role pinned `c2c.alias: lyra-quill` → first segment `lyra` → not blocked
  → fine.

This is correct; no change needed.

### Tests for this bug

The plan B4 lists:
> (a) blocklist rejects `claude`/`claude-code`/`gpt`, accepts `lyra-quill`

Add to B4:
- **(g) auto-gen name with client prefix is NOT rejected** (e.g. `codex-ember-frost` is allowed when produced by auto-gen, rejected when explicit).
- **(h) bare auto-gen name with non-client prefix matches is not rejected** (e.g. `river-stone` is fine; `claude-river` is fine; `codex-ember` is fine under (a) above).

---

## 4. Collision / Casefold — **SOUND** (minor edge cases noted)

The stacking design `word-word-a7c2-2` is internally consistent with the
existing casefold-eviction logic:

- `alias_casefold` is `String.lowercase_ascii` (broker.ml:352).
- Stored alias is preserved as-given (broker uses the string passed to
  `register`).
- `suggest_alias_prime` builds `%s-%d` over the casefolded base (line 1857);
  the new base is `word-word-a7c2`. So the prime-suffixed value is
  `word-word-a7c2-2`.
- The eviction predicate at broker.ml:1886 compares `alias_casefold reg.alias =
  alias_casefold alias` — comparing full strings — so a colliding
  `Word-Word-A7C2-3` would be correctly evicted by a registration of
  `word-word-a7c2-2`.

### Edge cases (all benign, worth a test)

- **Nonce collides with prime value**: the nonce charset is `0-9a-z` and
  primes are integers `2,3,5,7,11,13,...`. No collision (digits + letters
  vs pure integer).
- **Nonce-collision** (two auto-gens producing the same nonce): probability
  ~1/1.68M per pair. If it happens, `suggest_alias_prime` falls back to
  `-2` (or `-3` etc), which is casefold-distinct from the nonced base.
  Correct.
- **Explicit alias already includes `-2`**: e.g. user passes
  `--alias foo-bar-2`. The blocklist won't catch it (first segment `foo`).
  The auto-suggest (if collision) would yield `foo-bar-2-2`. Slightly
  weird but not a bug.
- **Casefold-eviction on stacked names**: `word-word-a7c2-2` and
  `Word-Word-A7C2-2` would both casefold-equal the same string; the
  eviction at line 1886 catches the latter if the former is already
  registered. Correct.

### Verdict

Section's correct. Just add a test:

- **(i) explicit `storm-beacon-2` (already prime-suffixed) doesn't trigger
  blocklist on first-segment** — the test_c2c_mcp.ml:2171 case naturally
  covers this. Plan should explicitly say "this test stays unchanged".

---

## 5. Test / Doc Full-Scan Adequacy

### Tests

Plan B4 lists 6 test additions (a-f). With the rework from §3, the list
should be expanded to (a-i) as noted above. Additional things to verify:

- **`test_c2c_name.ml`** (already exists) — unaffected by nonce (format
  check), but the plan should note that **blocklist doesn't subsume format
  check** (a 64-char `xxx...-claude` could be banned, and that's the
  blocklist's job; a `foo bar` is the format check's job). Add a test
  showing the two are orthogonal.
- **`test_c2c_mcp.ml`** — most register tests use explicit aliases
  (`"storm-ember"`, `"idle"`, `"session-bob"`, etc.). None currently
  exercise auto-gen through `Broker.register`. The new blocklist tests
  (a) and (g) should go here.
- **`test_c2c_identity_handlers.ml`** — exists; the plan should confirm
  the file imports `C2c_mcp_helpers` / `C2c_broker` and can drive the
  register handler with `tool_err` expectations.
- **`test_c2c_start.ml`** — already has `default_name_drops_client_prefix`
  and `generate_alias_378`. The plan should add an assertion that
  `default_name` output now ends with `-<4 lowercase alphanumerics>` (the
  nonce). And `generate_alias` output also gets the nonce suffix. Both
  via regex / shape match.
- **`test_c2c_setup*.ml`** — none of the auto-pick tests currently
  exist. The plan should add a test for `c2c setup` / `c2c install`
  auto-pick that asserts the produced alias shape (`<client>-<word>-
  <word>-<nonce>`).
- **No `blocklist` test file exists** — the plan creates a new module
  (`c2c_blocklist.ml` or wherever) but the plan should also create a
  `test_c2c_blocklist.ml` or fold into `test_c2c_name.ml`.

### Doc invariant: the "3 duplicated" claim is misleading

Plan says:
> the 3 duplicated invariant docs (`CLAUDE.md:268` == `AGENTS.md:268` ==
> `docs/commands.md:994`)

Reality:

- `CLAUDE.md:268` and `AGENTS.md:268` are **the same line** because
  `AGENTS.md → CLAUDE.md` is a symlink in the worktree (and in the main
  tree). Updating CLAUDE.md updates AGENTS.md for free.
- `docs/commands.md:994` is a **different line** — it's user-facing
  ("Aliases are short lowercase words (e.g., `storm-beacon`, `tide-runner`)
  drawn from the cartesian product of a 128-word pool hardcoded in
  `c2c_start.ml` and `c2c_setup.ml`..."). It does NOT mention blocklist,
  nonce, or any current state of the format.
- So there are **2 distinct places to update** (CLAUDE.md, docs/commands.md)
  with **different content** (architecture note vs user-facing
  format/format-rules doc), not 3 duplicates.

The plan should:
- Update **CLAUDE.md:268-269** (the alias-pool line) to mention the
  blocklist + nonce policy. Single source of truth.
- Update **docs/commands.md:994** (the alias-format paragraph) to:
  - Mention the blocklist (with the list of banned names).
  - Mention the nonce suffix for auto-generated names.
  - Show an example with the nonce (`ember-frost-a7c2`).
- **No separate `AGENTS.md` edit** — symlink.

The plan B4 doc-sweep should also check:
- `c2c-cli` `c2c help register` and `c2c help init` and `c2c help start`
  inline help strings (Cmdliner `~doc:"..."` fields at
  `c2c.ml:2857, 6683, 8978` and `c2c_setup.ml:1785`).
- Role template `c2c.alias:` documentation if any (none in the docs I
  scanned — pure TOML field).
- The `c2c_mcp.ml:30-38` tool description for `register` (the
  user-facing MCP tool doc) should mention the blocklist (MCP clients
  reading tool defs are the primary way to learn this).

### Verdict

Section is incomplete on tests and mis-counts on docs. Fixable with a
small expansion of B4.

---

## 6. Other Findings

### 6.1 `no_nonce` MCP arg is **dead code** as designed

Plan B2: "Add a `no_nonce` bool to the MCP `register` schema... honored
only when the handler auto-generates."

Looking at `c2c_identity_handlers.ml:14-23`:
```
let alias =
  match explicit_alias with
  | Some a -> a
  | None ->
      (match auto_register_alias () with  (* reads C2C_MCP_AUTO_REGISTER_ALIAS *)
       | Some a -> a
       | None -> invalid_arg "alias is required (pass {\"alias\":\"your-name\"} or set C2C_MCP_AUTO_REGISTER_ALIAS)")
```

The MCP register handler **never calls a pool generator**. Its "auto-gen"
path is just "read the env var". Per Max's locked decisions, env-supplied
names stay BARE. So `no_nonce` would never be true for the auto-gen branch
(there's no nonce to skip), and the explicit branch ignores `no_nonce` by
design.

Unless the plan intends to add **a new MCP pool-generator path**
(env-unset, no explicit alias → fall through to a pool gen inside the
handler), the `no_nonce` MCP arg is **dead**.

Three options:
- (i) **Drop the `no_nonce` MCP arg** — keep parity only at the CLI.
- (ii) **Add the pool-gen path** to the MCP handler — makes the MCP
  register's no-args form auto-pick a name the same way `c2c init` does.
  This is a behavior change, not just plumbing. It also re-opens the
  blocklist-auto-gen interaction from §3.
- (iii) **Keep `no_nonce` MCP arg but document it as future-use** —
  schema-only, no behavior. Confusing for MCP clients reading the schema.

Recommend (i) unless Max specifically wants (ii).

### 6.2 `--no-nonce` plumbing list

Plan B2: `c2c.ml:2857` for `register_cmd`. The actual `register_cmd` is at
`c2c.ml:2855`, and the `Broker.register` call is at `c2c.ml:2901`. Adding
`--no-nonce` to the `register_cmd` is fine (it just means "if I'm about to
auto-pick, don't add a nonce"). But for `register_cmd`, auto-pick is rare
(it's the explicit-register path; the user is more likely to use `c2c init`
or `c2c start` for auto-pick). So the flag is mostly cosmetic for register.

The high-value sites are:
- `c2c.ml:6682` (init) — auto-pick path. Add `--no-nonce` here.
- `c2c.ml:8977` (start) — auto-pick path (via `default_name` for instance
  name AND alias). Add `--no-nonce` here.
- `c2c_setup.ml:1785` (install) — auto-pick path. Add `--no-nonce` here.

Plan already enumerates these. Good. Just note the priority: `init` and
`start` are the user-visible auto-pick sites; `install` less so (operators
typically pass `--alias` explicitly).

### 6.3 Role `c2c.alias` flow check

`ocaml/cli/c2c.ml:9210` and `:9292` show:
```
let effective_alias = Option.value role.C2c_role.c2c_alias ~default:agent_name in
```

So when a role template has `c2c.alias:` set, the role value is used
directly as the alias. **No nonce application** — the role value reaches
`Broker.register` (or whatever the launch path uses) unmodified. ✓
This is the correct "role-pinned = bare" behavior Max specified.

If the role pins `c2c.alias: claude`, then the blocklist will reject. The
plan should add a test for this rejection (with a clear role template
fixture).

### 6.4 First-segment blocklist edge case: a 3-segment `claude-foo-bar`

The plan's "first-hyphen-segment" rule would block `claude-foo-bar` (first
segment `claude`) but allow `lyra-claude-foo` (first segment `lyra`). This
is the right behavior. Just confirm in a test.

### 6.5 Suggested nonce source module location

If the slice author goes with the over-engineered hoist (per §2 above), the
right home is **a new `c2c_blocklist.ml`**, not `c2c_name.ml`. Reasons:
- `c2c_name.ml` is a format validator (1..64, charset). Adding a banned-list
  conflates "what's syntactically valid" with "what's semantically banned" —
  two different policies.
- `c2c_blocklist.ml` cleanly owns the banned-name policy, the casefold
  predicate, and (optionally) the static list. `c2c_broker.ml` depends on
  it; nothing else needs to.

If the slice author skips the hoist and just `open C2c_start` in
`c2c_broker.ml`, no new module is needed.

### 6.6 B3 output-site completeness

Plan B3 enumerates: `c2c.ml:6779, 9152, 2914, 6934`, `c2c_setup.ml:441, 526, 1527`.
All these print the alias verbatim after the auto-gen function returns, so
they automatically print the post-nonce value once the nonce is applied
inside the gen function. **B3 is essentially "verify no edits needed"** —
should be re-stated in the plan as such to avoid wasted reviewer time
expecting diff hunks.

### 6.7 The `--no-nonce` flag is in the wrong direction

Max's locked decision says `--no-nonce` is the opt-out. The plan honors
this. But pragmatically, since nonce is **auto-gen-only** and the
explicit/role/env names are **always bare**, the flag's only effect is on
the `c2c init` / `c2c start` / `c2c install` commands when no explicit
`--alias` is passed. That's a small surface.

The plan should call out: "this flag is for users who hate the nonce and
want `c2c init` to produce a clean `ember-frost` instead of
`ember-frost-a7c2`". Most users will never touch it. Useful for
aesthetic-leaning operators.

---

## 7. Verdict

**NEEDS-REWORK** before peer-PASS.

### Top 3-6 concrete improvements

1. **(CRITICAL) Fix the blocklist-vs-auto-gen contradiction** — pick one of
   the four options in §3. I recommend (a) "auto-gen exemption": thread
   `?from_auto_gen:bool` through `Broker.register` (and CLI/MCP call sites
   that follow a generate_* call) and skip the blocklist check when true.
   This requires:
   - `c2c_broker.ml:1871` signature change (add `?from_auto_gen`)
   - `c2c_broker.ml:1872` blocklist branch guarded by `not from_auto_gen`
   - CLI: thread the flag at `c2c.ml:2901` (register), `c2c.ml:6763-6779`
     (init auto-pick), `c2c.ml:9151` (start default_name)
   - Setup: `c2c_setup.ml:1525-1528` (install auto-pick)
   - Tests: B4 (g) and (h) from §3 above.
2. **(HIGH) Drop the false "module cycle" warning** — §2. Either skip the
   hoist entirely (just `open C2c_start` in `c2c_broker.ml` if you want
   `supported_clients`) or, if you prefer the architectural decoupling,
   create a new `c2c_blocklist.ml` (NOT `c2c_name.ml`) and depend on it
   from `c2c_broker.ml`. The dep is one-way; no cycle.
3. **(MEDIUM) Drop the `no_nonce` MCP arg** — §6.1. It's dead code given
   the current MCP register handler design (which never pool-generates).
   Keep `--no-nonce` at the CLI for `init` / `start` / `install` only.
   If Max wants pool-gen in the MCP register handler, that's a separate
   slice with its own blocklist-vs-auto-gen analysis.
4. **(MEDIUM) Doc sweep: 2 places, not 3** — §5. Update `CLAUDE.md:268-269`
   (alias-pool line) and `docs/commands.md:994` (alias-format paragraph).
   AGENTS.md is a symlink. The two updates have different content.
5. **(LOW) Test expansion** — §3, §5. Add tests (g)/(h) for the auto-gen
   exemption, (i) for the casefold-stacking confirmation, and a new
   `test_c2c_blocklist.ml` (or fold into `test_c2c_name.ml`).
6. **(LOW) Random.seed audit** — §1. The new nonce function should
   `Random.self_init ()` defensively (mirroring `c2c_start.ml:2467`).
   The plan's existing verify-the-install-path note is correct — but the
   install path doesn't currently seed. Adding the seed inside the nonce
   function is the cleanest fix.

### What's already sound

- Auto-gen-only nonce boundary (the core risk-reduction decision) is
  correctly designed and correctly bounded by the "apply inside
  generate_*" rule.
- Casefold + nonce + prime stacking is internally consistent.
- B3 output sites are already correct (alias printed verbatim from
  generated value).
- B4 test list captures the right shape; just needs expansion.
- Random-seed discipline in `c2c_start.ml:generate_alias` is the right
  precedent for the new nonce function.

### What's a clean rebase after fixes 1-2

Once the auto-gen exemption is in place and the cycle warning is dropped,
the plan becomes a straightforward 4-slice sequence (B1 + B2' + B3 + B4)
with the worktree build + peer-PASS loop as the final gate. Estimated
delta: ~80 lines of OCaml (blocklist module + auto-gen flag + nonce fn),
~150 lines of tests, ~30 lines of doc updates. Modest slice.

---

**Reviewer signature:** MiniMax-M3 · 2026-06-12
**Worktree:** `.worktrees/wt-feat-name-nonce` @ `0f1854d0` (plan-only commit)
**No files modified. No commits made. No build run.**
