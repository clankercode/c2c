(* test_relay_list_rooms_roster.ml — B118.

   The anonymous /list_rooms directory must expose room members as
   presentation-only recipient addresses `alias#room@relay`, never bare
   aliases and never any lease/host machine metadata (opaque_host_id,
   node_id, session_id, identity key).

   Coverage:
   1. InMemoryRelay.list_rooms: members are `alias#room@relay` (actual room
      id), bare aliases absent.
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
      callback returns the formatted members and no metadata leak. *)

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

let test_address_round_trips () =
  let addr =
    Relay.format_room_roster_address ~alias:"alice" ~room_id:"b118-pub" in
  check string "emitted address" "alice#b118-pub@relay" addr;
  (* split host: alias#room@relay -> ("alice#b118-pub", Some "relay") *)
  let base, host = Relay_host_routing.split_alias_host addr in
  check string "host stripped leaves alias#room" "alice#b118-pub" base;
  check (option string) "host is literal relay" (Some "relay") host;
  (* the "relay" host is accepted regardless of the relay's own self_host *)
  check bool "host_acceptable (self_host None)" true
    (Relay_host_routing.host_acceptable ~self_host:None host);
  check bool "host_acceptable (self_host Some other)" true
    (Relay_host_routing.host_acceptable ~self_host:(Some "some.relay.example") host);
  (* the base classifies as a room recipient, not a DM *)
  check bool "base is a room recipient"
    true (C2c_mcp_helpers.is_room_recipient ~to_alias:base);
  (* and split '#' recovers (alias, room_id) *)
  (match String.split_on_char '#' base with
   | [ alias; room ] ->
     check string "recovered alias" "alice" alias;
     check string "recovered room_id" "b118-pub" room
   | _ -> fail "base did not split into [alias; room]")

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

(* --- 6. HTTP: anonymous GET /list_rooms --- *)

let test_http_anonymous_list_rooms () =
  RTSR.with_server (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let _ = Relay.InMemoryRelay.register relay
        ~node_id:sentinel_node ~session_id:sentinel_sess ~alias:"carol"
        ~identity_pk:sentinel_pk ~opaque_host_id:(Some sentinel_ohid) () in
    let _ = Relay.InMemoryRelay.join_room relay
        ~alias:"carol" ~room_id:"b118-http" () in
    RTSR.call ~base_url ~meth:`GET ~path:"/list_rooms" () >|= fun r ->
    check int "GET /list_rooms is 200" 200 (RTSR.status_code r);
    let body = r.RTSR.body_text in
    let contains needle =
      let re = Str.regexp_string needle in
      try ignore (Str.search_forward re body 0); true with Not_found -> false
    in
    check bool "body carries formatted address" true
      (contains "carol#b118-http@relay");
    check bool "no bare alias field \"carol\" outside address" true
      (not (contains "\"carol\""));
    check bool "opaque_host_id sentinel absent" false (contains sentinel_ohid);
    check bool "node_id sentinel absent" false (contains sentinel_node);
    check bool "session_id sentinel absent" false (contains sentinel_sess);
    check bool "identity_pk sentinel absent" false (contains sentinel_pk))

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
      ];
      "visibility filter", [
        test_case "InMemory public/gated listed, unlisted/private omitted"
          `Quick test_inmemory_visibility_filter;
        test_case "Sqlite public/gated listed, unlisted/private omitted"
          `Quick test_sqlite_visibility_filter;
      ];
    ]
