(* c2c_stickers.ml — Agent stickers: signed appreciation tokens *)

open Cmdliner.Term.Syntax
let ( // ) = Filename.concat

(* --- path helpers ------------------------------------------------------- *)

let sticker_dir () =
  match Git_helpers.git_common_dir_parent () with
  | Some parent -> parent // ".c2c" // "stickers"
  | None -> failwith "not in a git repository"

let received_dir ~alias =
  sticker_dir () // alias // "received"

let sent_dir ~alias =
  sticker_dir () // alias // "sent"

let public_dir () =
  sticker_dir () // "public"

(* shared per-alias signing key helpers (c2c_signing_helpers.ml) *)
let xdg_state_home = C2c_signing_helpers.xdg_state_home
let per_alias_key_path = C2c_signing_helpers.per_alias_key_path

(* --- registry ----------------------------------------------------------- *)

type registry_entry = {
  id : string;
  emoji : string;
  display_name : string;
  description : string;
}

let load_registry () =
  let reg_file = sticker_dir () // "registry.json" in
  try
    let json = Yojson.Safe.from_file reg_file in
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "stickers" fields with
       | Some (`List entries) ->
         List.filter_map (function
           | `Assoc e ->
             let id = List.assoc_opt "id" e |> function Some (`String s) -> s | _ -> "" in
             let emoji = List.assoc_opt "emoji" e |> function Some (`String s) -> s | _ -> "" in
             let display_name = List.assoc_opt "display_name" e |> function Some (`String s) -> s | _ -> "" in
             let description = List.assoc_opt "description" e |> function Some (`String s) -> s | _ -> "" in
             if id <> "" then Some { id; emoji; display_name; description } else None
           | _ -> None) entries
       | _ -> [])
    | _ -> []
  with _ -> []

let validate_sticker_id id =
  let registry = load_registry () in
  if List.exists (fun e -> e.id = id) registry then Ok ()
  else Error ("unknown sticker id: " ^ id)

(* --- envelope type ------------------------------------------------------ *)

type scope = [ `Public | `Private | `Both ]

type sticker_envelope = {
  version : int;
  from_ : string;
  to_ : string;
  sticker_id : string;
  note : string option;
  scope : scope;
  ts : string;
  nonce : string;
  sender_pk : string;
  signature : string;
}

(* --- crypto helpers ----------------------------------------------------- *)

let b64url_nopad s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let now_rfc3339_utc () =
  let t = Unix.gettimeofday () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let random_nonce_b64 () =
  Mirage_crypto_rng_unix.use_default ();
  let bytes = Mirage_crypto_rng.generate 16 in
  b64url_nopad bytes

let canonical_blob env =
  let note_str = match env.note with Some n -> n | None -> "" in
  let scope_str = match env.scope with `Public -> "public" | `Private -> "private" | `Both -> "both" in
  String.concat "|"
    [ string_of_int env.version; env.from_; env.to_; env.sticker_id; note_str; scope_str; env.ts; env.nonce ]

let sign_envelope ~identity env =
  let sender_pk = b64url_nopad identity.Relay_identity.public_key in
  let env = { env with sender_pk } in
  let blob = canonical_blob env in
  let sig_bytes = Relay_identity.sign identity blob in
  { env with signature = b64url_nopad sig_bytes }

let verify_envelope env =
  if env.signature = "" then Error "missing signature"
  else if env.sender_pk = "" then Error "missing sender public key"
  else
    match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet env.signature,
          Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet env.sender_pk with
    | Error _, _ -> Error "b64 decode failed for signature"
    | _, Error _ -> Error "b64 decode failed for sender_pk"
    | Ok sig_bytes, Ok pk_bytes ->
      if String.length pk_bytes <> 32 then Error "sender_pk must be 32 bytes"
      else if String.length sig_bytes <> 64 then Error "signature must be 64 bytes"
      else
        let blob = canonical_blob env in
        match Relay_identity.verify ~pk:pk_bytes ~msg:blob ~sig_:sig_bytes with
        | true -> Ok true
        | false -> Error "invalid signature"

(* --- storage ------------------------------------------------------------ *)

let envelope_to_json env =
  let scope_str = match env.scope with `Public -> "public" | `Private -> "private" | `Both -> "both" in
  let fields = [
    ("version", `Int env.version);
    ("from", `String env.from_);
    ("to", `String env.to_);
    ("sticker_id", `String env.sticker_id);
    ("scope", `String scope_str);
    ("ts", `String env.ts);
    ("nonce", `String env.nonce);
    ("sender_pk", `String env.sender_pk);
    ("signature", `String env.signature);
  ] in
  let fields = match env.note with Some n -> ("note", `String n) :: fields | None -> fields in
  `Assoc fields

let envelope_of_json json =
  let get_str fields k = List.assoc_opt k fields |> function Some (`String s) -> s | _ -> "" in
  let get_opt_str fields k = List.assoc_opt k fields |> function Some (`String s) -> Some s | _ -> None in
  match json with
  | `Assoc fields ->
    let scope = match get_str fields "scope" with "public" -> `Public | _ -> `Private in
    Ok {
      version = (match List.assoc_opt "version" fields with Some (`Int i) -> i | _ -> 1);
      from_ = get_str fields "from";
      to_ = get_str fields "to";
      sticker_id = get_str fields "sticker_id";
      note = get_opt_str fields "note";
      scope;
      ts = get_str fields "ts";
      nonce = get_str fields "nonce";
      sender_pk = get_str fields "sender_pk";
      signature = get_str fields "signature";
    }
  | _ -> Error "expected JSON object"

let atomic_write_file path content =
  let tmp = path ^ ".tmp" in
  try
    let oc = open_out tmp in
    output_string oc content;
    close_out oc;
    Unix.rename tmp path;
    Ok ()
  with e -> Error (Printexc.to_string e)

let store_envelope env =
  let dir, filename = match env.scope with
    | `Private -> received_dir ~alias:env.to_, Printf.sprintf "%s-%s.json" env.ts env.nonce
    | `Public -> public_dir (), Printf.sprintf "%s-%s-%s.json" env.from_ env.ts env.nonce
    | `Both -> received_dir ~alias:env.to_, Printf.sprintf "%s-%s.json" env.ts env.nonce
  in
  let () = C2c_utils.mkdir_p dir in
  let json = envelope_to_json env in
  let content = Yojson.Safe.to_string json ^ "\n" in
  atomic_write_file (dir // filename) content

let load_stickers ~alias ?(scope=`Both) () =
  let dirs = match scope with
    | `Both -> [ received_dir ~alias ]
    | `Public -> [ public_dir () ]
    | `Private -> [ received_dir ~alias ]
  in
  let glob dir =
    try
      if not (Sys.file_exists dir) then []
      else
        let d = Unix.opendir dir in
        let rec go acc =
          try
            match Unix.readdir d with
            | entry when entry <> "" && entry <> "." && entry <> ".." ->
              (try
                 let path = dir // entry in
                 let json = Yojson.Safe.from_file path in
                 match envelope_of_json json with
                 | Ok env -> go (env :: acc)
                 | Error _ -> go acc
               with _ -> go acc)
            | _ -> go acc
          with End_of_file -> acc
        in
        let results = go [] in
        Unix.closedir d;
        results
    with _ -> []
  in
  let stickers = List.concat (List.map glob dirs) in
  List.sort (fun a b -> String.compare b.ts a.ts) stickers

(* --- create and store --------------------------------------------------- *)

let create_and_store ~from_ ~to_ ~sticker_id ~note ~scope ~identity =
  match validate_sticker_id sticker_id with
  | Error e -> Error e
  | Ok () ->
    let ts = now_rfc3339_utc () in
    let nonce = random_nonce_b64 () in
    let sender_pk = b64url_nopad identity.Relay_identity.public_key in
    let env = { version = 1; from_; to_; sticker_id; note; scope; ts; nonce; sender_pk; signature = "" } in
    let env = sign_envelope ~identity env in
    match store_envelope env with
    | Ok () -> Ok env
    | Error e -> Error e

(* --- formatting --------------------------------------------------------- *)

let format_sticker env =
  let registry = load_registry () in
  let entry = List.find_opt (fun e -> e.id = env.sticker_id) registry in
  let emoji = match entry with Some e -> e.emoji | None -> "?" in
  let ts_str = env.ts in
  let note_str = match env.note with Some n -> " \"" ^ n ^ "\"" | None -> "" in
  Printf.sprintf "%s %s sent %s to %s at %s%s\n"
    emoji env.from_ env.sticker_id env.to_ ts_str note_str

(* --- CLI commands ------------------------------------------------------- *)

let json_flag =
  Cmdliner.Arg.(value & flag & info [ "json"; "j" ] ~doc:"Output machine-readable JSON.")

let scope_flag =
  let scope_conv =
    Cmdliner.Arg.enum [ "public", `Public; "private", `Private ]
  in
  Cmdliner.Arg.(value & opt (some scope_conv) None & info [ "scope" ]
    ~docv:"SCOPE" ~doc:"Sticker visibility: public or private (default: private)")

let resolve_current_alias () =
  match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
  | Some alias when alias <> "" -> Some alias
  | _ -> None

(* --- sticker list command --- *)

let sticker_list_cmd =
  let json = json_flag in
  let+ json = json in
  let registry = load_registry () in
  if json then
    let items = List.map (fun e ->
      `Assoc [
        ("id", `String e.id);
        ("emoji", `String e.emoji);
        ("display_name", `String e.display_name);
        ("description", `String e.description);
      ]) registry in
    Yojson.Safe.pretty_to_channel stdout (`List items);
    print_newline ()
  else
    List.iter (fun e ->
      Printf.printf "%s %s — %s\n" e.emoji e.display_name e.description
    ) registry

(* --- sticker send command --- *)

let sticker_send_cmd =
  let peer =
    Cmdliner.Arg.(required & pos 0 (some string) None & info []
      ~docv:"PEER" ~doc:"Recipient alias")
  in
  let sticker_id =
    Cmdliner.Arg.(required & pos 1 (some string) None & info []
      ~docv:"STICKER" ~doc:"Sticker id (run 'c2c sticker list' to see available)")
  in
  let note =
    let doc = "Optional note (max 280 chars)" in
    Cmdliner.Arg.(value & opt (some string) None & info [ "note" ] ~docv:"NOTE" ~doc)
  in
  let scope = scope_flag in
  let+ peer = peer
  and+ sticker_id = sticker_id
  and+ note = note
  and+ scope = scope in
  let scope = match scope with Some s -> s | None -> `Private in
  let from_alias = match resolve_current_alias () with
    | Some a -> a
    | None -> (Printf.eprintf "error: no alias set. Set C2C_MCP_AUTO_REGISTER_ALIAS or run 'c2c register' first.\n%!"; exit 1)
  in
  let identity =
    match per_alias_key_path ~alias:from_alias with
    | Some path when Sys.file_exists path ->
        Relay_identity.load_or_create_at ~path ~alias_hint:from_alias
    | _ ->
        Printf.eprintf
          "warning: no per-alias key at <broker>/keys/%s.ed25519; falling back to host identity\n%!"
          from_alias;
        (match Relay_identity.load () with
         | Ok id -> id
         | Error _ -> (Printf.eprintf "error: no identity found. Run 'c2c install' first.\n%!"; exit 1))
  in
  (match note with Some n when String.length n > 280 ->
    (Printf.eprintf "error: note exceeds 280 characters\n%!"; exit 1)
  | _ -> ());
  (match create_and_store ~from_:from_alias ~to_:peer ~sticker_id ~note ~scope ~identity with
   | Ok env ->
     let emoji = match List.assoc_opt env.sticker_id (List.map (fun e -> e.id, e) (load_registry ())) with
       | Some e -> e.emoji | None -> "?" in
     Printf.printf "Sent %s to %s\n" emoji peer
   | Error msg ->
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

(* --- sticker wall command --- *)

let sticker_wall_cmd =
  let alias_opt =
    let doc = "Alias to show stickers for (default: current session alias)" in
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias" ] ~docv:"ALIAS" ~doc)
  in
  let scope = scope_flag in
  let json = json_flag in
  let+ alias_opt = alias_opt
  and+ scope = scope
  and+ json = json in
  let scope = match scope with Some s -> s | None -> `Both in
  let alias = match alias_opt with Some a -> a | None ->
    (match resolve_current_alias () with
     | Some a -> a
     | None -> (Printf.eprintf "error: no alias set. Set C2C_MCP_AUTO_REGISTER_ALIAS or use --alias.\n%!"; exit 1))
  in
  let stickers = load_stickers ~alias ~scope () in
  if json then
    let items = List.map (fun env ->
      `Assoc [
        ("from", `String env.from_);
        ("to", `String env.to_);
        ("sticker_id", `String env.sticker_id);
        ("note", `String (Option.value env.note ~default:""));
        ("scope", `String (match env.scope with `Public -> "public" | `Private -> "private"));
        ("ts", `String env.ts);
      ]) stickers in
    Yojson.Safe.pretty_to_channel stdout (`List items);
    print_newline ()
  else
    if stickers = [] then Printf.printf "No stickers found for %s\n" alias
    else List.iter (fun env -> print_string (format_sticker env)) stickers

(* --- sticker verify command --- *)

let sticker_verify_cmd =
  let file =
    Cmdliner.Arg.(required & pos 0 (some string) None & info []
      ~docv:"FILE" ~doc:"Sticker JSON file to verify")
  in
  let+ file = file in
  (try
     let json = Yojson.Safe.from_file file in
     match envelope_of_json json with
     | Ok env ->
       (match verify_envelope env with
        | Ok true ->
          let emoji = match List.assoc_opt env.sticker_id (List.map (fun e -> e.id, e) (load_registry ())) with
            | Some e -> e.emoji | None -> "?" in
          Printf.printf "VALID: %s sent %s to %s at %s\n" env.from_ emoji env.to_ env.ts
        | Ok false ->
          Printf.printf "INVALID: signature verification returned false\n"
        | Error msg ->
          Printf.printf "INVALID: %s\n" msg)
     | Error msg ->
       Printf.printf "INVALID: %s\n" msg
   with e ->
     Printf.printf "INVALID: could not read file: %s\n" (Printexc.to_string e))

(* --- group --- *)

let sticker_group =
  Cmdliner.Cmd.group
    ~default:sticker_list_cmd
    (Cmdliner.Cmd.info "sticker" ~doc:"Send, view, and verify agent appreciation stickers")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List available sticker kinds.") sticker_list_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "send" ~doc:"Send a sticker to a peer.") sticker_send_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "wall" ~doc:"Show stickers received by an alias.") sticker_wall_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "verify" ~doc:"Verify a sticker's signature.") sticker_verify_cmd ]
