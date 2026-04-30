(* test_c2c_mcp_config_rewriter.ml — #512 mcp-config rewriter regression. *)

open Alcotest

let ( // ) = Filename.concat

let mkdir_p path =
  let rec loop p =
    if p = "/" || p = "." || p = "" then ()
    else if Sys.file_exists p then ()
    else begin
      loop (Filename.dirname p);
      try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  loop path

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) @@ fun () ->
  output_string oc contents

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) @@ fun () ->
  really_input_string ic (in_channel_length ic)

let rec remove_tree p =
  if not (Sys.file_exists p) then ()
  else
    match (Unix.lstat p).Unix.st_kind with
    | Unix.S_DIR ->
        Array.iter (fun n -> if n <> "." && n <> ".." then remove_tree (p // n))
          (Sys.readdir p);
        (try Unix.rmdir p with _ -> ())
    | _ -> (try Unix.unlink p with _ -> ())

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let name = Printf.sprintf "c2c-mcp-rewriter-%d-%d" (Unix.getpid ()) (Random.bits ()) in
  let dir = base // name in
  mkdir_p dir;
  Fun.protect ~finally:(fun () -> remove_tree dir) @@ fun () ->
  f dir

let noop_print _ = ()

(** Helper: build a .mcp.json with one server and a given env block. *)
let mcp_json_with_env env_pairs =
  let env_str =
    env_pairs
    |> List.map (fun (k, v) -> Printf.sprintf "        \"%s\": \"%s\"" k v)
    |> String.concat ",\n"
  in
  Printf.sprintf
    {|{
  "mcpServers": {
    "c2c": {
      "type": "stdio",
      "command": "c2c-mcp-server",
      "args": [],
      "env": {
%s
      }
    }
  }
}
|}
    env_str

let test_strips_legacy_broker_root () =
  with_temp_dir @@ fun tmp ->
  let path = tmp // ".mcp.json" in
  let legacy = "/repo/.git/c2c/mcp" in
  let default = "/home/u/.c2c/repos/abc/broker" in
  write_file path
    (mcp_json_with_env
       [
         ("C2C_MCP_BROKER_ROOT", legacy);
         ("C2C_MCP_DEBUG", "1");
         ("C2C_MCP_AUTO_JOIN_ROOMS", "swarm-lounge");
       ]);
  let outcome =
    C2c_mcp_config_rewriter.run ~legacy ~default ~paths:[path] ~dry_run:false
      ~print_line:noop_print
  in
  check int "rewritten count" 1 (List.length outcome.rewritten);
  check int "errors" 0 (List.length outcome.errors);
  let json = Yojson.Safe.from_file path in
  let env =
    match json with
    | `Assoc top ->
        (match List.assoc "mcpServers" top with
         | `Assoc servers ->
             (match List.assoc "c2c" servers with
              | `Assoc fields ->
                  (match List.assoc "env" fields with
                   | `Assoc e -> e
                   | _ -> [])
              | _ -> [])
         | _ -> [])
    | _ -> []
  in
  check bool "C2C_MCP_BROKER_ROOT removed" false
    (List.mem_assoc "C2C_MCP_BROKER_ROOT" env);
  check bool "C2C_MCP_DEBUG preserved" true (List.mem_assoc "C2C_MCP_DEBUG" env);
  check bool "C2C_MCP_AUTO_JOIN_ROOMS preserved" true
    (List.mem_assoc "C2C_MCP_AUTO_JOIN_ROOMS" env)

let test_strips_default_broker_root () =
  with_temp_dir @@ fun tmp ->
  let path = tmp // ".mcp.json" in
  let legacy = "/repo/.git/c2c/mcp" in
  let default = "/home/u/.c2c/repos/abc/broker" in
  write_file path
    (mcp_json_with_env
       [
         ("C2C_MCP_BROKER_ROOT", default);
         ("C2C_MCP_DEBUG", "1");
       ]);
  let outcome =
    C2c_mcp_config_rewriter.run ~legacy ~default ~paths:[path] ~dry_run:false
      ~print_line:noop_print
  in
  check int "rewritten count" 1 (List.length outcome.rewritten);
  let body = read_file path in
  check bool "BROKER_ROOT gone from body" false
    (try
       ignore (Str.search_forward (Str.regexp_string "C2C_MCP_BROKER_ROOT") body 0);
       true
     with Not_found -> false);
  check bool "C2C_MCP_DEBUG retained" true
    (try
       ignore (Str.search_forward (Str.regexp_string "C2C_MCP_DEBUG") body 0);
       true
     with Not_found -> false)

let test_keeps_unknown_broker_root () =
  with_temp_dir @@ fun tmp ->
  let path = tmp // ".mcp.json" in
  let legacy = "/repo/.git/c2c/mcp" in
  let default = "/home/u/.c2c/repos/abc/broker" in
  let override = "/srv/shared/c2c-broker" in
  write_file path
    (mcp_json_with_env
       [
         ("C2C_MCP_BROKER_ROOT", override);
         ("C2C_MCP_DEBUG", "1");
       ]);
  let outcome =
    C2c_mcp_config_rewriter.run ~legacy ~default ~paths:[path] ~dry_run:false
      ~print_line:noop_print
  in
  check int "no rewrites" 0 (List.length outcome.rewritten);
  check int "one kept" 1 (List.length outcome.kept);
  let body = read_file path in
  check bool "override survived" true
    (try
       ignore (Str.search_forward (Str.regexp_string override) body 0);
       true
     with Not_found -> false)

let test_dry_run_no_writes () =
  with_temp_dir @@ fun tmp ->
  let path = tmp // ".mcp.json" in
  let legacy = "/repo/.git/c2c/mcp" in
  let default = "/home/u/.c2c/repos/abc/broker" in
  let original =
    mcp_json_with_env
      [ ("C2C_MCP_BROKER_ROOT", legacy); ("C2C_MCP_DEBUG", "1") ]
  in
  write_file path original;
  let outcome =
    C2c_mcp_config_rewriter.run ~legacy ~default ~paths:[path] ~dry_run:true
      ~print_line:noop_print
  in
  check int "would_rewrite count" 1 (List.length outcome.would_rewrite);
  check int "rewritten (live) count" 0 (List.length outcome.rewritten);
  let body = read_file path in
  check string "file unchanged on dry-run" original body

let () =
  run "c2c_mcp_config_rewriter"
    [
      ( "rewriter",
        [
          test_case "strips legacy broker_root" `Quick
            test_strips_legacy_broker_root;
          test_case "strips default broker_root" `Quick
            test_strips_default_broker_root;
          test_case "keeps unknown broker_root" `Quick
            test_keeps_unknown_broker_root;
          test_case "dry-run does not write" `Quick test_dry_run_no_writes;
        ] );
    ]
