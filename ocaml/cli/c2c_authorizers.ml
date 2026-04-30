(* c2c_authorizers.ml — #511 Slice 1: authorizers[] schema + resolver.

   Reads the ordered `authorizers` list from ~/.c2c/repo.json (project-level
   first, then home-level), then resolves it against the live broker state
   using Broker.resolve_authorizers to find the first alive/DnD-clear/idle-
   cleared reviewer alias.

   The resolved alias is written into the pending record as `primary_authorizer`
   by the hook script (Slice 2); this module provides the OCaml resolver so the
   same logic is available both to the CLI and to the hook via `c2c resolve-authorizer`. *)

let ( // ) = Filename.concat

(** Canonical path to the repo.json at home level (~/.c2c/repo.json). *)
let project_repo_json () =
  Filename.concat (Sys.getcwd ()) ".c2c" // "repo.json"

(** Canonical path to the repo.json at home level (~/.c2c/repo.json). *)
let home_repo_json () =
  let home = match Sys.getenv_opt "HOME" with
    | Some h -> h | None -> Sys.getenv "HOME"  (* will raise if unset *)
  in
  home // ".c2c" // "repo.json"

(** Read the `authorizers` field from a repo.json file.
    Returns None if the file doesn't exist or the field is absent.
    Returns Some string list on success (may be empty list). *)
let read_authorizers_from_file path : string list option =
  if not (Sys.file_exists path) then None
  else
    try
      let ic = open_in path in
      Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        let n = in_channel_length ic in
        let data = really_input_string ic n in
        let j = Yojson.Safe.from_string data in
        match Yojson.Safe.Util.member "authorizers" j with
        | `List items ->
            let names = List.filter_map (function
              | `String s when s <> "" -> Some s
              | _ -> None) items
            in
            Some names
        | _ -> None)
    with _ -> None

(** Read the ordered `authorizers` list from repo.json.
    Project-level (~/.c2c/repo.json) takes priority over home-level.
    Returns None if neither file has the field, or Some list (may be []). *)
let get_authorizers () : string list option =
  match read_authorizers_from_file (project_repo_json ()) with
  | Some _ as result -> result
  | None -> read_authorizers_from_file (home_repo_json ())

(** Resolve the first available authorizer from the configured list.
    Uses Broker.resolve_authorizers: live (PID-confirmed alive) →
    not-DnD → not-idle (within 25-minute threshold).
    Returns None if no authorizers are configured or none qualify. *)
let resolve_first_authorizer ?(broker_root=None) () : string option =
  match get_authorizers () with
  | None -> None
  | Some [] -> None
  | Some authorizers ->
      let root = match broker_root with
        | Some r -> r
        | None -> C2c_repo_fp.resolve_broker_root ()
      in
      let broker = C2c_mcp.Broker.create ~root in
      C2c_mcp.Broker.resolve_authorizers broker ~authorizers
