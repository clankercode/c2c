(* test_c2c_peer_pass.ml — Alcotest for [reviewer_is_author] anti-cheat.

   Covers M1 from the 2026-04-28 peer-pass security audit
   (.collab/research/2026-04-28T05-34-30Z-stanza-coder-peer-pass-security-audit.md):
   a reviewer who appears in a [Co-authored-by:] trailer must still be
   treated as the author and blocked from self-PASS. *)

open Alcotest

let with_temp_repo (f : string -> unit) =
  let tmp = Filename.temp_file "c2c-peer-pass-test-" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o700;
  let cleanup () =
    let rec rm path =
      if Sys.file_exists path then
        if Sys.is_directory path then begin
          Array.iter (fun e -> rm (Filename.concat path e)) (Sys.readdir path);
          (try Unix.rmdir path with _ -> ())
        end else (try Sys.remove path with _ -> ())
    in
    rm tmp
  in
  Fun.protect ~finally:cleanup (fun () -> f tmp)

(* The test suite runs inside the c2c repo where a [git] shim on PATH
   re-enters [c2c git] and forces the active-agent identity onto every
   commit. Use the real binary directly so our [user.email]/[user.name]
   config takes effect inside the temp repo. *)
let real_git =
  if Sys.file_exists "/usr/bin/git" then "/usr/bin/git"
  else "git"

let run_in_dir dir cmd =
  let prev = Sys.getcwd () in
  Sys.chdir dir;
  Fun.protect ~finally:(fun () -> Sys.chdir prev) (fun () ->
    let rc = Sys.command cmd in
    if rc <> 0 then
      failwith (Printf.sprintf "command failed (rc=%d): %s" rc cmd))

let g cmd = real_git ^ " " ^ cmd

let init_repo dir =
  Unix.putenv "GIT_AUTHOR_NAME" "primary-author";
  Unix.putenv "GIT_AUTHOR_EMAIL" "primary-author@c2c.im";
  Unix.putenv "GIT_COMMITTER_NAME" "primary-author";
  Unix.putenv "GIT_COMMITTER_EMAIL" "primary-author@c2c.im";
  run_in_dir dir (g "init -q");
  run_in_dir dir (g "config user.email 'primary-author@c2c.im'");
  run_in_dir dir (g "config user.name 'primary-author'");
  run_in_dir dir (g "config commit.gpgsign false")

let head_sha dir =
  let prev = Sys.getcwd () in
  Sys.chdir dir;
  Fun.protect ~finally:(fun () -> Sys.chdir prev) (fun () ->
    let ic = Unix.open_process_in (g "rev-parse HEAD") in
    let line = input_line ic in
    ignore (Unix.close_process_in ic);
    String.trim line)

let test_parse_co_author_email_basic () =
  check (option string) "Name <email>"
    (Some "stanza-coder@c2c.im")
    (Git_helpers.parse_co_author_email "stanza-coder <stanza-coder@c2c.im>");
  check (option string) "extra whitespace"
    (Some "x@y.z")
    (Git_helpers.parse_co_author_email "  Some Name  <  x@y.z  >  ");
  check (option string) "no brackets"
    None
    (Git_helpers.parse_co_author_email "stanza-coder stanza-coder@c2c.im");
  check (option string) "empty brackets"
    None
    (Git_helpers.parse_co_author_email "Name <>")

let test_reviewer_is_author_blocks_co_authored_by () =
  with_temp_repo (fun dir ->
    init_repo dir;
    let cmd =
      g "commit --allow-empty -m 'feat: thing' \
         --trailer='Co-authored-by: stanza-coder <stanza-coder@c2c.im>'"
    in
    run_in_dir dir cmd;
    let sha = head_sha dir in
    let prev = Sys.getcwd () in
    Sys.chdir dir;
    Fun.protect ~finally:(fun () -> Sys.chdir prev) (fun () ->
      let emails = Git_helpers.git_commit_co_author_emails sha in
      check (list string) "trailer email extracted"
        ["stanza-coder@c2c.im"] emails;
      (* Direct anti-cheat check: reviewer = co-author -> blocked. *)
      check bool "co-authored-by reviewer treated as author"
        true (C2c_peer_pass.reviewer_is_author ~reviewer:"stanza-coder" ~sha);
      (* Primary author still matches. *)
      check bool "primary author still matches"
        true (C2c_peer_pass.reviewer_is_author ~reviewer:"primary-author" ~sha)))

let test_reviewer_is_author_doesnt_match_unrelated_co_author () =
  with_temp_repo (fun dir ->
    init_repo dir;
    let cmd =
      g "commit --allow-empty -m 'feat: other' \
         --trailer='Co-authored-by: someone-else <unrelated@c2c.im>'"
    in
    run_in_dir dir cmd;
    let sha = head_sha dir in
    let prev = Sys.getcwd () in
    Sys.chdir dir;
    Fun.protect ~finally:(fun () -> Sys.chdir prev) (fun () ->
      check bool "unrelated reviewer not flagged"
        false (C2c_peer_pass.reviewer_is_author ~reviewer:"stanza-coder" ~sha);
      (* Local-part of [unrelated@c2c.im] is [unrelated]; that's what the
         author-check matches against, not the display name. *)
      check bool "co-author email local-part flagged"
        true (C2c_peer_pass.reviewer_is_author ~reviewer:"unrelated" ~sha)))

let () =
  run "c2c_peer_pass" [
    "parse_co_author_email", [
      test_case "basic forms" `Quick test_parse_co_author_email_basic;
    ];
    "reviewer_is_author", [
      test_case "blocks co-authored-by reviewer (M1)" `Quick
        test_reviewer_is_author_blocks_co_authored_by;
      test_case "ignores unrelated co-author" `Quick
        test_reviewer_is_author_doesnt_match_unrelated_co_author;
    ];
  ]
