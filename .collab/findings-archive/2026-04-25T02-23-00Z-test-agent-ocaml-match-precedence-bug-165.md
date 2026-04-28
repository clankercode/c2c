# Finding: OCaml match precedence trap in #165 (jungle-coder)

**Date**: 2026-04-25
**Caught by**: coordinator1 during coord-review
**Severity**: High (runtime — `c2c start` silently exits 0 without starting anything when using resume mode or --worktree)

## Symptom

`c2c start <client> --session-id <uuid>` (resume mode) or `c2c start <client> --worktree` would print the expected log message but exit immediately with code 0, without actually starting the client. The `cmd_start` call was never reached.

## Root Cause (confirmed via OCaml repro by coordinator1)

The `;` after `| _ -> ()` causes OCaml to parse the `_` branch as:
```ocaml
| _ -> ((); exit (C2c_start.cmd_start ...))
```

Because `expr; expr` as a sequence returns the last value. So `(); exit (...)` is one expression, and since `_ -> expr` means the branch returns `expr`, the `_` branch returns the result of `exit (...)`. But `exit` never returns normally — it calls `exit(0)` — so the `_` branch never returns.

This means:
- `Some _` branch: `Printf.printf ...;` — returns unit, **never reaches exit/cmd_start**
- `None when auto_worktree` branch: `let wt_dir = ... in (try ...); Printf.printf ...;` — returns unit, **never reaches exit/cmd_start**
- `_` branch: `(); exit (cmd_start ...)` — exit IS called, **cmd_start IS reached**

Hence the failure mode: resume-mode and worktree paths silently exit 0 without starting anything. The no-flag default path still works (reaches `_` branch → cmd_start).

## The Buggy Code

```ocaml
let auto_worktree = worktree_flag || (match Sys.getenv_opt "C2C_AUTO_WORKTREE" with Some "1" -> true | _ -> false) in
match session_id_opt with
| Some _ ->
    Printf.printf "[c2c] resume mode — staying at parent cwd\n%!"
| None when auto_worktree ->
    let wt_dir = C2c_worktree.ensure_worktree ~alias:effective_alias ~branch:"master" in
    (try Unix.chdir wt_dir with Sys_error e ->
      Printf.eprintf "warning: failed to chdir to worktree %s: %s\n%!" wt_dir e);
    Printf.printf "[c2c] worktree: %s\n%!" wt_dir
| _ -> ();
exit (C2c_start.cmd_start ~client ~name ~extra_args:[]
    ?binary_override:bin_opt
    ?alias_override
    ?session_id_override:session_id_opt
    ?model_override
    ~one_hr_cache
    ?kickoff_prompt
    ?agent_name
    ?auto_join_rooms
    ?reply_to ())
```

The `exit` is at the same semicolon-chain level as the `match`. Because `| _ -> ();` makes the semicolon part of the branch body, OCaml parses `_` branch as `| _ -> ((); exit (...))`. So the `_` branch DOES reach `exit` — but the `Some _` and `None when auto_worktree` branches never do.

## Fix Applied by Jungle (098defb)

Wrap match in parens so `exit (cmd_start ...)` runs unconditionally after the match, not consumed by any branch:

```ocaml
let auto_worktree = ... in
(match session_id_opt with
| Some _ ->
    Printf.printf "[c2c] resume mode — staying at parent cwd\n%!"
| None when auto_worktree ->
    let wt_dir = ... in
    ...
| _ -> ());
exit (C2c_start.cmd_start ~client ~name ~extra_args:[]
    ?binary_override:bin_opt
    ...)
```

## Lessons

- OCaml semicolons in match branch bodies can consume trailing expressions: `| _ -> (); exit foo` parses as `| _ -> ((); exit foo)`
- "Build clean" is necessary but not sufficient for CLI plumbing review
- A one-line functional smoke (`c2c start kimi -n smoke-test --session-id smoke-123`) catches this instantly — the old code silently exits 0; the fixed code reaches `cmd_start` (and fails on session-id validation, which proves it tried to start)
- The failure mode is selective (only some branches break) not total, which makes it harder to detect

## Discovery Method

Coord-review by coordinator1 — not caught in peer review (build was clean, code looked structurally plausible). Functional smoke would have caught it immediately.
