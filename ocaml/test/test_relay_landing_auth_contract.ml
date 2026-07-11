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
         (path ^ " passes the outer gate (handler policy is route-specific)")
         true
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
  let classifier_only = Relay_server_auth.self_auth_classifier_only_routes in
  List.iter
    (fun r ->
       if List.mem r classifier_only then
         (* classifier-only compatibility entries pass the outer gate but
            have no HTTP router branch (e.g. /send_room_invite — the live
            endpoint is /invite_room), so advertising them as active
            endpoints would be a false claim (review finding, iteration 2). *)
         Alcotest.(check bool)
           (Printf.sprintf
              "self-auth section does NOT advertise classifier-only %s" r)
           false (contains sec (code r))
       else
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

let t_classifier_only_routes_still_self_auth () =
  (* Behavior preservation: classifier-only entries must stay in the
     classifier (removing one would flip it to the peer default and change
     auth_decision), and each must genuinely be a member of the exact list. *)
  List.iter
    (fun r ->
       Alcotest.(check bool)
         (Printf.sprintf "%s is in self_auth_exact_routes" r)
         true
         (List.mem r Relay_server_auth.self_auth_exact_routes);
       check_class ~path:r Relay_server_auth.Self_auth;
       Alcotest.(check bool)
         (Printf.sprintf "%s still passes the outer gate" r)
         true
         (allowed (decide ~path:r ())))
    Relay_server_auth.self_auth_classifier_only_routes

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

(* === 2a. bidirectional route-token check ===

   Listing-direction checks (above) prove every classified route is
   advertised in its section. This is the reverse direction (iteration-3
   review): every <code> token advertised inside a marked section must
   belong to that section's class, so hand-adding e.g. <code>/send</code>
   to the anonymous section fails the contract. *)

let code_open = "<code>"
let code_close = "</code>"

let code_tokens frag =
  let rec go acc start =
    match index_from_opt frag start code_open with
    | None -> List.rev acc
    | Some i ->
      let b = i + String.length code_open in
      (match index_from_opt frag b code_close with
       | None -> List.rev acc
       | Some e ->
         go (String.sub frag b (e - b) :: acc) (e + String.length code_close))
  in
  go [] 0

let check_only_allowed sec_name allowed_tokens =
  let sec = section sec_name in
  List.iter
    (fun tok ->
       Alcotest.(check bool)
         (Printf.sprintf "%s section token %S belongs to that class" sec_name
            tok)
         true
         (List.mem tok allowed_tokens))
    (code_tokens sec)

let t_sections_advertise_only_own_class () =
  check_only_allowed "anonymous" Relay_server_auth.anonymous_read_routes;
  check_only_allowed "admin"
    (Relay_server_auth.admin_exact_routes
     @ ["/list?include_dead=1"]
     @ List.map (fun p -> p ^ "*") Relay_server_auth.admin_prefix_routes);
  check_only_allowed "self-auth"
    ((List.filter
        (fun r ->
           not (List.mem r Relay_server_auth.self_auth_classifier_only_routes))
        Relay_server_auth.self_auth_exact_routes)
     @ List.map (fun p -> p ^ "*") Relay_server_auth.self_auth_prefix_routes
     (* the prose names the operator switch for the legacy unsigned room-op
        dev gate (B114: unsigned rejected by default; =0 on a token-less
        relay is the only opt-out); it is not a route *)
     @ ["C2C_REQUIRE_SIGNED_ROOM_OPS=0"]);
  (* peer tokens have no exhaustive list (default class): every advertised
     token must CLASSIFY as a peer route, after normalizing the
     <alias> placeholder *)
  List.iter
    (fun tok ->
       (* html-unescape just the <alias> placeholder pattern *)
       let path =
         match index_from_opt tok 0 "&lt;alias&gt;" with
         | None -> tok
         | Some i ->
           String.sub tok 0 i ^ "x"
           ^ String.sub tok
               (i + String.length "&lt;alias&gt;")
               (String.length tok - i - String.length "&lt;alias&gt;")
       in
       check_class ~path Relay_server_auth.Peer_ed25519)
    (code_tokens (section "peer"))

(* === 2c. endpoint-table method pins ===

   Iteration-3 review: the <pre> endpoint table advertised GET /gc while the
   router only matches POST /gc — a caller following the page gets a 404.
   Pin every documented method+path pair (verified against the `(`GET|`POST),
   "<path>"` branches of Relay_server.make_callback in ocaml/relay.ml). *)

let documented_endpoints =
  [ "GET  /health"; "GET  /list"; "GET  /list_rooms"; "GET  /dead_letter";
    "POST /gc"; "GET  /device-login"; "POST /register"; "POST /heartbeat";
    "POST /send"; "POST /send_all"; "POST /poll_inbox"; "POST /peek_inbox";
    "POST /join_room"; "POST /leave_room"; "POST /send_room";
    "POST /room_history" ]

let t_endpoint_table_methods () =
  List.iter
    (fun line ->
       Alcotest.(check bool)
         (Printf.sprintf "endpoint table advertises %S" line)
         true (contains landing line))
    documented_endpoints;
  Alcotest.(check bool) "no 'GET  /gc' (router only matches POST /gc)" false
    (contains landing "GET  /gc")

(* === 2b. semantic phrase pinning ===

   Substring checks on route names alone would let the surrounding prose
   drift (review finding, 2026-07-11): "no credentials" could become
   "credentials", or the self-auth section could (as the first cut of this
   slice did) claim every handler verifies a proof when poll/peek without an
   Ed25519 header, /binding/* revocation, and legacy unsigned room ops do
   not. Pin the load-bearing phrase of each class section, and ban the known
   false claims page-wide. This is deliberately a lightweight textual
   contract, not a semantic parser: it forces any meaning-changing edit to
   consciously update this test in the same commit. *)

let check_phrase sec_name phrase =
  Alcotest.(check bool)
    (Printf.sprintf "%s section pins phrase %S" sec_name phrase)
    true
    (contains (section sec_name) phrase)

let t_section_semantics_pinned () =
  check_phrase "anonymous" "no credentials needed";
  check_phrase "peer" "requires a per-request Ed25519";
  check_phrase "peer" "Bearer tokens are rejected";
  check_phrase "admin" "operator Bearer token only";
  check_phrase "admin" "Ed25519 rejected";
  (* self-auth must NOT claim a uniform handler check (iteration-2 review:
     headerless poll/peek and bare-ID /binding/* apply no authorization at
     all); it must describe an outer-gate bypass with route-specific policy
     AND disclose the legacy/unauthenticated acceptance paths (B111:
     unsigned room ops, envelope-less /send_room, headerless poll/peek,
     bare-ID /binding/* revoke). *)
  check_phrase "self-auth" "bypass the outer header-auth gate";
  check_phrase "self-auth" "route-specific";
  check_phrase "self-auth" "no check at all";
  check_phrase "self-auth" "legacy";
  check_phrase "self-auth" "C2C_REQUIRE_SIGNED_ROOM_OPS"

let t_no_blanket_proof_claim () =
  (* Iteration-1 copy claimed "the handler verifies a proof" for the whole
     self-auth class; iteration-2 copy claimed each handler "applies its own
     authorization" — both false for headerless poll/peek and bare-ID
     /binding/* revoke. Keep both phrases dead. *)
  Alcotest.(check bool) "no blanket 'verifies a proof' claim" false
    (contains landing "verifies a proof");
  Alcotest.(check bool) "no blanket 'applies its own authorization' claim"
    false
    (contains landing "applies its own authorization")

let t_dev_mode_disclosed () =
  (* auth_decision preserves tokenless dev mode: peer and admin routes allow
     credential-free requests when no server token is configured
     (check_auth None _ = true; peer default falls through to token = None).
     The unconditional production-mode wording of iteration 2 was flagged as
     inaccurate; the copy must scope the Ed25519/Bearer/"/list is not
     anonymous" claims to configured-token (production) mode and disclose
     dev mode. *)
  Alcotest.(check bool) "peer route allowed without creds in dev mode" true
    (allowed (decide ~path:"/send" ~token:None ()));
  Alcotest.(check bool) "/list allowed without creds in dev mode" true
    (allowed (decide ~path:"/list" ~token:None ()));
  Alcotest.(check bool) "admin route allowed without creds in dev mode" true
    (allowed (decide ~path:"/gc" ~token:None ()));
  Alcotest.(check bool) "copy scopes auth classes to configured-token mode"
    true
    (contains landing "when the operator has configured a server token");
  Alcotest.(check bool) "copy discloses dev mode" true
    (contains landing "dev mode");
  Alcotest.(check bool) "copy says dev mode skips peer/admin auth" true
    (contains landing "peer and admin routes accept unauthenticated requests")

(* === 3. B111 stale claims are gone; corrections are present === *)

let t_no_blanket_bearer_claim () =
  Alcotest.(check bool)
    "no 'All routes except ... require a Bearer token' claim" false
    (contains landing "All routes except")

let t_no_public_rooms_only_claim () =
  (* Ban the whole "public rooms" phrasing, not just the "public rooms only"
     variant: the directory lists public AND gated rooms, so any "public
     rooms" wording ("what public rooms exist?", review finding 2026-07-11)
     misdescribes it. Correct copy says "public and gated rooms" /
     "public + gated", which this substring does not match. *)
  Alcotest.(check bool) "no 'public rooms' phrasing anywhere" false
    (contains landing "public rooms")

let t_list_rooms_includes_gated () =
  Alcotest.(check bool) "/list_rooms copy says public and gated" true
    (contains landing "public and gated")

let t_list_is_not_anonymous () =
  (* Scoped to token-configured (production) relays: in tokenless dev mode
     /list IS anonymously readable (see t_dev_mode_disclosed). *)
  Alcotest.(check bool)
    "/list copy says not anonymously readable, scoped to token-configured"
    true
    (contains landing "not anonymously readable on a token-configured relay")

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
          Alcotest.test_case "peer section" `Quick t_landing_peer_section;
          Alcotest.test_case "classifier-only routes" `Quick
            t_classifier_only_routes_still_self_auth;
          Alcotest.test_case "sections advertise only own class" `Quick
            t_sections_advertise_only_own_class;
          Alcotest.test_case "endpoint table methods" `Quick
            t_endpoint_table_methods;
          Alcotest.test_case "section semantics pinned" `Quick
            t_section_semantics_pinned;
          Alcotest.test_case "no blanket proof claim" `Quick
            t_no_blanket_proof_claim;
          Alcotest.test_case "dev mode disclosed" `Quick
            t_dev_mode_disclosed ] );
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
