(* c2c_signing_helpers.ml — shared per-alias signing key helpers for peer-pass and stickers *)

let ( // ) = Filename.concat

(* TODO: broker_root resolution here duplicates resolve_broker_root from c2c.ml:89.
   Future slice should expose resolve_broker_root from a shared module so both
   c2c_signing_helpers and c2c.ml import the same helper. *)

let xdg_state_home () =
  match Sys.getenv_opt "XDG_STATE_HOME" with
  | Some v when String.trim v <> "" -> String.trim v
  | _ ->
      (match Sys.getenv_opt "HOME" with
       | Some h when String.trim h <> "" -> h // ".local" // "state"
       | _ -> "/tmp")

let per_alias_key_path ~alias =
  let abs_path p = if Filename.is_relative p then Sys.getcwd () // p else p in
  let broker_root =
    match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
    | Some dir -> abs_path dir
    | None -> (
        match Git_helpers.git_common_dir () with
        | Some git_dir -> abs_path git_dir // "c2c" // "mcp"
        | None -> xdg_state_home () // "c2c" // "default" // "mcp")
  in
  Some (broker_root // "keys" // (alias ^ ".ed25519"))
