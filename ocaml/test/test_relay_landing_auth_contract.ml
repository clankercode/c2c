(* B113: landing-page auth copy must match auth_decision's route classes.

   The relay landing page (Relay_server_html.landing_html) documents the
   operational auth model. B111 found it drifted from the code: it claimed
   every route except / and /health requires a Bearer token, and described
   /list_rooms as "public rooms only" although gated rooms are listed too.

   This suite is the contract check: the landing copy's auth-class sections
   are generated from the same route lists Relay_server_auth.auth_decision
   uses, and these tests cross-check both directions —

   1. every route in each exposed class list actually behaves per that
      class under auth_decision (list <-> behavior);
   2. every route in each class list appears inside the matching
      marker-delimited section of the landing HTML (list <-> copy);
   3. the stale claims from B111 stay dead (no "public rooms only",
      no blanket Bearer claim), and the required corrections are present
      (/list_rooms includes public AND gated; /list is not anonymously
      readable; aliases still surface via rosters + open history).

   If you change route classification in relay_server_auth.ml, the landing
   page regenerates automatically; if you hand-edit the landing copy out of
   sync, these tests fail. *)

let landing = Relay_server_html.landing_html

(* --- tiny substring helpers (no Str dependency) --- *)

let index_from_opt hay start needle =
  let hl = String.length hay and nl = String.length needle in
  if nl = 0 then Some start
  else
    let rec go i =
      if i + nl > hl then None
      else if String.sub hay i nl = needle then Some i
      else go (i + 1)
    in
    go start

let contains hay needle = index_from_opt hay 0 needle <> None

(* Extract the marker-delimited auth-class section from the landing page.
   Missing markers are themselves a contract violation. *)
let section cls =
  let s_marker = Printf.sprintf "<!-- auth-class:%s -->" cls in
  let e_marker = Printf.sprintf "<!-- /auth-class:%s -->" cls in
  match index_from_opt landing 0 s_marker with
  | None -> Alcotest.failf "landing page missing marker %s" s_marker
  | Some s ->
    let body_start = s + String.length s_marker in
    (match index_from_opt landing body_start e_marker with
     | None -> Alcotest.failf "landing page missing marker %s" e_marker
     | Some e -> String.sub landing body_start (e - body_start))

let code r = "<code>" ^ r ^ "</code>"

(* --- auth_decision harness --- *)

let decide ~path ?(include_dead = false) ?(token = Some "t0p") ?(auth = None)
    ?(ed = false) () =
  Relay_server_auth.auth_decision ~path ~include_dead ~token ~auth_header:auth
    ~ed25519_verified:ed

let allowed (ok, _) = ok

let bearer = Some "Bearer t0p"
let ed_hdr = Some "Ed25519 alias=a,ts=1,nonce=n,sig=s"

let class_name = function
  | Relay_server_auth.Anonymous_read -> "anonymous"
  | Relay_server_auth.Self_auth -> "self-auth"
  | Relay_server_auth.Bearer_admin -> "admin"
  | Relay_server_auth.Peer_ed25519 -> "peer"

let check_class ~path ?(include_dead = false) expected =
  Alcotest.(check string)
    (Printf.sprintf "classify_route %s%s" path
       (if include_dead then "?include_dead=1" else ""))
    (class_name expected)
    (class_name (Relay_server_auth.classify_route ~path ~include_dead))

(* === 1. class lists agree with auth_decision behavior === *)

let t_anonymous_routes_behave_anonymous () =
  List.iter
    (fun path ->
       check_class ~path Relay_server_auth.Anonymous_read;
       Alcotest.(check bool)
         (path ^ " allowed with token configured and no credentials") true
         (allowed (decide ~path ())))
    Relay_server_auth.anonymous_read_routes

let t_self_auth_routes_pass_outer_gate () =
  let routes =
    Relay_server_auth.self_auth_exact_routes
    @ List.map (fun p -> p ^ "test-suffix")
        Relay_server_auth.self_auth_prefix_routes
  in
  List.iter
    (fun path ->
       check_class ~path Relay_server_auth.Self_auth;
       Alcotest.(check bool)
         (path ^ " passes the outer gate (handler-verified)") true
         (allowed (decide ~path ())))
    routes

let t_admin_routes_are_bearer_only () =
  let routes =
    Relay_server_auth.admin_exact_routes
    @ List.map (fun p -> p ^ "test-suffix")
        Relay_server_auth.admin_prefix_routes
  in
  List.iter
    (fun path ->
       check_class ~path Relay_server_auth.Bearer_admin;
       Alcotest.(check bool) (path ^ " rejected without credentials") false
         (allowed (decide ~path ()));
       Alcotest.(check bool) (path ^ " rejected with Ed25519 header") false
         (allowed (decide ~path ~auth:ed_hdr ~ed:true ()));
       Alcotest.(check bool) (path ^ " allowed with Bearer token") true
         (allowed (decide ~path ~auth:bearer ())))
    routes;
  (* /list flips class on include_dead *)
  check_class ~path:"/list" ~include_dead:true Relay_server_auth.Bearer_admin;
  check_class ~path:"/list" Relay_server_auth.Peer_ed25519

let t_peer_examples_are_peer_routes () =
  List.iter
    (fun path ->
       check_class ~path Relay_server_auth.Peer_ed25519;
       Alcotest.(check bool)
         (path ^ " rejected without credentials when token set") false
         (allowed (decide ~path ()));
       Alcotest.(check bool) (path ^ " allowed with verified Ed25519") true
         (allowed (decide ~path ~auth:ed_hdr ~ed:true ())))
    Relay_server_html.peer_example_routes

(* === 2. class lists appear in the matching landing-page section === *)

let t_landing_anonymous_section_complete () =
  let sec = section "anonymous" in
  List.iter
    (fun r ->
       Alcotest.(check bool)
         (Printf.sprintf "anonymous section lists %s" r)
         true (contains sec (code r)))
    Relay_server_auth.anonymous_read_routes

let t_landing_admin_section_complete () =
  let sec = section "admin" in
  List.iter
    (fun r ->
       Alcotest.(check bool)
         (Printf.sprintf "admin section lists %s" r)
         true (contains sec (code r)))
    Relay_server_auth.admin_exact_routes;
  Alcotest.(check bool) "admin section covers include_dead" true
    (contains sec "include_dead");
  List.iter
    (fun p ->
       Alcotest.(check bool)
         (Printf.sprintf "admin section covers prefix %s" p)
         true (contains sec p))
    Relay_server_auth.admin_prefix_routes;
  Alcotest.(check bool) "admin section says Bearer" true
    (contains sec "Bearer")

let t_landing_self_auth_section_complete () =
  let sec = section "self-auth" in
  List.iter
    (fun r ->
       Alcotest.(check bool)
         (Printf.sprintf "self-auth section lists %s" r)
         true (contains sec (code r)))
    Relay_server_auth.self_auth_exact_routes;
  List.iter
    (fun p ->
       Alcotest.(check bool)
         (Printf.sprintf "self-auth section covers prefix %s" p)
         true (contains sec p))
    Relay_server_auth.self_auth_prefix_routes

let t_landing_peer_section () =
  let sec = section "peer" in
  Alcotest.(check bool) "peer section says Ed25519" true
    (contains sec "Ed25519");
  List.iter
    (fun r ->
       Alcotest.(check bool)
         (Printf.sprintf "peer section lists example %s" r)
         true (contains sec (code r)))
    Relay_server_html.peer_example_routes

(* === 3. B111 stale claims are gone; corrections are present === *)

let t_no_blanket_bearer_claim () =
  Alcotest.(check bool)
    "no 'All routes except ... require a Bearer token' claim" false
    (contains landing "All routes except")

let t_no_public_rooms_only_claim () =
  Alcotest.(check bool) "no 'public rooms only' claim" false
    (contains landing "public rooms only")

let t_list_rooms_includes_gated () =
  Alcotest.(check bool) "/list_rooms copy says public and gated" true
    (contains landing "public and gated")

let t_list_is_not_anonymous () =
  Alcotest.(check bool) "/list copy says not anonymously readable" true
    (contains landing "not anonymously readable")

let t_alias_visibility_explained () =
  Alcotest.(check bool) "copy explains listed-room member rosters" true
    (contains landing "member roster");
  Alcotest.(check bool) "copy explains sender aliases in open history" true
    (contains landing "sender aliases")

let () =
  Alcotest.run "relay_landing_auth_contract"
    [ ( "class-lists-vs-auth_decision",
        [ Alcotest.test_case "anonymous routes" `Quick
            t_anonymous_routes_behave_anonymous;
          Alcotest.test_case "self-auth routes" `Quick
            t_self_auth_routes_pass_outer_gate;
          Alcotest.test_case "admin routes" `Quick
            t_admin_routes_are_bearer_only;
          Alcotest.test_case "peer examples" `Quick
            t_peer_examples_are_peer_routes ] );
      ( "class-lists-vs-landing-copy",
        [ Alcotest.test_case "anonymous section" `Quick
            t_landing_anonymous_section_complete;
          Alcotest.test_case "admin section" `Quick
            t_landing_admin_section_complete;
          Alcotest.test_case "self-auth section" `Quick
            t_landing_self_auth_section_complete;
          Alcotest.test_case "peer section" `Quick t_landing_peer_section ] );
      ( "b111-copy-corrections",
        [ Alcotest.test_case "no blanket Bearer claim" `Quick
            t_no_blanket_bearer_claim;
          Alcotest.test_case "no public-rooms-only claim" `Quick
            t_no_public_rooms_only_claim;
          Alcotest.test_case "list_rooms includes gated" `Quick
            t_list_rooms_includes_gated;
          Alcotest.test_case "/list not anonymous" `Quick
            t_list_is_not_anonymous;
          Alcotest.test_case "alias visibility explained" `Quick
            t_alias_visibility_explained ] ) ]
