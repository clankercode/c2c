# #422 v3 non-blocker follow-ups (stanza peer-PASS notes)

**Source**: peer-PASS notes on `e286b0e2` (commit-range
`d5caf21d..e286b0e2`). All three are opportunistic — none were
FAIL-worthy at review time.

## F1 — Skip broker IO when `C2C_MCP_SESSION_ID` is unset

**Where**: `ocaml/cli/c2c_rooms.ml::resolve_alias_with_broker`

Current shape (post-#422 v3):

```ocaml
match Broker.list_registrations broker
      |> List.find_opt (fun r ->
           r.session_id = Option.value (C2c_mcp.session_id_from_env ())
                                       ~default:"") with
| Some r -> r.alias
| None ->
    (match C2c_utils.alias_from_env_only () with
     | Some a -> a
     | None -> exit 1)
```

When `C2C_MCP_SESSION_ID` is unset, the `Option.value … ~default:""`
returns `""`, and we still enumerate every registration looking for
a session_id == "" match. Cheap on a small broker, but unnecessary.

**Proposed shape**:

```ocaml
match C2c_mcp.session_id_from_env () with
| Some sid ->
    (match List.find_opt (fun r -> r.session_id = sid)
                         (Broker.list_registrations broker) with
     | Some r -> r.alias
     | None ->
         (match C2c_utils.alias_from_env_only () with
          | Some a -> a
          | None -> exit 1))
| None ->
    (* No session_id → skip broker IO entirely. *)
    (match C2c_utils.alias_from_env_only () with
     | Some a -> a
     | None -> exit 1)
```

Effect: rooms commands launched with `C2C_MCP_AUTO_REGISTER_ALIAS`
set but no `C2C_MCP_SESSION_ID` (e.g. ad-hoc CLI invocations) skip
the broker.list_registrations call entirely. Tiny perf win;
matches the "fast-path" intent in the original v1 SPEC.

**Effort**: ~10 LoC, single function. Add a unit test that asserts
the broker is not consulted when session_id is None and env is set.

## F2 — Test for actually-unset env var

**Where**: `ocaml/cli/test_c2c_utils.ml`

`with_env` helper currently:

```ocaml
let with_env key value f =
  let old = Sys.getenv_opt key in
  (match value with
   | "" -> Unix.putenv key ""
   | v -> Unix.putenv key v);
  ...
```

`Unix.putenv key ""` sets the env var to empty string — it does NOT
unset it. So `test_none_on_empty` exercises the empty-string branch
(`Sys.getenv_opt` returns `Some ""`) but NOT the truly-unset branch
(`Sys.getenv_opt` returns `None`). The renamed test honestly
reflects this.

`alias_from_env_only` collapses both into `None` via:

```ocaml
match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
| Some v when String.trim v <> "" -> Some (String.trim v)
| _ -> None
```

The `| _` catches both `None` and `Some ""`-after-trim. Both branches
*should* return `None`, but only one is exercised.

**Proposed shape**: extend `with_env` (or add a sibling) that uses
`Unix.unsetenv` (OCaml 5.x has `Unix.putenv` only; the unset
operation requires a small wrapper around `Stdlib.Sys.unsetenv` if
present, or use a fork-and-exec pattern). Or pre-clear the env in
the test setup.

**Effort**: ~15 LoC. Low risk; pure coverage improvement.

## F3 — Port canonical alias-resolution priority to CLAUDE.md

**Where**: `CLAUDE.md` "Key Architecture Notes"

`SPEC.md` (post-#422 v3) now carries:

> ## Alias Resolution Priority (canonical)
>
> ```
> override arg > session_id (C2C_MCP_SESSION_ID → broker)
>              > env (C2C_MCP_AUTO_REGISTER_ALIAS)
> ```

`CLAUDE.md` documents `C2C_MCP_AUTO_REGISTER_ALIAS` and
`C2C_MCP_SESSION_ID` separately but doesn't put them in priority
order. This is internal-facing today but worth lifting if any
operator-facing surface (a doctor subcommand, a test runbook, a
`c2c install` setup hint) needs to disambiguate.

**Effort**: ~5 LoC in CLAUDE.md, possibly mirrored in
`docs/architecture.md` if that page covers the same ground.

**Defer signal**: low operator pain reported. Pick this up only if
a specific user-facing question hits it.

## Slicing recommendation

F1 + F2 are the same surface (`alias_from_env_only` + its rooms
caller); could ship as one ~25 LoC slice. F3 is doc-only; trivial
when picked up. Suggest:

- `slice/422-followup-fastpath-and-coverage` — F1 + F2 bundled.
- `slice/422-followup-claude-md-priority` — F3, deferred.

No urgency on either. Filing here so the next agent (or future-me)
doesn't have to re-derive the analysis.
