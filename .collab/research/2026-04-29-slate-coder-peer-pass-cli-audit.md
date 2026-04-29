# peer-pass CLI audit — post-#427b schema bump

- Author: slate-coder
- Date: 2026-04-29 (UTC)
- Master HEAD baseline: `9467c14a`
- Working binary at audit: `c2c 0.8.0 68e4cfd6 2026-04-29T00:30:01Z`
- Source under audit: `/home/xertrov/src/c2c/ocaml/cli/c2c_peer_pass.ml` (654 lines)
- Related: `/home/xertrov/src/c2c/ocaml/peer_review.ml`

## Methodology

Read `c2c_peer_pass.ml` end-to-end. Ran `c2c peer-pass --help`,
`... sign --help`, `... send --help`, `... verify --help`,
`... list --help`, `... clean --help`. Compared flag sets,
docstrings, and JSON shapes.

## Summary

`sign` and `send` have full flag parity post-#427b
(`--build-rc` / `--all-targets` / `--allow-self` / `--via-subagent`
/ `--commit-range` / `--skill-version` / `--verdict` / `--criteria`
/ `--notes` / `--json` all on both). The remaining gaps are
`verify`/`list` polish, missing `--skill-name`, missing granular
`--targets`, no `show <SHA>` subcommand, and a couple of pre-#427b
loose ends in `signed_artifact`.

---

## CRITICAL

(none — no data-loss / signature-bypass / privilege-escalation issues
found in this surface)

---

## IMPORTANT

### I1. `verify` has no `--json` mode — breaks tooling parity
`c2c_peer_pass.ml:376-515` (the entire `peer_pass_verify_cmd`)

`sign --json`, `send --json`, `list --json`, `clean --json` all emit
machine-readable output, but `verify` is human-only. CI/swarm harnesses
cannot script verify without regex-scraping `Printf` lines like
`"VERIFIED: ..."` or `"VERIFY FAILED: ..."`. Worse, the TOFU
distinction (`Pin_first_seen` / `Pin_match` / `Pin_mismatch`) is only
in the human prose — automation can't tell them apart.

Fix scope: M. Add `-j/--json` flag; emit
`{"ok":bool, "reviewer":..., "sha":..., "verdict":..., "self_review":bool, "pin_state":"first_seen|match|mismatch|rotated", "build_exit_code":N|null}`.

### I2. SHA is not validated before identity load in `sign`
`c2c_peer_pass.ml:115-138` (`signed_artifact`) and `:75-93`
(`validate_signing_allowed`).

`signed_artifact` calls `validate_signing_allowed` BEFORE
`resolve_identity`, which is correct — but `validate_signing_allowed`
only checks `git_commit_exists`. A malformed-but-resolvable SHA
(e.g. ambiguous prefix) would still pass. More importantly,
`artifact_path` calls `validate_artifact_path_components` only at
write time (`:140-147`), AFTER the (cheap) identity load and signature.
Order is fine for a clean repo, but for a malformed SHA the user
sees the path-validator error from a context that already touched
the keystore.

Fix scope: S. Add an explicit early-validate
`Peer_review.validate_artifact_path_components` call at the top of
`signed_artifact` so the user sees the pure-syntactic error before
any key load.

### I3. `--build-rc` not propagated to user-facing summary in non-JSON `sign`
`c2c_peer_pass.ml:240`

When `--build-rc 0` is passed without `--json`, the only output is
`"Signed artifact written to <path>"`. A reviewer who typo'd
`--build-rc 1` (intending 0) gets no on-screen confirmation. `verify`
prints the captured rc, but the signer doesn't. Symmetric surfaces
should show what was captured.

Fix scope: S. Print
`"  build_exit_code: N (#427b verified-build)"` after the path line
when `Some _`.

### I4. `--criteria` is comma-split but values can contain `=` and free-form
`c2c_peer_pass.ml:95-98`, used at `:129`.

Reviewers are encouraged to write
`"build-clean-IN-slice-worktree-rc=N"` as a criterion (per
`--build-rc` doc at `:217`). That works but a comma in a criterion
silently splits it. Acceptable for now, but the docstring at `:175`
("Comma-separated list of criteria checked") doesn't warn.

Fix scope: S. Add note to `--criteria` doc:
`"commas split entries; use ';' or '|' inside a single entry if needed"`.

### I5. `verify` arg `FILE` doc is misleading
`c2c_peer_pass.ml:378-379`, behaviour at `:394-401`.

Docstring: `"Path to peer-PASS JSON artifact (or SHA for default location)"`.
The "or SHA" path silently picks `<dir>/<SHA>-<MY-CURRENT-ALIAS>.json`,
i.e. it only finds artifacts *I myself signed*. A reviewer
verifying someone else's PASS by SHA-only will see
`"artifact not found"` even though it lives in the same dir under
a different reviewer alias.

Fix scope: M. When `FILE` is not a path AND treated as SHA,
glob `<dir>/<SHA>-*.json`. If exactly one match, use it. If 0, error.
If >1, list all and ask user to disambiguate (or accept all and verify
each).

### I6. `--via-subagent` only takes effect when `--allow-self` is set
`c2c_peer_pass.ml:107-113` always merges; doc at `:206` says
`"when --allow-self is in effect"`.

Code merges the tag unconditionally (`merge_subagent_into_notes` has
no `~allow_self` guard), so the docstring is wrong: passing
`--via-subagent foo` without `--allow-self` still appends
`via-subagent: foo` to notes. Either tighten the code or the doc.
Probably the doc is what people read; the code is more permissive
than advertised, which is harmless but creates audit ambiguity.

Fix scope: S. Update doc to say
`"Appended to notes whenever passed; primarily relevant under --allow-self for subagent-review auditability."`.

### I7. `--allow-self` doc duplicated verbatim in `sign` and `send`
`c2c_peer_pass.ml:198-201` vs `:293-296`; ditto `--via-subagent`
`:205-207` vs `:300-302`; ditto `--build-rc` `:211-218` vs `:306-308`.

`send`'s `--build-rc` doc is shorter/simpler than `sign`'s. The
divergence isn't wrong per se but invites drift. Consolidate the
`Cmdliner.Arg.info` blocks into shared constants at top of file.

Fix scope: S. Extract `let allow_self_arg = ...` etc. Both `sign`
and `send` consume the same value. Eliminates ~30 lines and
guarantees parity.

---

## NICE-TO-HAVE

### N1. Missing `--skill-name`
`c2c_peer_pass.ml:177-179`.

Only `--skill-version` exists. There are now multiple review skills
(`review-and-fix`, `ultra-reviewer`, `simplify`). Recording just
the version is ambiguous — `1.0.0` of which skill? Schema field
`skill_version` is opaque, so adding `--skill-name` requires
either schema bump OR writing
`<name>@<version>` into the existing `skill_version` field by
convention.

Fix scope: S (convention-only, sign-side concat) or M
(schema bump — not worth it solo; piggy-back on next bump).

### N2. Missing `--targets c2c,c2c_mcp_server` granular control
`c2c_peer_pass.ml:100-105`, used at `:132`.

`--all-targets` is binary; you cannot say "I built only `c2c` and
`c2c_mcp_server` but not `c2c_inbox_hook`". The `Peer_review.targets`
record has three independent bools, but the CLI collapses them.
Most slices touch one or two targets only — the all-or-nothing flag
encourages honest reviewers to either lie (mark all) or skip the
flag (mark none).

Fix scope: M. Add
`--targets c2c,c2c_mcp_server,c2c_inbox_hook`
parser; mutually exclusive with `--all-targets`. Validation:
empty list rejected; unknown target name rejected.

### N3. Missing `c2c peer-pass show <SHA|FILE>` pretty-printer
`peer_pass_group` at `:645-654`.

`list` shows summary rows; `verify` mixes verification + summary.
A pure pretty-print of an artifact (all fields, formatted ts, full
notes, build_exit_code, criteria as bullets) without invoking
signature verification or pin checks would help auditors and
post-mortem readers. Currently the only way is `cat <path> | jq`.

Fix scope: M. Add `peer_pass_show_cmd`. Reuse `read_json_file` +
`Peer_review.t_of_string`; emit text and `--json`.

### N4. `clean` only matches self-review; no `--older-than 30d` / `--verdict FAIL`
`c2c_peer_pass.ml:588-641`.

Single-purpose. Safe but narrow. As `.git/<repo>/.c2c/peer-passes/`
grows over months, `clean --older-than 90d` would help. Out of
scope for this audit; flag and move on.

Fix scope: M (deferred).

### N5. No `--build-rc-from-just N` shortcut
User asked: should there be `--build-rc-from-just` that runs
`just build` and captures `$?`? Recommendation: **no**. Reasons:
(1) the reviewer should run the build deliberately and inspect output,
not have it hidden behind a sign flag; (2) `just build` semantics
vary (release vs dev, with/without flags); (3) `--build-rc $?`
right after `just build` is two keystrokes. Document the recipe
once in `git-workflow.md` rather than embedding in CLI.

Fix scope: 0 (don't do it). Just confirm in design notes.

### N6. `verify` `--strict` only fires on self-review, not pin-mismatch
`c2c_peer_pass.ml:381-383`, behaviour at `:407-419`.

`--strict` exits 1 on self-review WARN. Pin-mismatch already exits 1
unconditionally, so `--strict` is fine there. But `Claim_invalid` for
non-pin reasons (e.g. signature didn't verify) also exits 1, again
unconditionally. The `--strict` flag's scope is narrow; doc is
accurate but the flag could be repurposed in future for build_exit_code
non-zero on a PASS.

Fix scope: S (later — extend `--strict` to also fail when
`build_exit_code` is `Some n` with `n <> 0` and `verdict = "PASS"`).

### N7. `peer_pass_group` default is `list` — surprising for `c2c peer-pass <SHA>`
`c2c_peer_pass.ml:647`.

`Cmdliner.Cmd.group ~default:peer_pass_list_cmd`. A user typing
`c2c peer-pass abc1234` likely wants `verify abc1234`, not a list.
Acceptable default, but worth a doc note in `--help`.

Fix scope: 0 (doc-only).

### N8. `c2c peer-pass diff <SHA1> <SHA2>` for chain-of-custody
Speculative; user explicitly said "note absences but don't recommend
speculative additions." Noted absent.

Fix scope: N/A.

---

## Cross-cutting observations

- **No tests touched in this audit.** Test files exist under
  `ocaml/test/` for peer-review; verifying flag parity at the test
  layer would catch future drift. Out of scope.
- **The schema-version logic at `:120-122`** correctly bumps to v2
  only when `build_rc` is `Some _`, preserving byte-identity for
  legacy v1 signatures. This is well-commented and looks correct.
- **`peer_pass_message`** at `:149-157` only includes `branch` and
  `worktree` — no `--build-rc` echoed in the DM body. Recipients
  reading the DM see "peer-PASS by X, SHA=..." with no hint that the
  artifact carries a verified-build claim. Consider appending
  `, build-rc=N` when present. (Borderline IMPORTANT; left as
  NICE-TO-HAVE because the artifact itself is the source of truth and
  recipients should run `verify`.)

  Fix scope: S.

---

## Prioritized punch list (one-line summary)

| ID | Sev | File:line | Description | Fix |
|----|-----|-----------|-------------|-----|
| I1 | IMP | c2c_peer_pass.ml:376-515 | `verify` has no `--json` | M |
| I2 | IMP | c2c_peer_pass.ml:115-138 | SHA syntactic-validate before keystore touch | S |
| I3 | IMP | c2c_peer_pass.ml:240 | non-JSON sign output drops `--build-rc` echo | S |
| I4 | IMP | c2c_peer_pass.ml:174-176 | `--criteria` comma-split caveat undocumented | S |
| I5 | IMP | c2c_peer_pass.ml:378,394-401 | `verify` SHA-only lookup glued to my own alias | M |
| I6 | IMP | c2c_peer_pass.ml:107,206 | `--via-subagent` doc says "when --allow-self" but always merges | S |
| I7 | IMP | c2c_peer_pass.ml:198/293, 205/300, 211/306 | duplicated arg-info blocks for sign/send | S |
| N1 | NTH | c2c_peer_pass.ml:177-179 | no `--skill-name` | S |
| N2 | NTH | c2c_peer_pass.ml:100-105 | no granular `--targets` | M |
| N3 | NTH | c2c_peer_pass.ml:645-654 | no `peer-pass show <SHA>` | M |
| N4 | NTH | c2c_peer_pass.ml:588-641 | `clean` lacks `--older-than` / `--verdict FAIL` | M |
| N5 | NTH | (design) | `--build-rc-from-just` — recommend AGAINST | 0 |
| N6 | NTH | c2c_peer_pass.ml:381-419 | `--strict` doesn't cover `build_exit_code != 0` PASS | S |
| N7 | NTH | c2c_peer_pass.ml:647 | group default = list, surprising | 0 (doc) |
| --   | NTH | c2c_peer_pass.ml:149-157 | DM body doesn't echo build-rc | S |

CRITICAL: 0. IMPORTANT: 7 (mostly UX/consistency, all S/M).
NICE-TO-HAVE: 8.
