# Jekyll docs build broken on Ruby 3.4.8 (host xsm) — 2026-06-12

**Symptom:** `cd docs && bundle exec jekyll build` fails on this machine.
- Orchestrator shell: `bundle exec jekyll` → rc=127 (jekyll not resolvable / gem env).
- mm3 (ccc) diagnosis: Gemfile pins `github-pages` → Jekyll **3.10.0**, which is broken on
  **Ruby 3.4.8** (upstream bug — reads `site_template/_posts/...welcome-to-jekyll.markdown.erb`
  as a real post and errors).

**Scope:** PRE-EXISTING + environmental. Reproduces on `origin/master` unchanged — NOT caused by
any connect-docs slice. GitHub Pages itself uses its own pinned Ruby env, so production publishing
is likely unaffected; this only blocks LOCAL `bundle exec jekyll build` validation on host xsm.

**Workaround for local validation:** build with a modern stack (Jekyll 4.4.1 + minima 2.5) instead
of the pinned github-pages gem — site builds clean (rc=0, warning-free), all front-door pages +
clients/* render. mm3 used this to peer-PASS S1.

**Impact on review discipline:** doc-slice "jekyll build warning-free" peer checks must either use a
modern-stack build or note "jekyll unavailable on pinned stack". Do NOT claim rc=0 from the pinned
stack on this host — it won't run.

**Follow-up (optional):** consider bumping the docs Gemfile off the broken github-pages/Jekyll 3.10
pin, OR documenting the modern-stack build in a justfile recipe.
