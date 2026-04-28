(* c2c_peer_pass.ml — CLI for signed peer-PASS review artifacts *)

open Cmdliner.Term.Syntax
let ( // ) = Filename.concat

(* shared per-alias signing key helpers *)
let xdg_state_home = C2c_utils.xdg_state_home
let per_alias_key_path = C2c_signing_helpers.per_alias_key_path

(* --- path helpers ------------------------------------------------------- *)

let peer_passes_dir () =
  match Git_helpers.git_common_dir_parent () with
  | Some parent -> parent // ".c2c" // "peer-passes"
  | None -> failwith "not in a git repository"

let artifact_path ~sha ~alias =
  peer_passes_dir () // Printf.sprintf "%s-%s.json" sha alias

(* --- identity helpers ---------------------------------------------------- *)

let resolve_current_alias () =
  match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
  | Some alias when alias <> "" -> alias
  | _ ->
      Printf.eprintf "error: C2C_MCP_AUTO_REGISTER_ALIAS is not set — cannot sign peer-PASS artifact without a known identity.\n%!";
      exit 1

let resolve_identity () =
  let alias = resolve_current_alias () in
  match per_alias_key_path ~alias with
  | Some path when Sys.file_exists path ->
      Relay_identity.load_or_create_at ~path ~alias_hint:alias
  | _ ->
      Printf.eprintf "error: no per-alias key at <broker>/keys/%s.ed25519. Re-run 'c2c register' to generate.\n%!"
        alias;
      exit 1

(* --- anti-cheat helpers -------------------------------------------------- *)

(** Compare reviewer alias against commit author. The repo convention records
    authors as "<alias>@c2c.im" / name "<alias>". Match either. *)
let reviewer_is_author ~reviewer ~sha =
  let email = Git_helpers.git_commit_author_email sha in
  let name = Git_helpers.git_commit_author_name sha in
  let local_part_eq e =
    match String.index_opt e '@' with
    | Some i -> String.equal (String.sub e 0 i) reviewer
    | None -> String.equal e reviewer
  in
  (match email with Some e -> local_part_eq e | None -> false)
  || (match name with Some n -> String.equal n reviewer | None -> false)

let validate_signing_allowed ~alias ~sha ~allow_self =
  if not (Git_helpers.git_commit_exists sha) then begin
    Printf.eprintf "error: SHA %s does not resolve to a commit in this repository.\n%!" sha;
    Printf.eprintf "  fix: confirm the SHA is correct and the branch is fetched locally.\n%!";
    exit 1
  end;
  if reviewer_is_author ~reviewer:alias ~sha && not allow_self then begin
    Printf.eprintf
      "error: refusing to sign — reviewer alias %S matches commit author of %s.\n\
      \  Self-review-via-skill is NOT a peer-PASS (see git-workflow.md rule 3).\n\
      \  Get another swarm agent to run review-and-fix on this SHA.\n\
      \  If a coordinator has explicitly approved this, re-run with --allow-self.\n%!"
      alias sha;
    exit 1
  end

let criteria_list_of_string = function
  | Some s when s <> "" ->
      String.split_on_char ',' s |> List.map String.trim |> List.filter ((<>) "")
  | _ -> []

let targets_for_all all_targets =
  {
    Peer_review.c2c = all_targets;
    Peer_review.c2c_mcp_server = all_targets;
    Peer_review.c2c_inbox_hook = all_targets;
  }

let signed_artifact ~alias ~sha ~verdict ~criteria ~skill_version ~commit_range
    ~all_targets ~notes ~allow_self =
  validate_signing_allowed ~alias ~sha ~allow_self;
  let identity = resolve_identity () in
  let art = {
    Peer_review.version = 1;
    Peer_review.reviewer = alias;
    Peer_review.reviewer_pk = "";
    Peer_review.sha;
    Peer_review.verdict = Option.value verdict ~default:"PASS";
    Peer_review.criteria_checked = criteria_list_of_string criteria;
    Peer_review.skill_version = Option.value skill_version ~default:"unknown";
    Peer_review.commit_range = Option.value commit_range ~default:"";
    Peer_review.targets_built = targets_for_all all_targets;
    Peer_review.notes = Option.value notes ~default:"";
    Peer_review.signature = "";
    Peer_review.ts = Unix.gettimeofday ();
  } in
  Peer_review.sign ~identity art

let write_artifact ~sha ~alias signed =
  let path = artifact_path ~sha ~alias in
  (try C2c_utils.mkdir_p (Filename.dirname path) with _ -> ());
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc (Peer_review.t_to_string signed);
    output_string oc "\n");
  path

let peer_pass_message ~reviewer ~sha ?branch ?worktree () =
  let base = Printf.sprintf "peer-PASS by %s, SHA=%s" reviewer sha in
  let parts =
    [ Some base
    ; Option.map (Printf.sprintf "branch=%s") branch
    ; Option.map (Printf.sprintf "in %s") worktree
    ]
  in
  parts |> List.filter_map Fun.id |> String.concat ", "

(* --- sign command -------------------------------------------------------- *)

let peer_pass_sign_cmd =
  let sha =
    Cmdliner.Arg.(required & pos 0 (some string) None & info []
      ~docv:"SHA" ~doc:"Git SHA of the reviewed commit")
  in
  let verdict_conv =
    Cmdliner.Arg.enum [ "PASS", "PASS"; "FAIL", "FAIL" ]
  in
  let verdict =
    Cmdliner.Arg.(value & opt (some verdict_conv) (Some "PASS") & info [ "verdict"; "v" ]
      ~docv:"VERDICT" ~doc:"Review verdict (PASS or FAIL)")
  in
  let criteria =
    Cmdliner.Arg.(value & opt (some string) None & info [ "criteria"; "c" ]
      ~docv:"CRITERIA" ~doc:"Comma-separated list of criteria checked")
  in
  let skill_version =
    Cmdliner.Arg.(value & opt (some string) None & info [ "skill-version" ]
      ~docv:"VERSION" ~doc:"review-and-fix skill version (e.g. 1.0.0)")
  in
  let commit_range =
    Cmdliner.Arg.(value & opt (some string) None & info [ "commit-range" ]
      ~docv:"RANGE" ~doc:"Commit range reviewed (e.g. abc123..def456)")
  in
  let all_targets =
    Cmdliner.Arg.(value & flag & info [ "all-targets" ]
      ~doc:"Mark all three binaries (c2c, c2c_mcp_server, c2c_inbox_hook) as built")
  in
  let notes =
    Cmdliner.Arg.(value & opt (some string) None & info [ "notes"; "n" ]
      ~docv:"NOTES" ~doc:"Free-text notes from the review")
  in
  let json =
    Cmdliner.Arg.(value & flag & info [ "json"; "j" ] ~doc:"Output machine-readable JSON.")
  in
  let allow_self =
    Cmdliner.Arg.(value & flag & info [ "allow-self" ]
      ~doc:"Override the self-review anti-cheat check (reviewer == commit author). \
            Use only with explicit coordinator approval.")
  in
  let+ sha = sha
  and+ verdict = verdict
  and+ criteria = criteria
  and+ skill_version = skill_version
  and+ commit_range = commit_range
  and+ all_targets = all_targets
  and+ notes = notes
  and+ json = json
  and+ allow_self = allow_self in
  let alias = resolve_current_alias () in
  let signed =
    signed_artifact ~alias ~sha ~verdict ~criteria ~skill_version ~commit_range
      ~all_targets ~notes ~allow_self
  in
  let path = write_artifact ~sha ~alias signed in
  if json then
    Printf.printf "%s\n" (Yojson.Safe.pretty_to_string (Peer_review.t_to_json signed))
  else
    Printf.printf "Signed artifact written to %s\n%!" path

(* --- send command -------------------------------------------------------- *)

let peer_pass_send_cmd =
  let to_alias =
    Cmdliner.Arg.(required & pos 0 (some string) None & info []
      ~docv:"ALIAS" ~doc:"Coordinator or peer alias to notify after signing")
  in
  let sha =
    Cmdliner.Arg.(required & pos 1 (some string) None & info []
      ~docv:"SHA" ~doc:"Git SHA of the reviewed commit")
  in
  let verdict_conv =
    Cmdliner.Arg.enum [ "PASS", "PASS"; "FAIL", "FAIL" ]
  in
  let verdict =
    Cmdliner.Arg.(value & opt (some verdict_conv) (Some "PASS") & info [ "verdict"; "v" ]
      ~docv:"VERDICT" ~doc:"Review verdict (PASS or FAIL)")
  in
  let criteria =
    Cmdliner.Arg.(value & opt (some string) None & info [ "criteria"; "c" ]
      ~docv:"CRITERIA" ~doc:"Comma-separated list of criteria checked")
  in
  let skill_version =
    Cmdliner.Arg.(value & opt (some string) None & info [ "skill-version" ]
      ~docv:"VERSION" ~doc:"review-and-fix skill version (e.g. 1.0.0)")
  in
  let commit_range =
    Cmdliner.Arg.(value & opt (some string) None & info [ "commit-range" ]
      ~docv:"RANGE" ~doc:"Commit range reviewed (e.g. abc123..def456)")
  in
  let all_targets =
    Cmdliner.Arg.(value & flag & info [ "all-targets" ]
      ~doc:"Mark all three binaries (c2c, c2c_mcp_server, c2c_inbox_hook) as built")
  in
  let notes =
    Cmdliner.Arg.(value & opt (some string) None & info [ "notes"; "n" ]
      ~docv:"NOTES" ~doc:"Free-text notes from the review")
  in
  let branch =
    Cmdliner.Arg.(value & opt (some string) None & info [ "branch"; "b" ]
      ~docv:"BRANCH" ~doc:"Reviewed branch name to include in the notification")
  in
  let worktree =
    Cmdliner.Arg.(value & opt (some string) None & info [ "worktree"; "w" ]
      ~docv:"PATH" ~doc:"Reviewed worktree path to include in the notification")
  in
  let json =
    Cmdliner.Arg.(value & flag & info [ "json"; "j" ] ~doc:"Output machine-readable JSON.")
  in
  let allow_self =
    Cmdliner.Arg.(value & flag & info [ "allow-self" ]
      ~doc:"Override the self-review anti-cheat check (reviewer == commit author). \
            Use only with explicit coordinator approval.")
  in
  let+ to_alias = to_alias
  and+ sha = sha
  and+ verdict = verdict
  and+ criteria = criteria
  and+ skill_version = skill_version
  and+ commit_range = commit_range
  and+ all_targets = all_targets
  and+ notes = notes
  and+ branch = branch
  and+ worktree = worktree
  and+ json = json
  and+ allow_self = allow_self in
  let alias = resolve_current_alias () in
  let signed =
    signed_artifact ~alias ~sha ~verdict ~criteria ~skill_version ~commit_range
      ~all_targets ~notes ~allow_self
  in
  let path = write_artifact ~sha ~alias signed in
  let content = peer_pass_message ~reviewer:alias ~sha ?branch ?worktree () in
  let broker = C2c_mcp.Broker.create ~root:(C2c_utils.resolve_broker_root ()) in
  (try C2c_mcp.Broker.enqueue_message broker ~from_alias:alias ~to_alias ~content ()
   with Invalid_argument msg ->
     Printf.eprintf "error: signed artifact written to %s, but notification send failed: %s\n%!"
       path msg;
     exit 1);
  if json then
    Printf.printf "%s\n%!" (Yojson.Safe.pretty_to_string (`Assoc [
      ("ok", `Bool true);
      ("artifact_path", `String path);
      ("reviewer", `String alias);
      ("sha", `String sha);
      ("sent_to", `String to_alias);
      ("message", `String content);
    ]))
  else
    Printf.printf "Signed artifact written to %s\nSent peer-PASS notification to %s\n%!" path to_alias

(* --- verify command ------------------------------------------------------ *)

let read_json_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    really_input_string ic (in_channel_length ic))

let peer_pass_verify_cmd =
  let file =
    Cmdliner.Arg.(required & pos 0 (some string) None & info []
      ~docv:"FILE" ~doc:"Path to peer-PASS JSON artifact (or SHA for default location)")
  in
  let strict =
    Cmdliner.Arg.(value & flag & info [ "strict" ]
      ~doc:"Exit non-zero on anti-cheat WARN (e.g. self-review). Useful for CI/scripted gates.")
  in
  let+ file = file
  and+ strict = strict in
  let path =
    if Sys.file_exists file then file
    else
      let alias = resolve_current_alias () in
      let dir = peer_passes_dir () in
      let guessed = dir // Printf.sprintf "%s-%s.json" file alias in
      if Sys.file_exists guessed then guessed
      else (Printf.eprintf "error: artifact not found: %s\n%!" file; exit 1)
  in
  try
    let content = String.trim (read_json_file path) in
    match Peer_review.t_of_string content with
    | Some art ->
      (match Peer_review.verify art with
       | Ok true ->
         Printf.printf "VERIFIED: valid signature by %s for commit %s (verdict: %s)\n%!"
           art.Peer_review.reviewer art.Peer_review.sha art.Peer_review.verdict;
         Printf.printf "  reviewer: %s\n  ts: %.0f\n  criteria: [%s]\n%!"
           art.Peer_review.reviewer
           art.Peer_review.ts
           (String.concat ", " art.Peer_review.criteria_checked);
         (* Anti-cheat surface: warn if reviewer == commit author. *)
         let self_review =
           Git_helpers.git_commit_exists art.Peer_review.sha
           && reviewer_is_author ~reviewer:art.Peer_review.reviewer ~sha:art.Peer_review.sha
         in
         if self_review then
           Printf.printf "  WARN: reviewer %S matches commit author — self-review (not a true peer-PASS).\n%!"
             art.Peer_review.reviewer;
         if strict && self_review then begin
           Printf.eprintf "STRICT: failing on self-review WARN.\n%!";
           exit 1
         end
       | Ok false ->
         Printf.eprintf "VERIFY FAILED: invalid signature\n%!"; exit 1
       | Error e ->
         Printf.eprintf "VERIFY ERROR: %s\n%!" (Peer_review.verify_error_to_string e); exit 1)
    | None ->
      Printf.eprintf "error: could not parse artifact JSON from %s\n%!" path; exit 1
  with e ->
    Printf.eprintf "error: could not read %s: %s\n%!" path (Printexc.to_string e); exit 1

(* --- list command -------------------------------------------------------- *)

let peer_pass_list_cmd =
  let json = Cmdliner.Arg.(value & flag & info [ "json"; "j" ] ~doc:"Output machine-readable JSON.") in
  let warn_only =
    Cmdliner.Arg.(value & flag & info [ "warn-only" ]
      ~doc:"Show only artifacts where reviewer matches the commit author (self-review WARN).")
  in
  let+ json = json
  and+ warn_only = warn_only in
  let dir = peer_passes_dir () in
  let is_self_review art =
    Git_helpers.git_commit_exists art.Peer_review.sha
    && reviewer_is_author ~reviewer:art.Peer_review.reviewer ~sha:art.Peer_review.sha
  in
  if not (Sys.file_exists dir) then (
    if json then Printf.printf "[]\n%!" else Printf.printf "No peer passes stored.\n%!";
  ) else (
    try
      let files = Array.to_list (Sys.readdir dir) |> List.filter (fun f -> Filename.check_suffix f ".json") in
      if json then (
        let items = List.filter_map (fun f ->
          let path = dir // f in
          match try Some (String.trim (read_json_file path)) with _ -> None with
          | Some content -> (
            match Peer_review.t_of_string content with
            | Some art ->
              let self_review = is_self_review art in
              if warn_only && not self_review then None
              else Some (`Assoc [
                ("file", `String f);
                ("reviewer", `String art.Peer_review.reviewer);
                ("sha", `String art.Peer_review.sha);
                ("verdict", `String art.Peer_review.verdict);
                ("ts", `Float art.Peer_review.ts);
                ("self_review", `Bool self_review);
              ])
            | None ->
              if warn_only then None
              else Some (`Assoc [("file", `String f); ("parse_error", `Bool true)]))
          | None ->
            if warn_only then None
            else Some (`Assoc [("file", `String f); ("read_error", `Bool true)])
        ) files in
        Printf.printf "%s\n%!" (Yojson.Safe.pretty_to_string (`List items))
      ) else (
        List.iter (fun f ->
          let path = dir // f in
          match try Some (String.trim (read_json_file path)) with _ -> None with
          | Some content -> (
            match Peer_review.t_of_string content with
            | Some art ->
              let self_review = is_self_review art in
              if warn_only && not self_review then ()
              else
                Printf.printf "%s  %s  %s  %s  (%.0f)%s\n%!"
                  f art.Peer_review.reviewer art.Peer_review.sha art.Peer_review.verdict art.Peer_review.ts
                  (if self_review then "  WARN:self-review" else "")
            | None ->
              if not warn_only then Printf.printf "%s  [parse error]\n%!" f
          )
          | None ->
            if not warn_only then Printf.printf "%s  [read error]\n%!" f
        ) files
      )
    with e ->
      Printf.eprintf "error listing peer passes: %s\n%!" (Printexc.to_string e); exit 1
  )

(* --- clean command ------------------------------------------------------- *)

let peer_pass_clean_cmd =
  let apply =
    Cmdliner.Arg.(value & flag & info [ "apply" ]
      ~doc:"Actually delete the matched artifacts. Default is dry-run (print only).")
  in
  let json =
    Cmdliner.Arg.(value & flag & info [ "json"; "j" ] ~doc:"Output machine-readable JSON.")
  in
  let+ apply = apply
  and+ json = json in
  let dir = peer_passes_dir () in
  if not (Sys.file_exists dir) then begin
    if json then Printf.printf "{\"matched\":0,\"deleted\":0}\n%!"
    else Printf.printf "No peer passes stored.\n%!"
  end else begin
    let files = Array.to_list (Sys.readdir dir) |> List.filter (fun f -> Filename.check_suffix f ".json") in
    let matched = List.filter_map (fun f ->
      let path = dir // f in
      match try Some (String.trim (read_json_file path)) with _ -> None with
      | Some content -> (
        match Peer_review.t_of_string content with
        | Some art when Git_helpers.git_commit_exists art.Peer_review.sha
                       && reviewer_is_author ~reviewer:art.Peer_review.reviewer ~sha:art.Peer_review.sha ->
          Some (f, path, art)
        | _ -> None)
      | None -> None) files
    in
    let deleted =
      if apply then
        List.fold_left (fun n (_, path, _) ->
          try Sys.remove path; n + 1 with _ -> n) 0 matched
      else 0
    in
    if json then
      Printf.printf "%s\n%!" (Yojson.Safe.pretty_to_string (`Assoc [
        ("matched", `Int (List.length matched));
        ("deleted", `Int deleted);
        ("dry_run", `Bool (not apply));
        ("files", `List (List.map (fun (f, _, art) -> `Assoc [
          ("file", `String f);
          ("reviewer", `String art.Peer_review.reviewer);
          ("sha", `String art.Peer_review.sha);
        ]) matched));
      ]))
    else begin
      let header = if apply then "Deleted self-review artifacts:" else "Would delete self-review artifacts (dry-run; pass --apply):" in
      Printf.printf "%s\n" header;
      List.iter (fun (f, _, art) ->
        Printf.printf "  %s  %s  %s\n" f art.Peer_review.reviewer art.Peer_review.sha) matched;
      Printf.printf "(%d matched%s)\n%!"
        (List.length matched)
        (if apply then Printf.sprintf ", %d deleted" deleted else "")
    end
  end

(* --- group --------------------------------------------------------------- *)

let peer_pass_group =
  Cmdliner.Cmd.group
    ~default:peer_pass_list_cmd
    (Cmdliner.Cmd.info "peer-pass" ~doc:"Sign, send, and verify signed peer-PASS review artifacts")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "sign" ~doc:"Sign a peer-PASS artifact.") peer_pass_sign_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "send" ~doc:"Sign a peer-PASS artifact and notify a peer.") peer_pass_send_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "verify" ~doc:"Verify a signed peer-PASS artifact.") peer_pass_verify_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List stored peer-PASS artifacts.") peer_pass_list_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "clean"
        ~doc:"Delete self-review peer-PASS artifacts (dry-run by default).") peer_pass_clean_cmd ]
