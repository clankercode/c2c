# Agent Stickers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cryptographically-signed appreciation tokens as a new `c2c sticker` CLI subcommand group.

**Architecture:** New `c2c_stickers.ml` module handles registry loading, signing, verification, storage. Reuses `Relay_identity` for Ed25519 keys and `C2c_utils` for JSON file ops. Repo-relative storage at `.c2c/stickers/`. Closed set v1 sticker registry in `registry.json`.

**Tech Stack:** OCaml, Cmdliner, Base64, Mirage_crypto, Digestif.SHA256

**Reminder:** `.ml` file additions MUST include dune modules list update in the SAME commit.

---

## Cross-node references
- `ocaml/relay_identity.ml` — Ed25519 keypair load/sign (last modified: known)
- `ocaml/relay_signed_ops.ml` — canonicalization pattern (pipe-separated, align with it)
- `ocaml/cli/c2c.ml` — all_cmds wiring, existing patterns

---

## File Structure

- **Create:** `ocaml/cli/c2c_stickers.mli` — type definitions and signatures
- **Create:** `ocaml/cli/c2c_stickers.ml` — all sticker logic
- **Modify:** `ocaml/cli/dune` — add `c2c_stickers` to modules list
- **Modify:** `ocaml/cli/c2c.ml` — wire `sticker_group` into `all_cmds`
- **Create:** `.c2c/stickers/registry.json` — starter sticker registry (9 stickers)
- **Create:** `ocaml/test/test_c2c_stickers.ml` — unit tests

---

## Task 1: Create registry.json

**Files:**
- Create: `.c2c/stickers/registry.json`

- [ ] **Step 1: Create directory and registry file**

```json
{
  "stickers": [
    { "id": "solid-work",    "emoji": "🪨", "display_name": "Solid Work",      "description": "Reliable, thorough, high-quality output" },
    { "id": "brilliant",     "emoji": "✨", "display_name": "Brilliant",         "description": "Exceptional insight or solution" },
    { "id": "helpful",       "emoji": "🤝", "display_name": "Helpful",           "description": "Went out of their way to assist" },
    { "id": "clean-fix",     "emoji": "🔧", "display_name": "Clean Fix",         "description": "Elegant bug fix or refactor" },
    { "id": "save",          "emoji": "🫡", "display_name": "Save",              "description": "Saved the day under pressure" },
    { "id": "insight",       "emoji": "💡", "display_name": "Insight",          "description": "Valuable observation or idea" },
    { "id": "on-point",      "emoji": "🎯", "display_name": "On Point",         "description": "Exactly what was needed" },
    { "id": "good-catch",    "emoji": "🐛", "display_name": "Good Catch",       "description": "Caught a bug or issue before it shipped" },
    { "id": "first-slice",   "emoji": "🌱", "display_name": "First Slice",      "description": "First excellent contribution from a new agent" }
  ]
}
```

Run: `mkdir -p .c2c/stickers && cat > .c2c/stickers/registry.json << 'EOF'\n<json above>\nEOF`

- [ ] **Step 2: Commit**

```bash
git add .c2c/stickers/registry.json
git commit -m "feat(stickers): add v1 registry with 9 starter stickers"
```

---

## Task 2: Create c2c_stickers.mli

**Files:**
- Create: `ocaml/cli/c2c_stickers.mli`

- [ ] **Step 1: Write the interface file**

```ocaml
(** Sticker envelope v1 *)
type sticker_envelope = {
  version : int;
  from_ : string;
  to_ : string;
  sticker_id : string;
  note : string option;
  scope : [ `Public | `Private ];
  ts : string;
  nonce : string;
  signature : string;
}

(** A registry entry for a sticker kind *)
type registry_entry = {
  id : string;
  emoji : string;
  display_name : string;
  description : string;
}

(** Storage paths relative to repo root (.c2c/stickers/) *)
val sticker_dir : unit -> string
val received_dir : alias:string -> string
val sent_dir : alias:string -> string
val public_dir : unit -> string

(** Load and validate the registry *)
val load_registry : unit -> registry_entry list

(** Validate a sticker_id exists in the registry *)
val validate_sticker_id : string -> (unit, string) result

(** Build the canonical blob for signing: from|to|sticker_id|note_or_empty|scope|ts|nonce *)
val canonical_blob : sticker_envelope -> string

(** Sign an envelope using the identity's private key *)
val sign_envelope : identity:Relay_identity.t -> sticker_envelope -> sticker_envelope

(** Verify signature on an envelope *)
val verify_envelope : sticker_envelope -> (bool, string) result

(** Build envelope from input params, sign it, store it *)
val create_and_store : from_:string -> to_:string -> sticker_id:string -> note:string option -> scope:[`Public|`Private] -> identity:Relay_identity.t -> (sticker_envelope, string) result

(** Load stickers for an alias, optionally filtered by scope *)
val load_stickers : alias:string -> ?scope:[`Public|`Private] -> unit -> sticker_envelope list

(** Format a sticker for terminal display *)
val format_sticker : sticker_envelope -> registry_entry option -> string
```

- [ ] **Step 2: Commit**

```bash
git add ocaml/cli/c2c_stickers.mli
git commit -m "feat(stickers): add c2c_stickers.mli interface"
```

---

## Task 3: Create c2c_stickers.ml

**Files:**
- Create: `ocaml/cli/c2c_stickers.ml`

- [ ] **Step 1: Write the module**

Key implementation points:
- `sticker_dir ()` uses `git rev-parse --git-common-dir` + `.c2c/stickers`
- `canonical_blob` uses pipe-separated string: `<from>|<to>|<sticker_id>|<note_or_empty>|<scope>|<ts>|<nonce>`
- Scope serialized as string `"public"` or `"private"`
- `now_rfc3339_utc ()` for timestamp
- `random_nonce_b64 ()` using Mirage_crypto_rng
- `sign_envelope`: adds signature using `Relay_identity.sign` with canonical blob
- `verify_envelope`: extracts pk from identity, verifies Ed25519 sig
- Storage: `<ts>-<nonce>.json` for private/sent; `<from>-<ts>-<nonce>.json` for public
- Files written atomically via temp file + os.replace

```ocaml
(* c2c_stickers.ml — Agent stickers: signed appreciation tokens *)

open Cmdliner.Syntax
open Relay_identity
open C2c_utils

(* --- path helpers ------------------------------------------------------- *)

let sticker_dir () =
  let git_common = Git_helpers.git_common_dir () in
  Filename.concat git_common ".c2c" // "stickers"

let received_dir ~alias =
  sticker_dir () // alias // "received"

let sent_dir ~alias =
  sticker_dir () // alias // "sent"

let public_dir () =
  sticker_dir () // "public"

(* --- registry ----------------------------------------------------------- *)

type registry_entry = {
  id : string;
  emoji : string;
  display_name : string;
  description : string;
}

let load_registry () =
  let reg_file = sticker_dir () // "registry.json" in
  let json = C2c_utils.read_json_file reg_file in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "stickers" fields with
     | Some (`List entries) ->
       List.map (function
         | `Assoc e ->
           let id = List.assoc_opt "id" e |> function Some (`String s) -> s | _ -> ""
           and emoji = List.assoc_opt "emoji" e |> function Some (`String s) -> s | _ -> ""
           and display_name = List.assoc_opt "display_name" e |> function Some (`String s) -> s | _ -> ""
           and description = List.assoc_opt "description" e |> function Some (`String s) -> s | _ -> ""
           in { id; emoji; display_name; description }
         | _ -> { id=""; emoji=""; display_name=""; description="" }) entries
     | _ -> [])
  | _ -> []

let validate_sticker_id id =
  let registry = load_registry () in
  if List.exists (fun e -> e.id = id) registry then Ok ()
  else Error ("unknown sticker id: " ^ id)

(* --- envelope type ------------------------------------------------------ *)

type sticker_envelope = {
  version : int;
  from_ : string;
  to_ : string;
  sticker_id : string;
  note : string option;
  scope : [ `Public | `Private ];
  ts : string;
  nonce : string;
  signature : string;
}

(* --- crypto helpers ----------------------------------------------------- *)

let b64url_nopad s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let now_rfc3339_utc () =
  let t = Unix.gettimeofday () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02.03fZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min (float_of_int tm.Unix.tm_sec)

let random_nonce_b64 () =
  Mirage_crypto_rng_unix.use_default ();
  let bytes = Mirage_crypto_rng.generate 16 in
  b64url_nopad bytes

let canonical_blob env =
  let note_str = match env.note with Some n -> n | None -> "" in
  let scope_str = match env.scope with `Public -> "public" | `Private -> "private" in
  String.concat "|"
    [ env.from_; env.to_; env.sticker_id; note_str; scope_str; env.ts; env.nonce ]

let sign_envelope ~identity env =
  let blob = canonical_blob env in
  let sig = Relay_identity.sign identity blob in
  { env with signature = b64url_nopad sig }

let verify_envelope env =
  if env.signature = "" then Error "missing signature"
  else
    let blob = canonical_blob env in
    let pk = identity.Relay_identity.public_key in
    match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet env.signature with
    | Ok sig_bytes ->
      (match Relay_identity.verify pk blob sig_bytes with
       | true -> Ok true
       | false -> Error "invalid signature")
    | Error e -> Error ("b64 decode failed: " ^ e)

(* --- storage ------------------------------------------------------------ *)

let envelope_to_json env =
  let scope_str = match env.scope with `Public -> "public" | `Private -> "private" in
  let fields = [
    ("version", `Int env.version);
    ("from", `String env.from_);
    ("to", `String env.to_);
    ("sticker_id", `String env.sticker_id);
    ("scope", `String scope_str);
    ("ts", `String env.ts);
    ("nonce", `String env.nonce);
    ("signature", `String env.signature);
  ] in
  let fields = match env.note with Some n -> ("note", `String n) :: fields | None -> fields in
  `Assoc fields

let envelope_of_json json =
  let get_str fields k = List.assoc_opt k fields |> function Some (`String s) -> s | _ -> "" in
  let get_opt_str fields k = List.assoc_opt k fields |> function Some (`String s) -> Some s | _ -> None in
  match json with
  | `Assoc fields ->
    let scope = match get_str fields "scope" with "public" -> `Public | _ -> `Private in
    Ok {
      version = (match List.assoc_opt "version" fields with Some (`Int i) -> i | _ -> 1);
      from_ = get_str fields "from";
      to_ = get_str fields "to";
      sticker_id = get_str fields "sticker_id";
      note = get_opt_str fields "note";
      scope;
      ts = get_str fields "ts";
      nonce = get_str fields "nonce";
      signature = get_str fields "signature";
    }
  | _ -> Error "expected JSON object"

let store_envelope env =
  let dir, filename = match env.scope with
    | `Private -> received_dir ~alias:env.to_, Printf.sprintf "%s-%s.json" env.ts env.nonce
    | `Public -> public_dir (), Printf.sprintf "%s-%s-%s.json" env.from_ env.ts env.nonce
  in
  let json = envelope_to_json env in
  let content = Yojson.Safe.to_string json in
  C2c_utils.atomic_write_file (dir // filename) content

let load_stickers ~alias ?(scope=`Both) () =
  let dirs = match scope with
    | `Both -> [ received_dir ~alias ]
    | `Public -> [ public_dir () ]
    | `Private -> [ received_dir ~alias ]
  in
  let glob dir =
    try
      let d = Unix.opendir dir in
      let rec go acc =
        match Unix.readdir d with
        | entry when entry <> "" && entry <> "." && entry <> ".." ->
          let path = dir // entry in
          (match C2c_utils.read_json_file path with
           | `Assoc _ as json -> (match envelope_of_json json with Ok e -> e :: acc | Error _ -> acc)
           | _ -> acc)
        | _ -> go acc
      in
      let results = go [] in
      Unix.closedir d;
      results
    with _ -> []
  in
  List.concat (List.map glob dirs)

(* --- create and store ---------------------------------------------------- *)

let create_and_store ~from_ ~to_ ~sticker_id ~note ~scope ~identity =
  match validate_sticker_id sticker_id with
  | Error e -> Error e
  | Ok () ->
    let ts = now_rfc3339_utc () in
    let nonce = random_nonce_b64 () in
    let env = { version = 1; from_; to_; sticker_id; note; scope; ts; nonce; signature = "" } in
    let env = sign_envelope ~identity env in
    (match store_envelope env with
     | Ok () -> Ok env
     | Error e -> Error ("store failed: " ^ e))

(* --- formatting ---------------------------------------------------------- *)

let format_sticker env =
  let registry = load_registry () in
  let entry = List.find_opt (fun e -> e.id = env.sticker_id) registry in
  let emoji = match entry with Some e -> e.emoji | None -> "?" in
  let ts_str = env.ts in
  let note_str = match env.note with Some n -> " \"" ^ n ^ "\"" | None -> "" in
  Printf.sprintf "%s %s sent %s to %s at %s%s\n"
    emoji env.from_ env.sticker_id env.to_ ts_str note_str
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd /home/xertrov/src/c2c-stickers-work && opam exec -- dune build ./ocaml/cli/c2c_stickers.ml 2>&1 | grep -E "Error|error" | head -10`
Expected: no errors (ignore warnings)

- [ ] **Step 3: Commit**

```bash
git add ocaml/cli/c2c_stickers.ml
git commit -m "feat(stickers): add c2c_stickers.ml implementation"
```

---

## Task 4: Wire into c2c.ml + Register in dune (SAME COMMIT)

**Reminder: .ml file addition → dune modules list update in same commit.**

**Files:**
- Modify: `ocaml/cli/dune` — add `c2c_stickers` to modules list
- Modify: `ocaml/cli/c2c.ml` — add `sticker_group` to all_cmds

- [ ] **Step 1: Add c2c_stickers to dune modules list**

Find the `modules` line in `ocaml/cli/dune` and add `c2c_stickers` to the list.

- [ ] **Step 2: Wire sticker_group into all_cmds**

In `ocaml/cli/c2c.ml`, find the `all_cmds` list and add `; sticker_group` after `monitor` or wherever appropriate (grouped with social/swarm commands).

- [ ] **Step 3: Build both binaries**

Run: `opam exec -- dune build ./ocaml/cli/c2c.exe ./ocaml/server/c2c_mcp_server.exe 2>&1 | grep -E "Error|error|Unbound" | head -10`
Expected: no errors

- [ ] **Step 4: Commit**

```bash
git add ocaml/cli/dune ocaml/cli/c2c.ml
git commit -m "feat(stickers): wire sticker_group into CLI and register in dune"
```

---

## Task 5: Wire CLI commands (send, wall, verify, list)

**Files:**
- Modify: `ocaml/cli/c2c_stickers.ml` — add Cmdliner commands
- Add `sticker_send_cmd`, `sticker_wall_cmd`, `sticker_verify_cmd`, `sticker_list_cmd`
- Add `sticker_group` that groups them

**Files:**
- Modify: `ocaml/cli/c2c_stickers.ml` — add CLI command definitions
- Modify: `ocaml/cli/c2c_stickers.mli` — expose sticker_group

- [ ] **Step 1: Add CLI commands to c2c_stickers.ml**

Key patterns:
- `sticker send <peer> <sticker-id>`: `--note` optional, `--scope public|private` default private
- `sticker wall [--alias X] [--scope public|private]`: default to current alias
- `sticker verify <file>`: read JSON, verify, print VALID/INVALID
- `sticker list`: print registry entries

- [ ] **Step 2: Build**

Run: `opam exec -- dune build ./ocaml/cli/c2c.exe 2>&1 | grep -E "Error|error|Unbound" | head -10`

- [ ] **Step 3: Commit**

```bash
git add ocaml/cli/c2c_stickers.ml ocaml/cli/c2c_stickers.mli
git commit -m "feat(stickers): add send/wall/verify/list CLI commands"
```

---

## Task 6: Write tests

**Files:**
- Create: `ocaml/test/test_c2c_stickers.ml`

- [ ] **Step 1: Write failing tests**

```ocaml
let test_registry_load () =
  let registry = C2c_stickers.load_registry () in
  Alcotest.(check int) "9 stickers in registry" 9 (List.length registry);
  let entry = List.find (fun e -> e.id = "brilliant") registry in
  Alcotest.(check string) "brilliant emoji" "✨" entry.emoji

let test_validate_sticker_id () =
  Alcotest.(check bool) "valid id" true (Result.is_ok (C2c_stickers.validate_sticker_id "brilliant"));
  Alcotest.(check bool) "invalid id" true (Result.is_error (C2c_stickers.validate_sticker_id "nonexistent"))

let test_canonical_blob () =
  let env = { version=1; from_="a"; to_="b"; sticker_id="brilliant"; note=None; scope=`Private; ts="2026-04-25T00:00:00Z"; nonce="nonce"; signature="" } in
  let blob = C2c_stickers.canonical_blob env in
  Alcotest.(check string) "pipe-separated" "a|b|brilliant||private|2026-04-25T00:00:00Z|nonce" blob

let test_roundtrip_sign_verify () =
  let identity = Relay_identity.load () in
  let env = C2c_stickers.create_and_store ~from_:"jungle" ~to_:"galaxy" ~sticker_id:"brilliant" ~note:(Some "great work!") ~scope:`Private ~identity in
  Alcotest.(check bool) "created ok" true (Result.is_ok env);
  match env with Ok e ->
    Alcotest.(check bool) "verify ok" true (Result.get_ok (C2c_stickers.verify_envelope e) = true)
  | Error _ -> Alcotest.fail "create_and_store failed"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/xertrov/src/c2c-stickers-work && opam exec -- dune test 2>&1 | tail -20`
Expected: FAIL on sticker tests (module not yet registered in dune test)

- [ ] **Step 3: Fix and run tests**

Add `C2c_stickers` to dune test modules list, rebuild, run tests

- [ ] **Step 4: Commit**

```bash
git add ocaml/test/test_c2c_stickers.ml
git commit -m "test(stickers): add unit tests for registry, validation, and sign/verify"
```

---

## Task 7: Peer review

After all commits, before coordinator review:
1. Notify a peer (e.g., test-agent) to run `just install-all` on stickers-impl worktree
2. Verify `c2c sticker list`, `c2c sticker send`, `c2c sticker wall`, `c2c sticker verify` all work
3. Get PASS signal

---

## Spec Coverage Checklist

- [x] Closed set v1, registry-driven (registry.json)
- [x] Emoji as ID (registry entry)
- [x] Note field (envelope type, create_and_store)
- [x] Pipe-separated canonicalization (canonical_blob)
- [x] Per-alias Ed25519 keys (Relay_identity)
- [x] Repo-relative storage (.c2c/stickers/)
- [x] Public/private scope (envelope type, storage paths)
- [x] CLI: send, wall, verify, list
- [x] Sign + verify roundtrip
- [x] dune registration (Task 4, same commit as .ml)
- [x] Tests

## Execution Options

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
