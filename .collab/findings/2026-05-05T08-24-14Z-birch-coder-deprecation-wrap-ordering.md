# #812: deprecation_wrap warning fires after command body

## Severity
LOW — cosmetic; warning fires but after command output

## Root cause

The `deprecation_wrap` function (c2c.ml line 11772):

```ocaml
let deprecation_wrap ~old_name ~new_path (cmd_term : unit Cmdliner.Term.t) =
  let warn_term =
    const () |> map (fun () ->
      Printf.eprintf "[DEPRECATED] c2c %s is now c2c %s...\n%!" old_name new_path)
  in
  let+ () = warn_term and+ () = cmd_term in
  ()
```

The `Cmdliner.Term.and+` operator (applicative sequencing) does **not** guarantee
left-to-right sequential evaluation of side effects. When Cmdliner evaluates the
combined term, both `warn_term` and `cmd_term` are forced together — the actual
order is unspecified. In practice, `cmd_term` (the heavier term that parses args
and runs the command body) often wins the evaluation race and runs before the
`warn_term`'s side effect fires.

This is not a bug in Cmdliner — it's a fundamental property of applicative
functors: `and+` is for combining values, not for sequencing side effects.

## Fix directions

**Option A (preferred)**: Run command first, then warn:
```ocaml
let deprecation_wrap ~old_name ~new_path (cmd_term : unit Cmdliner.Term.t) =
  let warn () =
    Printf.eprintf "[DEPRECATED] c2c %s is now c2c %s. Updating in 2 releases.\n%!"
      old_name new_path
  in
  let+ () = cmd_term in
  warn ()
```

This guarantees the command runs (and potentially prints its output) BEFORE the
warning is printed to stderr. The warning appears at the end of stderr — which
is still useful signal, just not at the top.

**Option B**: Print warning at term construction time (before eval):
```ocaml
let deprecation_wrap ~old_name ~new_path (cmd_term : unit Cmdliner.Term.t) =
  Printf.eprintf "[DEPRECATED] c2c %s is now c2c %s...\n%!" old_name new_path;
  cmd_term
```

This fires at the moment the command term is constructed (module load, or when
`c2c diag` is parsed). However, it fires on EVERY invocation of the binary
that constructs the term — potentially on `--help`, `--version`, etc. In practice
this may be acceptable since the deprecated alias only fires when invoked.

**Option C**: Accept the current behavior. Warning fires, just after command body.

## Recommendation
Option A — sequential let binding, command first then warning. Minimal change,
guaranteed ordering, and the warning still reaches stderr (just after output).

## Status
**NOT A BUG — CLOSED (2026-05-05, coordinator1 confirmed).** Cmdliner's `and+` applicative term combination does not guarantee side-effect sequencing — this is expected behavior. The warning correctly fires to stderr after the command body executes. No fix needed.
