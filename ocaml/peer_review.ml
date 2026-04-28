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
  build_exit_code : int option;
  (** #427b: structured capture of the reviewer's slice-worktree build verdict.
      [Some 0] = clean build in slice's own worktree; [Some n] = non-zero
      exit; [None] = unsignaled (legacy v1 artifacts, or callers that didn't
      pass [--build-rc]). When this field is [Some _], [version] is bumped
      to 2 and the field is included in the canonical-JSON sign target.
      Reviewers passing [--build-rc] should also retain the textual
      [build-clean-IN-slice-worktree-rc=N] entry in [criteria_checked] for
      backward-readable evidence. *)
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
  let base = [
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
  ] in
  (* #427b: include build_exit_code only when set. Omitting it on legacy
     artifacts keeps v1 canonical bytes unchanged; including it on v2
     artifacts puts it in scope of the Ed25519 signature. *)
  let with_build = match art.build_exit_code with
    | Some n -> ("build_exit_code", `Int n) :: base
    | None -> base
  in
  `Assoc (sort_assoc with_build)

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
      let build_exit_code =
        match List.assoc_opt "build_exit_code" fields with
        | Some (`Int n) -> Some n
        | _ -> None
      in
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
        build_exit_code;
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

(** #57 Defence-in-depth path-traversal validator.

    [artifact_path] composes a filesystem path from caller-supplied [alias] and
    [sha]. Today the production callers feed these via [claim_of_content], which
    restricts alias to [a-z0-9_-] and sha to lowercase hex, so traversal is
    closed *de facto*. But [verify_claim_with_pin] / [verify_claim] /
    [artifact_path] are public functions; any future caller that passes an
    unfiltered alias (e.g., from [Broker.list_registrations], which does not
    enforce these character restrictions at registration time) reopens the
    traversal vector.

    The validator below independently rejects:
      - alias: empty, contains '/' '\' '..' NUL, leading '.', or any byte
        outside printable ASCII (0x20-0x7e) excluding ' '.
      - sha: not matching ^[0-9a-f]{4,64}$ (lowercase hex, 4..64 chars).

    Rejection short-circuits before any [Filename.concat]. *)
let validate_artifact_path_components ~alias ~sha : (unit, string) result =
  let is_alias_byte_ok c =
    let code = Char.code c in
    (* Printable ASCII excluding space; explicit allowlist is even tighter
       below via the structural checks (no '/', '\\', '.', NUL). *)
    code >= 0x21 && code <= 0x7e
  in
  let alias_has_dotdot s =
    let len = String.length s in
    let rec loop i =
      if i + 1 >= len then false
      else if s.[i] = '.' && s.[i+1] = '.' then true
      else loop (i + 1)
    in
    loop 0
  in
  let alias_max_bytes = 128 in
  let alias_invalid =
    if alias = "" then Some "alias is empty"
    else if String.length alias > alias_max_bytes then
      Some (Printf.sprintf "alias exceeds %d bytes" alias_max_bytes)
    else if String.contains alias '/' then Some "alias contains '/'"
    else if String.contains alias '\\' then Some "alias contains '\\'"
    else if String.contains alias '\x00' then Some "alias contains NUL byte"
    else if alias.[0] = '.' then Some "alias has leading '.'"
    else if alias_has_dotdot alias then Some "alias contains '..'"
    else
      let bad =
        let len = String.length alias in
        let rec scan i =
          if i >= len then None
          else if not (is_alias_byte_ok alias.[i]) then Some alias.[i]
          else scan (i + 1)
        in
        scan 0
      in
      match bad with
      | Some c -> Some (Printf.sprintf "alias contains non-printable byte 0x%02x" (Char.code c))
      | None -> None
  in
  let sha_invalid =
    let len = String.length sha in
    if len = 0 then Some "sha is empty"
    else if len < 4 then Some "sha shorter than 4 chars"
    else if len > 64 then Some "sha longer than 64 chars"
    else
      let rec scan i =
        if i >= len then None
        else
          let c = sha.[i] in
          if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') then scan (i + 1)
          else Some (Printf.sprintf "sha contains non-hex byte 0x%02x at offset %d" (Char.code c) i)
      in
      scan 0
  in
  match alias_invalid, sha_invalid with
  | Some msg, _ -> Error msg
  | _, Some msg -> Error msg
  | None, None -> Ok ()

(** Artifact file path for a given sha+alias pair. Uses git common dir parent
    so peer-passes are shared across all worktrees clones.

    #57: raises [Invalid_argument] if alias/sha fail
    [validate_artifact_path_components]. The high-level entry points
    ([verify_claim], [verify_claim_with_pin]) translate this into a
    [Claim_invalid] result so the broker's reject-logging machinery picks
    it up. Direct callers should pre-validate or be prepared to handle the
    exception. *)
let artifact_path ~sha ~alias =
  (match validate_artifact_path_components ~alias ~sha with
   | Ok () -> ()
   | Error msg ->
       invalid_arg (Printf.sprintf "artifact_path: alias/sha rejected by path-validator: %s" msg));
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

(** Maximum allowed size of a peer-pass artifact JSON file on disk.
    Real artifacts are well under 2KB; the cap exists to refuse a malicious
    or accidentally-huge file before it OOMs the broker on read. See #56. *)
let peer_pass_max_artifact_bytes = 64 * 1024

(** Read a file with a hard size cap. Stats the file first; refuses if the
    on-disk length exceeds [peer_pass_max_artifact_bytes]. Returns the raw
    bytes on success, or a [`Too_large of int] / [`Read_error of string]
    on failure. *)
let read_artifact_capped path
  : (string, [> `Too_large of int | `Read_error of string ]) result =
  try
    let st = Unix.stat path in
    let sz = st.Unix.st_size in
    if sz > peer_pass_max_artifact_bytes then Error (`Too_large sz)
    else
      let ic = open_in path in
      Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        Ok (really_input_string ic sz))
  with
  | Unix.Unix_error (e, _, _) -> Error (`Read_error (Unix.error_message e))
  | Sys_error msg -> Error (`Read_error msg)
  | e -> Error (`Read_error (Printexc.to_string e))

(** Read a peer-pass artifact from a JSON file. Enforces the artifact size
    cap before parsing — see [peer_pass_max_artifact_bytes]. *)
let read_artifact path =
  match read_artifact_capped path with
  | Error (`Too_large sz) ->
    Error (Printf.sprintf "artifact exceeds size cap (%d bytes > %d)"
             sz peer_pass_max_artifact_bytes)
  | Error (`Read_error msg) -> Error msg
  | Ok content ->
    try
      match t_of_json (Yojson.Safe.from_string content) with
      | Some art -> Ok art
      | None -> Error "JSON parse failed"
    with e -> Error (Printexc.to_string e)

(** Result of peer-pass claim verification. *)
type claim_verification =
  | Claim_valid of string        (* success message *)
  | Claim_missing of string       (* artifact file not found *)
  | Claim_invalid of string      (* signature/alias/sha mismatch *)

(** Verify a peer-pass claim: load the artifact, check signature, confirm
    alias and sha match. Returns Claim_valid on success.

    #57: rejects up-front if alias/sha fail the path-validator, so a
    caller passing unfiltered input never reaches [Filename.concat]. *)
let verify_claim ~alias ~sha =
  match validate_artifact_path_components ~alias ~sha with
  | Error msg ->
    Claim_invalid (Printf.sprintf "alias/sha rejected by path-validator: %s" msg)
  | Ok () ->
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

  (** #409: serialize concurrent save callers via Unix.lockf on a sidecar
      lock file. Without this, two upserters both writing simultaneously
      can race: A's atomic-rename and B's atomic-rename both succeed, but
      whichever ran rename second wins, silently dropping the loser's pin
      update. Pattern matches Broker.with_inbox_lock (c2c_mcp.ml:1193).
      Note: this fixes save-vs-save; the load→upsert→save read-modify-write
      window is NOT covered (load happens before this lock). Callers that
      need read-modify-write atomicity should hold this lock around the
      full sequence — see [with_pin_lock] below. *)
  let with_pin_lock ?path f =
    let p = match path with Some p -> p | None -> default_path () in
    mkdir_p (Filename.dirname p);
    let lock_path = p ^ ".lock" in
    let fd =
      Unix.openfile lock_path [ O_RDWR; O_CREAT ] 0o644
    in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
        (try Unix.close fd with _ -> ()))
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        f ())

  let save ?path (s : store) : unit =
    with_pin_lock ?path (fun () ->
      let p = match path with Some p -> p | None -> default_path () in
      let tmp = p ^ ".tmp" in
      let oc = open_out tmp in
      Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
        output_string oc (Yojson.Safe.pretty_to_string (store_to_json s));
        output_string oc "\n");
      Sys.rename tmp p)

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

(** #55: structured audit-log hook for pin rotation. The default no-op
    keeps the library standalone (no hard dep on c2c_mcp); the broker
    + CLI register a writer that appends a JSON line to
    <broker_root>/broker.log. Because the hook lives in [pin_rotate]
    itself (not at a single CLI call site), every caller — current and
    future, MCP and CLI alike — produces an audit entry. Any code that
    silently rotates a pin without going through [pin_rotate] is now
    the bug, not the missing log line. *)
type pin_rotate_log_event = {
  alias : string;
  old_pubkey : string;        (* "" when no prior pin existed *)
  new_pubkey : string;
  prior_first_seen : float option;
  ts : float;
  path : string;              (* the pin-store path used for this rotate *)
}

let pin_rotate_log_hook : (pin_rotate_log_event -> unit) ref =
  ref (fun _ -> ())

let set_pin_rotate_logger f = pin_rotate_log_hook := f

(** Apply TOFU pin policy on a verified artifact. The artifact's signature
    MUST already have been verified by [verify] before calling this — the pin
    policy is only meaningful on cryptographically valid signatures.

    On [Pin_first_seen] and [Pin_match], the pin is updated (last_seen
    bumped, or new pin written for first-seen). On [Pin_mismatch] nothing
    is written; caller is expected to surface the mismatch as a hard error.

    Use [pin_rotate] for the explicit rotation path.

    #54b: the entire load→decide→save sequence is wrapped in
    [Trust_pin.with_pin_lock] so two concurrent callers cannot interleave
    in the read-modify-write window. Without the wrap, A.load + B.load +
    A.save + B.save sees B clobber A's update; with the wrap, B blocks
    on A.save before its own load runs. *)
let pin_check ?path (art : t) : pin_check =
  Trust_pin.with_pin_lock ?path (fun () ->
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
      })

(** Explicit rotation: replace the existing pin (or create one) regardless
    of mismatch. Returns the previous pin (if any) for audit logging.

    #54b: load→upsert→save runs under [Trust_pin.with_pin_lock] so a
    concurrent verify-and-pin (or a parallel rotate) cannot interleave.
    #55: emits a structured audit-log event via [pin_rotate_log_hook]
    after the save lands. The hook fires for both first-rotate (no
    prior) and replacement; loggers can branch on
    [prior_first_seen = None] for the no-prior case. *)
let pin_rotate ?path (art : t) : Trust_pin.pin option =
  let resolved_path = match path with
    | Some p -> p
    | None -> Trust_pin.default_path ()
  in
  let prior =
    Trust_pin.with_pin_lock ?path (fun () ->
      let alias = art.reviewer in
      let store = Trust_pin.load ?path () in
      let prior = Trust_pin.find_pin store ~alias in
      let now = Unix.gettimeofday () in
      let first_seen = match prior with Some p -> p.Trust_pin.first_seen | None -> now in
      let new_pin = { Trust_pin.pubkey = art.reviewer_pk; first_seen; last_seen = now } in
      let store' = Trust_pin.upsert store ~alias ~pin:new_pin in
      Trust_pin.save ?path store';
      prior)
  in
  (* Best-effort audit log; never fail the rotate on a logger exception. *)
  (try
     let event = {
       alias = art.reviewer;
       old_pubkey = (match prior with Some p -> p.Trust_pin.pubkey | None -> "");
       new_pubkey = art.reviewer_pk;
       prior_first_seen = (match prior with Some p -> Some p.Trust_pin.first_seen | None -> None);
       ts = Unix.gettimeofday ();
       path = resolved_path;
     } in
     !pin_rotate_log_hook event
   with _ -> ());
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
(** [verify_claim_for_artifact] runs the H2 + H2b policy checks against an
    already-loaded artifact: sha/reviewer field match + signature verify +
    TOFU pubkey pin. Used by both the broker (which loads the artifact from
    its canonical path inside [verify_claim_with_pin]) and the CLI (which
    loads from a user-supplied path and calls this directly).

    Splitting the in-memory checks out of [verify_claim_with_pin] (#62)
    converges CLI and broker on the same policy without duplicating the
    sha/reviewer/sig/pin ladder. Future hardening lands once. *)
let verify_claim_for_artifact ?path ~(art : t) ~alias ~sha () : claim_verification =
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

let verify_claim_with_pin ?path ~alias ~sha () =
  match validate_artifact_path_components ~alias ~sha with
  | Error msg ->
    Claim_invalid (Printf.sprintf "alias/sha rejected by path-validator: %s" msg)
  | Ok () ->
  let art_path = artifact_path ~sha ~alias in
  if not (Sys.file_exists art_path) then
    Claim_missing (Printf.sprintf "no peer-pass artifact at %s" art_path)
  else
    match read_artifact art_path with
    | Error e -> Claim_invalid (Printf.sprintf "artifact read error: %s" e)
    | Ok art -> verify_claim_for_artifact ?path ~art ~alias ~sha ()
