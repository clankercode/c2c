(* c2c_agent_help.ml — `c2c agent-help [topic]` implementation.

   Agent-oriented help: for each c2c capability, prints the MCP tool-call
   example AND the equivalent CLI command. The whole surface is GENERATED
   AT RUNTIME from the existing sources of truth, so it cannot drift from
   what the binary actually offers:

   - Topics + descriptions + argument schemas come from the MCP tool
     registry [C2c_mcp.base_tool_definitions] (canonical in ocaml/c2c_mcp.ml).
     Adding/removing/renaming a tool, or editing its schema, is reflected
     here with no edit to this file.
   - CLI commands are derived from each tool name. Most map by simple
     underscore->hyphen rewriting (poll_inbox -> `c2c poll-inbox`). The few
     tools whose CLI surface lives under a command group (rooms / memory /
     schedule) carry an explicit name correspondence in [cli_overrides];
     tools with no CLI equivalent are listed in [mcp_only]. These two small
     maps are the only hand-maintained correspondence, and the drift-guard
     test (test_c2c_agent_help.ml) asserts every derived CLI command path
     actually resolves against the live binary.

   Behaviour:
   - `c2c agent-help`          -> overview: every topic + one-line summary.
   - `c2c agent-help <topic>`  -> detail for one capability (MCP + CLI).
       <topic> accepts the MCP tool name (`poll_inbox`), the CLI form
       (`poll-inbox`), the fully-qualified MCP name (`mcp__c2c__send`), or
       a group CLI path (`rooms join`); matching is case-insensitive. *)

open Cmdliner.Term.Syntax

module U = Yojson.Safe.Util

(* ------------------------------------------------------------------------ *)
(* Parsed view over an MCP tool_definition JSON value                       *)
(* ------------------------------------------------------------------------ *)

type prop = { p_name : string; p_type : string }

type tool = {
  t_name : string;            (* MCP tool name, e.g. "poll_inbox" *)
  t_desc : string;            (* tool description *)
  t_required : string list;   (* required property names, in declared order *)
  t_props : prop list;        (* all properties (required + optional) *)
}

let parse_tool (j : Yojson.Safe.t) : tool =
  let name = j |> U.member "name" |> U.to_string in
  let desc = try j |> U.member "description" |> U.to_string with _ -> "" in
  let schema = j |> U.member "inputSchema" in
  let required =
    match schema |> U.member "required" with
    | `List xs -> List.filter_map (function `String s -> Some s | _ -> None) xs
    | _ -> []
  in
  let props =
    match schema |> U.member "properties" with
    | `Assoc pairs ->
        List.map
          (fun (pn, pv) ->
            let ty = try pv |> U.member "type" |> U.to_string with _ -> "string" in
            { p_name = pn; p_type = ty })
          pairs
    | _ -> []
  in
  { t_name = name; t_desc = desc; t_required = required; t_props = props }

(* All topics, in registry order. Sourced from the canonical MCP registry. *)
let tools () : tool list = List.map parse_tool C2c_mcp.base_tool_definitions

let topic_names () : string list = List.map (fun t -> t.t_name) (tools ())

(* ------------------------------------------------------------------------ *)
(* MCP tool name  <->  CLI command path                                     *)
(* ------------------------------------------------------------------------ *)

let hyphenate s = String.map (fun c -> if c = '_' then '-' else c) s

(* Tools whose CLI surface is a subcommand of a command group, so the CLI
   path is not derivable by hyphenation alone. Values are the CLI path
   (group + verb) as typed after `c2c`. Verified against the registered
   command verbs; the drift-guard test re-checks each resolves live. *)
let cli_overrides =
  [ "join_room", "rooms join"
  ; "leave_room", "rooms leave"
  ; "delete_room", "rooms delete"
  ; "send_room", "rooms send"
  ; "list_rooms", "rooms list"
  ; "room_history", "rooms history"
  ; "send_room_invite", "rooms invite"
  ; "knock_room", "rooms knock"
  ; "list_room_knocks", "rooms knocks"
  ; "approve_room_knock", "rooms approve-knock"
  ; "deny_room_knock", "rooms deny-knock"
  ; "set_room_visibility", "rooms visibility"
  ; "memory_list", "memory list"
  ; "memory_read", "memory read"
  ; "memory_write", "memory write"
  ; "schedule_set", "schedule set"
  ; "schedule_list", "schedule list"
  ; "schedule_rm", "schedule rm"
  ]

(* Tools with no CLI equivalent — MCP-only surfaces. *)
let mcp_only = [ "set_dnd"; "dnd_status"; "stop_self"; "debug" ]

(* CLI command path for a tool, or [None] when the tool is MCP-only. *)
let cli_path_for (name : string) : string option =
  if List.mem name mcp_only then None
  else
    match List.assoc_opt name cli_overrides with
    | Some p -> Some p
    | None -> Some (hyphenate name)

(* ------------------------------------------------------------------------ *)
(* Example rendering                                                        *)
(* ------------------------------------------------------------------------ *)

let placeholder_for_type = function
  | "boolean" -> "false"
  | "integer" -> "0"
  | "number" -> "0"
  | "array" -> "[\"...\"]"
  | _ (* string / unknown *) -> "\"...\""

let type_of_prop (t : tool) (key : string) : string =
  match List.find_opt (fun p -> p.p_name = key) t.t_props with
  | Some p -> p.p_type
  | None -> "string"

(* `mcp__c2c__<name>({ "<req>": <placeholder>, ... })` — required props only,
   so the example is a minimal valid call. *)
let render_mcp_example (t : tool) : string =
  let body =
    t.t_required
    |> List.map (fun key ->
           Printf.sprintf "\"%s\": %s" key (placeholder_for_type (type_of_prop t key)))
    |> String.concat ", "
  in
  if body = "" then Printf.sprintf "mcp__c2c__%s({})" t.t_name
  else Printf.sprintf "mcp__c2c__%s({ %s })" t.t_name body

(* Property names that are optional (declared but not required). *)
let optional_props (t : tool) : string list =
  List.filter_map
    (fun p -> if List.mem p.p_name t.t_required then None else Some p.p_name)
    t.t_props

(* `c2c <cli-path> <req1> <req2>` — required props as positional placeholders.
   Exact flag/positional syntax is deferred to `--help`; the placeholders name
   what must be supplied regardless of how the CLI takes it. *)
let render_cli_example (t : tool) : string option =
  match cli_path_for t.t_name with
  | None -> None
  | Some path ->
      let args =
        t.t_required |> List.map (fun k -> "<" ^ k ^ ">") |> String.concat " "
      in
      if args = "" then Some (Printf.sprintf "c2c %s" path)
      else Some (Printf.sprintf "c2c %s %s" path args)

(* ------------------------------------------------------------------------ *)
(* Topic resolution                                                         *)
(* ------------------------------------------------------------------------ *)

let strip_prefix ~pre s =
  let lp = String.length pre in
  if String.length s >= lp && String.sub s 0 lp = pre then
    String.sub s lp (String.length s - lp)
  else s

(* Canonicalize a user-typed topic to the MCP tool-name form: lowercase,
   strip the mcp__c2c__ prefix, rewrite hyphens to underscores. *)
let normalize (thing : string) : string =
  let s = String.lowercase_ascii (String.trim thing) in
  let s = strip_prefix ~pre:"mcp__c2c__" s in
  String.map (fun c -> if c = '-' then '_' else c) s

let find_tool (thing : string) : tool option =
  let ts = tools () in
  let norm = normalize thing in
  match List.find_opt (fun t -> t.t_name = norm) ts with
  | Some _ as r -> r
  | None ->
      (* Reverse-lookup by full CLI path, e.g. "rooms join" -> join_room. *)
      let thing_cli = String.lowercase_ascii (String.trim thing) in
      List.find_opt (fun t -> cli_path_for t.t_name = Some thing_cli) ts

(* ------------------------------------------------------------------------ *)
(* Output                                                                   *)
(* ------------------------------------------------------------------------ *)

(* First sentence of a description: up to (and including) the first period
   that is followed by a space or end-of-string, so abbreviations like
   "broker.log" mid-sentence don't truncate it early. *)
let first_sentence s =
  let s = String.trim s in
  let n = String.length s in
  let rec find i =
    if i >= n then None
    else if s.[i] = '.' && (i + 1 >= n || s.[i + 1] = ' ') then Some i
    else find (i + 1)
  in
  match find 0 with Some i -> String.sub s 0 (i + 1) | None -> s

let render_detail (t : tool) : string =
  let buf = Buffer.create 512 in
  Buffer.add_string buf (Printf.sprintf "%s — %s\n\n" t.t_name t.t_desc);
  Buffer.add_string buf "MCP tool call:\n";
  Buffer.add_string buf (Printf.sprintf "  %s\n" (render_mcp_example t));
  (match optional_props t with
   | [] -> ()
   | opts -> Buffer.add_string buf (Printf.sprintf "  optional: %s\n" (String.concat ", " opts)));
  Buffer.add_string buf "\nCLI:\n";
  (match render_cli_example t with
   | None -> Buffer.add_string buf "  (no direct CLI equivalent — use the MCP tool)\n"
   | Some cli ->
       Buffer.add_string buf (Printf.sprintf "  %s\n" cli);
       (match cli_path_for t.t_name with
        | Some path -> Buffer.add_string buf (Printf.sprintf "  (run `c2c %s --help` for exact flags)\n" path)
        | None -> ()));
  Buffer.contents buf

let render_overview () : string =
  let buf = Buffer.create 2048 in
  Buffer.add_string buf "c2c agent-help — MCP tool call + CLI example for each c2c capability\n\n";
  Buffer.add_string buf "Usage:\n";
  Buffer.add_string buf "  c2c agent-help            # this overview\n";
  Buffer.add_string buf "  c2c agent-help <topic>    # MCP call + CLI example for one capability\n\n";
  Buffer.add_string buf
    "<topic> accepts the MCP tool name (poll_inbox), the CLI form (poll-inbox),\n\
     the qualified MCP name (mcp__c2c__send), or a group path (rooms join).\n\n";
  Buffer.add_string buf "Topics:\n\n";
  List.iter
    (fun t ->
      Buffer.add_string buf (Printf.sprintf "  %-22s %s\n" t.t_name (first_sentence t.t_desc)))
    (tools ());
  Buffer.add_string buf
    "\nMCP tools are called as mcp__c2c__<name>; the CLI fallback works without MCP.\n";
  Buffer.contents buf

(* ------------------------------------------------------------------------ *)
(* Cmdliner wiring                                                          *)
(* ------------------------------------------------------------------------ *)

let run (thing : string option) : unit =
  match thing with
  | None -> print_string (render_overview ())
  | Some t -> (
      match find_tool t with
      | Some tool -> print_string (render_detail tool)
      | None ->
          Printf.eprintf
            "error: unknown agent-help topic %S.\nRun `c2c agent-help` to list topics.\n" t;
          exit 2)

let agent_help_cmd =
  let thing =
    Cmdliner.Arg.(
      value
      & pos 0 (some string) None
      & info [] ~docv:"TOPIC"
          ~doc:
            "Capability to explain — an MCP tool name or CLI command (e.g. send, \
             poll-inbox, rooms join). Omit for an overview of all topics.")
  in
  let+ thing = thing in
  run thing

let agent_help =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "agent-help"
       ~doc:"Per-capability MCP tool-call + CLI examples for agents."
       ~man:
         [ `S "DESCRIPTION"
         ; `P
             "For each c2c capability, prints the MCP tool-call example and the \
              equivalent CLI command. Examples are generated at runtime from the MCP \
              tool registry, so they cannot drift from the schema the binary actually \
              serves."
         ; `S "EXAMPLES"
         ; `P "List every topic:"
         ; `Pre "  c2c agent-help"
         ; `P "Show how to send a direct message (MCP + CLI):"
         ; `Pre "  c2c agent-help send"
         ; `P "Show a room capability by its CLI path:"
         ; `Pre "  c2c agent-help rooms join"
         ])
    agent_help_cmd
