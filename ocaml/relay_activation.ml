(* relay_activation.ml — the single source of truth for "is the relay on?".

   B300: the relay is OPT-IN. c2c is local-only until an operator explicitly
   activates cross-machine messaging, and c2c must make NO relay network call
   before that. Activation is, in precedence order:

     1. an explicit [--relay-url URL] on the command,
     2. [C2C_RELAY_URL] in the environment,
     3. a [url] in relay.json (written by `c2c relay setup` / `c2c relay
        enable` / `c2c init --relay`), unless that file sets [enabled: false].

   (1) and (2) are direct operator intent for THIS invocation, so they win over
   a stored [enabled: false] — `c2c relay disable` parks a configured URL, it
   does not veto an explicit override. Nothing else activates the relay: in
   particular there is NO implicit fall back to the public relay, which is what
   used to make a pristine host phone home on `c2c doctor` / `c2c health`.

   B301: this lives in the library, below every caller, because the resolution
   had been copied three times and all three copies had drifted —
   `c2c health` read only [C2C_RELAY_URL] then hardcoded the public relay
   (so a private-relay host was told about the wrong server), and
   `c2c relay subscribe-daemon` read [~/.c2c/relay-setup.json], a path nothing
   else writes. Callers must route through here rather than re-deriving it. *)

let default_public_relay_url = "https://relay.c2c.im"

(* Same three branches as the CLI has always used, but KEEPING which branch was
   taken: surfaces that report on the relay config name the file rather than
   claim a scope, because only the middle branch is repo-local. *)
let config_location () : Relay_state.relay_config_location =
  match Sys.getenv_opt "C2C_RELAY_CONFIG" with
  | Some p when p <> "" -> Relay_state.Relay_config_explicit p
  | _ ->
      (match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
       | Some d when String.trim d <> "" ->
           Relay_state.Relay_config_repo
             (Filename.concat (String.trim d) "relay.json")
       | _ ->
           let home = try Sys.getenv "HOME" with Not_found -> "." in
           Relay_state.Relay_config_machine
             (Filename.concat home ".config/c2c/relay.json"))

let config_path () = Relay_state.relay_config_path_of (config_location ())

let load_config () =
  let path = config_path () in
  if not (Sys.file_exists path) then `Assoc []
  else try Yojson.Safe.from_file path with _ -> `Assoc []

let config_string_field key =
  match load_config () with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String v) when v <> "" -> Some v
       | _ -> None)
  | _ -> None

let config_bool_field key =
  match load_config () with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Bool v) -> Some v
       | _ -> None)
  | _ -> None

(* Constructors carry the [Relay_] prefix so the CLI can re-export this type
   verbatim (`type relay_activation = Relay_activation.t = Relay_inactive | ...`)
   and every existing `C2c_relay_cmd.Relay_active (...)` call site keeps
   compiling against the single definition. *)
type t =
  | Relay_inactive
      (** No URL from flag, env, or config — c2c is local-only. *)
  | Relay_disabled of string
      (** relay.json sets [enabled: false]; payload is that config path. *)
  | Relay_active of string * string
      (** Activated: (url, human-readable source of that url). *)

let resolve ?flag () =
  match flag with
  | Some v when String.trim v <> "" -> Relay_active (String.trim v, "--relay-url flag")
  | _ ->
      (match Sys.getenv_opt "C2C_RELAY_URL" with
       | Some v when String.trim v <> "" ->
           Relay_active (String.trim v, "env C2C_RELAY_URL")
       | _ ->
           if config_bool_field "enabled" = Some false then
             Relay_disabled (config_path ())
           else
             (match config_string_field "url" with
              | Some v ->
                  Relay_active (v, Printf.sprintf "relay config (%s)" (config_path ()))
              | None -> Relay_inactive))

let url ?flag () =
  match resolve ?flag () with
  | Relay_active (u, _) -> Some u
  | Relay_inactive | Relay_disabled _ -> None

let is_active () = match resolve () with Relay_active _ -> true | _ -> false

(* One activation message, used by every relay surface that cannot proceed. It
   must never read as a malfunction: a host with the relay off is correctly
   configured, so the text says what c2c still does locally and names the single
   command that turns cross-machine messaging on. *)
let not_activated_error () =
  match resolve () with
  | Relay_active _ -> ""
  | Relay_disabled path ->
      Printf.sprintf
        "error: the relay is disabled on this host (enabled: false in %s).\n\
        \  Re-enable with:  c2c relay enable\n\
        \  Or override once with --relay-url <URL> / C2C_RELAY_URL.\n"
        path
  | Relay_inactive ->
      Printf.sprintf
        "error: the relay is not activated on this host — c2c is local-only by \
         default.\n\
        \  Same-machine DMs, rooms and broadcast do not need it; only \
           cross-machine messaging does.\n\
        \  Activate with:  c2c relay enable              (public relay: %s)\n\
        \             or:  c2c relay enable --url <URL>  (private relay)\n\
        \  One-off override: --relay-url <URL> or C2C_RELAY_URL.\n"
        default_public_relay_url
