# SPEC roundtrip audit: signed peer-PASS

- **Spec**: `.collab/design/SPEC-signed-peer-pass.md`  (note: caller's brief said `.collab/specs/`, but the file actually lives under `.collab/design/`; flag for the spec patch — header should pin its own canonical path or we should move it into `.collab/specs/`)
- **Impl roots**:
  - `ocaml/peer_review.ml` (artifact + Trust_pin + verify_claim / verify_claim_with_pin)
  - `ocaml/c2c_mcp.ml` (broker enforcement, peer_pass_reject + pin_rotate audit log, hook registration)
  - `ocaml/cli/c2c_peer_pass.ml` (CLI sign / verify / rotate-pin, reviewer_is_author w/ co-author trailer)
- **Landed slices in scope**: H1, H2, H2b, M1, #56, #57, #57b, #55, #54b, S1.

The SPEC is broadly accurate at the top — the H2/H2b prelude was rewritten today and matches code. The drift is concentrated in **§Artifact Schema / §Verification / §Implementation Tasks / §Git Hook Integration / §Open Questions / §Path-traversal defence**, plus an unmentioned threat-model layer (#55 audit log) that the SPEC has no section for.

---

## §Status (line 5)

Match: yes for the listed shipped commits.

Drift:
- Doesn't list **#56** (size cap), **#57** (path-validator), **#57b** (alias 128-byte cap), **#55** (rotate-pin audit log), **#54b** (with_pin_lock RMW). These are referenced inline lower in the SPEC (the size-cap and path-validator sections were added) but not enumerated in the landing-order list. The pin-rotate audit log (#55) and the RMW lock (#54b) have NO mention anywhere in the SPEC.

Patch sketch: append `, #56 read_artifact_capped, #57 path-validator, #57b alias 128B cap, #55 pin-rotate audit log, #54b Trust_pin.with_pin_lock (RMW), S1 pin-save flock` to the shipped list. Cross-check that S1 commit hash `ef09077c` is for the save-time flock specifically and #54b for the RMW wrap; current SPEC mentions only S1.

---

## §Broker-side enforcement (H2 + H2b) (lines 7–53)

Match: very close. Two minor drifts:

1. The reject text in code is at `c2c_mcp.ml:4621-4623`, not 4471-4473. **SPEC line 29 is wrong by ~150 lines** (file grew). Recommend de-pinning to a quoted string only, dropping the `:NNNN` line range — those drift fast (#324 docs-up-to-date check applies).
2. The `<repo>/.c2c/peer-pass-trust.json` mention (line 47) implies a CLI-side store distinct from the broker-side store. In practice both resolve via `Trust_pin.default_path_ref` to the same `<broker_root>/peer-pass-trust.json` (the CLI's `c2c_peer_pass.ml:348` uses `C2c_utils.resolve_broker_root ()`, not the legacy `.git/c2c/...`). **There is one canonical store**, not two with the same schema. The SPEC suggests two; impl is one.

Patch sketch: change the pin-store paragraph to "Pin store: single file at `<broker_root>/peer-pass-trust.json`. Both broker and CLI resolve to the same path via `C2c_utils.resolve_broker_root` / `Trust_pin.default_path`."

---

## §Artifact Schema (lines 68–109)

Match: types match. Drift on **what's actually validated**:

- **`version`**: SPEC says required, currently 1. Impl: `t_of_json` defaults silently to `1` if missing (`peer_review.ml:107`). No version check — any artifact passes regardless. **Promise mentioned but unenforced.**
- **`verdict`**: SPEC says `"PASS" | "FAIL"`. Impl: stored verbatim as `string`; no allowlist check. A `verdict: "MAYBE"` artifact would pass `verify_claim_with_pin`. **Mentioned but unenforced.** (Mostly cosmetic but the sender-receipt echoes `art.verdict` verbatim — see `c2c_mcp.ml:4744`-ish.)
- **`reviewer_pk`**: required by SPEC; impl enforces non-empty, b64url-decodable, exactly 32 bytes. **Match.**
- **`signature`**: required by SPEC; impl enforces non-empty, b64url-decodable, exactly 64 bytes, valid Ed25519 sig over canonical JSON. **Match.**
- **`sha` / `reviewer`**: SPEC describes them as identifiers. Impl additionally enforces `validate_artifact_path_components` on the *claim* alias/sha (and only by transitive effect on the artifact body, since the body is rejected if `art.sha != claim_sha` or `art.reviewer != claim_alias` — see `peer_review.ml:735-738`). The artifact body's own `reviewer`/`sha` strings are never independently validated against the alias/sha character class — but they only matter via the claim-binding check. **De facto fine; not described in SPEC.**
- **`criteria_checked` / `skill_version` / `commit_range` / `targets_built` / `notes` / `ts`**: all parsed; none validated. **Mentioned but unenforced.** `ts` is the worst gap — see §Verification step 5 below.

Patch sketch: add a "Validation status" subtable next to "Field Semantics":

| Field | Validated? |
|-|-|
| version | NO (silently defaults to 1) |
| reviewer | only via claim-binding equality |
| reviewer_pk | YES (b64url, 32B) |
| sha | only via claim-binding equality |
| verdict | NO (stored as opaque string) |
| signature | YES (b64url, 64B, Ed25519 verify) |
| ts | NO (no age check; see §Verification #5) |
| others | parsed only |

---

## §Signature Computation (lines 111–116)

Match: yes. Note that the canonical JSON is produced by `t_to_canonical_json` which delegates to `json_to_string_sorted` — keys are emitted **alphabetically sorted**, NOT in the field order the SPEC enumerates. SPEC says "canonical field order: version, reviewer, ...". Impl order is alphabetical. The actual signed bytes are unambiguous either way (sorted is the canonical operation), but **the SPEC is misleading**.

Patch sketch: replace "canonical field order: version, reviewer, …" with "canonical JSON: keys sorted lexicographically (per `Peer_review.json_to_string_sorted`); the `signature` field is omitted from the to-be-signed bytes."

---

## §Verification (lines 118–125)

- Steps 1–4: match.
- Step 5 (`ts` age check, "NOT YET IMPLEMENTED"): still not implemented. **Match.**
- **Missing**: SPEC has no description of the **TOFU pin enforcement layer** (H1+H2b) at the *verification* level — the H2/H2b prelude up top is broker-boundary-flavored, but the §Verification section reads as if signature validation alone is sufficient. This is the single biggest doc drift: a fresh reader of §Verification would not know that `verify_claim_with_pin` is the boundary contract.

Patch sketch: insert after step 4:

> 4b. (For broker-boundary callers) Apply TOFU pubkey pin via `Trust_pin.find_pin` keyed by `reviewer`. `Pin_first_seen` and `Pin_match` advance to step 5; `Pin_mismatch` is a hard reject (`Claim_invalid`). The pin is updated under `Trust_pin.with_pin_lock` so the load→decide→save sequence is atomic across concurrent verifiers (#54b).

And add a **resolution-order paragraph** explicitly:

> **Verification resolution order**:
> 1. Path-validator on (alias, sha) — #57.
> 2. Size-cap stat() — #56.
> 3. Parse → `verify` (signature on canonical JSON) — H1 base.
> 4. Bind: `art.sha == claim_sha`, `art.reviewer == claim_alias` (case-insensitive on alias) — H2.
> 5. TOFU pin (`pin_check`) — H2b.
> 6. (TODO) `ts` age — unimplemented.
>
> The convenience entry point is `verify_claim_with_pin`; broker uses it (`c2c_mcp.ml:4588`). The legacy `verify_claim` (no pin) is retained for code paths that explicitly want sig-only and is **NOT broker-boundary-safe** on its own.

---

## §Artifact Size Cap (#56) (lines 127–144)

Match: yes — the inline description is accurate. `read_artifact_capped` exists, returns the polymorphic-variant pair, called from `read_artifact`. **No drift.** Could note that `read_artifact_capped` is also exposed for external callers (currently only used internally), low priority.

---

## §Path-traversal defence (#57) (lines 146–186)

Match: yes for the alias/sha reject set. Drift:

- **#57b alias 128-byte cap**: implemented at `peer_review.ml:208-212` (`alias_max_bytes = 128`) but the SPEC §Path-traversal defence doesn't list it in the alias-rejection bullet. The bullet says "empty; contains `/`, `\`, `..`, NUL, leading `.`; or any byte outside printable ASCII excluding space" — no length cap mentioned.
- The alias allowlist in code is `0x21..0x7e` (printable ASCII excluding space and DEL); SPEC says "0x20..0x7e" then qualifies "excluding space". Code's allowlist starts at `0x21`, so the SPEC range is technically wrong (it'd allow space then exclude it; impl just doesn't allow space at all). Cosmetic.

Patch sketch: add bullet "alias longer than 128 bytes (#57b)". Tighten allowlist to `0x21..0x7e`.

---

## §Git Hook Integration (#171) (lines 188–200)

**Major drift — entire section is aspirational.** No `githooks/` directory exists in repo. No pre-commit hook. The SPEC describes `githooks/pre-commit` and `c2c install` wiring it; neither is implemented. The "Implementation Tasks" checklist (line 222) correctly leaves these unchecked, but §Git Hook Integration reads in present tense ("verifies that for each commit…"), which is misleading.

Patch sketch: prefix section with "**STATUS: NOT IMPLEMENTED**. Design intent below."

Also `.peer-reviews/` (mentioned in line 196 + 200) doesn't match impl. The actual artifact location is `<git-common-dir-parent>/.c2c/peer-passes/<sha>-<alias>.json` (`peer_review.ml:261-270`). The git-hook section's filename `.<sha>.peer-pass.json` doesn't match either. Either the hook was designed against an older filename scheme that the artifact-write path then drifted away from, or the hook section was never reconciled with the working code. Recommend the patch sketch: rewrite §Git Hook Integration to reference the actual storage path used by `Peer_review.artifact_path` and gate behind a clear "future work" marker.

---

## §Open Questions (lines 226–234)

Drift:
- Q1 says `.peer-reviews/` per-worktree at `.git/peer-reviews/`. Reality: `<git-common-dir-parent>/.c2c/peer-passes/` — single shared dir, not per-worktree (the comment in `artifact_path` at peer_review.ml:252-253 explicitly says "shared across all worktrees clones"). So Q1's stated decision (per-worktree) is the OPPOSITE of what shipped.
- Q2 says NOT committed; reality `.c2c/` is gitignored. **Match in spirit.** But "lives in `.git/peer-reviews/`" is wrong location.
- Q3 (FAIL artifacts unsigned): impl signs whatever verdict the CLI is told to sign. `signed_artifact` at `c2c_peer_pass.ml:115` accepts `verdict` and signs it; FAIL is not special-cased. **Drift: SPEC says FAIL artifacts are NOT signed by default; impl signs them identically.**

Patch sketch: rewrite Q1 + Q3 to match reality.

---

## Unmentioned guarantees the impl now provides

These are real properties the impl gives that the SPEC does not call out anywhere:

1. **#54b RMW atomicity for pin operations**. `pin_check` and `pin_rotate` both run their entire load→decide→save sequence inside `Trust_pin.with_pin_lock`. SPEC line 49-50 mentions S1's save-only flock and exposes `with_pin_lock` for "callers needing read-modify-write atomicity" but does NOT state that `pin_check`/`pin_rotate` *themselves* now run under it. A reader could plausibly write a fourth caller that does load+upsert+save without the wrap and assume it's safe; the SPEC should either mandate the wrap pattern or say "pin_check / pin_rotate are the canonical entry points and already wrap; do not call Trust_pin.{load,save} directly".

2. **#55 pin-rotate audit log**. ENTIRELY UNMENTIONED. Every `pin_rotate` call (CLI `--rotate-pin` today; future MCP rotate-pin) emits a JSON line to `broker.log` with event `peer_pass_pin_rotate`, fields `alias`, `old_pubkey`, `new_pubkey`, `prior_first_seen`, `ts`. Hook is wired at broker startup (`c2c_mcp.ml:3283-3292`) so EVERY caller of `Peer_review.pin_rotate` produces an audit line — a stealth-rotate is no longer possible. **This changes the threat model**: a compromised key cannot silently overwrite the pin without leaving a forensic trail.

3. **`Peer_review.set_pin_rotate_logger` extension hook**. Library is decoupled from c2c_mcp — third parties (or the test suite) can install their own logger.

4. **Reject-text discipline (I3 from slate's review)**. The user-facing reject string is generic — it does not echo `claim_alias`, `claim_sha`, `reviewer_pk`, or underlying parse errors back to the sender, to avoid letting an attacker probe what the broker saw. The SPEC mentions this in passing (lines 35-43) but should elevate it to a named principle (it informs every future error-message change).

5. **Co-author trailer detection (M1)**. SPEC §Implementation Tasks lists no entry for self-pass detection at all. The broker's `check_self_pass_content` is in `c2c_mcp.ml:4174`, and the CLI's `reviewer_is_author` (which gates `signed_artifact`) now also walks `Co-authored-by:` trailers (`c2c_peer_pass.ml:62-73` + `git_commit_co_author_emails`). **Anti-cheat coverage is broader than SPEC suggests** — a co-author cannot self-PASS even via the CLI sign path now.

6. **Single canonical pin store**. As above: SPEC §Broker-side enforcement implies dual stores; impl is one.

---

## Mentioned-but-unimplemented promises

1. `ts` age check (30-day expiry). SPEC says NOT YET; correct, still not implemented.
2. `c2c install` git-hook wiring. Not implemented.
3. `githooks/pre-commit` script. Not implemented; `githooks/` dir doesn't exist.
4. `.peer-reviews/` storage convention. Replaced by `.c2c/peer-passes/`; SPEC text not reconciled.
5. `version` field validity check. Field exists, never checked.
6. `verdict` allowlist `PASS|FAIL`. Field exists, never checked.

---

## Threat-model coverage delta (rotate-pin audit log)

Before #55, the threat story was:
- TOFU pin protects against fresh-keypair forgery (H2b).
- Operator can rotate (`--rotate-pin`) when an alias legitimately changes keys.
- **Gap**: a CLI-on-the-victim-machine attacker, OR a future MCP rotate-pin tool, could call `pin_rotate` and silently replace the pin. No record of the change.

After #55: every `pin_rotate` call emits `peer_pass_pin_rotate` to `broker.log` (event, alias, old_pubkey, new_pubkey, prior_first_seen, ts). Forensic audit can detect:
- An alias whose pin rotated but no operator-visible action occurred.
- An alias whose pin rotated repeatedly (suggesting key-rotation flapping or attack).
- old_pubkey="" with a non-null prior_first_seen would be incoherent (impl never produces it; first-rotate has prior=None and old="").

The SPEC should add a §Threat Model section covering:
- Forgery via fresh keypair → blocked by H2b.
- Forgery via stolen key → blocked by signature check, no per-message replay protection (out of scope, no nonce).
- Stealth pin rotation → detectable via #55 audit log.
- Path traversal via crafted alias/sha → blocked by #57.
- DoS via huge artifact → blocked by #56 (64 KiB cap).
- Concurrent pin race → blocked by #54b RMW lock.
- Sender-side forensic leak via reject text → mitigated by I3 discipline.

---

## Highest-priority drift

**§Verification + §Artifact Schema** — the SPEC describes verification as signature-only, with H2b mentioned only in the broker-prelude up top. A fresh reader writing a new caller would plausibly use `verify_claim` (no pin), bypassing TOFU enforcement. This is the single most consequential drift because it can produce a *correct-looking but unsafe* implementation. Recommend the §Verification rewrite (with the explicit resolution-order list) be the first patch landed.

Second priority: §Open Questions Q1/Q3 are directly contradicted by impl — they're load-bearing for new contributors trying to find artifacts on disk.

Third priority: add §Threat Model (currently spread across the document; pulls #55, #56, #57, #57b, #54b, S1 into one place).

---

## SPEC patch outline (do not apply yet)

1. Add #56 #57 #57b #55 #54b to the §Status shipped list.
2. Replace pin-store dual-path text with single canonical path.
3. De-pin file:line references (e.g. `c2c_mcp.ml:4471-4473` → just the quoted string).
4. Add field-validation table to §Artifact Schema.
5. Replace §Verification with the 6-step resolution order; flag step 6 (ts) as unimplemented; add 4b TOFU step.
6. Mark §Git Hook Integration as NOT IMPLEMENTED + reconcile filename/dir to `.c2c/peer-passes/<sha>-<alias>.json`.
7. Rewrite Open Questions Q1/Q3 to match impl (single shared dir; FAIL artifacts ARE signed today).
8. Add §Threat Model section enumerating forgery / stealth-rotate / DoS / RMW-race / sender-side-leak coverage and the slice that closes each.
9. Add §Anti-cheat detection covering self-pass + co-author trailer (M1) — currently nowhere.
10. Add #57b alias 128-byte cap to §Path-traversal defence rejection list; tighten allowlist range (0x21–0x7e).
11. Cross-reference `Trust_pin.with_pin_lock` as the canonical RMW wrap and state that `pin_check`/`pin_rotate` already wrap (so direct `Trust_pin.{load,save}` callers are the bug).
12. Move file from `.collab/design/` to `.collab/specs/` if "specs" is the canonical home (caller's brief assumed this), or update the brief.

---

## File paths referenced

- `/home/xertrov/src/c2c/.collab/design/SPEC-signed-peer-pass.md`
- `/home/xertrov/src/c2c/ocaml/peer_review.ml`
- `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml`
- `/home/xertrov/src/c2c/ocaml/cli/c2c_peer_pass.ml`
- `/home/xertrov/src/c2c/ocaml/test/test_peer_review.ml`
- `/home/xertrov/src/c2c/ocaml/test/test_c2c_mcp.ml`
