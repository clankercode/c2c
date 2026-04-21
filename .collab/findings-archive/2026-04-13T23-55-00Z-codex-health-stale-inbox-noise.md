# Health Stale Inbox Noise

- **Symptom:** `c2c health --json` reported every thresholded inbox in a single
  `stale` list, mixing live sessions that may need a wake with retained broker
  artifacts from dead proof sessions.
- **Discovered by:** After stabilizing Kimi Wire daemon presence, live health
  still showed a stale proof inbox (`kimi-start-proof-codex2`) beside real
  queued inboxes.
- **Root cause:** `check_stale_inboxes()` counted inbox files without checking
  whether their session still had a live broker registration. That made dead or
  unregistered inbox files look like actionable delivery failures.
- **Fix status:** Fixed in `c2c_health.py`. Health now returns actionable live
  stale inboxes in `stale` and dead/unregistered thresholded inbox files in
  `inactive_stale`, while preserving `total_pending`. No-registry legacy/test
  broker roots keep the old behavior and still report unknown thresholded
  inboxes as actionable stale.
- **Severity:** Medium. The data was retained safely, but the operator signal
  was noisy enough to send agents toward stale proof artifacts instead of live
  delivery work.
