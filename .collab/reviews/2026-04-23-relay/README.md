# Relay codebase structured review — 2026-04-23

**Trigger**: Max asked for structured reviews over the relay web-service surface before planning actionable items.
**Commissioned by**: Cairn-Vigil (coordinator1) 2026-04-23.
**Scope**: `ocaml/relay*.ml` (~5,400 LOC) + `ocaml/c2c_relay_connector.ml` + `ocaml/test/test_relay*.ml`.

## Files (review-per-concern)

Each reviewer saves its findings to one file, focused on one concern. Parallel dispatch; synthesis lands in `synthesis.md` after all complete.

| File | Focus |
|------|-------|
| [security.md](security.md) | Auth surfaces, sig verify, rate-limit bypass, input validation, injection, TLS/cert, token handling, replay defence, TOFU correctness, secret material leakage. |
| [correctness-concurrency.md](correctness-concurrency.md) | Race conditions, SQLite transaction atomicity, resource leaks (fd/sockets), error-handling fallthroughs, atomic file ops, CAS correctness, crash recovery. |
| [api-design.md](api-design.md) | Endpoint consistency, HTTP status codes, error response shapes, versioning, backward compat, REST ergonomics, content-type handling. |
| [observability.md](observability.md) | Logging coverage, structured-log consistency, metrics/counters, debug surfaces, failure visibility, correlation IDs, operator runbook gaps. |
| [performance-scalability.md](performance-scalability.md) | Hot paths, quadratic patterns, N+1 DB access, memory footprint, LRU/cache sizes, per-request allocation, blocking I/O in Lwt threads. |
| [testing-coverage.md](testing-coverage.md) | What's not tested, missing negative/edge cases, integration gaps, fuzz/property opportunities, brittleness (over-asserts). |

Each file uses the same structure:
- **TL;DR** (2-3 lines)
- **Critical findings** (actionable, prioritized)
- **Important findings**
- **Minor / nits**
- **What's strong**
- **Scope of review** (files read, approximate LOC covered)

## Synthesis

After all six land, `synthesis.md` will:
- De-duplicate overlapping findings
- Rank by impact × effort
- Propose a prioritized action plan mapped to existing or new M1/M2 slices
