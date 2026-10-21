(* Native T3 client — see c2c_t3_client.mli for the contract and invariants. *)

open Lwt.Infix

type error =
  | Discovery of string
  | Ambiguous of string list
  | Unsafe_state of string
  | Runtime_changed of string
  | Credential of string
  | Timeout of string
  | Oversize of string
  | Protocol of string
  | Rpc_error of int
  | Http_status of { status : int; during : string }
  | Auth_denied of { status : int }
  | Redirect_refused of int
  | Tool_rejected of { tool : string; code : string }
  | Unsupported of string

let error_to_string = function
  | Discovery m -> "T3 discovery failed: " ^ m
  | Ambiguous l -> "ambiguous T3 runtime records: " ^ String.concat ", " l
  | Unsafe_state m -> "unsafe T3 state refused: " ^ m
  | Runtime_changed m -> "T3 runtime changed: " ^ m
  | Credential m -> "T3 credential: " ^ m
  | Timeout d -> "T3 request timed out during " ^ d
  | Oversize d -> "T3 response exceeds the byte bound (" ^ d ^ ")"
  | Protocol m -> "T3 protocol error: " ^ m
  | Rpc_error c -> Printf.sprintf "T3 MCP RPC error %d" c
  | Http_status { status; during } ->
      Printf.sprintf "T3 HTTP %d during %s" status during
  | Auth_denied { status } ->
      Printf.sprintf
        "T3 denied the credential (HTTP %d): expired or revoked; re-pair with \
         `c2c t3 pair`"
        status
  | Redirect_refused s ->
      Printf.sprintf "T3 endpoint answered with redirect %d; refused" s
  | Tool_rejected { tool; code } ->
      Printf.sprintf "T3 tool %s rejected (%s)" tool code
  | Unsupported m -> "unsupported T3 server: " ^ m

let is_auth_error = function Auth_denied _ -> true | _ -> false

let protocol_version = "2025-06-18"
let required_scopes = [ "orchestration:operate"; "orchestration:read" ]

let required_tools =
  [ "orchestrator_capabilities"; "t3_project_list"; "t3_thread_list";
    "t3_thread_read"; "t3_thread_send"; "t3_queue_list" ]

let supported_tools = required_tools @ [ "t3_environment_read" ]

type limits = {
  max_response_bytes : int;
  request_timeout_s : float;
  max_pages : int;
  max_items : int;
}

let default_limits =
  { max_response_bytes = 8 * 1024 * 1024; request_timeout_s = 30.;
    max_pages = 100; max_items = 10_000 }

let ( let* ) = Result.bind

(* ---------- strict JSON / SSE ---------- *)

let max_json_depth = 64

let validate_tree (j : Yojson.Safe.t) : (unit, error) result =
  let rec go depth (j : Yojson.Safe.t) =
    if depth > max_json_depth then Error (Protocol "JSON nesting too deep")
    else
    match j with
    | `Null | `Bool _ | `Int _ | `String _ -> Ok ()
    | `Float f ->
        if Float.is_finite f then Ok ()
        else Error (Protocol "non-finite JSON number")
    | `Intlit _ -> Error (Protocol "out-of-range JSON integer")
    | `List l -> all (depth + 1) l
    | `Assoc kv ->
        let keys = List.map fst kv in
        if List.length (List.sort_uniq String.compare keys) <> List.length keys
        then Error (Protocol "duplicate JSON object key")
        else all (depth + 1) (List.map snd kv)
  and all depth = function
    | [] -> Ok ()
    | x :: rest ->
        let* () = go depth x in
        all depth rest
  in
  go 0 j

let strict_json_of_string ~max_bytes s =
  if String.length s > max_bytes then Error (Oversize "json")
  else
    match Yojson.Safe.from_string s with
    | exception _ -> Error (Protocol "malformed JSON")
    | j ->
        let* () = validate_tree j in
        Ok j

let split_events body =
  (* Lines end at LF (CR stripped); a blank line ends an event. The text after
     the last LF is an incomplete line, so it can only belong to the tail. *)
  let parts = String.split_on_char '\n' body in
  let rec split_last acc = function
    | [] -> (List.rev acc, "")
    | [ last ] -> (List.rev acc, last)
    | x :: rest -> split_last (x :: acc) rest
  in
  let lines, remainder = split_last [] parts in
  let strip l =
    let n = String.length l in
    if n > 0 && l.[n - 1] = '\r' then String.sub l 0 (n - 1) else l
  in
  let events, cur =
    List.fold_left
      (fun (events, cur) l ->
        if strip l = "" then
          if cur = [] then (events, []) else (List.rev cur :: events, [])
        else (events, strip l :: cur))
      ([], []) lines
  in
  let tail = List.rev cur @ if remainder = "" then [] else [ strip remainder ] in
  (List.rev events, tail)

let sse_messages ~max_bytes body =
  let events, tail = split_events body in
  let is_data l = String.length l >= 5 && String.sub l 0 5 = "data:" in
  if List.exists is_data tail then Error (Protocol "unterminated SSE event")
  else
    let data_of lines =
      lines |> List.filter is_data
      |> List.map (fun l ->
             let v = String.sub l 5 (String.length l - 5) in
             if v <> "" && v.[0] = ' ' then String.sub v 1 (String.length v - 1)
             else v)
    in
    let rec go acc = function
      | [] -> Ok (List.rev acc)
      | ev :: rest -> (
          match data_of ev with
          | [] -> go acc rest
          | data ->
              let* j = strict_json_of_string ~max_bytes (String.concat "\n" data) in
              go (j :: acc) rest)
    in
    go [] events

let mime_of content_type =
  match String.index_opt content_type ';' with
  | Some i -> String.lowercase_ascii (String.trim (String.sub content_type 0 i))
  | None -> String.lowercase_ascii (String.trim content_type)

let member k = function `Assoc kv -> List.assoc_opt k kv | _ -> None

let parse_rpc ~max_bytes ~content_type ~id body =
  let* messages =
    match mime_of content_type with
    | "text/event-stream" -> sse_messages ~max_bytes body
    | "application/json" ->
        let* j = strict_json_of_string ~max_bytes body in
        Ok [ j ]
    | _ -> Error (Protocol "unsupported MCP response content type")
  in
  let matches = List.filter (fun m -> member "id" m = Some (`Int id)) messages in
  match matches with
  | [ m ] -> (
      if member "jsonrpc" m <> Some (`String "2.0") then
        Error (Protocol "response is not JSON-RPC 2.0")
      else
        match (member "result" m, member "error" m) with
        | Some _, Some _ -> Error (Protocol "response has both result and error")
        | None, None -> Error (Protocol "response has no result")
        | Some r, None -> Ok r
        | None, Some e -> (
            match member "code" e with
            | Some (`Int c) -> Error (Rpc_error c)
            | _ -> Error (Protocol "invalid JSON-RPC error envelope")))
  | _ -> Error (Protocol "response must contain exactly one matching JSON-RPC id")

(* ---------- RNG / PKCE ---------- *)

let rng_ready = ref false

let random_bytes n =
  if not !rng_ready then (
    Mirage_crypto_rng_unix.use_default ();
    rng_ready := true);
  Mirage_crypto_rng.generate n

let b64url s = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s
let hex_of s =
  String.concat "" (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))

let pkce_verifier () = b64url (random_bytes 32)

let pkce_challenge verifier =
  b64url (Digestif.SHA256.(to_raw_string (digest_string verifier)))

(* ---------- filesystem helpers ---------- *)

let read_file_bounded path max =
  try
    let ic = open_in_bin path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        (* Do not use [in_channel_length] here.  Procfs files report a zero
           length even though they produce their contents when read.  Read
           incrementally and consume at most one byte beyond the advertised
           bound so regular files and procfs have the same contract. *)
        let chunk_size = 8192 in
        let buf = Bytes.create (min chunk_size (max + 1)) in
        let out = Buffer.create (min max chunk_size) in
        let rec read total =
          let remaining = max - total in
          let want = min (Bytes.length buf) (remaining + 1) in
          let n = if want = 0 then 0 else input ic buf 0 want in
          if n = 0 then Some (Buffer.contents out)
          else if n > remaining then None
          else (
            Buffer.add_subbytes out buf 0 n;
            read (total + n))
        in
        read 0)
  with _ -> None

let lstat_opt p = try Some (Unix.lstat p) with Unix.Unix_error _ -> None

let split_lines s = String.split_on_char '\n' s

let is_exclusive_user_group ~group_row ~passwd_rows ~username ~uid ~gid =
  match String.split_on_char ':' (String.trim group_row) with
  | [ name; _; g; members ] ->
      name = username && int_of_string_opt g = Some gid
      && List.for_all (fun m -> m = "" || m = username)
           (String.split_on_char ',' members)
      &&
      let accounts =
        split_lines (String.trim passwd_rows)
        |> List.filter_map (fun r ->
               match String.split_on_char ':' r with
               | n :: _ :: u :: g :: _ -> (
                   match (int_of_string_opt u, int_of_string_opt g) with
                   | Some u, Some g -> Some (n, u, g)
                   | _ -> None)
               | _ -> None)
      in
      List.exists (fun (n, u, _) -> n = username && u = uid) accounts
      && List.for_all (fun (_, u, g) -> g <> gid || u = uid) accounts
  | _ -> false

type fs_env = {
  uid : int;
  gid : int;
  group_file : string;
  passwd_file : string;
}

(* Same-user, not world-writable; group-writable only for an exclusive
   user-private primary group (T3 writes 0664/0775 on the build hosts). *)
let safe_permissions env (st : Unix.stats) =
  if st.Unix.st_perm land 0o002 <> 0 then false
  else if st.Unix.st_perm land 0o020 = 0 then true
  else if st.Unix.st_gid <> env.gid then false
  else
    match
      ( (try Some (Unix.getpwuid env.uid).Unix.pw_name with _ -> None),
        read_file_bounded env.group_file 1_048_576,
        read_file_bounded env.passwd_file 1_048_576 )
    with
    | Some username, Some groups, Some passwd ->
        List.exists
          (fun row ->
            match String.split_on_char ':' row with
            | _ :: _ :: g :: _ when int_of_string_opt g = Some env.gid ->
                is_exclusive_user_group ~group_row:row ~passwd_rows:passwd
                  ~username ~uid:env.uid ~gid:env.gid
            | _ -> false)
          (split_lines groups)
    | _ -> false

let mkdir_p_private dir =
  let rec go d =
    if d <> "/" && d <> "." && not (Sys.file_exists d) then (
      go (Filename.dirname d);
      try Unix.mkdir d 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  go dir

let ensure_private_dir dir =
  (try mkdir_p_private dir with Unix.Unix_error (e, _, _) ->
     ignore e);
  match lstat_opt dir with
  | Some st
    when st.Unix.st_kind = Unix.S_DIR && st.Unix.st_uid = Unix.getuid ()
         && st.Unix.st_perm land 0o077 = 0 ->
      Ok ()
  | _ -> Error (Unsafe_state "T3 config directory must be a real directory owned by this user, mode 0700")

let fsync_dir dir =
  try
    let fd = Unix.openfile dir [ Unix.O_RDONLY ] 0 in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
        try Unix.fsync fd with Unix.Unix_error _ -> ())
  with Unix.Unix_error _ -> ()

let write_private ~replace path content =
  let dir = Filename.dirname path in
  let* () = ensure_private_dir dir in
  let tmp = Printf.sprintf "%s.%s.tmp" path (hex_of (random_bytes 8)) in
  match
    Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
  with
  | exception Unix.Unix_error _ -> Error (Credential "cannot create temporary credential file")
  | fd ->
      let cleanup () = try Unix.unlink tmp with Unix.Unix_error _ -> () in
      let r =
        try
          let b = Bytes.of_string content in
          let n = Unix.write fd b 0 (Bytes.length b) in
          if n <> Bytes.length b then failwith "short write";
          Unix.fsync fd;
          Unix.close fd;
          if replace then Unix.rename tmp path else Unix.link tmp path;
          Ok ()
        with
        | Unix.Unix_error (Unix.EEXIST, _, _) ->
            (try Unix.close fd with _ -> ());
            Error (Credential "credential already exists; re-pair explicitly with replace")
        | _ ->
            (try Unix.close fd with _ -> ());
            Error (Credential "cannot publish credential file")
      in
      cleanup ();
      if r = Ok () then fsync_dir dir;
      r

let read_private path max =
  match lstat_opt path with
  | None -> Error (Credential "no credential file; run `c2c t3 pair`")
  | Some st ->
      if st.Unix.st_kind <> Unix.S_REG || st.Unix.st_uid <> Unix.getuid ()
         || st.Unix.st_perm land 0o077 <> 0 || st.Unix.st_size > max
      then Error (Unsafe_state "credential file must be a regular file owned by this user, mode 0600")
      else
        match read_file_bounded path max with
        | Some s -> Ok s
        | None -> Error (Credential "cannot read credential file")

(* ---------- runtime discovery ---------- *)

type proof = {
  pid : int;
  start_ticks : int;
  boot_id : string;
  listeners : string list;
  exe_dev : int;
  exe_ino : int;
}

type runtime = {
  origin : string;
  port : int;
  pid : int;
  started_at : string;
  server_version : string option;
  record_path : string;
  t3_home : string;
  proof : proof;
}

let getenv_default = Sys.getenv_opt
let nonempty = function Some "" | None -> None | Some s -> Some s

let resolve_home ?(getenv = getenv_default) () =
  match nonempty (getenv "T3CODE_HOME") with
  | Some h ->
      if Filename.is_relative h then
        Error (Discovery "T3CODE_HOME must be an absolute path")
      else Ok h
  | None -> (
      match nonempty (getenv "HOME") with
      | Some h -> Ok (Filename.concat h ".t3")
      | None -> Error (Discovery "neither T3CODE_HOME nor HOME is set"))

let record_candidates home =
  [ Filename.concat (Filename.concat home "userdata") "server-runtime.json";
    Filename.concat (Filename.concat home "dev") "server-runtime.json" ]

let str_field k j = match member k j with Some (`String s) -> Some s | _ -> None
let int_field k j = match member k j with Some (`Int i) -> Some i | _ -> None

let parse_origin origin port =
  let u = Uri.of_string origin in
  let host_ok =
    match Uri.host u with Some ("127.0.0.1" | "::1") -> true | _ -> false
  in
  if Uri.scheme u = Some "http" && host_ok && Uri.userinfo u = None
     && (Uri.path u = "" || Uri.path u = "/") && Uri.query u = []
     && Uri.fragment u = None && Uri.port u = Some port
  then
    let ipv6 = Uri.host u = Some "::1" in
    Ok (Printf.sprintf "http://%s:%d" (if ipv6 then "[::1]" else "127.0.0.1") port, ipv6)
  else Error (Unsafe_state "runtime origin must be an explicit loopback http endpoint matching the recorded port")

let proc_boot_time proc_root =
  match read_file_bounded (Filename.concat proc_root "stat") 1_048_576 with
  | None -> None
  | Some s ->
      split_lines s
      |> List.find_map (fun l ->
             match String.split_on_char ' ' l with
             | [ "btime"; v ] -> int_of_string_opt v
             | _ -> None)

let proc_proof ~proc_root ~uid ~clk_tck ~pid ~port ~ipv6 =
  let p = Filename.concat proc_root (string_of_int pid) in
  let ( / ) = Filename.concat in
  match Unix.stat p with
  | exception Unix.Unix_error _ ->
      Error (Discovery (Printf.sprintf "recorded T3 PID %d is not running (stale runtime record); start T3" pid))
  | st when st.Unix.st_uid <> uid ->
      Error (Unsafe_state "T3 runtime PID belongs to another user")
  | _ -> (
      let tgid =
        match read_file_bounded (p / "status") 65536 with
        | None -> None
        | Some s ->
            split_lines s
            |> List.find_map (fun l ->
                   match String.split_on_char ':' l with
                   | [ "Tgid"; v ] -> int_of_string_opt (String.trim v)
                   | _ -> None)
      in
      if tgid <> Some pid then
        Error (Runtime_changed "recorded PID is not a thread-group leader (recycled PID)")
      else
        match
          ( read_file_bounded (p / "stat") 65536,
            proc_boot_time proc_root,
            read_file_bounded (proc_root / "sys" / "kernel" / "random" / "boot_id") 256 )
        with
        | Some stat, Some btime, Some boot_id -> (
            match String.rindex_opt stat ')' with
            | None -> Error (Protocol "unparseable /proc stat")
            | Some i -> (
                let rest = String.sub stat (i + 2) (String.length stat - i - 2) in
                match int_of_string_opt (List.nth_opt (String.split_on_char ' ' rest) 19 |> Option.value ~default:"") with
                | None -> Error (Protocol "unparseable /proc start time")
                | Some start_ticks -> (
                    let inodes =
                      try
                        Sys.readdir (p / "fd") |> Array.to_list
                        |> List.filter_map (fun fd ->
                               match Unix.readlink (p / "fd" / fd) with
                               | exception Unix.Unix_error _ -> None
                               | l ->
                                   let pre = "socket:[" in
                                   let pl = String.length pre in
                                   if String.length l > pl + 1
                                      && String.sub l 0 pl = pre
                                      && l.[String.length l - 1] = ']'
                                   then Some (String.sub l pl (String.length l - pl - 1))
                                   else None)
                      with Sys_error _ -> []
                    in
                    let table = if ipv6 then "tcp6" else "tcp" in
                    let allowed =
                      if ipv6 then [ "00000000000000000000000000000000"; "00000000000000000000000001000000" ]
                      else [ "00000000"; "0100007F" ]
                    in
                    let rows =
                      match read_file_bounded (p / "net" / table) 8_388_608 with
                      | None -> []
                      | Some s -> (match split_lines s with _ :: r -> r | [] -> [])
                    in
                    let listeners =
                      rows
                      |> List.filter_map (fun row ->
                             let cols =
                               String.split_on_char ' ' row |> List.filter (( <> ) "")
                             in
                             match cols with
                             | _ :: local :: _ :: state :: _ :: _ :: _ :: _ :: _ :: inode :: _ -> (
                                 match String.split_on_char ':' local with
                                 | [ addr; hexport ]
                                   when state = "0A"
                                        && int_of_string_opt ("0x" ^ hexport) = Some port
                                        && List.mem addr allowed
                                        && List.mem inode inodes -> Some inode
                                 | _ -> None)
                             | _ -> None)
                      |> List.sort_uniq String.compare
                    in
                    if listeners = [] then
                      Error (Runtime_changed "runtime PID does not own the loopback listening socket")
                    else
                      match Unix.stat (p / "exe") with
                      | exception Unix.Unix_error _ ->
                          Error (Unsafe_state "cannot inspect the T3 executable of the runtime PID")
                      | exe ->
                          let started =
                            float_of_int btime +. (float_of_int start_ticks /. float_of_int clk_tck)
                          in
                          Ok
                            ( { pid; start_ticks; boot_id = String.trim boot_id;
                                listeners; exe_dev = exe.Unix.st_dev;
                                exe_ino = exe.Unix.st_ino },
                              started ))))
        | _ -> Error (Unsafe_state "cannot read /proc state for the runtime PID"))

let started_at_epoch s =
  match Ptime.of_rfc3339 s with
  | Ok (t, _, _) -> Some (Ptime.to_float_s t)
  | Error _ -> None

let validate_record ~proc_root ~uid ~now ~clk_tck ~fs_env ~home ~real_home path =
  let reject m = Error m in
  match lstat_opt path with
  | None -> reject (Discovery (path ^ ": not present"))
  | Some st ->
      let dirs_ok =
        List.for_all
          (fun d ->
            match lstat_opt d with
            | Some s -> s.Unix.st_kind = Unix.S_DIR && s.Unix.st_uid = uid && safe_permissions fs_env s
            | None -> false)
          [ home; Filename.dirname path ]
      in
      if st.Unix.st_kind <> Unix.S_REG || st.Unix.st_uid <> uid
         || not (safe_permissions fs_env st) || st.Unix.st_size > 65536
      then reject (Unsafe_state (path ^ ": runtime record must be a bounded same-user file not writable by other accounts"))
      else if not dirs_ok then
        reject (Unsafe_state "T3 runtime directories must be owned and writable only by this account")
      else
        match read_file_bounded path 65536 with
        | None -> reject (Discovery (path ^ ": unreadable"))
        | Some text -> (
            match strict_json_of_string ~max_bytes:65536 text with
            | Error e -> Error e
            | Ok j -> (
                match
                  (str_field "origin" j, int_field "port" j, int_field "pid" j, str_field "startedAt" j)
                with
                | Some origin, Some port, Some pid, Some started_at when pid > 1 -> (
                    match parse_origin origin port with
                    | Error e -> Error e
                    | Ok (canonical_origin, ipv6) -> (
                        match proc_proof ~proc_root ~uid ~clk_tck ~pid ~port ~ipv6 with
                        | Error e -> Error e
                        | Ok (proof, proc_started) -> (
                            match started_at_epoch started_at with
                            | Some rec_at
                              when rec_at >= proc_started -. 5.
                                   && rec_at <= proc_started +. 300.
                                   && rec_at <= now +. 5. ->
                                Ok
                                  { origin = canonical_origin;
                                    port; pid; started_at;
                                    (* T3's runtime record calls this field
                                       [serverVersion].  Keep accepting the
                                       earlier [version] spelling for older
                                       records, but prefer the canonical field
                                       when both are present. *)
                                    server_version =
                                      (match str_field "serverVersion" j with
                                       | Some _ as version -> version
                                       | None -> str_field "version" j);
                                    record_path = path; t3_home = real_home; proof }
                            | _ ->
                                Error (Runtime_changed "runtime record does not match the process incarnation"))))
                | _ -> Error (Protocol (path ^ ": runtime record is missing origin/port/pid/startedAt"))))

let discover ?(proc_root = "/proc") ?(uid = Unix.getuid ()) ?(gid = Unix.getgid ())
    ?(now = Unix.gettimeofday ()) ?(clk_tck = 100) ?(group_file = "/etc/group")
    ?(passwd_file = "/etc/passwd") ~t3_home () =
  match (try Some (Unix.realpath t3_home) with Unix.Unix_error _ -> None) with
  | None ->
      Error (Discovery (Printf.sprintf "T3 home %s does not exist; start T3 or set T3CODE_HOME" t3_home))
  | Some real_home -> (
      let fs_env = { uid; gid; group_file; passwd_file } in
      let results =
        List.map
          (fun path ->
            ( path,
              validate_record ~proc_root ~uid ~now ~clk_tck ~fs_env ~home:real_home
                ~real_home path ))
          (record_candidates real_home)
      in
      match List.filter_map (fun (p, r) -> match r with Ok rt -> Some (p, rt) | Error _ -> None) results with
      | [ (_, rt) ] -> Ok rt
      | _ :: _ :: _ as l -> Error (Ambiguous (List.map fst l))
      | [] ->
          let reasons =
            results
            |> List.filter_map (fun (_, r) ->
                   match r with Error (Discovery m) when String.length m > 12 && String.ends_with ~suffix:"not present" m -> None
                   | Error e -> Some (error_to_string e) | Ok _ -> None)
          in
          Error
            (Discovery
               (Printf.sprintf
                  "no live T3 runtime under %s (%s); start T3 or set T3CODE_HOME"
                  real_home
                  (if reasons = [] then "no server-runtime.json" else String.concat "; " reasons))))

(* ---------- credentials ---------- *)

type credential = {
  c_origin : string;
  c_home : string;
  c_token : string;
  c_client_id : string;
  c_scopes : string list;
  c_generation : int;
  c_issued_at : string;
  c_expires_in : int option;
  c_proof : proof;
}

let make_credential ~origin ~t3_home ~token ~client_id ~scopes ~generation
    ~issued_at ~expires_in ~proof =
  { c_origin = origin; c_home = t3_home; c_token = token; c_client_id = client_id;
    c_scopes = List.sort String.compare scopes; c_generation = generation;
    c_issued_at = issued_at; c_expires_in = expires_in; c_proof = proof }

let credential_origin c = c.c_origin
let credential_generation c = c.c_generation
let credential_scopes c = c.c_scopes
let credential_proof c = c.c_proof

let default_config_dir ?(getenv = getenv_default) () =
  match nonempty (getenv "C2C_T3_CONFIG_DIR") with
  | Some d -> Ok d
  | None -> (
      match nonempty (getenv "HOME") with
      | Some h -> Ok (Filename.concat (Filename.concat h ".c2c") "t3")
      | None -> Error (Credential "neither C2C_T3_CONFIG_DIR nor HOME is set"))

let credential_path ~config_dir = Filename.concat config_dir "credential.json"

let proof_to_json (p : proof) =
  `Assoc
    [ ("pid", `Int p.pid); ("startTicks", `Int p.start_ticks);
      ("bootId", `String p.boot_id);
      ("listeners", `List (List.map (fun s -> `String s) p.listeners));
      ("exeDev", `Int p.exe_dev); ("exeIno", `Int p.exe_ino) ]

let proof_of_json j : proof option =
  match
    ( int_field "pid" j, int_field "startTicks" j, str_field "bootId" j,
      member "listeners" j, int_field "exeDev" j, int_field "exeIno" j )
  with
  | Some pid, Some start_ticks, Some boot_id, Some (`List l), Some exe_dev, Some exe_ino ->
      let ls = List.filter_map (function `String s -> Some s | _ -> None) l in
      if List.length ls = List.length l then
        Some { pid; start_ticks; boot_id; listeners = ls; exe_dev; exe_ino }
      else None
  | _ -> None

let credential_to_json c =
  `Assoc
    [ ("origin", `String c.c_origin); ("t3Home", `String c.c_home);
      ("token", `String c.c_token); ("clientId", `String c.c_client_id);
      ("scopes", `List (List.map (fun s -> `String s) c.c_scopes));
      ("generation", `Int c.c_generation); ("issuedAt", `String c.c_issued_at);
      ("expiresIn", (match c.c_expires_in with Some i -> `Int i | None -> `Null));
      ("runtimeProof", proof_to_json c.c_proof) ]

let save_credential ~config_dir ~replace c =
  write_private ~replace (credential_path ~config_dir)
    (Yojson.Safe.pretty_to_string (credential_to_json c) ^ "\n")

let load_credential ~config_dir =
  let* text = read_private (credential_path ~config_dir) 65536 in
  match strict_json_of_string ~max_bytes:65536 text with
  | Error _ -> Error (Credential "malformed credential file; re-pair with `c2c t3 pair`")
  | Ok j -> (
      match
        ( str_field "origin" j, str_field "t3Home" j, str_field "token" j,
          str_field "clientId" j, member "scopes" j, int_field "generation" j,
          str_field "issuedAt" j, Option.bind (member "runtimeProof" j) proof_of_json )
      with
      | Some o, Some h, Some t, Some cid, Some (`List sc), Some g, Some ia, Some proof
        when t <> "" ->
          let scopes = List.filter_map (function `String s -> Some s | _ -> None) sc in
          Ok
            (make_credential ~origin:o ~t3_home:h ~token:t ~client_id:cid ~scopes
               ~generation:g ~issued_at:ia
               ~expires_in:(match member "expiresIn" j with Some (`Int i) -> Some i | _ -> None)
               ~proof)
      | _ -> Error (Credential "credential file is missing fields; re-pair with `c2c t3 pair`"))

(* ---------- bounded HTTP ---------- *)

exception Bounded of error

let read_body ~max body =
  let buf = Buffer.create 4096 in
  Lwt_stream.iter_s
    (fun chunk ->
      if Buffer.length buf + String.length chunk > max then
        Lwt.fail (Bounded (Oversize "body"))
      else (
        Buffer.add_string buf chunk;
        Lwt.return_unit))
    (Cohttp_lwt.Body.to_stream body)
  >|= fun () -> Buffer.contents buf

type http_response = {
  status : int;
  headers : Cohttp.Header.t;
  body : string;
}

let http_call ~limits ~validate ~during ?(headers = []) ?body meth uri :
    (http_response, error) result Lwt.t =
  match validate () with
  | Error e -> Lwt.return (Error e)
  | Ok () ->
      Lwt.catch
        (fun () ->
          Lwt_unix.with_timeout limits.request_timeout_s (fun () ->
              let body = Option.map Cohttp_lwt.Body.of_string body in
              Cohttp_lwt_unix.Client.call ~headers:(Cohttp.Header.of_list headers)
                ?body meth uri
              >>= fun (resp, rbody) ->
              let status = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
              let rh = Cohttp.Response.headers resp in
              if status >= 300 && status < 400 then
                Cohttp_lwt.Body.drain_body rbody >|= fun () ->
                Error (Redirect_refused status)
              else if status = 401 || status = 403 then
                Cohttp_lwt.Body.drain_body rbody >|= fun () ->
                Error (Auth_denied { status })
              else if status < 200 || status >= 300 then
                Cohttp_lwt.Body.drain_body rbody >|= fun () ->
                Error (Http_status { status; during })
              else
                match Option.bind (Cohttp.Header.get rh "content-length") int_of_string_opt with
                | Some n when n > limits.max_response_bytes ->
                    Cohttp_lwt.Body.drain_body rbody >|= fun () ->
                    Error (Oversize during)
                | _ ->
                    read_body ~max:limits.max_response_bytes rbody >|= fun b ->
                    Ok { status; headers = rh; body = b }))
        (function
          | Bounded e -> Lwt.return (Error e)
          | Lwt_unix.Timeout -> Lwt.return (Error (Timeout during))
          | Unix.Unix_error (e, _, _) ->
              Lwt.return (Error (Protocol (Printf.sprintf "transport failure during %s: %s" during (Unix.error_message e))))
          | _ -> Lwt.return (Error (Protocol ("transport failure during " ^ during))))

(* ---------- MCP client ---------- *)

type 'a field = Unknown | Known of 'a

type client = {
  origin : string;
  token : string;
  generation : int;
  credential_identity : string;
  limits : limits;
  validate : unit -> (unit, error) result;
  lock : Lwt_mutex.t;
  mutable session : string option;
  mutable seq : int;
  mutable epoch : int;
  mutable auth_failed : bool;
  mutable tools : string list;
}

let create ?(limits = default_limits) ~origin ~credential ~validate () =
  let frame value = string_of_int (String.length value) ^ ":" ^ value in
  let credential_identity = Digestif.SHA256.(to_hex (digest_string
    (frame credential.c_origin ^ frame credential.c_home
     ^ frame credential.c_client_id ^ frame credential.c_token))) in
  { origin; token = credential.c_token; generation = credential.c_generation;
    credential_identity;
    limits; validate; lock = Lwt_mutex.create (); session = None; seq = 0;
    epoch = 0; auth_failed = false; tools = [] }

let credential_generation_of c = c.generation
let credential_identity_of c = c.credential_identity
let transport_epoch c = c.epoch

let mcp_request c ~during ~notification ~meth ~params =
  if c.auth_failed then
    Lwt.return (Error (Auth_denied { status = 401 }))
  else
    let id = if notification then None else (c.seq <- c.seq + 1; Some c.seq) in
    let payload =
      `Assoc
        ([ ("jsonrpc", `String "2.0") ]
        @ (match id with Some i -> [ ("id", `Int i) ] | None -> [])
        @ [ ("method", `String meth); ("params", params) ])
    in
    let headers =
      [ ("authorization", "Bearer " ^ c.token);
        ("content-type", "application/json");
        ("accept", "application/json, text/event-stream");
        ("mcp-protocol-version", protocol_version) ]
      @ (match c.session with Some s -> [ ("mcp-session-id", s) ] | None -> [])
    in
    http_call ~limits:c.limits ~validate:c.validate ~during ~headers
      ~body:(Yojson.Safe.to_string payload) `POST
      (Uri.of_string (c.origin ^ "/mcp"))
    >|= function
    | Error (Auth_denied _ as e) -> c.auth_failed <- true; Error e
    | Error e -> Error e
    | Ok r -> (
        (match Cohttp.Header.get r.headers "mcp-session-id" with
        | Some s when s <> "" -> c.session <- Some s
        | _ -> ());
        match id with
        | None -> Ok `Null
        | Some id ->
            parse_rpc ~max_bytes:c.limits.max_response_bytes
              ~content_type:(Option.value ~default:"" (Cohttp.Header.get r.headers "content-type"))
              ~id r.body)

let locked c f = Lwt_mutex.with_lock c.lock f

let initialize_unlocked c =
  c.session <- None;
  c.epoch <- c.epoch + 1;
  mcp_request c ~during:"initialize" ~notification:false ~meth:"initialize"
    ~params:
      (`Assoc
        [ ("protocolVersion", `String protocol_version); ("capabilities", `Assoc []);
          ("clientInfo", `Assoc [ ("name", `String "c2c-t3-client"); ("version", `String "1") ]) ])
  >>= function
  | Error e -> Lwt.return (Error e)
  | Ok r -> (
      match member "protocolVersion" r with
      | Some (`String v) when v = protocol_version -> (
          mcp_request c ~during:"initialized" ~notification:true
            ~meth:"notifications/initialized" ~params:(`Assoc [])
          >>= function
          | Error e -> Lwt.return (Error e)
          | Ok _ -> (
              mcp_request c ~during:"tools/list" ~notification:false ~meth:"tools/list"
                ~params:(`Assoc [])
              >|= function
              | Error e -> Error e
              | Ok r -> (
                  match member "tools" r with
                  | Some (`List l) ->
                      let names = List.filter_map (fun t -> str_field "name" t) l in
                      let missing = List.filter (fun t -> not (List.mem t names)) required_tools in
                      if missing <> [] then
                        Error (Unsupported ("missing required tools: " ^ String.concat ", " missing))
                      else (c.tools <- names; Ok ())
                  | _ -> Error (Protocol "tools/list has no tools array"))))
      | _ -> Lwt.return (Error (Unsupported "server does not speak MCP protocol 2025-06-18")))

let initialize c = locked c (fun () -> initialize_unlocked c)

let reconnect c =
  if c.auth_failed then Lwt.return (Error (Auth_denied { status = 401 }))
  else locked c (fun () -> initialize_unlocked c)

let tool_error_code tool j =
  let text =
    match member "content" j with
    | Some (`List items) ->
        List.find_map (fun i -> if str_field "type" i = Some "text" then str_field "text" i else None) items
    | _ -> None
  in
  let from_json j =
    match str_field "code" j with
    | Some c -> Some c
    | None -> Option.bind (member "error" j) (str_field "code")
  in
  let raw =
    match Option.bind (member "structuredContent" j) from_json with
    | Some c -> Some c
    | None -> (
        match Option.bind text (fun t -> try Some (Yojson.Safe.from_string t) with _ -> None) with
        | Some tj -> from_json tj
        | None -> None)
  in
  let ok c =
    String.length c >= 1 && String.length c <= 80
    && String.for_all (fun ch ->
           (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch = '_' || ch = '-') c
  in
  Tool_rejected { tool; code = (match raw with Some c when ok c -> c | _ -> "tool_error") }

let call_tool c tool args =
  if not (List.mem tool supported_tools) then
    Lwt.return (Error (Unsupported ("tool not on the allow-list: " ^ tool)))
  else
    locked c (fun () ->
        mcp_request c ~during:tool ~notification:false ~meth:"tools/call"
          ~params:(`Assoc [ ("name", `String tool); ("arguments", `Assoc args) ])
        >|= function
        | Error e -> Error e
        | Ok r -> (
            if member "isError" r = Some (`Bool true) then Error (tool_error_code tool r)
            else
              match member "structuredContent" r with
              | Some (`Assoc _ as s) -> Ok s
              | Some _ -> Error (Protocol "structuredContent is not an object")
              | None -> (
                  match member "content" r with
                  | Some (`List items) -> (
                      match List.find_map (fun i -> if str_field "type" i = Some "text" then str_field "text" i else None) items with
                      | Some t -> strict_json_of_string ~max_bytes:c.limits.max_response_bytes t
                      | None -> Error (Protocol "tool returned no result"))
                  | _ -> Error (Protocol "tool returned no result"))))

(* ---------- typed reads ---------- *)

type provider = {
  provider_instance_id : string field;
  driver_kind : string field;
  models : string list;
}

type capabilities = {
  runtime_mode : string field;
  interaction_mode : string field;
  providers : provider list;
}

let sfield k j = match member k j with Some (`String s) -> Known s | _ -> Unknown

let capabilities c =
  call_tool c "orchestrator_capabilities" [] >|= function
  | Error e -> Error e
  | Ok j ->
      let providers =
        match member "providers" j with
        | Some (`List l) ->
            List.map
              (fun p ->
                { provider_instance_id = sfield "providerInstanceId" p;
                  driver_kind = sfield "driverKind" p;
                  models =
                    (match member "models" p with
                    | Some (`List ms) -> List.filter_map (fun m -> str_field "id" m) ms
                    | _ -> []) })
              l
        | _ -> []
      in
      Ok { runtime_mode = sfield "runtimeMode" j;
           interaction_mode = sfield "interactionMode" j; providers }

type page = { items : Yojson.Safe.t list; complete : bool }

(* Cursor-paged list. Cursor must strictly advance; page/item bounds yield
   complete=false rather than an error. *)
let paged c ~tool ~args ~key =
  let rec loop pages acc count cursor =
    let a = args @ (match cursor with Some n -> [ ("cursor", `Int n) ] | None -> []) in
    call_tool c tool (("limit", `Int 100) :: a) >>= function
    | Error e -> Lwt.return (Error e)
    | Ok j -> (
        match member key j with
        | Some (`List l) -> (
            let count = count + List.length l in
            let acc = List.rev_append l acc in
            let finish complete = Lwt.return (Ok { items = List.rev acc; complete }) in
            match member "nextCursor" j with
            | Some `Null -> finish true
            | Some (`Int n) when n > Option.value ~default:(-1) cursor ->
                if pages + 1 >= c.limits.max_pages || count >= c.limits.max_items
                then finish false
                else loop (pages + 1) acc count (Some n)
            | _ -> Lwt.return (Error (Protocol "pagination cursor missing or not advancing")))
        | _ -> Lwt.return (Error (Protocol ("response has no " ^ key ^ " array"))))
  in
  loop 0 [] 0 None

let environment c = call_tool c "t3_environment_read" []
let list_projects c = paged c ~tool:"t3_project_list" ~args:[] ~key:"projects"

let list_threads c ~project_id ?title_contains ?(include_subagents = false) () =
  paged c ~tool:"t3_thread_list" ~key:"threads"
    ~args:
      ([ ("projectId", `String project_id); ("includeSubagents", `Bool include_subagents) ]
      @ (match title_contains with Some t -> [ ("titleContains", `String t) ] | None -> []))

type run = { run_id : string; status : string field; run_raw : Yojson.Safe.t }

type activity = {
  thread_id : string;
  parent_thread_id : string option field;
  runtime_mode : string field;
  provider_instance_id : string option field;
  model : string option field;
  pending_request_count : int field;
  settled : bool field;
  archived : bool field;
  deleted : bool field;
  snoozed : bool field;
  active_run_id : string option field;
  items : Yojson.Safe.t list;
  recent_runs : run list;
  runs_complete : bool;
  complete : bool;
  text_truncated : bool;
  thread_raw : Yojson.Safe.t;
}

let opt_string_field k j =
  match member k j with
  | Some (`String s) -> Known (Some s)
  | Some `Null -> Known None
  | _ -> Unknown

let int_field k j =
  match member k j with
  | Some (`Int n) when n >= 0 -> Known n
  | _ -> Unknown

let bool_field k j =
  match member k j with
  | Some (`Bool b) -> Known b
  | _ -> Unknown

let bool_field_default k default j =
  match bool_field k j with Known value -> Known value | Unknown -> Known default

let read_activity c ~thread_id ?(run_limit = 50) () =
  let rec loop pages acc size after last =
    let args =
      [ ("threadId", `String thread_id); ("view", `String "activity"); ("limit", `Int 100);
        ("runLimit", `Int run_limit); ("maxCharsPerItem", `Int 50_000) ]
      @ (match after with Some n -> [ ("afterPosition", `Int n) ] | None -> [])
    in
    call_tool c "t3_thread_read" args >>= function
    | Error e -> Lwt.return (Error e)
    | Ok j -> (
        match (member "thread" j, member "items" j, member "recentRuns" j) with
        | Some (`Assoc _ as thread), Some (`List items), Some (`List runs)
          when str_field "threadId" thread = Some thread_id ->
            let acc = List.rev_append items acc in
            let size = size + List.length items in
            let last = Some (thread, runs) in
            let finish complete =
              match last with
              | None -> Lwt.return (Error (Protocol "empty activity read"))
              | Some (thread, runs) ->
                  let recent_runs =
                    List.filter_map
                      (fun r ->
                        match str_field "runId" r with
                        | Some run_id -> Some { run_id; status = sfield "status" r; run_raw = r }
                        | None -> None)
                      runs
                  in
                  let items = List.rev acc in
                  Lwt.return
                    (Ok
                       { thread_id;
                         parent_thread_id = opt_string_field "parentThreadId" thread;
                         runtime_mode = sfield "runtimeMode" thread;
                         provider_instance_id = opt_string_field "providerInstanceId" thread;
                         model = opt_string_field "model" thread;
                         pending_request_count = int_field "pendingRequestCount" thread;
                         settled = bool_field "settled" thread;
                         archived = bool_field "archived" thread;
                         (* The public thread-detail contract has no deleted
                            field: a successful read proves the thread still
                            exists. A deleted row is reported as not-found by
                            the tool and handled by the service point-read. *)
                         deleted = bool_field_default "deleted" false thread;
                         snoozed =
                           (match bool_field "snoozed" thread with
                            | Known _ as value -> value
                            | Unknown ->
                                (match member "snoozedUntil" thread with
                                 | Some (`String _) -> Known true
                                 | Some `Null -> Known false
                                 | _ -> Unknown));
                         active_run_id = opt_string_field "activeRunId" thread;
                         items; recent_runs; complete;
                         runs_complete =
                           (match member "recentRunsHasMore" j, member "runsHasMore" j with
                            | Some (`Bool true), _ | _, Some (`Bool true) -> false
                            | Some (`Bool false), _ | _, Some (`Bool false) -> true
                            | _ -> List.length runs < run_limit);
                         text_truncated =
                           List.exists (fun i -> member "textTruncated" i = Some (`Bool true)) items;
                         thread_raw = thread })
            in
            (match (member "hasMore" j, member "nextPosition" j) with
            | Some (`Bool false), _ -> finish true
            | Some (`Bool true), Some (`Int n) when n > Option.value ~default:(-1) after ->
                if pages + 1 >= c.limits.max_pages || size >= c.limits.max_items
                then finish false
                else loop (pages + 1) acc size (Some n) last
            | _ -> Lwt.return (Error (Protocol "activity pagination missing or not advancing")))
        | _ -> Lwt.return (Error (Protocol "unexpected thread activity shape")))
  in
  loop 0 [] 0 None None

type queue = { queued_run_ids : string list; queue_complete : bool }

let list_queue c ~thread_id =
  paged c ~tool:"t3_queue_list" ~args:[ ("threadId", `String thread_id) ] ~key:"items"
  >|= function
  | Error e -> Error e
  | Ok p ->
      (* Only the identity is kept; queued text is dropped here. *)
      let ids = List.filter_map (fun i -> str_field "queuedRunId" i) p.items in
      if List.length ids <> List.length p.items
         || List.length (List.sort_uniq String.compare ids) <> List.length ids
      then Error (Protocol "invalid or duplicate queued run identity")
      else Ok { queued_run_ids = ids; queue_complete = p.complete }

type send_mode = [ `Auto | `Queue | `Steer | `Restart ]

type receipt = { receipt_thread_id : string; message_id : string; run_id : string }

let mode_string = function
  | `Auto -> "auto" | `Queue -> "queue" | `Steer -> "steer" | `Restart -> "restart"

let send_message c ~thread_id ~message ~mode ~client_request_id =
  call_tool c "t3_thread_send"
    [ ("threadId", `String thread_id); ("message", `String message);
      ("mode", `String (mode_string mode)); ("clientRequestId", `String client_request_id) ]
  >|= function
  | Error e -> Error e
  | Ok j -> (
      match (str_field "threadId" j, str_field "messageId" j, str_field "runId" j) with
      | Some t, Some m, Some r when t = thread_id ->
          Ok { receipt_thread_id = t; message_id = m; run_id = r }
      | _ -> Error (Protocol "invalid send receipt"))

(* ---------- authorize ---------- *)

let validator ~proc_root ~uid ~gid ~now ~clk_tck ~t3_home ~origin ~proof () =
  match discover ~proc_root ~uid ~gid ~now:(now ()) ~clk_tck ~t3_home () with
  | Error e -> Error e
  | Ok rt ->
      if rt.origin <> origin then Error (Runtime_changed "endpoint replaced; refusing to send the credential")
      else if rt.proof <> proof then Error (Runtime_changed "T3 restarted or its listener changed; credential held")
      else Ok ()

let authorize ?limits ?(rebind = false) ?(proc_root = "/proc") ?(uid = Unix.getuid ())
    ?(gid = Unix.getgid ()) ?now ?(clk_tck = 100) ~config_dir ~t3_home () =
  let now_fn = match now with Some n -> fun () -> n | None -> Unix.gettimeofday in
  let* rt = discover ~proc_root ~uid ~gid ~now:(now_fn ()) ~clk_tck ~t3_home () in
  let* cred = load_credential ~config_dir in
  if cred.c_origin <> rt.origin || cred.c_home <> rt.t3_home then
    Error (Runtime_changed "runtime endpoint/home differs from the paired credential; refusing to send it")
  else if List.sort String.compare cred.c_scopes <> required_scopes then
    Error (Credential "credential scopes are not exactly orchestration:read and orchestration:operate")
  else
    let* cred =
      if cred.c_proof = rt.proof then Ok cred
      else if rebind then (
        let cred = { cred with c_proof = rt.proof } in
        let* () = save_credential ~config_dir ~replace:true cred in
        Ok cred)
      else Error (Runtime_changed "T3 restarted since pairing; credential held until revalidated")
    in
    let validate =
      validator ~proc_root ~uid ~gid ~now:now_fn ~clk_tck ~t3_home ~origin:rt.origin
        ~proof:cred.c_proof
    in
    Ok (create ?limits ~origin:rt.origin ~credential:cred ~validate (), rt)

(* ---------- pairing ---------- *)

let json_post ~limits ~validate ~during origin path payload =
  http_call ~limits ~validate ~during
    ~headers:[ ("content-type", "application/json"); ("accept", "application/json") ]
    ~body:(Yojson.Safe.to_string payload) `POST (Uri.of_string (origin ^ path))
  >|= function
  | Error e -> Error e
  | Ok r -> strict_json_of_string ~max_bytes:limits.max_response_bytes r.body

let scopes_of_string s = String.split_on_char ' ' s |> List.filter (( <> ) "") |> List.sort String.compare

let create_pairing_code ~(runtime : runtime) ~t3_bin =
  let fs_env = { uid = Unix.getuid (); gid = Unix.getgid (); group_file = "/etc/group"; passwd_file = "/etc/passwd" } in
  if Filename.is_relative t3_bin then
    Lwt.return (Error (Unsafe_state "t3 binary path must be absolute"))
  else
    match Unix.stat t3_bin with
    | exception Unix.Unix_error _ -> Lwt.return (Error (Discovery "t3 binary not found"))
    | st when st.Unix.st_kind <> Unix.S_REG || st.Unix.st_uid <> fs_env.uid || not (safe_permissions fs_env st) ->
        Lwt.return (Error (Unsafe_state "t3 binary must be a same-user file not writable by other accounts"))
    | st when st.Unix.st_dev <> runtime.proof.exe_dev || st.Unix.st_ino <> runtime.proof.exe_ino ->
        Lwt.return (Error (Runtime_changed "t3 binary is not the executable the runtime is running"))
    | _ ->
        let args =
          [| t3_bin; "auth"; "pairing"; "create"; "--base-dir"; runtime.t3_home;
             "--scope"; "orchestration:read"; "--scope"; "orchestration:operate";
             "--ttl"; "10m"; "--label"; "c2c-t3-connector"; "--json" |]
        in
        Lwt.catch
          (fun () ->
            Lwt_process.pread ~timeout:30. ~stderr:`Dev_null (t3_bin, args) >|= fun out ->
            if String.length out > 65536 then Error (Oversize "pairing output")
            else
              match String.index_opt out '{' with
              | None -> Error (Protocol "pairing CLI printed no JSON")
              | Some i -> (
                  match strict_json_of_string ~max_bytes:65536 (String.sub out i (String.length out - i)) with
                  | Error e -> Error e
                  | Ok j ->
                      let scopes =
                        match member "scopes" j with
                        | Some (`List l) -> List.sort String.compare (List.filter_map (function `String s -> Some s | _ -> None) l)
                        | _ -> []
                      in
                      let code =
                        List.find_map (fun k -> str_field k j) [ "credential"; "token"; "code" ]
                      in
                      if scopes <> required_scopes then Error (Credential "pairing code carries unexpected scopes")
                      else match code with Some c when c <> "" -> Ok c | _ -> Error (Protocol "pairing CLI returned no code")))
          (fun _ -> Lwt.return (Error (Protocol "pairing CLI failed")))

let pair ?(limits = default_limits) ~(runtime : runtime) ~validate ~pairing_code
    ~client_name ~config_dir ~replace () =
  let redirect_uri = "http://127.0.0.1:53999/callback" in
  let origin = runtime.origin in
  let prior_gen =
    if replace then (match load_credential ~config_dir with Ok c -> c.c_generation | Error _ -> 0) else 0
  in
  if (not replace) && Sys.file_exists (credential_path ~config_dir) then
    Lwt.return (Error (Credential "credential exists; re-pair explicitly with replace"))
  else
    json_post ~limits ~validate ~during:"oauth register" origin "/oauth/mcp/register"
      (`Assoc
        [ ("client_name", `String client_name);
          ("redirect_uris", `List [ `String redirect_uri ]);
          ("grant_types", `List [ `String "authorization_code" ]);
          ("response_types", `List [ `String "code" ]);
          ("token_endpoint_auth_method", `String "none") ])
    >>= function
    | Error e -> Lwt.return (Error e)
    | Ok reg -> (
        match str_field "client_id" reg with
        | None -> Lwt.return (Error (Protocol "registration returned no client_id"))
        | Some client_id -> (
            let verifier = pkce_verifier () in
            let state = b64url (random_bytes 24) in
            json_post ~limits ~validate ~during:"oauth decision" origin "/oauth/mcp/decision"
              (`Assoc
                [ ( "authorization",
                    `Assoc
                      [ ("response_type", `String "code"); ("client_id", `String client_id);
                        ("redirect_uri", `String redirect_uri);
                        ("code_challenge", `String (pkce_challenge verifier));
                        ("code_challenge_method", `String "S256"); ("state", `String state);
                        ("resource", `String (origin ^ "/mcp")) ] );
                  ( "decision",
                    `Assoc
                      [ ("_tag", `String "pairing-code"); ("access", `String "auto");
                        ("code", `String pairing_code) ] ) ])
            >>= function
            | Error e -> Lwt.return (Error e)
            | Ok dec -> (
                let cb = Option.map Uri.of_string (str_field "redirectTo" dec) in
                let code =
                  match cb with
                  | Some u
                    when Uri.scheme u = Some "http" && Uri.host u = Some "127.0.0.1"
                         && Uri.port u = Some 53999 && Uri.path u = "/callback"
                         && Uri.get_query_param u "state" = Some state
                         && Uri.get_query_param u "error" = None ->
                      Uri.get_query_param u "code"
                  | _ -> None
                in
                match code with
                | None -> Lwt.return (Error (Credential "pairing callback rejected or failed state validation"))
                | Some auth_code -> (
                    http_call ~limits ~validate ~during:"oauth token"
                      ~headers:[ ("content-type", "application/x-www-form-urlencoded"); ("accept", "application/json") ]
                      ~body:
                        (Uri.encoded_of_query
                           [ ("grant_type", [ "authorization_code" ]); ("code", [ auth_code ]);
                             ("redirect_uri", [ redirect_uri ]); ("client_id", [ client_id ]);
                             ("code_verifier", [ verifier ]) ])
                      `POST (Uri.of_string (origin ^ "/oauth/mcp/token"))
                    >|= fun r ->
                    let* r = r in
                    let* tok = strict_json_of_string ~max_bytes:limits.max_response_bytes r.body in
                    let scope = Option.value ~default:"" (str_field "scope" tok) in
                    match (str_field "token_type" tok, str_field "access_token" tok) with
                    | Some "Bearer", Some access when access <> "" ->
                        if scopes_of_string scope <> required_scopes then
                          Error (Credential "server granted scopes other than orchestration:read and orchestration:operate")
                        else
                          let cred =
                            make_credential ~origin ~t3_home:runtime.t3_home ~token:access ~client_id
                              ~scopes:(scopes_of_string scope) ~generation:(prior_gen + 1)
                              ~issued_at:(Ptime.to_rfc3339 ~frac_s:0 ~tz_offset_s:0 (Ptime_clock.now ()))
                              ~expires_in:(match member "expires_in" tok with Some (`Int i) -> Some i | _ -> None)
                              ~proof:runtime.proof
                          in
                          let* () = save_credential ~config_dir ~replace cred in
                          Ok cred
                    | _ -> Error (Protocol "token response is not a Bearer token")))))
