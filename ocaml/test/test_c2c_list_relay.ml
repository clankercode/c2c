(* test_c2c_list_relay — H6 (friction-cn): relay-merged `c2c list --relay`
   with identity kind/scope labeling. Rows A053-A056/A060-A064/A080/A094;
   backlog B097 gap.

   The merged view labels what each entry IS instead of flattening two
   namespaces: a LOCAL row is a session alias on this machine's broker; a
   RELAY row is an alias@host_id registration anchored to a machine identity
   key. `identity_kind` = what the row is ("local"/"relay"); `identity_scope`
   = where the identity is registered ("local"/"relay"/"both"). Self-identity
   match rule: alias equal case-insensitively AND lease opaque_host_id equals
   this machine's host id — a matched lease is folded into its local row
   (scope "both" + nested "relay_lease"), never duplicated; the same alias on
   a DIFFERENT host stays a distinct row disambiguated by address. Labels are
   descriptive only — NO attestation surface (no trust tiers / verified
   badges; I008 stays unbuilt). The default `c2c list` stays local-only; the
   merged-by-default flip is an OPEN product gate per the friction-cn
   decision ledger (.collab/design/friction-cn-decision-ledger.md on the
   friction-adr0-decision-ledger branch).

   Coverage:
   - List_identity unit: self-identity match rule (case-insensitive alias,
     host anchor required), match_merged fold bookkeeping, --kind filter
     predicates (scope-both passes both).
   - End-to-end against a FAKE relay (forked loopback HTTP server serving a
     canned {"ok":true,"peers":[...]} — no production relay is ever
     contacted; the offline case points at a closed loopback port):
     merged human + JSON, offline nonfatal (local rows still print, warning
     on stderr / relay_error in JSON, exit 0), --kind/--match/--alive
     filters through the merged view, same-alias-different-host
     disambiguation, self-identity fold, JSON additivity for the default
     (no --relay) path. *)

open Alcotest

(* --- List_identity unit tests ------------------------------------------------ *)

let host_a = "3d08761ae3f3"
let host_b = "beefbeefbeef"

let test_same_identity_rule () =
  check bool "alias + host match -> same identity" true
    (List_identity.same_identity ~local_alias:"h6qz-selfy" ~local_host:host_a
       ~relay_alias:"h6qz-selfy" ~relay_host:(Some host_a));
  check bool "alias match is case-insensitive" true
    (List_identity.same_identity ~local_alias:"H6qz-Selfy" ~local_host:host_a
       ~relay_alias:"h6qz-selfy" ~relay_host:(Some host_a));
  check bool "different host -> distinct identity" false
    (List_identity.same_identity ~local_alias:"h6qz-selfy" ~local_host:host_a
       ~relay_alias:"h6qz-selfy" ~relay_host:(Some host_b));
  check bool "lease without host anchor never matches" false
    (List_identity.same_identity ~local_alias:"h6qz-selfy" ~local_host:host_a
       ~relay_alias:"h6qz-selfy" ~relay_host:None);
  check bool "different alias -> distinct identity" false
    (List_identity.same_identity ~local_alias:"h6qz-selfy" ~local_host:host_a
       ~relay_alias:"h6qz-other" ~relay_host:(Some host_a));
  check bool "empty local host never matches" false
    (List_identity.same_identity ~local_alias:"h6qz-selfy" ~local_host:""
       ~relay_alias:"h6qz-selfy" ~relay_host:(Some ""))

let test_match_merged_fold () =
  let locals = [ ("h6qz-selfy", host_a); ("h6qz-onlyloc", host_a) ] in
  let relays =
    [ ("h6qz-selfy", Some host_a) (* same identity: fold *)
    ; ("h6qz-selfy", Some host_b) (* same alias, other host: distinct *)
    ; ("h6qz-faraway", Some host_b) (* relay-only *)
    ]
  in
  let matches, merged = List_identity.match_merged ~locals ~relays in
  check (list (option int)) "per-local matching lease index"
    [ Some 0; None ] matches;
  check (list bool) "per-relay merged flags" [ true; false; false ] merged

let test_match_merged_empty_sides () =
  let matches, merged =
    List_identity.match_merged ~locals:[] ~relays:[ ("a", Some host_a) ]
  in
  check (list (option int)) "no locals -> no matches" [] matches;
  check (list bool) "no locals -> nothing merged" [ false ] merged;
  let matches, merged =
    List_identity.match_merged ~locals:[ ("a", host_a) ] ~relays:[]
  in
  check (list (option int)) "no relays -> local unmatched" [ None ] matches;
  check (list bool) "no relays -> empty merged list" [] merged

let test_kind_filter_predicates () =
  let open List_identity in
  (* scope-both rows pass BOTH filters: filtering is by where the identity is
     registered, not by which source produced the row. *)
  List.iter
    (fun scope ->
      check bool "no filter keeps every local row" true (local_passes None scope);
      check bool "--kind local keeps every local row" true
        (local_passes (Some Kf_local) scope))
    [ Scope_local; Scope_both ];
  check bool "--kind relay keeps scope-both local rows" true
    (local_passes (Some Kf_relay) Scope_both);
  check bool "--kind relay drops local-only rows" false
    (local_passes (Some Kf_relay) Scope_local);
  check bool "no filter keeps relay rows" true (relay_passes None);
  check bool "--kind relay keeps relay rows" true (relay_passes (Some Kf_relay));
  check bool "--kind local drops relay-only rows" false
    (relay_passes (Some Kf_local));
  check bool "scope strings pinned" true
    (List.map scope_to_string [ Scope_local; Scope_relay; Scope_both ]
     = [ "local"; "relay"; "both" ]);
  check bool "kind strings pinned" true
    (List.map kind_to_string [ Kind_local; Kind_relay ] = [ "local"; "relay" ])

(* --- fake relay fixture -------------------------------------------------------

   F5a: the hand-rolled forked loopback server this suite introduced in H6
   now lives in the shared Relay_test_support harness (bound-before-fork
   loopback child, SIGKILL+waitpid stop — same guarantees, one canonical
   implementation). GET /list is the only route `c2c list --relay` uses
   (unsigned here: the isolated HOME has no relay identity), so a single
   default canned 200 JSON response is all the scripting this suite needs. *)

(* A loopback port with nothing listening: connections are refused. *)
let closed_port () = Relay_test_support.closed_port ()

(* --- e2e fixture: temp HOME + broker with two local registrations ------------ *)

let c2c_bin =
  let dir = Filename.dirname Sys.executable_name in
  let candidate =
    Filename.concat (Filename.concat (Filename.dirname dir) "cli") "c2c.exe"
  in
  if Sys.file_exists candidate then candidate else "c2c"

let mkdtemp () =
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "c2c-list-relay-h6-%d-%d" (Unix.getpid ())
         (Random.int 1_000_000))
  in
  Unix.mkdir base 0o700;
  base

let this_host = Host_id.compute_host_hash ()

(* Synthetic aliases (not word-pool combos) so live-peer collisions are
   impossible even if a broker root ever leaked. *)
let self_alias = "h6qz-selfy"
let local_only_alias = "h6qz-onlyloc"
let faraway_alias = "h6qz-faraway"

let setup_broker () =
  let tmp = mkdtemp () in
  let root = Filename.concat tmp "broker" in
  let broker = C2c_mcp.Broker.create ~root in
  let me = Unix.getpid () in
  (* pid_start_time makes the registrations classify Alive (this process),
     which the --alive filter test relies on. *)
  let start_time = C2c_mcp.Broker.read_pid_start_time me in
  C2c_mcp.Broker.register broker ~session_id:"h6-sess-self" ~alias:self_alias
    ~pid:(Some me) ~pid_start_time:start_time ();
  C2c_mcp.Broker.register broker ~session_id:"h6-sess-onlyloc"
    ~alias:local_only_alias ~pid:(Some me) ~pid_start_time:start_time ();
  tmp

(* Canned relay /list body:
   - self_alias @ this_host  -> same identity as the local registration (fold)
   - self_alias @ host_b     -> same alias, DIFFERENT host (distinct row)
   - faraway_alias @ host_b  -> relay-only, dead *)
let relay_body =
  let peer ~alias ~host ~alive ~pk =
    `Assoc
      [ ("alias", `String alias);
        ("opaque_host_id", `String host);
        ("alive", `Bool alive);
        ("identity_pk", `String pk);
        ("node_id", `String ("node-" ^ alias));
        ("session_id", `String ("sess-" ^ alias));
        ("last_seen", `Float 1720000000.0);
        ("registered_at", `Float 1710000000.0);
      ]
  in
  Yojson.Safe.to_string
    (`Assoc
      [ ("ok", `Bool true);
        ("peers",
         `List
           [ peer ~alias:self_alias ~host:this_host ~alive:true ~pk:"PKSELFPKSELF";
             peer ~alias:self_alias ~host:host_b ~alive:true ~pk:"PKOTHERPKOTHER";
             peer ~alias:faraway_alias ~host:host_b ~alive:false ~pk:"PKFARPKFARPK";
           ]);
      ])

(* Run c2c in a curated env (isolated HOME: no relay config, no relay
   identity; isolated broker root) capturing stdout + stderr separately. *)
let run_c2c ~tmp args =
  let out_path = Filename.concat tmp (Printf.sprintf "out-%d" (Random.int 1_000_000)) in
  let err_path = out_path ^ ".err" in
  let env =
    [| "PATH=" ^ (try Sys.getenv "PATH" with Not_found -> "/usr/bin:/bin");
       "HOME=" ^ tmp;
       "C2C_MCP_SESSION_ID=h6-list-relay-test";
       "C2C_MCP_BROKER_ROOT=" ^ Filename.concat tmp "broker";
    |]
  in
  let out_fd = Unix.openfile out_path [ Unix.O_WRONLY; Unix.O_CREAT ] 0o600 in
  let err_fd = Unix.openfile err_path [ Unix.O_WRONLY; Unix.O_CREAT ] 0o600 in
  let pid =
    Unix.create_process_env c2c_bin
      (Array.of_list (c2c_bin :: args))
      env Unix.stdin out_fd err_fd
  in
  Unix.close out_fd;
  Unix.close err_fd;
  let _, status = Unix.waitpid [] pid in
  let code = match status with Unix.WEXITED c -> c | _ -> -1 in
  let slurp path =
    let ic = open_in_bin path in
    let s = really_input_string ic (in_channel_length ic) in
    close_in ic;
    s
  in
  (code, slurp out_path, slurp err_path)

let with_fake_relay f =
  Relay_test_support.with_server
    ~default:(Relay_test_support.response relay_body)
    (fun srv -> f (Relay_test_support.url srv))

let string_contains ~needle haystack = Relay_doctor.string_contains ~needle haystack

(* JSON helpers *)
let assoc_string key = function
  | `Assoc fields ->
      (match List.assoc_opt key fields with Some (`String s) -> Some s | _ -> None)
  | _ -> None

let has_key key = function
  | `Assoc fields -> List.mem_assoc key fields
  | _ -> false

let envelope_peers j =
  match j with
  | `Assoc fields ->
      (match List.assoc_opt "peers" fields with
       | Some (`List rows) -> rows
       | _ -> fail "envelope missing peers array")
  | _ -> fail "expected --relay --json envelope object"

let envelope_relay_error j =
  match j with
  | `Assoc fields ->
      (match List.assoc_opt "relay_error" fields with
       | Some v -> v
       | None -> fail "envelope missing relay_error key")
  | _ -> fail "expected --relay --json envelope object"

let rows_with ~key ~value rows =
  List.filter (fun r -> assoc_string key r = Some value) rows

let merged_json ~tmp ~url extra_args =
  let code, out, _err =
    run_c2c ~tmp ([ "list"; "--relay"; "--relay-url"; url; "--json" ] @ extra_args)
  in
  check int "list --relay --json exit 0" 0 code;
  Yojson.Safe.from_string out

(* --- e2e: merged JSON (labels, fold, disambiguation, relay_error null) ------- *)

let test_merged_json_labels_and_fold () =
  let tmp = setup_broker () in
  with_fake_relay (fun url ->
      let j = merged_json ~tmp ~url [] in
      check bool "relay_error is null on success" true
        (envelope_relay_error j = `Null);
      let rows = envelope_peers j in
      (* local-only row: kind local, scope local, no folded lease *)
      (match rows_with ~key:"alias" ~value:local_only_alias rows with
       | [ row ] ->
           check (option string) "local-only kind" (Some "local")
             (assoc_string "identity_kind" row);
           check (option string) "local-only scope" (Some "local")
             (assoc_string "identity_scope" row);
           check bool "local-only row has no relay_lease" false
             (has_key "relay_lease" row);
           check (option string) "local-only source" (Some "local")
             (assoc_string "source" row)
       | rows -> fail (Printf.sprintf "expected 1 local-only row, got %d" (List.length rows)));
      (* self identity: ONE row (fold), kind local, scope both, lease nested *)
      (match rows_with ~key:"alias" ~value:self_alias rows with
       | [ a; b ] ->
           (* one local scope-both row + one relay row for the OTHER host *)
           let local_row, relay_row =
             if assoc_string "source" a = Some "local" then (a, b) else (b, a)
           in
           check (option string) "self row kind" (Some "local")
             (assoc_string "identity_kind" local_row);
           check (option string) "self row scope" (Some "both")
             (assoc_string "identity_scope" local_row);
           check bool "self row folds the lease" true
             (has_key "relay_lease" local_row);
           (match local_row with
            | `Assoc fields ->
                (match List.assoc_opt "relay_lease" fields with
                 | Some lease ->
                     check bool "folded lease drops the source tag" false
                       (has_key "source" lease);
                     check (option string) "folded lease keeps identity_pk"
                       (Some "PKSELFPKSELF") (assoc_string "identity_pk" lease);
                     check (option string) "folded lease address anchors this host"
                       (Some (self_alias ^ "@" ^ this_host))
                       (assoc_string "address" lease)
                 | None -> fail "relay_lease missing")
            | _ -> fail "expected object row");
           check (option string) "self local row addressed to this host"
             (Some (self_alias ^ "@" ^ this_host))
             (assoc_string "address" local_row);
           (* same alias, DIFFERENT host: its own relay row *)
           check (option string) "other-host row source" (Some "relay")
             (assoc_string "source" relay_row);
           check (option string) "other-host row kind" (Some "relay")
             (assoc_string "identity_kind" relay_row);
           check (option string) "other-host row scope" (Some "relay")
             (assoc_string "identity_scope" relay_row);
           check (option string) "other-host row disambiguated by address"
             (Some (self_alias ^ "@" ^ host_b))
             (assoc_string "address" relay_row)
       | rows ->
           fail
             (Printf.sprintf
                "expected exactly 2 rows for %s (fold + other host), got %d"
                self_alias (List.length rows)));
      (* the this-host lease must NOT appear as its own source=relay row *)
      let dup_self_relay_rows =
        rows_with ~key:"address" ~value:(self_alias ^ "@" ^ this_host) rows
        |> rows_with ~key:"source" ~value:"relay"
      in
      check int "no duplicate relay row for the folded self lease" 0
        (List.length dup_self_relay_rows);
      (* A confirmed-dead relay-only peer is hidden by default. *)
      (match rows_with ~key:"alias" ~value:faraway_alias rows with
       | [] -> ()
       | rows ->
           fail
             (Printf.sprintf "expected dead relay-only peer hidden, got %d rows"
                (List.length rows)));
      (* --all restores the dead relay peer for diagnostics. *)
      let rows = envelope_peers (merged_json ~tmp ~url [ "--all" ]) in
      match rows_with ~key:"alias" ~value:faraway_alias rows with
      | [ row ] ->
          check (option string) "relay-only kind" (Some "relay")
            (assoc_string "identity_kind" row);
          check (option string) "relay-only scope" (Some "relay")
            (assoc_string "identity_scope" row)
      | rows -> fail (Printf.sprintf "expected 1 relay-only row, got %d" (List.length rows)))

(* --- e2e: merged human (scope column, both marker, parity with JSON) --------- *)

let test_merged_human_scope_labels () =
  let tmp = setup_broker () in
  with_fake_relay (fun url ->
      let code, out, _err =
        run_c2c ~tmp [ "list"; "--relay"; "--relay-url"; url ]
      in
      check int "list --relay (human) exit 0" 0 code;
      (* local listing still leads with the plain local rows *)
      check bool "local row printed" true
        (string_contains ~needle:local_only_alias out);
      (* relay block with scope column; header counts the scope-both fold *)
      check bool "relay block present" true
        (string_contains ~needle:"relay peers (" out);
      check bool "header counts also-local identities" true
        (string_contains ~needle:"1 also local (scope both)" out);
      check bool "SCOPE column present" true (string_contains ~needle:"SCOPE" out);
      (* the same JSON scope strings appear as human labels (parity) *)
      check bool "scope both rendered" true
        (string_contains ~needle:"both" out);
      check bool "self lease cross-referenced, not duplicated anonymously" true
        (string_contains ~needle:(Printf.sprintf "(= local '%s')" self_alias) out);
      check bool "distinct-host address rendered" true
        (string_contains ~needle:(self_alias ^ "@" ^ host_b) out))

(* --- e2e: offline nonfatal ---------------------------------------------------- *)

let test_offline_nonfatal_json () =
  let tmp = setup_broker () in
  let url = Printf.sprintf "http://127.0.0.1:%d" (closed_port ()) in
  let code, out, _err =
    run_c2c ~tmp [ "list"; "--relay"; "--relay-url"; url; "--json" ]
  in
  (* Partial success: the local listing is the product; exit code stays 0 and
     the relay failure is surfaced as data, never as an abort. *)
  check int "offline --relay --json still exits 0" 0 code;
  let j = Yojson.Safe.from_string out in
  (match envelope_relay_error j with
   | `String msg ->
       check bool "relay_error names the failure" true
         (string_contains ~needle:"relay fetch failed" msg)
   | _ -> fail "expected relay_error string when the relay is unreachable");
  let rows = envelope_peers j in
  check int "both local rows survive the relay outage" 2 (List.length rows);
  check int "no relay rows when the relay is down" 0
    (List.length (rows_with ~key:"source" ~value:"relay" rows))

let test_offline_nonfatal_human () =
  let tmp = setup_broker () in
  let url = Printf.sprintf "http://127.0.0.1:%d" (closed_port ()) in
  let code, out, err = run_c2c ~tmp [ "list"; "--relay"; "--relay-url"; url ] in
  check int "offline --relay (human) still exits 0" 0 code;
  check bool "local rows still print" true
    (string_contains ~needle:self_alias out
     && string_contains ~needle:local_only_alias out);
  check bool "relay-unavailable warning on stderr" true
    (string_contains ~needle:"relay fetch failed" err);
  check bool "warning says local peers still shown" true
    (string_contains ~needle:"showing local peers only" err)

(* --- e2e: filters through the merged view ------------------------------------- *)

let test_kind_filter_relay () =
  let tmp = setup_broker () in
  with_fake_relay (fun url ->
      let rows = envelope_peers (merged_json ~tmp ~url [ "--kind"; "relay" ]) in
      (* relay-registered visible identities only: the scope-both local row
         plus the live relay-only row; the local-only alias is filtered out. *)
      check int "local-only row filtered out" 0
        (List.length (rows_with ~key:"alias" ~value:local_only_alias rows));
      check int "scope-both local row kept (identity IS relay-registered)" 1
        (List.length
           (rows_with ~key:"alias" ~value:self_alias rows
            |> rows_with ~key:"identity_scope" ~value:"both"));
      check int "confirmed-dead relay-only row hidden" 0
        (List.length (rows_with ~key:"alias" ~value:faraway_alias rows));
      check int "two visible relay-registered identities total" 2 (List.length rows);
      let all_rows = envelope_peers (merged_json ~tmp ~url [ "--kind"; "relay"; "--all" ]) in
      check int "--all restores dead relay-only row" 1
        (List.length (rows_with ~key:"alias" ~value:faraway_alias all_rows));
      check int "three relay-registered identities with --all" 3 (List.length all_rows))

let test_kind_filter_local () =
  let tmp = setup_broker () in
  with_fake_relay (fun url ->
      let rows = envelope_peers (merged_json ~tmp ~url [ "--kind"; "local" ]) in
      (* locally-registered identities only: both local rows (incl. the
         scope-both one); relay-only rows dropped. *)
      check int "both local rows kept" 2
        (List.length (rows_with ~key:"source" ~value:"local" rows));
      check int "relay-only rows dropped" 0
        (List.length (rows_with ~key:"source" ~value:"relay" rows));
      check int "scope-both row still present under --kind local" 1
        (List.length (rows_with ~key:"identity_scope" ~value:"both" rows)))

let test_match_and_alive_compose_with_relay () =
  let tmp = setup_broker () in
  with_fake_relay (fun url ->
      (* --match applies to both sources, but does not implicitly reveal a
         confirmed-dead relay row. *)
      let rows = envelope_peers (merged_json ~tmp ~url [ "--match"; "faraway" ]) in
      check int "--match filters local rows out" 0
        (List.length (rows_with ~key:"source" ~value:"local" rows));
      check int "--match leaves dead relay row hidden" 0 (List.length rows);
      let rows = envelope_peers (merged_json ~tmp ~url [ "--match"; "faraway"; "--all" ]) in
      check int "--all --match restores the matching relay row" 1 (List.length rows);
      check (option string) "matched row is the faraway peer"
        (Some faraway_alias) (assoc_string "alias" (List.hd rows));
      (* --alive drops the dead relay lease *)
      let rows = envelope_peers (merged_json ~tmp ~url [ "--alive" ]) in
      check int "--alive drops the dead relay-only peer" 0
        (List.length (rows_with ~key:"alias" ~value:faraway_alias rows));
      check int "--alive keeps live rows from both sources" 3
        (List.length rows))

(* --- e2e: default path additivity ---------------------------------------------- *)

let test_default_json_shape_unchanged () =
  let tmp = setup_broker () in
  let code, out, _err = run_c2c ~tmp [ "list"; "--json" ] in
  check int "default list --json exit 0" 0 code;
  (match Yojson.Safe.from_string out with
   | `List rows ->
       check int "default JSON lists the two local rows" 2 (List.length rows);
       List.iter
         (fun row ->
           check bool "no identity_kind on the default path" false
             (has_key "identity_kind" row);
           check bool "no identity_scope on the default path" false
             (has_key "identity_scope" row);
           check bool "no relay_lease on the default path" false
             (has_key "relay_lease" row);
           check bool "B097 source tag still present" true
             (has_key "source" row))
         rows
   | _ ->
       fail
         "default `c2c list --json` must stay a bare array (merged-by-default \
          is an open product gate — decision ledger)")

let test_kind_relay_without_relay_hints () =
  let tmp = setup_broker () in
  let code, out, err = run_c2c ~tmp [ "list"; "--kind"; "relay"; "--json" ] in
  check int "exit 0" 0 code;
  (match Yojson.Safe.from_string out with
   | `List rows -> check int "no relay data -> nothing matches" 0 (List.length rows)
   | _ -> fail "default path stays a bare array even with --kind");
  check bool "hint points at --relay" true (string_contains ~needle:"--relay" err)

(* --- runner -------------------------------------------------------------------- *)

let () =
  Random.self_init ();
  run "c2c_list_relay"
    [
      ( "List_identity unit",
        [ test_case "self-identity match rule" `Quick test_same_identity_rule;
          test_case "match_merged fold bookkeeping" `Quick test_match_merged_fold;
          test_case "match_merged empty sides" `Quick test_match_merged_empty_sides;
          test_case "--kind filter predicates" `Quick test_kind_filter_predicates ] );
      ( "merged view (fake relay)",
        [ test_case "JSON labels, fold, disambiguation" `Quick
            test_merged_json_labels_and_fold;
          test_case "human scope labels + both marker" `Quick
            test_merged_human_scope_labels ] );
      ( "offline nonfatal",
        [ test_case "JSON relay_error, local rows survive" `Quick
            test_offline_nonfatal_json;
          test_case "human warning, exit 0" `Quick test_offline_nonfatal_human ] );
      ( "filters",
        [ test_case "--kind relay" `Quick test_kind_filter_relay;
          test_case "--kind local" `Quick test_kind_filter_local;
          test_case "--match / --alive compose" `Quick
            test_match_and_alive_compose_with_relay ] );
      ( "default path additivity",
        [ test_case "list --json shape unchanged" `Quick
            test_default_json_shape_unchanged;
          test_case "--kind relay without --relay hints" `Quick
            test_kind_relay_without_relay_hints ] );
    ]
