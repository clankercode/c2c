(* c2c_glyphs_cmd - list-glyphs command assembly.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open Cmdliner.Term.Syntax
open C2c_cli_helpers

(* .collab/design/2026-06-26-c2c-list-glyphs-registry.md — emit the canonical
   c2c TUI glyph registry (message direction, broker route, liveness,
   subagent-registration vocabulary + ascii fallbacks + semantic colors +
   action tokens + message-sources) as JSON so clients (pi-c2c today) can
   fetch the vocabulary at launch instead of hardcoding it.

   HARD CONSTRAINT: this command MUST be always-runnable in any session.
   pi-c2c invokes it with the host session env (which may set a session-id
   var that flips `is_agent_session ()` true). It is therefore classified
   Tier1 in command_tier_map so `filter_commands` never drops it from the
   dispatchable cmdliner group. "Hidden from help by default" is handled in
   the help-text layer via `hidden_unless_dev` + the global `--dev` flag,
   NOT via the tier filter (which would make it unrunnable). *)
let list_glyphs_cmd =
  let compact =
    Cmdliner.Arg.(value & flag & info [ "compact" ]
      ~doc:"Emit single-line JSON instead of pretty-printed.")
  in
  let+ compact = compact in
  let json = Glyphs.to_json () in
  if compact then print_endline (Yojson.Safe.to_string json)
  else print_json json

let list_glyphs : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "list-glyphs"
      ~doc:"(dev) emit the canonical c2c TUI glyph registry as JSON")
    list_glyphs_cmd
