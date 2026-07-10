# H7 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-h7-status-honesty`
- Tips: `c6297567` (fix) + `5c2d79b1` (http_status pin). Base `672bdae6`
  (F5b reviewed tip). Fixes defects 1 (B090) and 2 (C047), both
  F5b-reviewer-confirmed.
- **New Relay_client.request result contract** (documented in sig comment):
  1. 2xx → parsed body byte-identical passthrough (ok:true ONLY here).
  2. non-2xx + honest ok:false object body → passthrough, its own
     error_code/error win, annotated `http_status:<code>` (401/429/500
     matrix cells keep original codes — PoW flow depends on this).
  3. non-2xx + body NOT reporting ok:false → overridden ok:false,
     error_code=`http_error_<code>`, http_status, offending body preserved
     under `relay_response`.
  4. Transport failure → synthesized ok:false connection_error
     `transport:true`; new exported `Relay_client.is_transport_error`;
     request still never raises.
- **Doctor truth**: probe_relay folds transport-synthesized health into
  health=None + health_error → relay.reachable=FAIL ("relay unreachable"),
  relay.lease=INCONCLUSIVE, capabilities inherit reachable:=false. A
  500-serving relay is still reachable=PASS (it responded) — reviewer
  verified both directions.
- **Red→green**: both F5b FIXME skips converted (`http_5xx_ok_body_never_success`,
  `doctor_refused_reachable_fails`) with pre-fix RED reproduced. Matrix
  31 run / 0 skip, reviewer ran twice stable. Zero expectation changes to
  the 29 previously-green cells; `check_status_fault` gained an ADDED
  http_status pin.
- **Caller audit** (worker + reviewer): c2c_relay_cmd print_result_and_exit
  keys on ok (strictly benefits); pow_client is_pow_required on honest-branch
  429 body (all 6 PoW cells green, single-minted-retry intact); health/doctor/
  init/mesh/monitor/relay_state key on ok — unchanged success, more honest
  faults. H3's classify_relay_response (sibling branch) compatible on merge:
  dishonest 5xx peek becomes Peek_transient (safe default).
- Scope: exactly relay_client.ml, c2c_doctor_relay.ml,
  test_relay_fault_matrix.ml, docs/changelog.md. No dune edits. Connector's
  INLINE Relay_client (c2c_relay_connector.ml:577) deliberately untouched —
  same defect recorded as run issue (adjudicate H10/unification at J5/Q1).
- B098 untouched: approval suites 23+7 green, diff touches neither file.
- Live peer-PASS (independent opus reviewer, not author or its subagent):
  PASS first pass. Evidence IN slice worktree: reviewer's own
  `DUNE_WATCHDOG_TIMEOUT=900 just check` rc=0. Signed artifact
  `5c2d79b1-fable-warden.json` (v2, build_rc=0, all targets).
- Findings carried (nonblocking): LOW — a relay body could emit
  transport:true on 2xx making ITSELF look unreachable in doctor
  (fail-safe, diagnostic-only); probe_relay /list signed-path fallback
  swallows signing errors (`with e -> `Assoc []`, unused e); 3xx now
  http_error_3xx (redirects still not followed).
- Coordinator evidence-pass note: one transient catalog-check false-FAIL
  (nudge_tick) on first run, non-reproducible — finding
  `2026-07-10T09-10-00Z-fable-warden-catalog-check-transient-miss.md`
  (mirrored to main checkout).
