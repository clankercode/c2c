(* c2c_find_cmd — `c2c find PATTERN`: locate a peer across brokers.

   A vanilla agent hunting for one live peer shouldn't have to page
   through `c2c list --global --all` (thousands of dead historical
   sessions) and pipe JSON to jq. `c2c find` matches a case-insensitive
   alias substring (or an exact session id) against BOTH the per-repo
   broker and the cross-repo sessions broker by default (bias:
   just-works discovery), prints alive-first, and exits 0 iff at least
   one registration matched (1 otherwise).

   `--global` widens the sweep to every known per-repo broker root;
   `--cross-repo` narrows to the sessions broker only (same meaning as
   on `c2c list`). *)

open C2c_cli_helpers
open Cmdliner.Term.Syntax

let liveness_rank = function
  | C2c_mcp.Broker.Alive -> 0
  | C2c_mcp.Broker.Unknown -> 1
  | C2c_mcp.Broker.Dead -> 2

let liveness_str = function
  | C2c_mcp.Broker.Alive -> "alive"
  | C2c_mcp.Broker.Unknown -> "unknown"
  | C2c_mcp.Broker.Dead -> "dead"

(* One matched registration + where it was found.
   [broker_label] is "repo" | "sessions" | "repo:<fp>" (--global sweep). *)
type hit =
  { reg : C2c_mcp.registration
  ; state : C2c_mcp.Broker.liveness_state
  ; broker_label : string
  ; broker_root : string
  }

let matches ~pattern (r : C2c_mcp.registration) =
  string_contains_ci r.alias pattern
  || String.lowercase_ascii r.session_id = String.lowercase_ascii pattern

(* Best-effort scan: a missing/unreadable broker root contributes no hits
   rather than aborting the whole search. *)
let scan_root ~label ~root ~pattern : hit list =
  try
    let broker = C2c_mcp.Broker.create ~root in
    C2c_mcp.Broker.list_registrations broker
    |> List.filter (matches ~pattern)
    |> List.map (fun (r : C2c_mcp.registration) ->
        { reg = r
        ; state = C2c_mcp.Broker.registration_liveness_state r
        ; broker_label = label
        ; broker_root = root
        })
  with _ -> []

let hit_to_json (h : hit) : Yojson.Safe.t =
  let r : C2c_mcp.registration = h.reg in
  let alive : Yojson.Safe.t =
    match h.state with
    | C2c_mcp.Broker.Alive -> `Bool true
    | C2c_mcp.Broker.Dead -> `Bool false
    | C2c_mcp.Broker.Unknown -> `Null
  in
  let fields =
    [ ("alias", `String r.alias)
    ; ("session_id", `String r.session_id)
    ; ("alive", alive)
    ; ("state", `String (liveness_str h.state))
    ; ( "client_type",
        match r.client_type with Some c -> `String c | None -> `Null )
    ; ("broker", `String h.broker_label)
    ; ("broker_root", `String h.broker_root)
    ]
  in
  let fields =
    match r.pid with Some p -> fields @ [ ("pid", `Int p) ] | None -> fields
  in
  let fields =
    match r.registered_at with
    | Some ts -> fields @ [ ("registered_at", `Float ts) ]
    | None -> fields
  in
  `Assoc fields

let find_term =
  let pattern =
    Cmdliner.Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"PATTERN"
          ~doc:
            "Alias substring (case-insensitive) or exact session ID to look \
             for.")
  in
  let global =
    Cmdliner.Arg.(
      value & flag
      & info [ "global"; "g" ]
          ~doc:
            "Also sweep every known per-repo broker root system-wide (same \
             scan as $(b,c2c list --global)).")
  in
  let+ json = json_flag
  and+ pattern = pattern
  and+ global = global
  and+ cross_repo = cross_repo_flag in
  mcp_nudge_if_needed ~cmd:"find";
  let sessions_root = Repo_fp.resolve_sessions_broker_root () in
  let sources =
    if cross_repo then [ ("sessions", sessions_root) ]
    else
      let repo_root = try Some (resolve_broker_root ()) with _ -> None in
      let base =
        match repo_root with
        | Some r when r <> sessions_root ->
            [ ("repo", r); ("sessions", sessions_root) ]
        | _ -> [ ("sessions", sessions_root) ]
      in
      if global then
        let covered = List.map snd base in
        base
        @ (Repo_fp.list_all_broker_roots ()
          |> List.filter (fun (_fp, root) -> not (List.mem root covered))
          |> List.map (fun (fp, root) -> ("repo:" ^ fp, root)))
      else base
  in
  let hits =
    List.concat_map (fun (label, root) -> scan_root ~label ~root ~pattern) sources
  in
  (* Dedupe identical registrations reached via two source paths (e.g. an
     env override aliasing a --global root). *)
  let seen = Hashtbl.create 16 in
  let hits =
    List.filter
      (fun h ->
        let r : C2c_mcp.registration = h.reg in
        let key = (r.session_id, r.alias, h.broker_root) in
        if Hashtbl.mem seen key then false
        else (
          Hashtbl.add seen key ();
          true))
      hits
  in
  (* Alive first, then unknown, then dead; alphabetical within a state. *)
  let hits =
    List.stable_sort
      (fun a b ->
        match compare (liveness_rank a.state) (liveness_rank b.state) with
        | 0 ->
            let al : C2c_mcp.registration = a.reg
            and bl : C2c_mcp.registration = b.reg in
            compare
              (String.lowercase_ascii al.alias)
              (String.lowercase_ascii bl.alias)
        | c -> c)
      hits
  in
  if json then print_json (`List (List.map hit_to_json hits))
  else if hits = [] then
    Printf.printf "No peers matching %S (searched: %s).\n" pattern
      (String.concat ", " (List.map fst sources))
  else
    List.iter
      (fun h ->
        let r : C2c_mcp.registration = h.reg in
        Printf.printf "  %-20s %-8s %-10s %s  [%s]\n" r.alias
          (liveness_str h.state)
          (match r.client_type with Some c -> c | None -> "?")
          r.session_id h.broker_label)
      hits;
  if hits = [] then exit 1

let find : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "find"
       ~doc:
         "Find a peer by alias substring (case-insensitive) or exact session \
          ID. Searches this repo's broker and the cross-repo sessions broker \
          by default (add $(b,--global) to sweep all known broker roots; \
          $(b,--cross-repo) to search only the sessions broker). Alive peers \
          sort first. Exits 0 when at least one registration matches, 1 when \
          none do.")
    find_term
