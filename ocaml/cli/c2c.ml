(* c2c CLI — human-friendly command-line interface to the c2c broker.
   When invoked with no arguments, shows help.
   Otherwise dispatches to CLI subcommands. *)

open C2c_cli_helpers
open Cmdliner.Term.Syntax
open C2c_mcp
open C2c_types
open C2c_commands
open C2c_utils
open C2c_agent

(* Send commands moved to c2c_send_cmd.ml. *)

(* List/sessions command island moved to c2c_list_cmd.ml. *)

(* Whoami command island moved to c2c_whoami_cmd.ml. *)

(* Inbox/compact/pending command island moved to c2c_inbox_cmd.ml. *)

(* Health, connect, verify, host-id subcommands extracted to c2c_health_cmd.ml *)

(* Register/deregister command island moved to c2c_register_cmd.ml. *)

(* Monitor subcommand extracted to c2c_monitor_cmd.ml *)


(* Relay subcommands extracted to c2c_relay_cmd.ml *)
(* Mesh subcommands extracted to c2c_mesh_cmd.ml *)

(* --- main entry point ----------------------------------------------------- *)

(* Send commands extracted to c2c_send_cmd.ml. *)
(* List/sessions commands extracted to c2c_list_cmd.ml. *)
(* Whoami command extracted to c2c_whoami_cmd.ml. *)
(* Inbox/compact/pending commands extracted to c2c_inbox_cmd.ml. *)

(* Approval subcommands extracted to c2c_approval_cmd.ml *)

(* Register/deregister commands extracted to c2c_register_cmd.ml. *)

(* Phase 1 split: install/setup code moved to c2c_setup.ml *)

(* Init/setup command island moved to c2c_init_cmd.ml. *)

(* MCP stdio command island moved to c2c_serve_cmd.ml. *)

(* Managed-instance commands moved to c2c_instances_cmd.ml. *)

(* --- doctor command group moved to c2c_doctor_cmd.ml --------------------- *)

(* Root landing, help, and startup fast paths moved to c2c_root_cmd.ml. *)

let dev_group =
  let info = Cmdliner.Cmd.info "dev"
    ~doc:"Developer/operator commands for c2c swarm internals."
  in
  (* Tier-aware subcommand filtering: Tier 2 subcommands (instances, worktree,
     sitrep, peer-pass, status) are always visible. Tier 3/4 subcommands (diag,
     restart-self, smoke-test, inject) are hidden in agent sessions. *)
  let tier2_subs =
    [ C2c_instances_cmd.dev_instances_sub
    ; C2c_worktree.worktree_group; C2c_sitrep.sitrep_group
    ; C2c_peer_pass.peer_pass_group ]
  in
  let tier3_subs = [ C2c_instances_cmd.diag; C2c_managed_cmd.restart_self; C2c_host_cmd.smoke_test; C2c_inject_cmd.inject ] in
  let visible_subs =
    if is_agent_session () then tier2_subs
    else tier2_subs @ tier3_subs
  in
  Cmdliner.Cmd.group info ~default:C2c_instances_cmd.dev_instances_cmd visible_subs

(* Deprecated top-level aliases — warn on stderr BEFORE execution.
   We prepend a side-effecting term via `and+` that fires during argument
   evaluation (before the command body), using Cmdliner.Term.const with
   a thunk forced by map. *)
let deprecation_wrap ~old_name ~new_path (cmd_term : unit Cmdliner.Term.t) : unit Cmdliner.Term.t =
  let open Cmdliner.Term in
  let warn_term =
    const () |> map (fun () ->
      Printf.eprintf "[DEPRECATED] c2c %s is now c2c %s. Updating in 2 releases.\n%!" old_name new_path)
  in
  let+ () = warn_term and+ () = cmd_term in
  ()

let diag_deprecated =
  Cmdliner.Cmd.v (Cmdliner.Cmd.info "diag" ~doc:"[DEPRECATED: use c2c dev diag]")
    (deprecation_wrap ~old_name:"diag" ~new_path:"dev diag" C2c_instances_cmd.diag_cmd)

let restart_self_deprecated =
  Cmdliner.Cmd.v (Cmdliner.Cmd.info "restart-self" ~doc:"[DEPRECATED: use c2c dev restart-self]")
    (deprecation_wrap ~old_name:"restart-self" ~new_path:"dev restart-self" C2c_managed_cmd.restart_self_cmd)

let smoke_test_deprecated =
  Cmdliner.Cmd.v (Cmdliner.Cmd.info "smoke-test" ~doc:"[DEPRECATED: use c2c dev smoke-test]")
    (deprecation_wrap ~old_name:"smoke-test" ~new_path:"dev smoke-test" C2c_host_cmd.smoke_test_cmd)

let inject_deprecated =
  Cmdliner.Cmd.v (Cmdliner.Cmd.info "inject" ~doc:"[DEPRECATED: use c2c dev inject]")
    (deprecation_wrap ~old_name:"inject" ~new_path:"dev inject" C2c_inject_cmd.inject_cmd)

let () =
  C2c_root_cmd.try_fast_path ();
  C2c_root_cmd.sanitize_help_env ();
  for i = 0 to Array.length Sys.argv - 1 do
    if Sys.argv.(i) = "-h" then Sys.argv.(i) <- "--help"
  done;
  let is_agent = is_agent_session () in
  let tier_grouped_man = C2c_commands_cmd.commands_man is_agent in
  let all_cmds =
    [ C2c_send_cmd.send; C2c_list_cmd.list; C2c_list_cmd.sessions; C2c_whoami_cmd.whoami; C2c_inbox_cmd.set_compact; C2c_inbox_cmd.clear_compact; C2c_inbox_cmd.open_pending_reply; C2c_inbox_cmd.check_pending_reply; C2c_inbox_cmd.poll_inbox; C2c_inbox_cmd.peek_inbox; C2c_approval_cmd.await_reply; C2c_approval_cmd.approval_reply; C2c_approval_cmd.authorize; C2c_approval_cmd.approval_pending_write; C2c_approval_cmd.approval_list; C2c_approval_cmd.approval_show; C2c_approval_cmd.approval_gc; C2c_approval_cmd.resolve_authorizer; C2c_send_cmd.send_all; C2c_sweep_cmd.sweep; C2c_sweep_cmd.registry_prune
    ; C2c_sweep_cmd.sweep_dryrun; C2c_migrate_cmd.migrate_broker; C2c_history_cmd.history; C2c_health_cmd.health; C2c_health_cmd.connect; C2c_host_cmd.setcap; C2c_health_cmd.status; C2c_health_cmd.verify; C2c_health_cmd.host_id; C2c_git_cmd.git; C2c_register_cmd.register; C2c_register_cmd.deregister; C2c_refresh_peer_cmd.refresh_peer; C2c_coord.coord_cherry_pick_cmd; C2c_coord.coord_group
    ; C2c_broker_cmd.tail_log; C2c_broker_cmd.server_info; C2c_broker_cmd.my_rooms; C2c_broker_cmd.dead_letter; C2c_broker_cmd.prune_rooms; C2c_broker_cmd.get_tmux_location; smoke_test_deprecated; C2c_init_cmd.init; C2c_init_cmd.install; C2c_init_cmd.self_update; C2c_init_cmd.update_alias; C2c_init_cmd.upgrade_alias; C2c_uninstall.uninstall_subcmd; C2c_init_cmd.completion_cmd; C2c_glyphs_cmd.list_glyphs
    ; C2c_serve_cmd.serve; C2c_serve_cmd.mcp; C2c_managed_cmd.start; C2c_agent.agent_group; C2c_config_cmd.config_group; C2c_agent.roles_group; C2c_gui_cmd.gui; C2c_managed_cmd.stop; C2c_managed_cmd.restart; C2c_managed_cmd.reset_thread; restart_self_deprecated; C2c_instances_cmd.instances_deprecated; diag_deprecated; dev_group; C2c_doctor_cmd.doctor; C2c_stats_cmd.stats; C2c_rooms.rooms_group; C2c_rooms.room_group    ; C2c_relay_cmd.relay_group; C2c_relay_pins_cmd.relay_pins; C2c_mesh_cmd.mesh_group; C2c_skills_cmd.skills_group; C2c_stickers.sticker_group; C2c_memory.memory_group; C2c_schedule.schedule_group; C2c_monitor_cmd.monitor; C2c_hook_cmd.hook; inject_deprecated; C2c_config_cmd.repo_group; C2c_inject_cmd.screen; C2c_statefile_cmd.statefile_top; C2c_statefile_cmd.debug_group; C2c_statefile_cmd.oc_plugin_group; C2c_statefile_cmd.cc_plugin_group; C2c_supervisor_cmd.supervisor_group; C2c_deliver_watch.deliver_group; C2c_commands_cmd.commands_by_safety; C2c_agent_help.agent_help; C2c_watch.watch_cmd; C2c_root_cmd.help ]
  in
  let visible_cmds = filter_commands ~cmds:all_cmds in
  exit
    (Cmdliner.Cmd.eval
       (Cmdliner.Cmd.group ~default:C2c_root_cmd.default_term
          (Cmdliner.Cmd.info "c2c"
             ~version:(version_string ())
             ~doc:"c2c — peer-to-peer messaging for AI agents"
             ~man:
                ([ `S "GETTING STARTED"
                ; `P "New to c2c? Run $(b,c2c init) to configure your client, register, and join the swarm-lounge room in one step."
                ; `P "Then try: $(b,c2c list) to see peers, $(b,c2c send ALIAS MSG) to message someone, or $(b,c2c rooms) to join a room."
                ; `P "For full command reference see COMMANDS below."
                ; `S "DESCRIPTION"
                ; `P "c2c is a peer-to-peer messaging broker between AI coding sessions. Use subcommands to interact with the broker."
                ; `S "EXIT CODES"
                ; `P "c2c uses standard exit codes:"
                ; `Noblank; `P "123 — operational error (e.g., relay unreachable, broker unreachable, or registration failed)"
                ; `Noblank; `P "124 — bad command-line flag or argument — check your syntax"
                ; `Noblank; `P "125 — bug in c2c — please report at https://github.com/clankercode/c2c/issues"
                ] @ tier_grouped_man))
             visible_cmds))
