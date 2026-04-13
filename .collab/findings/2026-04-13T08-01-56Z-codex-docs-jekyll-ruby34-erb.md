# Docs Jekyll Build Fails On Ruby 3.4 Without Explicit `erb`

- **Time:** 2026-04-13T08:01:56Z
- **Reporter:** codex
- **Severity:** medium for docs/site verification

## Symptom

After the c2c.im docs redesign, `bundle exec jekyll build` failed before
rendering pages:

```text
cannot load such file -- erb (LoadError)
```

The host also did not have `bundle` on PATH initially, so the first build
attempt failed with `bundle: command not found`.

## Discovery

I tried to verify the redesigned docs site from `docs/` using the committed
`Gemfile`. Ruby and RubyGems were installed, but Bundler was missing. After
installing Bundler in the user gem path and installing dependencies with
`BUNDLE_PATH=vendor/bundle`, Jekyll failed on `require "erb"`.

## Root Cause

This host is running Ruby 3.4, where parts of the standard library that older
Jekyll/GitHub Pages stacks assume are always available can require explicit gem
activation. Jekyll 3.10 loads `jekyll/commands/new.rb`, which requires `erb`.
The docs `Gemfile` did not declare `erb`.

## Fix Status

Fixed locally:

- Added `gem "erb"` to `docs/Gemfile`.
- Ignored local Bundler install directories (`docs/vendor/`, `docs/.bundle/`) so
  site verification does not pollute git status.

## Verification

Run from `docs/`:

```bash
BUNDLE_PATH=vendor/bundle /home/xertrov/.local/share/gem/ruby/3.4.0/bin/bundle install
BUNDLE_PATH=vendor/bundle /home/xertrov/.local/share/gem/ruby/3.4.0/bin/bundle exec jekyll build
```

The first command installed dependencies locally. The second command completed
successfully after the `erb` dependency was installed.

## Residual Risk

Bundler itself was installed into `/home/xertrov/.local/share/gem/ruby/3.4.0/bin`,
which is not currently on PATH. Future agents can either call it by full path or
add that directory to PATH before running docs builds.
