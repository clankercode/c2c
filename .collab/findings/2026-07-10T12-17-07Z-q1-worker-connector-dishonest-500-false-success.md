# Connector treats dishonest HTTP 500 + ok:true relay response as success (H7 gap)

- **Date:** 2026-07-10
- **Author:** q1-worker (friction-points-cn slice Q1, CLI error-contract matrix)
- **Severity:** medium (false-success reporting; only triggers against a *dishonest* relay — 5xx status with an `ok:true` JSON body)
- **Status:** OPEN — pinned as a FIXME runtime-skip in `tests/test_c2c_cli_error_contract.py` (`test_FIXME_dishonest_500_ok_true_is_treated_as_success`). NOT fixed in Q1 because `ocaml/c2c_relay_connector.ml` is owned by lane H9 (done/reviewed — cross-lane file, hands off per slice constraints).

## Symptom

Against a scripted fault relay that answers **HTTP 500 with body `{"ok": true, "results": []}`** on every route:

```
$ C2C_RELAY_URL=http://127.0.0.1:<fault-port> C2C_RELAY_TOKEN=tok c2c relay connect --once
[relay-connector] starting — relay=http://127.0.0.1:37913 node=... auth=token-only interval=30s
[relay-connector] sync: registered=2 heartbeated=0 fwd=0 failed=0 dlqed=0 inbound=0 alerts=0
$ echo $?
0
```

The connector reports `registered=2` and exits **0** — a false success. The same fault
relay pointed at the direct CLI paths (`c2c relay dm send`, `c2c relay register`,
`c2c relay status`) correctly yields exit 1 with:

```json
{ "ok": false, "error_code": "http_error_500",
  "error": "relay answered HTTP 500 but the body did not report ok:false",
  "http_status": 500, "relay_response": { "ok": true, "results": [] } }
```

## Root cause

H7 (commit c6297567) added HTTP-status honesty to `Relay_client` in `ocaml/relay.ml`:
a 5xx response whose body does not say `ok:false` is rewritten to an `ok:false` /
`http_error_5xx` envelope.

But `ocaml/c2c_relay_connector.ml` has its **own inline `Relay_client` module**
(around line 577, comment: "HTTP client (inline — minimal, matches Relay_client in
relay.ml)"). Its `request` function discards the response status entirely:

```ocaml
Cohttp_lwt_unix.Client.call ~headers ~body:body_payload meth uri
>>= fun (_resp, resp_body) ->            (* <- _resp (status) never inspected *)
Cohttp_lwt.Body.to_string resp_body >>= fun text ->
try Lwt.return (Yojson.Safe.from_string text)
with _ -> Lwt.return (connection_error "invalid_json_response")
```

So the connector's success/failure classification keys purely on the body's
`ok` field. The dispatcher note "H3's classify_relay_response keys on body
ok/error_code — H7's contract is compatible (dishonest 5xx becomes transient)"
holds only for calls routed through `ocaml/relay.ml`'s `Relay_client`; the
connector does not route through it, so H7's honesty guard never runs and the
dishonest 5xx is classified as *success*, not transient.

## Contrast cells (all verified 2026-07-10 against the Q1 tree, merge 806f0df9)

| relay behaviour | `relay dm send` / `relay register` / `relay status` | `relay connect --once` |
| --- | --- | --- |
| connection refused | exit 1, `connection_error` | exit 2, `last_error_op` recorded ✓ |
| 200 + malformed JSON | exit 1, `connection_error`/`invalid_json_response` | exit 2 ✓ |
| 200 + `ok:false` | exit 1, error_code passthrough | exit 2 ✓ |
| **500 + `ok:true`** | exit 1, `http_error_500` (H7 ✓) | **exit 0, registered counted — FALSE SUCCESS ✗** |

## Suggested fix (for the owning lane / a follow-up slice)

Mirror H7's honesty check in the connector's inline `Relay_client.request`:
inspect `Cohttp.Response.status _resp`; when status >= 400 and the parsed body
does not report `ok:false`, synthesize the `http_error_<n>` ok:false envelope
(same shape as `ocaml/relay.ml` post-H7). Then the existing H3
`classify_relay_response` will classify it transient, `--once` exits 2, and
`connector-state.json.last_error_*` records it.

## Repro

`tests/test_c2c_cli_error_contract.py::ConnectorNegativeContractTests::test_FIXME_dishonest_500_ok_true_is_treated_as_success`
self-skips (loudly) while the defect is present and becomes an enforcing test
the moment the connector is fixed.
