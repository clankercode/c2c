(** Tests for c2c_coord.

    Two groups:
    - [382-per-pick-head]: regression for #382 — per-cherry-pick HEAD
      capture for auto-DM (a multi-SHA batch must NOT cite the final
      HEAD as new_sha for every author).
    - [classify_install_outcome] (#401): pure decision helper for
      `--no-fail-on-install` (rc<>0 with the flag → soft-fail; without
      → hard-fail; rc=0 always → ok). *)

open Alcotest

let sh fmt =
  Printf.ksprintf (fun cmd ->
      let code = Sys.command (cmd ^ " >/dev/null 2>&1") in
      if code <> 0 then
        failwith (Printf.sprintf "shell command failed (%d): %s" code cmd))
    fmt

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let rec loop acc =
         try loop (input_line ic :: acc)
         with End_of_file -> List.rev acc
       in
       loop [])

(* Build a repo with two commits on master, then create a side branch
   carrying two more commits ([sha_a], [sha_b]) that we can cherry-pick
   back onto master. Returns (repo_dir, sha_a, sha_b). *)
let make_repo_with_two_picks dir =
  let repo = Filename.concat dir "repo" in
  sh "git init -q -b master %s" (Filename.quote repo);
  sh "git -C %s config user.email coord@test" (Filename.quote repo);
  sh "git -C %s config user.name coord" (Filename.quote repo);
  sh "echo base > %s/f" (Filename.quote repo);
  sh "git -C %s add f" (Filename.quote repo);
  sh "git -C %s commit -q -m base" (Filename.quote repo);
  (* Side branch with two cherry-pickable commits authored by a known
     coord email so dm_author has a valid lookup path (though we override
     via the capture-args fixture anyway). *)
  sh "git -C %s checkout -q -b side" (Filename.quote repo);
  sh "echo a > %s/a.txt" (Filename.quote repo);
  sh "git -C %s add a.txt" (Filename.quote repo);
  sh "git -C %s commit -q -m commit-a" (Filename.quote repo);
  let sha_a =
    let ic = Unix.open_process_in
        (Printf.sprintf "git -C %s rev-parse HEAD" (Filename.quote repo))
    in
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
      (fun () -> input_line ic |> String.trim)
  in
  sh "echo b > %s/b.txt" (Filename.quote repo);
  sh "git -C %s add b.txt" (Filename.quote repo);
  sh "git -C %s commit -q -m commit-b" (Filename.quote repo);
  let sha_b =
    let ic = Unix.open_process_in
        (Printf.sprintf "git -C %s rev-parse HEAD" (Filename.quote repo))
    in
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
      (fun () -> input_line ic |> String.trim)
  in
  sh "git -C %s checkout -q master" (Filename.quote repo);
  (repo, sha_a, sha_b)

(* The bug: a multi-SHA batch produced auto-DMs that all cited the final
   HEAD as `new_sha`. Fix: capture HEAD per-cherry-pick. We assert that
   the two captured `new_sha` values differ. *)
let test_dm_author_captures_per_cherry_pick_HEAD () =
  let tmp = Filename.temp_file "c2c-coord-382-" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  Fun.protect
    ~finally:(fun () ->
        ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmp))))
    (fun () ->
       let repo, sha_a, sha_b = make_repo_with_two_picks tmp in
       let capture_path = Filename.concat tmp "dm-calls.log" in
       Unix.putenv "C2C_COORDINATOR" "1";
       Unix.putenv "C2C_REPO_ROOT" repo;
       Unix.putenv "C2C_COORD_DM_FIXTURE" "capture-args";
       Unix.putenv "C2C_COORD_DM_CAPTURE_FILE" capture_path;
       (* Drive the real run_coord_cherry_pick logic, skipping install
          (no `just` available in test env) but exercising the per-pick
          HEAD capture + DM call site we changed for #382. *)
       (try
          C2c_coord.run_coord_cherry_pick
            ~no_install:true ~no_dm:false ~shas:[sha_a; sha_b] ()
        with Stdlib.Exit -> ());
       let lines = read_file capture_path in
       check int "two DM calls captured" 2 (List.length lines);
       (* Each line: "<original_sha> <new_sha>". Pull out the new_shas
          and check they differ — i.e. NOT both equal to final HEAD. *)
       let parts =
         List.map
           (fun l ->
              match String.split_on_char ' ' l with
              | [orig; nw] -> (orig, nw)
              | _ -> failwith ("bad capture line: " ^ l))
           lines
       in
       let orig0, new0 = List.nth parts 0 in
       let orig1, new1 = List.nth parts 1 in
       check string "first DM original is sha_a" sha_a orig0;
       check string "second DM original is sha_b" sha_b orig1;
       check bool "per-pick new_sha differs across calls" true (new0 <> new1);
       (* And specifically: new1 should equal current HEAD; new0 should NOT. *)
       let final_head =
         let ic = Unix.open_process_in
             (Printf.sprintf "git -C %s rev-parse HEAD" (Filename.quote repo))
         in
         Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
           (fun () -> input_line ic |> String.trim)
       in
       check string "second DM cites final HEAD" final_head new1;
       check bool "first DM does NOT cite final HEAD (the #382 bug)"
         true (new0 <> final_head))

(* #401: classify_install_outcome — pure decision helper. *)

let outcome_eq a b =
  match a, b with
  | `Ok, `Ok | `Soft_fail, `Soft_fail | `Hard_fail, `Hard_fail -> true
  | _ -> false

let outcome_pp ppf = function
  | `Ok -> Format.fprintf ppf "Ok"
  | `Soft_fail -> Format.fprintf ppf "Soft_fail"
  | `Hard_fail -> Format.fprintf ppf "Hard_fail"

let outcome = testable outcome_pp outcome_eq

let test_install_ok_strict () =
  check outcome "rc=0, strict-default -> Ok" `Ok
    (C2c_coord.classify_install_outcome ~rc:0 ~no_fail_on_install:false)

let test_install_ok_lenient () =
  check outcome "rc=0, --no-fail-on-install -> Ok" `Ok
    (C2c_coord.classify_install_outcome ~rc:0 ~no_fail_on_install:true)

let test_install_fail_strict_default () =
  check outcome "rc=1, strict-default -> Hard_fail" `Hard_fail
    (C2c_coord.classify_install_outcome ~rc:1 ~no_fail_on_install:false);
  check outcome "rc=127 (cmd-not-found), strict-default -> Hard_fail" `Hard_fail
    (C2c_coord.classify_install_outcome ~rc:127 ~no_fail_on_install:false)

let test_install_fail_with_no_fail_flag () =
  check outcome "rc=1, --no-fail-on-install -> Soft_fail" `Soft_fail
    (C2c_coord.classify_install_outcome ~rc:1 ~no_fail_on_install:true);
  check outcome "rc=137 (SIGKILL), --no-fail-on-install -> Soft_fail" `Soft_fail
    (C2c_coord.classify_install_outcome ~rc:137 ~no_fail_on_install:true)

let () =
  Alcotest.run "c2c_coord"
    [ "382-per-pick-head",
      [ test_case "dm_author captures per-cherry-pick HEAD"
          `Quick test_dm_author_captures_per_cherry_pick_HEAD ]
    ; ( "classify_install_outcome",
        [ ( "rc_zero_strict_returns_ok",
            `Quick, test_install_ok_strict )
        ; ( "rc_zero_lenient_returns_ok",
            `Quick, test_install_ok_lenient )
        ; ( "rc_nonzero_strict_returns_hard_fail",
            `Quick, test_install_fail_strict_default )
        ; ( "rc_nonzero_with_no_fail_flag_returns_soft_fail",
            `Quick, test_install_fail_with_no_fail_flag )
        ] )
    ]
