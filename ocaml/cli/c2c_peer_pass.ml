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

(* #57 defence-in-depth: validate alias/sha before composing the artifact
   path. Same validator as [Peer_review.validate_artifact_path_components];
   the CLI builds its own path under a different base so we re-check here
   rather than relying on the lib check downstream. *)
let artifact_path ~sha ~alias =
  (match Peer_review.validate_artifact_path_components ~alias ~sha with
   | Ok () -> ()
   | Error msg ->
       Printf.eprintf
         "error: cannot build peer-pass artifact path — alias/sha rejected by \
          path-validator: %s\n%!"
         msg;
       exit 1);
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

(** Compare reviewer alias against commit authorship. The repo convention
    records authors as "<alias>@c2c.im" / name "<alias>"; match the primary
    [%ae]/[%an] either way.

    M1 (audit 2026-04-28): also check [Co-authored-by:] trailers — a
    reviewer who co-authored the commit can still self-PASS otherwise.
    Each trailer value is in [Name <email>] form; we extract the email
    and compare its local-part to [reviewer]. If any author surface
    matches, treat as author and block self-PASS. *)
let reviewer_is_author ~reviewer ~sha =
  let email = Git_helpers.git_commit_author_email sha in
  let name = Git_helpers.git_commit_author_name sha in
  let co_author_emails = Git_helpers.git_commit_co_author_emails sha in
  let local_part_eq e =
    match String.index_opt e '@' with
    | Some i -> String.equal (String.sub e 0 i) reviewer
    | None -> String.equal e reviewer
  in
  (match email with Some e -> local_part_eq e | None -> false)
  || (match name with Some n -> String.equal n reviewer | None -> false)
  || List.exists local_part_eq co_author_emails

let validate_signing_allowed ~alias ~sha ~allow_self =
  if not (Git_helpers.git_commit_exists sha) then begin
    Printf.eprintf "error: SHA %s does not resolve to a commit in this repository.\n%!" sha;
    Printf.eprintf "  fix: confirm the SHA is correct and the branch is fetched locally.\n%!";
    exit 1
  end;
  if reviewer_is_author ~reviewer:alias ~sha && not allow_self then begin
    Printf.eprintf
      "error: self-sign refused — reviewer alias %S matches commit author of %s.\n\
      \  Default-strict: an independent live swarm peer is the canonical reviewer.\n\
      \  If the review came from a fresh-slate review-and-fix subagent (no live\n\
      \  peer available, or mechanical/low-stakes slice), this is sanctioned —\n\
      \  re-run with --allow-self (and optionally --via-subagent <id> for\n\
      \  auditability). See git-workflow.md \"Subagent-review as peer-PASS\".\n\
      \  HIGH-severity slices (security, data-loss, broker state, signing crypto)\n\
      \  should still get a live peer if at all possible.\n%!"
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

let merge_subagent_into_notes ~via_subagent ~notes =
  let base = Option.value notes ~default:"" in
  match via_subagent with
  | Some id when id <> "" ->
      let tag = Printf.sprintf "via-subagent: %s" id in
      if base = "" then tag else Printf.sprintf "%s; %s" base tag
  | _ -> base

(* #427c: PASS verdicts MUST carry a structured build-rc unless the
   slice author opts out via --no-build-rc (legitimate doc-only / runbook
   slices where there's no compile target). FAIL verdicts are unaffected
   (a FAIL by definition records that something didn't work; the rc, if
   any, is part of the FAIL evidence not a precondition). *)
let validate_build_rc_precondition ~verdict ~build_rc ~no_build_rc =
  let resolved_verdict = Option.value verdict ~default:"PASS" in
  if resolved_verdict = "PASS" && build_rc = None && not no_build_rc then begin
    Printf.eprintf
      "error: PASS peer-pass artifacts must carry --build-rc N (the exit code \
       from a build run IN the slice's own worktree, per Pattern 8 / #427b).\n\
       \n\
       Pass --build-rc 0 after `cd .worktrees/<slice>/ && just build` returns 0,\n\
       or pass --no-build-rc when the slice has no compilable target (pure\n\
       documentation / runbook / configuration changes that need no build\n\
       verification).\n\
       \n\
       See `.collab/skills/review-and-fix.md` Step 4 for the rubric.\n%!";
    exit 124
  end

let signed_artifact ~alias ~sha ~verdict ~criteria ~skill_version ~commit_range
    ~all_targets ~notes ~allow_self ~via_subagent ~build_rc ~no_build_rc =
  validate_signing_allowed ~alias ~sha ~allow_self;
  validate_build_rc_precondition ~verdict ~build_rc ~no_build_rc;
  let identity = resolve_identity () in
  let final_notes = merge_subagent_into_notes ~via_subagent ~notes in
  (* #427c: when --no-build-rc is used on a PASS, augment the notes so
     the audit trail records that the precondition was explicitly waived
     (vs accidentally omitted on an old binary that didn't enforce it). *)
  let final_notes =
    if no_build_rc && build_rc = None then
      let tag = "no-build-rc:doc-only" in
      if final_notes = "" then tag else Printf.sprintf "%s; %s" final_notes tag
    else final_notes
  in
  (* #427b: schema-version bump from 1 → 2 only when build_rc is set, so
     legacy v1 artifacts continue signing/verifying byte-identically. *)
  let version = match build_rc with Some _ -> 2 | None -> 1 in
  let art = {
    Peer_review.version;
    Peer_review.reviewer = alias;
    Peer_review.reviewer_pk = "";
    Peer_review.sha;
    Peer_review.verdict = Option.value verdict ~default:"PASS";
    Peer_review.criteria_checked = criteria_list_of_string criteria;
    Peer_review.skill_version = Option.value skill_version ~default:"unknown";
    Peer_review.commit_range = Option.value commit_range ~default:"";
    Peer_review.targets_built = targets_for_all all_targets;
    Peer_review.notes = final_notes;
    Peer_review.signature = "";
    Peer_review.ts = Unix.gettimeofday ();
    Peer_review.build_exit_code = build_rc;
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
      ~doc:"Sanctioned override for the self-sign check (reviewer == commit author). \
            Use when the verdict came from a fresh-slate review-and-fix subagent \
            and no live peer was available, or for mechanical/low-stakes slices. \
            See git-workflow.md \"Subagent-review as peer-PASS\".")
  in
  let via_subagent =
    Cmdliner.Arg.(value & opt (some string) None & info [ "via-subagent" ]
      ~docv:"ID" ~doc:"Record the fresh-slate subagent task id (or short description) \
                       used for the review. Appended to the artifact's notes field \
                       for auditability when --allow-self is in effect.")
  in
  let build_rc =
    Cmdliner.Arg.(value & opt (some int) None & info [ "build-rc" ]
      ~docv:"N" ~doc:"#427b: capture the slice-worktree build exit code as a \
                      structured field on the artifact. 0 = clean build in the \
                      slice's own worktree (the only value that should accompany \
                      a PASS verdict per Pattern 8); non-zero = the reviewer ran \
                      the build but it failed. Bumps the artifact schema to v2. \
                      Reviewers should also retain a textual \
                      'build-clean-IN-slice-worktree-rc=N' entry in --criteria \
                      for backward-readable evidence. PASS without --build-rc \
                      is rejected unless --no-build-rc is also passed (#427c).")
  in
  let no_build_rc =
    Cmdliner.Arg.(value & flag & info [ "no-build-rc" ]
      ~doc:"#427c: opt out of the PASS-must-carry-build-rc precondition. \
            Use ONLY for legitimate doc-only / runbook / config-only slices \
            where no compilable target exists. Recorded in the artifact \
            notes as 'no-build-rc:doc-only' for audit. Cannot be combined \
            with --build-rc.")
  in
  let+ sha = sha
  and+ verdict = verdict
  and+ criteria = criteria
  and+ skill_version = skill_version
  and+ commit_range = commit_range
  and+ all_targets = all_targets
  and+ notes = notes
  and+ json = json
  and+ allow_self = allow_self
  and+ via_subagent = via_subagent
  and+ build_rc = build_rc
  and+ no_build_rc = no_build_rc in
  if build_rc <> None && no_build_rc then begin
    Printf.eprintf "error: --build-rc and --no-build-rc are mutually exclusive\n%!";
    exit 124
  end;
  let alias = resolve_current_alias () in
  let signed =
    signed_artifact ~alias ~sha ~verdict ~criteria ~skill_version ~commit_range
      ~all_targets ~notes ~allow_self ~via_subagent ~build_rc ~no_build_rc
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
      ~doc:"Sanctioned override for the self-sign check (reviewer == commit author). \
            Use when the verdict came from a fresh-slate review-and-fix subagent \
            and no live peer was available, or for mechanical/low-stakes slices. \
            See git-workflow.md \"Subagent-review as peer-PASS\".")
  in
  let via_subagent =
    Cmdliner.Arg.(value & opt (some string) None & info [ "via-subagent" ]
      ~docv:"ID" ~doc:"Record the fresh-slate subagent task id (or short description) \
                       used for the review. Appended to the artifact's notes field \
                       for auditability when --allow-self is in effect.")
  in
  let build_rc =
    Cmdliner.Arg.(value & opt (some int) None & info [ "build-rc" ]
      ~docv:"N" ~doc:"#427b: capture the slice-worktree build exit code on the \
                      signed artifact. 0 = clean build in the slice's own \
                      worktree; non-zero = build failed. Bumps schema to v2. \
                      PASS without --build-rc is rejected unless --no-build-rc \
                      is also passed (#427c).")
  in
  let no_build_rc =
    Cmdliner.Arg.(value & flag & info [ "no-build-rc" ]
      ~doc:"#427c: opt out of the PASS-must-carry-build-rc precondition. \
            Use ONLY for legitimate doc-only / runbook / config-only slices \
            where no compilable target exists.")
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
  and+ allow_self = allow_self
  and+ via_subagent = via_subagent
  and+ build_rc = build_rc
  and+ no_build_rc = no_build_rc in
  (* Mutex check at the CLI level (defensive — the precondition validator
     also catches it but the user gets a friendlier message here). *)
  if build_rc <> None && no_build_rc then begin
    Printf.eprintf "error: --build-rc and --no-build-rc are mutually exclusive\n%!";
    exit 124
  end;
  let alias = resolve_current_alias () in
  let signed =
    signed_artifact ~alias ~sha ~verdict ~criteria ~skill_version ~commit_range
      ~all_targets ~notes ~allow_self ~via_subagent ~build_rc ~no_build_rc
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

(* Read a peer-pass artifact file with the size cap from Peer_review.
   On too-large or read error, prints to stderr and exits 1.
   See #56: refuse > [Peer_review.peer_pass_max_artifact_bytes] (64KB)
   to prevent OOM/DoS via a malicious artifact. *)
let read_json_file path =
  match Peer_review.read_artifact_capped path with
  | Ok content -> content
  | Error (`Too_large sz) ->
    Printf.eprintf
      "error: artifact %s exceeds size cap (%d bytes > %d)\n%!"
      path sz Peer_review.peer_pass_max_artifact_bytes;
    exit 1
  | Error (`Read_error msg) ->
    Printf.eprintf "error: cannot read artifact %s: %s\n%!" path msg;
    exit 1

(* H1: TOFU pin store lives under the broker root so all worktrees of a
   given repo share one alias <-> pubkey binding. Override the default
   resolver before any verify call. *)
let trust_pin_path () =
  Filename.concat (C2c_utils.resolve_broker_root ()) "peer-pass-trust.json"

let () =
  Peer_review.Trust_pin.set_default_path_resolver trust_pin_path

let peer_pass_verify_cmd =
  let file =
    Cmdliner.Arg.(required & pos 0 (some string) None & info []
      ~docv:"FILE" ~doc:"Path to peer-PASS JSON artifact (or SHA for default location)")
  in
  let strict =
    Cmdliner.Arg.(value & flag & info [ "strict" ]
      ~doc:"Exit non-zero on anti-cheat WARN (e.g. self-review). Useful for CI/scripted gates.")
  in
  let rotate_pin =
    Cmdliner.Arg.(value & flag & info [ "rotate-pin" ]
      ~doc:"Replace the existing TOFU pubkey pin for this reviewer alias. \
            Use ONLY for legitimate key rotation; pin replacement is logged \
            and printed as a clear audit warning.")
  in
  let+ file = file
  and+ strict = strict
  and+ rotate_pin = rotate_pin in
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
      let do_anti_cheat () =
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
      in
      let print_verified () =
        Printf.printf "VERIFIED: valid signature by %s for commit %s (verdict: %s)\n%!"
          art.Peer_review.reviewer art.Peer_review.sha art.Peer_review.verdict;
        Printf.printf "  reviewer: %s\n  ts: %.0f\n  criteria: [%s]\n%!"
          art.Peer_review.reviewer
          art.Peer_review.ts
          (String.concat ", " art.Peer_review.criteria_checked);
        (match art.Peer_review.build_exit_code with
         | Some n -> Printf.printf "  build_exit_code: %d (#427b verified-build)\n%!" n
         | None -> ())
      in
      if rotate_pin then begin
        (* Rotate path explicitly replaces the existing pin, so it cannot
           go through verify_claim_for_artifact (which enforces the pin).
           Keep the existing rotate ladder: signature must verify, then
           rotate, then optional anti-cheat warn.
           #432 TOFU Finding 4: pin_rotate now verifies internally, so
           the CLI's pre-call verify is redundant for safety but kept for
           the print_verified user-facing message ladder.

           #432 TOFU Finding 5: pin_rotate also requires an operator
           attestation. The CLI is run by a human (or coord-agent) with
           shell access on the broker host — that's the SPEC-defined
           operator boundary, so [Cli_local_shell] is the correct
           attestation here. A future MCP rotate tool would use
           [Mcp_operator_token <tok>] and require C2C_OPERATOR_AUTH_TOKEN
           to be set on the broker. *)
        match Peer_review.verify art with
        | Ok true ->
          print_verified ();
          (match Peer_review.pin_rotate ~attestation:Peer_review.Cli_local_shell art with
           | Error e ->
             Printf.eprintf "  PIN-ROTATE REJECTED: %s\n%!"
               (Peer_review.verify_error_to_string e);
             exit 1
           | Ok prior ->
             (match prior with
              | None ->
                Printf.printf "  PIN-ROTATE: no prior pin for %s; recorded new pubkey.\n%!"
                  art.Peer_review.reviewer
              | Some p ->
                Printf.printf
                  "  PIN-ROTATE WARNING: replaced pin for %s.\n    \
                  old pubkey: %s\n    \
                  new pubkey: %s\n    \
                  old first_seen: %.0f\n%!"
                  art.Peer_review.reviewer
                  p.Peer_review.Trust_pin.pubkey
                  art.Peer_review.reviewer_pk
                  p.Peer_review.Trust_pin.first_seen);
             do_anti_cheat ())
        | Ok false ->
          Printf.eprintf "VERIFY FAILED: invalid signature\n%!"; exit 1
        | Error e ->
          Printf.eprintf "VERIFY ERROR: %s\n%!" (Peer_review.verify_error_to_string e); exit 1
      end else begin
        (* #62: route the non-rotate path through verify_claim_for_artifact
           so CLI and broker share one signature+TOFU policy ladder. The
           sha/reviewer match check inside is vacuous here (we pass the
           artifact's own values), but signature verify and pin enforcement
           are the load-bearing pieces; future hardening on those lands
           once and applies to both surfaces. *)
        match
          Peer_review.verify_claim_for_artifact
            ~art
            ~alias:art.Peer_review.reviewer
            ~sha:art.Peer_review.sha
            ()
        with
        | Peer_review.Claim_valid _msg ->
          print_verified ();
          (* The valid path covers Pin_first_seen and Pin_match; differentiate
             for the operator-facing TOFU message by re-reading the pin store. *)
          (match Peer_review.pin_check art with
           | Peer_review.Pin_first_seen ->
             Printf.printf "  TOFU: first verify for %s; pubkey pinned.\n%!"
               art.Peer_review.reviewer
           | Peer_review.Pin_match ->
             Printf.printf "  TOFU: pubkey matches pin for %s.\n%!"
               art.Peer_review.reviewer
           | Peer_review.Pin_mismatch _ ->
             (* Should be unreachable: verify_claim_for_artifact returns
                Claim_invalid on Pin_mismatch. Guard for safety. *)
             Printf.eprintf "VERIFY FAILED: pin state changed during verify\n%!"; exit 1);
          do_anti_cheat ()
        | Peer_review.Claim_invalid msg ->
          (* Surface pin-mismatch with the same operator-friendly hint as
             pre-#62, since the claim message is broker-shaped. *)
          (match Peer_review.pin_check art with
           | Peer_review.Pin_mismatch { alias; pinned_pubkey; artifact_pubkey; first_seen } ->
             Printf.eprintf
               "VERIFY FAILED: TOFU pin mismatch for alias %s.\n  \
               pinned pubkey:    %s\n  \
               artifact pubkey:  %s\n  \
               pin first_seen:   %.0f\n  \
               This artifact was signed by a DIFFERENT key than the one \
               previously seen for this alias.\n  \
               If this is a legitimate key rotation (e.g. lost device, \
               key rollover), re-run with --rotate-pin AFTER \
               out-of-band confirmation with the alias holder.\n%!"
               alias pinned_pubkey artifact_pubkey first_seen;
             exit 1
           | _ ->
             Printf.eprintf "VERIFY FAILED: %s\n%!" msg; exit 1)
        | Peer_review.Claim_missing msg ->
          Printf.eprintf "VERIFY FAILED: %s\n%!" msg; exit 1
      end
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
