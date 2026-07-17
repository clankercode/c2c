(* test_relay_list_rooms_roster.ml — B118 + B229.

   The anonymous /list_rooms directory must expose public-room members as
   presentation-only recipient addresses `alias#room@relay`, never bare
   aliases and never any lease/host machine metadata (opaque_host_id,
   node_id, session_id, identity key).

   B229: gated rooms remain listable for discovery but their members array
   is redacted (empty) while member_count stays accurate — same non-member
   roster redaction as local-broker 4-level list_rooms.

   Coverage:
   1. InMemoryRelay.list_rooms: public members are `alias#room@relay` (actual
      room id), bare aliases absent.
   2. SqliteRelay.list_rooms: identical response shape to InMemoryRelay.
   3. No-leak: a member registered with distinctive opaque_host_id / node_id
      / session_id / identity_pk sentinels — none of those sentinel values
      appear anywhere in the serialized directory JSON (both backends).
   4. Round-trip: an emitted address parses back through the existing
      room-recipient parser (split_alias_host + host_acceptable +
      is_room_recipient + split '#') to recover (alias, room_id).
   5. Visibility: public and gated rooms remain listable; unlisted and
      private rooms remain omitted (both backends).
   6. HTTP: an anonymous GET /list_rooms against the production relay
      callback returns the formatted public members and no metadata leak.
   7. B229 gated roster redaction: listed gated room keeps member_count but
      members=[] (InMemory + Sqlite + HTTP). *)

open Alcotest

module RTSR = Relay_test_support_real

(* --- distinctive sentinels that must never appear in directory JSON --- *)
let sentinel_ohid = "b118zzhostid"      (* 12 lowercase hex-ish; opaque_host_id *)
let sentinel_node = "b118-node-SENTINEL"
let sentinel_sess = "b118-session-SENTINEL"
let sentinel_pk = "b118-identity-pk-SENTINEL"

(* --- JSON extraction helpers over a list_rooms result --- *)

let room_id_of = function
  | `Assoc fields ->
    (match List.assoc_opt "room_id" fields with
     | Some (`String s) -> s
     | _ -> failwith "room entry missing room_id")
  | _ -> failwith "room entry not an object"

let members_of = function
  | `Assoc fields ->
    (match List.assoc_opt "members" fields with
     | Some (`List ms) ->
       List.map (function `String s -> s
                        | _ -> failwith "member not a string") ms
     | _ -> failwith "room entry missing members")
  | _ -> failwith "room entry not an object"

let member_count_of = function
  | `Assoc fields ->
    (match List.assoc_opt "member_count" fields with
     | Some (`Int n) -> n
     | _ -> failwith "room entry missing member_count")
  | _ -> failwith "room entry not an object"

let find_room rooms room_id =
  List.find_opt (fun r -> room_id_of r = room_id) rooms

(* Serialize the whole directory and search for a substring. *)
let json_contains_substr (rooms : Yojson.Safe.t list) needle =
  let s = Yojson.Safe.to_string (`List rooms) in
  let re = Str.regexp_string needle in
  try ignore (Str.search_forward re s 0); true with Not_found -> false

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base
      (Printf.sprintf "c2c-relay-b118-%08x" (Random.bits ())) in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) |> ignore)
    (fun () -> f dir)

(* --- 1. InMemoryRelay: members formatted as alias#room@relay --- *)

let test_inmemory_members_formatted () =
  let t = Relay.InMemoryRelay.create () in
  let _ = Relay.InMemoryRelay.register t
      ~node_id:"n-alice" ~session_id:"s-alice" ~alias:"alice" () in
  let _ = Relay.InMemoryRelay.register t
      ~node_id:"n-bob" ~session_id:"s-bob" ~alias:"bob" () in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"alice" ~room_id:"b118-pub" () in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"bob" ~room_id:"b118-pub" () in
  let rooms = Relay.InMemoryRelay.list_rooms t in
  match find_room rooms "b118-pub" with
  | None -> fail "public room b118-pub not listed"
  | Some room ->
    let members = List.sort compare (members_of room) in
    check (list string) "members are alias#room@relay addresses"
      [ "alice#b118-pub@relay"; "bob#b118-pub@relay" ] members;
    (* bare aliases must be absent *)
    check bool "bare alias 'alice' absent" false (List.mem "alice" members);
    check bool "bare alias 'bob' absent" false (List.mem "bob" members)

(* --- 2. SqliteRelay: identical response shape --- *)

let test_sqlite_matches_inmemory_shape () =
  with_temp_dir (fun dir ->
    let build_backend register join list_rooms create =
      let t = create () in
      let _ = register t ~node_id:"n-alice" ~session_id:"s-alice" ~alias:"alice" in
      let _ = register t ~node_id:"n-bob" ~session_id:"s-bob" ~alias:"bob" in
      let _ = join t ~alias:"alice" ~room_id:"b118-pub" in
      let _ = join t ~alias:"bob" ~room_id:"b118-pub" in
      list_rooms t
    in
    let im =
      build_backend
        (fun t ~node_id ~session_id ~alias ->
           Relay.InMemoryRelay.register t ~node_id ~session_id ~alias ())
        (fun t ~alias ~room_id ->
           Relay.InMemoryRelay.join_room t ~alias ~room_id ())
        Relay.InMemoryRelay.list_rooms
        Relay.InMemoryRelay.create
    in
    let sq =
      build_backend
        (fun t ~node_id ~session_id ~alias ->
           Relay.SqliteRelay.register t ~node_id ~session_id ~alias ())
        (fun t ~alias ~room_id ->
           Relay.SqliteRelay.join_room t ~alias ~room_id ())
        Relay.SqliteRelay.list_rooms
        (fun () -> Relay.SqliteRelay.create ~persist_dir:dir ())
    in
    let members_sorted rooms =
      match find_room rooms "b118-pub" with
      | Some r -> List.sort compare (members_of r)
      | None -> fail "b118-pub not listed"
    in
    check (list string) "sqlite members == inmemory members"
      (members_sorted im) (members_sorted sq);
    check (list string) "sqlite members are alias#room@relay"
      [ "alice#b118-pub@relay"; "bob#b118-pub@relay" ] (members_sorted sq))

(* --- 3. No metadata leak, both backends --- *)

let no_leak_assertions rooms label =
  check bool (label ^ ": opaque_host_id sentinel absent") false
    (json_contains_substr rooms sentinel_ohid);
  check bool (label ^ ": node_id sentinel absent") false
    (json_contains_substr rooms sentinel_node);
  check bool (label ^ ": session_id sentinel absent") false
    (json_contains_substr rooms sentinel_sess);
  check bool (label ^ ": identity_pk sentinel absent") false
    (json_contains_substr rooms sentinel_pk);
  (* the formatted address IS present *)
  check bool (label ^ ": formatted address present") true
    (json_contains_substr rooms "carol#b118-leak@relay")

let test_inmemory_no_metadata_leak () =
  let t = Relay.InMemoryRelay.create () in
  let _ = Relay.InMemoryRelay.register t
      ~node_id:sentinel_node ~session_id:sentinel_sess ~alias:"carol"
      ~identity_pk:sentinel_pk ~opaque_host_id:(Some sentinel_ohid) () in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"carol" ~room_id:"b118-leak" () in
  let rooms = Relay.InMemoryRelay.list_rooms t in
  no_leak_assertions rooms "inmemory"

let test_sqlite_no_metadata_leak () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let _ = Relay.SqliteRelay.register t
        ~node_id:sentinel_node ~session_id:sentinel_sess ~alias:"carol"
        ~identity_pk:sentinel_pk ~opaque_host_id:(Some sentinel_ohid) () in
    let _ = Relay.SqliteRelay.join_room t ~alias:"carol" ~room_id:"b118-leak" () in
    let rooms = Relay.SqliteRelay.list_rooms t in
    no_leak_assertions rooms "sqlite")

(* --- 4. Round-trip through the existing recipient parser --- *)

(* Round-trip a single (alias, room_id) pair through BOTH parse orders:
   (a) the canonical reply classifier [is_room_recipient] on the FULL
       host-attached directory address (the order c2c_utils /
       schema_v1_msg_type_of_recipient uses to route a room reply); and
   (b) host-strip-then-classify (the @host-aware router order), which must
       leave `alias#room` and recover (alias, room_id) via split '#'.
   Both must agree that the address is a room addressed to (alias, room_id). *)
let assert_round_trip ~alias ~room_id =
  let addr = Relay.format_room_roster_address ~alias ~room_id in
  check string "emitted address"
    (Printf.sprintf "%s#%s@relay" alias room_id) addr;
  (* (a) canonical classifier on the FULL address -> room, never a DM. This
     is the case that matters for a 12-hex room id: the `#` suffix
     `<room>@relay` is not a bare 12-hex host hash. *)
  check bool ("full address is a room recipient (" ^ room_id ^ ")")
    true (C2c_mcp_helpers.is_room_recipient ~to_alias:addr);
  (* (b) host-strip order *)
  let base, host = Relay_host_routing.split_alias_host addr in
  check string "host stripped leaves alias#room"
    (Printf.sprintf "%s#%s" alias room_id) base;
  check (option string) "host is literal relay" (Some "relay") host;
  check bool "host_acceptable (self_host None)" true
    (Relay_host_routing.host_acceptable ~self_host:None host);
  check bool "host_acceptable (self_host Some other)" true
    (Relay_host_routing.host_acceptable ~self_host:(Some "some.relay.example") host);
  (* NB: we do NOT assert is_room_recipient on the *stripped* base here. The
     host-strip-first order is the @host-aware DM router's path, not a
     room-reply path; and for an all-12-hex room id the shared classifier
     treats a bare `alias#<12hex>` as a legacy host-hash DM (a pre-existing
     property of the address scheme, not introduced by B118). Room replies
     use the canonical full-address classifier asserted above, which is
     unambiguous because `@relay` keeps the `#` suffix non-12-hex. *)
  match String.split_on_char '#' base with
  | [ a; r ] ->
    check string "recovered alias" alias a;
    check string "recovered room_id" room_id r
  | _ -> fail "base did not split into [alias; room]"

let test_address_round_trips () =
  (* realistic grammar shapes: hyphen, underscore, mixed-case, digits *)
  assert_round_trip ~alias:"alice" ~room_id:"b118-pub";
  assert_round_trip ~alias:"lyra-quill" ~room_id:"swarm_lounge";
  assert_round_trip ~alias:"bob" ~room_id:"Room123";
  (* an all-lowercase 12-hex room id is within the canonical grammar; it must
     still round-trip via the canonical full-address classifier (reviewer
     edge case). *)
  assert_round_trip ~alias:"carol" ~room_id:"abcdef012345"

(* --- 5. Visibility filter preserved --- *)

let visibility_backend register join set_visibility list_rooms =
  (* register a member for each of the four visibilities, join a distinct
     room per visibility, then set that room's visibility. *)
  let _ = register ~node_id:"n-d" ~session_id:"s-d" ~alias:"dora" in
  List.iter (fun (room, vis) ->
      let _ = join ~alias:"dora" ~room_id:room in
      set_visibility ~room_id:room ~visibility:vis)
    [ "b118-public", "public"; "b118-gated", "gated";
      "b118-unlisted", "unlisted"; "b118-private", "private" ];
  let rooms = list_rooms () in
  let listed r = find_room rooms r <> None in
  (listed, rooms)

let test_inmemory_visibility_filter () =
  let t = Relay.InMemoryRelay.create () in
  let listed, _ =
    visibility_backend
      (fun ~node_id ~session_id ~alias ->
         Relay.InMemoryRelay.register t ~node_id ~session_id ~alias ())
      (fun ~alias ~room_id ->
         Relay.InMemoryRelay.join_room t ~alias ~room_id ())
      (fun ~room_id ~visibility ->
         Relay.InMemoryRelay.set_room_visibility t ~room_id ~visibility)
      (fun () -> Relay.InMemoryRelay.list_rooms t)
  in
  check bool "public listed" true (listed "b118-public");
  check bool "gated listed" true (listed "b118-gated");
  check bool "unlisted omitted" false (listed "b118-unlisted");
  check bool "private omitted" false (listed "b118-private")

let test_sqlite_visibility_filter () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let listed, _ =
      visibility_backend
        (fun ~node_id ~session_id ~alias ->
           Relay.SqliteRelay.register t ~node_id ~session_id ~alias ())
        (fun ~alias ~room_id ->
           Relay.SqliteRelay.join_room t ~alias ~room_id ())
        (fun ~room_id ~visibility ->
           Relay.SqliteRelay.set_room_visibility t ~room_id ~visibility)
        (fun () -> Relay.SqliteRelay.list_rooms t)
    in
    check bool "public listed" true (listed "b118-public");
    check bool "gated listed" true (listed "b118-gated");
    check bool "unlisted omitted" false (listed "b118-unlisted");
    check bool "private omitted" false (listed "b118-private"))

(* --- 5b. B229: gated roster redacted; public roster intact --- *)

let assert_gated_roster_redacted rooms ~gated_id ~public_id ~public_member =
  (match find_room rooms gated_id with
   | None -> fail (Printf.sprintf "gated room %s must be listed" gated_id)
   | Some gated ->
     check int "gated member_count preserved for discovery" 1
       (member_count_of gated);
     check (list string) "gated members redacted for anonymous directory" []
       (members_of gated);
     check bool "gated member address absent from directory JSON" false
       (json_contains_substr rooms (public_member ^ "#" ^ gated_id ^ "@relay")));
  (match find_room rooms public_id with
   | None -> fail (Printf.sprintf "public room %s must be listed" public_id)
   | Some pub ->
     check int "public member_count intact" 1 (member_count_of pub);
     check (list string) "public members still presentation addresses"
       [ public_member ^ "#" ^ public_id ^ "@relay" ]
       (List.sort compare (members_of pub)))

let test_inmemory_gated_roster_redacted () =
  let t = Relay.InMemoryRelay.create () in
  let _ =
    Relay.InMemoryRelay.register t ~node_id:"n-a" ~session_id:"s-a"
      ~alias:"alice" ()
  in
  let _ =
    Relay.InMemoryRelay.join_room t ~visibility:"gated" ~alias:"alice"
      ~room_id:"b229-gated" ()
  in
  let _ =
    Relay.InMemoryRelay.join_room t ~alias:"alice" ~room_id:"b229-public" ()
  in
  assert_gated_roster_redacted
    (Relay.InMemoryRelay.list_rooms t)
    ~gated_id:"b229-gated" ~public_id:"b229-public" ~public_member:"alice"

let test_sqlite_gated_roster_redacted () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let _ =
      Relay.SqliteRelay.register t ~node_id:"n-a" ~session_id:"s-a"
        ~alias:"alice" ()
    in
    let _ =
      Relay.SqliteRelay.join_room t ~visibility:"gated" ~alias:"alice"
        ~room_id:"b229-gated" ()
    in
    let _ =
      Relay.SqliteRelay.join_room t ~alias:"alice" ~room_id:"b229-public" ()
    in
    assert_gated_roster_redacted
      (Relay.SqliteRelay.list_rooms t)
      ~gated_id:"b229-gated" ~public_id:"b229-public" ~public_member:"alice")

(* --- 6. HTTP: anonymous GET /list_rooms --- *)

let test_http_anonymous_list_rooms () =
  RTSR.with_server (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let _ = Relay.InMemoryRelay.register relay
        ~node_id:sentinel_node ~session_id:sentinel_sess ~alias:"carol"
        ~identity_pk:sentinel_pk ~opaque_host_id:(Some sentinel_ohid) () in
    let _ = Relay.InMemoryRelay.join_room relay
        ~alias:"carol" ~room_id:"b118-http" () in
    (* B229: gated room with a real member must not expose the roster on
       anonymous GET /list_rooms. *)
    let _ = Relay.InMemoryRelay.join_room relay
        ~visibility:"gated" ~alias:"carol" ~room_id:"b229-http-gated" () in
    RTSR.call ~base_url ~meth:`GET ~path:"/list_rooms" () >|= fun r ->
    check int "GET /list_rooms is 200" 200 (RTSR.status_code r);
    let body = r.RTSR.body_text in
    let contains needle =
      let re = Str.regexp_string needle in
      try ignore (Str.search_forward re body 0); true with Not_found -> false
    in
    check bool "body carries formatted public address" true
      (contains "carol#b118-http@relay");
    check bool "gated member address redacted from body" false
      (contains "carol#b229-http-gated@relay");
    check bool "gated room still discoverable by id" true
      (contains "b229-http-gated");
    check bool "no bare alias field \"carol\" outside address" true
      (not (contains "\"carol\""));
    check bool "opaque_host_id sentinel absent" false (contains sentinel_ohid);
    check bool "node_id sentinel absent" false (contains sentinel_node);
    check bool "session_id sentinel absent" false (contains sentinel_sess);
    check bool "identity_pk sentinel absent" false (contains sentinel_pk);
    (* Parse rooms array from ok envelope and assert gated redaction shape. *)
    match Yojson.Safe.from_string body with
    | `Assoc fields ->
      (match List.assoc_opt "rooms" fields with
       | Some (`List rooms) ->
         assert_gated_roster_redacted rooms
           ~gated_id:"b229-http-gated" ~public_id:"b118-http"
           ~public_member:"carol"
       | _ -> fail "HTTP /list_rooms missing rooms array")
    | _ -> fail "HTTP /list_rooms body not an object")

(* --- 6b. Defensive directory-boundary filter: even when an out-of-grammar
   room id is created DIRECTLY via the backend join_room (bypassing the HTTP
   handle_join_room grammar guard — the legacy-persisted / backend-direct
   path), list_rooms omits it so no ambiguous alias#room@relay address is ever
   emitted. Both backends. --- *)

let test_inmemory_omits_out_of_grammar_room () =
  let t = Relay.InMemoryRelay.create () in
  let _ = Relay.InMemoryRelay.register t
      ~node_id:"n-x" ~session_id:"s-x" ~alias:"xavier" () in
  (* backend join_room does not validate grammar — create a `#`-bearing room *)
  let _ = Relay.InMemoryRelay.join_room t ~alias:"xavier" ~room_id:"bad#room" () in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"xavier" ~room_id:"ok-room" () in
  let rooms = Relay.InMemoryRelay.list_rooms t in
  check bool "out-of-grammar 'bad#room' omitted from directory" false
    (find_room rooms "bad#room" <> None);
  check bool "grammar-valid 'ok-room' still listed" true
    (find_room rooms "ok-room" <> None);
  check bool "no ambiguous address emitted" false
    (json_contains_substr rooms "bad#room")

let test_sqlite_omits_out_of_grammar_room () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let _ = Relay.SqliteRelay.register t
        ~node_id:"n-x" ~session_id:"s-x" ~alias:"xavier" () in
    let _ = Relay.SqliteRelay.join_room t ~alias:"xavier" ~room_id:"bad@room" () in
    let _ = Relay.SqliteRelay.join_room t ~alias:"xavier" ~room_id:"ok-room" () in
    let rooms = Relay.SqliteRelay.list_rooms t in
    check bool "out-of-grammar 'bad@room' omitted from directory" false
      (find_room rooms "bad@room" <> None);
    check bool "grammar-valid 'ok-room' still listed" true
      (find_room rooms "ok-room" <> None);
    check bool "no ambiguous address emitted" false
      (json_contains_substr rooms "bad@room"))

(* --- 7. Room-op boundary rejects out-of-grammar room ids (B118) so the
   directory address can never carry an extra `#`/`@` delimiter. --- *)

let test_http_join_rejects_bad_room_id () =
  RTSR.with_server (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let _ = Relay.InMemoryRelay.register relay
        ~node_id:"n-eve" ~session_id:"s-eve" ~alias:"eve" () in
    let join room_id =
      RTSR.call_json ~base_url ~meth:`POST ~path:"/join_room"
        ~body:(`Assoc [ ("alias", `String "eve"); ("room_id", `String room_id) ]) ()
    in
    let mentions_grammar r =
      let re = Str.regexp_string "room_id must match" in
      try ignore (Str.search_forward re r.RTSR.body_text 0); true
      with Not_found -> false
    in
    (* a `#` in the room id would inject a second alias/room separator *)
    join "bad#room" >>= fun r_hash ->
    (* an `@` in the room id would collide with the host separator *)
    join "bad@room" >>= fun r_at ->
    (* a well-formed room id passes the grammar gate (it then fails later on
       the room-op proof check in this signed-ops harness, i.e. NOT 400). *)
    join "b118-ok" >|= fun r_ok ->
    check int "join with '#' room id rejected (400)" 400 (RTSR.status_code r_hash);
    check bool "'#' rejection cites room_id grammar" true (mentions_grammar r_hash);
    check int "join with '@' room id rejected (400)" 400 (RTSR.status_code r_at);
    check bool "'@' rejection cites room_id grammar" true (mentions_grammar r_at);
    (* grammar gate fires BEFORE auth: the valid id is not a 400 grammar reject *)
    check bool "grammar-valid room id passes grammar gate (not 400)" true
      (RTSR.status_code r_ok <> 400);
    (* the out-of-grammar rooms never entered the directory *)
    let listed = Relay.InMemoryRelay.list_rooms relay in
    check bool "bad#room not in directory" false
      (find_room listed "bad#room" <> None);
    check bool "bad@room not in directory" false
      (find_room listed "bad@room" <> None))

let () =
  run "test_relay_list_rooms_roster"
    [ "roster formatting", [
        test_case "InMemory members are alias#room@relay" `Quick
          test_inmemory_members_formatted;
        test_case "Sqlite shape identical to InMemory" `Quick
          test_sqlite_matches_inmemory_shape;
        test_case "address round-trips through recipient parser" `Quick
          test_address_round_trips;
      ];
      "no metadata leak", [
        test_case "InMemory directory JSON leaks no metadata" `Quick
          test_inmemory_no_metadata_leak;
        test_case "Sqlite directory JSON leaks no metadata" `Quick
          test_sqlite_no_metadata_leak;
        test_case "HTTP anonymous /list_rooms formatted + no leak" `Quick
          test_http_anonymous_list_rooms;
        test_case "room-op boundary rejects out-of-grammar room ids" `Quick
          test_http_join_rejects_bad_room_id;
        test_case "InMemory list_rooms omits backend-direct out-of-grammar room"
          `Quick test_inmemory_omits_out_of_grammar_room;
        test_case "Sqlite list_rooms omits backend-direct out-of-grammar room"
          `Quick test_sqlite_omits_out_of_grammar_room;
      ];
      "visibility filter", [
        test_case "InMemory public/gated listed, unlisted/private omitted"
          `Quick test_inmemory_visibility_filter;
        test_case "Sqlite public/gated listed, unlisted/private omitted"
          `Quick test_sqlite_visibility_filter;
      ];
      "B229 gated roster redaction", [
        test_case "InMemory gated members redacted, public intact" `Quick
          test_inmemory_gated_roster_redacted;
        test_case "Sqlite gated members redacted, public intact" `Quick
          test_sqlite_gated_roster_redacted;
      ];
    ]
