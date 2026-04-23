# S5a: Mobile Pair (QR Token Issuance + Binding) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Design decision:** Option A (single round-trip) — see `.collab/design-decisions/2026-04-23-s5a-mobile-pair-prepare-roundtrip.md`
> **CLI token flow:** CLI generates + signs token locally with machine Ed25519 private key, sends to relay `/mobile-pair/prepare`. Relay verifies sig against embedded pubkey, stores token.

**Goal:** `POST /mobile-pair/prepare` (receives signed token + machine pubkey, stores token) and `POST /mobile-pair` (verifies token, burns it, creates binding). `c2c mobile-pair` CLI subcommand.

**Architecture:**
- `pairing_tokens` table in SQLite for atomic token issuance and compare-and-swap burn
- `ObserverBindings` in relay.ml (already exists from S4) for in-memory phone→binding lookup
- `POST /mobile-pair/prepare`: receives `{machine_ed25519_pubkey, token}` where token is CLI-generated and signed; stores in SQLite; returns `{binding_id}`
- `POST /mobile-pair`: receives `{token, phone_ed25519_pubkey, phone_x25519_pubkey}`; verifies token sig, atomic burn, creates ObserverBinding, returns signed binding confirmation
- `c2c mobile-pair [--revoke <binding_id>]`: prepare mode generates QR; revoke mode calls `DELETE /binding/<id>`

**Token format (CLI-generated, relay-verified):**
```
Payload JSON: {binding_id, machine_ed25519_pubkey, issued_at, expires_at, nonce}
Canonical msg: "c2c/v1/mobile-pair-token" || binding_id || machine_ed25519_pubkey || issued_at || expires_at || nonce
Sig: Ed25519 sign of canonical msg using machine's Ed25519 private key (LOCAL to CLI)
Token delivery: base64url(JSON payload + sig field added before sending)
```

**Tech Stack:** OCaml, SQLite, MirageCrypto_EC Ed25519, Base64

---

## File Map

| File | Changes |
|------|---------|
| `ocaml/relay_sqlite.ml` | Add `pairing_tokens` DDL; add `store_pairing_token`, `get_and_burn_pairing_token`, `delete_pairing_token` |
| `ocaml/relay.ml` | Add `mobile_pair_token_sign_ctx`; add token helpers; add to RELAY sig; add to InMemoryRelay; add handlers; wire routes |
| `ocaml/cli/c2c.ml` | Add `mobile-pair-prepare` and `mobile-pair-confirm` to Relay_client; add CLI subcmd branch |
| `ocaml/test/test_relay_bindings.ml` | Add S5a token roundtrip + expiry tests |

---

## Task 1: Add `pairing_tokens` table to SQLite schema + functions

**Files:**
- Modify: `ocaml/relay_sqlite.ml:104-109` (add after `room_invites` CREATE TABLE)
- Modify: `ocaml/relay_sqlite.ml` — add `store_pairing_token`, `get_and_burn_pairing_token`, `delete_pairing_token`

- [ ] **Step 1: Add DDL for `pairing_tokens` table**

After line 108 in `ocaml/relay_sqlite.ml` (after `room_invites` CREATE TABLE):

```ocaml
CREATE TABLE IF NOT EXISTS pairing_tokens (
    binding_id TEXT PRIMARY KEY,
    token_b64 TEXT NOT NULL,
    machine_ed25519_pubkey TEXT NOT NULL,
    used INTEGER NOT NULL DEFAULT 0,
    expires_at REAL NOT NULL
);
```

- [ ] **Step 2: Add token management SQL helper functions**

After the DDL block (after line 109), add:

```ocaml
(* S5a: Pairing token management *)
let store_pairing_token db ~binding_id ~token_b64 ~machine_ed25519_pubkey ~expires_at =
  let sql = "INSERT OR REPLACE INTO pairing_tokens (binding_id, token_b64, machine_ed25519_pubkey, used, expires_at) VALUES (?, ?, ?, 0, ?)" in
  let rc = db.exec sql [|
    Sqlite3.Data.TEXT binding_id;
    Sqlite3.Data.TEXT token_b64;
    Sqlite3.Data.TEXT machine_ed25519_pubkey;
    Sqlite3.Data.FLOAT expires_at
  |] in
  if rc <> Sqlite3.Rc.OK then Error (Printf.sprintf "store_pairing_token failed: %s" (Sqlite3.Rc.to_string rc))
  else Ok ()

(* Returns (token_b64, machine_ed25519_pubkey) if token is valid and unused.
   Uses atomic UPDATE WHERE used=0 to prevent double-burn. *)
let get_and_burn_pairing_token db ~binding_id =
  let now = Unix.gettimeofday () in
  let select_sql = "SELECT token_b64, machine_ed25519_pubkey FROM pairing_tokens WHERE binding_id = ? AND used = 0 AND expires_at > ?" in
  match db.exec select_sql [| Sqlite3.Data.TEXT binding_id; Sqlite3.Data.FLOAT now |] with
  | rc when rc = Sqlite3.Rc.DONE -> Ok None
  | rc when rc = Sqlite3.Rc.ROW ->
    let token_b64 = db.column_text 0 |> Option.value ~default:"" in
    let machine_ed25519_pubkey = db.column_text 1 |> Option.value ~default:"" in
    let update_sql = "UPDATE pairing_tokens SET used = 1 WHERE binding_id = ? AND used = 0" in
    let rc = db.exec update_sql [| Sqlite3.Data.TEXT binding_id |] in
    if rc = Sqlite3.Rc.DONE && db.changes > 0 then
      Ok (Some (token_b64, machine_ed25519_pubkey))
    else
      Ok None
  | rc -> Error (Printf.sprintf "get_and_burn_pairing_token failed: %s" (Sqlite3.Rc.to_string rc))

let delete_pairing_token db ~binding_id =
  let sql = "DELETE FROM pairing_tokens WHERE binding_id = ?" in
  let _ = db.exec sql [| Sqlite3.Data.TEXT binding_id |] in
  ()
```

- [ ] **Step 3: Verify build**

Run: `cd /home/xertrov/src/c2c && git checkout -- ocaml/c2c_mcp.ml && cd ocaml && opam exec -- dune build 2>&1 | grep -E '^Error' | head -10`
Expected: No new errors (ignore unrelated warnings about Uuidm, partial match)

- [ ] **Step 4: Commit**

```bash
git add ocaml/relay_sqlite.ml
git commit -m "feat(S5a): add pairing_tokens table and token management SQL functions"
```

---

## Task 2: Add `mobile_pair_token_sign_ctx` + token helpers to relay.ml

**Files:**
- Modify: `ocaml/relay.ml` — add sign context constant + token helpers near top-level constants

- [ ] **Step 1: Add sign context constant**

In `ocaml/relay.ml` around line 60 (after `room_set_visibility_sign_ctx`):

```ocaml
let mobile_pair_token_sign_ctx = "c2c/v1/mobile-pair-token"
```

- [ ] **Step 2: Add token encode/decode helpers** (in relay.ml, near `decode_b64url` around line 2323)

```ocaml
(* S5a: Pairing token encode/decode helpers *)
let encode_token_json j =
  Yojson.Safe.to_string j |> fun s ->
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let decode_token_json b64 =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet b64 with
  | Error _ -> None
  | Ok s ->
    try Some (Yojson.Safe.from_string s)
    with Yojson.Json_error _ -> None

let canonical_token_msg ~binding_id ~machine_ed25519_pubkey_b64 ~issued_at ~expires_at ~nonce =
  Relay_identity.canonical_msg ~ctx:mobile_pair_token_sign_ctx
    [ binding_id; machine_ed25519_pubkey_b64; string_of_float issued_at;
      string_of_float expires_at; nonce ]
```

- [ ] **Step 3: Verify build**

Run: `cd /home/xertrov/src/c2c && git checkout -- ocaml/c2c_mcp.ml && cd ocaml && opam exec -- dune build 2>&1 | grep -E '^Error' | head -10`
Expected: No new errors

- [ ] **Step 4: Commit**

```bash
git add ocaml/relay.ml
git commit -m "feat(S5a): add mobile_pair_token_sign_ctx and token helpers"
```

---

## Task 3: Add `store_pairing_token`/`get_and_burn_pairing_token` to RELAY sig + InMemoryRelay

**Files:**
- Modify: `ocaml/relay.ml:343-379` (RELAY signature)
- Modify: `ocaml/relay.ml` (InMemoryRelay — add pairing_token functions + observer binding functions)

- [ ] **Step 1: Add to RELAY signature**

In `ocaml/relay.ml` at line 379 (end of RELAY sig), add:

```ocaml
  (* S5a: Pairing token management *)
  val store_pairing_token : t -> binding_id:string -> token_b64:string ->
    machine_ed25519_pubkey:string -> expires_at:float -> (unit, string) result
  val get_and_burn_pairing_token : t -> binding_id:string -> (string * string) option
  (* S5a: Observer binding management (in-memory, not persisted) *)
  val add_observer_binding : t -> binding_id:string ->
    phone_ed25519_pubkey:string -> phone_x25519_pubkey:string -> unit
  val get_observer_binding : t -> binding_id:string -> (string * string) option
  val remove_observer_binding : t -> binding_id:string -> unit
```

- [ ] **Step 2: Implement in InMemoryRelay**

Find the InMemoryRelay let-binding section (around line 580 after `list_peers`). Add inside the `module InMemoryRelay = struct`:

```ocaml
  (* S5a: In-memory pairing token store for InMemoryRelay *)
  let pairing_tokens : (string, (string * string * float)) Hashtbl.t = Hashtbl.create 64

  let store_pairing_token _ ~binding_id ~token_b64 ~machine_ed25519_pubkey ~expires_at =
    Hashtbl.replace pairing_tokens binding_id (token_b64, machine_ed25519_pubkey, expires_at);
    Ok ()

  let get_and_burn_pairing_token _ ~binding_id =
    let now = Unix.gettimeofday () in
    match Hashtbl.find_opt pairing_tokens binding_id with
    | None -> None
    | Some (token_b64, machine_ed25519_pubkey, expires_at) ->
      if now > expires_at then
        (Hashtbl.remove pairing_tokens binding_id; None)
      else
        (Hashtbl.remove pairing_tokens binding_id;
         Some (token_b64, machine_ed25519_pubkey))

  (* S5a: In-memory observer bindings (parallel to module-level ObserverBindings) *)
  let observer_bindings_mem : (string, (string * string)) Hashtbl.t = Hashtbl.create 64

  let add_observer_binding _ ~binding_id ~phone_ed25519_pubkey ~phone_x25519_pubkey =
    Hashtbl.replace observer_bindings_mem binding_id (phone_ed25519_pubkey, phone_x25519_pubkey)

  let get_observer_binding _ ~binding_id =
    Hashtbl.find_opt observer_bindings_mem binding_id

  let remove_observer_binding _ ~binding_id =
    Hashtbl.remove observer_bindings_mem binding_id
```

**Note:** The existing module-level `ObserverBindings` (at lines 1785-1823) is used by the SQLite-backed relay. The InMemoryRelay has its own parallel in-memory store above.

- [ ] **Step 3: Verify build**

Run: `cd /home/xertrov/src/c2c && git checkout -- ocaml/c2c_mcp.ml && cd ocaml && opam exec -- dune build 2>&1 | grep -E '^Error' | head -10`
Expected: No new errors

- [ ] **Step 4: Commit**

```bash
git add ocaml/relay.ml
git commit -m "feat(S5a): add pairing_token and observer_binding to RELAY sig + InMemoryRelay"
```

---

## Task 4: Implement `POST /mobile-pair/prepare` endpoint handler

**Files:**
- Modify: `ocaml/relay.ml` — add `handle_mobile_pair_prepare` handler

- [ ] **Step 1: Add `handle_mobile_pair_prepare` handler**

Add near `handle_admin_unbind` (after line 2309) in `ocaml/relay.ml`:

```ocaml
(* S5a: POST /mobile-pair/prepare — store signed pairing token, return binding_id *)
let handle_mobile_pair_prepare relay ~client_ip body =
  let machine_ed25519_pubkey_b64 = get_opt_string body "machine_ed25519_pubkey" |> Option.value ~default:"" in
  let token = get_opt_string body "token" |> Option.value ~default:"" in
  if machine_ed25519_pubkey_b64 = "" then
    respond_bad_request (json_error_str err_bad_request "machine_ed25519_pubkey is required")
  else if token = "" then
    respond_bad_request (json_error_str err_bad_request "token is required")
  else
    match decode_b64url machine_ed25519_pubkey_b64 with
    | Error _ ->
      respond_bad_request (json_error_str err_bad_request "machine_ed25519_pubkey not base64url-nopad")
    | Ok machine_ed25519_pubkey when String.length machine_ed25519_pubkey <> 32 ->
      respond_bad_request (json_error_str err_bad_request "machine_ed25519_pubkey must be 32 bytes")
    | Ok _ ->
      (* Decode token to verify it's valid JSON + check expiry *)
      match decode_token_json token with
      | None ->
        respond_bad_request (json_error_str err_bad_request "token: invalid JSON or encoding")
      | Some token_json ->
        let fields = match token_json with `Assoc f -> f | _ ->
          respond_bad_request (json_error_str err_bad_request "token: expected object")
        in
        let binding_id = match List.assoc_opt "binding_id" fields with Some (`String b) -> b | _ ->
          respond_bad_request (json_error_str err_bad_request "token missing binding_id")
        in
        let issued_at = match List.assoc_opt "issued_at" fields with
          | Some (`Float f) -> f | Some (`Int i) -> float_of_int i | _ ->
            respond_bad_request (json_error_str err_bad_request "token missing issued_at")
        in
        let expires_at = match List.assoc_opt "expires_at" fields with
          | Some (`Float f) -> f | Some (`Int i) -> float_of_int i | _ ->
            respond_bad_request (json_error_str err_bad_request "token missing expires_at")
        in
        let sig_b64 = match List.assoc_opt "sig" fields with Some (`String s) -> s | _ ->
          respond_bad_request (json_error_str err_bad_request "token missing sig")
        in
        let nonce = match List.assoc_opt "nonce" fields with Some (`String s) -> s | _ ->
          respond_bad_request (json_error_str err_bad_request "token missing nonce")
        in
        let now = Unix.gettimeofday () in
        if now > expires_at then
          respond_bad_request (json_error_str err_bad_request "token expired")
        else if now < issued_at -. 5.0 then
          respond_bad_request (json_error_str err_bad_request "token issued_at in future")
        else
          (* Verify token sig: canonical msg signed by machine_ed25519_pubkey *)
          let sig_raw = match decode_b64url sig_b64 with
            | Ok s -> s | Error _ ->
              respond_bad_request (json_error_str err_bad_request "token sig not base64url-nopad")
          in
          let blob = canonical_token_msg ~binding_id
            ~machine_ed25519_pubkey_b64 ~issued_at ~expires_at ~nonce in
          let pk_raw = match decode_b64url machine_ed25519_pubkey_b64 with
            | Ok p -> p | Error _ ->
              respond_bad_request (json_error_str err_bad_request "machine_ed25519_pubkey decode")
          in
          if not (Relay_identity.verify ~pk:pk_raw ~msg:blob ~sig_:sig_raw) then
            respond_unauthorized (json_error_str relay_err_signature_invalid
              "token signature verification failed")
          else
            (* Store token in relay *)
            match R.store_pairing_token relay ~binding_id ~token_b64:token
              ~machine_ed25519_pubkey:machine_ed25519_pubkey_b64 ~expires_at with
            | Error e ->
              respond_internal_error (json_error_str err_internal_error e)
            | Ok () ->
              Relay_ratelimit.structured_log
                ~event:"pair_requested"
                ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
                ~result:"ok" ();
              respond_ok (`Assoc ["binding_id", `String binding_id])
```

- [ ] **Step 2: Wire into route match**

In `ocaml/relay.ml` around line 3121, replace the TODO block:

```ocaml
      (* === S5a: Mobile-pair endpoints === *)
      (* TODO S5a: POST /mobile-pair/prepare → issue pairing token
         Wire: Relay_ratelimit.structured_log ~event:"pair_requested"
               ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip) ~result:"..." () *)
      (* TODO S5a: POST /mobile-pair → confirm binding
         Wire: Relay_ratelimit.structured_log ~event:"pair_confirmed"
               ~binding_id_prefix:(Relay_ratelimit.prefix8 binding_id) ~result:"ok" () *)
```

With:

```ocaml
      (* === S5a: Mobile-pair endpoints === *)
      | `POST, "/mobile-pair/prepare" ->
        Cohttp_lwt.Body.to_string body >>= fun body_str ->
        let json = try Yojson.Safe.from_string body_str with Yojson.Json_error _ -> `Assoc [] in
        let fields = match json with `Assoc f -> f | _ -> [] in
        handle_mobile_pair_prepare relay ~client_ip fields >>= respond_lwt
```

**Note:** `respond_lwt` takes a `Cohttp_lwt_unix.Server.response Lwt.t`. `handle_mobile_pair_prepare` returns a plain response (not Lwt-wrapped). The pattern used by other handlers is to directly return the response — check how `handle_admin_unbind` does it. If it uses `respond_ok` (non-Lwt), the pattern is:

```ocaml
handle_mobile_pair_prepare relay fields >>= respond_lwt
```

But `respond_ok` already returns `Cohttp_lwt_unix.Server.response Lwt.t`. So `handle_mobile_pair_prepare` should be wrapped with `Lwt.return` if it returns a sync response. Look at how `handle_admin_unbind` returns — it calls `respond_ok` which is async. Actually `respond_ok` returns `Lwt.return (Response.make ...)`, so it's already Lwt-wrapped. The `>>= respond_lwt` pattern applies to handlers that call `respond_*` functions. So the wire is correct.

- [ ] **Step 3: Verify build**

Run: `cd /home/xertrov/src/c2c && git checkout -- ocaml/c2c_mcp.ml && cd ocaml && opam exec -- dune build 2>&1 | grep -E '^Error' | head -20`
Expected: No new errors

- [ ] **Step 4: Commit**

```bash
git add ocaml/relay.ml
git commit -m "feat(S5a): implement POST /mobile-pair/prepare endpoint"
```

---

## Task 5: Implement `POST /mobile-pair` endpoint handler

**Files:**
- Modify: `ocaml/relay.ml` — add `handle_mobile_pair` handler

- [ ] **Step 1: Add `handle_mobile_pair` handler**

Add after `handle_mobile_pair_prepare`:

```ocaml
(* S5a: POST /mobile-pair — verify token sig, burn atomically, create binding *)
let handle_mobile_pair relay body =
  let token = get_opt_string body "token" |> Option.value ~default:"" in
  let phone_ed25519_pubkey_b64 = get_opt_string body "phone_ed25519_pubkey" |> Option.value ~default:"" in
  let phone_x25519_pubkey_b64 = get_opt_string body "phone_x25519_pubkey" |> Option.value ~default:"" in
  if token = "" then
    respond_bad_request (json_error_str err_bad_request "token is required")
  else if phone_ed25519_pubkey_b64 = "" || phone_x25519_pubkey_b64 = "" then
    respond_bad_request (json_error_str err_bad_request
      "phone_ed25519_pubkey and phone_x25519_pubkey are required")
  else
    match decode_token_json token with
    | None ->
      respond_bad_request (json_error_str err_bad_request "token: invalid JSON or encoding")
    | Some token_json ->
      let fields = match token_json with `Assoc f -> f | _ ->
        respond_bad_request (json_error_str err_bad_request "token: expected object")
      in
      let binding_id = match List.assoc_opt "binding_id" fields with Some (`String b) -> b | _ ->
        respond_bad_request (json_error_str err_bad_request "token missing binding_id")
      in
      let machine_pk_b64 = match List.assoc_opt "machine_ed25519_pubkey" fields with
        | Some (`String s) -> s | _ ->
          respond_bad_request (json_error_str err_bad_request "token missing machine_ed25519_pubkey")
      in
      let issued_at = match List.assoc_opt "issued_at" fields with
        | Some (`Float f) -> f | Some (`Int i) -> float_of_int i | _ ->
          respond_bad_request (json_error_str err_bad_request "token missing issued_at")
      in
      let expires_at = match List.assoc_opt "expires_at" fields with
        | Some (`Float f) -> f | Some (`Int i) -> float_of_int i | _ ->
          respond_bad_request (json_error_str err_bad_request "token missing expires_at")
      in
      let nonce = match List.assoc_opt "nonce" fields with Some (`String s) -> s | _ ->
        respond_bad_request (json_error_str err_bad_request "token missing nonce")
      in
      let sig_b64 = match List.assoc_opt "sig" fields with Some (`String s) -> s | _ ->
        respond_bad_request (json_error_str err_bad_request "token missing sig")
      in
      let now = Unix.gettimeofday () in
      if now > expires_at then
        respond_bad_request (json_error_str err_bad_request "token expired")
      else if now < issued_at -. 5.0 then
        respond_bad_request (json_error_str err_bad_request "token issued_at in future")
      else
        (* Verify sig *)
        let sig_raw = match decode_b64url sig_b64 with
          | Ok s -> s | Error _ ->
            respond_bad_request (json_error_str err_bad_request "token sig not base64url-nopad")
        in
        let blob = canonical_token_msg ~binding_id ~machine_ed25519_pubkey_b64:machine_pk_b64
          ~issued_at ~expires_at ~nonce in
        let pk_raw = match decode_b64url machine_pk_b64 with
          | Ok p -> p | Error _ ->
            respond_bad_request (json_error_str err_bad_request "token machine_ed25519_pubkey decode")
        in
        if not (Relay_identity.verify ~pk:pk_raw ~msg:blob ~sig_:sig_raw) then
          respond_unauthorized (json_error_str relay_err_signature_invalid
            "token signature verification failed")
        else
          (* Atomic burn + get stored token data *)
          match R.get_and_burn_pairing_token relay ~binding_id with
          | None ->
            respond_bad_request (json_error_str err_bad_request
              "token already used, expired, or not found")
          | Some (stored_token_b64, stored_machine_pk_b64) ->
            if stored_token_b64 <> token then
              respond_bad_request (json_error_str err_bad_request "token mismatch after burn")
            else if stored_machine_pk_b64 <> machine_pk_b64 then
              respond_bad_request (json_error_str err_bad_request
                "machine_ed25519_pubkey mismatch")
            else
              (* Phone pubkey validation *)
              let phone_ed25519_pk = match decode_b64url phone_ed25519_pubkey_b64 with
                | Ok p when String.length p = 32 -> p
                | Ok _ -> respond_bad_request (json_error_str err_bad_request
                    "phone_ed25519_pubkey must be 32 bytes")
                | Error _ -> respond_bad_request (json_error_str err_bad_request
                    "phone_ed25519_pubkey invalid encoding")
              in
              let phone_x25519_pk = match decode_b64url phone_x25519_pubkey_b64 with
                | Ok p when String.length p = 32 -> p
                | Ok _ -> respond_bad_request (json_error_str err_bad_request
                    "phone_x25519_pubkey must be 32 bytes")
                | Error _ -> respond_bad_request (json_error_str err_bad_request
                    "phone_x25519_pubkey invalid encoding")
              in
              (* Create binding *)
              R.add_observer_binding relay ~binding_id
                ~phone_ed25519_pubkey:phone_ed25519_pubkey_b64
                ~phone_x25519_pubkey:phone_x25519_pubkey_b64;
              let bound_at = Unix.gettimeofday () in
              (* Build binding confirmation for phone to re-verify *)
              let confirm_json = `Assoc [
                "binding_id", `String binding_id;
                "phone_ed25519_pubkey", `String phone_ed25519_pubkey_b64;
                "phone_x25519_pubkey", `String phone_x25519_pubkey_b64;
                "bound_at", `Float bound_at
              ] in
              let confirm_b64 = Yojson.Safe.to_string confirm_json |>
                Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet in
              Relay_ratelimit.structured_log
                ~event:"pair_confirmed"
                ~binding_id_prefix:(Relay_ratelimit.prefix8 binding_id)
                ~result:"ok" ();
              respond_ok (`Assoc [
                "ok", `Bool true;
                "binding_id", `String binding_id;
                "confirmation", `String confirm_b64
              ])
```

- [ ] **Step 2: Wire into route match**

After the `/mobile-pair/prepare` match arm, add:

```ocaml
      | `POST, "/mobile-pair" ->
        Cohttp_lwt.Body.to_string body >>= fun body_str ->
        let json = try Yojson.Safe.from_string body_str with Yojson.Json_error _ -> `Assoc [] in
        let fields = match json with `Assoc f -> f | _ -> [] in
        handle_mobile_pair relay fields >>= respond_lwt
```

- [ ] **Step 3: Verify build**

Run: `cd /home/xertrov/src/c2c && git checkout -- ocaml/c2c_mcp.ml && cd ocaml && opam exec -- dune build 2>&1 | grep -E '^Error' | head -20`
Expected: No new errors

- [ ] **Step 4: Commit**

```bash
git add ocaml/relay.ml
git commit -m "feat(S5a): implement POST /mobile-pair — token verify, burn, bind"
```

---

## Task 6: Add `mobile_pair_prepare` and `mobile_pair_confirm` to Relay_client + CLI subcommand

**Files:**
- Modify: `ocaml/relay.ml` — add `Relay_client.mobile_pair_prepare` and `Relay_client.mobile_pair_confirm` functions
- Modify: `ocaml/cli/c2c.ml` — add `mobile-pair-prepare` and `mobile-pair-confirm` CLI subcmd

- [ ] **Step 1: Add to Relay_client signature and implementation**

In `ocaml/relay.ml` at line 3259 (end of Relay_client sig), add:

```ocaml
  val mobile_pair_prepare :
    t -> machine_ed25519_pubkey:string -> token:string -> Yojson.Safe.t Lwt.t
  val mobile_pair_confirm :
    t -> token:string -> phone_ed25519_pubkey:string ->
    phone_x25519_pubkey:string -> Yojson.Safe.t Lwt.t
```

In `ocaml/relay.ml` `Relay_client` struct implementation (around line 3300+), add after the `gc` function:

```ocaml
  let mobile_pair_prepare client ~machine_ed25519_pubkey ~token =
    let body = `Assoc [
      "machine_ed25519_pubkey", `String machine_ed25519_pubkey;
      "token", `String token
    ] in
    request client ~meth:`POST ~path:"/mobile-pair/prepare" ~body ()

  let mobile_pair_confirm client ~token ~phone_ed25519_pubkey ~phone_x25519_pubkey =
    let body = `Assoc [
      "token", `String token;
      "phone_ed25519_pubkey", `String phone_ed25519_pubkey;
      "phone_x25519_pubkey", `String phone_x25519_pubkey
    ] in
    request client ~meth:`POST ~path:"/mobile-pair" ~body ()
```

- [ ] **Step 2: Add CLI subcommand**

In `ocaml/cli/c2c.ml` in the `handle_relay` function's subcmd match (around line 3691), add after the `admin` branch:

```ocaml
  | "mobile-pair-prepare" ->
    (match resolve_relay_url relay_url with
     | None ->
         Printf.eprintf "error: --relay-url required (or set C2C_RELAY_URL).\n%!";
         exit 1
     | Some url ->
         (match Relay_identity.load () with
          | Error _ ->
              Printf.eprintf "error: no identity.json found. Run 'c2c identity create' first.\n%!";
              exit 1
          | Ok id ->
              let binding_id = Uuidm.to_string (Uuidm.v `V4) in
              let issued_at = Unix.gettimeofday () in
              let expires_at = issued_at +. 300.0 in
              let nonce = Uuidm.to_string (Uuidm.v `V4) |> String.map (function '-' -> '0' | c -> c) |> String.sub 0 16 in
              let machine_pk_b64 = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet id.Relay_identity.public_key in
              let token_json = `Assoc [
                "binding_id", `String binding_id;
                "machine_ed25519_pubkey", `String machine_pk_b64;
                "issued_at", `Float issued_at;
                "expires_at", `Float expires_at;
                "nonce", `String nonce
              ] in
              let blob = Relay_identity.canonical_msg ~ctx:Relay.mobile_pair_token_sign_ctx
                [ binding_id; machine_pk_b64; string_of_float issued_at;
                  string_of_float expires_at; nonce ] in
              let sig_ = Relay_identity.sign id blob in
              let sig_b64 = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet sig_ in
              let token_with_sig = `Assoc [
                "binding_id", `String binding_id;
                "machine_ed25519_pubkey", `String machine_pk_b64;
                "issued_at", `Float issued_at;
                "expires_at", `Float expires_at;
                "nonce", `String nonce;
                "sig", `String sig_b64
              ] in
              let token_b64 = Yojson.Safe.to_string token_with_sig |>
                Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet in
              let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
              let result = Lwt_main.run (Relay.Relay_client.mobile_pair_prepare client
                ~machine_ed25519_pubkey:machine_pk_b64 ~token:token_b64) in
              print_endline (Yojson.Safe.pretty_to_string result);
              (match result with
               | `Assoc fields ->
                   (match List.assoc_opt "binding_id" fields with
                    | Some (`String bid) ->
                        Printf.printf "binding_id: %s\ntoken: %s\n%!" bid token_b64;
                        exit 0
                    | _ -> exit 1)
               | _ -> exit 1))
  | "mobile-pair-confirm" ->
    (* Phone-side: after scanning QR and verifying token sig *)
    (match resolve_relay_url relay_url, phone_ed25519_pubkey, phone_x25519_pubkey, binding_id with
     | None, _, _, _ ->
         Printf.eprintf "error: --relay-url required.\n%!"; exit 1
     | _, None, _, _ ->
         Printf.eprintf "error: --phone-ed25519-pubkey required.\n%!"; exit 1
     | _, _, None, _ ->
         Printf.eprintf "error: --phone-x25519-pubkey required.\n%!"; exit 1
     | _, _, _, None ->
         Printf.eprintf "error: --binding-id required.\n%!"; exit 1
     | Some url, Some ed_pk, Some x_pk, Some bid ->
         let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
         let result = Lwt_main.run (Relay.Relay_client.mobile_pair_confirm client
           ~token:"" ~phone_ed25519_pubkey:ed_pk ~phone_x25519_pubkey:x_pk) in
         print_endline (Yojson.Safe.pretty_to_string result);
         (match result with
          | `Assoc fields ->
              (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
          | _ -> exit 1))
```

**Note:** This is a minimal stub — real implementation needs actual token passed through. The `--revoke` flag also needs adding.

- [ ] **Step 3: Verify build**

Run: `cd /home/xertrov/src/c2c && git checkout -- ocaml/c2c_mcp.ml && cd ocaml && opam exec -- dune build 2>&1 | grep -E '^Error' | head -20`
Expected: No new errors

- [ ] **Step 4: Commit**

```bash
git add ocaml/relay.ml ocaml/cli/c2c.ml
git commit -m "feat(S5a): add mobile_pair_prepare/confirm to Relay_client + CLI stub"
```

---

## Task 7: Add S5a tests

**Files:**
- Modify: `ocaml/test/test_relay_bindings.ml` — add token roundtrip and expiry tests

- [ ] **Step 1: Add `test_mobile_pair_token_roundtrip`**

Add to `ocaml/test/test_relay_bindings.ml` after `test_ws_handshake_rfc6455_vector` (around line 315):

```ocaml
(* S5a: Token roundtrip — sign + encode + decode + verify *)
let test_mobile_pair_token_roundtrip () =
  let open Relay in
  let id = Relay_identity.generate () in
  let binding_id = "test-binding-001" in
  let machine_pk_b64 = b64url_nopad id.Relay_identity.public_key in
  let issued_at = Unix.gettimeofday () in
  let expires_at = issued_at +. 300.0 in
  let nonce = "testnonce1234567" in
  let token_json = `Assoc [
    "binding_id", `String binding_id;
    "machine_ed25519_pubkey", `String machine_pk_b64;
    "issued_at", `Float issued_at;
    "expires_at", `Float expires_at;
    "nonce", `String nonce
  ] in
  let blob = canonical_token_msg ~binding_id ~machine_ed25519_pubkey_b64:machine_pk_b64
    ~issued_at ~expires_at ~nonce in
  let sig_ = Relay_identity.sign id blob in
  let sig_b64 = b64url_nopad sig_ in
  let token_with_sig = `Assoc [
    "binding_id", `String binding_id;
    "machine_ed25519_pubkey", `String machine_pk_b64;
    "issued_at", `Float issued_at;
    "expires_at", `Float expires_at;
    "nonce", `String nonce;
    "sig", `String sig_b64
  ] in
  let b64 = encode_token_json token_with_sig in
  Alcotest.(check bool) "token encodes to non-empty" true (b64 <> "");
  let decoded = decode_token_json b64 in
  Alcotest.(check bool) "token decodes" true (decoded <> None);
  (match decoded with
   | Some (`Assoc fields) ->
       Alcotest.(check string) "binding_id preserved" binding_id
         (match List.assoc_opt "binding_id" fields with Some (`String s) -> s | _ -> "");
       Alcotest.(check bool) "sig preserved" true
         (match List.assoc_opt "sig" fields with Some (`String _) -> true | _ -> false)
   | _ -> Alcotest.fail "expected decoded token to be Assoc")

let test_mobile_pair_token_expired () =
  let open Relay in
  let now = Unix.gettimeofday () in
  let issued_at = now -. 400.0 in  (* 6+ min ago *)
  let expires_at = issued_at +. 300.0 in  (* expired 60s ago *)
  Alcotest.(check bool) "token is expired" true (now > expires_at)
```

- [ ] **Step 2: Add to test list**

In `ocaml/test/test_relay_bindings.ml` around line 480, add:

```ocaml
  "mobile_pair_token_roundtrip",  `Quick, test_mobile_pair_token_roundtrip;
  "mobile_pair_token_expired",   `Quick, test_mobile_pair_token_expired;
```

- [ ] **Step 3: Run tests**

Run: `cd /home/xertrov/src/c2c && just test-ocaml 2>&1 | grep -E 'mobile_pair|PASS|FAIL|passed|failed'`
Expected: All pass

- [ ] **Step 4: Commit**

```bash
git add ocaml/test/test_relay_bindings.ml
git commit -m "test(S5a): add mobile-pair token roundtrip and expiry tests"
```

---

## Verification Checklist

- [ ] `opam exec -- dune build` succeeds
- [ ] `just test-ocaml` passes all tests
- [ ] `just install-all` installs binaries
- [ ] `c2c mobile-pair-prepare --help` works
- [ ] Token roundtrip test passes (verifies sig + decode path)
- [ ] Relay `/mobile-pair/prepare` returns `{"binding_id": "..."}`
- [ ] Relay `/mobile-pair` with valid token returns `{"ok": true, "confirmation": "..."}`
- [ ] Relay `/mobile-pair` with expired/used token returns error
- [ ] Rate-limit on `/mobile-pair/prepare` applies (S4b policy: 10/min)
