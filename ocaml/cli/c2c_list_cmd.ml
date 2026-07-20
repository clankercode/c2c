(* c2c_list_cmd - peer discovery/listing command assembly.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open C2c_cli_helpers
open C2c_types
open Cmdliner.Term.Syntax

(* lookup_role_info: best-effort load of .c2c/roles/<alias>.md for enriched listing.
   Returns (role_class, description) defaulting to ("","") when the role file is absent
   or unparseable. Tolerant to malformed files — discoverability is informational, not
   load-bearing. *)
let lookup_role_info (alias : string) : string * string =
  let path = C2c_role.canonical_roles_dir () // (alias ^ ".md") in
  if not (Sys.file_exists path) then ("", "")
  else
    try
      let r = C2c_role.parse_file path in
      let role_class = Option.value r.C2c_role.role_class ~default:"" in
      (role_class, r.C2c_role.description)
    with _ -> ("", "")

(* truncate a string to n graphemes (approximate via bytes, safe for ASCII descriptions). *)
let truncate_str (s : string) (n : int) : string =
  let s = String.trim s in
  if String.length s <= n then s
  else if n <= 1 then String.sub s 0 (max 0 n)
  else String.sub s 0 (n - 1) ^ "…"

(* relative-time: render a registered_at timestamp as "active now" / "5m ago" / "2h ago" / etc. *)
let format_last_seen (registered_at : float option) : string =
  match registered_at with
  | None -> "—"
  | Some ts ->
      let now = Unix.gettimeofday () in
      let delta = now -. ts in
      if delta < 0.0 then "future?"
      else if delta < 120.0 then "active now"
      else if delta < 3600.0 then Printf.sprintf "%dm ago" (int_of_float (delta /. 60.0))
      else if delta < 86400.0 then Printf.sprintf "%dh ago" (int_of_float (delta /. 3600.0))
      else Printf.sprintf "%dd ago" (int_of_float (delta /. 86400.0))

(* --- B097: relay-peer unification helpers -----------------------------------

   Relay inclusion in `c2c list` is opt-in via --relay so the default listing
   never touches the network (no regression for tests / offline / high-frequency
   swarm wake ticks). When --relay is passed, peers are fetched from the
   configured relay (graceful: failures become a one-line note, never a crash)
   and merged with the local listing. Each row — local or relay — carries:
     source     "local" | "relay"
     address    <alias>@<opaque_host_id>  (bare alias when host id unknown)
     identity_pk  Ed25519 public key (base64url), when published
   plus the alive state. *)

(* Local peer address: <alias>@<opaque_host_id>. A local registration is by
   definition on THIS host, so a missing opaque_host_id falls back to this
   host's computed id (same recipe as `c2c host-id`). *)
let local_address (r : C2c_mcp.registration) : string =
  let host = match r.opaque_host_id with
    | Some h when h <> "" -> h
    | _ -> Host_id.compute_host_hash ()
  in
  Printf.sprintf "%s@%s" r.alias host

(* Extract a string field from a relay lease JSON object. *)
let relay_str_field (peer : Yojson.Safe.t) (key : string) : string option =
  match peer with
  | `Assoc fs -> (match List.assoc_opt key fs with Some (`String s) -> Some s | _ -> None)
  | _ -> None

(* Extract a float field from a relay lease JSON object. *)
let relay_float_field (peer : Yojson.Safe.t) (key : string) : float option =
  match peer with
  | `Assoc fs -> (match List.assoc_opt key fs with Some (`Float f) -> Some f | _ -> None)
  | _ -> None

(* Relay peer address: <alias>@<opaque_host_id> when the lease carries an
   opaque_host_id, else the bare alias (the host half is unknown to the relay
   — e.g. a peer registered before opaque_host_id shipped). *)
let relay_address (peer : Yojson.Safe.t) : string =
  let alias = Option.value (relay_str_field peer "alias") ~default:"?" in
  match relay_str_field peer "opaque_host_id" with
  | Some h when h <> "" -> Printf.sprintf "%s@%s" alias h
  | _ -> alias

(* Relay peer alive state as an explicit tri-state mirroring the local
   registration_liveness_state JSON encoding: true | false | null (unknown).
   The relay lease always emits a bool `alive`, but be defensive. *)
let relay_alive_json (peer : Yojson.Safe.t) : Yojson.Safe.t =
  match peer with
  | `Assoc fs ->
      (match List.assoc_opt "alive" fs with
       | Some (`Bool b) -> `Bool b
       | _ -> `Null)
  | _ -> `Null

let relay_peer_is_alive (peer : Yojson.Safe.t) : bool option =
  match relay_alive_json peer with `Bool b -> Some b | _ -> None

(* Short identity_pk fingerprint for human rows: first 8 chars of the
   base64url key. Full key is always emitted in --json. *)
let short_pk (pk : string) : string =
  if String.length pk <= 8 then pk else String.sub pk 0 8 ^ "…"

let list_cmd =
  let all =
    Cmdliner.Arg.(value & flag & info [ "all"; "a" ]
      ~doc:"Show extended info (session ID, registered time) and include confirmed-dead sessions. By default, stale sessions whose process has exited are hidden so peer discovery stays focused on reachable agents. Also disables the default-broker cwd-scope filter (#74): on the shared 'default' broker, rows whose registration cwd is outside the current scope directory (git toplevel, else cwd) are otherwise hidden so unrelated non-repo agents stop showing as peers.")
  in
  let enriched =
    Cmdliner.Arg.(value & flag & info [ "enriched"; "e" ]
      ~doc:"Show role-class + description + last-seen for each peer (looked up from .c2c/roles/<alias>.md). Useful for new agents orienting on who's who in the swarm.")
  in
  let global =
    Cmdliner.Arg.(value & flag & info [ "global"; "g" ]
      ~doc:"Scan all known broker roots (across all repos) and group visible sessions by current versus other repository broker. Human output hides opaque repo fingerprints; use --json for broker paths/fingerprints when diagnosing routing. Confirmed-dead rows stay hidden unless --all is passed.")
  in
  let alive_only =
    Cmdliner.Arg.(value & flag & info [ "alive"; "A" ]
      ~doc:"Show only alive sessions. By default, confirmed-dead sessions are hidden while sessions with unknown liveness remain visible; use --all to include dead sessions too.")
  in
  let match_substr =
    Cmdliner.Arg.(value & opt (some string) None & info [ "match"; "m" ]
      ~docv:"SUBSTR"
      ~doc:"Show only sessions whose alias contains $(docv) (case-insensitive). Composes with --alive/--global/--all/--json/--relay.")
  in
  (* B097: relay-peer inclusion. Opt-in via --relay so the default listing
     never touches the network (tests / offline / high-frequency swarm wake
     ticks are unaffected). When set, ALSO fetch peers from the configured
     relay and merge them with the local listing, tagging each row with
     source: local|relay, the full alias@hostid address, identity_pk, and
     alive. Failures are non-fatal: local peers always show + a one-line
     note. See docs/reference/scopes.md. *)
  let relay =
    Cmdliner.Arg.(value & flag & info [ "relay" ]
      ~doc:"Also fetch peers from the configured relay and merge them with the local listing. Each peer row is tagged with source (local|relay), the full alias@hostid address, identity_pk, and alive. The relay fetch is non-fatal: if the relay is unconfigured or unreachable, local peers still show with a one-line note. Requires a configured relay (c2c relay setup + c2c relay register --alias <ALIAS>).")
  in
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL"
      ~doc:"Override the relay URL for --relay (default: saved c2c relay setup config, C2C_RELAY_URL, or the public relay).")
  in
  let relay_alias =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-alias" ] ~docv:"ALIAS"
      ~doc:"Alias to sign the relay /list request as for --relay (default: C2C_MCP_AUTO_REGISTER_ALIAS, else the \"anon\" placeholder). Must be bound to your local identity on the relay via c2c relay register --alias ALIAS.")
  in
  let relay_timeout =
    Cmdliner.Arg.(value & opt float 3.0 & info [ "relay-timeout" ] ~docv:"SECONDS"
      ~doc:"Timeout for the --relay peer fetch (default 3.0). Keeps `c2c list --relay` responsive when the relay is slow or unreachable.")
  in
  (* H6: filter by identity kind/scope. Scope-both rows (one identity present
     on both the local broker and the relay) pass BOTH filters — filtering is
     by where the identity is registered, not by which source produced the
     row. *)
  let kind =
    let kind_conv =
      Cmdliner.Arg.enum
        [ ("local", List_identity.Kf_local); ("relay", List_identity.Kf_relay) ]
    in
    Cmdliner.Arg.(value & opt (some kind_conv) None & info [ "kind" ] ~docv:"local|relay"
      ~doc:"Filter by identity kind/scope: 'local' keeps rows registered on this machine's broker (identity_scope local or both); 'relay' keeps relay-registered rows (relay-only rows plus local rows with identity_scope both). Most useful with --relay; without --relay, 'relay' matches nothing (a hint is printed).")
  in
  let+ json = json_flag
  and+ all = all
  and+ enriched = enriched
  and+ global = global
  and+ alive_only = alive_only
  and+ match_substr = match_substr
  and+ relay = relay
  and+ relay_url = relay_url
  and+ relay_alias = relay_alias
  and+ relay_timeout = relay_timeout
  and+ kind_filter = kind
  and+ cross_repo = cross_repo_flag in
    mcp_nudge_if_needed ~cmd:"list";

  if global && cross_repo then begin
    Printf.eprintf "error: --global (scan per-repo brokers) and --cross-repo (sessions broker) are mutually exclusive.\n%!";
    exit 2
  end;

  let is_alive r = C2c_mcp.Broker.registration_liveness_state r = C2c_mcp.Broker.Alive in
  let matches_alias (r : C2c_mcp.registration) =
    match match_substr with
    | None -> true
    | Some s -> string_contains_ci r.alias s
  in
  (* A missing or unverifiable PID is deliberately [Unknown], not [Dead]: a
     vanilla hook client may still receive on its next hook. Hide only
     confirmed process-exited rows by default. [--all] is the explicit
     operator escape hatch for stale-session forensics. *)
  let regs_filter regs =
    regs
    |> (if all then Fun.id else
          List.filter (fun r ->
            C2c_mcp.Broker.registration_liveness_state r <> C2c_mcp.Broker.Dead))
    |> (if alive_only then List.filter is_alive else Fun.id)
    |> List.filter matches_alias
  in

  (* --- helpers shared between single-broker and global modes --- *)
  let list_registration_to_json ?(repo_fp="") ?(repo_path="") ~(enriched:bool) (r : C2c_mcp.registration) =
    let base : (string * Yojson.Safe.t) list =
      [ ("source", `String "local")
      ; ("session_id", `String r.session_id)
      ; ("alias", `String r.alias)
      ; ("address", `String (local_address r))
      ]
    in
    let with_repo = if repo_fp <> "" then base @ [ ("repo_fp", `String repo_fp); ("repo_path", `String repo_path) ] else base in
    let with_pid =
      match r.pid with
      | Some n -> with_repo @ [ ("pid", `Int n) ]
      | None -> with_repo
    in
    let liveness = C2c_mcp.Broker.registration_liveness_state r in
    let alive_val : Yojson.Safe.t =
      match liveness with
      | C2c_mcp.Broker.Alive -> `Bool true
      | C2c_mcp.Broker.Dead -> `Bool false
      | C2c_mcp.Broker.Unknown -> `Null
    in
    let state =
      match liveness with
      | C2c_mcp.Broker.Alive -> "alive"
      | C2c_mcp.Broker.Dead -> "dead"
      | C2c_mcp.Broker.Unknown -> "unknown"
    in
    (* Keep the machine-readable liveness shape aligned with [c2c find]:
       [alive] is tri-state for existing consumers and [state] is the
       explicit, script-friendly label. *)
    let with_alive = with_pid @ [ ("alive", alive_val); ("state", `String state) ] in
    (* B097: surface the local Ed25519 identity key as identity_pk so callers
       can verify senders / cross-reference relay peers. Mirrors the relay
       lease field name for a uniform per-peer shape. *)
    let with_identity =
      match r.ed25519_pubkey with
      | Some pk -> with_alive @ [ ("identity_pk", `String pk) ]
      | None -> with_alive
    in
    let fields =
      match r.registered_at with
      | Some ts -> with_identity @ [ ("registered_at", `Float ts) ]
      | None -> with_identity
    in
    let fields =
      match r.tmux_location with
      | Some loc -> fields @ [ ("tmux_location", `String loc) ]
      | None -> fields
    in
    let fields =
      match r.compacting with
      | Some c ->
          let reason_json = match c.reason with Some r -> `String r | None -> `Null in
          fields @ [ ("compacting", `Assoc [ ("started_at", `Float c.started_at); ("reason", reason_json) ]) ]
      | None -> fields
    in
    let fields =
      if enriched then
        let (role_class, description) = lookup_role_info r.alias in
        fields @ [
          ("role_class", `String role_class);
          ("description", `String description);
          ("last_seen", `String (format_last_seen r.registered_at));
        ]
      else fields
    in
    `Assoc fields
  in

  let output_mode = if json then Json else Human in

  (* B097: relay peer fetch (opt-in via --relay). Computed once and merged
     into both the JSON array and the human output. The fetch is non-fatal:
     on no-config / network / auth failure we keep [relay_peers] empty and
     surface [relay_note] as a one-line stderr note, so `c2c list` never
     crashes or hangs (timeout-bounded). --match / --alive apply to relay
     peers too (merge-then-filter). *)
  let (relay_peers, relay_note) =
    if not relay then ([], None)
    else begin
      let result =
        C2c_relay_cmd.fetch_relay_peers_for_list
          ~timeout:relay_timeout ?relay_url ?alias:relay_alias ()
      in
      let note = match result with
        | C2c_relay_cmd.Relay_no_config ->
            Some "no relay configured — run `c2c relay setup --url <URL>` and `c2c relay register --alias <ALIAS>` (showing local peers only)"
        | C2c_relay_cmd.Relay_error msg ->
            Some (Printf.sprintf "relay fetch failed (%s) — showing local peers only" msg)
        | C2c_relay_cmd.Relay_peers _ -> None
      in
      let raw = match result with
        | C2c_relay_cmd.Relay_peers ps -> ps
        | _ -> []
      in
      let peer_matches (peer : Yojson.Safe.t) =
        match match_substr with
        | None -> true
        | Some s ->
            (match relay_str_field peer "alias" with
             | Some a -> string_contains_ci a s
             | None -> false)
      in
      let peers =
        raw
        |> List.filter peer_matches
        |> (if all then Fun.id else
              List.filter (fun p -> relay_peer_is_alive p <> Some false))
        |> (if alive_only then
              List.filter (fun p -> relay_peer_is_alive p = Some true)
            else Fun.id)
      in
      (peers, note)
    end
  in

  (* Normalise a relay lease JSON object into the unified per-peer shape:
     source=relay, alias, full alias@hostid address, identity_pk, alive,
     plus passthrough relay-only fields. *)
  let relay_peer_to_json (peer : Yojson.Safe.t) : Yojson.Safe.t =
    let alias = Option.value (relay_str_field peer "alias") ~default:"" in
    let base =
      [ ("source", `String "relay")
      ; ("alias", `String alias)
      ; ("address", `String (relay_address peer))
      ; ("alive", relay_alive_json peer)
      ]
    in
    let with_pk = match relay_str_field peer "identity_pk" with
      | Some pk -> base @ [ ("identity_pk", `String pk) ]
      | None -> base
    in
    let add_str key fields = match relay_str_field peer key with
      | Some v -> fields @ [ (key, `String v) ]
      | None -> fields
    in
    let add_float key fields = match relay_float_field peer key with
      | Some v -> fields @ [ (key, `Float v) ]
      | None -> fields
    in
    let fields =
      with_pk
      |> add_str "node_id"
      |> add_str "session_id"
      |> add_str "client_type"
      |> add_str "opaque_host_id"
      |> add_float "registered_at"
      |> add_float "last_seen"
    in
    `Assoc fields
  in

  (* --- H6: identity kind/scope labeling over the merged view ---------------

     Two kinds of identifier appear side by side under --relay and are
     labeled rather than flattened: a LOCAL row is a session alias on this
     machine's broker; a RELAY row is an alias@host_id relay registration
     anchored to a machine identity key. `identity_kind` says what a row IS;
     `identity_scope` says where that identity is registered (local / relay /
     both). Self-identity match rule (List_identity.same_identity): alias
     equal case-insensitively AND lease opaque_host_id = this row's effective
     host id. A matched pair is ONE identity: the relay lease is folded into
     the local row (identity_scope "both" + nested "relay_lease"), never
     emitted as a confusing duplicate row. The same alias on a DIFFERENT
     host stays a distinct row, disambiguated by its alias@host_id address.

     These are descriptive labels only — deliberately NO attestation surface
     (no trust tiers, no verified badges, no signature checking; I008 is a
     separate unbuilt layer). The default `c2c list` view stays local-only:
     flipping the default to merged is an OPEN operator-owned product gate —
     see .collab/design/friction-cn-decision-ledger.md (on the
     friction-adr0-decision-ledger branch). *)
  let this_host = lazy (Host_id.compute_host_hash ()) in
  let effective_local_host (r : C2c_mcp.registration) =
    match r.opaque_host_id with
    | Some h when h <> "" -> h
    | _ -> Lazy.force this_host
  in
  let relay_pairs =
    List.map
      (fun p ->
        ( Option.value (relay_str_field p "alias") ~default:"",
          match relay_str_field p "opaque_host_id" with
          | Some h when h <> "" -> Some h
          | _ -> None ))
      relay_peers
  in
  (* Gather the local rows the current mode will render, once, so labeling
     and every output path see the same peers. *)
  let all_roots = if global then C2c_repo_fp.list_all_broker_roots () else [] in
  let global_rows =
    if not global then []
    else
      List.fold_left (fun acc (fp, root) ->
        try
          let broker = C2c_mcp.Broker.create ~root in
          let regs = C2c_mcp.Broker.list_registrations broker |> regs_filter in
          List.map (fun r -> (fp, root, r)) regs @ acc
        with _ -> acc
      ) [] all_roots
  in
  (* #74: cwd-scope filter ONLY on the shared `default` broker. Real repo
     brokers are already fingerprint-partitioned; applying the filter there
     would hide same-repo worktree peers from each other. Bypassed by --all,
     --global, and --cross-repo. Rows with no cwd fail open (shown). Applied
     AFTER regs_filter so the hidden count only reflects rows that would
     otherwise have been shown. *)
  let apply_scope_filter = (not all) && (not global) && (not cross_repo) in
  let (single_regs, scope_hidden_count) =
    if global then ([], 0)
    else
      let broker_root = resolve_effective_broker_root ~cross_repo () in
      let broker = C2c_mcp.Broker.create ~root:broker_root in
      let regs = C2c_mcp.Broker.list_registrations broker |> regs_filter in
      C2c_list_scope.maybe_filter_default_broker ~broker_root
        ~apply:apply_scope_filter
        ~cwd_of:(fun (r : C2c_mcp.registration) -> r.cwd) regs
  in
  let mode_regs =
    if global then List.map (fun (_, _, r) -> r) global_rows else single_regs
  in
  (* Per-local matching relay-lease index (Some i => scope both, fold lease i)
     and per-relay merged flag (folded leases are not emitted as rows). No
     --relay => no relay data => every local row is honestly scope-unlabeled
     (the identity fields are only added in relay mode). *)
  let (local_matches, relay_merged_flags) =
    if not relay then
      (List.map (fun _ -> None) mode_regs, List.map (fun _ -> false) relay_peers)
    else
      let locals =
        List.map
          (fun (r : C2c_mcp.registration) -> (r.alias, effective_local_host r))
          mode_regs
      in
      List_identity.match_merged ~locals ~relays:relay_pairs
  in
  let scope_of_match m = List_identity.scope_of_local ~matched:(m <> None) in
  (if kind_filter = Some List_identity.Kf_relay && not relay then
     Printf.eprintf
       "hint: --kind relay only matches relay-registered rows; pass --relay to fetch relay peers.\n%!");
  (* Local rows zipped with their match, filtered by --kind. *)
  let kept_local_zip =
    List.combine mode_regs local_matches
    |> List.filter (fun (_, m) ->
           List_identity.local_passes kind_filter (scope_of_match m))
  in
  (* relay-lease index -> matching local alias (for scope-both rendering). *)
  let merged_alias_of_idx =
    List.concat
      (List.map2
         (fun (r : C2c_mcp.registration) m ->
           match m with Some i -> [ (i, r.alias) ] | None -> [])
         mode_regs local_matches)
  in
  (* Local row JSON: the unified B097 shape, plus (relay mode only) the H6
     identity labels and the folded relay lease for scope-both rows. The
     default (no --relay) JSON row shape is byte-for-byte unchanged. *)
  let local_row_json ?(repo_fp = "") ?(repo_path = "") ~enriched ~matched
      (r : C2c_mcp.registration) : Yojson.Safe.t =
    let base = list_registration_to_json ~repo_fp ~repo_path ~enriched r in
    if not relay then base
    else
      match base with
      | `Assoc fields ->
          let scope = scope_of_match matched in
          let fields =
            fields
            @ [ ("identity_kind", `String (List_identity.kind_to_string List_identity.Kind_local));
                ("identity_scope", `String (List_identity.scope_to_string scope)) ]
          in
          let fields =
            match matched with
            | Some i ->
                (match relay_peer_to_json (List.nth relay_peers i) with
                 | `Assoc pf ->
                     fields @ [ ("relay_lease", `Assoc (List.remove_assoc "source" pf)) ]
                 | _ -> fields)
            | None -> fields
          in
          `Assoc fields
      | j -> j
  in
  (* Relay-only row JSON: normalized lease + identity labels. *)
  let relay_peer_row_json (peer : Yojson.Safe.t) : Yojson.Safe.t =
    match relay_peer_to_json peer with
    | `Assoc fields ->
        `Assoc
          (fields
          @ [ ("identity_kind", `String (List_identity.kind_to_string List_identity.Kind_relay));
              ("identity_scope", `String (List_identity.scope_to_string List_identity.Scope_relay)) ])
    | j -> j
  in
  (* Relay rows that remain after folding scope-both leases into their local
     rows, filtered by --kind. *)
  let kept_relay_rows () : Yojson.Safe.t list =
    if not (List_identity.relay_passes kind_filter) then []
    else
      List.combine relay_peers relay_merged_flags
      |> List.filter (fun (_, merged) -> not merged)
      |> List.map (fun (p, _) -> relay_peer_row_json p)
  in
  (* JSON top level: the default path stays a bare array (additive contract);
     --relay wraps the merged rows in an envelope carrying relay_error so a
     failed fetch is machine-visible without aborting the local listing
     (relay_error is null on success; exit code stays 0 either way — the
     listing is a partial success, not a failure). *)
  let print_list_json (rows : Yojson.Safe.t list) =
    if relay then
      print_json
        (`Assoc
          [ ("peers", `List rows);
            ("relay_error",
             match relay_note with Some n -> `String n | None -> `Null) ])
    else print_json (`List rows)
  in

  (* Human-mode relay section + non-fatal note. Local rows are left untouched
     so the default listing format is unchanged; the relay block is appended.
     Scope-both leases stay visible here (the block is the relay's view) but
     are explicitly cross-referenced to their local row instead of appearing
     as an anonymous duplicate. *)
  let emit_relay_human () =
    (match relay_note with
     | Some msg -> Printf.eprintf "note: %s\n%!" msg
     | None -> ());
    let rows =
      List.mapi (fun i p -> (p, List.assoc_opt i merged_alias_of_idx)) relay_peers
      |> List.filter (fun (_, merged) ->
             match merged with
             | Some _ -> true (* scope both: passes both --kind filters *)
             | None -> List_identity.relay_passes kind_filter)
    in
    if rows <> [] then begin
      let n_total = List.length relay_peers in
      let n_alive = List.length (List.filter (fun p -> relay_peer_is_alive p = Some true) relay_peers) in
      let n_both = List.length merged_alias_of_idx in
      let both_note =
        if n_both > 0 then Printf.sprintf "; %d also local (scope both)" n_both
        else ""
      in
      Printf.printf "\nrelay peers (%d alive / %d total%s):\n" n_alive n_total both_note;
      Printf.printf "  %-34s %-8s %-6s %s\n" "ADDRESS" "STATE" "SCOPE" "IDENTITY_PK";
      List.iter (fun (p, merged) ->
        let state = match relay_peer_is_alive p with
          | Some true -> "alive"
          | Some false -> "dead"
          | None -> "unknown"
        in
        let scope = match merged with Some _ -> "both" | None -> "relay" in
        let pk = match relay_str_field p "identity_pk" with
          | Some k -> "pk:" ^ short_pk k
          | None -> "—"
        in
        let marker = match merged with
          | Some local_alias -> Printf.sprintf "  (= local '%s')" local_alias
          | None -> ""
        in
        Printf.printf "  %-34s %-8s %-6s %s%s\n" (truncate_str (relay_address p) 34) state scope pk marker
      ) rows
    end
  in

  let () = (if global then
    (* --global: scan all known broker roots (gathered above as global_rows) *)
    if all_roots = [] then (
      match output_mode with
      | Json -> print_list_json (kept_relay_rows ())
      | Human -> Printf.printf "No broker roots found.\n")
    else
      let all_regs =
        List.combine global_rows local_matches
        |> List.filter (fun (_, m) ->
               List_identity.local_passes kind_filter (scope_of_match m))
      in
      match output_mode with
      | Json ->
          let json_regs =
            List.map
              (fun ((fp, root, r), m) ->
                local_row_json ~repo_fp:fp ~repo_path:root ~enriched ~matched:m r)
              all_regs
          in
          print_list_json (json_regs @ kept_relay_rows ())
      | Human ->
          let all_regs = List.map fst all_regs in
          if all_regs = [] then Printf.printf "No registered peers across %d broker root(s).\n" (List.length all_roots)
          else begin
            (* Group registrations by (fp, root) for human output *)
            let by_broker : (string * string, C2c_mcp.registration list) Hashtbl.t = Hashtbl.create 16 in
            List.iter (fun (fp, root, r) ->
              let key = (fp, root) in
              let existing = try Hashtbl.find by_broker key with Not_found -> [] in
              Hashtbl.replace by_broker key (r :: existing)
            ) all_regs;
            (* Print only repositories with a visible row.  After the default
               dead-session filter, retaining an empty broker header would
               still expose the stale repository as list noise. *)
            let current_root = try Some (resolve_broker_root ()) with _ -> None in
            all_roots
            |> List.filter (fun key -> Hashtbl.mem by_broker key)
            |> List.iter (fun (fp, root) ->
              let regs = try Hashtbl.find by_broker (fp, root) with Not_found -> [] in
              let scope = match current_root with
                | Some current when current = root -> "current repository"
                | _ -> "other repository broker"
              in
              Printf.printf "\n[%s]\n"
                (if enriched then scope ^ ", enriched" else scope);
              List.iter (fun r ->
                let alive_str =
                  match C2c_mcp.Broker.registration_liveness_state r with
                  | C2c_mcp.Broker.Alive -> "alive"
                  | C2c_mcp.Broker.Dead -> "dead "
                  | C2c_mcp.Broker.Unknown -> "unknown"
                in
                let pid_str = match r.pid with Some p -> Printf.sprintf " pid=%d" p | None -> "" in
                if enriched then
                  let (role_class, description) = lookup_role_info r.alias in
                  let role_class = if role_class = "" then "—" else role_class in
                  let description = if description = "" then "—" else description in
                  let last_seen = format_last_seen r.registered_at in
                  Printf.printf "  %-20s %-13s %-40s %-12s %s%s\n"
                    (truncate_str r.alias 20)
                    (truncate_str role_class 13)
                    (truncate_str description 40)
                    last_seen
                    alive_str pid_str
                else if all then
                  let session_short = let s = r.session_id in if String.length s > 12 then String.sub s 0 12 ^ "..." else s in
                  let time_str = match r.registered_at with None -> "" | Some ts ->
                    let t = Unix.gmtime ts in Printf.sprintf " %04d-%02d-%02d %02d:%02d" (1900+t.tm_year) (1+t.tm_mon) t.tm_mday t.tm_hour t.tm_min
                  in
                  let tmux_str = match r.tmux_location with Some s -> " ["^s^"]" | _ -> "" in
                  Printf.printf "  %-20s %s%s  %s%s%s\n" r.alias alive_str pid_str session_short time_str tmux_str
                else begin
                  let tmux_str = match r.tmux_location with Some s -> " ["^s^"]" | _ -> "" in
                  Printf.printf "  %-20s %s%s%s\n" r.alias alive_str pid_str tmux_str
                end
              ) regs
            )
          end
  else
    (* single-broker (default or --cross-repo): gathered above as single_regs *)
    let regs = single_regs in
    if regs = [] then (
      match output_mode with
      | Json -> print_list_json (kept_relay_rows ())
      | Human ->
          if relay && relay_peers <> [] then
            Printf.printf "No local peers in this repo.\n"
          else if cross_repo then Printf.printf "No registered peers on the sessions broker.\n"
          else begin
            let n_alive =
              try
                let sb = C2c_mcp.Broker.create ~root:(Repo_fp.resolve_sessions_broker_root ()) in
                C2c_mcp.Broker.list_registrations sb
                |> List.filter (fun r -> C2c_mcp.Broker.registration_liveness_state r = C2c_mcp.Broker.Alive)
                |> List.length
              with _ -> 0
            in
            if n_alive > 0 then
              Printf.printf "No peers in this repo; %d alive on the sessions broker — try `c2c list --cross-repo`.\n" n_alive
            else
              Printf.printf "No registered peers.\n"
          end)
    else
      let regs = List.map fst kept_local_zip in
      match output_mode with
      | Json ->
          let json_regs =
            List.map
              (fun (r, m) -> local_row_json ~enriched ~matched:m r)
              kept_local_zip
          in
          print_list_json (json_regs @ kept_relay_rows ())
      | Human ->
          if enriched then begin
            Printf.printf "  %-20s %-13s %-40s %-12s %s\n"
              "ALIAS" "ROLE" "DESCRIPTION" "LAST-SEEN" "STATE";
            Printf.printf "  %-20s %-13s %-40s %-12s %s\n"
              (String.make 20 '-') (String.make 13 '-') (String.make 40 '-')
              (String.make 12 '-') (String.make 5 '-');
            List.iter
              (fun (r : C2c_mcp.registration) ->
                let alive_str =
                  match C2c_mcp.Broker.registration_liveness_state r with
                  | C2c_mcp.Broker.Alive -> "alive"
                  | C2c_mcp.Broker.Dead -> "dead"
                  | C2c_mcp.Broker.Unknown -> "unknown"
                in
                let (role_class, description) = lookup_role_info r.alias in
                let role_class = if role_class = "" then "—" else role_class in
                let description = if description = "" then "—" else description in
                let last_seen = format_last_seen r.registered_at in
                Printf.printf "  %-20s %-13s %-40s %-12s %s\n"
                  (truncate_str r.alias 20)
                  (truncate_str role_class 13)
                  (truncate_str description 40)
                  last_seen
                  alive_str)
              regs
          end else
            List.iter
              (fun (r : C2c_mcp.registration) ->
                let alive_str =
                  match C2c_mcp.Broker.registration_liveness_state r with
                  | C2c_mcp.Broker.Alive -> "alive"
                  | C2c_mcp.Broker.Dead -> "dead "
                  | C2c_mcp.Broker.Unknown -> "unknown"
                in
                let pid_str =
                  match r.pid with
                  | Some p -> Printf.sprintf " pid=%d" p
                  | None -> ""
                in
                if all then
                  let session_short =
                    let s = r.session_id in
                    if String.length s > 12 then String.sub s 0 12 ^ "..." else s
                  in
                  let time_str =
                    match r.registered_at with
                    | None -> ""
                    | Some ts ->
                        let t = Unix.gmtime ts in
                        Printf.sprintf " %04d-%02d-%02d %02d:%02d"
                          (1900 + t.tm_year) (1 + t.tm_mon) t.tm_mday t.tm_hour t.tm_min
                  in
                  let tmux_str = match r.tmux_location with Some s -> " [" ^ s ^ "]" | _ -> "" in
                  Printf.printf "  %-20s %s%s  %s%s%s\n" r.alias alive_str pid_str session_short time_str tmux_str
                else
                  let tmux_str = match r.tmux_location with Some s -> " [" ^ s ^ "]" | _ -> "" in
                  Printf.printf "  %-20s %s%s%s\n" r.alias alive_str pid_str tmux_str)
               regs) in
  if relay && output_mode = Human then emit_relay_human ();
  (* #74: make the default-broker cwd-scope filtering discoverable, never
     silent. Printed to stderr so it does not corrupt --json stdout, in both
     output modes. Only non-zero when the listing was on the `default` broker. *)
  if scope_hidden_count > 0 then
    Printf.eprintf
      "(%d agent%s in other directories hidden — use --all to show)\n%!"
      scope_hidden_count
      (if scope_hidden_count = 1 then "" else "s")

let sessions_cmd =
  let+ json = json_flag in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let regs = C2c_mcp.Broker.list_registrations broker in
  if json then
    print_json (C2c_sessions_format.sessions_to_json regs)
  else
    print_string (C2c_sessions_format.format_human regs)

let list : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "list" ~doc:"List registered C2C peers.")
    list_cmd

(** B183: discoverable synonym for agents that try `c2c peers`. *)
let peers : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "peers"
       ~doc:"Alias for $(b,list) — list registered C2C peers.")
    list_cmd

let sessions : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "sessions" ~doc:"List registered sessions with session_id, alias, client_type, cwd, and liveness.")
    sessions_cmd
