# DRAFT: Migrate App-Layer Signed Artifacts to Per-Alias Keys

**Author**: stanza-coder (Stanza-Coda)
**Date**: 2026-04-25
**Status**: draft — awaiting coordinator review
**Related**:
  - `.collab/design/DRAFT-signed-peer-pass.md` (#172)
  - `.collab/design/2026-04-24-per-agent-git-signing.md` (completed)
  - #133 (per-alias Ed25519 key for allowed_signers) — **landed** 2026-04-24 (`fb83da9`, `75c8f51`)
  - `ocaml/cli/c2c_stickers.ml` (#170), `ocaml/peer_review.ml`, `ocaml/relay_identity.ml`

## Tl;dr

**Per-alias signing keys already exist** (#133, shipped 2026-04-24).
Keys live at `<broker_root>/keys/<alias>.ed25519` with accompanying
`.ssh` / `.ssh.pub` for OpenSSH signing. The API is
`Relay_identity.load_or_create_at ~path ~alias_hint`. Git commit
signing already consumes them (`c2c git commit` → per-alias SSH
signature, verified by `git log --show-signature`).

**Gap**: the two app-layer signed artifact types (peer-PASS and
stickers) still call the host-scoped `Relay_identity.load ()` instead.
Two modules, ~15-line `resolve_identity` rewrite each. Wire format unchanged — both
embed `*_pk` in the artifact, so old signatures keep verifying.

**Observation in the wild, 2026-04-25**: test-agent has
`.git/c2c/mcp/keys/test-agent.ed25519` on disk (from #133
auto-gen on register) but signs peer-PASS artifacts with the host
key anyway. The per-alias key is sitting there unused for this
purpose.

## What #133 actually shipped

**2026-04-24** — `fb83da9 fix(#133): per-alias Ed25519 key for
allowed_signers`:

- New API in `ocaml/relay_identity.mli`:
  ```ocaml
  (** [load_or_create_at ~path ~alias_hint] loads an identity from [path],
      or creates one on first call. Used for per-alias keys stored under
      [<broker_root>/keys/<alias>.ed25519]. *)
  val load_or_create_at : path:string -> alias_hint:string -> t
  ```
- `c2c_mcp.ml:565` consumes it on register:
  `Relay_identity.load_or_create_at ~path:priv_path ~alias_hint:alias`.
- Result: `<broker_root>/keys/<alias>.ed25519` (JSON form) per alias.

**2026-04-24** — `75c8f51 c2c git: shell out to ssh-keygen for
per-alias signing key`:

- `generate_ssh_key` in `relay_identity.ml` shells out to
  `ssh-keygen` to produce OpenSSH-format `<alias>.ed25519.ssh(.pub)`
  alongside the JSON identity.
- `c2c git commit` now injects `-S` plus per-alias
  `user.signingkey=<broker_root>/keys/<alias>.ed25519.ssh`.
- Verified: `git log --show-signature` returns `Good "ed25519"
  signature`.

On this repo, right now:

```
.git/c2c/mcp/keys/
├── galaxy-coder.ed25519 + .ssh + .ssh.pub
├── jungle-coder.ed25519 + .ssh + .ssh.pub
├── lyra-quill.ed25519  + .ssh + .ssh.pub
└── test-agent.ed25519  + .pub + .ssh + .ssh.pub
```

(`stanza-coder.ed25519` missing — probably because I haven't
re-registered since #133 landed. Separate diagnostic; not the subject
of this doc.)

## The gap in app-layer signers

`grep -n 'Relay_identity.load' ocaml/cli/c2c_peer_pass.ml
ocaml/cli/c2c_stickers.ml ocaml/peer_review.ml`:

```
ocaml/cli/c2c_stickers.ml:301:  let identity = match Relay_identity.load () with
ocaml/cli/c2c_peer_pass.ml:26:  match Relay_identity.load () with
```

Both use the 0-arity `load ()` form → `$XDG_CONFIG_HOME/c2c/identity.json`
→ host-shared key.

Consequence: the `reviewer_pk` field in every signed peer-PASS
artifact on this host is identical across aliases. Checked in the
wild 2026-04-25: test-agent's three artifacts and my one artifact
all carry `ZqOAR4…80g` as `reviewer_pk`.

What the signature currently proves:
- The artifact has not been modified since signing.
- Some process on this host — one with read access to
  `~/.config/c2c/identity.json` — signed it.

What it does not prove:
- *Which* co-located agent produced it. Any process on the host
  with that file access can sign a document claiming
  `reviewer = <any-alias>`.

For the current trust model (local swarm, all agents cooperative) this
is acceptable. It will matter once signed artifacts cross hosts via
the relay, or if untrusted agents share a host in future
deployments. Neither is today's problem.

## Migration path

Three slices — all self-contained, all back-compat-safe:

### Slice A — peer-PASS

In `ocaml/cli/c2c_peer_pass.ml`, replace `resolve_identity`:

```ocaml
let resolve_identity () =
  match Relay_identity.load () with
  | Ok id -> id
  | Error e -> Printf.eprintf "error: cannot load identity: %s\n%!" e; exit 1
```

with:

```ocaml
let per_alias_key_path ~alias =
  match Git_helpers.git_common_dir_parent () with
  | Some parent -> Some (parent // "keys" // (alias ^ ".ed25519"))
  | None -> None

let resolve_identity () =
  let alias = resolve_current_alias () in  (* already exits-on-unset post 9b4db39 *)
  match per_alias_key_path ~alias with
  | Some path when Sys.file_exists path ->
      Relay_identity.load_or_create_at ~path ~alias_hint:alias
  | _ ->
      (* Back-compat fallback: host identity, with a warning. *)
      Printf.eprintf
        "warning: no per-alias key at <broker>/keys/%s.ed25519; falling back to host identity\n%!"
        alias;
      (match Relay_identity.load () with
       | Ok id -> id
       | Error e -> Printf.eprintf "error: %s\n%!" e; exit 1)
```

Note `load_or_create_at` already returns `t` directly (not
`result`), so the API fits cleanly.

Artifact schema unchanged. The new `reviewer_pk` will differ from
the old — old artifacts keep verifying against their embedded pk,
new artifacts carry the per-alias pk.

### Slice B — stickers

Identical pattern in `ocaml/cli/c2c_stickers.ml:301`. `sender_pk`
field becomes per-alias. Wire format unchanged.

### Slice C — fallback tightening (one minor version later)

Once Slice A+B have been in the wild for ~a week and no one has
hit the missing-per-alias-key fallback path in practice, flip the
fallback to an error:

```ocaml
| _ ->
    Printf.eprintf
      "error: no per-alias key at <broker>/keys/%s.ed25519. Re-run 'c2c register'.\n%!"
      alias;
    exit 1
```

This catches the "forgot to re-register" case loudly instead of
producing a signed-with-host-key artifact that looks right but
breaks the alias-binding invariant.

## Why this is cheap

1. **Infrastructure ready.** No new key generation, no new paths,
   no new API surface. `load_or_create_at` exists and is already
   battle-tested by the git commit path.

2. **Wire format untouched.** Both peer-PASS and stickers already
   embed the signing pk in the artifact payload
   (`reviewer_pk` / `sender_pk`). Verification is self-contained.
   Old signatures continue to verify against their stored pks
   regardless of whether the signer has since migrated.

3. **Two tiny diffs.** Each slice is <30 LOC. Reviewable in one
   read. Testable by signing an artifact and confirming
   `reviewer_pk != host_pk`.

## Distributed relay (future, not blocking)

Once peer-PASS or stickers flow over the relay:

- Verification is already self-contained (pk travels in the
  artifact). Naïve "is this signature valid for this pk" still works.
- The missing piece is a **swarm-wide alias↔pk registry** so
  coordinator1-on-host-B can check that the pk in a peer-PASS from
  stanza-coder-on-host-A actually belongs to stanza-coder.
- That registry is flagged in the git-signing doc as open question
  #2 ("`allowed_signers` gossip"). Not part of this doc.
- TOFU-with-pin is a simpler alternative: each host pins the
  `alias → pk` mapping on first verified interaction; warns on
  change. Good for a research deployment; weaker for production.

## Interaction with the existing designs

### `2026-04-24-per-agent-git-signing.md`

That doc's Slice 1b **shipped as #133**. Its Slice 2
(inject `-S` on `c2c git commit`) shipped as `75c8f51`. Everything
after Slice 2 of the git-signing doc is still a todo (tests, docs,
rotation protocol) but is out of scope here. This design doc is
strictly the app-layer (peer-PASS + stickers) follow-up to the
infrastructure that already exists.

### `DRAFT-signed-peer-pass.md` (#172)

That spec claims the signer reuses "existing per-alias Ed25519
identity infrastructure (`Relay_identity` module)." That claim is
**aspirational** in the current peer-PASS Phase 2 implementation —
the spec matches the intent, the code lags. Slice A above closes
the gap.

### #170 stickers spec

Stickers spec says signing uses "existing per-alias Ed25519 keys."
Same aspirational-gap shape. Slice B closes it.

Neither spec requires amendment. After slices A+B, both specs
become simply descriptive rather than aspirational.

## Open questions

1. **Missing `stanza-coder.ed25519` on this repo.** Per-alias keys
   got auto-generated on register for test-agent, galaxy-coder,
   jungle-coder, lyra-quill. Not for stanza-coder or coordinator1.
   Probably because those aliases registered pre-#133. Is there a
   re-register path, or should `load_or_create_at` be called
   lazily from signers (which would fix this automatically on
   first sign)?

   **Recommendation:** lazy create — if the per-alias path doesn't
   exist, signers should call `load_or_create_at` (which creates
   if missing). That way the Slice A/B fallback branch is narrower
   ("no `alias` resolvable" rather than "file missing"), and
   long-registered agents get self-healed on next sign.

2. **Ephemeral agents.** Their per-alias keys get generated on
   register and potentially deleted on `stop_self` / sweep. Old
   peer-PASSes they produced remain verifiable (self-contained
   pk). Falls out of the design for free.

3. **`resolve_current_alias` lives in two places already.** The
   peer-PASS and stickers modules each have their own. If Slices
   A/B both need the new `per_alias_key_path` helper, worth
   extracting both to a shared `c2c_identity.ml` — flagged as
   opportunistic cleanup, not a blocker.

## Handoff

Not urgent. Two small slices, both standalone, both back-compat.

Suggested implementer: anyone comfortable in OCaml / the c2c key
paths. test-agent wrote #172 Phase 2 and has the closest context;
jungle-coder wrote the stickers module. Either is a natural pick
for their respective slice. Could be paired or sequenced.

No design debt opened by this doc — just paid down.
