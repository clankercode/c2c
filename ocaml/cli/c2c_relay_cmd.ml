(* c2c_relay_cmd — relay subcommands (shell-out to Python).
   Extracted from c2c.ml as part of the architecture refactoring. *)

open Cmdliner.Term.Syntax
open C2c_cli_helpers

let ( // ) = Filename.concat

(* relay-specific json_flag (no -j short form) *)
let json_flag =
  Cmdliner.Arg.(value & flag & info ["json"]
    ~doc:"Output raw JSON instead of a human-readable table.")

let relay_serve_cmd =
  let listen =
    Cmdliner.Arg.(value & opt (some string) None & info [ "listen" ] ~docv:"HOST:PORT" ~doc:"Address to listen on (default: 127.0.0.1:7331).")
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:"Bearer token for authentication.")
  in
  let token_file =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token-file" ] ~docv:"PATH" ~doc:"Read bearer token from a file.")
  in
  let storage =
    Cmdliner.Arg.(value & opt (some string) None & info [ "storage" ] ~docv:"memory|sqlite" ~doc:"Storage backend (default: memory).")
  in
  let db_path =
    Cmdliner.Arg.(value & opt (some string) None & info [ "db-path" ] ~docv:"PATH" ~doc:"SQLite database path (use with --storage sqlite).")
  in
  let gc_interval =
    Cmdliner.Arg.(value & opt (some int) None & info [ "gc-interval" ] ~docv:"SECONDS" ~doc:"GC interval in seconds (default: 300).")
  in
  let verbose =
    Cmdliner.Arg.(value & flag & info [ "verbose"; "v" ] ~doc:"Enable verbose output.")
  in
  let tls_cert =
    Cmdliner.Arg.(value & opt (some string) None & info [ "tls-cert" ] ~docv:"PATH" ~doc:"PEM certificate file for TLS (enables HTTPS).")
  in
  let tls_key =
    Cmdliner.Arg.(value & opt (some string) None & info [ "tls-key" ] ~docv:"PATH" ~doc:"PEM private-key file for TLS (required with --tls-cert).")
  in
  let allowed_identities =
    Cmdliner.Arg.(value & opt (some string) None & info [ "allowed-identities" ] ~docv:"PATH"
      ~doc:"JSON file mapping {alias: identity_pk_b64} (L3/5). Listed aliases require a matching signed register; unlisted aliases stay first-mover-wins.")
  in
  let persist_dir =
    Cmdliner.Arg.(value & opt (some string) None & info [ "persist-dir" ] ~docv:"DIR"
      ~doc:"Directory for persistent room history storage (or C2C_RELAY_PERSIST_DIR). Room messages are written to <dir>/rooms/<room_id>/history.jsonl and loaded on startup.")
  in
  let remote_broker_ssh_target =
    Cmdliner.Arg.(value & opt (some string) None & info [ "remote-broker-ssh-target" ] ~docv:"USER@HOST"
      ~doc:"SSH target for remote broker polling (e.g. user@broker-host.example.com).")
  in
  let remote_broker_root =
    Cmdliner.Arg.(value & opt (some string) None & info [ "remote-broker-root" ] ~docv:"PATH"
      ~doc:"Remote broker root path (e.g. /home/user/.local/share/c2c). Used with --remote-broker-ssh-target.")
  in
  let remote_broker_id =
    Cmdliner.Arg.(value & opt (some string) None & info [ "remote-broker-id" ] ~docv:"ID"
      ~doc:"Identifier for this remote broker (default: \"default\"). Used with --remote-broker-ssh-target.")
  in
  let relay_name =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-name" ] ~docv:"NAME"
      ~doc:"This relay's well-known host name for cross-host alias resolution \
            (#379 Phase 2 §6.1). When a `to_alias` arrives shaped `<alias>@<host>`, \
            the relay strips and looks up the bare alias only when `<host>` matches \
            this name (or the literal `relay` back-compat or empty). Other host \
            parts are dead-lettered with reason `cross_host_not_implemented`. \
            Defaults to the value of the listen host (the host part of --listen). \
            Single-relay v1; mesh forwarding (#330) will branch from the dead-letter site.")
  in
  (* #330 S1: peer relay table — accumulate name=url and name=pk pairs *)
  let peer_relay_urls =
    Cmdliner.Arg.(value & opt_all string [] & info [ "peer-relay" ] ~docv:"NAME=URL"
      ~doc:"A peer relay's well-known name and its base URL (repeatable). \
            Example: --peer-relay relay-b=http://relay-b:9001. \
            Configure symmetric entries on both relays.")
  in
  let peer_relay_pks =
    Cmdliner.Arg.(value & opt_all string [] & info [ "peer-relay-pubkey" ] ~docv:"NAME=PK"
      ~doc:"A peer relay's Ed25519 public key (repeatable). \
            Example: --peer-relay-pubkey relay-b=<base64-pk>. \
            Configure symmetric entries on both relays.")
  in
  let+ listen = listen
  and+ token = token
  and+ token_file = token_file
  and+ storage = storage
  and+ db_path = db_path
  and+ gc_interval = gc_interval
  and+ verbose = verbose
  and+ tls_cert = tls_cert
  and+ tls_key = tls_key
  and+ allowed_identities = allowed_identities
  and+ persist_dir = persist_dir
  and+ remote_broker_ssh_target = remote_broker_ssh_target
  and+ remote_broker_root = remote_broker_root
  and+ remote_broker_id = remote_broker_id
  and+ relay_name = relay_name
  and+ peer_relay_urls = peer_relay_urls
  and+ peer_relay_pks = peer_relay_pks in
  (* Parse listen address (default 127.0.0.1:7331) *)
  let host, port = match listen with
    | None -> ("127.0.0.1", 7331)
    | Some v ->
        (match String.split_on_char ':' v with
         | [host; port_str] ->
             (match int_of_string_opt port_str with
              | Some p -> (host, p)
              | None ->
                  Printf.eprintf "error: invalid port in --listen %S\n%!" v;
                  exit 1)
         | _ ->
             Printf.eprintf "error: --listen must be HOST:PORT (%S)\n%!" v;
             exit 1)
  in
  (* Resolve token: prefer direct value, fall back to file *)
  let token = match token with
    | Some t -> Some t
    | None ->
        (match token_file with
         | Some f ->
             (try Some (Stdlib.input_line (open_in f)) with
              | Sys_error msg ->
                  Printf.eprintf "error reading token file: %s\n%!" msg;
                  exit 1
              | End_of_file ->
                  Printf.eprintf "error: token file %S is empty\n%!" f;
                  exit 1)
         | None -> None)
  in
  (* Convert gc_interval from int option to float (0.0 = disabled) *)
  let gc_interval = match gc_interval with
    | Some i -> float_of_int i
    | None -> 0.0
  in
  (* Storage backend selection. InMemoryRelay is the default. SqliteRelay is
     planned (OCaml-native, replacing the deprecated Python fallback). *)
  let tls_cfg =
    match tls_cert, tls_key with
    | Some c, Some k -> Some (`Cert_key (c, k))
    | None, None -> None
    | Some _, None ->
        Printf.eprintf "error: --tls-cert requires --tls-key\n%!"; exit 1
    | None, Some _ ->
        Printf.eprintf "error: --tls-key requires --tls-cert\n%!"; exit 1
  in
  let allowlist = match allowed_identities with
  | None -> []
  | Some path ->
    (try
      let json = Yojson.Safe.from_file path in
      match json with
      | `Assoc pairs ->
        List.map (fun (alias, v) -> match v with
          | `String pk_b64 -> (alias, pk_b64)
          | _ ->
            Printf.eprintf "error: --allowed-identities entry for %S must be a string\n%!" alias;
            exit 1) pairs
      | _ ->
        Printf.eprintf "error: --allowed-identities file must be a JSON object { alias: pk_b64, ... }\n%!";
        exit 1
    with
    | Sys_error msg ->
      Printf.eprintf "error reading --allowed-identities: %s\n%!" msg; exit 1
    | Yojson.Json_error msg ->
      Printf.eprintf "error parsing --allowed-identities: %s\n%!" msg; exit 1)
in
let persist_dir = match persist_dir with
  | Some d -> Some d
  | None -> Sys.getenv_opt "C2C_RELAY_PERSIST_DIR"
in
Random.self_init ();
(* Banner git hash: prefer RAILWAY_GIT_COMMIT_SHA at runtime (same logic
   /health uses — see Relay.handle_health), fall back to a `git rev-parse`
   shell-out, and finally to the literal "unknown". Without this fallback
   the Docker build context has no .git (see .dockerignore), so the compile
   time Version.git_sha is "unknown" and the banner would always show
   "git=unknown" even when Railway sets the SHA at runtime. *)
let banner_git_hash =
  match Sys.getenv_opt "RAILWAY_GIT_COMMIT_SHA" with
  | Some sha when String.length sha >= 7 -> String.sub sha 0 7
  | _ -> Option.value (git_shorthash ()) ~default:"unknown"
in
Version.banner ~role:"relay-server" ~git_hash:banner_git_hash;
Printf.eprintf "  listen=%s:%d\n%!" host port;
(* #379 S2: --relay-name defaults to the listen host. The resolved value is
   threaded into Broker.create as ~self_host so the cross-host alias splitter
   from S1 (galaxy's slice) can decide which `<alias>@<host>` inputs to accept
   vs dead-letter as cross_host_not_implemented. *)
let resolved_relay_name = match relay_name with
  | Some n -> n
  | None -> host
in
Printf.eprintf "  relay-name=%s\n%!" resolved_relay_name;
(* #330 S1: parse --peer-relay and --peer-relay-pubkey into a peer_relays table *)
(* Build peer_relays_tbl as a single expression so it ends with 'in' *)
let peer_relays_tbl = begin
  let urls = List.fold_left (fun acc s ->
    match String.index_opt s '=' with
    | None -> (Printf.eprintf "error: --peer-relay %S must be NAME=URL\n%!" s; exit 1)
    | Some i ->
        let name = String.sub s 0 i in
        let url = String.sub s (i + 1) (String.length s - i - 1) in
        if name = "" then (Printf.eprintf "error: --peer-relay NAME=URL: NAME must not be empty\n%!"; exit 1);
        if url = "" then (Printf.eprintf "error: --peer-relay NAME=URL: URL must not be empty\n%!"; exit 1);
        (name, url) :: acc
  ) [] peer_relay_urls in
  let pks = List.fold_left (fun acc s ->
    match String.index_opt s '=' with
    | None -> (Printf.eprintf "error: --peer-relay-pubkey %S must be NAME=PK\n%!" s; exit 1)
    | Some i ->
        let name = String.sub s 0 i in
        let pk = String.sub s (i + 1) (String.length s - i - 1) in
        if name = "" then (Printf.eprintf "error: --peer-relay-pubkey NAME=PK: NAME must not be empty\n%!"; exit 1);
        if pk = "" then (Printf.eprintf "error: --peer-relay-pubkey NAME=PK: PK must not be empty\n%!"; exit 1);
        (name, pk) :: acc
  ) [] peer_relay_pks in
  (* Validate: every pk name must have a corresponding url name *)
  List.iter (fun (name, _) ->
    if not (List.mem_assoc name urls) then (
      Printf.eprintf "error: --peer-relay-pubkey %s=PK has no matching --peer-relay %s=URL\n%!" name name;
      exit 1
    )
  ) pks;
  (* Validate: every url name must have a corresponding pk *)
  List.iter (fun (name, _url) ->
    if not (List.mem_assoc name pks) then (
      Printf.eprintf "error: --peer-relay %s=URL has no matching --peer-relay-pubkey %s=PK\n%!" name name;
      exit 1
    )
  ) urls;
  (* Build and return peer_relays_tbl *)
  let tbl = Hashtbl.create (List.length urls) in
  List.iter (fun (name, url) ->
    let pk = List.assoc name pks in
    Hashtbl.add tbl name { Relay.name; url; identity_pk = pk }
  ) urls;
  Printf.eprintf "  peer-relays: %d configured\n%!" (Hashtbl.length tbl);
  tbl
end in
match storage with
| Some "sqlite" ->
    Printf.printf "storage: sqlite\n%!";
    (match persist_dir with
     | Some d -> Printf.eprintf "  persist-dir=%s\n%!" d
     | None -> Printf.eprintf "  persist-dir=%s\n%!" (Filename.concat (Sys.getcwd()) ""));
    (match db_path with
     | Some p -> Printf.eprintf "  db-path=%s\n%!" p
     | None -> ());
    let relay = Relay.SqliteRelay.create ~self_host:(Some resolved_relay_name) ~peer_relays:peer_relays_tbl ?persist_dir () in
    let remote_polling_stop = match remote_broker_ssh_target, remote_broker_root with
      | Some ssh_target, Some broker_root ->
          let broker_id = Option.value remote_broker_id ~default:"default" in
          let broker = { Relay_remote_broker.id = broker_id; ssh_target; broker_root } in
          Printf.eprintf "  remote-broker: polling %s:%s\n%!" ssh_target broker_root;
          Some (Relay_remote_broker.start_polling ~broker ~interval:5.0
            ~on_fetch:(fun n -> Printf.eprintf "  [remote-broker] fetched %d messages\n%!" n))
      | _ -> None
    in
    let _ = remote_polling_stop in
    let module Server = Relay.Relay_server(Relay.SqliteRelay) in
    Lwt_main.run (Server.start_server ~host ~port ~relay ~token ~verbose ~gc_interval ?tls:tls_cfg ~allowlist ())
| _ ->
    Printf.printf "storage: memory\n%!";
    (match persist_dir with
     | Some d -> Printf.eprintf "  persist-dir=%s\n%!" d
     | None -> Printf.eprintf "  persist-dir=none (in-memory only)\n%!");
    let relay = Relay.InMemoryRelay.create ~self_host:(Some resolved_relay_name) ~peer_relays:peer_relays_tbl ?persist_dir () in
    let remote_polling_stop = match remote_broker_ssh_target, remote_broker_root with
      | Some ssh_target, Some broker_root ->
          let broker_id = Option.value remote_broker_id ~default:"default" in
          let broker = { Relay_remote_broker.id = broker_id; ssh_target; broker_root } in
          Printf.eprintf "  remote-broker: polling %s:%s\n%!" ssh_target broker_root;
          Some (Relay_remote_broker.start_polling ~broker ~interval:5.0
            ~on_fetch:(fun n -> Printf.eprintf "  [remote-broker] fetched %d messages\n%!" n))
      | _ -> None
    in
    let _ = remote_polling_stop in
    let module Server = Relay.Relay_server(Relay.InMemoryRelay) in
    Lwt_main.run (Server.start_server ~host ~port ~relay ~token ~verbose ~gc_interval ?tls:tls_cfg ~allowlist ())

let relay_config_path () =
  match Sys.getenv_opt "C2C_RELAY_CONFIG" with
  | Some p when p <> "" -> p
  | _ ->
      (match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
       | Some d when String.trim d <> "" -> Filename.concat (String.trim d) "relay.json"
       | _ ->
           let home = try Sys.getenv "HOME" with Not_found -> "." in
           Filename.concat home ".config/c2c/relay.json")

(* Delegated to C2c_io.read_file_trimmed (#388) *)
let read_file_trimmed = C2c_io.read_file_trimmed

let load_relay_config () =
  let path = relay_config_path () in
  if not (Sys.file_exists path) then `Assoc []
  else
    try Yojson.Safe.from_file path
    with _ -> `Assoc []

let relay_config_string_field key =
  match load_relay_config () with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String v) when v <> "" -> Some v
       | _ -> None)
  | _ -> None

(* Default public relay URL. Surfaced in --help so users can find it
   without reading source (B091). The same constant is also used as a
   fallback in c2c_relay_subscribe_daemon.ml / c2c_health_cmd.ml. *)
let default_public_relay_url = "https://relay.c2c.im"

let relay_url_resolution_doc =
  Printf.sprintf
    "Relay server URL. Default: %s (public relay). \
     Override with $(b,--relay-url), $(b,C2C_RELAY_URL), or $(b,c2c relay setup --url) <URL>."
    default_public_relay_url

let relay_token_resolution_doc =
  "Bearer token (or C2C_RELAY_TOKEN or saved c2c relay setup config)."

let relay_url_required_error =
  Printf.sprintf
    "error: --relay-url required (default public relay is %s; \
     set C2C_RELAY_URL or run c2c relay setup --url <URL>).\n"
    default_public_relay_url

let resolve_relay_url opt =
  match opt with
  | Some v when v <> "" -> Some v
  | _ ->
      (match Sys.getenv_opt "C2C_RELAY_URL" with
       | Some v when v <> "" -> Some v
       | _ -> relay_config_string_field "url")

let resolve_relay_token opt =
  match opt with
  | Some v when v <> "" -> Some v
  | _ ->
      (match Sys.getenv_opt "C2C_RELAY_TOKEN" with
       | Some v when v <> "" -> Some v
       | _ -> relay_config_string_field "token")

(* B114: room mutations on the relay REQUIRE a signed body proof/envelope
   (the unsigned legacy path is dev-only server-side). The CLI therefore
   always signs room ops — if no client identity exists yet, create one at
   the resolved identity path (C2C_RELAY_IDENTITY_PATH override, else the
   default ~/.config/c2c/identity.json), mirroring the broker's
   load_or_create_ed25519_identity behavior. The alias is bound to the key
   via TOFU on the first signed op. *)
let client_identity_path () =
  match Sys.getenv_opt "C2C_RELAY_IDENTITY_PATH" with
  | Some p when p <> "" -> p
  | _ -> Relay_identity.default_path ()

let load_client_identity () =
  Relay_identity.load ~path:(client_identity_path ()) ()

let load_or_create_client_identity ~alias_hint =
  let path = client_identity_path () in
  Relay_identity.load_or_create_at ~path ~alias_hint

(* Shared by `c2c relay register` and the explicit
   `c2c monitor --register-relay-alias` bootstrap. This is the one canonical
   direct-registration shape: cli-<alias>/cli-<alias>, signed by the local
   machine identity. *)
let register_alias_signed ~url ?token ~alias ~identity () =
  C2c_monitor_relay_preflight.register_alias_signed
    ~url ?token ~alias ~identity ()

(* --- shared result rendering -----------------------------------------------

   Every relay subcommand ends by printing the relay's JSON response and
   exiting 0/1 on its "ok" field. [print_result_and_exit] centralizes that
   tail so auth failures can carry actionable hints: when the relay rejects a
   signed request because the claimed alias has no identity binding
   (Relay_client_hints.is_missing_identity_binding), a fix-it hint naming the
   exact registration command is printed to stderr. Pass [~alias_source] for
   any request that was (or may have been) signed with an alias; omit it for
   unsigned/admin requests and for `relay register` itself (hinting "run
   c2c relay register" at a failing register would be circular). *)
let print_result_and_exit ?alias_source result =
  print_endline (Yojson.Safe.pretty_to_string result);
  let ok = match result with
    | `Assoc fields ->
        (match List.assoc_opt "ok" fields with Some (`Bool true) -> true | _ -> false)
    | _ -> false
  in
  if ok then exit 0
  else begin
    (* B121: protocol-skew responses already carry the upgrade sentence in
       [error]; echo it on stderr so operators see it next to any other
       hints even when stdout is piped/json-consumed. *)
    if Relay.Relay_client.is_protocol_incompatible result then begin
      match result with
      | `Assoc fields ->
          (match List.assoc_opt "error" fields with
           | Some (`String msg) -> Printf.eprintf "%s\n%!" msg
           | _ -> ())
      | _ -> ()
    end;
    (match alias_source with
     | Some src ->
         (match Relay_client_hints.hint_for_response ~alias_source:src result with
          | Some hint -> Printf.eprintf "%s%!" hint
          | None -> ())
     | None -> ());
    exit 1
  end

let relay_connect_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let token_file =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token-file" ] ~docv:"PATH" ~doc:"Read bearer token from a file.")
  in
  let node_id =
    Cmdliner.Arg.(value & opt (some string) None & info [ "node-id" ] ~docv:"ID" ~doc:"Node identifier (default: hostname-githash).")
  in
  let broker_root =
    Cmdliner.Arg.(value & opt (some string) None & info [ "broker-root" ] ~docv:"DIR" ~doc:"Broker root directory.")
  in
  let interval =
    Cmdliner.Arg.(value & opt (some int) None & info [ "interval" ] ~docv:"SECONDS" ~doc:"Poll interval in seconds (default: 30).")
  in
  let once =
    Cmdliner.Arg.(value & flag & info [ "once" ] ~doc:"Run once and exit.")
  in
  let all_brokers =
    Cmdliner.Arg.(value & flag & info [ "all-brokers" ]
      ~doc:"Dynamically sync every known repository broker on this machine. Used by the managed machine-wide connector.")
  in
  let verbose =
    Cmdliner.Arg.(value & flag & info [ "verbose"; "v" ] ~doc:"Enable verbose output.")
  in
  let+ relay_url = relay_url
  and+ token = token
  and+ token_file = token_file
  and+ node_id = node_id
  and+ broker_root = broker_root
  and+ interval = interval
  and+ once = once
  and+ all_brokers = all_brokers
  and+ verbose = verbose in
  let use_python = Sys.getenv_opt "C2C_RELAY_CONNECTOR_BACKEND" = Some "python" in
  let effective_broker_root = match broker_root with
    | Some b -> b
    | None -> resolve_broker_root ()
  in
  let effective_node_id = match node_id with
    | Some n -> n
    (* B087: derive a real opaque node id from the host (12-hex SHA256 of
       product_uuid / machine-id / hostname via Host_id) instead of the
       "unknown-node" placeholder, which made every relay registration
       anonymous and unaddressable. Falls back to the "000000000000"
       sentinel only when no host source is readable at all. *)
    | None -> Host_id.compute_host_hash ()
  in
  let effective_token = match token, token_file with
    | Some t, _ when t <> "" -> Some t
    | _, Some f -> (try Some (read_file_trimmed f) with _ -> None)
    | _, None -> resolve_relay_token None
  in
  let effective_interval = float_of_int (Option.value interval ~default:30) in
  let effective_identity_path = match Sys.getenv_opt "C2C_RELAY_IDENTITY_PATH" with
    | Some p -> Some p
    | None ->
        (match Relay_identity.default_path () with
         | p when Sys.file_exists p -> Some p
         | _ -> None)
  in
  let effective_identity = match effective_identity_path with
    | Some p -> (match Relay_identity.load ~path:p () with | Ok id -> Some id | Error _ -> None)
    | None -> None
  in
  let effective_relay_url = Option.value (resolve_relay_url relay_url) ~default:"http://localhost:7331" in
  if not use_python then
    if all_brokers then
      exit (C2c_relay_connector.start_machine
        ~relay_url:effective_relay_url ~token:effective_token
        ~identity:effective_identity ~primary_broker_root:effective_broker_root
        ~node_id:effective_node_id ~heartbeat_ttl:300.0
        ~interval:effective_interval ~verbose ~once)
    else
      exit (C2c_relay_connector.start
        ~relay_url:effective_relay_url
        ~token:effective_token
        ~identity:effective_identity
        ~broker_root:effective_broker_root
        ~node_id:effective_node_id
        ~heartbeat_ttl:300.0
        ~interval:effective_interval
        ~verbose
        ~once)
  else
    if all_brokers then begin
      Printf.eprintf "error: --all-brokers requires the OCaml connector backend.\n%!";
      exit 1
    end else
    match find_python_script "c2c_relay_connector.py" with
    | None ->
        Printf.eprintf "error: cannot find c2c_relay_connector.py. Run from inside the c2c git repo.\n%!";
        exit 1
    | Some script ->
        let args = [ "python3"; script; "--relay-url"; effective_relay_url ] in
        let args = match token, token_file with
          | Some v, _ when v <> "" -> args @ [ "--token"; v ]
          | _, Some _ -> args
          | _ -> (match resolve_relay_token None with None -> args | Some v -> args @ [ "--token"; v ])
        in
        let args = match token_file with None -> args | Some v -> args @ [ "--token-file"; v ] in
        let args = match effective_node_id with "unknown-node" -> args | v -> args @ [ "--node-id"; v ] in
        let args = args @ [ "--broker-root"; effective_broker_root ] in
        let args = match interval with None -> args | Some v -> args @ [ "--interval"; string_of_int v ] in
        let args = if once then args @ [ "--once" ] else args in
        let args = if verbose then args @ [ "--verbose" ] else args in
        let args = match Relay_identity.load () with
          | Ok _ -> args @ [ "--identity-path"; Relay_identity.default_path () ]
          | Error _ -> args
        in
        Unix.execvp "python3" (Array.of_list args)

let relay_setup_cmd =
  let url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "url" ] ~docv:"URL"
      ~doc:(Printf.sprintf
              "Relay server URL. Default public relay is %s. \
               Equivalent to $(b,C2C_RELAY_URL) or saved config; pass this \
               flag to point at a private relay instead."
              default_public_relay_url))
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:"Bearer token.")
  in
  let token_file =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token-file" ] ~docv:"PATH" ~doc:"Read bearer token from a file.")
  in
  let node_id =
    Cmdliner.Arg.(value & opt (some string) None & info [ "node-id" ] ~docv:"ID" ~doc:"Node identifier.")
  in
  let show =
    Cmdliner.Arg.(value & flag & info [ "show" ] ~doc:"Show current relay configuration.")
  in
  let+ url = url
  and+ token = token
  and+ token_file = token_file
  and+ node_id = node_id
  and+ show = show in
  let save path json =
    mkdir_p (Filename.dirname path);
    let oc = open_out path in
    Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      output_string oc (Yojson.Safe.pretty_to_string json);
      output_char oc '\n')
  in
  let path = relay_config_path () in
  if show then begin
    let cfg = load_relay_config () in
    print_endline (Yojson.Safe.pretty_to_string cfg);
    exit 0
  end;
  let token_final =
    match token with
    | Some _ as v -> v
    | None ->
        (match token_file with
         | Some f -> (try Some (read_file_trimmed f) with _ -> None)
         | None -> None)
  in
  (* Merge: keep existing fields, override with provided ones. *)
  let existing = match load_relay_config () with `Assoc l -> l | _ -> [] in
  let set_field fields key = function
    | None -> fields
    | Some v ->
      (key, `String v) :: List.filter (fun (k, _) -> k <> key) fields
  in
  let merged =
    existing
    |> (fun f -> set_field f "url" url)
    |> (fun f -> set_field f "token" token_final)
    |> (fun f -> set_field f "node_id" node_id)
  in
  save path (`Assoc merged);
  Printf.printf "wrote %s\n" path;
  exit 0

let relay_status_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let+ relay_url = relay_url
  and+ token = token in
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "%s%!" relay_url_required_error;
      exit 1
  | Some url ->
      let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      let result = Lwt_main.run (Relay.Relay_client.health client) in
      print_result_and_exit result

let relay_list_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias" ] ~docv:"ALIAS"
      ~doc:"Alias to sign the /list request as (default: $(b,C2C_MCP_AUTO_REGISTER_ALIAS), \
            else the \"anon\" placeholder). Must be bound to your local identity on the \
            relay via $(b,c2c relay register --alias) $(i,ALIAS).")
  in
  let dead =
    Cmdliner.Arg.(value & flag & info [ "dead" ] ~doc:"Include reserved offline aliases.")
  in
  let+ relay_url = relay_url
  and+ token = token
  and+ alias = alias
  and+ dead = dead in
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "%s%!" relay_url_required_error;
      exit 1
  | Some url ->
      let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      (* Signing alias: --alias wins, then C2C_MCP_AUTO_REGISTER_ALIAS, else the
         "anon" placeholder (kept so dev-mode relays without auth still answer;
         prod relays reject it — print_result_and_exit renders the fix). *)
      let alias_source = match alias, env_auto_alias () with
        | Some a, _ -> Relay_client_hints.Explicit a
        | None, Some a -> Relay_client_hints.Explicit a
        | None, None -> Relay_client_hints.Anon_fallback
      in
      let signing_alias = match alias_source with
        | Relay_client_hints.Explicit a -> a
        | Relay_client_hints.Anon_fallback -> "anon"
      in
      let result = (match Relay_identity.load () with
        | Ok id when not dead ->
            (* /list (no include_dead) is a peer route: requires Ed25519 in prod mode *)
            let auth = Relay_signed_ops.sign_request id ~alias:signing_alias ~meth:"GET" ~path:"/list" ~body_str:"" () in
            Lwt_main.run (Relay.Relay_client.list_peers_signed client ~auth_header:auth ())
        | _ ->
            (* /list?include_dead=1 is an admin route (Bearer only); also fallback when no identity *)
            Lwt_main.run (Relay.Relay_client.list_peers client ~include_dead:dead ())) in
      print_result_and_exit ~alias_source result

(* --- shared relay peer fetch for `c2c list --relay` (B097) ---------------------

   Mirrors relay_list_cmd's URL/token/alias resolution and signing, but is
   non-fatal: it returns a result variant instead of calling exit, so `c2c list`
   can degrade gracefully (local peers + one-line note) when the relay is
   unconfigured, unreachable, or rejects the request. Never raises.

   - [Relay_no_config]: no relay URL resolved from --relay-url / C2C_RELAY_URL /
     saved `c2c relay setup` config, and none was forced.
   - [Relay_peers peers]: the relay answered {"ok":true,"peers":[...]} (peers may
     be empty). [peers] is the raw list of RegistrationLease JSON objects.
   - [Relay_error note]: a short human-readable note for the failure (network,
     timeout, auth, ok=false, or unexpected response shape). Surfaced as a
     one-line stderr note by the caller.

   Relay inclusion in `c2c list` is OPT-IN via --relay, so the default listing
   never touches the network (no regression for tests / offline / high-frequency
   swarm wake ticks). See docs/reference/scopes.md. *)
type relay_peer_fetch =
  | Relay_no_config
  | Relay_peers of Yojson.Safe.t list
  | Relay_error of string

let fetch_relay_peers_for_list ~timeout ?relay_url ?token ?alias () =
  match resolve_relay_url relay_url with
  | None -> Relay_no_config
  | Some url ->
      let client = Relay.Relay_client.make ?token:(resolve_relay_token token) ~timeout url in
      (* Signing alias resolution matches `c2c relay list`: --alias >
         C2C_MCP_AUTO_REGISTER_ALIAS > "anon" placeholder. Prod relays reject
         the anon placeholder; the failure is surfaced as Relay_error with the
         fix-it hint rendered by Relay_client_hints in the note. *)
      let alias_source = match alias, env_auto_alias () with
        | Some a, _ -> Relay_client_hints.Explicit a
        | None, Some a -> Relay_client_hints.Explicit a
        | None, None -> Relay_client_hints.Anon_fallback
      in
      let signing_alias = match alias_source with
        | Relay_client_hints.Explicit a -> a
        | Relay_client_hints.Anon_fallback -> "anon"
      in
      let parse resp =
        match resp with
        | `Assoc fs ->
            (match List.assoc_opt "ok" fs with
             | Some (`Bool true) ->
                 (match List.assoc_opt "peers" fs with
                  | Some (`List peers) -> Relay_peers peers
                  | _ -> Relay_error "relay list response missing 'peers' array")
             | _ ->
                 let detail = match List.assoc_opt "error" fs with
                   | Some (`String e) -> e
                   | _ -> "relay rejected the list request"
                 in
                 let hint =
                   match Relay_client_hints.hint_for_response ~alias_source resp with
                   | Some h -> "\n" ^ h
                   | None -> ""
                 in
                 Relay_error (Printf.sprintf "%s: %s%s" url detail hint))
        | _ -> Relay_error "relay list response was not a JSON object"
      in
      try
        let resp = match Relay_identity.load () with
          | Ok id ->
              (* /list (live peers only) is a peer route: requires Ed25519 auth
                 in prod mode. We do not request include_dead here because that
                 is a Bearer-only admin route and `c2c list` is a peer context. *)
              let auth = Relay_signed_ops.sign_request id ~alias:signing_alias
                ~meth:"GET" ~path:"/list" ~body_str:"" () in
              Lwt_main.run (Relay.Relay_client.list_peers_signed client ~auth_header:auth ())
          | Error _ ->
              Lwt_main.run (Relay.Relay_client.list_peers client ())
        in
        parse resp
      with
      | Failure msg ->
          (* cohttp/network failures and the request_timeout land here. *)
          Relay_error (Printf.sprintf "%s (%s)" url msg)
      | e ->
          Relay_error (Printf.sprintf "%s (%s)" url (Printexc.to_string e))

let relay_rooms_cmd =
  let subcmd =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"list|join|leave|send|history|invite|uninvite|set-visibility|set-history-public" ~doc:"Rooms subcommand.")
  in
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let room =
    Cmdliner.Arg.(value & opt (some string) None & info [ "room" ] ~docv:"ROOM" ~doc:"Room id (required for history).")
  in
  let limit =
    Cmdliner.Arg.(value & opt int 50 & info [ "limit" ] ~docv:"N" ~doc:"Max messages for history (default 50).")
  in
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias" ] ~docv:"ALIAS" ~doc:"Alias (required for join/leave/send/invite/uninvite; optional for history, required there for gated/private rooms).")
  in
  let invitee_pk =
    Cmdliner.Arg.(value & opt (some string) None & info [ "invitee-pk" ] ~docv:"PK" ~doc:"Base64url invitee identity public key (required for invite/uninvite).")
  in
  let visibility =
    Cmdliner.Arg.(value & opt (some string) None & info [ "visibility" ] ~docv:"public|unlisted|gated|private" ~doc:"Room visibility: 'public' (listed + open join), 'unlisted' (unlisted + open join), 'gated' (listed + invite-gated join), or 'private' (unlisted + invite-gated join). Required for set-visibility; optional for join, where it applies only when the join creates the room.")
  in
  let history_public =
    Cmdliner.Arg.(value & opt (some string) None & info [ "history-public" ] ~docv:"true|false" ~doc:"History readability policy for 'set-history-public': 'true' allows anonymous room-history reads on a public/unlisted room, 'false' makes it member-only. Rejected for gated/private rooms (always member-only).")
  in
  let words =
    Cmdliner.Arg.(value & pos_right 0 string [] & info [] ~docv:"WORDS" ~doc:"Message body for 'send' (joined with spaces).")
  in
  let canonical_visibility_for_sig v =
    match Relay.canonical_visibility v with
    | Some v -> v
    | None -> v
  in
  let+ subcmd = subcmd
  and+ relay_url = relay_url
  and+ token = token
  and+ room = room
  and+ limit = limit
  and+ alias = alias
  and+ invitee_pk = invitee_pk
  and+ visibility = visibility
  and+ history_public = history_public
  and+ words = words in
  match subcmd with
  | "join" | "leave" ->
      let sign_ctx = if subcmd = "join" then Relay.room_join_sign_ctx
                     else Relay.room_leave_sign_ctx in
      (match resolve_relay_url relay_url, room, alias with
       | None, _, _ ->
           Printf.eprintf "%s%!" relay_url_required_error;
           exit 1
       | _, None, _ ->
           Printf.eprintf "error: --room required for 'rooms %s'.\n%!" subcmd;
           exit 1
       | _, _, None ->
           Printf.eprintf "error: --alias required for 'rooms %s'.\n%!" subcmd;
           exit 1
       | Some url, Some room_id, Some alias ->
           let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
           (* --visibility is only meaningful for 'join', where it applies if
              the join creates the room. 'leave' ignores it. *)
           (* B114: always sign — the relay rejects unsigned room ops. *)
           let id = load_or_create_client_identity ~alias_hint:alias in
           let result =
             if subcmd = "join" then
               let p =
                 match visibility with
                 | None ->
                     Relay_signed_ops.sign_room_op id ~ctx:sign_ctx ~room_id ~alias
                 | Some visibility_val ->
                     Relay_signed_ops.sign_room_op_with_visibility id
                       ~ctx:sign_ctx ~room_id ~alias
                       ~visibility:(canonical_visibility_for_sig visibility_val)
               in
               Lwt_main.run (Relay.Relay_client.join_room_signed client
                 ?visibility ~alias ~room_id
                 ~identity_pk:p.Relay_signed_ops.identity_pk_b64
                 ~ts:p.Relay_signed_ops.ts ~nonce:p.Relay_signed_ops.nonce
                 ~sig_:p.Relay_signed_ops.sig_b64)
             else
               let p = Relay_signed_ops.sign_room_op id ~ctx:sign_ctx ~room_id ~alias in
               Lwt_main.run (Relay.Relay_client.leave_room_signed client
                 ~alias ~room_id
                 ~identity_pk:p.Relay_signed_ops.identity_pk_b64
                 ~ts:p.Relay_signed_ops.ts ~nonce:p.Relay_signed_ops.nonce
                 ~sig_:p.Relay_signed_ops.sig_b64)
           in
           print_result_and_exit ~alias_source:(Relay_client_hints.Explicit alias) result)
  | "send" ->
      (match resolve_relay_url relay_url, room, alias, words with
       | None, _, _, _ ->
           Printf.eprintf "%s%!" relay_url_required_error;
           exit 1
       | _, None, _, _ ->
           Printf.eprintf "error: --room required for 'rooms send'.\n%!";
           exit 1
       | _, _, None, _ ->
           Printf.eprintf "error: --alias required for 'rooms send'.\n%!";
           exit 1
       | _, _, _, [] ->
           Printf.eprintf "error: message body required for 'rooms send'.\n%!";
           exit 1
       | Some url, Some room_id, Some from_alias, ws ->
           let content = String.concat " " ws in
           let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
           (* B114: always send a signed envelope — the relay rejects
              envelope-less sends. *)
           let id = load_or_create_client_identity ~alias_hint:from_alias in
           let result =
             let envelope =
               Relay_signed_ops.sign_send_room id
                 ~room_id ~from_alias ~content
             in
             Lwt_main.run
               (Relay.Relay_client.send_room_signed client
                  ~from_alias ~room_id ~content ~envelope ())
           in
           print_result_and_exit ~alias_source:(Relay_client_hints.Explicit from_alias) result)
  | "history" ->
      (match resolve_relay_url relay_url, room with
       | None, _ ->
           Printf.eprintf "%s%!" relay_url_required_error;
           exit 1
       | _, None ->
           Printf.eprintf "error: --room required for 'rooms history'.\n%!";
           exit 1
       | Some url, Some room_id ->
           let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
           let result =
             match Relay_identity.load (), alias with
             | Ok id, Some alias ->
                 let body =
                   `Assoc
                     [ ("room_id", `String room_id)
                     ; ("limit", `Int limit)
                     ]
                 in
                 let auth =
                   Relay_signed_ops.sign_request id ~alias ~meth:"POST"
                     ~path:"/room_history"
                     ~body_str:(Yojson.Safe.to_string body) ()
                 in
                 Lwt_main.run
                   (Relay.Relay_client.room_history_signed client ~room_id ~limit
                      ~auth_header:auth ())
             | _ ->
                 Lwt_main.run
                   (Relay.Relay_client.room_history client ~room_id ~limit ())
           in
           (* L4/3 client verify: annotate each history entry with sig_ok. *)
           let annotate entry =
             match entry with
             | `Assoc fs ->
                 (match List.assoc_opt "envelope" fs with
                  | Some env ->
                      let get_s k = match List.assoc_opt k fs with
                        | Some (`String s) -> Some s | _ -> None in
                      (match get_s "room_id", get_s "from_alias", get_s "content" with
                       | Some r, Some fa, Some c ->
                           let ok = match Relay_signed_ops.verify_history_envelope
                             ~room_id:r ~from_alias:fa ~content:c env with
                             | Ok () -> `Bool true
                             | Error _ -> `Bool false in
                           `Assoc (("sig_ok", ok) :: fs)
                       | _ -> `Assoc (("sig_ok", `Null) :: fs))
                  | None -> `Assoc (("sig_ok", `Null) :: fs))
             | other -> other
           in
           let annotated = match result with
             | `Assoc fs ->
                 let fs' = List.map (fun (k, v) ->
                   if k = "history" then
                     match v with
                     | `List items -> (k, `List (List.map annotate items))
                     | other -> (k, other)
                   else (k, v)) fs in
                 `Assoc fs'
             | other -> other
           in
           let alias_source =
             Option.map (fun a -> Relay_client_hints.Explicit a) alias
           in
           print_result_and_exit ?alias_source annotated)
  | "list" ->
      (match resolve_relay_url relay_url with
       | None ->
           Printf.eprintf "%s%!" relay_url_required_error;
           exit 1
       | Some url ->
           let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
           let result = Lwt_main.run (Relay.Relay_client.list_rooms client) in
           print_result_and_exit result)
  | "invite" | "uninvite" ->
      (match resolve_relay_url relay_url, room, alias, invitee_pk with
       | None, _, _, _ ->
           Printf.eprintf "%s%!" relay_url_required_error;
           exit 1
       | _, None, _, _ ->
           Printf.eprintf "error: --room required for 'rooms %s'.\n%!" subcmd;
           exit 1
       | _, _, None, _ ->
           Printf.eprintf "error: --alias required for 'rooms %s'.\n%!" subcmd;
           exit 1
       | _, _, _, None ->
           Printf.eprintf "error: --invitee-pk required for 'rooms %s'.\n%!" subcmd;
           exit 1
       | Some url, Some room_id, Some from_alias, Some invitee_pk_val ->
           let sign_ctx = if subcmd = "invite" then Relay.room_invite_sign_ctx
                          else Relay.room_uninvite_sign_ctx in
           let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
           (* B114: always sign — the relay rejects unsigned room ops. The
              invitee_pk (target) is authorization-relevant and must be bound
              into the signature (review finding 2), so use the target-key
              signer rather than the plain room-op signer. *)
           let id = load_or_create_client_identity ~alias_hint:from_alias in
           let result =
             let p = Relay_signed_ops.sign_room_op_with_target_pk id
                       ~ctx:sign_ctx ~room_id ~alias:from_alias
                       ~target_pk:invitee_pk_val in
             let fn = if subcmd = "invite"
                      then Relay.Relay_client.invite_room_signed
                      else Relay.Relay_client.uninvite_room_signed in
             Lwt_main.run (fn client ~alias:from_alias ~room_id ~invitee_pk:invitee_pk_val
               ~identity_pk:p.Relay_signed_ops.identity_pk_b64
               ~ts:p.Relay_signed_ops.ts ~nonce:p.Relay_signed_ops.nonce
               ~sig_:p.Relay_signed_ops.sig_b64)
           in
           print_result_and_exit ~alias_source:(Relay_client_hints.Explicit from_alias) result)
  | "set-visibility" ->
      (match resolve_relay_url relay_url, room, alias, visibility with
       | None, _, _, _ ->
           Printf.eprintf "%s%!" relay_url_required_error;
           exit 1
       | _, None, _, _ ->
           Printf.eprintf "error: --room required for 'rooms set-visibility'.\n%!";
           exit 1
       | _, _, None, _ ->
           Printf.eprintf "error: --alias required for 'rooms set-visibility'.\n%!";
           exit 1
       | _, _, _, None ->
           Printf.eprintf "error: --visibility required for 'rooms set-visibility'.\n%!";
           exit 1
       | Some url, Some room_id, Some alias, Some visibility_val ->
           let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
           (* B114: the relay requires the caller be a room member AND a
              signed proof — always sign. *)
           let id = load_or_create_client_identity ~alias_hint:alias in
           let result =
             let p = Relay_signed_ops.sign_room_op_with_visibility id
                       ~ctx:Relay.room_set_visibility_sign_ctx ~room_id ~alias
                       ~visibility:(canonical_visibility_for_sig visibility_val) in
             Lwt_main.run (Relay.Relay_client.set_room_visibility_signed client
               ~alias ~room_id ~visibility:visibility_val
               ~identity_pk:p.Relay_signed_ops.identity_pk_b64
               ~ts:p.Relay_signed_ops.ts ~nonce:p.Relay_signed_ops.nonce
               ~sig_:p.Relay_signed_ops.sig_b64)
           in
           print_result_and_exit ~alias_source:(Relay_client_hints.Explicit alias) result)
  | "set-history-public" ->
      let parsed_hp = match history_public with
        | Some v ->
            (match String.lowercase_ascii (String.trim v) with
             | "true" | "1" | "yes" | "on" -> Some true
             | "false" | "0" | "no" | "off" -> Some false
             | _ -> None)
        | None -> None
      in
      (match resolve_relay_url relay_url, room, alias, history_public, parsed_hp with
       | None, _, _, _, _ ->
           Printf.eprintf "%s%!" relay_url_required_error;
           exit 1
       | _, None, _, _, _ ->
           Printf.eprintf "error: --room required for 'rooms set-history-public'.\n%!";
           exit 1
       | _, _, None, _, _ ->
           Printf.eprintf "error: --alias required for 'rooms set-history-public'.\n%!";
           exit 1
       | _, _, _, None, _ ->
           Printf.eprintf "error: --history-public true|false required for 'rooms set-history-public'.\n%!";
           exit 1
       | _, _, _, Some _, None ->
           Printf.eprintf "error: --history-public must be 'true' or 'false'.\n%!";
           exit 1
       | Some url, Some room_id, Some alias, Some _, Some hp ->
           let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
           (* The relay requires the caller be a room member AND a signed proof
              whose signature covers the boolean — always sign. *)
           let id = load_or_create_client_identity ~alias_hint:alias in
           let result =
             let p = Relay_signed_ops.sign_room_op_with_history_public id
                       ~ctx:Relay.room_set_history_public_sign_ctx ~room_id ~alias
                       ~history_public:hp in
             Lwt_main.run (Relay.Relay_client.set_room_history_public_signed client
               ~alias ~room_id ~history_public:hp
               ~identity_pk:p.Relay_signed_ops.identity_pk_b64
               ~ts:p.Relay_signed_ops.ts ~nonce:p.Relay_signed_ops.nonce
               ~sig_:p.Relay_signed_ops.sig_b64)
           in
           print_result_and_exit ~alias_source:(Relay_client_hints.Explicit alias) result)
  | _ ->
      Printf.eprintf "error: unknown rooms subcommand '%s'\n%!" subcmd;
      exit 1

(* c2c relay register — bind Ed25519 identity on the relay (§8.2) *)
let relay_register_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let alias =
    Cmdliner.Arg.(required & opt (some string) None & info [ "alias" ] ~docv:"ALIAS" ~doc:"Alias to register.")
  in
  let+ relay_url = relay_url and+ token = token and+ alias = alias in
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "%s%!" relay_url_required_error;
      exit 1
  | Some url ->
      (* B114: register with the same identity the signed room ops use
         (C2C_RELAY_IDENTITY_PATH override, else the default path), creating
         it if absent — otherwise the register-time binding and subsequent
         room-op proofs can come from different keys, and every later signed
         room op fails with alias_identity_mismatch. *)
      let id = load_or_create_client_identity ~alias_hint:alias in
      let result =
        Lwt_main.run
          (register_alias_signed ~url ?token:(resolve_relay_token token)
             ~alias ~identity:id ())
      in
      (* No ~alias_source: register IS the binding-establishment command, so
         hinting "run c2c relay register" at a failing register is circular. *)
      print_result_and_exit result

(* c2c relay dm — cross-host direct messages (§8.3) *)
let relay_dm_cmd =
  let subcmd =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"send|poll|peek|send-all" ~doc:"DM subcommand: send, poll (drain), peek (non-destructive read, B096), or send-all (broadcast 1:N).")
  in
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias" ] ~docv:"ALIAS" ~doc:"Your alias (required for poll, peek, and send-all).")
  in
  let words =
    Cmdliner.Arg.(value & pos_right 0 string [] & info [] ~docv:"WORDS" ~doc:"For send: <to-alias> <message...>; for send-all: <message...>")
  in
  let+ subcmd = subcmd and+ relay_url = relay_url and+ token = token
  and+ alias = alias and+ words = words in
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "%s%!" relay_url_required_error;
      exit 1
  | Some url ->
      let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      (match subcmd with
       | "send" ->
           (match words with
            | [] | [_] ->
                Printf.eprintf "error: usage: dm send <to-alias> <message...>\n%!";
                exit 1
            | to_alias :: msg_words ->
                let from_alias = match alias with
                  | Some a -> a
                  | None ->
                      Printf.eprintf "error: --alias required for dm send\n%!";
                      exit 1
                in
                let content = String.concat " " msg_words in
                (* B045: Substitution check removed from relay/programmatic paths.
                   Body is data, never eval'd by a shell. The local CLI retains
                   a stderr-only informational hint for human operators. *)
                let body_str = Yojson.Safe.to_string (`Assoc [
                  ("from_alias", `String from_alias);
                  ("to_alias", `String to_alias);
                  ("content", `String content);
                ]) in
                let result = (match Relay_identity.load () with
                  | Ok id ->
                      let auth = Relay_signed_ops.sign_request id ~alias:from_alias
                        ~meth:"POST" ~path:"/send" ~body_str () in
                      Lwt_main.run (Relay.Relay_client.send_signed client
                        ~from_alias ~to_alias ~content ~auth_header:auth ())
                  | Error _ ->
                      Lwt_main.run (Relay.Relay_client.send client
                        ~from_alias ~to_alias ~content ())) in
                (* J2: a relay ACK means the relay accepted the message —
                   emit the canonical schema-v1 shape (delivery.state
                   "accepted", source "relay") with the legacy ack keys
                   (ok/ts/duplicate) preserved; errors pass through raw. *)
                let result =
                  C2c_utils.adapt_relay_dm_send_result ~from_alias ~to_alias
                    ~content result
                in
                print_result_and_exit
                  ~alias_source:(Relay_client_hints.Explicit from_alias) result)
       | "poll" ->
           let from_alias = match alias with
             | Some a -> a
             | None ->
                 Printf.eprintf "error: --alias required for dm poll\n%!";
                 exit 1
           in
           let node_id = Printf.sprintf "cli-%s" from_alias in
           let body_str = Yojson.Safe.to_string (`Assoc [
             ("node_id", `String node_id);
             ("session_id", `String node_id);
           ]) in
           let result = (match Relay_identity.load () with
             | Ok id ->
                 let auth = Relay_signed_ops.sign_request id ~alias:from_alias
                   ~meth:"POST" ~path:"/poll_inbox" ~body_str () in
                 Lwt_main.run (Relay.Relay_client.poll_inbox_signed client
                   ~node_id ~session_id:node_id ~auth_header:auth)
             | Error _ ->
                 Lwt_main.run (Relay.Relay_client.poll_inbox client
                   ~node_id ~session_id:node_id)) in
           (* J2: drained relay rows were delivered to this caller —
              schema-v1 rows (delivery.state "delivered", source "relay")
              with legacy row keys preserved; empty batches keep the
              exact legacy shape. *)
           let result =
             C2c_utils.adapt_relay_dm_inbox_result
               ~delivery_state:C2c_schema_v1.Delivered result
           in
           print_result_and_exit
             ~alias_source:(Relay_client_hints.Explicit from_alias) result
       | "peek" ->
           (* B096: non-destructive variant of poll — reads pending DMs
              WITHOUT draining the inbox, so a relay-aware monitor (B089)
              can tail without stealing messages from the poll consumer.
              Signs against /peek_inbox; the server route already exists.
              B115: the relay now requires the signed request's alias to
              own the node/session for both /poll_inbox and /peek_inbox —
              by default even on tokenless relays; this signed path
              satisfies that. The unsigned fallback below only works
              against a tokenless dev relay that also sets the explicit
              C2C_RELAY_ALLOW_UNSIGNED_INBOX=1 gate. *)
           let from_alias = match alias with
             | Some a -> a
             | None ->
                 Printf.eprintf "error: --alias required for dm peek\n%!";
                 exit 1
           in
           let node_id = Printf.sprintf "cli-%s" from_alias in
           let body_str = Yojson.Safe.to_string (`Assoc [
             ("node_id", `String node_id);
             ("session_id", `String node_id);
           ]) in
           let result = (match Relay_identity.load () with
             | Ok id ->
                 let auth = Relay_signed_ops.sign_request id ~alias:from_alias
                   ~meth:"POST" ~path:"/peek_inbox" ~body_str () in
                 Lwt_main.run (Relay.Relay_client.peek_inbox_signed client
                   ~node_id ~session_id:node_id ~auth_header:auth)
             | Error _ ->
                 Lwt_main.run (Relay.Relay_client.peek_inbox client
                   ~node_id ~session_id:node_id)) in
           (* J2: peeked relay rows are NOT drained — schema-v1 rows with
              delivery.state "queued", source "relay"; legacy row keys
              preserved. *)
           let result =
             C2c_utils.adapt_relay_dm_inbox_result
               ~delivery_state:C2c_schema_v1.Queued result
           in
           print_result_and_exit
             ~alias_source:(Relay_client_hints.Explicit from_alias) result
       | "send-all" ->
           (* Broadcast (1:N) — POST /send_all with Ed25519 auth header.
              Used by relay smoke tests (gap D) to verify the broadcast
              fan-out path on the deployed relay. Loopback: with a single
              registered alias, sender's own message lands in their inbox
              (when send_all does NOT exclude the sender), or skipped (when
              it does). The smoke script asserts on relay's `ok` ack +
              archive material; semantic of self-loopback is whatever the
              relay's send_all implementation decides — tested empirically. *)
           (match words with
            | [] ->
                Printf.eprintf "error: usage: dm send-all <message...>\n%!";
                exit 1
            | msg_words ->
                let from_alias = match alias with
                  | Some a -> a
                  | None ->
                      Printf.eprintf "error: --alias required for dm send-all\n%!";
                      exit 1
                in
                let content = String.concat " " msg_words in
                (* B045: Substitution check removed from relay/programmatic paths.
                   Body is data, never eval'd by a shell. *)
                let body = `Assoc [
                  ("from_alias", `String from_alias);
                  ("content", `String content);
                ] in
                let body_str = Yojson.Safe.to_string body in
                let result = (match Relay_identity.load () with
                  | Ok id ->
                      let auth = Relay_signed_ops.sign_request id ~alias:from_alias
                        ~meth:"POST" ~path:"/send_all" ~body_str () in
                      Lwt_main.run (Relay.Relay_client.request client
                        ~meth:`POST ~path:"/send_all" ~body
                        ~auth_override:auth ())
                  | Error _ ->
                      Lwt_main.run (Relay.Relay_client.request client
                        ~meth:`POST ~path:"/send_all" ~body ())) in
                print_result_and_exit
                  ~alias_source:(Relay_client_hints.Explicit from_alias) result)
       | other ->
           Printf.eprintf "error: unknown dm subcommand: %s\n%!" other;
           exit 1)

(* c2c relay mobile-pair — Issue a mobile pairing token via QR code flow (§S5a) *)
let relay_mobile_pair_cmd =
  let subcmd =
    Cmdliner.Arg.(required & pos 0 (some string) None & info []
       ~docv:"prepare|confirm|revoke" ~doc:"Mobile-pair subcommand: prepare issues a pairing token; confirm completes binding; revoke deletes a binding.")
  in
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ]
       ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ]
       ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let binding_id =
    Cmdliner.Arg.(value & opt (some string) None & info [ "binding-id" ]
       ~docv:"ID" ~doc:"Binding ID (for confirm).")
  in
  let phone_ed_pk =
    Cmdliner.Arg.(value & opt (some string) None & info [ "phone-ed-pk" ]
       ~docv:"B64" ~doc:"Phone Ed25519 pubkey base64url (for confirm).")
  in
  let phone_x_pk =
    Cmdliner.Arg.(value & opt (some string) None & info [ "phone-x-pk" ]
       ~docv:"B64" ~doc:"Phone X25519 pubkey base64url (for confirm).")
  in
  let ttl =
    Cmdliner.Arg.(value & opt (some float) None & info [ "ttl" ]
       ~docv:"SECONDS" ~doc:"Token TTL in seconds (default: 300, max: 300).")
  in
  let user_code =
    Cmdliner.Arg.(value & opt (some string) None & info [ "user-code" ]
       ~docv:"CODE" ~doc:"User code from device-pair init (for claim).")
  in
  let+ subcmd = subcmd
  and+ relay_url = relay_url
  and+ token = token
  and+ binding_id = binding_id
  and+ phone_ed_pk = phone_ed_pk
  and+ phone_x_pk = phone_x_pk
  and+ ttl = ttl
  and+ user_code = user_code
  and+ json = json_flag in
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "%s%!" relay_url_required_error;
      exit 1
  | Some url ->
      let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      match subcmd with
      | "prepare" ->
          (match Relay_identity.load () with
           | Error _ ->
               Printf.eprintf "error: no identity.json found. Run 'c2c relay identity init' first.\n%!";
               exit 1
           | Ok id ->
               let bid = match binding_id with
                 | Some b -> b
                 | None -> Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ())
               in
               let now = Unix.gettimeofday () in
               let ttl_val = match ttl with Some t -> t | None -> 300.0 in
               let ttl_val = min ttl_val 300.0 in
               let issued_at = now in
               let expires_at = issued_at +. ttl_val in
               let nonce = Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ()) in
               let machine_pk_b64 =
                 Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet id.Relay_identity.public_key
               in
               let blob = Relay_identity.canonical_msg ~ctx:Relay.mobile_pair_token_sign_ctx
                 [ bid; machine_pk_b64; string_of_float issued_at;
                   string_of_float expires_at; nonce ]
               in
               let sig_ = Relay_identity.sign id blob in
               let sig_b64 =
                 Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet sig_
               in
               let token_json = `Assoc [
                 "binding_id", `String bid;
                 "machine_ed25519_pubkey", `String machine_pk_b64;
                 "issued_at", `Float issued_at;
                 "expires_at", `Float expires_at;
                 "nonce", `String nonce;
                 "sig", `String sig_b64;
               ] in
               let token_b64 =
                 Yojson.Safe.to_string token_json |>
                 Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
               in
               let result = Lwt_main.run
                 (Relay.Relay_client.mobile_pair_prepare client
                    ~machine_ed25519_pubkey:machine_pk_b64 ~token:token_b64)
               in
                if json then print_endline (Yojson.Safe.pretty_to_string result)
                else (
                  match List.assoc_opt "binding_id" (Yojson.Safe.Util.to_assoc result) with
                  | Some (`String bid) ->
                      let broker_root = resolve_broker_root () in
                      C2c_relay_connector.add_mobile_binding broker_root ~binding_id:bid;
                      Printf.printf "binding_id: %s\ntoken: %s\nnonce: %s\nttl: %.0f\n"
                        bid token_b64 nonce ttl_val;
                      Printf.printf "QR content: %s\n%!" token_b64
                  | _ -> ()
                );
                exit 0)
      | "confirm" ->
          let token_val = match token with Some t -> t | None -> "" in
          let ed_pk = phone_ed_pk in
          let x_pk = phone_x_pk in
          if ed_pk = None then (Printf.eprintf "error: --phone-ed-pk required for confirm.\n%!"; exit 1);
          if x_pk = None then (Printf.eprintf "error: --phone-x-pk required for confirm.\n%!"; exit 1);
          let ed_pk = Option.get ed_pk in
          let x_pk = Option.get x_pk in
          let result = Lwt_main.run
            (Relay.Relay_client.mobile_pair_confirm client
               ~token:token_val ~phone_ed25519_pubkey:ed_pk ~phone_x25519_pubkey:x_pk)
          in
          print_result_and_exit result
      | "revoke" ->
          let bid = binding_id in
          if bid = None then (Printf.eprintf "error: --binding-id required for revoke.\n%!"; exit 1);
          let bid = Option.get bid in
          (* B116: revocation requires a proof signed by the machine
             identity that created the binding (the phone key can also
             revoke, from the phone side). *)
          (match Relay_identity.load () with
           | Error _ ->
               Printf.eprintf
                 "error: no identity.json found. Binding revocation requires the machine identity that created the binding — run 'c2c relay identity init' first.\n%!";
               exit 1
           | Ok id ->
               let proof = Relay_signed_ops.sign_binding_revoke id ~binding_id:bid in
               let result = Lwt_main.run
                 (Relay.Relay_client.mobile_pair_revoke client ~binding_id:bid
                    ~revoke_pk:proof.Relay_signed_ops.identity_pk_b64
                    ~ts:proof.Relay_signed_ops.ts
                    ~nonce:proof.Relay_signed_ops.nonce
                    ~sig_b64:proof.Relay_signed_ops.sig_b64)
               in
               print_result_and_exit result)
      | "init" ->
          (match Relay_identity.load () with
           | Error _ ->
               Printf.eprintf "error: no identity.json found. Run 'c2c relay identity init' first.\n%!";
               exit 1
           | Ok id ->
               let machine_pk_b64 =
                 Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet id.Relay_identity.public_key
               in
               let result = Lwt_main.run
                 (Relay.Relay_client.device_pair_init client ~machine_ed25519_pubkey:machine_pk_b64)
               in
               if json then print_endline (Yojson.Safe.pretty_to_string result)
               else (
                 match List.assoc_opt "user_code" (Yojson.Safe.Util.to_assoc result) with
                 | Some (`String uc) ->
                     let poll_interval = match List.assoc_opt "poll_interval" (Yojson.Safe.Util.to_assoc result) with
                       | Some (`Float f) -> Printf.sprintf "%.0f" f | _ -> "2" in
                     let expires_at = match List.assoc_opt "expires_at" (Yojson.Safe.Util.to_assoc result) with
                       | Some (`Float f) -> Printf.sprintf "%.0f" f | _ -> "0" in
                     Printf.printf "user_code: %s\npoll_interval: %ss\nexpires_at: %s\n" uc poll_interval expires_at;
                     Printf.eprintf "Enter this code on your phone at the relay URL.\n%!"
                 | _ -> ()
               );
               exit 0)
      | "claim" ->
          (match user_code with
           | None ->
               Printf.eprintf "error: --user-code required for claim.\n%!";
               exit 1
           | Some uc ->
               let rec poll_loop () =
                 let result = Lwt_main.run
                   (Relay.Relay_client.device_pair_poll client ~user_code:uc)
                 in
                 let status = match List.assoc_opt "status" (Yojson.Safe.Util.to_assoc result) with
                   | Some (`String s) -> s | _ -> "" in
                 if status = "claimed" then
                   (if json then print_endline (Yojson.Safe.pretty_to_string result)
                    else (
                      match List.assoc_opt "binding_id" (Yojson.Safe.Util.to_assoc result) with
                      | Some (`String bid) ->
                          Printf.printf "Pairing complete! binding_id: %s\n%!" bid
                      | _ -> Printf.eprintf "Pairing complete.\n%!"
                    );
                    exit 0)
                 else
                   (if not json then Printf.eprintf "Waiting... status: %s\n%!" status;
                    let () = ignore (Lwt_main.run (Lwt_unix.sleep 2.0)) in
                    poll_loop ())
               in
               poll_loop ())
      | other ->
          Printf.eprintf "error: unknown mobile-pair subcommand: %s (use prepare, confirm, revoke, init, or claim)\n%!" other;
          exit 1

(* c2c relay subscribe — WebSocket push subscription for DMs (slice 2) *)
let relay_subscribe_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let alias =
    Cmdliner.Arg.(required & opt (some string) None & info [ "alias" ] ~docv:"ALIAS" ~doc:"Your alias to subscribe as.")
  in
  let+ relay_url = relay_url
  and+ alias = alias in
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "%s%!" relay_url_required_error;
      exit 1
  | Some url ->
      (* Scheme support is decided by Relay_doctor.subscribe_url_supported — the
         SAME predicate `c2c doctor --relay`'s capability matrix consults — so
         the advertised `subscribe` capability always matches this actual
         attempt (B090/B093 actual-attempt parity). B189: wss/https are supported
         via Relay_ws_client. *)
      if not (Relay_doctor.subscribe_url_supported url) then begin
        Printf.eprintf
          "error: c2c relay subscribe does not support this relay URL scheme.\n\
           hint: use http(s):// or ws(s):// (e.g. https://relay.c2c.im), or poll DMs via `c2c relay dm --alias <you> poll`.\n\
           note: run `c2c doctor --relay` for the live capability matrix.\n%!";
        exit 1
      end;
      (* Load identity for signing *)
      match Relay_identity.load () with
      | Error msg ->
          Printf.eprintf "error: cannot load identity.json: %s\n%!" msg;
          Printf.eprintf "Run 'c2c relay identity init' first.\n%!";
          exit 1
      | Ok id ->
          let endpoint = Relay_ws_client.parse_endpoint url in
          let scheme = if endpoint.Relay_ws_client.use_tls then "wss" else "ws" in
          Printf.eprintf "[relay subscribe] connecting to %s://%s:%d as %s...\n%!"
            scheme endpoint.Relay_ws_client.host endpoint.Relay_ws_client.port alias;
          let open Lwt.Infix in
          let run =
            Lwt.catch
              (fun () ->
                 Relay_ws_client.connect_subscribe ~endpoint ~alias ~identity:id ()
                 >>= fun (session, close) ->
                 Printf.eprintf "[relay subscribe] WebSocket connected. Listening for DMs...\n%!";
                 let rec loop () =
                   Lwt.catch
                     (fun () ->
                        Relay_ws_frame.Client_session.recv session >>= fun msg ->
                        match msg with
                        | Some (`Text payload) ->
                            print_endline payload;
                            flush stdout;
                            loop ()
                        | Some (`Ping) ->
                            (* Client_session.recv already answered with a masked pong. *)
                            loop ()
                        | Some `Pong -> loop ()
                        | Some (`Close (code, reason)) ->
                            Printf.eprintf
                              "[relay subscribe] connection closed: code=%d reason=%s\n%!"
                              code reason;
                            Lwt.return 0
                        | Some (`Binary _) -> loop ()
                        | None -> loop ())
                     (fun e ->
                        Printf.eprintf "[relay subscribe] error: %s\n%!"
                          (Printexc.to_string e);
                        Lwt.return 1)
                 in
                 Lwt.finalize loop close)
              (fun e ->
                 Printf.eprintf "error: %s\n%!" (Printexc.to_string e);
                 Lwt.return 1)
          in
          exit (Lwt_main.run run)

let relay_gc_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let interval =
    Cmdliner.Arg.(value & opt (some int) None & info [ "interval" ] ~docv:"SECONDS" ~doc:"GC interval in seconds.")
  in
  let once =
    Cmdliner.Arg.(value & flag & info [ "once" ] ~doc:"Run once and exit.")
  in
  let verbose =
    Cmdliner.Arg.(value & flag & info [ "verbose"; "v" ] ~doc:"Enable verbose output.")
  in
  let+ relay_url = relay_url
  and+ token = token
  and+ interval = interval
  and+ once = once
  and+ verbose = verbose in
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "%s%!" relay_url_required_error;
      exit 1
  | Some url ->
      let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      let run_once () =
        let open Lwt.Infix in
        Relay.Relay_client.gc client >>= fun result ->
        if verbose || once then print_endline (Yojson.Safe.pretty_to_string result);
        let ok = match result with
          | `Assoc fields ->
              (match List.assoc_opt "ok" fields with Some (`Bool true) -> true | _ -> false)
          | _ -> false
        in
        Lwt.return ok
      in
      if once then begin
        let ok = Lwt_main.run (run_once ()) in
        exit (if ok then 0 else 1)
      end else begin
        let sleep_s = match interval with Some s -> float_of_int s | None -> 30.0 in
        let rec loop () =
          let open Lwt.Infix in
          run_once () >>= fun _ -> Lwt_unix.sleep sleep_s >>= loop
        in
        Lwt_main.run (loop ())
      end

let relay_dead_letter_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let json_flag =
    Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Output raw JSON.")
  in
  let limit =
    Cmdliner.Arg.(value & opt int 50 & info [ "limit"; "l" ] ~docv:"N" ~doc:"Max entries to display.")
  in
  let purge_flag =
    Cmdliner.Arg.(value & flag & info [ "purge" ] ~doc:"Delete all dead-letter entries after display (not yet implemented — reserved).")
  in
  let+ relay_url = relay_url
  and+ token = token
  and+ json_out = json_flag
  and+ limit = limit
  and+ purge = purge_flag in
  if purge then begin
    Printf.eprintf "error: --purge is not yet implemented\n%!";
    exit 1
  end;
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "%s%!" relay_url_required_error;
      exit 1
  | Some url ->
      let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      let result = Lwt_main.run (Relay.Relay_client.dead_letter client) in
      let ok, entries = match result with
        | `Assoc fields ->
            let ok_flag = match List.assoc_opt "ok" fields with Some (`Bool true) -> true | _ -> false in
            let entry_list = match List.assoc_opt "dead_letter" fields with
              | Some (`List l) -> l
              | _ -> []
            in
            (ok_flag, entry_list)
        | _ -> (false, [])
      in
      if not ok then begin
        let err = match result with
          | `Assoc fields -> (try List.assoc "error" fields |> Yojson.Safe.Util.to_string with _ -> "unknown error")
          | _ -> "unexpected response format"
        in
        Printf.eprintf "error: relay returned failure: %s\n%!" err;
        exit 1
      end;
      let n = List.length entries in
      let entries =
        if n <= limit then entries
        else
          let drop = n - limit in
          let rec skip i = function
            | [] -> []
            | _ :: rest when i > 0 -> skip (i - 1) rest
            | lst -> lst
          in
          skip drop entries
      in
      if json_out then
        print_endline (Yojson.Safe.to_string (`List entries))
      else if entries = [] then
        Printf.printf "(no dead-letter entries on relay)\n"
      else begin
        Printf.printf "Relay dead-letter (%d entries%s):\n\n"
          (List.length entries)
          (if n > limit then Printf.sprintf ", showing last %d of %d" limit n else "");
        List.iter (fun entry ->
          let open Yojson.Safe.Util in
          let from_a = try to_string (member "from_alias" entry) with _ -> "?" in
          let to_a = try to_string (member "to_alias" entry) with _ -> "?" in
          let reason = try to_string (member "reason" entry) with _ -> "?" in
          let ts = try to_number (member "ts" entry) with _ -> 0.0 in
          let msg_id = try to_string (member "message_id" entry) with _ -> "" in
          let content = try to_string (member "content" entry) with _ -> "" in
          let content_preview =
            if String.length content <= 80 then content
            else String.sub content 0 77 ^ "..."
          in
          let ts_str =
            let t = Unix.gmtime ts in
            Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
              (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday
              t.tm_hour t.tm_min t.tm_sec
          in
          Printf.printf "  [%s] %s → %s\n    reason: %s | id: %s\n    %s\n\n"
            ts_str from_a to_a reason msg_id content_preview)
          entries
      end

(* c2c relay poll-inbox — poll a remote relay's /remote_inbox/<session_id> endpoint.
   Used by a remote node to receive messages ferried through the relay from a remote broker. *)
let relay_poll_inbox_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let session_id =
    Cmdliner.Arg.(value & opt (some string) None & info [ "session-id" ] ~docv:"ID" ~doc:"Session ID to poll (required).")
  in
  let+ relay_url = relay_url
  and+ token = token
  and+ session_id = session_id in
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "%s%!" relay_url_required_error;
      exit 1
  | Some url ->
      let session_id = match session_id with
        | Some s -> s
        | None ->
            Printf.eprintf "error: --session-id required.\n%!";
            exit 1
      in
      let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      let path = "/remote_inbox/" ^ session_id in
      let result = Lwt_main.run (Relay.Relay_client.request client ~meth:`GET ~path ()) in
      (match result with
       | `Assoc fields ->
           (match List.assoc_opt "messages" fields with
            | Some (`List msgs) ->
                if msgs = [] then exit 0
                else begin
                  List.iter (fun msg ->
                    match msg with
                    | `Assoc msg_fields ->
                        let from_alias = match List.assoc_opt "from_alias" msg_fields with Some (`String s) -> s | _ -> "?" in
                        let content = match List.assoc_opt "content" msg_fields with Some (`String s) -> s | _ -> "" in
                        let ts = match List.assoc_opt "ts" msg_fields with Some (`Float f) -> string_of_float f | _ -> "?" in
                        Printf.printf "[%s] %s: %s\n%!" ts from_alias content
                    | _ -> ())
                    msgs;
                  exit 0
                end
            | _ ->
                Printf.eprintf "error: unexpected response shape: %s\n%!" (Yojson.Safe.to_string result);
                exit 1)
       | _ ->
           Printf.eprintf "error: unexpected response: %s\n%!" (Yojson.Safe.to_string result);
           exit 1)

(* --- relay identity (Layer 3 slice 6) ------------------------------------- *)
(* Wraps Relay_identity (ocaml/relay_identity.ml) with init/show/fingerprint
   subcommands for managing ~/.config/c2c/identity.json. See
   docs/c2c-research/relay-peer-identity-spec.md §8. *)

let relay_identity_init_cmd =
  let alias_hint =
    Cmdliner.Arg.(value & opt string "" & info [ "alias-hint" ] ~docv:"HINT"
      ~doc:"Informational alias label stored in identity.json (not authoritative).")
  in
  let path =
    Cmdliner.Arg.(value & opt (some string) None & info [ "path" ] ~docv:"PATH"
      ~doc:"Override identity file path (default: ~/.config/c2c/identity.json).")
  in
  let force =
    Cmdliner.Arg.(value & flag & info [ "force" ]
      ~doc:"Overwrite an existing identity file without prompting.")
  in
  let json = Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Emit JSON output.") in
  let+ alias_hint = alias_hint
  and+ path = path
  and+ force = force
  and+ json = json in
  let target = match path with Some p -> p | None -> Relay_identity.default_path () in
  if (not force) && Sys.file_exists target then begin
    if json then
      print_endline (Printf.sprintf
        {|{"ok":true,"exists":true,"path":%S,"hint":"pass --force to overwrite"}|}
        target)
    else
      Printf.eprintf
        "identity already exists at %s (use --force to overwrite)\n%!" target;
    exit 0
  end;
  let id = Relay_identity.generate ~alias_hint () in
  match Relay_identity.save ~path:target id with
  | Error msg ->
      if json then
        print_endline (Printf.sprintf
          {|{"ok":false,"error":%S}|} msg)
      else
        Printf.eprintf "error: %s\n%!" msg;
      exit 1
  | Ok () ->
      if json then
        print_endline (Yojson.Safe.to_string
          (`Assoc [
            "ok", `Bool true;
            "path", `String target;
            "fingerprint", `String id.fingerprint;
            "alias_hint", `String id.alias_hint;
            "created_at", `String id.created_at;
          ]))
      else begin
        Printf.printf "identity written to %s\n" target;
        Printf.printf "  fingerprint: %s\n" id.fingerprint;
        if id.alias_hint <> "" then
          Printf.printf "  alias_hint:  %s\n" id.alias_hint;
        Printf.printf "  created_at:  %s\n" id.created_at
      end

let relay_identity_show_cmd =
  let path =
    Cmdliner.Arg.(value & opt (some string) None & info [ "path" ] ~docv:"PATH"
      ~doc:"Override identity file path (default: ~/.config/c2c/identity.json).")
  in
  let json = Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Emit JSON output.") in
  let+ path = path
  and+ json = json in
  let target = match path with Some p -> p | None -> Relay_identity.default_path () in
  match Relay_identity.load ~path:target () with
  | Error msg ->
      if json then
        print_endline (Printf.sprintf {|{"ok":false,"error":%S}|} msg)
      else
        Printf.eprintf "error: %s\n%!" msg;
      exit 1
  | Ok id ->
      if json then
        (* Never emit the private_key on show — only public metadata. *)
        print_endline (Yojson.Safe.to_string
          (`Assoc [
            "ok", `Bool true;
            "path", `String target;
            "public_key", `String (Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet id.Relay_identity.public_key);
            "fingerprint", `String id.fingerprint;
            "alias_hint", `String id.alias_hint;
            "created_at", `String id.created_at;
            "alg", `String id.alg;
            "version", `Int id.version;
          ]))
      else begin
        Printf.printf "path:        %s\n" target;
        Printf.printf "fingerprint: %s\n" id.fingerprint;
        Printf.printf "alg:         %s\n" id.alg;
        if id.alias_hint <> "" then
          Printf.printf "alias_hint:  %s\n" id.alias_hint;
        Printf.printf "created_at:  %s\n" id.created_at
      end

let relay_identity_fingerprint_cmd =
  let path =
    Cmdliner.Arg.(value & opt (some string) None & info [ "path" ] ~docv:"PATH"
      ~doc:"Override identity file path (default: ~/.config/c2c/identity.json).")
  in
  let+ path = path in
  let target = match path with Some p -> p | None -> Relay_identity.default_path () in
  match Relay_identity.load ~path:target () with
  | Error msg -> Printf.eprintf "error: %s\n%!" msg; exit 1
  | Ok id -> print_endline id.fingerprint

let relay_identity_init =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "init" ~doc:"Generate a new Ed25519 identity keypair.")
    relay_identity_init_cmd

let relay_identity_show =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "show" ~doc:"Print identity metadata (fingerprint, alias_hint, created_at).")
    relay_identity_show_cmd

let relay_identity_fingerprint =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "fingerprint" ~doc:"Print just the SHA256 fingerprint, one line.")
    relay_identity_fingerprint_cmd

let relay_identity =
  Cmdliner.Cmd.group
    ~default:relay_identity_show_cmd
    (Cmdliner.Cmd.info "identity"
      ~doc:"Manage the local Ed25519 identity used for peer authentication.")
    [ relay_identity_init; relay_identity_show; relay_identity_fingerprint ]

let relay_setup =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "setup"
       ~doc:"Configure relay connection (URL + bearer token)."
       ~man:
         [ `S "DESCRIPTION"
         ; `P
             (Printf.sprintf
                "Persist a relay URL and bearer token under \
                 $(i,~/.config/c2c/relay.json). The default public relay \
                 is $(b,%s) — use it unless you run your own relay. \
                 Subsequent commands that talk to a relay \
                 ($(b,status), $(b,list), $(b,dm), $(b,rooms), \
                 $(b,subscribe), …) read from this config, from \
                 $(b,C2C_RELAY_URL) / $(b,C2C_RELAY_TOKEN), or from \
                 $(b,--relay-url) / $(b,--token) flags, in that order."
                default_public_relay_url)
         ; `P
             "Example: $(b,c2c relay setup --url https://relay.c2c.im --token <TOKEN>)"
         ; `S "OPTIONS"
         ; `P "Flags listed below; $(b,--show) prints the currently saved config as JSON."
         ])
    relay_setup_cmd

let relay_serve = Cmdliner.Cmd.v (Cmdliner.Cmd.info "serve" ~doc:"Start the relay server.") relay_serve_cmd
let relay_connect = Cmdliner.Cmd.v (Cmdliner.Cmd.info "connect" ~doc:"Run the relay connector.") relay_connect_cmd
let relay_status = Cmdliner.Cmd.v (Cmdliner.Cmd.info "status" ~doc:"Show relay health.") relay_status_cmd
let relay_list = Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List relay peers.") relay_list_cmd
let relay_rooms = Cmdliner.Cmd.v (Cmdliner.Cmd.info "rooms" ~doc:"Manage relay rooms.") relay_rooms_cmd
 let relay_gc = Cmdliner.Cmd.v (Cmdliner.Cmd.info "gc" ~doc:"Run relay garbage collection.") relay_gc_cmd
 let relay_dead_letter = Cmdliner.Cmd.v (Cmdliner.Cmd.info "dead-letter" ~doc:"Show relay dead-letter entries.") relay_dead_letter_cmd
 let relay_poll_inbox = Cmdliner.Cmd.v (Cmdliner.Cmd.info "poll-inbox" ~doc:"Poll a remote relay's /remote_inbox/<session_id> endpoint.") relay_poll_inbox_cmd
 let relay_register = Cmdliner.Cmd.v (Cmdliner.Cmd.info "register" ~doc:"Register Ed25519 identity on the relay.") relay_register_cmd
 let relay_dm = Cmdliner.Cmd.v (Cmdliner.Cmd.info "dm" ~doc:"Send or receive cross-host direct messages.") relay_dm_cmd
 let relay_mobile_pair = Cmdliner.Cmd.v (Cmdliner.Cmd.info "mobile-pair" ~doc:"Mobile device pairing via QR token flow (§S5a).") relay_mobile_pair_cmd
 let relay_subscribe = Cmdliner.Cmd.v (Cmdliner.Cmd.info "subscribe" ~doc:"WebSocket push subscription for DMs (slice 2).") relay_subscribe_cmd
let relay_subscribe_daemon = C2c_relay_subscribe_daemon.subscribe_daemon_cmd

 let relay_group =
  let group_doc =
    Printf.sprintf
      "Cross-machine relay (default: %s). \
       Subcommands: serve, connect, setup, status, list, rooms, gc, \
       dead-letter, identity, register, dm, mobile-pair, subscribe."
      default_public_relay_url
  in
  let group_man =
    [ `S "DESCRIPTION"
    ; `P
        (Printf.sprintf
           "The relay connects brokers across machines. The default \
            public relay is $(b,%s); switch to a private relay with \
            $(b,c2c relay setup --url) <URL> or $(b,C2C_RELAY_URL)."
           default_public_relay_url)
    ; `P
        "Use $(b,c2c relay setup) once to point your broker at the relay, \
         then run $(b,c2c relay connect) to keep the broker connected."
    ; `P
        "Common workflow: $(b,c2c relay setup --url https://relay.c2c.im) \
         then $(b,c2c relay connect). See also $(b,c2c relay setup --help) \
         for the default URL and per-flag precedence."
    ]
  in
  Cmdliner.Cmd.group
    ~default:relay_status_cmd
    (Cmdliner.Cmd.info "relay" ~doc:group_doc ~man:group_man)
    [ relay_serve; relay_connect; relay_setup; relay_status; relay_list; relay_rooms; relay_gc; relay_dead_letter; relay_poll_inbox; relay_identity; relay_register; relay_dm; relay_mobile_pair; relay_subscribe; relay_subscribe_daemon ]

(* --- mesh ------------------------------------------------------------------- *)
