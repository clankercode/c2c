<!-- Spec for the c2c `--cross-repo` flag + send-identity UX.
Author: cc-pi-c2c (coordinator in the pi-c2c repo), via a read-only investigation workflow.
For: pi-2315bf to implement. Line numbers are vs c2c HEAD 1218c307 — VERIFY before editing (code may have shifted). -->

Decisive finding that overturns the investigation notes' premise: the sessions broker **does** carry a `registry.json` with ~180 alias registrations (populated by the pi-c2c extension registering into the sessions broker — see pi-c2c `src/index.ts:552-555`). So `list_registrations` against the sessions broker returns real cross-repo peers, and `c2c list --cross-repo` is meaningful. `register --cross-repo` also makes sense (it would write a registration into the sessions broker, which is what pi-c2c already does programmatically).

I have everything. Writing the spec.

---

# IMPLEMENTATION SPEC — `--cross-repo` flag + UX fixes for `c2c` CLI

**Target repo:** `/home/xertrov/src/c2c` (OCaml). **HEAD:** `1218c307`.
**Primary file:** `ocaml/cli/c2c.ml`. **Resolver file:** `ocaml/c2c_repo_fp.ml`.
**Executor:** agent `pi-2315bf`. **Note to executor:** do NOT use `attn`; report to coordinator.

## 0. Ground-truth corrections (read first — they change the design)

The investigation notes contain two load-bearing errors. Verified against live source + on-disk state:

1. **`monitor` IS a cmdliner subcommand.** Defined `c2c.ml:3544` (`monitor_cmd`), registered `c2c.ml:4173`. Lens 3 was wrong. It uses `Cmdliner.Term.const`/`Arg` style (NOT `let+ … and+`), and already resolves a broker root: explicit `--broker-root`/`--root` arg → `C2C_MCP_BROKER_ROOT` env → `resolve_broker_root ()` (`c2c.ml:3600-3619`).

2. **The sessions broker carries a real `registry.json` with alias registrations.** Verified on disk: `~/.c2c/sessions/broker/registry.json` exists, ~43 KB, ~180 entries with `session_id`/`alias`/`canonical_alias`/`cwd`. These are written by the pi-c2c extension (`src/index.ts:552-555`), not by the OCaml CLI today. Consequence: `Broker.list_registrations` (`c2c_broker.ml:1210`, reads `registry.json` at `:35`) returns meaningful peers when pointed at the sessions broker. So `list --cross-repo` and `register --cross-repo` are both well-defined. (Lens 2's "sessions broker holds no registrations" was true for the OCaml send path only; the TS extension populates it.)

3. **Naming collision: `--sessions` is a bad alias.** A `sessions` subcommand already exists (`c2c.ml:832`) that lists the **per-repo** broker's registrations. Aliasing `--cross-repo` to `--sessions` invites "is `--sessions` the same as `sessions`?" confusion. **Recommendation: use `--cross-repo` only, with `--global-broker` as the secondary alias if one is wanted.** Keep `-g`/`--global` reserved for the existing repo-fingerprint scanner (`c2c.ml:617`). → **DECISION NEEDED** (see §6 Q1).

## 1. Shared Arg term + resolver helper (do this first)

### 1a. New resolver alias (`c2c.ml`, near line 49)

`resolve_sessions_broker_root` already lives in `c2c_repo_fp.ml:121` and is reachable as `Repo_fp.resolve_sessions_broker_root` (the alias `module Repo_fp = C2c_repo_fp` is at `c2c.ml:21`; used at `c2c.ml:531`). No new resolver code needed.

Add a single precedence helper next to `resolve_broker_root` (`c2c.ml:49`):

```ocaml
(* Effective broker root for a subcommand, honoring --cross-repo.
   Precedence: explicit --root/--broker-root arg  >  --cross-repo  >  C2C_MCP_BROKER_ROOT env  >  per-repo default. *)
let resolve_effective_broker_root ?(explicit_root : string option = None) ~cross_repo () =
  match explicit_root with
  | Some r when String.trim r <> "" -> String.trim r          (* 1. explicit flag wins *)
  | _ ->
      if cross_repo then Repo_fp.resolve_sessions_broker_root () (* 2. --cross-repo *)
      else resolve_broker_root ()  (* 3+4. resolve_broker_root already does env then per-repo default *)
```

Note: `resolve_broker_root` (`c2c.ml:49` → `c2c_repo_fp.ml:94`) already encapsulates the env→default tiers (and the legacy-path guard at `c2c_repo_fp.ml:99-109`). Do NOT re-read `C2C_MCP_BROKER_ROOT` in the helper — let `resolve_broker_root` own it, so the precedence is exactly: explicit-arg > cross-repo > (env > default). This matches the prompt's recommended order.

### 1b. Shared cross-repo flag term (`c2c.ml`, near `json_flag` at line 230)

```ocaml
let cross_repo_flag =
  Cmdliner.Arg.(value & flag & info [ "cross-repo"; "global-broker" ]
    ~doc:"Target the cross-repo sessions broker ($(b,~/.c2c/sessions/broker)) instead of \
          this repo's per-repo broker. Auto-resolves the rendezvous root \
          (override with $(b,C2C_SESSIONS_BROKER_ROOT)); no manual \
          $(b,C2C_MCP_BROKER_ROOT) needed. An explicit $(b,--root) still wins.")
```

This is the single reusable term for `list`, `send`, `register` (all use `let+ … and+`). `monitor` uses `const`/`Arg` style and can reuse the **same `cross_repo_flag` Arg value** directly (it is a plain `bool Cmdliner.Term.t`) — see §1c.

### 1c. Edge case — `--cross-repo` + explicit `--root` together (monitor only)

`monitor` already has `--broker-root`/`--root` (`c2c.ml:3548`). Per precedence, explicit `--root` must win. Implement by passing `~explicit_root:broker_root_arg ~cross_repo` into the helper. For `list`/`send`/`register` there is NO `--root` flag, so `explicit_root` is always `None` there.

## 2. Change 1 — `--cross-repo` on `list`, `send`, `monitor`, `register`

### 2a. `list_cmd` (`c2c.ml:609`)

- **Add to the `let+ … and+` block (`c2c.ml:625-629`):** add `and+ cross_repo = cross_repo_flag in`.
- **Edge: mutual exclusion with `--global`.** `--global` (`c2c.ml:617`) scans per-repo roots; `--cross-repo` targets the sessions broker. They are different sources. Guard immediately after the binders:
  ```ocaml
  if global && cross_repo then begin
    Printf.eprintf "error: --global (scan per-repo brokers) and --cross-repo (sessions broker) are mutually exclusive.\n%!";
    exit 2
  end;
  ```
- **Wire the single-broker branch (`c2c.ml:758-759`):** replace
  `let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in`
  with
  `let broker = C2c_mcp.Broker.create ~root:(resolve_effective_broker_root ~cross_repo ()) in`
- The empty-list branch (`c2c.ml:761-764`) is also where Change 2 (§3) plugs in — but only when `not cross_repo` (no point hinting at the sessions broker when you're already on it).

### 2b. `send_cmd` (`c2c.ml:383`)

- **Add binder (`c2c.ml:420-428`):** `and+ cross_repo = cross_repo_flag in`.
- **Edge: interaction with `--session`.** `--session` already forces the sessions broker for delivery (`c2c.ml:528-534`). `--cross-repo` instead changes which broker the **alias→recipient** resolution and `enqueue_message` use. They are compatible but the common cross-repo case is "send to an alias registered in the sessions broker":
  - **`` `Alias `` path (`c2c.ml:503-527`):** the `broker` created at `c2c.ml:430` must become cross-repo-aware. Change `c2c.ml:430`:
    `let broker = C2c_mcp.Broker.create ~root:(resolve_effective_broker_root ~cross_repo ()) in`
    This makes both `resolve_alias`/`validate_from_override` (sender identity, `c2c.ml:447-468`) AND the recipient `enqueue_message` (`c2c.ml:510`) use the sessions broker — correct, because the recipient's registration lives there.
  - **`` `Session `` path (`c2c.ml:528-534`):** already uses the sessions broker explicitly. With `--cross-repo` the `broker` at `:430` is now also the sessions broker, so sender-identity resolution becomes consistent (today `--session` resolves identity against the per-repo broker at `:430` but delivers to the sessions broker — a latent inconsistency `--cross-repo` cleanly fixes). Leave the `:529-532` explicit `sessions_broker` create as-is (harmless; same root).
- **Edge: self-send guard (`c2c.ml:504-507`)** compares `from_alias`/`to_alias` strings — unaffected by broker choice.

### 2c. `monitor_cmd` (`c2c.ml:3544`)

- **Add Arg + thread into `const`:** monitor builds args explicitly. Add `let cross_repo = cross_repo_flag in` among the arg lets (e.g. after `c2c.ml:3598`), add `cross_repo` as a parameter of the `const (fun … )` at `c2c.ml:3600`, and add it to the `$ ... $ cross_repo` application list at the term assembly (search for the `Term.(const … $ json_flag $ …)` block following `c2c.ml:3640+`; add `$ cross_repo` in the same positional order as the new fun param).
- **Wire the resolver (`c2c.ml:3600-3619`):** replace the whole `broker_root` resolution block with:
  ```ocaml
  let broker_root =
    let resolved value_opt =
      match value_opt with Some s when String.trim s <> "" -> Some (String.trim s) | _ -> None
    in
    match resolved broker_root_arg with
    | Some r -> r                                   (* explicit --root wins *)
    | None ->
        if cross_repo then Repo_fp.resolve_sessions_broker_root ()  (* --cross-repo *)
        else (match C2c_utils.trimmed_env_value "C2C_MCP_BROKER_ROOT" with
              | Some r -> r
              | None -> (try resolve_broker_root () with _ ->
                  Printf.eprintf "c2c monitor: cannot resolve broker root \
                    (set C2C_MCP_BROKER_ROOT or run from inside the repo)\n%!";
                  exit 1))
  in
  ```
  (Cannot use the §1a helper verbatim here because monitor keeps the empty-string-env special-case and the custom failure message; the precedence is identical.)
- **Edge: `--alias` default (`c2c.ml:3620-3624`).** Monitor defaults `my_alias` to `C2C_MCP_SESSION_ID`. In the cross-repo dogfood the verifier passes `--alias <me>` explicitly, so this is fine; but document that without `--alias`, cross-repo monitor watches the inbox for your session-id in the sessions broker (the rendezvous keying) — which is exactly the intended cross-repo receive path.
- **Edge: per-alias lockfile (`c2c.ml:3625-3633`)** is keyed under `<broker_root>/.monitor-locks/<alias>.lock`. With cross-repo it correctly moves to the sessions broker root — no change needed, but note two monitors (per-repo + cross-repo) for the same alias now get **separate** locks (different roots), which is desired.

### 2d. `register_cmd` (`c2c.ml:3118`)

- **Recommendation: ADD it.** It is meaningful and matches what the pi-c2c extension already does programmatically (registers the alias into the sessions broker so cross-repo peers can resolve it). Without a CLI `register --cross-repo`, a human operating the bare CLI cannot make themselves discoverable cross-repo.
- **Add binder (`c2c.ml:3128-3131`):** `and+ cross_repo = cross_repo_flag in`.
- **Wire (`c2c.ml:3132`):** replace
  `let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in`
  with
  `let broker = C2c_mcp.Broker.create ~root:(resolve_effective_broker_root ~cross_repo ()) in`
- **Edge:** registration into the sessions broker writes `<session_id>` keyed registration + alias into `sessions/broker/registry.json`. This is additive and idempotent (same `add_registration` path). No per-repo state is touched when `--cross-repo` is set. → **DECISION NEEDED** whether register should write BOTH roots (§6 Q2). Default in this spec: cross-repo writes ONLY the sessions broker.

## 3. Change 2 — empty `c2c list` hints at the sessions broker

**Location:** the per-repo empty branch, `c2c.ml:761-764`:
```ocaml
if regs = [] then (
  match output_mode with
  | Json -> print_json (`List [])
  | Human -> Printf.printf "No registered peers.\n")
```

**Replace the `Human` arm** (only when `not cross_repo`, so we never hint while already cross-repo). Compute the alive count on the sessions broker cheaply:

```ocaml
| Human ->
    if cross_repo then Printf.printf "No registered peers on the sessions broker.\n"
    else begin
      let n_alive =
        try
          let sb = C2c_mcp.Broker.create ~root:(Repo_fp.resolve_sessions_broker_root ()) in
          C2c_mcp.Broker.list_registrations sb
          |> List.filter (fun r -> C2c_mcp.Broker.registration_liveness_state r = C2c_mcp.Broker.Alive)
          |> List.length
        with _ -> 0
      in
      if n_alive > 0 then
        Printf.printf
          "No peers in this repo; %d alive on the sessions broker — try `c2c list --cross-repo`.\n"
          n_alive
      else
        Printf.printf "No registered peers.\n"
    end
```

- **Edge: JSON arm unchanged** — machine consumers must keep getting `[]`. Hint is Human-only.
- **Edge: sessions broker unreadable / absent** → `try … with _ -> 0` falls back to the plain message. Never crash `list`.
- **Edge: performance** — one extra `list_registrations` (a single `registry.json` read) only on the empty-repo path; negligible.
- **Wording:** prompt suggested "(or --global)". `--global` means something different here (per-repo scan). **Omit "(or --global)"** to avoid steering users wrong. → see §6 Q1.

## 4. Change 3 — soften the send-identity error (common case first)

**Location:** `validate_from_override`, the "different session" branch, `c2c.ml:132-138`:
```ocaml
if from_registered_to_other then begin
  Printf.eprintf
    "refusing to send as '%s': that alias is registered to a different session \
     (not your identity). Set C2C_COORDINATOR=1 to relay on behalf of another agent, \
     or send as your own alias.\n%!"
    from_alias;
  exit 1
```

**Problem:** the relay path (`C2C_COORDINATOR=1`) is suggested before the far more common fix ("I *am* this alias; my `C2C_MCP_SESSION_ID` just isn't set/matching"). Reorder so the identity path comes first, and only mention it when the alias is in fact registered to a resolvable session (which is exactly the `from_registered_to_other` branch — the alias IS registered, just to a different/absent session id than the caller's).

**Replace `c2c.ml:133-137` with:**
```ocaml
Printf.eprintf
  "refusing to send as '%s': that alias is registered to a different session \
   than yours.\n\
   - If you ARE %s: set C2C_MCP_SESSION_ID to that session's id so the broker \
   recognizes you (this is the usual fix).\n\
   - To relay on behalf of another agent: set C2C_COORDINATOR=1.\n\
   - Otherwise: send as your own alias.\n%!"
  from_alias from_alias;
exit 1
```

- **Edge: keep the sibling "not registered" branch (`c2c.ml:139-145`) as-is** — there the alias is unknown, so "set C2C_MCP_SESSION_ID" would be misleading; the existing "alias is not registered / your own alias or C2C_COORDINATOR=1" message is correct.
- **Edge: rooms duplicate.** A casefold-identical pair exists in `ocaml/cli/c2c_rooms.ml:60`/`:67` (per lens 3). **Out of scope** unless the executor wants parity — flag, don't auto-edit. → §6 Q3.
- **Edge: `--from` is the only trigger.** `validate_from_override` runs only on `--from` override (`c2c.ml:153`, `:454`). The default no-`--from` path errors elsewhere (`c2c.ml:183`,`:191`) and is untouched.

## 5. Test plan

### 5a. Build / unit (run in `/home/xertrov/src/c2c`)
- `dune build ./ocaml/cli/c2c.exe` (limit to 2 jobs: `dune build -j2`). Must compile clean — watch for unused-binding warnings on the new `cross_repo` binders (Cmdliner `let+` style tolerates them since they're consumed).
- `c2c list --help`, `c2c send --help`, `c2c monitor --help`, `c2c register --help` — confirm `--cross-repo` (and `--global-broker`) appear with correct docs and that `list --help` still shows `--global`.

### 5b. Behavioral, single host (use a scratch sessions root to avoid clobbering live `~/.c2c/sessions/broker`)
- `export C2C_SESSIONS_BROKER_ROOT=$(mktemp -d)/sb`
- Register two fake peers into it: `C2C_MCP_SESSION_ID=s-alice c2c register --cross-repo --alias alice`; same for `bob`.
- `c2c list --cross-repo --json` → array contains `alice`,`bob`.
- From a dir with no per-repo broker: `c2c list --json` → `[]` and Human `c2c list` prints the "N alive on the sessions broker — try `c2c list --cross-repo`" hint with N=2.
- Precedence: `C2C_MCP_BROKER_ROOT=/some/perrepo c2c list --cross-repo` → still lists sessions peers (cross-repo beats env). `c2c monitor --root /explicit --cross-repo` → uses `/explicit` (explicit beats cross-repo) — verify via a debug print or by pointing at an empty dir.
- Identity error: `C2C_MCP_SESSION_ID=s-bob c2c send --cross-repo --from alice hi` → new 3-bullet message, identity bullet first, `exit 1`.

### 5c. Cross-repo dogfood (the verifier `cc-pi-c2c` runs this from the `pi-c2c` repo / a non-c2c repo)
Run against the **live** sessions broker (do NOT set `C2C_SESSIONS_BROKER_ROOT`; let it auto-resolve to `~/.c2c/sessions/broker`). Use the freshly built `c2c` binary.

1. **Discovery:** from `/home/xertrov/src/pi-c2c` (or any non-c2c repo): `c2c list --cross-repo` → shows cross-repo peers (e.g. the ~180 live registrations seen on disk; confirm a known alive coordinator like `cc-pi-c2c-coord` appears). Compare `c2c list` (per-repo) → should be empty or only local, and print the hint.
2. **Send reaches them:** pick an alive cross-repo alias `<alias>` from step 1: `c2c send --cross-repo <alias> "dogfood ping from cc-pi-c2c"`. Verify delivery by checking `~/.c2c/sessions/broker/<their-session>.inbox.json` gained the message, or have the recipient confirm.
3. **Monitor streams:** `c2c monitor --cross-repo --alias cc-pi-c2c` (the verifier's own alias) → blocks and streams; have a peer `c2c send --cross-repo cc-pi-c2c "ack"` and confirm the line appears. Ctrl-C to stop; confirm lockfile lands under `~/.c2c/sessions/broker/.monitor-locks/`.

**Pass criteria:** all three succeed without any manual `C2C_MCP_BROKER_ROOT`/`C2C_SESSIONS_BROKER_ROOT` export, and per-repo `c2c list` from a non-c2c repo prints the new hint.

## 6. Ambiguities needing a human decision

- **Q1 (alias name):** Use `--cross-repo` + secondary `--global-broker`? The prompt floats `--sessions`, but a `sessions` subcommand already exists (`c2c.ml:832`, lists the per-repo broker) and `-g/--global` is taken by the per-repo scanner (`c2c.ml:617`). Spec assumes `--cross-repo`/`--global-broker` and drops "(or --global)" from the §3 hint. Confirm.
- **Q2 (register scope):** Should `register --cross-repo` write ONLY the sessions broker (spec default) or BOTH per-repo and sessions? Writing both makes a peer discoverable everywhere in one command but duplicates state.
- **Q3 (rooms parity):** Apply the §4 message softening to the room variants in `ocaml/cli/c2c_rooms.ml:60`/`:67` too? Spec leaves them untouched.
- **Q4 (`--session` + `--cross-repo`):** Spec makes `--cross-repo` move sender-identity resolution to the sessions broker, incidentally fixing the latent inconsistency where `send --session` resolves identity against the per-repo broker but delivers to the sessions broker. Confirm this is desirable rather than scope-creep to leave alone.

## 7. Ordered task list for `pi-2315bf`

1. Add `resolve_effective_broker_root` helper after `c2c.ml:49`.
2. Add shared `cross_repo_flag` term after `json_flag` (`c2c.ml:231`).
3. `list_cmd` (`c2c.ml:609`): add `and+ cross_repo`; add `--global`×`--cross-repo` mutex guard; wire `:758-759` to the helper.
4. Implement Change 2 hint in the `list` Human empty-branch (`c2c.ml:761-764`).
5. `send_cmd` (`c2c.ml:383`): add `and+ cross_repo` (`:428`); wire broker create `:430` to the helper.
6. `register_cmd` (`c2c.ml:3118`): add `and+ cross_repo` (`:3131`); wire `:3132` to the helper.
7. `monitor_cmd` (`c2c.ml:3544`): add `cross_repo` Arg; thread into `const` fun param and term application; rewrite `broker_root` resolution (`:3600-3619`) with explicit-arg > cross-repo > env > default.
8. Implement Change 3: reorder/soften the identity error (`c2c.ml:133-137`); leave `:139-145` as-is.
9. `dune build -j2 ./ocaml/cli/c2c.exe`; fix warnings.
10. Run §5a help checks, §5b behavioral tests (scratch sessions root), then hand the §5c dogfood to `cc-pi-c2c`.
11. Surface §6 Q1–Q4 to the coordinator before merging.

**Key files (absolute):** `/home/xertrov/src/c2c/ocaml/cli/c2c.ml`, `/home/xertrov/src/c2c/ocaml/c2c_repo_fp.ml`, `/home/xertrov/src/c2c/ocaml/c2c_broker.ml` (for `list_registrations`/`registry.json` semantics), `/home/xertrov/src/c2c/ocaml/cli/c2c_rooms.ml` (Q3 only).