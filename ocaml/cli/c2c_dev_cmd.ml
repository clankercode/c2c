open C2c_cli_helpers
open C2c_commands
open Cmdliner.Term.Syntax

let dev_group =
  let info =
    Cmdliner.Cmd.info "dev"
      ~doc:"Developer/operator commands for c2c swarm internals."
  in
  (* Tier-aware subcommand filtering: Tier 2 subcommands (instances, worktree,
     sitrep, peer-pass, status) are always visible. Tier 3/4 subcommands (diag,
     restart-self, smoke-test, inject) are hidden in agent sessions. *)
  let tier2_subs =
    [ C2c_instances_cmd.dev_instances_sub
    ; C2c_worktree.worktree_group
    ; C2c_sitrep.sitrep_group
    ; C2c_peer_pass.peer_pass_group
    ; C2c_detect_agent_cmd.detect_agent_type
    ]
  in
  let tier3_subs =
    [ C2c_instances_cmd.diag
    ; C2c_managed_cmd.restart_self
    ; C2c_host_cmd.smoke_test
    ; C2c_inject_cmd.inject
    ]
  in
  let visible_subs =
    if is_agent_session () then tier2_subs else tier2_subs @ tier3_subs
  in
  Cmdliner.Cmd.group info ~default:C2c_instances_cmd.dev_instances_cmd visible_subs

(* Deprecated top-level aliases — warn on stderr BEFORE execution.
   We prepend a side-effecting term via `and+` that fires during argument
   evaluation (before the command body), using Cmdliner.Term.const with
   a thunk forced by map. *)
let deprecation_wrap ~old_name ~new_path
    (cmd_term : unit Cmdliner.Term.t) : unit Cmdliner.Term.t =
  let open Cmdliner.Term in
  let warn_term =
    const ()
    |> map (fun () ->
           Printf.eprintf
             "[DEPRECATED] c2c %s is now c2c %s. Updating in 2 releases.\n%!"
             old_name new_path)
  in
  let+ () = warn_term and+ () = cmd_term in
  ()

let diag_deprecated =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "diag" ~doc:"[DEPRECATED: use c2c dev diag]")
    (deprecation_wrap ~old_name:"diag" ~new_path:"dev diag"
       C2c_instances_cmd.diag_cmd)

let restart_self_deprecated =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "restart-self"
       ~doc:"[DEPRECATED: use c2c dev restart-self]")
    (deprecation_wrap ~old_name:"restart-self" ~new_path:"dev restart-self"
       C2c_managed_cmd.restart_self_cmd)

let smoke_test_deprecated =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "smoke-test"
       ~doc:"[DEPRECATED: use c2c dev smoke-test]")
    (deprecation_wrap ~old_name:"smoke-test" ~new_path:"dev smoke-test"
       C2c_host_cmd.smoke_test_cmd)

let inject_deprecated =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "inject" ~doc:"[DEPRECATED: use c2c dev inject]")
    (deprecation_wrap ~old_name:"inject" ~new_path:"dev inject"
       C2c_inject_cmd.inject_cmd)
