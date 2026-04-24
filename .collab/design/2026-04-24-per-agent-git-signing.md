# Per-agent git commit signing via existing c2c keys

**Author**: coordinator1 (Cairn-Vigil)
**Date**: 2026-04-24
**Status**: design ready for implementation
**Related**: todo-ideas.txt (git-proxy extensions), #122 (guarded `c2c git` shim), completed M1-S1 (Ed25519+X25519 keypair in `c2c register`)

## Goal

Every commit from a managed c2c agent should be cryptographically signed by that agent's own Ed25519 identity key — the same key `c2c register` already generates. No user/global GPG key is touched; c2c manages its own signing surface entirely per-repo, per-agent.

`git log --show-signature` against the swarm allowed-signers file tells you "this commit was made by `test-agent`" in a verifiable way.

## Non-goals

- Detecting or reusing the user's global `~/.gitconfig` `user.signingkey` — explicitly out of scope. Max's personal key stays unknown to c2c.
- PoW-gated email proxy (separate idea, see `todo-ideas.txt`).
- Signing commits made outside the `c2c git` proxy path — unmanaged direct `git commit` calls are unsigned by c2c and that's fine.

## Design

### 1. Reuse the Ed25519 identity key

`c2c register` already generates a per-alias Ed25519 keypair (M1-S1 shipped). The private key lives under the broker root — we treat it as the agent's git signing key too. No new key material.

### 2. Per-repo scope via `.git/c2c/`

- Keys continue to live under the broker root (git common dir): `<broker_root>/keys/<alias>.ed25519` (private) + `.pub` (public).
- Allowed-signers file for this repo: `<broker_root>/allowed_signers` — git's native format, one line per alias:
  ```
  <alias>@c2c.im ssh-ed25519 AAAA…
  ```
- Scope is per-repo because `<broker_root>` resolves from `git rev-parse --git-common-dir`. Each clone/worktree gets its own set. Shared across worktrees of the same common dir (which is the existing c2c registry behavior).

### 3. Git configuration per agent, per commit

When the `c2c git commit` path fires, the shim:

1. Resolves the caller alias from `CLAUDE_SESSION_ID` / `C2C_MCP_SESSION_ID` → c2c registry lookup → alias.
2. Locates that alias's private key.
3. Invokes real git with:
   ```
   -c gpg.format=ssh \
   -c user.signingkey=<path to alias.ed25519.pub> \
   -c gpg.ssh.allowedSignersFile=<broker_root>/allowed_signers \
   -c commit.gpgsign=true \
   -c user.email=<alias>@c2c.im \
   -c user.name=<alias> \
   commit -S --author="<alias> <<alias>@c2c.im>" "$@"
   ```
   (The `-c key=value` flags override rather than persist to `.gitconfig`; per-invocation only.)

   The private key is passed to `ssh-keygen -Y sign` via the `gpg.ssh.defaultKeyCommand` / `user.signingkey` convention — use the file-path form (`user.signingkey=/path/to/priv.key` with the public key at `.pub` next to it). Git's SSH signing driver reads the private key file directly.

4. For non-commit git subcommands (status, diff, log, …), passthrough unchanged — no key injection.

### 4. Opt-out

A single config key in `<broker_root>/config.toml` (or env var):

```toml
[git]
sign = true          # default
attribution = true   # default
```

Setting `sign = false` skips `-S` injection. `attribution = false` skips the `--author` injection. Both pass through existing user-supplied `-S` / `--author` if present (don't double-set).

### 5. Ephemeral / short-lived agents

Ephemeral agents get a fresh keypair at registration. Their entry is added to `allowed_signers` when they register and removed on `stop_self` / sweep. Git `log --show-signature` against an older `allowed_signers` snapshot may show "no matching principals" for retired ephemerals — that's by design (commits are still valid under the snapshot at the time of signing). To preserve historical verifiability, **append-only** semantics on `allowed_signers` (never remove lines, only add) with a dated suffix:
```
coordinator1@c2c.im ssh-ed25519 AAAA… # added 2026-04-24
eph-review-bot-tovi-drift@c2c.im ssh-ed25519 BBBB… # added 2026-04-22, retired 2026-04-23
```
Git ignores the trailing comment.

### 6. Key rotation / compromise

If an alias's key must rotate: new entry appended to `allowed_signers` with a new `# added <date>` comment; old entry kept for historical verification of prior commits. The old private key is deleted from the broker root.

## Implementation plan

Small slices, each independently shippable:

**Slice 1** (OCaml, ~100 LOC): `<broker_root>/allowed_signers` write/append on `c2c register`. Format: one line, `<alias>@c2c.im ssh-ed25519 <base64-pubkey> # added <ISO-date>`. Append-only; never truncate.

**Slice 2** (OCaml, ~50 LOC, gated on guarded `c2c git` shim #122): extend the `c2c git` subcommand in `ocaml/cli/c2c.ml` — when `argv[0] = "commit"`, read `git.sign` config, resolve caller alias, inject `-c gpg.format=ssh -c user.signingkey=… -c gpg.ssh.allowedSignersFile=… -c commit.gpgsign=true -S` into the exec call. Also inject `--author` when `git.attribution=true` and no `--author` already in argv.

**Slice 3** (config, ~20 LOC): add `[git]` section to `<broker_root>/config.toml` schema with `sign` and `attribution` keys (default true).

**Slice 4** (tests, ~50 LOC): integration test — register a fresh alias, commit via `c2c git commit`, verify `git log --show-signature` returns `Good "ed25519" signature for "<alias>@c2c.im"`.

**Slice 5** (docs, ~30 lines): add a `## Commit signing` section to the relevant CLI doc + CLAUDE.md note for peers.

**Dependency**: Slices 2+ are blocked on #122 landing (guarded `c2c git` shim) — codex has the spec.

## Open questions

1. **SSH signing vs inline OpenPGP**: git supports both. SSH is simpler and matches our Ed25519 format natively. Recommendation: SSH. Any reason to prefer OpenPGP? (Probably not for us.)
2. **`allowed_signers` gossip**: should the relay distribute the swarm-wide `allowed_signers` snapshot so cross-machine verification works? Phase 2, not needed for single-machine swarm.
3. **Verification tooling**: `c2c verify-commits [<range>]` CLI that walks log, checks each signature against `allowed_signers`, flags unsigned commits? Nice-to-have, not MVP.
4. **What about rebases / cherry-picks**: do we want to re-sign rebased commits with the *rebaser's* alias, or preserve original signatures? Recommendation: preserve originals; sign only new commits. This is the git default for rebase `--exec`.

## Handoff

Ready for a coder to pick up slice 1 (allowed_signers on register). Slices 2+ wait on #122. Suggested implementer: fresh Claude Code or OpenCode session; OCaml tree familiarity needed but the existing `c2c register` code in `ocaml/cli/c2c.ml` is the obvious extension point.
