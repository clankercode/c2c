# GitHub Pages build silently broken for ~5 weeks (jekyll `{% link %}` to excluded `.collab/` doc)

**Discovered**: 2026-06-11T09:52Z by claude (Max's interactive session), while
deploying the new `/connect/` page.
**Severity**: HIGH — c2c.im served a **stale build** for ~5 weeks; every docs
change since ~2026-05-04 silently failed to publish.

## Symptom

Pushing docs changes to `origin/master` triggers `pages-build-deployment`, but
the live site never updated. `c2c.im/` and existing pages return **200** (so the
site *looks* up), masking that it's frozen on the last successful build. New
pages 404 indefinitely.

`gh run list` showed **every** `pages build and deployment` run since
2026-05-04 with conclusion **failure** (~38s each): runs 25313279684,
25325032320, 25362598771, 25420783684, and mine 27338536975.

## Root cause

`docs/MSG_IO_METHODS.md` used a Liquid `{% link %}` tag pointing at an
**internal** doc that is excluded from the published site:

```
See [`...kimi-notification-store-delivery.md`]({% link
.collab/runbooks/kimi-notification-store-delivery.md %}) for ...
```

Jekyll's core `{% link %}` tag **hard-errors the entire build** when the target
isn't a real site document:

```
github-pages 232 | Error: Could not find document
'.collab/runbooks/kimi-notification-store-delivery.md' in tag 'link'.
```

`.collab/` is outside `docs/` (the site source) and never published, so the tag
can never resolve. One bad tag = whole-site build failure.

Two more files had `[text](../.collab/...md)` / `[text](../../.collab/...md)`
relative links (`docs/MSG_IO_METHODS.md` "See Also", `docs/security/pending-permissions.md`).
Those don't fail the build (the relative-links plugin leaves out-of-site targets
alone) but render as **broken 404 links** for public readers.

## Fix

Converted all cross-site `.collab/` references in `docs/` from links/`{% link %}`
to **plain inline-code provenance** (the form already used correctly at
`MSG_IO_METHODS.md:406`), e.g. ``` `.collab/runbooks/...md` (internal) ```.
Files: `docs/MSG_IO_METHODS.md`, `docs/security/pending-permissions.md`.
Verified no `{% link %}`/`{% post_url %}` tags and no `](../…)` / `](.collab/…)`
links remain under `docs/`.

## Prevention

- **Never `{% link %}` (or markdown-link) an internal `.collab/` doc from
  `docs/`.** Use inline-code provenance — see `docs/CLAUDE.md` "Cross-doc link
  discipline": internal refs should be provenance trails, not clickable links.
- **`c2c.im` returning 200 does NOT mean the latest push deployed.** After a
  docs push, check `gh api repos/<owner>/<repo>/pages/builds/latest --jq .status`
  (or `gh run list`) for build success, and curl the *specific new path*.
- Consider a CI guard: grep `docs/**` for `{% link %}` and `](../` / `](.collab/`
  in a pre-push or Actions check, since one such link silently freezes the site.

## Status

FIXED (this branch). Build expected green on next push.
