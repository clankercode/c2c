(* Peer_review — signed peer-PASS artifact for c2c code review chain.
   Spec: .collab/design/DRAFT-signed-peer-pass.md

   Reuses Relay_identity (Ed25519) for signing.
   Reviewer's public key is embedded in the artifact (like stickers design)
   so verification is self-contained and does not require a registry lookup. *)

(* --- types --------------------------------------------------------------- *)

type targets_built = {
  c2c : bool;
  c2c_mcp_server : bool;
  c2c_inbox_hook : bool;
}

type t = {
  version : int;
  reviewer : string;
  reviewer_pk : string;  (* base64url-encoded 32-byte Ed25519 public key *)
  sha : string;
  verdict : string;
  criteria_checked : string list;
  skill_version : string;
  commit_range : string;
  targets_built : targets_built;
  notes : string;
  signature : string;     (* base64url-encoded 64-byte Ed25519 signature *)
  ts : float;
}

(* --- JSON serialization --------------------------------------------------- *)

let b64url_encode s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let b64url_decode s =
  Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let sort_assoc lst =
  List.sort (fun (a, _) (b, _) -> String.compare a b) lst

let rec json_to_string_sorted (j : Yojson.Safe.t) : string =
  match j with
  | `Assoc fields ->
    let sorted = sort_assoc fields in
    let inner = List.map (fun (k, v) -> Printf.sprintf "%s:%s" (Yojson.Safe.to_string (`String k)) (json_to_string_sorted v)) sorted in
    "{" ^ String.concat "," inner ^ "}"
  | `List items ->
    let inner = List.map json_to_string_sorted items in
    "[" ^ String.concat "," inner ^ "]"
  | `String s -> Yojson.Safe.to_string (`String s)
  | `Null -> "null"
  | `Int i -> string_of_int i
  | `Intlit s -> s
  | `Float f -> string_of_float f
  | `Bool b -> string_of_bool b
  | _ -> Yojson.Safe.to_string j

let targets_built_to_json (tb : targets_built) : Yojson.Safe.t =
  `Assoc (sort_assoc [
    "c2c", `Bool tb.c2c;
    "c2c_mcp_server", `Bool tb.c2c_mcp_server;
    "c2c_inbox_hook", `Bool tb.c2c_inbox_hook;
  ])

let targets_built_of_json (j : Yojson.Safe.t) : targets_built option =
  match j with
  | `Assoc fields ->
    let get_bool f = match List.assoc_opt f fields with Some (`Bool b) -> b | _ -> false in
    Some { c2c = get_bool "c2c"; c2c_mcp_server = get_bool "c2c_mcp_server"; c2c_inbox_hook = get_bool "c2c_inbox_hook" }
  | _ -> None

let t_to_json (art : t) : Yojson.Safe.t =
  `Assoc (sort_assoc [
    "version", `Int art.version;
    "reviewer", `String art.reviewer;
    "reviewer_pk", `String art.reviewer_pk;
    "sha", `String art.sha;
    "verdict", `String art.verdict;
    "criteria_checked", `List (List.map (fun s -> `String s) art.criteria_checked);
    "skill_version", `String art.skill_version;
    "commit_range", `String art.commit_range;
    "targets_built", targets_built_to_json art.targets_built;
    "notes", `String art.notes;
    "ts", `Float art.ts;
    "signature", `String art.signature;
  ])

(* Canonical JSON for signing: same as to_json but without the signature field.
   Field order: version, reviewer, reviewer_pk, sha, verdict, criteria_checked,
                skill_version, commit_range, targets_built, notes, ts *)
let t_to_canonical_json (art : t) : string =
  let unsigned = { art with signature = "" } in
  let json = t_to_json unsigned in
  json_to_string_sorted json

let t_of_json (j : Yojson.Safe.t) : t option =
  match j with
  | `Assoc fields ->
    let get_str f = match List.assoc_opt f fields with Some (`String s) -> s | _ -> "" in
    let get_float f = match List.assoc_opt f fields with Some (`Float f) -> f | Some (`Int i) -> float_of_int i | _ -> 0.0 in
    let get_list f = match List.assoc_opt f fields with Some (`List l) -> List.filter_map (function `String s -> Some s | _ -> None) l | _ -> [] in
    let targets = match List.assoc_opt "targets_built" fields with Some j -> targets_built_of_json j | _ -> None in
    if targets = None then None
    else
      Some {
        version = (match List.assoc_opt "version" fields with Some (`Int i) -> i | _ -> 1);
        reviewer = get_str "reviewer";
        reviewer_pk = get_str "reviewer_pk";
        sha = get_str "sha";
        verdict = get_str "verdict";
        criteria_checked = get_list "criteria_checked";
        skill_version = get_str "skill_version";
        commit_range = get_str "commit_range";
        targets_built = Option.get targets;
        notes = get_str "notes";
        signature = get_str "signature";
        ts = get_float "ts";
      }
  | _ -> None

let t_to_string (art : t) : string =
  Yojson.Safe.to_string (t_to_json art)

let t_of_string (s : string) : t option =
  try t_of_json (Yojson.Safe.from_string s) with _ -> None

(* --- signing ------------------------------------------------------------- *)

let sign ~(identity : Relay_identity.t) (art : t) : t =
  let reviewer_pk = b64url_encode identity.Relay_identity.public_key in
  let art_with_pk = { art with reviewer_pk } in
  let canonical = t_to_canonical_json art_with_pk in
  let sig_bytes = Relay_identity.sign identity canonical in
  { art_with_pk with signature = b64url_encode sig_bytes }

(* --- verification -------------------------------------------------------- *)

type verify_error =
  | Missing_signature
  | Missing_reviewer_pk
  | Signature_b64_decode_failed
  | Reviewer_pk_b64_decode_failed
  | Reviewer_pk_wrong_length
  | Signature_wrong_length
  | Invalid_signature

let verify_error_to_string = function
  | Missing_signature -> "missing signature"
  | Missing_reviewer_pk -> "missing reviewer public key"
  | Signature_b64_decode_failed -> "signature base64 decode failed"
  | Reviewer_pk_b64_decode_failed -> "reviewer public key base64 decode failed"
  | Reviewer_pk_wrong_length -> "reviewer public key must be 32 bytes"
  | Signature_wrong_length -> "signature must be 64 bytes"
  | Invalid_signature -> "invalid signature"

let verify (art : t) : (bool, verify_error) result =
  if art.signature = "" then Error Missing_signature
  else if art.reviewer_pk = "" then Error Missing_reviewer_pk
  else
    match b64url_decode art.signature, b64url_decode art.reviewer_pk with
    | Error _, _ -> Error Signature_b64_decode_failed
    | _, Error _ -> Error Reviewer_pk_b64_decode_failed
    | Ok sig_bytes, Ok pk_bytes ->
      if String.length pk_bytes <> 32 then Error Reviewer_pk_wrong_length
      else if String.length sig_bytes <> 64 then Error Signature_wrong_length
      else
        let canonical = t_to_canonical_json art in
        match Relay_identity.verify ~pk:pk_bytes ~msg:canonical ~sig_:sig_bytes with
        | true -> Ok true
        | false -> Error Invalid_signature

(* --- peer-pass claim extraction and auto-verify ----------------------------- *)

(** Artifact file path for a given sha+alias pair. Uses git common dir parent
    so peer-passes are shared across all worktrees clones. *)
let artifact_path ~sha ~alias =
  let base = match Git_helpers.git_common_dir_parent () with
    | Some parent -> Filename.concat parent ".c2c"
    | None -> ".c2c"
  in
  Filename.concat base (Printf.sprintf "peer-passes/%s-%s.json" sha alias)

(** Parse "peer-PASS by <alias>" and "SHA=<sha>" from message content.
    Returns (alias, sha) if both patterns found, None otherwise.
    Case-insensitive for the peer-PASS marker; SHA is case-sensitive hex. *)
let claim_of_content content =
  let lc = String.lowercase_ascii content in
  let needle = "peer-pass by" in
  let needle_len = String.length needle in
  let rec find_alias pos =
    match String.index_from_opt lc pos needle.[0] with
    | None -> None
    | Some i ->
        if i + needle_len <= String.length lc
           && String.sub lc i needle_len = needle
        then
          let start = i + needle_len in
          let rec skip_space j =
            if j >= String.length lc then None
            else if lc.[j] = ' ' || lc.[j] = '\t' || lc.[j] = '\n' || lc.[j] = '\r'
            then skip_space (j + 1)
            else Some j
          in
          match skip_space start with
          | None -> None
          | Some pos ->
              let rec read_alias acc j =
                if j >= String.length lc then Some (acc, j)
                else
                  let c = lc.[j] in
                  if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-' || c = '_'
                  then read_alias (acc ^ String.make 1 c) (j + 1)
                  else Some (acc, j)
              in
              read_alias "" pos
        else find_alias (i + 1)
  in
  let sha_marker = "sha=" in
  let sha_marker_len = String.length sha_marker in
  let lc = String.lowercase_ascii content in
  let rec find_sha pos =
    match String.index_from_opt lc pos 's' with
    | None -> None
    | Some i ->
        if i + sha_marker_len <= String.length lc
           && String.sub lc i sha_marker_len = sha_marker
        then
          let start = i + sha_marker_len in
          let rec read_sha acc j =
            if j >= String.length lc then Some (acc, j)
            else
              let c = lc.[j] in
              if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
              then read_sha (acc ^ String.make 1 c) (j + 1)
              else if acc = "" then find_sha (j + 1) else Some (acc, j)
          in
          read_sha "" start
        else find_sha (i + 1)
  in
  match find_alias 0 with
  | None -> None
  | Some (alias, _) ->
      match find_sha 0 with
      | None -> None
      | Some (sha, _) ->
          if sha <> "" then Some (alias, sha) else None

(** Read a peer-pass artifact from a JSON file. *)
let read_artifact path =
  try
    let content = Yojson.Safe.from_file path in
    match t_of_json content with
    | Some art -> Ok art
    | None -> Error "JSON parse failed"
  with e -> Error (Printexc.to_string e)

(** Result of peer-pass claim verification. *)
type claim_verification =
  | Claim_valid of string        (* success message *)
  | Claim_missing of string       (* artifact file not found *)
  | Claim_invalid of string      (* signature/alias/sha mismatch *)

(** Verify a peer-pass claim: load the artifact, check signature, confirm
    alias and sha match. Returns Claim_valid on success. *)
let verify_claim ~alias ~sha =
  let path = artifact_path ~sha ~alias in
  if not (Sys.file_exists path) then
    Claim_missing (Printf.sprintf "no peer-pass artifact at %s" path)
  else
    match read_artifact path with
    | Error e -> Claim_invalid (Printf.sprintf "artifact read error: %s" e)
    | Ok art ->
        match verify art with
        | Error e -> Claim_invalid (Printf.sprintf "invalid signature: %s" (verify_error_to_string e))
        | Ok false -> Claim_invalid "signature verification failed"
        | Ok true ->
            if art.sha <> sha then
              Claim_invalid (Printf.sprintf "SHA mismatch: artifact is for %s, claim is for %s" art.sha sha)
            else if String.lowercase_ascii art.reviewer <> String.lowercase_ascii alias then
              Claim_invalid (Printf.sprintf "reviewer mismatch: artifact is by %s, claim is by %s" art.reviewer alias)
            else
              Claim_valid (Printf.sprintf "peer-pass artifact verified: %s for %s" art.verdict sha)
