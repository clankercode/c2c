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
  let+ sha = sha
  and+ verdict = verdict
  and+ criteria = criteria
  and+ skill_version = skill_version
  and+ commit_range = commit_range
  and+ all_targets = all_targets
  and+ notes = notes
  and+ json = json in
  let alias = resolve_current_alias () in
  let identity = resolve_identity () in
  let criteria_list = match criteria with
    | Some s when s <> "" -> String.split_on_char ',' s |> List.map String.trim |> List.filter ((<>) "")
    | _ -> []
  in
  let targets = {
    Peer_review.c2c = all_targets;
    Peer_review.c2c_mcp_server = all_targets;
    Peer_review.c2c_inbox_hook = all_targets;
  } in
  let art = {
    Peer_review.version = 1;
    Peer_review.reviewer = alias;
    Peer_review.reviewer_pk = "";
    Peer_review.sha;
    Peer_review.verdict = Option.value verdict ~default:"PASS";
    Peer_review.criteria_checked = criteria_list;
    Peer_review.skill_version = Option.value skill_version ~default:"unknown";
    Peer_review.commit_range = Option.value commit_range ~default:"";
    Peer_review.targets_built = targets;
    Peer_review.notes = Option.value notes ~default:"";
    Peer_review.signature = "";
    Peer_review.ts = Unix.gettimeofday ();
  } in
  let signed = Peer_review.sign ~identity art in
  let path = artifact_path ~sha ~alias in
  (try C2c_utils.mkdir_p (Filename.dirname path) with _ -> ());
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc (Peer_review.t_to_string signed);
    output_string oc "\n");
  if json then
    Printf.printf "%s\n" (Yojson.Safe.pretty_to_string (Peer_review.t_to_json signed))
  else
    Printf.printf "Signed artifact written to %s\n%!" path

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
  let+ file = file in
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
           (String.concat ", " art.Peer_review.criteria_checked)
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
  let+ json = json in
  let dir = peer_passes_dir () in
  if not (Sys.file_exists dir) then (
    if json then Printf.printf "[]\n%!" else Printf.printf "No peer passes stored.\n%!";
  ) else (
    try
      let files = Array.to_list (Sys.readdir dir) |> List.filter (fun f -> Filename.check_suffix f ".json") in
      if json then (
        let items = List.map (fun f ->
          let path = dir // f in
          match try Some (String.trim (read_json_file path)) with _ -> None with
          | Some content -> (
            match Peer_review.t_of_string content with
            | Some art -> `Assoc [
                ("file", `String f);
                ("reviewer", `String art.Peer_review.reviewer);
                ("sha", `String art.Peer_review.sha);
                ("verdict", `String art.Peer_review.verdict);
                ("ts", `Float art.Peer_review.ts);
              ]
            | None -> `Assoc [("file", `String f); ("parse_error", `Bool true)])
          | None -> `Assoc [("file", `String f); ("read_error", `Bool true)]
        ) files in
        Printf.printf "%s\n%!" (Yojson.Safe.pretty_to_string (`List items))
      ) else (
        List.iter (fun f ->
          let path = dir // f in
          match try Some (String.trim (read_json_file path)) with _ -> None with
          | Some content -> (
            match Peer_review.t_of_string content with
            | Some art ->
              Printf.printf "%s  %s  %s  %s  (%.0f)\n%!" f art.Peer_review.reviewer art.Peer_review.sha art.Peer_review.verdict art.Peer_review.ts
            | None ->
              Printf.printf "%s  [parse error]\n%!" f
          )
          | None ->
            Printf.printf "%s  [read error]\n%!" f
        ) files
      )
    with e ->
      Printf.eprintf "error listing peer passes: %s\n%!" (Printexc.to_string e); exit 1
  )

(* --- group --------------------------------------------------------------- *)

let peer_pass_group =
  Cmdliner.Cmd.group
    ~default:peer_pass_list_cmd
    (Cmdliner.Cmd.info "peer-pass" ~doc:"Sign and verify signed peer-PASS review artifacts")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "sign" ~doc:"Sign a peer-PASS artifact.") peer_pass_sign_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "verify" ~doc:"Verify a signed peer-PASS artifact.") peer_pass_verify_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List stored peer-PASS artifacts.") peer_pass_list_cmd ]
