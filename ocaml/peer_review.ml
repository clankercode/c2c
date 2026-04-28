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

(* --- TOFU pubkey pin (H1: alias <-> pubkey binding) ----------------------- *)

(* Background: prior to the H1 fix, [verify] above accepted whatever
   [reviewer_pk] was embedded in the artifact, as long as the signature
   validated against that key. Any agent could forge a peer-PASS for any
   alias by minting a fresh ed25519 keypair and signing under their target's
   alias. The trust anchor was "whoever wrote the file", not cryptographic
   identity.

   The TOFU pin store closes that gap by binding alias -> pubkey on first
   verify. Subsequent verifies for the same alias must present the same
   pubkey or be rejected. Rotation requires explicit operator action via
   [pin_rotate] (CLI: `c2c peer-pass verify --rotate-pin`).

   Pin store format (JSON, at <broker_root>/peer-pass-trust.json):
     { "version": 1,
       "pins": { "<alias>": { "pubkey": "<b64url>",
                              "first_seen": <unix-ts>,
                              "last_seen": <unix-ts> } } } *)

module Trust_pin = struct
  type pin = {
    pubkey : string;       (* b64url, same encoding as Peer_review.reviewer_pk *)
    first_seen : float;
    last_seen : float;
  }

  type store = {
    version : int;
    pins : (string * pin) list;  (* alias -> pin; alias keys lowercased *)
  }

  let empty = { version = 1; pins = [] }

  let pin_to_json p : Yojson.Safe.t =
    `Assoc [
      "pubkey", `String p.pubkey;
      "first_seen", `Float p.first_seen;
      "last_seen", `Float p.last_seen;
    ]

  let pin_of_json (j : Yojson.Safe.t) : pin option =
    match j with
    | `Assoc fields ->
      let get_str f = match List.assoc_opt f fields with Some (`String s) -> s | _ -> "" in
      let get_float f =
        match List.assoc_opt f fields with
        | Some (`Float f) -> f
        | Some (`Int i) -> float_of_int i
        | _ -> 0.0
      in
      let pubkey = get_str "pubkey" in
      if pubkey = "" then None
      else Some { pubkey; first_seen = get_float "first_seen"; last_seen = get_float "last_seen" }
    | _ -> None

  let store_to_json s : Yojson.Safe.t =
    let pins_obj = `Assoc (List.map (fun (a, p) -> (a, pin_to_json p)) s.pins) in
    `Assoc [
      "version", `Int s.version;
      "pins", pins_obj;
    ]

  let store_of_json (j : Yojson.Safe.t) : store option =
    match j with
    | `Assoc fields ->
      let version =
        match List.assoc_opt "version" fields with
        | Some (`Int i) -> i
        | _ -> 1
      in
      let pins =
        match List.assoc_opt "pins" fields with
        | Some (`Assoc plist) ->
          List.filter_map (fun (alias, j) ->
            match pin_of_json j with
            | Some p -> Some (String.lowercase_ascii alias, p)
            | None -> None) plist
        | _ -> []
      in
      Some { version; pins }
    | _ -> None

  (** Default pin-store path: <broker_root>/peer-pass-trust.json. The caller
      may override via [path] for tests / explicit broker roots. *)
  let default_path_ref : (unit -> string) ref =
    ref (fun () ->
      (* Fallback: under the current dir's .c2c if no broker resolver is
         wired. The CLI overrides this on startup. *)
      let base =
        match Git_helpers.git_common_dir_parent () with
        | Some p -> Filename.concat p ".c2c"
        | None -> ".c2c"
      in
      Filename.concat base "peer-pass-trust.json")

  let set_default_path_resolver f = default_path_ref := f
  let default_path () = !default_path_ref ()

  let load ?path () : store =
    let p = match path with Some p -> p | None -> default_path () in
    if not (Sys.file_exists p) then empty
    else
      try
        match store_of_json (Yojson.Safe.from_file p) with
        | Some s -> s
        | None -> empty
      with _ -> empty

  let mkdir_p d =
    let rec aux p =
      if p = "" || p = "/" || p = "." then ()
      else if Sys.file_exists p then ()
      else begin
        aux (Filename.dirname p);
        try Unix.mkdir p 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
      end
    in
    aux d

  let save ?path (s : store) : unit =
    let p = match path with Some p -> p | None -> default_path () in
    mkdir_p (Filename.dirname p);
    let tmp = p ^ ".tmp" in
    let oc = open_out tmp in
    Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      output_string oc (Yojson.Safe.pretty_to_string (store_to_json s));
      output_string oc "\n");
    Sys.rename tmp p

  let find_pin (s : store) ~alias : pin option =
    List.assoc_opt (String.lowercase_ascii alias) s.pins

  let upsert (s : store) ~alias ~pin : store =
    let key = String.lowercase_ascii alias in
    let pins =
      (key, pin) :: List.filter (fun (a, _) -> a <> key) s.pins
    in
    { s with pins }
end

type pin_check =
  | Pin_first_seen        (* no prior pin; pin written this call (TOFU) *)
  | Pin_match             (* artifact pubkey matches existing pin *)
  | Pin_mismatch of {
      alias : string;
      pinned_pubkey : string;
      artifact_pubkey : string;
      first_seen : float;
    }

(** Apply TOFU pin policy on a verified artifact. The artifact's signature
    MUST already have been verified by [verify] before calling this — the pin
    policy is only meaningful on cryptographically valid signatures.

    On [Pin_first_seen] and [Pin_match], the pin is updated (last_seen
    bumped, or new pin written for first-seen). On [Pin_mismatch] nothing
    is written; caller is expected to surface the mismatch as a hard error.

    Use [pin_rotate] for the explicit rotation path. *)
let pin_check ?path (art : t) : pin_check =
  let alias = art.reviewer in
  let store = Trust_pin.load ?path () in
  let now = Unix.gettimeofday () in
  match Trust_pin.find_pin store ~alias with
  | None ->
    let new_pin =
      { Trust_pin.pubkey = art.reviewer_pk; first_seen = now; last_seen = now }
    in
    let store' = Trust_pin.upsert store ~alias ~pin:new_pin in
    Trust_pin.save ?path store';
    Pin_first_seen
  | Some existing when existing.Trust_pin.pubkey = art.reviewer_pk ->
    let bumped = { existing with Trust_pin.last_seen = now } in
    let store' = Trust_pin.upsert store ~alias ~pin:bumped in
    Trust_pin.save ?path store';
    Pin_match
  | Some existing ->
    Pin_mismatch {
      alias;
      pinned_pubkey = existing.Trust_pin.pubkey;
      artifact_pubkey = art.reviewer_pk;
      first_seen = existing.Trust_pin.first_seen;
    }

(** Explicit rotation: replace the existing pin (or create one) regardless
    of mismatch. Returns the previous pin (if any) for audit logging. *)
let pin_rotate ?path (art : t) : Trust_pin.pin option =
  let alias = art.reviewer in
  let store = Trust_pin.load ?path () in
  let prior = Trust_pin.find_pin store ~alias in
  let now = Unix.gettimeofday () in
  let first_seen = match prior with Some p -> p.Trust_pin.first_seen | None -> now in
  let new_pin = { Trust_pin.pubkey = art.reviewer_pk; first_seen; last_seen = now } in
  let store' = Trust_pin.upsert store ~alias ~pin:new_pin in
  Trust_pin.save ?path store';
  prior

(** Convenience wrapper that fuses signature verification with TOFU pin
    enforcement. Returns:
    - [Ok Pin_first_seen | Pin_match] on success (pin written/updated).
    - [Error] for any signature failure (passthrough from [verify]).
    - [Ok (Pin_mismatch _)] for TOFU mismatch (caller decides hard-fail vs
      rotation prompt). *)
let verify_with_pin ?path (art : t) : (pin_check, verify_error) result =
  match verify art with
  | Error e -> Error e
  | Ok false -> Error Invalid_signature
  | Ok true -> Ok (pin_check ?path art)

(** Pin-aware variant of [verify_claim] for the broker boundary (#29 H2b).

    Behaves like [verify_claim] but additionally enforces the TOFU pubkey
    pin via [verify_with_pin]. The forgery vector closed by this function:
    an attacker generates a fresh ed25519 keypair, signs an artifact under
    a victim alias (embedding the fresh pubkey as [reviewer_pk]), drops
    the artifact at the well-known path, and DMs a "peer-PASS by <victim>,
    SHA=<sha>" — without pin enforcement, the signature validates against
    the attacker-controlled pubkey and [verify_claim] returns
    [Claim_valid]. With pin enforcement, the artifact's [reviewer_pk]
    must match the existing pin for that alias (or be the first-seen
    pubkey for the alias).

    Pin policy:
    - [Pin_first_seen] -> [Claim_valid] (TOFU; pin written this call).
    - [Pin_match]      -> [Claim_valid].
    - [Pin_mismatch]   -> [Claim_invalid] with a structured reason
                          including pinned + artifact pubkey fingerprints
                          (full b64url) for audit.

    The optional [path] override targets the pin store JSON; the broker
    wires this to a path under its broker root so all worktrees of one
    repo share one pin set, and tests pass an isolated path. *)
let verify_claim_with_pin ?path ~alias ~sha () =
  let art_path = artifact_path ~sha ~alias in
  if not (Sys.file_exists art_path) then
    Claim_missing (Printf.sprintf "no peer-pass artifact at %s" art_path)
  else
    match read_artifact art_path with
    | Error e -> Claim_invalid (Printf.sprintf "artifact read error: %s" e)
    | Ok art ->
      if art.sha <> sha then
        Claim_invalid (Printf.sprintf "SHA mismatch: artifact is for %s, claim is for %s" art.sha sha)
      else if String.lowercase_ascii art.reviewer <> String.lowercase_ascii alias then
        Claim_invalid (Printf.sprintf "reviewer mismatch: artifact is by %s, claim is by %s" art.reviewer alias)
      else begin
        match verify_with_pin ?path art with
        | Error e ->
          Claim_invalid (Printf.sprintf "invalid signature: %s" (verify_error_to_string e))
        | Ok Pin_match ->
          Claim_valid (Printf.sprintf "peer-pass artifact verified: %s for %s" art.verdict sha)
        | Ok Pin_first_seen ->
          Claim_valid (Printf.sprintf "peer-pass artifact verified (pin first-seen): %s for %s" art.verdict sha)
        | Ok (Pin_mismatch m) ->
          Claim_invalid
            (Printf.sprintf
               "pin mismatch for reviewer %s: pinned pubkey=%s, artifact pubkey=%s, first_seen=%.0f"
               m.alias m.pinned_pubkey m.artifact_pubkey m.first_seen)
      end
