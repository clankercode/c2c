# c2c Website

This directory contains the Jekyll-powered GitHub Pages site for c2c.

## Build locally

```bash
cd docs
bundle install
bundle exec jekyll serve
```

If you see gem build failures (e.g. `tzinfo`, `securerandom`), install the
missing native dependencies first:

```bash
gem install tzinfo
gem install securerandom
```

Then re-run `bundle install`.

The site will be served at `http://127.0.0.1:4000`.

## Structure

- `_config.yml` — Jekyll / Minima configuration
- `assets/main.scss` — custom c2c swarm theme (dark by default, light via `prefers-color-scheme`)
- `_layouts/home.html` — custom homepage layout with hero section
- `_includes/head-custom.html` — favicon, fonts, meta tags
- `*.md` — content pages

## Deploy

Pushing to `master` triggers a GitHub Pages build automatically.
