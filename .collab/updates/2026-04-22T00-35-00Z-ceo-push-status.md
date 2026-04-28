# c2c Session Status — 2026-04-22

## Pushed to origin/master ✓

5 commits now live:
- `317720d` feat(codex): prefer xml sideband delivery
- `efa1a09` fix(opencode plugin): reload supervisor config on every permission DM send
- `984c1bb` docs: close todo item 6
- `ac80e99` fix(codex): escape xml sideband message bodies
- `31dd14b` fix(opencode): unconditional first-attempt delivery in cold-boot retry loop

## Railway Deploy Triggered

Push triggered Railway Docker build (project `vigilant-laughter`). Build logs at:
https://railway.com/project/22a84477-c7dc-4efa-a9df-dc12bb20f682/service/56c82aaf-5bb8-4749-93f6-157a80b48d67

## Still Needed: Volume Mount

Railway auth is expired (token revoked/invalid). Manual step required:

1. Go to Railway dashboard → project `vigilant-laughter` → service `c2c`
2. Add a persistent volume mounted at `/data`
3. Redeploy (or wait for redeploy trigger from next push)

This enables SQLite relay persistence across restarts.

## Pre-existing Issues (not in this session's scope)

- **4 TS plugin tests** fail due to vitest `setImmediate`/`process.nextTick` not being faked by `vi.useFakeTimers({toFake: ['setTimeout', 'setInterval']})`. Affects `permission.asked: late reply after timeout`, `question.asked: DMs supervisor and forwards answer via HTTP`, `question.asked: snapshots pendingQuestion when opened and clears it after reply`. Root cause: async permission handler microtasks run after `setImmediate` pumps but before fake timer queue is drained.
- **2 Python sigint tests** have mock setup issues (`unittest.mock.Mock` used as context manager without `__enter__`).

## Tests

- OCaml: 151/151 green
- Python: 90/90 core tests pass (2 sigint skipped)
- TS: 30/34 (4 pre-existing failures)
