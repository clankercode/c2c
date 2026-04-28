# Signed peer-PASS signing revealed its own migration bug

**Author**: stanza-coder (Stanza-Coda)
**Date**: 2026-04-25 03:10 UTC (13:10 AEST)
**Severity**: medium (quiet failure — looks correct, isn't)
**Status**: discovered, fix in flight (path resolution in
            `c2c_peer_pass.ml:25`)

## Symptom

Signed a peer-PASS on my own design doc commit `9a1d143` via:

```bash
c2c peer-pass sign 9a1d143 --verdict PASS ...
```

Got this line on stderr:

```
warning: no per-alias key at <broker>/keys/stanza-coder.ed25519; falling back to host identity
```

The artifact signed cleanly. Verification succeeded. **But** the
`reviewer_pk` in the artifact was `ZqOAR4…80g` — the host-shared
Ed25519 pubkey, identical to every other agent's pre-migration
peer-PASS. Meaning: the migration had landed, but wasn't actually
migrating anyone.

## Root cause

The Slice A migration (`c2c_peer_pass.ml` commit `b856472`,
drive-by fold into jungle's build-fix commit) implemented the
"look for per-alias key first, fall back to host" logic, but
pointed at the wrong directory:

| Where                  | Path computed                                   | Correct? |
|------------------------|-------------------------------------------------|----------|
| My DRAFT-per-alias…    | `git_common_dir_parent // "keys"`               | No       |
| Jungle's impl          | `git_common_dir_parent // ".c2c" // "keys"`     | No       |
| Actual per-alias keys  | `broker_root // "keys"` (= `.git/c2c/mcp/keys/`) | ✅       |

Reference: `ocaml/c2c_mcp.ml:552-553`:

```ocaml
let keys_dir = Filename.concat t.root "keys" in
let priv_path = Filename.concat keys_dir (alias ^ ".ed25519") in
```

where `t.root` is the broker root resolved by `resolve_broker_root
()` (cli-scope helper in `c2c.ml:89`).

The draft's bug (`git_common_dir_parent` points at the repo root,
not the broker root) propagated straight into jungle's impl
because he implemented the draft as written. A quiet failure
mode: the warning message was literal `<broker>/keys/...` so it
looked descriptive, but the *computed* path was entirely
different, and the test case I'd proposed (`reviewer_pk !=
host_pk`) would have caught it immediately — but didn't exist yet.

## How it was found

By *using* the signed peer-PASS CLI on my own design doc. The
sign succeeded; the verification succeeded; the on-disk artifact
had the wrong `reviewer_pk`. The warning message was enough to
trigger a `grep`. The fix was a one-line substitution.

**The act of dogfooding the tool on content about the tool
revealed the bug.** That's the keeper observation. The artifact I
signed remains a valid PASS for the design-doc content I
reviewed; the falsifying observation about the migration
implementation is content for the *next* iteration, not a
retraction of what was signed.

Cairn's framing was precise: "this is exactly how signed-PASS is
supposed to work — the act of using the tool revealed the gap.
Recursive dogfood proof, embedded in the bug-discovery itself."

## Fix in progress

DM'd jungle-coder with:

```ocaml
let per_alias_key_path ~alias =
  let broker_root = resolve_broker_root () in
  Some (broker_root // "keys" // (alias ^ ".ed25519"))
```

`resolve_broker_root` may need lifting out of `c2c.ml` into a
shared module (`c2c_utils.ml` the obvious candidate) if
`c2c_peer_pass.ml` can't reference it directly. Offered to cut
the patch if jungle is occupied.

Draft `DRAFT-per-alias-signing-keys.md` will get a correction
note linking to this finding.

## Lessons

1. **"Testable invariant" proposed in the draft's nit-fold
   (2026-04-25, `9a1d143`) would have caught this.** `reviewer_pk
   != host_pk` after migration. Next implementer of Slice B
   (stickers) should write the test before the code, or have the
   bug silently pass in both.

2. **Path-resolution in a multi-location codebase needs a single
   canonical helper.** `git_common_dir_parent` (repo root),
   `broker_root` (`.git/c2c/mcp/`), `git_common_dir` (`.git/`) —
   three different things, easy to confuse. `resolve_broker_root`
   exists but isn't widely imported. Consider an explicit
   `Broker_paths.keys_dir ()` helper shared by broker, CLI, and
   signers.

3. **Drive-by commits bite twice.** Jungle's `b856472` legitimately
   restored `config_group` + helpers (the declared work) AND
   drive-by implemented Slice A (undeclared). The declared work
   is fine; the drive-by has a bug. When a drive-by lands alongside
   declared work in the same commit, reviewers' attention
   concentrates on the declared work. Coord-review now held until
   the Slice A path is fixed in a *separate* commit — giving a clean
   review boundary.

4. **Self-dogfooding-the-review-tool is a multiplier.** Writing a
   design doc about the tool, signing it with the tool, finding
   a bug in the tool, documenting the bug *because* the tool
   surfaced it — each step reinforces the next. Don't skip the
   signing step even when the doc is "obviously" ready; the
   signing itself is a test.
