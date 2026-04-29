(* test_relay_peer_relay.ml — #330 S1 peer_relay table tests *)

open Relay

let fail_fmt fmt = Printf.ksprintf (fun s -> failwith s) fmt

(* ---- helper: run a test inside a temp-dir sandbox ---- *)
let with_sqliteRelay_tempdir name f =
  let dir = Filename.temp_dir "c2c_test" name in
  Fun.protect ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ dir))) (fun () -> f dir)

(* ---- InMemoryRelay peer_relay table ---- *)

let test_inmemory_empty_on_create () =
  let t = InMemoryRelay.create () in
  match InMemoryRelay.peer_relay_of t ~name:"relay-b" with
  | None -> ()
  | Some _ -> fail_fmt "expected empty peer_relays on create"

let test_inmemory_add_and_lookup () =
  let t = InMemoryRelay.create () in
  let pr = { name = "relay-b"; url = "http://relay-b:9001"; identity_pk = "abc123" } in
  InMemoryRelay.add_peer_relay t pr;
  match InMemoryRelay.peer_relay_of t ~name:"relay-b" with
  | Some pr2 ->
      if pr2.name <> "relay-b" then fail_fmt "name mismatch";
      if pr2.url <> "http://relay-b:9001" then fail_fmt "url mismatch";
      if pr2.identity_pk <> "abc123" then fail_fmt "pk mismatch"
  | None -> fail_fmt "add_peer_relay should be findable"

let test_inmemory_add_replaces_existing () =
  let t = InMemoryRelay.create () in
  let pr1 = { name = "relay-b"; url = "http://old:9001"; identity_pk = "pk1" } in
  let pr2 = { name = "relay-b"; url = "http://new:9001"; identity_pk = "pk2" } in
  InMemoryRelay.add_peer_relay t pr1;
  InMemoryRelay.add_peer_relay t pr2;
  match InMemoryRelay.peer_relay_of t ~name:"relay-b" with
  | Some pr -> if pr.url <> "http://new:9001" then fail_fmt "add_peer_relay should replace"
  | None -> fail_fmt "should still be findable after replace"

let test_inmemory_list () =
  let t = InMemoryRelay.create () in
  let pr1 = { name = "relay-a"; url = "http://a:9001"; identity_pk = "pk_a" } in
  let pr2 = { name = "relay-b"; url = "http://b:9001"; identity_pk = "pk_b" } in
  InMemoryRelay.add_peer_relay t pr1;
  InMemoryRelay.add_peer_relay t pr2;
  let list = InMemoryRelay.peer_relays_list t in
  if List.length list <> 2 then fail_fmt "expected 2 entries, got %d" (List.length list);
  let names = List.map (fun pr -> pr.name) list |> List.sort String.compare in
  if names <> ["relay-a"; "relay-b"] then fail_fmt "names mismatch: %s" (String.concat "," names)

let test_inmemory_list_empty () =
  let t = InMemoryRelay.create () in
  let list = InMemoryRelay.peer_relays_list t in
  if list <> [] then fail_fmt "expected empty list on fresh relay"

let test_inmemory_multiple_relays () =
  let t = InMemoryRelay.create () in
  let relays = [
    { name = "relay-a"; url = "http://a:9001"; identity_pk = "pk_a" };
    { name = "relay-b"; url = "http://b:9001"; identity_pk = "pk_b" };
    { name = "relay-c"; url = "http://c:9001"; identity_pk = "pk_c" };
  ] in
  List.iter (InMemoryRelay.add_peer_relay t) relays;
  let list = InMemoryRelay.peer_relays_list t in
  if List.length list <> 3 then fail_fmt "expected 3 entries, got %d" (List.length list);
  List.iter (fun expected ->
    match InMemoryRelay.peer_relay_of t ~name:expected.name with
    | Some got -> if got.url <> expected.url then fail_fmt "url mismatch for %s" expected.name
    | None -> fail_fmt "relay %s not found" expected.name
  ) relays

(* ---- SqliteRelay peer_relay table ---- *)

let test_sqlite_empty_on_create () =
  with_sqliteRelay_tempdir "sqlite_peer" (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    match Relay.SqliteRelay.peer_relay_of t ~name:"relay-b" with
    | None -> ()
    | Some _ -> fail_fmt "expected empty peer_relays on sqlite create")

let test_sqlite_add_and_lookup () =
  with_sqliteRelay_tempdir "sqlite_peer2" (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let pr = { name = "relay-b"; url = "http://relay-b:9001"; identity_pk = "abc123" } in
    Relay.SqliteRelay.add_peer_relay t pr;
    match Relay.SqliteRelay.peer_relay_of t ~name:"relay-b" with
    | Some pr2 ->
        if pr2.name <> "relay-b" then fail_fmt "name mismatch";
        if pr2.url <> "http://relay-b:9001" then fail_fmt "url mismatch";
        if pr2.identity_pk <> "abc123" then fail_fmt "pk mismatch"
    | None -> fail_fmt "add_peer_relay should be findable in sqlite relay")

let test_sqlite_list () =
  with_sqliteRelay_tempdir "sqlite_peer3" (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let relays = [
      { name = "relay-x"; url = "http://x:9001"; identity_pk = "pk_x" };
      { name = "relay-y"; url = "http://y:9001"; identity_pk = "pk_y" };
    ] in
    List.iter (Relay.SqliteRelay.add_peer_relay t) relays;
    let list = Relay.SqliteRelay.peer_relays_list t in
    if List.length list <> 2 then fail_fmt "expected 2 entries, got %d" (List.length list))

(* ---- InMemoryRelay.create accepts ?peer_relays ---- *)

let test_inmemory_create_with_peer_relays () =
  let init = Hashtbl.create 2 in
  Hashtbl.add init "relay-b" { name = "relay-b"; url = "http://b:9001"; identity_pk = "init_pk" };
  let t = InMemoryRelay.create ~peer_relays:init () in
  match InMemoryRelay.peer_relay_of t ~name:"relay-b" with
  | Some pr -> if pr.identity_pk <> "init_pk" then fail_fmt "init_pk mismatch"
  | None -> fail_fmt "pre-seeded peer_relay should be findable"

(* ---- SqliteRelay.create accepts ?peer_relays ---- *)

let test_sqlite_create_with_peer_relays () =
  with_sqliteRelay_tempdir "sqlite_peer4" (fun dir ->
    let init = Hashtbl.create 2 in
    Hashtbl.add init "relay-b" { name = "relay-b"; url = "http://b:9001"; identity_pk = "init_pk2" };
    let t = Relay.SqliteRelay.create ~persist_dir:dir ~peer_relays:init () in
    match Relay.SqliteRelay.peer_relay_of t ~name:"relay-b" with
    | Some pr -> if pr.identity_pk <> "init_pk2" then fail_fmt "init_pk2 mismatch"
    | None -> fail_fmt "pre-seeded peer_relay should be findable in sqlite")

let () =
  let tests = [
    "inmemory empty on create", test_inmemory_empty_on_create;
    "inmemory add and lookup", test_inmemory_add_and_lookup;
    "inmemory add replaces existing", test_inmemory_add_replaces_existing;
    "inmemory list", test_inmemory_list;
    "inmemory list empty", test_inmemory_list_empty;
    "inmemory multiple relays", test_inmemory_multiple_relays;
    "inmemory create with peer_relays", test_inmemory_create_with_peer_relays;
    "sqlite empty on create", test_sqlite_empty_on_create;
    "sqlite add and lookup", test_sqlite_add_and_lookup;
    "sqlite list", test_sqlite_list;
    "sqlite create with peer_relays", test_sqlite_create_with_peer_relays;
  ] in
  let passed = ref 0 in
  let failed = ref 0 in
  List.iter (fun (name, test) ->
    try
      test ();
      Printf.printf "[PASS] %s\n%!" name;
      incr passed
    with e ->
      Printf.printf "[FAIL] %s: %s\n%!" name (Printexc.to_string e);
      incr failed
  ) tests;
  Printf.printf "\n%d passed, %d failed\n%!" !passed !failed;
  if !failed > 0 then exit 1
