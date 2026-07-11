# Root Python file usage audit

> **SUPERSEDED for product decisions by**  
> `.collab/research/2026-07-11T17-30-00Z-b123-deprecated-python-user-facing-audit.md`  
> (B123, 2026-07-11). That audit classifies by **user-facing product path**, not "is imported".

This file retains the older inventory for archaeology. Its "keep" recommendations are **stale** — OCaml `c2c` is canonical; root wrappers now **refuse** (B123) unless `C2C_ALLOW_PYTHON_LEGACY=1`.

---

## Prior audit (stale methodology)

Repo root: `/home/xertrov/src/c2c`  
Scope: `*.py` files directly in the repo root.

### Old methodology (wrong axis for B123)

For each root `*.py` file the prior pass searched for imports, wrappers, Docker, docs, and tests, then marked **used** → **keep**. That preserves test-backed code but fails the product rule: *Python is OK in tests, not user-facing*.

### Old summary

- Total root `*.py` files: **61** (then)
- Used: **55** → recommended keep (stale)
- Unused: **6** — moved under `deprecated-python/`

### B123 status (2026-07-11)

| Surface | Status |
|---------|--------|
| Root `c2c-*` wrappers | Refuse with OCaml pointer (exit 2) |
| `just install-python-legacy` | Refuse unless `C2C_ALLOW_PYTHON_LEGACY=1` |
| `c2c_install.py` | Same refuse |
| Repo `./c2c` shim | Native-first |
| `Dockerfile.agent` | OCaml `c2c` + `c2c-deliver-inbox` only |
| Survival-guide recipes | Point at OCaml CLI |
| Root `*.py` modules | Retained for tests; not installed on PATH by `just install-all` |

See the research note for the full classification table and residual list.
