# S5b: Device-Login OAuth Fallback — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add RFC 8628-style device-login flow as fallback when QR scanning isn't viable. Machine init → phone registers pubkeys via web → machine claims. Same binding result as S5a QR flow.

**Architecture:** New `device_pair_pending` in-memory table (keyed by `user_code`) + three relay HTTP endpoints + two new CLI subcommands. No new DB table (InMemory store is fine for v1 — pending records are short-lived). Rate-limit: 5/min/IP per user_code; 10 failed attempts invalidates code (per M1 spec §I2).

**Tech Stack:** OCaml, relay.ml, cli/c2c.ml

---

## File Structure

- Modify: `ocaml/relay.ml`
  - DDL `device_pair_pending` in-memory table (near `pairing_tokens`)
  - `handle_device_pair_init` — POST /device-pair/init
  - `handle_device_pair_register` — POST /device-pair/<user_code>
  - `handle_device_pair_claim` — GET /device-pair/<user_code> (for polling) or separate POST /device-pair/claim
  - Route entries for all three
  - Rate-limit structured logs
- Modify: `ocaml/relay_ratelimit.ml`
  - `/device-pair` policy already defined at line 66-67 (5/min)
- Modify: `ocaml/relay_client.ml` (or `relay.ml`'s client section)
  - `device_pair_init` — call POST /device-pair/init
  - `device_pair_register` — not needed from machine (phone calls directly)
  - `device_pair_poll` — call GET /device-pair/<user_code> to check if phone registered
- Modify: `ocaml/cli/c2c.ml`
  - Add `init` subcommand to `mobile-pair` — calls device_pair_init, prints user_code + URL
  - Add `claim` subcommand to `mobile-pair` — calls device_pair_poll to check + claim
- Create: `ocaml/test/test_relay_device_pair.ml`

---

## Task 1: In-Memory Pending Table

**Files:**
- Modify: `ocaml/relay.ml:295-301` (after pairing_tokens DDL)

- [ ] **Step 1: Write failing test**

```ocaml
(* test_relay_device_pair.ml *)
let test_device_pair_init_returns_user_code () =
  let relay = Relay.make () in
  let machine_pk = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
    (String.make 32 '\x01') in
  let rs = { rate_limit_buckets = Hashtbl.create 16; structured_log = (fun ~event ~result -> ()) } in
  let body = `Assoc ["machine_ed25519_pubkey", `String machine_pk] in
  let (ok, resp) = RS.auth_decision ~path:"/device-pair/init" in
  Alcotest.(check bool) "/device-pair/init self-auth" true ok
```

- [ ] **Step 2: Run test to verify it fails**

Run: `opam exec -- dune runtest ocaml/test/test_relay_device_pair.ml 2>&1 | head -20`
Expected: FAIL — file not found / undefined

- [ ] **Step 3: Add device_pair_pending DDL near pairing_tokens (relay.ml:295)**

```ocaml
(* In-memory pending device-pair records.
   Key: user_code (8-char base32). Value: record. *)
type device_pair_pending = {
  binding_id : string;
  machine_ed25519_pubkey : string;
  phone_ed25519_pubkey : string option;
  phone_x25519_pubkey : string option;
  created_at : float;
  expires_at : float;
  fail_count : int;
}

let device_pair_pending_table : (string, device_pair_pending) Hashtbl.t =
  Hashtbl.create 64
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `opam exec -- dune runtest ocaml/test/test_relay_device_pair.ml 2>&1`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ocaml/relay.ml
git commit -m "feat(S5b): add device_pair_pending in-memory table for OAuth flow"
```

---

## Task 2: POST /device-pair/init Handler

**Files:**
- Modify: `ocaml/relay.ml` (add handler, route entry)

- [ ] **Step 1: Write failing test**

```ocaml
let test_device_pair_init_returns_user_code () =
  let relay = Relay.make () in
  let machine_pk = Test_utils.gen_pk () in
  let body = `Assoc ["machine_ed25519_pubkey", `String machine_pk] in
  let resp = Relay.handle_device_pair_init relay ~client_ip:"127.0.0.1" body in
  let json = match resp with `Ok j -> j | _ -> `Assoc [] in
  let user_code = Yojson.Safe.Util.(json |> member "user_code" |> to_string_option) in
  Alcotest.(check (option string)) "user_code returned" (Some true) (Option.is_some user_code)
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `handle_device_pair_init` undefined

- [ ] **Step 3: Implement handle_device_pair_init**

```ocaml
(* S5b: POST /device-pair/init — create pending device-pair, return user_code *)
let handle_device_pair_init relay ~client_ip body =
  let open Yojson.Safe.Util in
  let machine_pk = get_opt_string body "machine_ed25519_pubkey" |> Option.value ~default:"" in
  if machine_pk = "" then respond_bad_request (json_error_str err_bad_request "machine_ed25519_pubkey required")
  else
    match decode_b64url machine_pk with
    | Error _ -> respond_bad_request (json_error_str err_bad_request "machine_ed25519_pubkey not base64url")
    | Ok pk when String.length pk <> 32 -> respond_bad_request (json_error_str err_bad_request "machine_ed25519_pubkey must be 32 bytes")
    | Ok _ ->
      (* Generate user_code: 8-char base32 (rfc4648 alphabet, no padding) *)
      let raw = Nocrypto.Rng.gen 5 |> Cstruct.to_string in
      let user_code = Base64.encode_string ~pad:false ~alphabet:Base64.base32_alphabet raw in
      (* Strip padding and lowercase for readability *)
      let user_code = String.map (function '=' -> "" | c -> String.make 1 c) user_code in
      let binding_id = "dev-" ^ user_code in
      let now = Unix.gettimeofday () in
      let expires_at = now +. 600.0 in (* 10-minute TTL per spec *)
      let pending = {
        binding_id;
        machine_ed25519_pubkey = machine_pk;
        phone_ed25519_pubkey = None;
        phone_x25519_pubkey = None;
        created_at = now;
        expires_at;
        fail_count = 0;
      } in
      Hashtbl.replace device_pair_pending_table user_code pending;
      Relay_ratelimit.structured_log ~event:"device_pair_init"
        ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
        ~user_code_prefix:(Relay_ratelimit.prefix8 user_code)
        ~result:"ok" ();
      respond_ok (`Assoc [
        "user_code", `String user_code;
        "device_code", `String binding_id; (* reuse binding_id as device_code per spec *)
        "poll_interval", `Float 2.0;
        "expires_at", `Float expires_at
      ])
```

- [ ] **Step 3b: Add route entry in router (around line 3951)**

```ocaml
| `POST, "/device-pair/init" ->
   (match body_of_req req body_ch with
    | Error _ -> respond_bad_request (json_error_str err_bad_request "invalid body")
    | Ok j -> handle_device_pair_init relay ~client_ip j)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `opam exec -- dune runtest ocaml/test/test_relay_device_pair.ml 2>&1`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ocaml/relay.ml
git commit -m "feat(S5b): POST /device-pair/init — create pending device-pair, return user_code"
```

---

## Task 3: POST /device-pair/<user_code> — Phone Registers Pubkeys

**Files:**
- Modify: `ocaml/relay.ml`

- [ ] **Step 1: Write failing test**

```ocaml
let test_device_pair_register_stores_phone_keys () =
  let relay = Relay.make () in
  let machine_pk = Test_utils.gen_pk () in
  let phone_ed = Test_utils.gen_pk () in
  let phone_x = Test_utils.gen_pk () in
  (* First init *)
  let init_body = `Assoc ["machine_ed25519_pubkey", `String machine_pk] in
  let `Ok init_json = Relay.handle_device_pair_init relay ~client_ip:"127.0.0.1" init_body in
  let user_code = Yojson.Safe.Util.(init_json |> member "user_code" |> to_string) in
  (* Register phone keys *)
  let reg_body = `Assoc [
    "phone_ed25519_pubkey", `String phone_ed;
    "phone_x25519_pubkey", `String phone_x
  ] in
  let resp = Relay.handle_device_pair_register relay ~client_ip:"127.0.0.1" ~user_code reg_body in
  Alcotest.(check bool) "register ok" true (resp |> function `Ok _ -> true | _ -> false)
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `handle_device_pair_register` undefined

- [ ] **Step 3: Implement handle_device_pair_register**

```ocaml
(* S5b: POST /device-pair/<user_code> — phone registers its pubkeys *)
let handle_device_pair_register relay ~client_ip ~user_code body =
  let open Yojson.Safe.Util in
  let phone_ed_pk = get_opt_string body "phone_ed25519_pubkey" |> Option.value ~default:"" in
  let phone_x_pk = get_opt_string body "phone_x25519_pubkey" |> Option.value ~default:"" in
  if phone_ed_pk = "" || phone_x_pk = "" then
    respond_bad_request (json_error_str err_bad_request "phone_ed25519_pubkey and phone_x25519_pubkey required")
  else
    match Hashtbl.find_opt device_pair_pending_table user_code with
    | None ->
      Relay_ratelimit.structured_log ~event:"device_pair_register"
        ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
        ~user_code_prefix:(Relay_ratelimit.prefix8 user_code)
        ~result:"user_code_not_found" ();
      respond_not_found (json_error_str err_not_found "user_code not found or expired")
    | Some pending ->
      if Unix.gettimeofday () > pending.expires_at then
        (Hashtbl.remove device_pair_pending_table user_code;
         respond_not_found (json_error_str err_not_found "user_code expired"))
      else
        match decode_b64url phone_ed_pk, decode_b64url phone_x_pk with
        | Error _, _ | _, Error _ ->
          respond_bad_request (json_error_str err_bad_request "pubkey not base64url")
        | Ok ed when String.length ed <> 32, _ | _, Ok x when String.length x <> 32 ->
          respond_bad_request (json_error_str err_bad_request "pubkeys must be 32 bytes")
        | Ok _ed, Ok _x ->
          let updated = { pending with
            phone_ed25519_pubkey = Some phone_ed_pk;
            phone_x25519_pubkey = Some phone_x_pk
          } in
          Hashtbl.replace device_pair_pending_table user_code updated;
          Relay_ratelimit.structured_log ~event:"device_pair_register"
            ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
            ~user_code_prefix:(Relay_ratelimit.prefix8 user_code)
            ~result:"ok" ();
          respond_ok (`Assoc ["ok", `Bool true])
```

- [ ] **Step 3b: Add route entry**

```ocaml
| `POST, path when starts_with path "/device-pair/" ->
  let user_code = String.sub path 13 (String.length path - 13) in
  (match body_of_req req body_ch with
   | Error _ -> respond_bad_request (json_error_str err_bad_request "invalid body")
   | Ok j -> handle_device_pair_register relay ~client_ip ~user_code j)
```

- [ ] **Step 4: Run test to verify it passes**

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ocaml/relay.ml
git commit -m "feat(S5b): POST /device-pair/<user_code> — phone registers pubkeys"
```

---

## Task 4: GET /device-pair/<user_code> — Machine Polls / Claims

**Files:**
- Modify: `ocaml/relay.ml`

- [ ] **Step 1: Write failing test**

```ocaml
let test_device_pair_poll_pending () =
  let relay = Relay.make () in
  let machine_pk = Test_utils.gen_pk () in
  let init_body = `Assoc ["machine_ed25519_pubkey", `String machine_pk] in
  let `Ok init_json = Relay.handle_device_pair_init relay ~client_ip:"127.0.0.1" init_body in
  let user_code = Yojson.Safe.Util.(init_json |> member "user_code" |> to_string) in
  let resp = Relay.handle_device_pair_poll relay ~client_ip:"127.0.0.1" ~user_code in
  let json = match resp with `Ok j -> j | _ -> `Assoc [] in
  let status = Yojson.Safe.Util.(json |> member "status" |> to_string) in
  Alcotest.(check string) "status pending" "pending" status
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `handle_device_pair_poll` undefined

- [ ] **Step 3: Implement handle_device_pair_poll**

```ocaml
(* S5b: GET /device-pair/<user_code> — machine polls for phone registration *)
let handle_device_pair_poll relay ~client_ip ~user_code =
  match Hashtbl.find_opt device_pair_pending_table user_code with
  | None ->
    respond_not_found (json_error_str err_not_found "user_code not found")
  | Some pending ->
    if Unix.gettimeofday () > pending.expires_at then
      (Hashtbl.remove device_pair_pending_table user_code;
       respond_not_found (json_error_str err_not_found "user_code expired"))
    else
      match pending.phone_ed25519_pubkey, pending.phone_x25519_pubkey with
      | None, None ->
        respond_ok (`Assoc ["status", `String "pending"; "user_code", `String user_code])
      | Some ed_pk, Some x_pk ->
        (* Phone has registered. Build the binding and burn. *)
        let () = R.add_observer_binding relay ~binding_id:pending.binding_id
          ~phone_ed25519_pubkey:ed_pk ~phone_x25519_pubkey:x_pk in
        let bound_at = Unix.gettimeofday () in
        let () = push_pseudo_registration_to_observers ~binding_id:pending.binding_id
          ~phone_ed_pk:ed_pk ~phone_x_pk:x_pk
          ~machine_ed_pk:pending.machine_ed25519_pubkey
          ~provenance_sig:"" ~bound_at in
        Hashtbl.remove device_pair_pending_table user_code;
        Relay_ratelimit.structured_log ~event:"device_pair_claimed"
          ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
          ~user_code_prefix:(Relay_ratelimit.prefix8 user_code)
          ~binding_id_prefix:(Relay_ratelimit.prefix8 pending.binding_id)
          ~result:"ok" ();
        respond_ok (`Assoc [
          "status", `String "claimed";
          "binding_id", `String pending.binding_id
        ])
      | _ ->
        respond_bad_request (json_error_str err_bad_request "incomplete registration")
```

- [ ] **Step 3b: Add GET route entry**

```ocaml
| `GET, path when starts_with path "/device-pair/" ->
  let user_code = String.sub path 13 (String.length path - 13) in
  handle_device_pair_poll relay ~client_ip ~user_code
```

- [ ] **Step 4: Run test to verify it passes**

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ocaml/relay.ml
git commit -m "feat(S5b): GET /device-pair/<user_code> — poll/claim device-pair"
```

---

## Task 5: CLI — mobile-pair init + claim Subcommands

**Files:**
- Modify: `ocaml/cli/c2c.ml:4019-4150` (mobile-pair cmd)
- Modify: `ocaml/relay.ml` (Relay_client section)

- [ ] **Step 1: Write failing test (placeholder — CLI test exists)**

Verify existing `mobile-pair` test structure

- [ ] **Step 2: Add Relay_client.device_pair_init**

```ocaml
let device_pair_init t ~machine_ed25519_pubkey =
  post t "/device-pair/init" (`Assoc [
    "machine_ed25519_pubkey", `String machine_ed25519_pubkey
  ])
```

- [ ] **Step 3: Add Relay_client.device_pair_poll**

```ocaml
let device_pair_poll t ~user_code =
  get t ("/device-pair/" ^ user_code)
```

- [ ] **Step 4: Add CLI `init` subcommand (relay_mobile_pair_cmd)**

In the `match subcmd with` block, add:

```ocaml
| "init" ->
  (* Get machine ed25519 pubkey from identity *)
  (match Relay_identity.get_public_key () with
   | None -> Printf.eprintf "error: no identity key found\n%!"; exit 1
   | Some machine_pk ->
     let pk_b64 = machine_pk |> Nocrypto.SEED.of_secret
       |> Option.get |> Nocrypto.B58.pk_of_seed |> Option.get
       |> Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
     in
     Lwt_main.run (Lwt.catch (fun () ->
       let%lwt result = Relay.Relay_client.device_pair_init client ~machine_ed25519_pubkey:pk_b64 in
       let json = Yojson.Safe.from_string result in
       let user_code = Yojson.Safe.Util.(json |> member "user_code" |> to_string) in
       let poll_interval = Yojson.Safe.Util.(json |> member "poll_interval" |> to_number) in
       Printf.printf "User code: %s\n" user_code;
       Printf.printf "Poll interval: %.0fs\n" poll_interval;
       Printf.printf "Enter this code on your phone at the relay URL.\n%!";
       Lwt.return_unit
     ) (fun e -> Printf.eprintf "error: %s\n%!" (Printexc.to_string e); Lwt.return_unit)))
```

- [ ] **Step 5: Add CLI `claim` subcommand**

```ocaml
| "claim" ->
  let user_code_arg =
    Cmdliner.Arg.(value & opt (some string) None & info [ "user-code" ]
       ~docv:"CODE" ~doc:"User code from device-pair init.")
  in
  (* Add user_code_arg to let+ binding above *)
  let+ subcmd = subcmd
  and+ relay_url = relay_url
  and+ token = token
  and+ user_code_arg = user_code_arg
  ...
  | "claim" ->
    (match user_code_arg with
     | None -> Printf.eprintf "error: --user-code required for claim\n%!"; exit 1
     | Some uc ->
       Lwt_main.run (Lwt.catch (fun () ->
         let rec poll () =
           let%lwt result = Relay.Relay_client.device_pair_poll client ~user_code:uc in
           let json = Yojson.Safe.from_string result in
           let status = Yojson.Safe.Util.(json |> member "status" |> to_string) in
           if status = "claimed" then
             (let binding_id = Yojson.Safe.Util.(json |> member "binding_id" |> to_string) in
              Printf.printf "Pairing complete! binding_id: %s\n%!" binding_id;
              Lwt.return_unit)
           else
             (Printf.printf "Waiting... status: %s\n%!" status;
              let%lwt () = Lwt_unix.sleep 2.0 in
              poll ())
         in
         poll ()
       ) (fun e -> Printf.eprintf "error: %s\n%!" (Printexc.to_string e); Lwt.return_unit)))
```

- [ ] **Step 6: Commit**

```bash
git add ocaml/cli/c2c.ml ocaml/relay.ml
git commit -m "feat(S5b): CLI init + claim subcommands for device-login flow"
```

---

## Task 6: Rate Limit — 10-Fail Invalidation

**Files:**
- Modify: `ocaml/relay.ml` (handle_device_pair_register)

- [ ] **Step 1: Add fail_count increment on bad registration attempt**

In `handle_device_pair_register`, when decoding fails or phone_pk mismatch:

```ocaml
| Some pending ->
  let new_fail = pending.fail_count + 1 in
  if new_fail >= 10 then
    (Hashtbl.remove device_pair_pending_table user_code;
     Relay_ratelimit.structured_log ~event:"device_pair_invalidated"
       ~source_ip_prefix:(Relay_ratelimit.prefix8 client_ip)
       ~user_code_prefix:(Relay_ratelimit.prefix8 user_code)
       ~result:"max_failures" ();
     respond_not_found (json_error_str err_not_found "user_code invalidated"))
  else
    Hashtbl.replace device_pair_pending_table user_code { pending with fail_count = new_fail };
    respond_bad_request (...)
```

- [ ] **Step 2: Run build**

Run: `just build 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add ocaml/relay.ml
git commit -m "feat(S5b): invalidate user_code after 10 failed registration attempts"
```

---

## Task 7: Contract Smoke Tests

**Files:**
- Create: `ocaml/test/test_relay_device_pair.ml`

- [ ] **Test: init → register → poll/claim full flow**

```ocaml
let test_full_device_pair_flow () =
  let relay = Relay.make () in
  let machine_pk = Test_utils.gen_pk () in
  let phone_ed = Test_utils.gen_pk () in
  let phone_x = Test_utils.gen_pk () in

  (* 1. Init *)
  let init_resp = Relay.handle_device_pair_init relay ~client_ip:"127.0.0.1"
    (`Assoc ["machine_ed25519_pubkey", `String machine_pk]) in
  let `Ok init_json = init_resp in
  let user_code = Yojson.Safe.Util.(init_json |> member "user_code" |> to_string) in

  (* 2. Poll → pending *)
  let poll_resp = Relay.handle_device_pair_poll relay ~client_ip:"127.0.0.1" ~user_code in
  let `Ok poll_json = poll_resp in
  let status = Yojson.Safe.Util.(poll_json |> member "status" |> to_string) in
  Alcotest.(check string) "initial status" "pending" status;

  (* 3. Phone registers *)
  let reg_resp = Relay.handle_device_pair_register relay ~client_ip:"127.0.0.2" ~user_code
    (`Assoc ["phone_ed25519_pubkey", `String phone_ed;
             "phone_x25519_pubkey", `String phone_x]) in
  Alcotest.(check bool) "register ok" true (reg_resp |> function `Ok _ -> true | _ -> false);

  (* 4. Poll → claimed, binding created *)
  let poll_resp2 = Relay.handle_device_pair_poll relay ~client_ip:"127.0.0.1" ~user_code in
  let `Ok poll_json2 = poll_resp2 in
  let status2 = Yojson.Safe.Util.(poll_json2 |> member "status" |> to_string) in
  Alcotest.(check string) "after register status" "claimed" status2;
  let binding_id = Yojson.Safe.Util.(poll_json2 |> member "binding_id" |> to_string) in
  Alcotest.(check bool) "binding_id starts with dev-" true (String.starts_with ~prefix:"dev-" binding_id);

  (* 5. Binding exists in observer_bindings *)
  let binding = R.get_observer_binding relay ~binding_id in
  Alcotest.(check bool) "binding exists" true (Option.is_some binding)
```

- [ ] **Step 2: Run full flow test**

Run: `opam exec -- dune runtest ocaml/test/test_relay_device_pair.ml 2>&1`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add ocaml/test/test_relay_device_pair.ml ocaml/relay.ml
git commit -m "feat(S5b): device-pair OAuth flow — full integration test"
```

---

## Cross-node references

- `ocaml/relay.ml` — existing S5a mobile-pair handlers (lines 3323-3468) for pattern reference
- `ocaml/relay_ratelimit.ml:66-67` — /device-pair rate limit policy already defined
- `ocaml/relay.ml:295-301` — pairing_tokens DDL (in-memory table pattern to follow)
- `ocaml/cli/c2c.ml:4019-4150` — mobile-pair CLI (pattern for init/claim subcommands)

## Spec coverage

| Requirement | Task |
|---|---|
| POST /device-pair/init returns {user_code, device_code, poll_interval} | Task 2 |
| POST /device-pair/<user_code> phone registers pubkeys | Task 3 |
| GET /device-pair/<user_code> poll + claim creates binding | Task 4 |
| Same binding result as QR flow (add_observer_binding) | Task 4 |
| 8-char base32 user_code | Task 2 |
| 10-minute TTL | Task 2 |
| Rate limit 5/min/IP | relay_ratelimit.ml:66-67 (already set) |
| 10 failed attempts invalidates code | Task 6 |
| CLI init + claim subcommands | Task 5 |
| Full integration test | Task 7 |