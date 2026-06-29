open Alcotest

let is_valid = C2c_name.is_valid

let valid_cases = [
  ("alice", true); ("bob-42", true); ("my.peer", true); ("oc_coder1", true);
  ("planner1", true); ("a", true); (String.make 64 'x', true);
]

let invalid_cases = [
  ("", false); (String.make 65 'x', false); (".hidden", false); ("foo/bar", false);
  ("a b", false); ("foo\x00bar", false); ("hello!", false); ("foo@bar", false);
  ("space in name", false);
]

let test_valid_cases () =
  List.iter (fun (name, expected) ->
    Alcotest.(check bool) (Printf.sprintf "valid: %S" name) expected (is_valid name)
  ) valid_cases

let test_invalid_cases () =
  List.iter (fun (name, expected) ->
    Alcotest.(check bool) (Printf.sprintf "invalid: %S" name) expected (is_valid name)
  ) invalid_cases

(* ---- is_opaque_host_id: 12-16 char lowercase hex ---- *)

let opaque_host_id_cases = [
  (* valid: 12, 13, 14, 16 char lowercase hex *)
  ("3d08761ae3f3", true);   (* 12 — the exact host hash from bugs.txt bug #1 *)
  ("3d08761ae3f30", true);  (* 13 *)
  ("deadbeefcafe12", true); (* 14 *)
  (String.make 16 'a', true); (* 16 — max *)
  (* invalid: wrong length *)
  (String.make 11 'a', false);  (* too short *)
  (String.make 17 'a', false);  (* too long *)
  ("", false);
  (* invalid: uppercase / non-hex *)
  ("3D08761AE3F3", false);  (* uppercase rejected *)
  ("3d08761ae3fg", false);  (* 'g' is not hex *)
  ("3d08761ae3f ", false);  (* trailing space *)
]

let test_is_opaque_host_id () =
  List.iter (fun (s, expected) ->
    Alcotest.(check bool)
      (Printf.sprintf "is_opaque_host_id %S = %b" s expected)
      expected (C2c_name.is_opaque_host_id s)
  ) opaque_host_id_cases

(* ---- is_valid_with_opaque_host_id: <name>@<12-16 hex> or bare name ---- *)

let valid_with_host_cases = [
  (* bare names behave like is_valid *)
  ("alice", true);
  ("bob-42", true);
  (* name @ opaque host id — relay address shape *)
  ("pi-8391d3@3d08761ae3f3", true);  (* EXACT repro from bugs.txt bug #1 *)
  ("lyra-quill@3d08761ae3f3", true);
  ("a@deadbeefcafe12", true);
  (* invalid *)
  ("foo@bar", false);                 (* host part not hex *)
  ("foo@3d08761ae3f", false);         (* host part 11 chars *)
  ("foo@3D08761AE3F3", false);        (* uppercase host *)
  ("@3d08761ae3f3", false);           (* empty name *)
  (".hidden@3d08761ae3f3", false);    (* leading dot name *)
  ("foo/bar@3d08761ae3f3", false);    (* bad char in name *)
  (String.make 65 'x' ^ "@3d08761ae3f3", false); (* name too long *)
]

let test_is_valid_with_opaque_host_id () =
  List.iter (fun (s, expected) ->
    Alcotest.(check bool)
      (Printf.sprintf "is_valid_with_opaque_host_id %S = %b" s expected)
      expected (C2c_name.is_valid_with_opaque_host_id s)
  ) valid_with_host_cases

(* ---- split_opaque_host_id ---- *)

let split_cases = [
  ("alice", ("alice", None));
  ("pi-8391d3@3d08761ae3f3", ("pi-8391d3", Some "3d08761ae3f3"));  (* bug #1 repro *)
  ("lyra-quill@deadbeefcafe12", ("lyra-quill", Some "deadbeefcafe12"));
  ("a@b", ("a", Some "b"));  (* split is positional; validation is caller's job *)
]

let test_split_opaque_host_id () =
  List.iter (fun (input, (exp_name, exp_host)) ->
    let got_name, got_host = C2c_name.split_opaque_host_id input in
    Alcotest.(check string)
      (Printf.sprintf "split %S name" input) exp_name got_name;
    Alcotest.(check (option string))
      (Printf.sprintf "split %S host" input) exp_host got_host
  ) split_cases

(* ---- Bug #1 regression: relay signer vs host-qualified from_alias ----

   bugs.txt 2026-06-24: a pi-c2c sender registered under bare alias
   `pi-8391d3` (Ed25519 signer bound to the bare name at register) sent a
   DM with body `from_alias = "pi-8391d3@3d08761ae3f3"` (its full relay
   address). The relay rejected it with `signature_invalid`: "verified
   signer \"pi-8391d3\" does not match body from_alias
   \"pi-8391d3@3d08761ae3f3\"".

   Root cause: relay.ml compared `verified_alias = body.from_alias`
   literally. Fixed in commit 2516b640 ("fix(relay): accept full-address
   (<name>@<host>) signer on send routes") by extracting the NAME part of
   from_alias (via C2c_name.split_opaque_host_id) when it is a
   well-formed <name>@<host>, and comparing the signer against that.

   This test encodes the exact decision rule from relay.ml
   `from_alias_signer_name` so a future regression in either the
   primitive or the rule is caught. *)

(* Mirrors relay.ml: `from_alias_signer_name` — the name the verified
   signer is compared against. *)
let signer_name_of_from_alias from_alias =
  if C2c_name.is_valid_with_opaque_host_id from_alias
  then fst (C2c_name.split_opaque_host_id from_alias)
  else from_alias

let test_bug1_signer_matches_host_qualified_from_alias () =
  (* The exact failing case from the bug report must now be ACCEPTED:
     verified signer "pi-8391d3" matches from_alias "pi-8391d3@3d08761ae3f3". *)
  let verified = "pi-8391d3" in
  let from_alias = "pi-8391d3@3d08761ae3f3" in
  let matches = (signer_name_of_from_alias from_alias = verified) in
  Alcotest.(check bool)
    "bug #1: host-qualified from_alias matches bare verified signer" true matches;
  (* Bare from_alias still matches (back-compat). *)
  Alcotest.(check bool)
    "bug #1: bare from_alias matches bare verified signer" true
    (signer_name_of_from_alias "pi-8391d3" = verified);
  (* A genuinely different alias must still be rejected. *)
  Alcotest.(check bool)
    "bug #1: different name still rejected" false
    (signer_name_of_from_alias "other-agent@3d08761ae3f3" = verified);
  (* A malformed host suffix must NOT be stripped — whole-string compare rejects. *)
  Alcotest.(check bool)
    "bug #1: malformed host suffix falls through to whole-string compare" false
    (signer_name_of_from_alias "pi-8391d3@nothex" = verified)

let tests = [
  "valid cases",    `Quick, test_valid_cases;
  "invalid cases", `Quick, test_invalid_cases;
  "is_opaque_host_id", `Quick, test_is_opaque_host_id;
  "is_valid_with_opaque_host_id", `Quick, test_is_valid_with_opaque_host_id;
  "split_opaque_host_id", `Quick, test_split_opaque_host_id;
  "bug1 signer vs host-qualified from_alias", `Quick, test_bug1_signer_matches_host_qualified_from_alias;
]

let () = Alcotest.run "c2c_name" [ "is_valid", tests ]
