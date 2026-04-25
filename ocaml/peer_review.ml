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
