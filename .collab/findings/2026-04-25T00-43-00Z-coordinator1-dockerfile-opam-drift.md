# Dockerfile opam install list drift from local opam env

- When: 2026-04-25 ~10:01-10:42 UTC+10 (during deploy of 9f700ed → c4b7db9)
- Who: coordinator1 (caught on push); jungle-coder (root-cause both fixes)
- Severity: Medium — held up production deploy 40min through 2 hotfixes
- Status: Fixed at 226ef47 (hacl-star) + c4b7db9 (cmake)

## Symptom

Pushed master to origin/master at 9f700ed expecting Railway build (~15min).
After 25 minutes, prod relay still reported old git_hash. Two consecutive
build failures in Railway, not visible to me from the relay endpoint
(only via Railway dashboard which jungle had access to).

## Root cause

Local dev opam env had transitively-installed deps (`hacl-star` and its
native build tooling `cmake`) that the Dockerfile's explicit opam install
list did not enumerate. The Dockerfile mirrors `dune-project`'s package
deps but isn't auto-generated from it.

When commit 218643c added `hacl-star` to `ocaml/dune`'s libraries (for
Ed25519 sticker signing in #170 work), the Dockerfile install list wasn't
updated. Build failure 1: `Unbound module Hacl_star`.

Fixing #1 by adding `hacl-star` to the Dockerfile opam install list
revealed #2: hacl-star's native build needs `cmake`, which wasn't in
the apt-get install list (added build-essential, pkg-config, etc but not
cmake).

## Fix

Two-line patch across two commits:
- `226ef47 fix(Dockerfile): add hacl-star to opam install list`
- `c4b7db9 fix(Dockerfile): add cmake — hacl-star native build requires it`

## Lessons

1. **Add a CI check for Dockerfile drift.** Either (a) auto-generate
   Dockerfile install list from `dune-project`, or (b) run a clean
   container build in CI on every push to PR/master. Right now
   "build locally + push" lets divergence sneak through to prod
   build-time only.

2. **Failure visibility gap.** I could see the relay was stale via
   `/health` but couldn't see WHY Railway failed without the dashboard.
   Jungle's access to the dashboard (or his ability to run a docker
   build locally and reproduce) was the unblocking factor. Worth
   either: (a) giving coordinator1 some Railway-status visibility tool,
   or (b) documenting "if push doesn't deploy in 20min, ask
   <peer-with-railway-access>" in the runbook.

3. **The `hacl-star` dep itself is correct** for #170 stickers (sticker
   signing uses Relay_identity → hacl-star backend for Ed25519 in pure
   OCaml). The drift was the Dockerfile not catching up with dune-project
   changes, not the dep choice.

4. **Hotfixes during a swarm-active deploy** — even with hotfixes, push
   policy worked: the second push didn't bypass review (it was urgent
   relay-fix), but the convention held. Standing authorization for
   coordinator-driven hotfixes makes this fast.

## Cross-links

- #170 stickers (added hacl-star)
- 218643c (added hacl-star to dune)
- 9f700ed (the push that surfaced the drift)
- 226ef47, c4b7db9 (the hotfixes)
