# Implementation Plan — c2c `--cross-repo` flag + send-identity UX

**Goal:** Add a `--cross-repo` CLI flag to `list`, `send`, `monitor`, and `register` so users can target the shared sessions broker (`~/.c2c/sessions/broker`) instead of the per-repo broker, plus improve the error message when sending as an alias registered to a different session.

**Branch/Worktree:** `slice/cross-repo-flag` in `.worktrees/cross-repo-flag`.
**Primary file:** `ocaml/cli/c2c.ml`.
**Spec:** `.collab/specs/2026-06-20-cross-repo-flag-spec.md`.

**Decisions on open questions (Q1–Q4):**
- Q1: Use `--cross-repo` with secondary alias `--global-broker` only. Do **not** add `--sessions` (collides with `sessions` subcommand) or `-g/--global` (taken by per-repo scanner).
- Q2: `register --cross-repo` writes **only** the sessions broker.
- Q3: Leave `c2c_rooms.ml` identity-error variants untouched for now.
- Q4: `--cross-repo` moves sender-identity resolution to the sessions broker; this also fixes the latent inconsistency where `send --session` resolved identity against the per-repo broker.

**Architecture:**
1. Add one shared resolver helper and one shared Cmdliner flag term.
2. Wire the flag into `list`, `send`, `register`, and `monitor`.
3. Add a human-only hint when the per-repo `list` is empty but the sessions broker has alive peers.
4. Reorder/soften the `--from` identity error so the "set C2C_MCP_SESSION_ID" path is suggested first.

---

## Global Constraints

- Compile with `dune build -j2 ./ocaml/cli/c2c.exe`.
- Do not change the JSON output of `c2c list`.
- Preserve all existing `--global` behavior.
- Preserve plain `send --session` behavior unless `--cross-repo` is also supplied; with `--cross-repo --session`, sender identity resolution should use the sessions broker.
- Do not deprecate or remove the win32 npm package.
- All changes stay in the isolated worktree.
- Do not commit unless the coordinator explicitly asks for a commit.
- Report progress to coordinator; do not use `attn`.

---

## Task 1: Shared helper + flag

**Files:**
- Modify: `ocaml/cli/c2c.ml` (after line 49 and after `json_flag` at line 231).

**What to do:**
1. Add `resolve_effective_broker_root` after `resolve_broker_root`:
   ```ocaml
   let resolve_effective_broker_root ?(explicit_root : string option = None) ~cross_repo () =
     match explicit_root with
     | Some r when String.trim r <> "" -> String.trim r
     | _ ->
         if cross_repo then Repo_fp.resolve_sessions_broker_root ()
         else resolve_broker_root ()
   ```
2. Add `cross_repo_flag` after `json_flag`:
   ```ocaml
   let cross_repo_flag =
     Cmdliner.Arg.(value & flag & info [ "cross-repo"; "global-broker" ]
       ~doc:"Target the cross-repo sessions broker ($(b,~/.c2c/sessions/broker)) instead of \
             this repo's per-repo broker. Auto-resolves the rendezvous root \
             (override with $(b,C2C_SESSIONS_BROKER_ROOT)); no manual \
             $(b,C2C_MCP_BROKER_ROOT) needed. An explicit $(b,--root), where available, still wins.")
   ```

**Verify:** `dune build -j2 ./ocaml/cli/c2c.exe` compiles (the new values are unused until later tasks).

---

## Task 2: `list --cross-repo` + empty-list hint

**Files:**
- Modify: `ocaml/cli/c2c.ml` (`list_cmd`, around lines 609–764).

**What to do:**
1. Add `and+ cross_repo = cross_repo_flag` in the `let+` block.
2. Immediately after the binders, before creating any broker or doing output work, add the mutex guard:
   ```ocaml
   if global && cross_repo then begin
     Printf.eprintf "error: --global (scan per-repo brokers) and --cross-repo (sessions broker) are mutually exclusive.\n%!";
     exit 2
   end;
   ```
3. Replace `let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in` with:
   ```ocaml
   let broker = C2c_mcp.Broker.create ~root:(resolve_effective_broker_root ~cross_repo ()) in
   ```
4. In the `regs = []` Human branch, replace the plain "No registered peers.\n" with a check against the sessions broker (when `not cross_repo`):
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
           Printf.printf "No peers in this repo; %d alive on the sessions broker — try `c2c list --cross-repo`.\n" n_alive
         else
           Printf.printf "No registered peers.\n"
       end
   ```

**Verify:**
- `dune build -j2 ./ocaml/cli/c2c.exe`
- `c2c list --help` shows `--cross-repo` and `--global-broker`.
- `c2c list --global --cross-repo` exits 2.

---

## Task 3: `send --cross-repo`

**Files:**
- Modify: `ocaml/cli/c2c.ml` (`send_cmd`, around lines 383–534).

**What to do:**
1. Add `and+ cross_repo = cross_repo_flag` in the `let+` block (around line 428).
2. Replace `let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in` (around line 430) with:
   ```ocaml
   let broker = C2c_mcp.Broker.create ~root:(resolve_effective_broker_root ~cross_repo ()) in
   ```

**Verify:**
- `dune build -j2 ./ocaml/cli/c2c.exe`
- `c2c send --help` shows `--cross-repo`.
- With scratch sessions registrations for `alice` and `bob`, `C2C_MCP_SESSION_ID=s-bob ./ocaml/cli/c2c.exe send --cross-repo --from alice bob hi` reaches `validate_from_override` and prints the softened identity error. Do not use `send --cross-repo --from alice hi`; that is parsed as target-only with no message and only tests usage validation.

---

## Task 4: `register --cross-repo`

**Files:**
- Modify: `ocaml/cli/c2c.ml` (`register_cmd`, around lines 3118–3132).

**What to do:**
1. Add `and+ cross_repo = cross_repo_flag` in the `let+` block.
2. Replace `let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in` with:
   ```ocaml
   let broker = C2c_mcp.Broker.create ~root:(resolve_effective_broker_root ~cross_repo ()) in
   ```
3. Leave the existing `write_allowed_signers_entry broker ~alias` call as-is. With `--cross-repo`, this may write broker-local ancillary signer state under the sessions broker, but it must not touch the per-repo broker.

**Verify:**
- `dune build -j2 ./ocaml/cli/c2c.exe`
- `c2c register --help` shows `--cross-repo`.
- Under a scratch `C2C_SESSIONS_BROKER_ROOT`, `register --cross-repo` creates/updates the sessions broker registry and does not create/update the current repo broker registry.

---

## Task 5: `monitor --cross-repo`

**Files:**
- Modify: `ocaml/cli/c2c.ml` (`monitor_cmd`, around lines 3544–3640).

**What to do:**
1. Add `let cross_repo = cross_repo_flag in` near the other arg lets.
2. Add `cross_repo` as a parameter to the `const (fun ...)` block.
3. Add `$ cross_repo` to the term assembly.
4. Replace the `broker_root` resolution block (lines 3600–3619) with explicit-arg > cross-repo > env > default precedence:
   ```ocaml
   let broker_root =
     let resolved value_opt =
       match value_opt with Some s when String.trim s <> "" -> Some (String.trim s) | _ -> None
     in
     match resolved broker_root_arg with
     | Some r -> r
     | None ->
         if cross_repo then Repo_fp.resolve_sessions_broker_root ()
         else (match C2c_utils.trimmed_env_value "C2C_MCP_BROKER_ROOT" with
               | Some r -> r
               | None -> (try resolve_broker_root () with _ ->
                   Printf.eprintf "c2c monitor: cannot resolve broker root \
                     (set C2C_MCP_BROKER_ROOT or run from inside the repo)\n%!";
                   exit 1))
   in
   ```

**Verify:**
- `dune build -j2 ./ocaml/cli/c2c.exe`
- `c2c monitor --help` shows `--cross-repo`.

---

## Task 6: Softened `--from` identity error

**Files:**
- Modify: `ocaml/cli/c2c.ml` (`validate_from_override`, lines 132–138).

**What to do:**
Replace the `from_registered_to_other` branch message with:
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

Leave the sibling "not registered" branch unchanged.

**Verify:**
- `dune build -j2 ./ocaml/cli/c2c.exe`
- A scratch test with a registered alias and mismatched session id prints the new message.

---

## Task 7: Build + help checks

**Run:**
```bash
cd /home/xertrov/src/c2c/.worktrees/cross-repo-flag
dune build -j2 ./ocaml/cli/c2c.exe
./ocaml/cli/c2c.exe list --help | grep -E 'cross-repo|global-broker'
./ocaml/cli/c2c.exe send --help | grep -E 'cross-repo|global-broker'
./ocaml/cli/c2c.exe register --help | grep -E 'cross-repo|global-broker'
./ocaml/cli/c2c.exe monitor --help | grep -E 'cross-repo|global-broker'
./ocaml/cli/c2c.exe list --global --cross-repo 2>&1 | head -1
```

Expected: all help outputs mention `--cross-repo`/`--global-broker`; the mutex command prints the mutual-exclusion error.

---

## Task 8: Behavioral tests with scratch sessions broker

**Run:**
```bash
export C2C_SESSIONS_BROKER_ROOT=$(mktemp -d)/sb
C2C_MCP_SESSION_ID=s-alice ./ocaml/cli/c2c.exe register --cross-repo --alias alice
C2C_MCP_SESSION_ID=s-bob ./ocaml/cli/c2c.exe register --cross-repo --alias bob
./ocaml/cli/c2c.exe list --cross-repo --json | jq '.[].alias'
```
Expected: output contains `alice` and `bob`.

```bash
mkdir -p /tmp/no-c2c-repo && cd /tmp/no-c2c-repo
C2C_MCP_BROKER_ROOT=/tmp/fake-perrepo /home/xertrov/src/c2c/.worktrees/cross-repo-flag/ocaml/cli/c2c.exe list
```
Expected: "No peers in this repo; 2 alive on the sessions broker — try `c2c list --cross-repo`."

```bash
C2C_MCP_SESSION_ID=s-bob /home/xertrov/src/c2c/.worktrees/cross-repo-flag/ocaml/cli/c2c.exe send --cross-repo --from alice bob hi 2>&1 | head -5
```
Expected: new 3-bullet error with identity bullet first. The recipient/message pair (`bob hi`) is intentional; a single positional token would fail usage parsing before identity validation.

---

## Task 9: Dogfood handoff + final review

1. Do **not** commit by default; keep the worktree diff available for review unless the coordinator explicitly asks for a commit.
2. Run `c2c doctor` (or equivalent) to confirm local-only status/readiness.
3. Hand off the dogfood verification (§5c of the spec) to `cc-pi-c2c` once quota is available.
4. Run a final code review pass over the diff.
5. Request coordinator approval for any merge or push to master.

---

## Risks / assumptions

- The sessions broker root auto-resolution in `Repo_fp.resolve_sessions_broker_root` is assumed to work as documented.
- `monitor` uses Cmdliner's `const`/`Arg` style; threading `cross_repo` through it must preserve argument order between the `const (fun ...)` parameters and the `$ ...` term application.
- The empty-list hint is Human-only. The `Json` branch must remain exactly `[]` for compatibility.
- The plan assumes no other agent is simultaneously editing `ocaml/cli/c2c.ml` in this worktree.
