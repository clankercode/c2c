# OCaml/Dune Learnings

A collection of OCaml compiler and Dune build system quirks relevant to the c2c codebase.

---

## Single-file executable rule: `let () =` must be in the entry module (#482 S1, 2026-05-01)

### Symptom
Binary compiles cleanly, tests pass, but running the binary exits 0 with no output
and no observable side effects.

### Root Cause
Two-file executable layout:
```dune
(executable
 (name c2c_deliver_inbox)
 (modules c2c_deliver_inbox_main c2c_deliver_inbox)  ; main listed FIRST
 ...)
```
```ocaml
(* c2c_deliver_inbox_main.ml *)
let () = C2c_deliver_inbox.main ()

(* c2c_deliver_inbox.ml *)
let main () = (* ... program body ... *)
```

Dune compiles the **first module** (`c2c_deliver_inbox_main`) as the entry point.
The OCaml runtime's `caml_program` calls each module's `.entry` function once for
initialization, then exits. The `let () = C2c_deliver_inbox.main ()` call is a
pure function call at initialization time with no observable side effects — the
OCaml optimizer (from `camlopt`) compiles it away entirely.

The actual program body (`C2c_deliver_inbox.main`, compiled as `main_887`) is
never called because `caml_program`'s role is initialization + exit, not
dispatching to a "main function."

### Evidence
- `nm binary | grep main_` shows the symbol as local `t` (text, not `T`)
- Adding `prerr_endline "top"` at the very start of `c2c_deliver_inbox_main.ml`'s
  `let ()` confirmed it was never reached
- Two-file layout with main module containing imperative code directly (not just
  a function call to another module) works fine — the bug is specifically when the
  entry module does nothing but forward to another module

### Fix
Merge all logic into a single `.ml` file named the same as the `(name ...)` in
the dune stanza. The `let () =` in that file **is** the OCaml program body:

```dune
(executable
 (name c2c_deliver_inbox)
 (modules c2c_deliver_inbox)  ; single module — let () = IS the program body
 ...)
```

```ocaml
(* c2c_deliver_inbox.ml — all logic in one file *)
let main () = (* ... *)

let () = main ()  (* this let () = IS the program body, not a forward declaration *)
```

### Files
- `ocaml/cli/c2c_deliver_inbox.ml` (single-file executable, 366 lines)

### Status
Fixed. Commits `505ac335` / `a171ef1a` on `slice/482-s1-scaffold`.

---

## Dune `modules` ordering: first module is entry point (#482 S1, 2026-05-01)

The Dune documentation does not make this explicit, but the first module in a
`(modules ...)` list is compiled as the entry point. This is not a Dune bug —
it's how native OCaml executables work — but it surprises developers accustomed to
linker semantics where a separate `main()` symbol is the entry.

**Rule**: when writing a Dune executable, put the module containing your
`let () =` program body **last** in the `(modules ...)` list, OR (better)
use a single-module executable.

---

*To add an entry: create a new top-level `##` section with date, issue number, and description.*
