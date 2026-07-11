open C2c_cli_helpers
open C2c_commands

let all_cmds =
  [ C2c_send_cmd.send
  ; C2c_list_cmd.list
  ; C2c_find_cmd.find
  ; C2c_list_cmd.sessions
  ; C2c_whoami_cmd.whoami
  ; C2c_inbox_cmd.set_compact
  ; C2c_inbox_cmd.clear_compact
  ; C2c_inbox_cmd.open_pending_reply
  ; C2c_inbox_cmd.check_pending_reply
  ; C2c_inbox_cmd.poll_inbox
  ; C2c_inbox_cmd.peek_inbox
  ; C2c_inbox_cmd.wait_inbox
  ; C2c_approval_cmd.await_reply
  ; C2c_approval_cmd.approval_reply
  ; C2c_approval_cmd.authorize
  ; C2c_approval_cmd.approval_pending_write
  ; C2c_approval_cmd.approval_list
  ; C2c_approval_cmd.approval_show
  ; C2c_approval_cmd.approval_gc
  ; C2c_approval_cmd.resolve_authorizer
  ; C2c_send_cmd.send_all
  ; C2c_sweep_cmd.sweep
  ; C2c_sweep_cmd.registry_prune
  ; C2c_sweep_cmd.sweep_dryrun
  ; C2c_migrate_cmd.migrate_broker
  ; C2c_history_cmd.history
  ; C2c_changelog_cmd.changelog
  ; C2c_health_cmd.health
  ; C2c_health_cmd.ping
  ; C2c_health_cmd.connect (* deprecated alias for ping — B095 *)
  ; C2c_host_cmd.setcap
  ; C2c_health_cmd.status
  ; C2c_health_cmd.verify
  ; C2c_health_cmd.host_id
  ; C2c_git_cmd.git
  ; C2c_register_cmd.register
  ; C2c_register_cmd.deregister
  ; C2c_refresh_peer_cmd.refresh_peer
  ; C2c_coord.coord_cherry_pick_cmd
  ; C2c_coord.coord_group
  ; C2c_broker_cmd.tail_log
  ; C2c_broker_cmd.server_info
  ; C2c_broker_cmd.my_rooms
  ; C2c_broker_cmd.dead_letter
  ; C2c_broker_cmd.prune_rooms
  ; C2c_broker_cmd.get_tmux_location
  ; C2c_dev_cmd.smoke_test_deprecated
  ; C2c_init_cmd.init
  ; C2c_init_cmd.install
  ; C2c_init_cmd.self_update
  ; C2c_init_cmd.update_alias
  ; C2c_init_cmd.upgrade_alias
  ; C2c_uninstall.uninstall_subcmd
  ; C2c_init_cmd.completion_cmd
  ; C2c_glyphs_cmd.list_glyphs
  ; C2c_serve_cmd.serve
  ; C2c_serve_cmd.mcp
  ; C2c_managed_cmd.start
  ; C2c_agent.agent_group
  ; C2c_config_cmd.config_group
  ; C2c_agent.roles_group
  ; C2c_gui_cmd.gui
  ; C2c_managed_cmd.stop
  ; C2c_managed_cmd.restart
  ; C2c_managed_cmd.reset_thread
  ; C2c_dev_cmd.restart_self_deprecated
  ; C2c_instances_cmd.instances_deprecated
  ; C2c_dev_cmd.diag_deprecated
  ; C2c_dev_cmd.dev_group
  ; C2c_doctor_cmd.doctor
  ; C2c_stats_cmd.stats
  ; C2c_rooms.rooms_group
  ; C2c_rooms.room_group
  ; C2c_relay_cmd.relay_group
  ; C2c_relay_pins_cmd.relay_pins
  ; C2c_mesh_cmd.mesh_group
  ; C2c_skills_cmd.skills_group
  ; C2c_stickers.sticker_group
  ; C2c_memory.memory_group
  ; C2c_schedule.schedule_group
  ; C2c_monitor_cmd.monitor
  ; C2c_hook_cmd.hook
  ; C2c_dev_cmd.inject_deprecated
  ; C2c_config_cmd.repo_group
  ; C2c_inject_cmd.screen
  ; C2c_statefile_cmd.statefile_top
  ; C2c_statefile_cmd.debug_group
  ; C2c_statefile_cmd.oc_plugin_group
  ; C2c_statefile_cmd.cc_plugin_group
  ; C2c_supervisor_cmd.supervisor_group
  ; C2c_deliver_watch.deliver_group
  ; C2c_commands_cmd.commands_by_safety
  ; C2c_agent_help.agent_help
  ; C2c_watch.watch_cmd
  ; C2c_root_cmd.help
  ]

let run () =
  C2c_root_cmd.try_fast_path ();
  C2c_root_cmd.sanitize_help_env ();
  for i = 0 to Array.length Sys.argv - 1 do
    if Sys.argv.(i) = "-h" then Sys.argv.(i) <- "--help"
  done;
  let is_agent = is_agent_session () in
  let tier_grouped_man = C2c_commands_cmd.commands_man is_agent in
  let visible_cmds = filter_commands ~cmds:all_cmds in
  exit
    (Cmdliner.Cmd.eval
       (Cmdliner.Cmd.group ~default:C2c_root_cmd.default_term
          (Cmdliner.Cmd.info "c2c" ~version:(version_string ())
             ~doc:"c2c — peer-to-peer messaging for AI agents"
             ~man:
               ([ `S "GETTING STARTED"
                ; `P
                    "New to c2c? Run $(b,c2c init) to configure your client, \
                     register, and join the swarm-lounge room in one step."
                ; `P
                    "Then try: $(b,c2c list) to see peers, $(b,c2c send \
                     ALIAS MSG) to message someone, or $(b,c2c rooms) to \
                     join a room."
                ; `P
                    "Messaging across machines? The public relay defaults \
                     to $(b,https://relay.c2c.im) — see $(b,c2c relay) and \
                     $(b,c2c relay setup --help)."
                ; `P "For full command reference see COMMANDS below."
                ; `S "DESCRIPTION"
                ; `P
                    "c2c is a peer-to-peer messaging broker between AI coding \
                     sessions. Use subcommands to interact with the broker."
                ; `S "EXIT CODES"
                ; `P "c2c uses standard exit codes:"
                ; `Noblank
                ; `P
                    "123 — operational error (e.g., relay unreachable, broker \
                     unreachable, or registration failed)"
                ; `Noblank
                ; `P
                    "124 — bad command-line flag or argument — check your \
                     syntax"
                ; `Noblank
                ; `P
                    "125 — bug in c2c — please report at \
                     https://github.com/clankercode/c2c/issues"
                ]
               @ tier_grouped_man))
          visible_cmds))
