# Review: Connect Docs + Experience Improvement Design

**Reviewer:** Codex
**Date:** 2026-06-12
**Plan under review:** `.collab/design/2026-06-12-connect-experience-improvements.md`
**Scope:** Plan/design review only. No implementation performed. Plan doc not edited.

## Overall Verdict

**SOUND-WITH-FIXES.**

The plan identifies the right core problem: the public connect/onboarding path is fragmented, Gemini/Crush truth has drifted, and there is no obvious newcomer-facing command that answers "did my c2c setup actually work?" The proposed Phase 1 and Phase 2 doc work is well justified, and a Phase 3 connect verifier is buildable if scoped carefully.

The fixes needed before execution are mostly precision and sequencing, not a rewrite:

1. **Correct the `relay.json` backlog claim.** Current OCaml already loads saved relay config for `relay connect`, `relay status`, and `relay list`; the plan's "relay.json ignored" claim is wrong as stated.
2. **Tighten Phase 3's loopback-verifier contract.** The CLI can observe broker enqueue plus an auto-delivery consumer drain/stage event in many paths; it cannot universally prove transcript injection. Existing `doctor delivery-mode` measures sender intent, not actual delivery path.
3. **Reframe a few docs evidence claims from "missing everywhere" to "missing from the newcomer path."** Local self-send/e2e checks exist in specialist docs, just not where a new user lands.
4. **Move or narrow the recommended cut.** Phase 1 + the `/get-started/` path fork is a clean first push. Adding the full Phase 3 loopback verifier in the same push is likely too large unless its v1 semantics are explicitly reduced.
5. **Add `docs/commands.md` and link/redirect safety to Phase 1/2 acceptance criteria.** It duplicates relay/client command surfaces and will otherwise keep drifting.

## Evidence Check

### Claims that checked out

- **Gemini inconsistency is real.** `docs/index.md:52` says five clients including Gemini, while `docs/index.md:53` says "Four-client parity." The same contradiction appears in `docs/get-started.md:15` vs `docs/get-started.md:18`. `docs/clients/feature-matrix.md:19` has only Claude/OpenCode/Codex/Kimi columns, and `docs/overview.md:11` / `docs/overview.md:22` omit Gemini from the intro/diagram. Nuance: Gemini is present in `docs/client-delivery.md:334` and `docs/client-delivery.md:451`, so this is inconsistency, not total absence.
- **Homepage hero stat is wrong.** `docs/_layouts/home.html:24` hardcodes `4 clients + Crush exp`; `docs/index.md:6` hero lead also lists only Claude/Codex/OpenCode/Kimi.
- **`layout: docs` is unsupported by local layouts.** `docs/clients/feature-matrix.md:4` and `docs/clients/e2e-checklist.md:4` use it. The repo's `docs/_layouts/` contains only `home.html`; the site uses `minima` (`docs/_config.yml:6`), so the precise action should be "verify and replace with a valid layout," not merely infer the build warning.
- **`/get-started/` is not a quickstart.** H1 is "Next Steps" (`docs/get-started.md:8`), followed by "What's Shipped Recently" (`docs/get-started.md:10`) and "Spawning Child Sessions" internals (`docs/get-started.md:26`). It is in top nav (`docs/_config.yml:21`) and the homepage calls it the "full changelog" (`docs/index.md:55`).
- **`smoke-test` cannot validate the real install.** It creates a temp broker (`ocaml/cli/c2c.ml:6588-6595`), registers two smoke sessions, and drains that temporary inbox (`ocaml/cli/c2c.ml:6602-6611`).
- **`install all` omits the restart footer.** The scriptable `install all` path prints only `Done.` (`ocaml/cli/c2c_setup.ml:1852-1877`), while the interactive installer has the restart guidance (`ocaml/cli/c2c_setup.ml:1763-1764`).
- **`init` no-client hint is stale.** It hardcodes `opencode`, `claude`, `codex`, `codex-headless` (`ocaml/cli/c2c.ml:6739-6743`) while the init-configurable list includes Kimi and Gemini (`ocaml/cli/c2c_setup.ml:1469-1470`).
- **`init` swallows identity-init failures.** It runs `c2c relay identity init 2>/dev/null` and ignores the rc (`ocaml/cli/c2c.ml:6782-6784`).

### Claims that need correction or narrower wording

- **Wrong: "`relay.json` written by setup but ignored by status/connect/list."** Current code resolves saved relay config via `relay_config_path`, `load_relay_config`, `resolve_relay_url`, and `resolve_relay_token` (`ocaml/cli/c2c.ml:4276-4327`). `relay connect` uses `resolve_relay_url relay_url` (`ocaml/cli/c2c.ml:4388`), `relay status` uses it (`ocaml/cli/c2c.ml:4492-4497`), and `relay list` uses it (`ocaml/cli/c2c.ml:4518-4523`). This backlog item should be removed or replaced with a specific still-open relay-config bug if one exists elsewhere.
- **Overstated: "only round-trip verification on the whole site is relay."** Correct for the newcomer/local onboarding path, but not for the whole site. `docs/clients/feature-matrix.md:159-164` includes a self-send smoke test, and `docs/clients/e2e-checklist.md:64-76` covers local auto-delivery. The plan should say "no local self-test in the quickstart/front-door path."
- **Overbroad: "purge stale `.py` references."** The cited `.py` references exist, but some are explicitly historical/deprecated context (`docs/overview.md:85`, `docs/client-delivery.md:294-301`). Phase 1 should audit them against docs hygiene, then remove or quarantine public-facing obsolete references rather than blindly deleting every `.py` mention.
- **Partly overstated: "`c2c health` checks per-client plugin installs."** `c2c health` is indeed the broad diagnostic for broker, registry/liveness, relay, stale daemons, and plugin checks (`ocaml/cli/c2c.ml:2158-2244`), but `check_plugin_installs` currently covers Claude, OpenCode, and GUI only (`ocaml/cli/c2c.ml:2008-2058`). It does not yet verify Codex/Kimi/Gemini install parity.

## Phase 3 Feasibility

`c2c doctor connect` is buildable, but only with a precise v1 contract.

The broker has the right primitives to enqueue a unique non-ephemeral self marker and watch for its fate. Archive entries persist `drained_by` (`ocaml/c2c_broker.ml:2312-2324`, `ocaml/c2c_broker.ml:2341-2358`), and push-path drains use distinct labels such as `deliver-watch`, `xml`, `oc_plugin`, `hook`, or `poll_inbox` depending on path. That can support a useful status like:

```text
PASS: marker was consumed by auto-delivery path <drained_by>
INCONCLUSIVE: marker remains queued; restart or client activity may be needed
FAIL: broker/registration/config path broken
NOT PROVEN: transcript visibility is client-specific and was not confirmed
```

The current `doctor delivery-mode` is not enough for this. It counts `deferrable` sender intent and explicitly says it is not delivery actuals (`ocaml/c2c_broker.ml:2477-2484`, `ocaml/cli/c2c.ml:8501-8504`). The plan should name `drained_by` / archive matching, or add marker/message-id logging, as the intended mechanism.

There are client-specific caveats:

- **Claude:** a command that waits inside the current tool invocation may not see the PostToolUse hook fire until after the command exits. The v1 UX may need "send marker now, run this command again after one tool turn" or a separate nonblocking probe mode.
- **Codex XML:** the XML loop drains before writing to the FD (`ocaml/c2c_pty_inject.ml:172-194`); archive drain proves consumption, not client acceptance.
- **Kimi:** notification-store delivery may stage messages via Kimi-specific files/acks rather than the normal archive path; the verifier needs either a Kimi-specific branch or an explicit "not fully observable" result.
- **Ephemeral messages:** cannot be used for the probe because ephemeral drains are intentionally not archived (`ocaml/c2c_broker.ml:2273-2276`).

So Phase 3 is feasible as "broker + auto-consumer drain/staging verification." It is not feasible as universal "the client transcript contains the message" without new per-client acknowledgements or tmux transcript inspection.

## Completeness / Gaps

- **Cross-machine relay onboarding deferral is defensible only if Phase 2's path fork is very explicit.** A user who wants to reach a specific person must be sent to `/connect/` / relay registration immediately. Do not let `/get-started/` imply that local `c2c init` joins them to another machine.
- **Install-consistency P1-P8 deferral is defensible for this cut.** It is broader than connect docs and would balloon the slice. However, Phase 3 depends on knowing whether installs are configured enough to support a verifier, so add a small acceptance criterion: `doctor connect` reports "unsupported/unverified client install check" rather than pretending all clients are equally checked.
- **`relay.json` is not a core-cut blocker because the cited bug is stale/wrong.** Remove it from the plan's backlog list unless a narrower active bug is provided.
- **`docs/commands.md` should be in scope for Phase 1 truth.** It duplicates relay and install command references (`docs/commands.md:857-876` and `docs/commands.md:928-943`) and will remain a drift source if ignored.
- **Inbound links/permalinks need a concrete redirect plan.** The `/get-started/` content move should preserve `/get-started/` as the intuitive quickstart URL and move changelog content to a new permalink, with a link from old "full changelog" wording fixed.

## Scope / Sequencing

The phase order is mostly right: truth pass before journey rewrite before CLI verifier.

I would adjust the recommended cut:

1. **First push:** Phase 1 plus the narrow Phase 2 front-door restructure: make `/get-started/` a real quickstart, add the local-vs-specific-person fork, add newcomer troubleshooting, fix obvious stale command/doc claims. This is deployable and low risk.
2. **Second push:** Phase 3 v1 `doctor connect` with reduced semantics and tests. This needs OCaml changes, fixture design, and live tmux dogfood; coupling it to a docs rewrite risks making the push too broad.
3. **Later Phase 2 polish:** delivery-doc consolidation and rooms page. Consolidation can be done after the Gemini truth pass, but the truth pass should mark one page as temporary canonical to avoid immediate re-drift.

If Max wants one flagship push, the "headline of Phase 3" should be scoped to a small alias/wrapper plus restart-footer/init fixes, not the full loopback verifier.

## Risks

The plan's listed risks are real: Jekyll publish-by-default, `/get-started/` URL/SEO, and loopback observability.

Missing or underweighted risks:

- **Existing inbound doc links and duplicate nav entries.** Moving changelog content without a permalink/redirect will break links and make search snippets weird.
- **Docs-up-to-date peer-PASS gate.** The c2c review discipline requires docs updates when user-facing CLI/help behavior changes; Phase 3 must update docs and command help together.
- **Testing churn in tracked config.** `c2c init`, `c2c install`, and relay setup can touch `.mcp.json`, `.opencode/opencode.json`, `.c2c/*`, and user-global config. Tests/dogfood need temp HOME/broker roots or explicit cleanup.
- **False-positive verification.** A marker in archive can mean "consumer drained" even if client display failed after drain. Output must avoid saying "delivered to transcript" unless client-specific ACK/tracing proves it.
- **Doctor naming collision.** Default `c2c doctor` is currently push-readiness and repo-only (`ocaml/cli/c2c.ml:7742-7827`); connect diagnostics should be additive (`doctor connect`, `health --connect`, or `connect --verify`) rather than changing the default doctor's meaning.

## Open Decisions

The five decisions are mostly the right ones, but I would tighten them:

- **Q1 Scope:** Good. Recommend separating docs-first from full loopback verifier unless Max explicitly wants a larger flagship push.
- **Q2 URL:** Good. Best framing: keep `/get-started/` as quickstart, move current changelog-ish content to `/changelog/`, and add redirect/link preservation for any old changelog references.
- **Q3 Connect verify:** Good but should split into two decisions: command name, and v1 proof level. Proposed v1 proof level should be "broker enqueue + auto-consumer drain/staging," not transcript confirmation.
- **Q4 Canonical delivery page:** Good. Add a temporary rule for Phase 1: until consolidation lands, the feature matrix or client-delivery page is authoritative and all other pages link/summarize.
- **Q5 Optional extras:** Good, but rooms page should stay optional; human-operator relay onboarding/signpost is more important than a standalone rooms page for the core connect journey.

One extra Max decision to surface:

- **Q6 Diagnostic semantics:** Should `doctor connect` ever drain the user's real inbox as part of probing? Recommended answer: no; use a unique non-ephemeral marker, preserve unrelated inbox messages, and report if the probe cannot isolate its marker.

## Bottom Line

Proceed after fixing the overclaims and tightening Phase 3. The plan is directionally strong and worth executing, but it should not ship with a stale `relay.json` premise or a verifier promise that the current broker/client architecture cannot universally prove.
