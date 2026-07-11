# H6 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-h6-list-identity`
- Tips: `989719a5` (feat) + `34f6978d` (tests) + `8b2c4c0c` (docs).
  Base `aad5c1b1` (H5 peer-PASSed tip — dune lane H4→J1→H5→H6→F5a; F5a next).
- Pure `ocaml/list_identity.ml`(.mli): identity kinds `local` (broker-scoped
  session alias, no crypto anchor) / `relay` (alias@host_id anchored to
  machine key); scopes local/relay/both. Fold rule: alias case-insensitive
  equal AND lease opaque_host_id == effective local host id; lease without a
  host anchor never folds; wrong host never folds; first-match-wins.
- `c2c list --relay`: merged view — JSON `{peers:[...], relay_error}` envelope
  with per-row identity_kind/identity_scope + folded rows carrying nested
  relay_lease; human SCOPE column + `(= local '<alias>')` cross-reference.
  Offline nonfatal: relay fetch is a total variant (never throws), local rows
  always print, relay_error surfaced (JSON field / stderr note), exit 0
  (documented partial-success). `--kind local|relay` filter (scope-both passes
  both); `--kind relay` without `--relay` → empty + stderr hint.
- **Default `c2c list` invariant** (highest-priority criterion): reviewer
  traced in code that identity labels are guarded behind the relay flag and
  default JSON stays a bare array with zero new keys; pinned by
  test_default_json_shape_unchanged.
- Authority constraints honored: merged-by-default flip NOT taken — documented
  as an open operator-owned product gate citing the decision ledger
  (friction-adr0-decision-ledger branch); NO attestation surface (all
  trust/verified mentions in the diff are explicit negations; I008 noted
  unbuilt).
- Tests: exclusive `ocaml/test/test_c2c_list_relay.ml`, 13 cases vs a hermetic
  forked loopback fake relay (bound+listen before fork, ephemeral port,
  SIGKILL+waitpid cleanup; offline = closed loopback port; no external hosts).
  Dune lane: pure trailing append below H5's stanza.
- Docs: docs/reference/identifiers.md (identity model + verbatim examples),
  scopes.md, commands.md list row. Reviewer verified human-output format
  strings match code exactly; JSON example is a disclosed illustrative subset
  (nit: could add "fields elided").
- Live peer-PASS (independent opus reviewer, not author or its subagent):
  PASS first pass. Evidence IN slice worktree: reviewer's own
  `DUNE_WATCHDOG_TIMEOUT=900 just check` rc=0
  (build-clean-IN-slice-worktree-rc=0); suites list_relay 13, relay_state 22,
  schema_v1 26, doctor 23. Signed artifact `8b2c4c0c-fable-warden.json`
  (v2, build_rc=0, all targets).
- Out-of-scope notes carried: `--relay --json` envelope supersedes the B097
  bare array (no in-tree consumers of the 2-day-old shape — reviewer
  re-verified); dead-self-lease + `--alive` scope quirk (honest, documented);
  `--global --relay` labeling compile-verified only (needs broker-root
  enumeration fixture — candidate future work).
