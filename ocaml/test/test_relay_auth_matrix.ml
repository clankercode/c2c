(* L2/4 hard-cut auth matrix.

   (peer|admin|unauth) × (bearer|ed25519|none) × (token configured?)

   Peer routes: Ed25519 only.
   Admin routes: /gc, /dead_letter, /list?include_dead=1 — Bearer only.
   Unauth: /, /health — always allowed. *)

open Relay.Relay_server

let decide ?(path="/send") ?(include_dead=false) ?(token=Some "t0p")
           ?(auth=None) ?(ed=false) () =
  auth_decision ~path ~include_dead ~token ~auth_header:auth
    ~ed25519_verified:ed

let allowed (ok, _) = ok
let msg (_, m) = match m with Some s -> s | None -> ""

let bearer = Some "Bearer t0p"
let bearer_wrong = Some "Bearer nope"
let ed_hdr = Some "Ed25519 alias=a,ts=1,nonce=n,sig=s"

(* --- Unauth routes --- *)

let t_health_no_auth () =
  Alcotest.(check bool) "/health allowed without auth" true
    (allowed (decide ~path:"/health" ~token:(Some "x") ()))

let t_root_no_auth () =
  Alcotest.(check bool) "/ allowed without auth" true
    (allowed (decide ~path:"/" ()))

let t_list_rooms_no_auth () =
  Alcotest.(check bool) "/list_rooms allowed without auth (read-only)" true
    (allowed (decide ~path:"/list_rooms" ~token:(Some "x") ()))

let t_room_history_no_auth () =
  Alcotest.(check bool) "/room_history allowed without auth (read-only)" true
    (allowed (decide ~path:"/room_history" ~token:(Some "x") ()))

(* --- Peer routes (Ed25519 only) --- *)

let t_peer_ed25519_ok () =
  Alcotest.(check bool) "peer + verified Ed25519 ok" true
    (allowed (decide ~ed:true ~auth:ed_hdr ()))

let t_peer_bearer_rejected () =
  let r = decide ~auth:bearer () in
  Alcotest.(check bool) "peer + Bearer rejected" false (allowed r);
  Alcotest.(check bool) "error names Ed25519 requirement" true
    (let m = msg r in
     let has s = try ignore (Str.search_forward (Str.regexp_string s) m 0); true
                 with Not_found -> false in
     has "Ed25519" && has "admin-only")

let t_peer_no_auth_rejected_when_token_set () =
  Alcotest.(check bool) "peer + no auth rejected (token set)" false
    (allowed (decide ()))

let t_peer_no_auth_allowed_in_dev_mode () =
  Alcotest.(check bool) "peer + no auth allowed when token=None" true
    (allowed (decide ~token:None ()))

(* --- Admin routes (Bearer only) --- *)

let t_admin_gc_bearer_ok () =
  Alcotest.(check bool) "/gc + Bearer ok" true
    (allowed (decide ~path:"/gc" ~auth:bearer ()))

let t_admin_dead_letter_bearer_ok () =
  Alcotest.(check bool) "/dead_letter + Bearer ok" true
    (allowed (decide ~path:"/dead_letter" ~auth:bearer ()))

let t_admin_list_include_dead_bearer_ok () =
  Alcotest.(check bool) "/list?include_dead=1 + Bearer ok" true
    (allowed (decide ~path:"/list" ~include_dead:true ~auth:bearer ()))

let t_plain_list_is_peer () =
  (* /list without include_dead stays a peer route: Bearer must be rejected. *)
  Alcotest.(check bool) "/list (no include_dead) + Bearer rejected" false
    (allowed (decide ~path:"/list" ~auth:bearer ()))

let t_admin_ed25519_rejected () =
  let r = decide ~path:"/gc" ~auth:ed_hdr ~ed:true () in
  Alcotest.(check bool) "/gc + Ed25519 rejected" false (allowed r);
  Alcotest.(check bool) "error names Bearer requirement" true
    (let m = msg r in
     try ignore (Str.search_forward (Str.regexp_string "Bearer") m 0); true
     with Not_found -> false)

let t_admin_wrong_bearer_rejected () =
  Alcotest.(check bool) "/gc + wrong Bearer rejected" false
    (allowed (decide ~path:"/gc" ~auth:bearer_wrong ()))

let t_admin_no_auth_rejected () =
  Alcotest.(check bool) "/gc + no auth rejected" false
    (allowed (decide ~path:"/gc" ()))

let t_admin_no_token_configured_allows () =
  (* Dev mode: when server has no Bearer token configured, admin routes
     fall through to check_auth None = true. *)
  Alcotest.(check bool) "/gc + no auth allowed when token=None (dev)" true
    (allowed (decide ~path:"/gc" ~token:None ()))

(* --- Bootstrap route: /register must bypass outer auth (adb152f) ---
   /register uses in-body Ed25519 proof; handle_register does its own
   crypto verification. The outer auth_decision must always allow it
   through — otherwise new registrations fail in prod mode before the
   body is even inspected. *)

let t_register_allowed_no_auth_prod () =
  Alcotest.(check bool) "/register allowed with no auth in prod mode" true
    (allowed (decide ~path:"/register" ~token:(Some "t0p") ~auth:None ~ed:false ()))

let t_register_allowed_with_ed25519_prod () =
  Alcotest.(check bool) "/register allowed with Ed25519 header in prod mode" true
    (allowed (decide ~path:"/register" ~token:(Some "t0p") ~auth:ed_hdr ~ed:true ()))

let t_register_allowed_dev_mode () =
  Alcotest.(check bool) "/register allowed in dev mode (no token)" true
    (allowed (decide ~path:"/register" ~token:None ~auth:None ~ed:false ()))

let () =
  Alcotest.run "relay_auth_matrix" [
    "unauth", [
      Alcotest.test_case "/health no auth" `Quick t_health_no_auth;
      Alcotest.test_case "/ no auth" `Quick t_root_no_auth;
      Alcotest.test_case "/list_rooms no auth" `Quick t_list_rooms_no_auth;
      Alcotest.test_case "/room_history no auth" `Quick t_room_history_no_auth;
    ];
    "peer", [
      Alcotest.test_case "Ed25519 ok" `Quick t_peer_ed25519_ok;
      Alcotest.test_case "Bearer rejected" `Quick t_peer_bearer_rejected;
      Alcotest.test_case "no auth rejected (token set)" `Quick
        t_peer_no_auth_rejected_when_token_set;
      Alcotest.test_case "no auth allowed (dev, no token)" `Quick
        t_peer_no_auth_allowed_in_dev_mode;
    ];
    "bootstrap", [
      Alcotest.test_case "/register allowed no auth prod mode" `Quick
        t_register_allowed_no_auth_prod;
      Alcotest.test_case "/register allowed Ed25519 prod mode" `Quick
        t_register_allowed_with_ed25519_prod;
      Alcotest.test_case "/register allowed dev mode" `Quick
        t_register_allowed_dev_mode;
    ];
    "admin", [
      Alcotest.test_case "/gc Bearer ok" `Quick t_admin_gc_bearer_ok;
      Alcotest.test_case "/dead_letter Bearer ok" `Quick t_admin_dead_letter_bearer_ok;
      Alcotest.test_case "/list?include_dead=1 Bearer ok" `Quick
        t_admin_list_include_dead_bearer_ok;
      Alcotest.test_case "/list plain is peer" `Quick t_plain_list_is_peer;
      Alcotest.test_case "Ed25519 on /gc rejected" `Quick t_admin_ed25519_rejected;
      Alcotest.test_case "wrong Bearer rejected" `Quick t_admin_wrong_bearer_rejected;
      Alcotest.test_case "/gc no auth rejected" `Quick t_admin_no_auth_rejected;
      Alcotest.test_case "/gc no token configured allows" `Quick
        t_admin_no_token_configured_allows;
    ];
  ]
