# Review — Feature A: Connect Metadata (opt-out) Plan

**Reviewer:** mimo25p (gemini-2.5-pro) · **Date:** 2026-06-12
**Plan:** `.worktrees/wt-feat-connect-metadata/.collab/design/2026-06-12-feat-connect-metadata-plan.md`

---

## 1. EVIDENCE CHECK — file:line anchors

| # | Plan Claim | Actual Lines | Verdict |
|---|-----------|-------------|---------|
| 1 | `c2c_mcp.mli:49-112` (record type, cwd :106-111, canonical_alias :55) | 49-112, 106-111, 55 | **Exact** |
| 2 | `c2c_broker.ml:122` (to_json), `:248` (of_json) | 122, 248 | **Exact** |
| 3 | `c2c_broker.ml:1871` (register fn with `?cwd`) | 1871 | **Exact** |
| 4 | `c2c_broker.ml:1695-1712` (canonical_alias derivation) | 1691-1712 | **Off by 4** (starts earlier at 1691) |
| 5 | `c2c_repo_fp.ml:14-28` (fingerprint) | 14-27 | **Off by 1** (28 is blank) |
| 6 | `c2c_identity_handlers.ml:14` (handler), `:285-287` (call) | 14, 283-286 | **Off by 2** |
| 7 | `cli/c2c.ml:2855` (term), `:2901` (Broker.register call) | 2855, 2901 | **Exact** |
| 8 | `c2c_identity_handlers.ml:357-409` (list), `:411-426` (whoami) | 357-409, 411-427 | **Off by 1** (whoami ends 427) |
| 9 | `c2c_broker.ml:1103-1191` (worktree guard) | 1100-1189 | **Off by 3** start, **Off by 2** end |
| 10 | `c2c_mcp.ml:30-38` (register schema) | 30-38 | **Exact** |
| 11 | `c2c_broker.ml:1904-1927` (state carry-over) | 1904-1927 | **Exact** |

**Summary:** Anchors are mostly exact or off by 1-4 lines (document rot range). No
materially wrong anchors. The plan's key factual claims are all verified:
- CLI `register_cmd` at 2901 does omit `~cwd` (defaults to `None`) ✓
- MCP handler at 283-286 does pass `~cwd:(try Some (Sys.getcwd ()) ...)` ✓
- Worktree guard at 1144-1150 does read `reg.cwd` from the registration record ✓
- `of_json` at 248 uses `member`-based extraction (unknown fields silently ignored) ✓
- State carry-over at 1927 destructures `_old_cwd` (discarded, not preserved) ✓

---

## 2. APPROACH SOUNDNESS

### 2a. The consent flag gates an empty set — defensible but over-framed

The plan says the flag is "honored at every read/exposure site" and "suppresses any
*future* metadata surfacing/federation." In v1 there are zero exposure sites — `list`
and `whoami` omit cwd, relay never sees registrations. The flag is literally a boolean
written to disk and never read by any code path.

**Verdict: defensible as future-proofing**, but the plan over-frames it. The real
deliverable is the CLI cwd bug fix (step 3). The flag is scaffolding. The plan should
be honest that v1's "opt-out" is "record a preference for later enforcement" — not a
live gate. Recording it now is still the right call (changing the record type later is
more disruptive), but reviewers should not expect the flag to *do* anything in v1.

### 2b. CRITICAL BUG: Slice A1 contradicts the guard invariant

The plan's "Chosen approach" (§2) explicitly states:

> "do NOT make `cwd` itself opt-out-able"

Yet Slice A1 says:

> `ocaml/cli/c2c.ml:2901`: pass `~cwd:(Sys.getcwd ())` **unless `--no-metadata`**;
> pass `~metadata_opt_out:no_metadata`.

If `--no-metadata` suppresses `~cwd`, then `cwd` defaults to `None` in the
registration record. The worktree guard at `c2c_broker.ml:1149` reads `reg.cwd` —
when it's `None`, the guard silently skips (line 1153: `None -> ()`). This means
`--no-metadata` **breaks the guard for that session**, exactly the scenario the plan's
approach section says must not happen.

The MCP handler (`c2c_identity_handlers.ml:286`) gets this right:
`~cwd:(try Some (Sys.getcwd ()) with Sys_error _ -> None)` is **unconditional** — it
runs regardless of `include_metadata`. The CLI must match: always pass `~cwd`, use
`--no-metadata` only to set the `metadata_opt_out` flag.

**Fix for Slice A1:** Change the CLI call to always pass `~cwd:(Sys.getcwd ())` and
only vary `metadata_opt_out` based on `--no-metadata`.

---

## 3. FORWARD-COMPAT

The plan correctly identifies that `of_json` ignores unknown fields (natural
forward-compat via `member`-based extraction). Adding `metadata_opt_out` to the record
and `to_json` is safe.

**The plan should specify the exact serialization pattern.** Based on the existing code
conventions (see `dnd` at line 148: only emits when `true`), the new field should:

```ocaml
(* in registration_to_json, after the last existing field *)
let with_opt_out =
  if metadata_opt_out then with_... @ [ ("metadata_opt_out", `Bool true) ]
  else with_...
in
```

And in `of_json`:

```ocaml
; metadata_opt_out = bool_member_default "metadata_opt_out" json false
```

The `bool_member_default` helper already exists at line 254-256 and is used for `dnd`
at line 272. This pattern omits the field when `false` (compact JSON) and defaults
missing fields to `false` (forward-compat). **Verified safe.**

---

## 4. GAPS & RISKS

### 4a. Worktree guard reads cwd from registration — no recompute

Confirmed: `c2c_broker.ml:1145-1150` loads `reg.cwd` from the registration record via
`load_registrations`. It does NOT call `Sys.getcwd()`. The guard compares the
registration-time cwd against the expected-cwd file. **The opt-out flag cannot confuse
the guard** because the plan correctly keeps `cwd` always-captured (once the A1 bug
above is fixed).

### 4b. No relay path — flag won't be federated

Confirmed: registrations are broker-local. The research doc notes "zero cwd/
canonical_alias refs in relay*.ml." The `metadata_opt_out` flag has no federation path
in v1. **No risk.**

### 4c. State carry-over of `metadata_opt_out` on re-registration

The plan mentions "state carry-over (:1904-1927)" but does NOT specify how
`metadata_opt_out` should behave on re-registration. Looking at the code:

- `_old_cwd` is **discarded** (line 1927) — cwd is always from the new call
- `tmux_location` is **preserved** via `effective_tmux_location` (lines 1956-1958)

Which pattern should `metadata_opt_out` follow? Two options:

1. **Discard like cwd** — every re-registration re-evaluates the flag from the caller's
   current preference. This means a managed session that re-registers (e.g., after
   restart) would need to re-assert `--no-metadata` each time.
2. **Preserve like tmux_location** — once set, the flag sticks until explicitly changed.
   More user-friendly but could surprise if the user re-registers without the flag.

**Recommendation:** Discard (match cwd behavior). The flag is a per-registration
preference; the caller should re-assert it. The plan should specify this explicitly.

### 4d. Slice A3 wording is misleading

The plan says: "when false, set `metadata_opt_out=true` and **skip cwd capture path's
*exposure***." There is no separate "exposure path" in the MCP handler — cwd is
captured unconditionally at line 286 and the flag is just recorded. The wording implies
a code path that doesn't exist. **Minor clarity issue.**

### 4e. Test plan missing guard-verification test

The test plan covers (a) CLI stores cwd, (b) `--no-metadata` sets flag, (c) JSON
round-trip, (d) forward-compat. But it does NOT test:

- **That `--no-metadata` still stores cwd** (the guard invariant). This is the critical
  test given the A1 bug above — once fixed, a test should assert that `cwd` is `Some _`
  even when `metadata_opt_out=true`.

---

## 5. SLICE SIZING + TEST PLAN

**Sizing: appropriate.** Four slices (A1-A4), each touching 1-2 files, well-scoped.
The real deliverable (CLI cwd fix) is the smallest change; the flag plumbing is
mechanical. Could be a single commit series.

**Test plan: adequate with one gap** (4e above). The plan correctly gates external
effects behind fixture env vars and references the right test files. The test list (a-d)
covers the main scenarios but should add (e): `--no-metadata` does NOT suppress cwd
capture.

---

## VERDICT: SOUND-WITH-FIXES

The plan's architecture is sound: reuse existing cwd + slug, record a consent flag for
future enforcement, fix the CLI cwd bug. The worktree guard interaction is correctly
reasoned. Forward-compat is safe.

**However, Slice A1 as written breaks the guard invariant it claims to protect.**
This is the one must-fix.

### Top 5 Concrete Improvements

1. **FIX A1: CLI must always pass `~cwd:(Sys.getcwd())`** — `--no-metadata` should
   only set `metadata_opt_out`, never suppress cwd. The MCP handler
   (`c2c_identity_handlers.ml:286`) already does this correctly; match its pattern.
   *Plan §Slice A1, line ~43.*

2. **Specify `metadata_opt_out` carry-over semantics on re-registration.** Recommend
   discarding (caller re-asserts), matching cwd's `_old_cwd` pattern at
   `c2c_broker.ml:1927`. Add to Slice A2.
   *Plan §Slice A2, line ~48.*

3. **Add guard-invariant test: `--no-metadata` still stores `cwd = Some _`.** Without
   this test, the A1 fix has no regression safety.
   *Plan §Slice A4, line ~63.*

4. **Specify exact serialization pattern for the new field** (omit-when-false via
   existing `bool_member_default` at `c2c_broker.ml:254`). This prevents an implementer
   from using a different pattern that breaks compactness or forward-compat.
   *Plan §Slice A2, line ~50.*

5. **Tone down the "honored at every exposure site" framing** — v1 has zero exposure
   sites. Be honest that the flag is scaffolding and the real deliverable is the CLI cwd
   fix. This sets correct expectations for reviewers.
   *Plan §Chosen approach, lines 25-28.*
