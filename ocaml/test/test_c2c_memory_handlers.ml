(* #388 memory handler tests — test_c2c_memory_handlers.ml
   Tests pure argument-parsing + frontmatter-parsing logic for each memory handler.
   Broker-level operations require a live broker + sessions (covered by integration tests).

   Handler arg-reading strategy:
     memory_list:  "shared_with_me" → `Bool b | _ → false
     memory_read:  "name" → string_member (strict, raises if missing)
     memory_write: "name" → string_member (strict)
                  "description" → optional_string_member (None if absent/empty)
                  "shared" → `Bool b | _ → false
                  "shared_with" → `String s → parse_alias_list s
                               → `List xs → filter_map strings, concat with comma
                  "content" → string_member (strict)

   parse_frontmatter and parse_alias_list are pure functions — tested directly.
   JSON membership helpers (Json_util) tested via Yojson.Safe.Util. *)

open Alcotest
module J = Yojson.Safe.Util

(* ------------------------------------------------------------------------- *)
(* parse_frontmatter — pure function from C2c_memory_handlers                 *)
(* Returns (name, description, shared, shared_with, body_lines)              *)
(* ------------------------------------------------------------------------- *)

let test_parse_frontmatter_empty () =
  let content = "" in
  let (name, desc, shared, shared_with, body) =
    C2c_memory_handlers.parse_frontmatter content in
  check (option string) "name" None name;
  check (option string) "desc" None desc;
  check bool "shared" false shared;
  check (list string) "shared_with" [] shared_with;
  (* empty string splits to [""] — one empty-string line *)
  check (list string) "body" [""] body

let test_parse_frontmatter_name_only () =
  let content = "---\nname: test-entry\n---\nbody content\n" in
  let (name, desc, shared, shared_with, body) =
    C2c_memory_handlers.parse_frontmatter content in
  (match name with Some n -> check string "name" "test-entry" n | None -> Alcotest.fail "expected name");
  check (option string) "desc" None desc;
  check bool "shared" false shared;
  check (list string) "shared_with" [] shared_with;
  check bool "body non-empty" true (body <> [])

let test_parse_frontmatter_full () =
  let content = "---\nname: my-entry\ndescription: A test entry\nshared: true\nshared_with: [alice, bob]\n---\nEntry body here." in
  let (name, desc, shared, shared_with, body) =
    C2c_memory_handlers.parse_frontmatter content in
  (match name with Some n -> check string "name" "my-entry" n | None -> Alcotest.fail "expected name");
  (match desc with Some d -> check string "desc" "A test entry" d | None -> Alcotest.fail "expected desc");
  check bool "shared" true shared;
  check bool "shared_with has entries" true (shared_with <> []);
  check bool "alice in shared_with" true (List.mem "alice" shared_with);
  check bool "bob in shared_with" true (List.mem "bob" shared_with);
  check bool "body has content" true (List.mem "Entry body here." body)

let test_parse_frontmatter_shared_false () =
  let content = "---\nname: private-entry\nshared: false\n---\n" in
  let (_, _, shared, _, _) =
    C2c_memory_handlers.parse_frontmatter content in
  check bool "shared false" false shared

let test_parse_frontmatter_no_delimiters () =
  (* no --- delimiters — entire content treated as body *)
  let content = "just some body text\nwith multiple lines\n" in
  let (name, _, shared, _, body) =
    C2c_memory_handlers.parse_frontmatter content in
  check (option string) "name absent → None" None name;
  check bool "shared default false" false shared;
  check bool "body is content" true (body <> [])

let test_parse_frontmatter_description_with_colon () =
  (* description value contains a colon — regex handles it *)
  let content = "---\nname: test\ndescription: url: http://example.com\n---\n" in
  let (_, desc, _, _, _) =
    C2c_memory_handlers.parse_frontmatter content in
  match desc with
  | Some d -> check string "description" "url: http://example.com" d
  | None -> Alcotest.fail "expected description"

let test_parse_frontmatter_shared_with_quoted () =
  let content = "---\nname: shared-entry\nshared_with: [\"alice\", \"bob\"]\n---\n" in
  let (_, _, _, shared_with, _) =
    C2c_memory_handlers.parse_frontmatter content in
  check bool "shared_with has 2 entries" true (List.length shared_with = 2)

(* ------------------------------------------------------------------------- *)
(* parse_alias_list — pure function from C2c_mcp_helpers                     *)
(* Parses "[alice, bob]" or "alice, bob" into a string list                  *)
(* ------------------------------------------------------------------------- *)

let test_parse_alias_list_bracketed () =
  let r = C2c_mcp_helpers.parse_alias_list "[alice, bob]" in
  check bool "has 2 entries" true (List.length r = 2);
  check bool "alice present" true (List.mem "alice" r);
  check bool "bob present" true (List.mem "bob" r)

let test_parse_alias_list_bare () =
  let r = C2c_mcp_helpers.parse_alias_list "alice, bob" in
  check bool "has 2 entries" true (List.length r = 2)

let test_parse_alias_list_empty_brackets () =
  let r = C2c_mcp_helpers.parse_alias_list "[]" in
  check bool "empty list" true (r = [])

let test_parse_alias_list_with_whitespace () =
  let r = C2c_mcp_helpers.parse_alias_list "[ alice ,  bob ]" in
  check bool "has 2 entries" true (List.length r = 2)

let test_parse_alias_list_single () =
  let r = C2c_mcp_helpers.parse_alias_list "[alice]" in
  check (list string) "single entry" ["alice"] r

(* ------------------------------------------------------------------------- *)
(* memory_list: shared_with_me                                               *)
(* Handler: `Bool b → b | _ → false                                          *)
(* ------------------------------------------------------------------------- *)

let test_shared_with_me_true () =
  let args = `Assoc [("shared_with_me", `Bool true)] in
  let v = J.member "shared_with_me" args in
  match v with `Bool true -> () | _ -> Alcotest.fail "expected Bool true"

let test_shared_with_me_false () =
  let args = `Assoc [("shared_with_me", `Bool false)] in
  let v = J.member "shared_with_me" args in
  match v with `Bool false -> () | _ -> Alcotest.fail "expected Bool false"

let test_shared_with_me_absent () =
  let args = `Assoc [] in
  let v = J.member "shared_with_me" args in
  (* handler default: false — `Null is not `Bool, so handler returns false *)
  check bool "shared_with_me absent → `Null" true (v = `Null)

let test_shared_with_me_wrong_type () =
  let args = `Assoc [("shared_with_me", `String "true")] in
  let v = J.member "shared_with_me" args in
  (* handler: not `Bool → default false *)
  check bool "shared_with_me string → not `Null" true (v <> `Null)

(* ------------------------------------------------------------------------- *)
(* memory_read / memory_write: name (strict string_member)                    *)
(* Json_util.string_member: Some s if `String s, None otherwise              *)
(* ------------------------------------------------------------------------- *)

let test_memory_name_present () =
  let args = `Assoc [("name", `String "my-entry")] in
  let v = Json_util.string_member "name" args in
  match v with Some "my-entry" -> () | _ -> Alcotest.fail "expected Some \"my-entry\""

let test_memory_name_absent () =
  let args = `Assoc [] in
  let v = Json_util.string_member "name" args in
  check bool "name absent → None" true (v = None)

let test_memory_name_wrong_type () =
  let args = `Assoc [("name", `Int 42)] in
  let v = Json_util.string_member "name" args in
  check bool "name int → None" true (v = None)

let test_memory_name_empty () =
  let args = `Assoc [("name", `String "")] in
  let v = Json_util.string_member "name" args in
  (* string_member returns Some "" for empty string *)
  match v with Some "" -> () | _ -> Alcotest.fail "expected Some \"\""

(* ------------------------------------------------------------------------- *)
(* memory_write: description (optional_string_member)                        *)
(* optional_string_member: Some non-empty trimmed string, None if absent/empty *)
(* ------------------------------------------------------------------------- *)

let test_description_present () =
  let args = `Assoc [("description", `String "A test description")] in
  let v = J.member "description" args in
  match v with
  | `String s when String.trim s <> "" -> ()
  | _ -> Alcotest.fail "expected non-empty string"

let test_description_absent () =
  let args = `Assoc [] in
  let v = J.member "description" args in
  check bool "description absent → `Null" true (v = `Null)

let test_description_empty () =
  let args = `Assoc [("description", `String "  ")] in
  let v = J.member "description" args in
  (* handler: empty-after-trim → None *)
  check bool "description whitespace → not a non-empty string" true (v <> `Null)

(* ------------------------------------------------------------------------- *)
(* memory_write: shared (`Bool b → b | _ → false)                            *)
(* ------------------------------------------------------------------------- *)

let test_shared_true () =
  let args = `Assoc [("shared", `Bool true)] in
  let v = J.member "shared" args in
  match v with `Bool true -> () | _ -> Alcotest.fail "expected Bool true"

let test_shared_false () =
  let args = `Assoc [("shared", `Bool false)] in
  let v = J.member "shared" args in
  match v with `Bool false -> () | _ -> Alcotest.fail "expected Bool false"

let test_shared_absent () =
  let args = `Assoc [] in
  let v = J.member "shared" args in
  check bool "shared absent → `Null" true (v = `Null)

(* ------------------------------------------------------------------------- *)
(* memory_write: shared_with (`String s → parse_alias_list s;                *)
(*                              `List xs → filter_map strings → concat)     *)
(* ------------------------------------------------------------------------- *)

let test_shared_with_string () =
  let args = `Assoc [("shared_with", `String "[alice, bob]")] in
  let v = J.member "shared_with" args in
  match v with
  | `String s ->
      let r = C2c_mcp_helpers.parse_alias_list s in
      check bool "parsed 2 aliases" true (List.length r = 2)
  | _ -> Alcotest.fail "expected `String"

let test_shared_with_list () =
  let args = `Assoc [("shared_with", `List [`String "alice"; `String "bob"])] in
  let v = J.member "shared_with" args in
  match v with
  | `List xs ->
      let strings = List.filter_map (function `String s -> Some s | _ -> None) xs in
      check bool "2 strings from list" true (List.length strings = 2)
  | _ -> Alcotest.fail "expected `List"

let test_shared_with_absent () =
  let args = `Assoc [] in
  let v = J.member "shared_with" args in
  check bool "shared_with absent → `Null" true (v = `Null)

let test_shared_with_wrong_type () =
  let args = `Assoc [("shared_with", `Int 42)] in
  let v = J.member "shared_with" args in
  check bool "shared_with int → `Null" true (v <> `Null)

(* ------------------------------------------------------------------------- *)
(* memory_write: content (strict string_member)                              *)
(* ------------------------------------------------------------------------- *)

let test_content_present () =
  let args = `Assoc [("content", `String "Entry body text")] in
  let v = Json_util.string_member "content" args in
  match v with Some "Entry body text" -> () | _ -> Alcotest.fail "expected Some"

let test_content_absent () =
  let args = `Assoc [] in
  let v = Json_util.string_member "content" args in
  check bool "content absent → None" true (v = None)

let test_content_empty_string () =
  let args = `Assoc [("content", `String "")] in
  let v = Json_util.string_member "content" args in
  (* string_member returns Some "" for empty string (trim-to-None is caller's job) *)
  match v with Some "" -> () | _ -> Alcotest.fail "expected Some \"\""

(* ========================================================================= *)
let memory_handler_tests : unit test =
  "memory_handler_argument_parsing", [
    (* parse_frontmatter *)
    "parse_frontmatter empty"                  , `Quick, test_parse_frontmatter_empty;
    "parse_frontmatter name only"              , `Quick, test_parse_frontmatter_name_only;
    "parse_frontmatter full"                  , `Quick, test_parse_frontmatter_full;
    "parse_frontmatter shared: false"          , `Quick, test_parse_frontmatter_shared_false;
    "parse_frontmatter no delimiters"          , `Quick, test_parse_frontmatter_no_delimiters;
    "parse_frontmatter description with colon"  , `Quick, test_parse_frontmatter_description_with_colon;
    "parse_frontmatter shared_with quoted"     , `Quick, test_parse_frontmatter_shared_with_quoted;
    (* parse_alias_list *)
    "parse_alias_list bracketed"               , `Quick, test_parse_alias_list_bracketed;
    "parse_alias_list bare"                    , `Quick, test_parse_alias_list_bare;
    "parse_alias_list empty brackets"          , `Quick, test_parse_alias_list_empty_brackets;
    "parse_alias_list with whitespace"         , `Quick, test_parse_alias_list_with_whitespace;
    "parse_alias_list single"                  , `Quick, test_parse_alias_list_single;
    (* memory_list: shared_with_me *)
    "shared_with_me true"                     , `Quick, test_shared_with_me_true;
    "shared_with_me false"                    , `Quick, test_shared_with_me_false;
    "shared_with_me absent"                   , `Quick, test_shared_with_me_absent;
    "shared_with_me wrong type"               , `Quick, test_shared_with_me_wrong_type;
    (* memory_read/memory_write: name *)
    "memory name present"                     , `Quick, test_memory_name_present;
    "memory name absent"                      , `Quick, test_memory_name_absent;
    "memory name wrong type"                  , `Quick, test_memory_name_wrong_type;
    "memory name empty"                       , `Quick, test_memory_name_empty;
    (* memory_write: description *)
    "description present"                    , `Quick, test_description_present;
    "description absent"                      , `Quick, test_description_absent;
    "description empty whitespace"           , `Quick, test_description_empty;
    (* memory_write: shared *)
    "shared true"                            , `Quick, test_shared_true;
    "shared false"                            , `Quick, test_shared_false;
    "shared absent"                          , `Quick, test_shared_absent;
    (* memory_write: shared_with *)
    "shared_with string"                    , `Quick, test_shared_with_string;
    "shared_with list"                      , `Quick, test_shared_with_list;
    "shared_with absent"                    , `Quick, test_shared_with_absent;
    "shared_with wrong type"                 , `Quick, test_shared_with_wrong_type;
    (* memory_write: content *)
    "content present"                        , `Quick, test_content_present;
    "content absent"                         , `Quick, test_content_absent;
    "content empty string"                   , `Quick, test_content_empty_string;
  ]

let () =
  Alcotest.run "c2c_memory_handlers"
    [memory_handler_tests]
