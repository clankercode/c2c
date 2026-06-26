# Finding: docs `head-custom.html` was orphaned (not included) — theme-color silently dead

**Severity:** low (cosmetic/SEO), but a latent footgun for anyone adding to head-custom.
**Discovered during:** OG social-card slice (wiring og:image/twitter meta tags).

## Symptom
Adding meta tags to `docs/_includes/head-custom.html` had zero effect on the
built `<head>`. The file's existing `theme-color` + font `<link>`s were also
absent from every built page.

## Root cause
The repo ships a LOCAL `docs/_includes/head.html` that overrides minima's
stock head include. The stock minima head ends with
`{%- include head-custom.html -%}`; the local override dropped that line.
So `head-custom.html` was dead code — nothing included it. (Fonts still
worked only because `docs/assets/main.scss` `@import`s them directly.)

## Also relevant
`jekyll-seo-tag` is active (in `_config.yml` plugins) and already emits
`og:title/description/url/site_name/type`, `twitter:card`, `twitter:title`.
Naively emitting the full OG set in head-custom would have produced duplicate
tags. seo-tag reads `image` from PAGE front matter (not `site.image`), so a
per-page `defaults: image:` is the canonical way to get absolute
`og:image`/`twitter:image` + a `summary_large_image` upgrade.

## Fix applied (in OG-card slice)
- `head.html`: re-added `{%- include head-custom.html -%}` (favicon now sourced
  once from head-custom; removed the duplicate from head.html).
- `_config.yml`: `defaults: [{scope:{path:""}, values:{image: /assets/og-image.png}}]`.
- `head-custom.html`: only the supplemental tags seo-tag omits
  (og:image:type/width/height/alt, twitter:description, twitter:image:alt).
- Verified: built `<head>` has every OG/Twitter tag exactly once, all absolute.

## Next-agent takeaway
If you add anything to `docs/_includes/head-custom.html`, confirm it actually
renders (`bundle exec jekyll build` + grep `_site/`). The local `head.html`
override is the source of truth for what's in `<head>`.
