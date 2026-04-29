# c2c_start.ml code-health audit — 2026-04-29

slate-coder. File: `/home/xertrov/src/c2c/ocaml/c2c_start.ml` (4741 LOC).
Read-only audit; no code modified. Companion to stanza's c2c_mcp.ml audit
at `.collab/research/2026-04-29-stanza-coder-c2c-mcp-code-health.md`.

Build is clean today (`dune build` exits 0 with no warnings on a fresh
recompile of this file), so unlike the c2c_mcp audit there are no
pre-existing warnings to triage. Findings are about LOC concentration,
DRY, dead optional args, magic numbers, and `Obj.magic` use.

## Top recommendations (ranked by leverage)

### 1. Split `run_outer_loop` (3333–4165, 833 LOC)

Single biggest readability win in the file. `run_outer_loop` is 833 LOC
in one binding — almost 18% of the file lives inside this one function.
It builds env, resolves binaries, sets up tee/pipes/fifos, forks the
inner client, attaches sidecars, manages SIGTERM/SIGTSTP/SIGCONT, and
finalises shutdown. There's no fan-out into helpers; the whole graph is
read top-to-bottom with deeply nested `match`/`let` bindings.

Concrete sub-units that are already cleanly delimited and could lift
out as named helpers (without changing behaviour, just giving names to
the seams):

- **L3386–3404** repo bootstrap (instance dir, tmux capture, git-shim
  write) — `let prepare_instance_dir ~name ~broker_root` returning unit.
- **L3412–3469** sidecar PID refs + `cleanup_and_exit` closure — already
  factored into a closure but the closure captures 4 refs and 1 fn from
  the outer scope; lifting it to a `module Outer_cleanup` keeps the
  state explicit and testable.
- **L3492–3549** env construction — five sequential
  `let env = ... Array.append env [| ... |] ...` rebinds. Refactor to
  `let env = build_env ~name ~client ~role ~kickoff_path ~one_hr_cache
  ~resume_session_id ~agent_name (...) in`. Each `Array.append` is O(N)
  so the rebinds are O(N²) in the env size — small N today (~20
  entries), but the pattern is also just hard to read.
- **L3555–3641** launch-arg + bridge wiring — fifo creation, fd numbers,
  bash heredoc for codex-headless. `let prepare_codex_headless_cmd ...`
  + `let prepare_codex_xml_pipe ...`.
- **L3789–3950** the fork-and-wire-sidecars block. This is the densest
  knot: codex_xml_pipe, dup_fifo_to_fd, request_events/responses fifos,
  fallback deliver-daemon retry, exception handler that unwinds them.
  ~160 LOC of mostly-fd-shuffling that wants to be 3 helpers:
  `child_setup_codex_fds`, `start_deliver_or_fallback`, `unwind_fifos_on_failure`.
- **L3952–4002** the opencode plugin-fallback supervisor thread (50 LOC
  inline `Thread.create`). Lift to `start_opencode_fallback_supervisor`.
- **L4041–4089** `wait_for_child` SIGTSTP/SIGCONT loop. Already a `rec`
  inner fn; promotes cleanly to a module-level `wait_for_inner_child`.
- **L4092–4119** tee thread shutdown sequence — well-commented but the
  4-step ordering deserves its own named function so future edits don't
  reorder it (the comment at 4092 already warns this is load-bearing).

Effort: **8–14 h** end-to-end. First useful slice — extract the
opencode-fallback thread + the env-build chain → ~120 LOC delta, no
behaviour change, can be reviewed in isolation. Risk: medium; the fork
block has subtle pgid/tcsetpgrp ordering that must not move (see the
comment at 3800–3814).

### 2. Three near-identical TOML boolean readers — collapse to one parameterised helper (468–556)

`repo_config_enable_channels` (468–496), `repo_config_git_attribution`
(498–526), `repo_config_git_sign` (528–556) are textually identical
30-LOC blocks differing only in:

- the key string (`"enable_channels"` / `"git_attribution"` / `"git_sign"`)
- its length (15 / 16 / 8)
- the file-missing default (`false` / `true` / `true`)

Confirmed via `diff` — the diff between the first two readers is
exactly four lines (key name, length, length, default-when-missing).
That's ~60 LOC of pure copy-paste. Plus all three inline the same
`v = "true" || v = "1" || v = "yes" || v = "on"` test (493, 523, 553)
even though `parse_bool_like` already exists at line 199.

Recommended: a single `read_top_level_bool ~key ~default_when_missing`
that streams `repo_config_path ()` and uses `parse_bool_like` for the
final coercion. Total file delta: ~−60 LOC. Bonus: the existing
hand-rolled "is the next char `=` or space?" predicate can become one
call to a `match_key_prefix` helper (or just be replaced by the
`read_toml_sections_with_prefix` machinery already at 558 — these three
keys are top-level not under any `[section]`, but a
`read_toml_top_level` variant of that fn would subsume all three).

Effort: **1 h**. Risk: very low; the three call sites are limited
(`repo_config_git_attribution` called twice at 2218 + 3389,
`repo_config_git_sign` only inside `cli/c2c_setup.ml` per grep,
`repo_config_enable_channels` is currently dead in *this* file —
worth checking external callers, but that's a quick `grep -r`). Same
slice should also collapse `read_pmodel_raw` (912–945) and
`repo_config_default_binary` (971–1003) — both reinvent the
"scan-while-in-table" logic and are 90% identical (verified via diff).

### 3. `build_env` has 5 unerasable `option = None` arguments (2188–2192)

```ocaml
let build_env ?(broker_root_override : string option = None)
    ?(auto_join_rooms_override : string option = None)
    ?(role_class_opt : string option = None)
    ?(client : string option = None)
    ?(reply_to_override : string option = None)
    (name : string) (alias_override : string option) : string array =
```

This is the canonical Warning 16 anti-pattern — `option` typed args
defaulted to `None` mean every call site passes `?(arg=Some _)` or
nothing, never the natural `~arg:None`, which makes the `?` purely
ergonomic noise and forces the user to know all 5 names.

Call sites: there is exactly **one** non-test call site
(L3493 inside `run_outer_loop`), where it's invoked as:

```ocaml
let env = build_env ~broker_root_override:(Some broker_root)
    ~auto_join_rooms_override:auto_join_rooms ~client:(Some client)
    ~reply_to_override:reply_to
    name alias_override in
```

So `role_class_opt` is **never passed** — confirmed dead. The
`broker_root_override` and `client` are always `Some` at the only
call site (could be plain non-optional). The two genuine options
(`auto_join_rooms_override`, `reply_to_override`) are already typed
`string option` at the caller side, so the extra `option = None`
default is redundant — drop the `= None` and they become normal
optional `string` args, callable as `?auto_join_rooms_override` or
`~auto_join_rooms_override:rooms`.

Recommended:

```ocaml
let build_env ~broker_root ~client
    ?auto_join_rooms_override ?reply_to_override
    ~name ~alias_override () : string array = ...
```

Drops `role_class_opt` entirely (verified unused), promotes
`broker_root` + `client` to required, deletes 4 of the 5 `option =
None` defaults. Effort: **30 min**. Risk: trivial — single call site.

### 4. Five copy-paste adapter dispatches in `prepare_launch_args` (2407–2517)

Lines 2418–2489 are five `match client with | "X" -> let module A = (val
(Stdlib.Hashtbl.find client_adapters "X") : CLIENT_ADAPTER) in
A.build_start_args ...` arms, plus a hard-coded `codex-headless` arm
that's the odd one out (no adapter — opportunity to add one for
parity).

The post-arm fixups (2491–2516) are 4 more sequential rebinds of
`args` for codex sideband fds, model_override append guard,
codex_xml_input_fd prepend, and final `extra_args` append. Each is a
small `match` that mutates the args list.

Two refactors stack:

(a) **Promote codex-headless to a `CodexHeadlessAdapter`** so the
top-level dispatch is uniform: `let module A = ... in
A.build_start_args ~extra_inputs ...` for every client. The
`extra_inputs` record carries the fd flags (`thread_id_fd`,
`server_request_events_fd`, `server_request_responses_fd`,
`codex_xml_input_fd`, `agent_name`, `kickoff_prompt`), passed
verbatim — adapters that don't care ignore the field.

(b) **Replace the 5 dispatch arms with one Hashtbl lookup** plus the
shared post-fixups:

```ocaml
let module A = (val (Stdlib.Hashtbl.find client_adapters client)
                : CLIENT_ADAPTER) in
A.build_start_args ~name ?alias_override ?model_override
  ?resume_session_id ~extra_inputs ~extra_args ()
```

Removes ~70 LOC, makes adding a new client a 1-place change instead of
2 (adapter module + dispatch arm). Effort: **2.5 h** including writing
the `CodexHeadlessAdapter` and updating the `CLIENT_ADAPTER` signature
to take an `extra_inputs` record. Risk: low–medium; covered by
`test_c2c_start.ml` (2686 LOC).

### 5. Three near-duplicate FATAL "nested session" blocks (4218–4266)

`cmd_start` rejects nested sessions with three almost-identical
9-LOC eprintf blocks, one for each of (session_id only, alias only,
both). They differ only in which env var name they print and which
`Sys.getenv_opt` they recompute (which they then re-extract with
`match ... with Some s -> s | None -> "(unknown)"` even though the
pattern match above just established that the var is `Some _`).

Same with the 5× `let use_color = Unix.isatty Unix.stderr in let red
= ... let yellow = ... let reset = ...` boilerplate (4194, 4222,
4236, 4250, 4323). One `Term_color` helper module would let every
call site read `Term_color.fatal "..."` instead of 4 ANSI bindings
plus an `Printf.eprintf "%s%s%s..."`.

Recommendation:

```ocaml
let fatal_nested_session ~env_var ~value =
  let red, reset = Term_color.(red (), reset ()) in
  Printf.eprintf
    "%sFATAL:%s refusing to start nested session.\n  \
     You are already running inside a c2c agent session\n  \
     (%s=%s).\n  Hint: use 'c2c stop' or 'c2c restart-self'.\n%!"
    red reset env_var value;
  exit 1
```

…called from a single 4-arm `match (session_id, alias,
wrapper_self) with` instead of the current 7 arms (4 of which are
unit `()`). Effort: **45 min**. Risk: trivial.

### 6. `Obj.magic` for fd ↔ int conversions (30, 31, 32, 3285, 3824, 3840, 3841, 3879)

Eight call sites use `Obj.magic` to convert between OCaml `int` and
`Unix.file_descr`. This works on Linux because `Unix.file_descr` is
abstract-but-actually-an-int, but the unsafe-cast is a foot-gun that
a future OCaml runtime change or non-Linux port would silently break.

The standard idiom is the (rather buried) `Stdlib.Obj` API or a
small C stub. Within the OCaml stdlib, `Unix.dup` and family return
`file_descr` directly; the only place we need an int-to-fd is when
asking for "the fd numbered 3" (L3824) or matching `/proc/self/fd`
entries by name (L29). Two surgical fixes:

(a) **Add a tiny C stub** `caml_c2c_fd_of_int : int -> Unix.file_descr`
in `cli/c2c_posix_stubs.c` (next to the existing `setpgid`/`tcsetpgrp`
externals). One `return Val_int(fd)` — the existing externals already
demonstrate this is in scope. Replace the 5 `Obj.magic n` casts in
`run_outer_loop` and `pty_inject` with the stub call.

(b) **For `fds_to_close`** (L13–37) the reverse direction (fd → int)
is what's needed; OCaml's `Unix.file_descr` *is* an int on Unix, so
we can use `(Unix.dup_or_set_close_on_exec : ...)`-style helpers, OR
just expose `caml_c2c_int_of_fd` symmetric to the above.

Effort: **1.5 h** including the C stub + tests. Risk: low; safer
than the status quo, surface change is isolated.

### 7. Magic numbers / constants → named (top of file)

The opencode-plugin float triple at 3953–3966 spells out three
repeated `60.0` defaults inline, with the env-var fallback parser
also repeated three times:

```
C2C_OPENCODE_PLUGIN_GRACE_S    -> 60.0
C2C_OPENCODE_PLUGIN_STALE_S    -> 60.0
C2C_OPENCODE_FALLBACK_CHECK_S  -> 10.0
```

Other magic-but-meaningful floats throughout the file:

| line | value | what |
|------|-------|------|
| 184 | 30.0 | default heartbeat command timeout |
| 277 | 0.001 | min sleep before next aligned heartbeat |
| 1651 | 10.0 | dev-channel auto-answer poll timeout |
| 1672 | 0.2 | dev-channel poll interval |
| 1716 | 2 * 1024 * 1024 | stderr ring-log cap |
| 1719, 1721 | 4096 | stderr tee buffer / chunk size |
| 2151 | 2.0 | tmux deliver poll interval |
| 2162 | 300.0 | opentui zig cache stale threshold |
| 3169 | 600.0 | poker interval (kimi) |
| 3175 | 5.0 | wire-daemon poll interval |
| 3194/3206/3209/3212 | 0.1 | thread-id watcher backoff |
| 3219 | 1200 | thread-id watcher max attempts (= ~2min) |
| 3239 | 0.01 | bracketed-paste post-write delay |
| 3267 | 0.1 | pty deliver loop poll interval |
| 3453 | 0.3 | inner-pgrp SIGTERM→SIGKILL grace |
| 3434 | 20 | stop_sidecar wait_try iterations (= 2s) |
| 4022 | 30.0 | title ticker poll interval |
| 4086 | 0.5 | post-wait inner-pgrp SIGTERM→SIGKILL |
| 4537 | 10.0 | cmd_stop SIGTERM→SIGKILL grace |
| 4561 | 0.05 | wait_for_exit poll interval |
| 4685 | 5.0 | reset_thread restart timeout |
| 4724 | 100.0 | CLK_TCK assumption |

Most of these are well-commented at point of use, but a single
`Constants` module (or a few `let default_X_s = ...` at top of file)
would let an operator twiddle "all the 0.1s polls" without grepping
the file. The 4724 `let hz = 100.0` is the dangerous one — that's a
hard-coded kernel `CLK_TCK` assumption that's true on essentially
every x86_64 Linux but not portable. Worth a `Sysconf` call or a
comment escalated from "almost always 100" to a runtime probe.

Effort: **45 min** for the named-constant pass; **2 h** if you also
move CLK_TCK to a runtime probe. Risk: trivial.

### 8. Repeated `Option.value alias_override ~default:name` (8 sites)

L2090, L2232, L2355, L3487, L3674, L3862, L4010, L4454 all repeat the
same coalesce. Lift to a one-liner near the top of the file:

```ocaml
let effective_alias ?alias_override ~name () =
  Option.value alias_override ~default:name
```

Or pass an `alias` explicitly into helpers instead of re-computing the
default at each layer. Effort: **15 min**. Risk: trivial.

### 9. `cmd_start` is 308 LOC (4184–4491)

Second-largest function in the file. The bulk is:

- 70 LOC of nested-session FATAL blocks (covered by #5 above).
- 50 LOC of session-id validation with per-client branching (4274–4318).
  Refactor to one `validate_session_id ~client ~sid` returning
  `(unit, string) result` per client; ~3× LOC reduction.
- 80 LOC of "load existing config and merge with overrides" (4347–4429).
  This is the resume-vs-fresh logic; an `instance_config_for_launch
  ~name ~client ~explicit_overrides` helper would isolate it.
- The PTY/tmux client special-case dispatch at the end (4269–4474) is
  fine as-is — flat, linear.

Effort: **3 h** total; can slice as #5 + session-id validator + resume-merge
helper. Risk: medium-low; well-tested via `test_c2c_start.ml`.

### 10. Three places re-derive `broker_root ()` instead of threading through (1876, 2194, 2797, 4270, 4428)

`broker_root ()` is called 5×, often inside helpers that already had
`broker_root` available in their caller's scope (e.g. `KimiAdapter`
at 2797 calls `broker_root ()` even though `prepare_launch_args` has
`~broker_root` as a labelled arg). Either:

(a) Thread the resolved `broker_root` through every helper — verbose
but explicit. The cost is small since every helper that touches the
broker already has `~name` and `~broker_root` adjacent.

(b) Cache the result in a `Lazy.t` at top of file. The current call
is cheap (`C2c_repo_fp.resolve_broker_root` does at most one
`git rev-parse`), so this is a clarity, not perf, win.

Pairs naturally with #4 (the adapter refactor). Effort: rolled into
#4 — no extra work. Risk: trivial.

## Leave-it-alone notes

- **Adapter modules** (1187, 2688, 2733, 2776, 2825) are 50–115 LOC
  each and read top-to-bottom — splitting them across files would
  scatter "what does kimi do at startup?" across 5 files. The
  `CLIENT_ADAPTER` module type is a clean seam already; resist the
  urge to add a sub-module hierarchy.
- **`start_stderr_tee`** (1714, 90 LOC) is dense but the comment at
  4092 documents the load-bearing shutdown ordering. Adding a layer
  of abstraction risks losing the four-step shutdown contract. Leave.
- **`run_outer_loop`'s `wait_for_child` inner loop** (4045–4072) is
  the SIGTSTP/SIGCONT/EINTR handler — correct and well-commented.
  Lifting to a top-level helper is fine but the body itself shouldn't
  shrink.
- **The `tool_definitions`-style hard-coded client `Hashtbl`
  registrations** (1112–1177) are flat and declarative. Don't split
  per-client — keeping them in one block makes it easy to compare
  delivery flags side by side.
- **`fds_to_close`** (13–37) is unsafe-looking but the `Obj.magic` use
  is contained, the function is pure (testable without side effect),
  and the comment block clearly documents the EINTR/error-propagation
  contract. Fix per #6, but don't otherwise reorganize.
- File modes (`0o600` / `0o644` / `0o755`) — same as stanza's c2c_mcp
  audit: well-understood Unix mode bits, don't bikeshed into named
  constants.
- ANSI escape sequences (`\027[1;31m` etc.) are pervasive in error
  messages. A `Term_color` module is a nice-to-have (#5 above) but the
  current inline form is locally readable; extraction is for DRY, not
  correctness.

## Summary table

| # | Win | Effort | Risk | Type |
|---|-----|--------|------|------|
| 1 | Split `run_outer_loop` (833 LOC → ~6 helpers) | 8–14 h | medium (fd/pgid ordering) | reviewability |
| 2 | Collapse 3 boolean TOML readers + 2 table readers into 1 helper | 1 h | very low | DRY |
| 3 | `build_env` 5× `option = None` cleanup | 0.5 h | trivial | hygiene |
| 4 | Adapter dispatch via Hashtbl + `extra_inputs` record | 2.5 h | low | DRY |
| 5 | FATAL nested-session blocks + `Term_color` helper | 0.75 h | trivial | DRY |
| 6 | Replace `Obj.magic` fd casts with C stub | 1.5 h | low | safety |
| 7 | Named constants for sleep/timeout floats | 0.75 h | trivial | clarity |
| 8 | Lift `effective_alias` helper | 0.25 h | trivial | DRY |
| 9 | Split `cmd_start` (308 LOC) into validator + merger | 3 h | low | reviewability |
| 10 | Thread `broker_root` instead of re-resolving | rolled into #4 | trivial | clarity |

Suggested **first slice** for a single coder session:
**#2 + #3 + #5 + #7 + #8** → ~3.25 h, ~−180 LOC delta, no behaviour
change, no warning churn (build is already clean). Lands a hygiene
baseline before tackling #1 (the big reviewability win) or #4 (the
adapter refactor that touches every client).

**Highest correctness leverage**: #6 (eliminates `Obj.magic`) and #1
(833-LOC function gets carved into named seams that future bug fixes
can be scoped to). Both worth their costs.

— slate-coder, 2026-04-29
