# TOFU pin-save / pin-rotate audit (HEAD ~00b9952d)

Read-only audit, scope: `Peer_review.Trust_pin` pin store + `pin_check` /
`pin_rotate` (`ocaml/peer_review.ml`), broker enforcement and in-memory
x25519/ed25519 hashtables (`ocaml/c2c_mcp.ml`), CLI rotate path
(`ocaml/cli/c2c_peer_pass.ml`). Mapped against the six audit
questions. Severity: CRIT / HIGH / MED / LOW / NIT / OK.

## Two distinct pin layers (clarifying frame)

The audit prompt conflates two pin systems that actually exist
side-by-side. Findings cite both.

1. **Persistent peer-pass pin store** — `peer-pass-trust.json` at
   `<broker_root>/`, owned by `Peer_review.Trust_pin`. Used for
   peer-PASS artifact ed25519 identity (H1 / H2b). Disk-backed,
   flock-protected, atomic-rename, audit-logged. This is what the SPEC
   calls "TOFU pin".
2. **In-memory relay-e2e pin tables** — `Broker.known_keys_x25519` and
   `known_keys_ed25519` (Hashtbl.t), `Broker.tofu_mutex` (per-alias
   `Lwt_mutex`), `Broker.tofu_sync_mutex` (one global `Mutex.t`). Used
   by `relay_e2e` envelope decrypt + outbound encrypt. Process-local;
   reset on every broker restart. NOT what the SPEC calls TOFU and
   NOT what `pin_rotate` rotates.

The audit prompt's "tofu_mutex" is layer 2; "pin_save / pin_rotate /
peer-PASS verification" is layer 1. They never share state today.

---

## 1. CRIT — In-memory x25519/ed25519 pins are NOT persisted across broker restart

`c2c_mcp.ml:802-809` — `known_keys_x25519`/`known_keys_ed25519` are
plain `Hashtbl.t`. There is no load-on-startup, no save-on-write, and
no link to `Trust_pin.save`. Every `Broker.pin_x25519_sync` /
`pin_ed25519_sync` (call sites at `c2c_mcp.ml:3669, 4812, 4815, 5243`)
mutates the table only.

**Effect**: every broker restart silently downgrades x25519 first-seen-wins
to "first-seen-this-process". An attacker who can race a fresh-key DM
against the first poll after restart wins the pin. This trivially
defeats the "first-seen-wins" guarantee implied by Q4. Note: this is
the relay-e2e identity layer, not the peer-PASS layer (#1 above), but
the SPEC at `2026-04-29-message-e2e-encryption-cairn.md:210` describes
this layer as the user-visible TOFU surface for messaging.

**Severity**: CRIT for the messaging-encryption threat model; the
peer-PASS layer is unaffected because it uses the disk-backed store.

## 2. OK — `Trust_pin.save` is tmp+rename atomic AND fsync-on-write is partial

`peer_review.ml:577-585`. Writes `<path>.tmp`, then `Sys.rename`. The
`open_out` + `output_string` + `close_out` sequence flushes via
`close_out`, but there is **no explicit `Unix.fsync` on the tmp fd
before rename** (the post-H2b audit at
`.collab/findings/2026-04-28T20-25-00Z-stanza-coder-peer-pass-audit-post-h2b.md`
flagged this; #54 was scoped to flock and the fsync gap was not
closed). On crash between rename and disk-flush the pin store can
revert to a pre-rename inode state. Not exploitable in the current
threat model but worth noting.

**Severity**: LOW (correctness gap, not security exposure).

## 3. OK — Cross-process flock on pin-store IS in place (#54 / #409)

`peer_review.ml:553-575` `Trust_pin.with_pin_lock` does
`Unix.lockf … F_LOCK` on `<path>.lock` and the **entire**
load→decide→save sequence in `pin_check` (`:646`) and `pin_rotate`
(`:686`) runs inside it. This closes the cross-process lost-update
window the post-H2b audit flagged. Verified: there are no direct
`Trust_pin.save` callers outside `with_pin_lock` (the function
itself self-locks at `:578`).

## 4. HIGH — `pin_rotate` does NOT require a valid signature

`peer_review.ml:680-709`. Compare with `pin_check` which is documented
as "the artifact's signature MUST already have been verified by
[verify] before calling this" (`:631-633`) — but neither function
calls `verify` itself. The CLI rotate path
(`cli/c2c_peer_pass.ml:497`) gates on `Peer_review.verify art`
returning `Ok true` before invoking `pin_rotate`, so today's only
caller is safe. **But the API trusts the caller**: any future
broker/MCP/CLI code path that calls `Peer_review.pin_rotate` on an
unverified artifact silently rotates the pin. The post-H2b audit
(line 107) called this out as a test gap; it remains a test gap.

**Recommendation**: bake `verify art >>= pin_rotate` into a single
`pin_rotate_verified` and deprecate the unchecked entry point.

**Severity**: HIGH (latent footgun; one wrong caller = silent pin
flip on attacker-supplied artifact).

## 5. MED — No authorization / attestation gate on `pin_rotate`

Q3 asks: "does the broker require a specific signature or attestation
before accepting a rotation?" — **No**. Rotation is operator-only by
convention (`c2c peer-pass verify --rotate-pin` is the documented
path, run by a human or coord-agent), and the broker has no
`mcp__c2c__rotate_pin` tool today, so the only attacker path requires
shell access on the host. The audit log (`#55`,
`c2c_mcp.ml:3523-3547`) provides forensic detection, not prevention.

This matches the SPEC ("Rotation: only the operator-driven … path can
replace an existing pin; the broker never auto-rotates",
`SPEC-signed-peer-pass.md:52-53`). **But there's no defense-in-depth
guard**: the function is plain `Peer_review.pin_rotate`, not
`pin_rotate ~operator_token:…`. If a future MCP rotate tool lands
without auth gating (issue prompt explicitly mentions "future MCP
rotate-pin tool" at `c2c_mcp.ml:3520`), the rotation is wide open.

**Severity**: MED (today's attack surface = local shell; tomorrow's
= broker MCP tool unless someone adds the gate).

## 6. OK — Strict-mode rejects fresh-key DM after legit pin

`c2c_mcp.ml:4854-4902` + `peer_review.ml:755-773`. On send,
`verify_claim_with_pin` returns `Claim_invalid` for `Pin_mismatch`,
and the broker rejects the DM (does NOT enqueue). `log_peer_pass_reject`
fires (`c2c_mcp.ml:4887`). User-facing message is generic
("forged or pin-mismatched"); detailed reason goes to broker.log.
Verified by `test_peer_pass_dm_h2b_fresh_key_forgery_rejected`
(`test_c2c_mcp.ml:8299`).

## 7. OK — Audit log fires for both first-pin and replace

`peer_review.ml:697-708` + `c2c_mcp.ml:3556-3565`. Hook fires inside
`pin_rotate` post-save with `prior_first_seen=None` for first-pin and
`Some _` for replace. The hook is set at module-init time via
`set_pin_rotate_logger` so any caller of `pin_rotate` produces a
broker.log line — verified by
`test_pin_rotate_log_writes_json_line_under_pin_dir`. Hook errors are
swallowed (`try … with _ -> ()`) so a logger crash cannot block
rotation; this is correct (audit failure must not deny service).

## 8. OK — Peer-PASS verification correctly drives off the pinned pubkey

`verify_claim_for_artifact` (`peer_review.ml:755`) requires
`Pin_first_seen | Pin_match` for `Claim_valid`. A racy pin rotation
would not "silently flip TOFU validity" because (a) rotation is
serialized inside `with_pin_lock`, (b) post-rotation the new pubkey is
on disk before any subsequent verify reads it, and (c) `pin_check`
inside `verify_with_pin` runs in the same lock window. Q6's specific
worry (peer-PASS sign relies on TOFU pin → racy rotation → silent
flip) does not materialize for the disk-backed peer-PASS layer.

## 9. NIT — In-memory relay-e2e pins use two different mutexes

`c2c_mcp.ml:792-856`. `pin_x25519_if_unknown` uses per-alias
`Lwt_mutex`; `pin_x25519_sync` uses a single global `Mutex.t`. Both
mutate the same `known_keys_x25519` Hashtbl. A concurrent
Lwt-context call into `pin_x25519_if_unknown` and a sync-context call
into `pin_x25519_sync` for the same alias do NOT serialize against
each other. Probability of harm low (writes are idempotent for
matching pk, divergent for mismatch — and mismatch is the rare path),
but the locking discipline is inconsistent. Combined with finding #1,
the layer needs a redesign anyway (persistent backing + one mutex
hierarchy).

**Severity**: LOW (theoretical; finding #1 dwarfs it).

## 10. OK — All disk pin-write paths go through `with_pin_lock`

Verified by grep: every `Trust_pin.save` callsite is inside
`with_pin_lock` (either via `pin_check`/`pin_rotate` or via the
function's self-lock at `:578`). No bypass paths. Q1 answered for the
peer-PASS layer.

## 11. OK — `Pin_mismatch` does not write the pin (correctness)

`peer_review.ml:663-669`. The mismatch branch returns the
`Pin_mismatch` record without any `Trust_pin.upsert`/`save`. The
attacker cannot "poison" the pin store by triggering a mismatch.
First-seen-wins discipline holds at the disk layer.

---

## Top-3 actionable items

1. **CRIT #1**: persist `known_keys_x25519`/`known_keys_ed25519` to
   disk (sibling to `peer-pass-trust.json`), or at minimum document
   loud-and-clear that messaging-layer TOFU resets per-process. The
   SPEC implies persistence; the code does not deliver it. Filing
   suggested.
2. **HIGH #4**: fold `verify` into `pin_rotate` so the API cannot be
   misused by a future caller. ~10 LoC + a test that calls
   `pin_rotate` on a tampered artifact and asserts no rotation.
3. **MED #5**: when an MCP `rotate_pin` tool is added (referenced as
   future work in `c2c_mcp.ml:3520-3521`), require an attestation —
   either a fresh artifact signed by BOTH old and new keypairs, or a
   side-channel operator confirmation. Document the requirement in
   the SPEC before the tool ships.

## Files cited

- `/home/xertrov/src/c2c/ocaml/peer_review.ml` (Trust_pin, pin_check, pin_rotate, verify_with_pin)
- `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml` (Broker pin tables, broker-side enforcement, audit logger)
- `/home/xertrov/src/c2c/ocaml/cli/c2c_peer_pass.ml` (CLI rotate path)
- `/home/xertrov/src/c2c/.collab/design/SPEC-signed-peer-pass.md`
- `/home/xertrov/src/c2c/.collab/findings/2026-04-28T20-25-00Z-stanza-coder-peer-pass-audit-post-h2b.md` (prior audit; closed/open status updated above)
