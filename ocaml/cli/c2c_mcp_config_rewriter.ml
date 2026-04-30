(* c2c_mcp_config_rewriter.ml — strip stale C2C_MCP_BROKER_ROOT entries
   from .mcp.json files.

   Fourth leg of the broker-root drift cluster (#504, #512). Companion to
   the opencode-plugin skip-when-default slice (c9c11541): the same
   "omit when value matches resolver default OR legacy path" rule applied
   to .mcp.json env blocks instead of opencode sidecars.

   Operator-facing entry point: `c2c migrate-broker --rewrite-mcp-configs`.

   Detection rule for each `mcpServers.<name>.env.C2C_MCP_BROKER_ROOT`:
     - matches the legacy path (<repo>/.git/c2c/mcp)        → STRIP
     - matches resolve_broker_root () (current default)     → STRIP
     - any other value (operator override)                  → KEEP

   Atomic rewrite: temp file + fsync + rename. Other env keys preserved
   verbatim. Yojson preserves the assoc-list order, so non-stripped keys
   come out in their original order.

   Scan paths are caller-supplied (kept narrow on purpose — repo root +
   .worktrees/* in the v1 caller). *)

let ( // ) = Filename.concat

(** Per-file outcome line for the dry-run / live legend. *)
type file_action =
  | Will_strip of {
      path : string;
      server_name : string;
      value : string;
      match_kind : string; (* "legacy" | "default" *)
    }
  | Keep of { path : string; server_name : string; value : string; reason : string }
  | No_op of string  (* path *)

let normalize_path p =
  (* Canonicalize trailing slashes so equality holds on `/foo/` vs `/foo`. *)
  if String.length p > 1 && p.[String.length p - 1] = '/' then
    String.sub p 0 (String.length p - 1)
  else p

(** Decide whether a broker_root value is a "default-class" stale entry
    that should be stripped. Returns Some "legacy" / Some "default" if
    yes, None if it's an operator override we must leave alone. *)
let classify_value ~legacy ~default value =
  let v = normalize_path (String.trim value) in
  if v = "" then None
  else if normalize_path legacy = v && legacy <> "" then Some "legacy"
  else if normalize_path default = v && default <> "" then Some "default"
  else None

(** Read a JSON file. Returns None if missing or unparsable. *)
let read_json path =
  if not (Sys.file_exists path) then None
  else
    try Some (Yojson.Safe.from_file path)
    with _ -> None

(** Atomic write using temp file + fsync + rename. *)
let write_json_atomic path json =
  let dir = Filename.dirname path in
  let tmp = Filename.temp_file ~temp_dir:dir ".mcp-rewriter-" ".tmp" in
  let oc = open_out tmp in
  Fun.protect
    ~finally:(fun () -> try close_out oc with _ -> ())
    (fun () ->
      output_string oc (Yojson.Safe.pretty_to_string json);
      output_char oc '\n';
      (try
         let fd = Unix.descr_of_out_channel oc in
         Unix.fsync fd
       with _ -> ()));
  Unix.rename tmp path

(** Walk the .mcp.json tree, mutate stale env entries.

    Returns (rewritten_json_or_none, actions). [rewritten_json_or_none]
    is None if no change was needed (NO-OP), Some new_json otherwise. *)
let analyze_file ~legacy ~default ~path : Yojson.Safe.t option * file_action list =
  match read_json path with
  | None -> (None, [No_op path])
  | Some json ->
      let actions = ref [] in
      let changed = ref false in
      let rewrite_env server_name env_assoc =
        List.filter_map
          (fun (k, v) ->
            if k = "C2C_MCP_BROKER_ROOT" then begin
              let value_str = match v with `String s -> s | _ -> "" in
              match classify_value ~legacy ~default value_str with
              | Some kind ->
                  actions :=
                    Will_strip
                      { path; server_name; value = value_str; match_kind = kind }
                    :: !actions;
                  changed := true;
                  None
              | None ->
                  actions :=
                    Keep
                      {
                        path;
                        server_name;
                        value = value_str;
                        reason = "operator override (not legacy or default)";
                      }
                    :: !actions;
                  Some (k, v)
            end
            else Some (k, v))
          env_assoc
      in
      let rewrite_server (server_name, server_json) =
        match server_json with
        | `Assoc fields ->
            let new_fields =
              List.map
                (fun (k, v) ->
                  if k = "env" then
                    match v with
                    | `Assoc env_assoc ->
                        (k, `Assoc (rewrite_env server_name env_assoc))
                    | other -> (k, other)
                  else (k, v))
                fields
            in
            (server_name, `Assoc new_fields)
        | other -> (server_name, other)
      in
      let new_json =
        match json with
        | `Assoc top ->
            `Assoc
              (List.map
                 (fun (k, v) ->
                   if k = "mcpServers" then
                     match v with
                     | `Assoc servers ->
                         (k, `Assoc (List.map rewrite_server servers))
                     | other -> (k, other)
                   else (k, v))
                 top)
        | other -> other
      in
      let actions = List.rev !actions in
      let actions = if actions = [] then [No_op path] else actions in
      ((if !changed then Some new_json else None), actions)

(** Render an action as a single legend line. *)
let render_action = function
  | Will_strip { path; server_name; value; match_kind } ->
      Printf.sprintf
        "  [WILL STRIP %s: mcpServers.%s.env.C2C_MCP_BROKER_ROOT=%s (matches %s)]"
        path server_name value match_kind
  | Keep { path; server_name; value; reason } ->
      Printf.sprintf
        "  [KEEP %s: mcpServers.%s.env.C2C_MCP_BROKER_ROOT=%s (%s)]" path
        server_name value reason
  | No_op path -> Printf.sprintf "  [NO-OP %s: no stale broker_root]" path

(** Default scan-path discovery: project root + .worktrees/*.
    Caller can override via [paths] arg to [run]. *)
let default_scan_paths ~repo_root =
  let root_mcp = repo_root // ".mcp.json" in
  let worktrees_dir = repo_root // ".worktrees" in
  let worktree_mcps =
    if Sys.file_exists worktrees_dir && Sys.is_directory worktrees_dir then
      try
        Array.to_list (Sys.readdir worktrees_dir)
        |> List.filter (fun n -> n <> "." && n <> "..")
        |> List.map (fun n -> worktrees_dir // n // ".mcp.json")
        |> List.filter Sys.file_exists
      with _ -> []
    else []
  in
  let paths = root_mcp :: worktree_mcps in
  List.filter Sys.file_exists paths

type outcome = {
  rewritten : string list;          (** paths actually written *)
  would_rewrite : string list;      (** paths that would be written in --dry-run *)
  kept : (string * string) list;    (** path, value *)
  no_ops : string list;             (** paths with no stale entry *)
  errors : (string * string) list;  (** path, error *)
}

let empty_outcome =
  { rewritten = []; would_rewrite = []; kept = []; no_ops = []; errors = [] }

(** Run the rewriter over [paths]. If [dry_run], only emit lines and
    populate [would_rewrite]; no writes. *)
let run ~legacy ~default ~paths ~dry_run ~print_line : outcome =
  print_line
    (Printf.sprintf "Scanning %d .mcp.json file(s) for stale C2C_MCP_BROKER_ROOT:"
       (List.length paths));
  print_line (Printf.sprintf "  legacy match : %s" legacy);
  print_line (Printf.sprintf "  default match: %s" default);
  let acc = ref empty_outcome in
  List.iter
    (fun path ->
      let new_json_opt, actions = analyze_file ~legacy ~default ~path in
      List.iter (fun a -> print_line (render_action a)) actions;
      List.iter
        (fun a ->
          match a with
          | Keep { path; value; _ } ->
              acc := { !acc with kept = (path, value) :: !acc.kept }
          | No_op p -> acc := { !acc with no_ops = p :: !acc.no_ops }
          | Will_strip _ -> ())
        actions;
      match new_json_opt with
      | None -> ()
      | Some new_json ->
          if dry_run then
            acc := { !acc with would_rewrite = path :: !acc.would_rewrite }
          else (
            try
              write_json_atomic path new_json;
              acc := { !acc with rewritten = path :: !acc.rewritten }
            with exn ->
              acc :=
                { !acc with
                  errors = (path, Printexc.to_string exn) :: !acc.errors;
                }))
    paths;
  print_line "";
  if dry_run then
    print_line
      (Printf.sprintf
         "DRY RUN: %d file(s) would be rewritten. Run without --dry-run to apply."
         (List.length !acc.would_rewrite))
  else
    print_line
      (Printf.sprintf "Rewrote %d file(s); %d kept (operator override); %d no-op."
         (List.length !acc.rewritten)
         (List.length !acc.kept)
         (List.length !acc.no_ops));
  {
    rewritten = List.rev !acc.rewritten;
    would_rewrite = List.rev !acc.would_rewrite;
    kept = List.rev !acc.kept;
    no_ops = List.rev !acc.no_ops;
    errors = List.rev !acc.errors;
  }
