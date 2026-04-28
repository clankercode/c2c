(* test_c2c_git_shim — #367.

   Verify the `c2c git` shim's env-overlay logic only injects
   GIT_AUTHOR_{NAME,EMAIL} defaults when they aren't already set in the
   parent env. *)

let overlay_keys arr =
  Array.to_list arr
  |> List.map (fun s ->
         match String.index_opt s '=' with
         | Some i -> String.sub s 0 i
         | None -> s)
  |> List.sort compare

let pair k v = k ^ "=" ^ v

let test_no_parent () =
  let parent_env = [||] in
  let overlay =
    C2c_git_shim.build_author_overlay ~parent_env ~name:"alice"
      ~email:"alice@c2c.im"
  in
  Alcotest.(check (list string))
    "both defaults injected when parent env empty"
    [ "GIT_AUTHOR_EMAIL"; "GIT_AUTHOR_NAME" ]
    (overlay_keys overlay);
  Alcotest.(check bool)
    "name pair present" true
    (Array.exists (( = ) (pair "GIT_AUTHOR_NAME" "alice")) overlay);
  Alcotest.(check bool)
    "email pair present" true
    (Array.exists (( = ) (pair "GIT_AUTHOR_EMAIL" "alice@c2c.im")) overlay)

let test_parent_sets_name () =
  let parent_env = [| "PATH=/bin"; "GIT_AUTHOR_NAME=Operator Override" |] in
  let overlay =
    C2c_git_shim.build_author_overlay ~parent_env ~name:"alice"
      ~email:"alice@c2c.im"
  in
  Alcotest.(check (list string))
    "only email injected when name pre-set" [ "GIT_AUTHOR_EMAIL" ]
    (overlay_keys overlay);
  Alcotest.(check bool)
    "operator name not clobbered" false
    (Array.exists
       (fun s ->
         String.length s >= 16 && String.sub s 0 16 = "GIT_AUTHOR_NAME=")
       overlay)

let test_parent_sets_email () =
  let parent_env = [| "GIT_AUTHOR_EMAIL=ops@example.com" |] in
  let overlay =
    C2c_git_shim.build_author_overlay ~parent_env ~name:"alice"
      ~email:"alice@c2c.im"
  in
  Alcotest.(check (list string))
    "only name injected when email pre-set" [ "GIT_AUTHOR_NAME" ]
    (overlay_keys overlay)

let test_parent_sets_both () =
  let parent_env =
    [| "GIT_AUTHOR_NAME=Op"; "GIT_AUTHOR_EMAIL=ops@example.com" |]
  in
  let overlay =
    C2c_git_shim.build_author_overlay ~parent_env ~name:"alice"
      ~email:"alice@c2c.im"
  in
  Alcotest.(check int)
    "no overlay when both pre-set" 0 (Array.length overlay)

(* Ensure exec semantics: parent env wins because overlay is empty for that
   key, and Unix.execve uses Array.append [overlay] [parent_env] — overlay
   first wins for keys it sets, parent for keys it doesn't. We assert the
   absence directly above; this test pins the contract that the overlay
   never DUPLICATES a key the parent already had (which would otherwise
   shadow it via earlier-position-wins). *)
let test_no_duplicate_keys () =
  let parent_env = [| "GIT_AUTHOR_NAME=Op" |] in
  let overlay =
    C2c_git_shim.build_author_overlay ~parent_env ~name:"alice"
      ~email:"alice@c2c.im"
  in
  let dup =
    Array.exists
      (fun s ->
        String.length s >= 16 && String.sub s 0 16 = "GIT_AUTHOR_NAME=")
      overlay
  in
  Alcotest.(check bool) "overlay does not redefine pre-set name" false dup

let () =
  Alcotest.run "c2c_git_shim"
    [
      ( "build_author_overlay",
        [
          Alcotest.test_case "empty parent env" `Quick test_no_parent;
          Alcotest.test_case "parent sets name" `Quick test_parent_sets_name;
          Alcotest.test_case "parent sets email" `Quick test_parent_sets_email;
          Alcotest.test_case "parent sets both" `Quick test_parent_sets_both;
          Alcotest.test_case "no duplicate keys" `Quick test_no_duplicate_keys;
        ] );
    ]
