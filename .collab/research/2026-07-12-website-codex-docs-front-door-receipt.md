# Receipt — front-door + llms pages: codex app-server interactive delivery framing

- Task: #9 website (front-door follow-up T005 deliberately left).
- Worktree: `.worktrees/website-codex-docs`, branch `slice/website-codex-docs`.
- Date: 2026-07-12 (UTC). Commit: `fc8ab48b`.
- Coordinator course-corrections applied mid-slice (via file inbox):
  1. B131 (live supervisor wiring) is being built in parallel → frame app-server
     interactive delivery as **landing now / being wired in**, not
     "follow-up slice / hooks-only today", and never as turnkey-shipped.
  2. **No legacy command option in the end state** (B131 removes the older
     command grammar) → present `c2c new codex` / `c2c start codex` as THE
     codex command: app-server-backed on supported Codex, hooks as the
     automatic fallback for older Codex. The removed option is absent from all
     eight changed files.

## One-line framing used everywhere

> Managed Codex sessions (`c2c new codex` / `c2c start codex`) run behind an
> authenticated loopback app-server with the stock remote TUI attached (hooks
> are the automatic fallback for older Codex). App-server interactive delivery
> — arrival-time model-visible injection that never touches a typed draft,
> plus one gated auto-turn for eligible local mail — is library-proven and
> landing now; until the live wiring is confirmed, sessions receive at the
> hook boundary.

No turnkey "codex auto-receives + auto-responds live" claim anywhere. No
composer-empty gating language. Alpha framing of the site unchanged.

## Pages changed

| file | change |
|---|---|
| `docs/index.md` | New "What's New" top bullet (codex app-server interactive delivery, landing now); Codex row of the client auto-delivery table updated (hook-boundary; app-server interactive delivery landing now). |
| `docs/overview.md` | Codex receive bullet: hook-boundary semantics made explicit (vanilla + managed alike); canonical launcher + app-server landing-now framing + `c2c doctor hooks` + link to `/client-delivery/#codex`. MCP-setup Codex section: one pointer sentence to the delivery transports. |
| `docs/get-started.md` | Only the "Codex delivery" note in Advanced § managed sessions (T005-authored) — updated per coordinator directives: removed legacy command-option wording, "follow-up slice" → "live supervisor wiring being wired in", added `c2c new codex`. Front-door/intro steps untouched. |
| `docs/llms.txt` | Codex receive bullet rewritten (stale "still being ported" claim removed — see Contradictions); Codex install-link descriptor updated. |
| `docs/llms-codex-install.txt` | Stale "still being ported" claim removed; Managed-sessions block extended with `c2c new codex` / `c2c resume codex ALIAS`; verbatim T006 passthrough examples (`c2c new codex -- --model gpt-5.3-codex-spark`, `alias cx='c2c new codex --'`) copied from `docs/commands.md`; new "Delivery" section (hooks today, app-server landing now, `c2c doctor hooks`). |
| `docs/MSG_IO_METHODS.md` | Drive-by: Codex row of the hooks client-support table carried the same stale "still being ported" claim — fixed with the same framing. Not a T005-owned page. |
| `llms.txt` (repo root) | Drive-by: same stale claim in the root copy of the llms file — fixed. |

Other `docs/llms-*-install.txt` files do not mention codex delivery — unchanged.

## Contradictions found (none in T005's pages)

- T005's pages (`docs/client-delivery.md`, `docs/clients/feature-matrix.md`,
  `docs/clients/e2e-checklist.md`, `docs/commands.md`, `docs/dnd-mode-spec.md`)
  were internally consistent — **not edited** by this slice.
- The stale claim "managed `c2c start codex` delivery is still being ported to
  that hook path" survived in four NON-T005 files (`docs/llms.txt`,
  `docs/llms-codex-install.txt`, root `llms.txt`, `docs/MSG_IO_METHODS.md`) and
  contradicted T005's client-delivery.md. All four fixed here.
- **Known residual skew (deliberate, for coordinator/B131 reconciliation):**
  T005's pages still say "wiring is a follow-up slice" and retain older command
  grammar; per coordinator instruction this slice matched the newer
  "landing now / removed legacy option" framing instead, and T005's pages are
  left for the B131 reconciliation pass.

## FLAGGED status-assertion sentences (for the post-B131 flip-to-shipped pass)

Grep key: `landing now` and `until` land on every one of these.

1. `docs/index.md` What's New bullet: "…the live supervisor wiring is being
   wired in now; until that is confirmed live, Codex sessions receive at the
   hook boundary." (+ the bullet title "(landing now)")
2. `docs/index.md` client table Codex cell: "app-server interactive delivery
   landing now".
3. `docs/overview.md` Codex receive bullet: "App-server interactive delivery
   is landing now — … with the live supervisor wiring being wired in; until
   that is confirmed live, Codex sessions receive at the hook boundary."
4. `docs/overview.md` MCP-setup Codex pointer: "(hooks as the vanilla/fallback
   path; app-server interactive delivery landing now)".
5. `docs/get-started.md` Codex delivery note: "Today delivery uses Codex
   hooks…" and "App-server interactive delivery is landing now: … with the
   live supervisor wiring being wired in (until it is confirmed live,
   sessions receive at the hook boundary)."
6. `docs/llms.txt` Codex bullet: "App-server interactive delivery is landing
   now — … until it is confirmed live, sessions receive at the hook boundary."
7. `docs/llms.txt` install-link descriptor: "(app-server interactive delivery
   landing now)".
8. `docs/llms-codex-install.txt` Delivery §: "All Codex sessions — vanilla and
   managed — receive messages through the installed hooks today." and
   "App-server interactive delivery is landing now. … until it is confirmed
   live, sessions receive at the hook boundary."
9. `llms.txt` (root) Codex bullet: "App-server interactive delivery is landing
   now: … until it is confirmed live, sessions receive at the hook boundary."
10. `docs/MSG_IO_METHODS.md` Codex row: "App-server interactive delivery
    (arrival-time, draft-safe) is landing now for managed sessions".

## Command-example provenance

- `c2c new codex -- --model gpt-5.3-codex-spark` and `alias cx='c2c new codex --'`
  copied verbatim from `docs/commands.md` § Codex session grammar (T006's
  live-tested examples).
- `c2c start codex` / `c2c new codex` / `c2c resume codex ALIAS` grammar rows
  match `docs/commands.md` § Managed instances.
- No invented flags; the removed legacy command option appears in none of the
  eight changed files.

## Verification (return codes)

| command | rc | notes |
|---|---|---|
| `just build` | 0 | run after doc edits; codegen no-ops, dune targets built |
| docs build (`cd docs && bundle exec jekyll build`) | n/a | jekyll not installable in this env (pre-existing toolchain gap, same as T005) — per `docs/CLAUDE.md`, text-only fallback used |
| fence/link lint (python, all 8 changed files) | 0 | fences balanced; no unclosed links; internal links well-formed; `/client-delivery/#codex` anchor exists (`## Codex` heading + permalink) |
| retired legacy-option search over all 8 changed files | 1 (clean) | no retired-option mentions remain |
| `just check` | not run in full | pre-existing sole failure is the Grok skill-codegen drift (per T005 receipt); this slice touched no skill files |
