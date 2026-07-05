(* c2c_config_cmd - local config and repo supervisor subcommands.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open C2c_cli_helpers
open Cmdliner.Term.Syntax
open C2c_types

let c2c_config_path () =
  Filename.concat (Sys.getcwd ()) (Filename.concat ".c2c" "config.toml")

let config_read () : (string * string) list =
  let path = c2c_config_path () in
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) @@ fun () ->
      let rec loop acc =
        match try Some (input_line ic) with End_of_file -> None with
        | None -> List.rev acc
        | Some line ->
          let trimmed = String.trim line in
          if trimmed = "" || String.length trimmed > 0 && trimmed.[0] = '#' then loop acc
          else match String.index_opt trimmed '=' with
            | None -> loop acc
            | Some i ->
              let k = String.trim (String.sub trimmed 0 i) in
              let v_raw = String.trim (String.sub trimmed (i+1) (String.length trimmed - i - 1)) in
              let v =
                let n = String.length v_raw in
                if n >= 2 && v_raw.[0] = '"' && v_raw.[n-1] = '"' then String.sub v_raw 1 (n-2)
                else v_raw
              in
              loop ((k, v) :: acc)
      in
      loop []

let config_write (entries : (string * string) list) : unit =
  let path = c2c_config_path () in
  let dir = Filename.dirname path in
  C2c_utils.mkdir_p dir;
  let tmp = path ^ ".tmp" in
  let oc = open_out tmp in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    output_string oc "# c2c per-repo config (.c2c/config.toml)\n";
    output_string oc "# Generated/edited by `c2c config ...`.\n\n";
    List.iter (fun (k, v) ->
      Printf.fprintf oc "%s = \"%s\"\n" k v
    ) entries
  );
  Unix.rename tmp path

let config_set (key : string) (value : string) : unit =
  let existing = config_read () in
  let without = List.filter (fun (k, _) -> k <> key) existing in
  let updated = without @ [(key, value)] in
  config_write updated

let valid_generation_clients = ["claude"; "opencode"; "codex"]

let config_show_term =
  let+ () = Cmdliner.Term.const () in
  let entries = config_read () in
  if entries = [] then Printf.printf "(no config set — %s)\n" (c2c_config_path ())
  else List.iter (fun (k, v) -> Printf.printf "%s = %s\n" k v) entries

let config_generation_client_term =
  let value =
    Cmdliner.Arg.(value & pos 0 (some string) None & info [] ~docv:"CLIENT"
      ~doc:("Set generation_client to one of: " ^ String.concat ", " valid_generation_clients ^
            ". Omit to show current value."))
  in
  let+ value = value in
  match value with
  | None ->
    (match List.assoc_opt "generation_client" (config_read ()) with
     | Some v -> print_endline v
     | None -> Printf.printf "(unset — default would be opencode when needed)\n")
  | Some v ->
    if not (List.mem v valid_generation_clients) then begin
      Printf.eprintf "error: '%s' not one of %s\n%!" v (String.concat ", " valid_generation_clients);
      exit 1
    end;
    config_set "generation_client" v;
    Printf.printf "generation_client = %s\n  written: %s\n" v (c2c_config_path ())

let config_show_cmd = Cmdliner.Cmd.v
  (Cmdliner.Cmd.info "show" ~doc:"Show current c2c config values.") config_show_term
let config_generation_client_cmd = Cmdliner.Cmd.v
  (Cmdliner.Cmd.info "generation-client"
    ~doc:"Show or set the generation_client preference — which client handles code generation in multi-agent workflows (claude|opencode|codex).")
  config_generation_client_term

let config_group =
  Cmdliner.Cmd.group ~default:config_show_term
    (Cmdliner.Cmd.info "config" ~doc:"Manage .c2c/config.toml — per-repo c2c configuration.")
    [config_show_cmd; config_generation_client_cmd]

(* --- subcommand group: repo ------------------------------------------------ *)

let repo_set_supervisor_cmd =
  let aliases_arg =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ALIAS[,ALIAS2,...]"
                    ~doc:"Supervisor alias or comma-separated list.")
  in
  let strategy_arg =
    Cmdliner.Arg.(value & opt (some string) None & info ["strategy"; "s"] ~docv:"STRATEGY"
                    ~doc:"Dispatch strategy: first-alive (default), round-robin, broadcast.")
  in
  let+ aliases_str = aliases_arg
  and+ strategy_opt = strategy_arg
  and+ json = json_flag in
  let aliases = List.filter (fun s -> s <> "") (String.split_on_char ',' aliases_str) in
  if aliases = [] then (
    Printf.eprintf "error: at least one alias required\n%!";
    exit 1
  );
  (match strategy_opt with
   | Some s when not (List.mem s C2c_init_cmd.valid_strategies) ->
       Printf.eprintf "error: unknown strategy '%s'. Use: %s\n%!" s (String.concat ", " C2c_init_cmd.valid_strategies);
       exit 1
   | _ -> ());
  let config = C2c_init_cmd.load_repo_config () in
  let fields = match config with `Assoc f -> f | _ -> [] in
  let supervisor_val = `List (List.map (fun a -> `String a) aliases) in
  let fields' = ref
    (("supervisors", supervisor_val)
     :: List.filter (fun (k, _) -> k <> "supervisors" && k <> "permission_supervisors" && k <> "supervisor_strategy") fields)
  in
  (match strategy_opt with
   | Some s -> fields' := ("supervisor_strategy", `String s) :: !fields'
   | None -> ());
  C2c_init_cmd.save_repo_config (`Assoc !fields');
  let output_mode = if json then Json else Human in
  let strategy_str = match strategy_opt with Some s -> s | None -> "first-alive (default)" in
  (match output_mode with
   | Json ->
       let out = [ ("ok", `Bool true); ("supervisors", supervisor_val); ("config", `String (C2c_init_cmd.repo_config_path ())) ] in
       let out = match strategy_opt with Some s -> ("supervisor_strategy", `String s) :: out | None -> out in
       print_json (`Assoc out)
   | Human ->
       Printf.printf "Supervisor set: %s\n" (String.concat ", " aliases);
       Printf.printf "Strategy:      %s\n" strategy_str;
       Printf.printf "Config:        %s\n" (C2c_init_cmd.repo_config_path ());
       Printf.printf "Override:      C2C_PERMISSION_SUPERVISOR=alias or C2C_SUPERVISORS=a,b\n")

let repo_show_cmd =
  let+ json = json_flag in
  let config = C2c_init_cmd.load_repo_config () in
  let output_mode = if json then Json else Human in
  (match output_mode with
   | Json -> print_json config
   | Human ->
       let path = C2c_init_cmd.repo_config_path () in
       if not (Sys.file_exists path) then (
         Printf.printf "No repo config (.c2c/repo.json) — using defaults.\n";
         Printf.printf "  Run: c2c repo set supervisor <alias> to configure.\n"
       ) else (
         Printf.printf "Repo config: %s\n" path;
         let fields = match config with `Assoc f -> f | _ -> [] in
         (match List.assoc_opt "supervisors" fields with
          | Some (`List aliases) ->
              let names = List.filter_map (function `String s -> Some s | _ -> None) aliases in
              Printf.printf "  supervisors: %s\n" (String.concat ", " names)
          | _ ->
              Printf.printf "  supervisors: (not set — default: coordinator1)\n");
         let shown = [ "supervisors"; "permission_supervisors" ] in
         List.iter (fun (k, v) ->
           if not (List.mem k shown) then
             let vstr = match v with `String s -> s | _ -> Yojson.Safe.to_string v in
             Printf.printf "  %s: %s\n" k vstr
         ) fields
       ))

let repo_group =
  Cmdliner.Cmd.group
    (Cmdliner.Cmd.info "repo"
       ~doc:"Per-repository c2c configuration (supervisors, defaults).")
    [ Cmdliner.Cmd.group
        (Cmdliner.Cmd.info "set" ~doc:"Set a per-repo config value.")
        [ Cmdliner.Cmd.v
            (Cmdliner.Cmd.info "supervisor"
               ~doc:"Set permission supervisor alias(es) for this repo."
               ~man:[ `S "DESCRIPTION"
                    ; `P "Sets the alias(es) that receive permission.ask notifications \
                          when OpenCode needs approval. Stored in .c2c/repo.json."
                    ; `S "EXAMPLES"
                    ; `P "$(b,c2c repo set supervisor coordinator1)"
                    ; `P "$(b,c2c repo set supervisor coordinator1,planner1)  — round-robin"
                    ])
            repo_set_supervisor_cmd
        ]
    ; Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "show" ~doc:"Show current repo config.")
        repo_show_cmd
    ]
