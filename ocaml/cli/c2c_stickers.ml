(* c2c_stickers.ml — Agent stickers: signed appreciation tokens *)

open Cmdliner.Term.Syntax
let ( // ) = Filename.concat

(* --- path helpers ------------------------------------------------------- *)

let sticker_dir_opt () : string option =
  match Git_helpers.git_common_dir_parent () with
  | Some parent -> Some (parent // ".c2c" // "stickers")
  | None -> None

let received_dir ~(alias:string) ~(sticker_dir:string) : string =
  sticker_dir // alias // "received"

let sent_dir ~(alias:string) ~(sticker_dir:string) : string =
  sticker_dir // alias // "sent"

let public_dir ~(sticker_dir:string) : string =
  sticker_dir // "public"

(* shared per-alias signing key helpers (c2c_signing_helpers.ml) *)
let xdg_state_home = C2c_utils.xdg_state_home
let per_alias_key_path = C2c_signing_helpers.per_alias_key_path

(* --- by-msg index for reactions ---------------------------------------- *)

(* Index path: .c2c/stickers/<reactor>/by-msg-out/<full-msg-id>.json
   Stores the sticker envelope path for each reaction this alias has made. *)
let by_msg_out_dir ~(alias:string) ~(sticker_dir:string) : string =
  sticker_dir // alias // "by-msg-out"

let by_msg_out_path ~(alias:string) ~(sticker_dir:string) ~(msg_id:string) : string =
  by_msg_out_dir ~alias ~sticker_dir // (msg_id ^ ".json")

(* [append_to_by_msg_index ~alias ~sticker_dir ~msg_id ~envelope_path] appends a reaction
   envelope reference to the index. The index is append-only so multiple
   reactions to the same message accumulate. *)
let append_to_by_msg_index ~(alias:string) ~(sticker_dir:string) ~msg_id ~envelope_path =
  let dir = by_msg_out_dir ~alias ~sticker_dir in
  let path = by_msg_out_path ~alias ~sticker_dir ~msg_id in
  let () = C2c_utils.mkdir_p dir in
  let line = envelope_path ^ "\n" in
  let oc = open_out_gen [Open_text; Open_append; Open_creat] 0o600 path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc line)

(* [load_by_msg_index ~alias ~sticker_dir ~msg_id] reads all envelope paths from the
   reaction index for a given message. Returns [] if no reactions exist. *)
let load_by_msg_index ~(alias:string) ~(sticker_dir:string) ~(msg_id:string) =
  let path = by_msg_out_path ~alias ~sticker_dir ~msg_id in
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in ic)
      (fun () ->
        let rec loop acc =
          match input_line ic with
          | exception End_of_file -> List.rev acc
          | line ->
              let line = String.trim line in
              if line = "" then loop acc
              else loop (line :: acc)
        in
        loop [])



(* --- registry ----------------------------------------------------------- *)

type registry_entry = {
  id : string;
  emoji : string;
  display_name : string;
  description : string;
}

let load_registry () =
  let reg_file = match sticker_dir_opt () with
    | None -> ".c2c/stickers/registry.json"  (* non-git: try path, let try/with return [] on miss *)
    | Some d -> d // "registry.json"
  in
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
  target_msg_id : string option;
    (* v2+: id of the message being reacted to. None for peer-addressed
       (non-reaction) stickers. v1 envelopes always have this as None and
       it is NOT included in their canonical blob. *)
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
  let base =
    [ string_of_int env.version; env.from_; env.to_; env.sticker_id; note_str; scope_str; env.ts; env.nonce ]
  in
  (* Version-switched: v1 envelopes sign 8 fields exactly as before; v2+
     envelopes append target_msg_id (empty string when None). v1 envelopes
     on disk verify byte-for-byte against the legacy blob. *)
  let fields =
    if env.version >= 2 then
      let tgt = match env.target_msg_id with Some s -> s | None -> "" in
      base @ [ tgt ]
    else base
  in
  String.concat "|" fields

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
  let fields = match env.target_msg_id with
    | Some t -> ("target_msg_id", `String t) :: fields
    | None -> fields
  in
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
      target_msg_id = get_opt_str fields "target_msg_id";
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

let store_envelope env : (unit, string) result =
  match sticker_dir_opt () with
  | None -> Error "not in a git repository"
  | Some sticker_dir ->
      let dir, filename = match env.scope with
        | `Private -> received_dir ~alias:env.to_ ~sticker_dir, Printf.sprintf "%s-%s.json" env.ts env.nonce
        | `Public -> public_dir ~sticker_dir, Printf.sprintf "%s-%s-%s.json" env.from_ env.ts env.nonce
        | `Both -> received_dir ~alias:env.to_ ~sticker_dir, Printf.sprintf "%s-%s.json" env.ts env.nonce
      in
      let () = C2c_utils.mkdir_p dir in
      let json = envelope_to_json env in
      let content = Yojson.Safe.to_string json ^ "\n" in
      atomic_write_file (dir // filename) content

let load_stickers ~(alias:string) ?(scope=`Both) () =
  match sticker_dir_opt () with
  | None -> []
  | Some sticker_dir ->
      let dirs = match scope with
        | `Both -> [ received_dir ~alias ~sticker_dir ]
        | `Public -> [ public_dir ~sticker_dir ]
        | `Private -> [ received_dir ~alias ~sticker_dir ]
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

let create_and_store ?target_msg_id ~from_ ~to_ ~sticker_id ~note ~scope ~identity () =
  match validate_sticker_id sticker_id with
  | Error e -> Error e
  | Ok () ->
    let ts = now_rfc3339_utc () in
    let nonce = random_nonce_b64 () in
    let sender_pk = b64url_nopad identity.Relay_identity.public_key in
    (* Version bumps to 2 only when target_msg_id is explicitly set. Plain
       peer-addressed stickers stay on v1 so their canonical blob is
       unchanged from the existing on-disk format. *)
    let version = match target_msg_id with Some _ -> 2 | None -> 1 in
    let env = {
      version; from_; to_; sticker_id; note; target_msg_id;
      scope; ts; nonce; sender_pk; signature = "";
    } in
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

(* --- reaction XML builder ----------------------------------------------- *)

(* [build_reaction_xml ~from_alias ~target_msg_id ~sticker_id ~emoji ~note]
   builds the c2c event body for a reaction DM to be sent to the original
   message sender. The target recipient is derived from the archive entry
   (the original sender), not passed explicitly. *)
let build_reaction_xml ~from_alias ~target_msg_id ~sticker_id ~emoji ~note =
  let note_attr = match note with
    | Some n -> Printf.sprintf " note=\"%s\"" (C2c_mcp.xml_escape n)
    | None -> ""
  in
  Printf.sprintf "<c2c event=\"reaction\" from=\"%s\" target_msg_id=\"%s\" sticker_id=\"%s\"%s/>"
    (C2c_mcp.xml_escape from_alias)
    (C2c_mcp.xml_escape target_msg_id)
    (C2c_mcp.xml_escape sticker_id)
    note_attr

(* [parse_reaction_content content] parses a reaction DM body and returns
    Some (reactor_alias, sticker_id, target_msg_id, note) if the content is a
    <c2c event="reaction" .../> tag. *)
let parse_reaction_content (content : string) : (string * string * string * string option) option =
  if String.length content < 7 ||
     String.sub content 0 5 <> "<c2c " ||
     String.sub content (String.length content - 2) 2 <> "/>"
  then None
  else
    (* Collect all key="value" pairs by scanning for '=' then finding the
       surrounding '"' characters. Simple and robust — no regex needed. *)
    let rec scan pos attrs =
      if pos >= String.length content then List.rev attrs
      else
        match String.index_from content pos '=' with
        | exception Not_found -> List.rev attrs
        | eq_pos ->
            (* Scan backwards from eq_pos-1 to find valid identifier start *)
            let rec key_start i =
              if i < 0 then 0
              else match content.[i] with
                   | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' -> key_start (i - 1)
                   | _ -> i + 1
            in
            let ks = key_start (eq_pos - 1) in
            let key = String.sub content ks (eq_pos - ks) in
            (* Next char after '=' must be '"' *)
            let vp = eq_pos + 1 in
            if vp >= String.length content || content.[vp] <> '"' then
              scan (eq_pos + 1) attrs
            else
              (* Find closing '"' *)
              let rec find_close c =
                if c >= String.length content then None
                else if content.[c] = '"' then
                  (* Heuristic: if this quote is followed by '/' or ' ' then '/', 
                     it's likely the real attribute closer. If followed by ';' it's 
                     likely inside an entity like &quot; and should be skipped. *)
                  if c + 1 < String.length content then
                    match content.[c + 1] with
                    | '/' | ' ' -> Some c
                    | ';' -> find_close (c + 1)
                    | _ -> Some c
                  else Some c
                else find_close (c + 1)
              in
              match find_close (vp + 1) with
              | None -> scan (eq_pos + 1) attrs
              | Some close ->
                  let value = String.sub content (vp + 1) (close - vp - 1) in
                  scan (close + 1) ((key, value) :: attrs)
    in
    let attrs = scan 0 [] in
    let get key = List.assoc_opt key attrs in
    match get "event" with
    | Some "reaction" ->
        (match get "from", get "sticker_id", get "target_msg_id" with
         | Some reactor_alias, Some sticker_id, Some target_msg_id ->
             Some (reactor_alias, sticker_id, target_msg_id, get "note")
         | _ -> None)
    | _ -> None

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
        Printf.eprintf "error: no per-alias key at <broker>/keys/%s.ed25519. Re-run 'c2c register' to generate.\n%!"
          from_alias;
        exit 1
  in
  (match note with Some n when String.length n > 280 ->
    (Printf.eprintf "error: note exceeds 280 characters\n%!"; exit 1)
  | _ -> ());
  (match create_and_store ~from_:from_alias ~to_:peer ~sticker_id ~note ~scope ~identity () with
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
        ("scope", `String (match env.scope with `Public -> "public" | `Private -> "private" | `Both -> "both"));
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

(* --- sticker react command ---------------------------------------------- *)

let sticker_react_cmd =
  let msg_id_or_prefix =
    Cmdliner.Arg.(required & pos 0 (some string) None & info []
      ~docv:"MSG-ID"
      ~doc:"Message ID or 8-char prefix to react to. Use 'c2c history' to find message IDs.")
  in
  let sticker_id =
    Cmdliner.Arg.(required & pos 1 (some string) None & info []
      ~docv:"STICKER" ~doc:"Sticker id to react with (run 'c2c sticker list').")
  in
  let note =
    let doc = "Optional note (max 280 chars)" in
    Cmdliner.Arg.(value & opt (some string) None & info [ "note" ] ~docv:"NOTE" ~doc)
  in
  let json = json_flag in
  let+ msg_id_or_prefix = msg_id_or_prefix
  and+ sticker_id = sticker_id
  and+ note = note
  and+ json = json in
  (match note with Some n when String.length n > 280 ->
    (Printf.eprintf "error: note exceeds 280 characters\n%!"; exit 1)
  | _ -> ());
  let from_alias = match resolve_current_alias () with
    | Some a -> a
    | None -> (Printf.eprintf "error: no alias set. Set C2C_MCP_AUTO_REGISTER_ALIAS or run 'c2c register' first.\n%!"; exit 1)
  in
  let identity =
    match per_alias_key_path ~alias:from_alias with
    | Some path when Sys.file_exists path ->
        Relay_identity.load_or_create_at ~path ~alias_hint:from_alias
    | _ ->
        Printf.eprintf "error: no per-alias key at <broker>/keys/%s.ed25519. Re-run 'c2c register' to generate.\n%!"
          from_alias;
        exit 1
  in
  (match validate_sticker_id sticker_id with
   | Error e -> Printf.eprintf "error: %s\n%!" e; exit 1
   | Ok () -> ());
  let broker_root = C2c_utils.resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  match C2c_mcp.Broker.find_message_by_id broker ~alias:from_alias ~id_prefix:msg_id_or_prefix with
  | Error msg ->
      Printf.eprintf "error: %s\n%!" msg;
      Printf.eprintf "(Hint: poll your inbox with 'c2c poll-inbox' first to receive messages.)\n%!";
      exit 1
  | Ok entry ->
      let original_sender = entry.C2c_mcp.Broker.ae_from_alias in
      let full_msg_id = match entry.C2c_mcp.Broker.ae_message_id with
        | Some id -> id
        | None -> msg_id_or_prefix
      in
      (* Build the reaction envelope with target_msg_id *)
      match create_and_store ~target_msg_id:full_msg_id
        ~from_:from_alias ~to_:original_sender ~sticker_id ~note
        ~scope:`Private ~identity () with
      | Error msg ->
          Printf.eprintf "error: %s\n%!" msg;
          exit 1
      | Ok env ->
          (* Append to by-msg index for this reactor *)
          let sticker_dir = match sticker_dir_opt () with
            | Some d -> d
            | None -> (Printf.eprintf "error: not in a git repository\n%!"; exit 1)
          in
          let envelope_path = received_dir ~alias:original_sender ~sticker_dir // Printf.sprintf "%s-%s.json" env.ts env.nonce in
          (try append_to_by_msg_index ~alias:from_alias ~sticker_dir ~msg_id:full_msg_id ~envelope_path with _ -> ());
          (* Enqueue DM to original sender with reaction XML *)
          let emoji = match List.assoc_opt env.sticker_id (List.map (fun e -> e.id, e) (load_registry ())) with
            | Some e -> e.emoji | None -> "?" in
          let reaction_xml = build_reaction_xml ~from_alias ~target_msg_id:full_msg_id
            ~sticker_id:env.sticker_id ~emoji ~note in
          (try C2c_mcp.Broker.enqueue_message broker ~from_alias ~to_alias:original_sender
            ~content:reaction_xml ()
           with Invalid_argument msg ->
             Printf.eprintf "error: reaction enqueued locally but DM to %s failed: %s\n%!" original_sender msg);
          if json then (
            Yojson.Safe.pretty_to_channel stdout (`Assoc [
              ("ok", `Bool true);
              ("envelope_path", `String envelope_path);
              ("to", `String original_sender);
              ("target_msg_id", `String full_msg_id);
              ("dm_enqueued", `Bool true);
            ]);
            print_newline ()
          ) else
            Printf.printf "%s %s reacted to [%s] from %s\n" emoji from_alias
              (String.sub full_msg_id 0 (min 8 (String.length full_msg_id))) original_sender

(* --- sticker reactions command ------------------------------------------- *)

let sticker_reactions_cmd =
  let msg_id_or_prefix =
    Cmdliner.Arg.(required & pos 0 (some string) None & info []
      ~docv:"MSG-ID"
      ~doc:"Message ID or 8-char prefix to show reactions for.")
  in
  let json = json_flag in
  let+ msg_id_or_prefix = msg_id_or_prefix
  and+ json = json in
  let from_alias = match resolve_current_alias () with
    | Some a -> a
    | None -> (Printf.eprintf "error: no alias set. Set C2C_MCP_AUTO_REGISTER_ALIAS or run 'c2c register' first.\n%!"; exit 1)
  in
  let broker_root = C2c_utils.resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  (* Scan all inbox archive entries for this user's sessions.
     Reactions arrive as incoming DMs, so we look in the user's own inbox archive.
     For each entry, parse_reaction_content extracts the target_msg_id from the
     reaction body and filters by prefix match. *)
  let regs = C2c_mcp.Broker.list_registrations broker in
  let my_session_ids = List.filter_map (fun (r : C2c_mcp.registration) ->
    if r.C2c_mcp.alias = from_alias then Some r.C2c_mcp.session_id else None) regs in
  let all_reactions =
    List.fold_left (fun acc session_id ->
      let entries = C2c_mcp.Broker.read_archive broker ~session_id ~limit:500 in
      let matching = List.filter_map (fun (e : C2c_mcp.Broker.archive_entry) ->
        match parse_reaction_content e.C2c_mcp.Broker.ae_content with
        | Some (reactor_alias, sticker_id, target_msg_id, note) ->
            (* Only include if target_msg_id matches the user-supplied prefix *)
            if String.length target_msg_id >= String.length msg_id_or_prefix &&
               String.sub target_msg_id 0 (String.length msg_id_or_prefix) = msg_id_or_prefix
            then Some (reactor_alias, sticker_id, note)
            else None
        | None -> None
      ) entries in
      acc @ matching
    ) [] my_session_ids
  in
  (* Dedupe by reactor_alias *)
  let deduped =
    let seen = Hashtbl.create 16 in
    List.filter (fun (ra, _, _) ->
      if Hashtbl.mem seen ra then false
      else (Hashtbl.add seen ra true; true))
      all_reactions
  in
  if deduped = [] then (
    if json then (
      Yojson.Safe.pretty_to_channel stdout (`List []);
      print_newline ()
    ) else
      Printf.printf "No reactions to [%s]\n"
        (String.sub msg_id_or_prefix 0 (min 8 (String.length msg_id_or_prefix)))
  ) else
    if json then (
      let items = List.map (fun (reactor_alias, sticker_id, note) ->
        `Assoc [
          ("from", `String reactor_alias);
          ("sticker_id", `String sticker_id);
          ("note", `String (Option.value note ~default:""));
        ]
      ) deduped in
      Yojson.Safe.pretty_to_channel stdout (`List items);
      print_newline ()
    ) else
      List.iter (fun (reactor_alias, sticker_id, note) ->
        let emoji = match List.assoc_opt sticker_id (List.map (fun e -> e.id, e) (load_registry ())) with
          | Some e -> e.emoji | None -> "?" in
        Printf.printf "%s %s reacted with %s\n"
          emoji reactor_alias sticker_id
      ) deduped

(* --- group --- *)

let sticker_group =
  Cmdliner.Cmd.group
    ~default:sticker_list_cmd
    (Cmdliner.Cmd.info "sticker" ~doc:"Send, view, and verify agent appreciation stickers")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List available sticker kinds.") sticker_list_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "send" ~doc:"Send a sticker to a peer.") sticker_send_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "wall" ~doc:"Show stickers received by an alias.") sticker_wall_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "verify" ~doc:"Verify a sticker's signature.") sticker_verify_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "react" ~doc:"React to a message with a sticker.") sticker_react_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "reactions" ~doc:"Show reactions to a message.") sticker_reactions_cmd ]
