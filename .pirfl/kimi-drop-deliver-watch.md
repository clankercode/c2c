# PIRFL — kimi: stop emitting the stale deliver-watch.sh (#10)

## Goal
`c2c install kimi` wrote a `deliver-watch.sh` with the install-time `broker_root`
baked in and never regenerated it, so a reinstall in another repo left it pinned
to the previous broker root (#10). But kimi delivery is exclusively the REST
notifier (`c2c_start.ml` maps `"kimi" -> "notifier"`); the deliver-watch.sh
sidecar is never *started* for kimi. The artifact is inert AND staleness-prone.

## Decision (IGC / decisive)
- **A: regenerate deliver-watch.sh at `c2c start kimi`** — REFUTED: kimi never
  executes the script, so regenerating a never-run artifact keeps a misleading
  file for zero runtime benefit.
- **B: stop emitting it for kimi; remove any legacy script on (re)install; keep
  uninstall cleanup** — SURVIVES. Chosen.

## Changes
- `setup_kimi`: dropped `~deliver_watch`; the deliver-watch block now always
  removes any legacy `deliver-watch.sh` + `start-hooks/pre-deliver.sh` and emits
  no owned-file artifacts.
- `deliver_watch_clients` = `["opencode"; "agy"]` (kimi removed).
- `--no-deliver-watch` help text updated (kimi uses the REST notifier).
- `do_install_client` kimi branch + test helper drop `~deliver_watch`.
- `c2c uninstall kimi` unchanged — `recompute_kimi_artifacts` still lists the
  deliver-watch paths (known-path fallback) so legacy files are cleaned there too.

## Verification
- `test_c2c_setup_kimi` 22/22 (new: "setup_kimi removes legacy deliver-watch.sh (#10)").
- Dogfood: seeded a stale `deliver-watch.sh` in an isolated HOME, ran real
  `c2c install kimi` → both scripts removed, none written, install summary lists
  no deliver-watch artifact.
- Pending: adversarial review → PR.

Closes #10.
