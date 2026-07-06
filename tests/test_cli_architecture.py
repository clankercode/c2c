"""Architecture guards for the OCaml CLI refactor."""

import re
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]


def assert_ocaml_value_defined(src: str, name: str) -> None:
    assert re.search(rf"\blet\s+{re.escape(name)}\b", src), (
        f"expected OCaml value {name!r} to be defined"
    )


def assert_ocaml_value_extracted(c2c_src: str, module_src: str, name: str) -> None:
    assert re.search(rf"\blet\s+{re.escape(name)}\b", c2c_src) is None, (
        f"expected OCaml value {name!r} to be extracted from c2c.ml"
    )
    assert_ocaml_value_defined(module_src, name)


def assert_ocaml_type_extracted(c2c_src: str, module_src: str, name: str) -> None:
    assert re.search(rf"\btype\s+{re.escape(name)}\b", c2c_src) is None, (
        f"expected OCaml type {name!r} to be extracted from c2c.ml"
    )
    assert re.search(rf"\btype\s+{re.escape(name)}\b", module_src), (
        f"expected OCaml type {name!r} to be defined"
    )


def assert_token_reference(src: str, dotted_name: str) -> None:
    assert re.search(rf"\b{re.escape(dotted_name)}(?![A-Za-z0-9_])", src), (
        f"expected token-bounded reference to {dotted_name!r}"
    )


def test_doctor_command_is_extracted_from_monolithic_cli():
    """The doctor command assembly should live outside ocaml/cli/c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    doctor_ml = REPO / "ocaml" / "cli" / "c2c_doctor_cmd.ml"

    assert doctor_ml.exists(), "expected extracted doctor command module"
    doctor_src = doctor_ml.read_text(encoding="utf-8")

    assert "let doctor_cmd =" not in c2c_ml
    assert "let doctor =" not in c2c_ml
    assert "C2c_doctor_cmd.doctor" in c2c_ml
    assert "let doctor_cmd =" in doctor_src
    assert "let doctor =" in doctor_src


def test_inject_and_screen_commands_are_extracted_from_monolithic_cli():
    """PTY injection and screen capture should live outside ocaml/cli/c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    inject_ml = REPO / "ocaml" / "cli" / "c2c_inject_cmd.ml"

    assert inject_ml.exists(), "expected extracted inject/screen command module"
    inject_src = inject_ml.read_text(encoding="utf-8")

    assert "let inject_cmd =" not in c2c_ml
    assert "let screen_cmd =" not in c2c_ml
    assert "C2c_inject_cmd.inject_cmd" in c2c_ml
    assert "C2c_inject_cmd.inject" in c2c_ml
    assert "C2c_inject_cmd.screen" in c2c_ml
    assert "let inject_cmd =" in inject_src
    assert "let screen_cmd =" in inject_src


def test_init_setup_commands_are_extracted_from_monolithic_cli():
    """Onboarding/setup commands should live outside ocaml/cli/c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    init_ml = REPO / "ocaml" / "cli" / "c2c_init_cmd.ml"
    config_ml = REPO / "ocaml" / "cli" / "c2c_config_cmd.ml"

    assert init_ml.exists(), "expected extracted init/setup command module"
    init_src = init_ml.read_text(encoding="utf-8")
    config_src = config_ml.read_text(encoding="utf-8") if config_ml.exists() else ""

    assert "let init_cmd =" not in c2c_ml
    assert "let completion_cmd =" not in c2c_ml
    assert "let self_update_cmd =" not in c2c_ml
    assert "let install =" not in c2c_ml
    assert "let repo_config_path () =" not in c2c_ml
    assert "C2c_init_cmd.init" in c2c_ml
    assert "C2c_init_cmd.install" in c2c_ml
    assert "C2c_init_cmd.self_update" in c2c_ml
    assert "C2c_init_cmd.completion_cmd" in c2c_ml
    assert "C2c_init_cmd.repo_config_path" in (c2c_ml + config_src)
    assert "let init_cmd =" in init_src
    assert "let completion_cmd =" in init_src
    assert "let self_update_cmd =" in init_src
    assert "let install =" in init_src
    assert "let repo_config_path () =" in init_src


def test_instances_and_diag_commands_are_extracted_from_monolithic_cli():
    """Managed-instance listing, cleanup, and diagnostics should be modular."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    instances_ml = REPO / "ocaml" / "cli" / "c2c_instances_cmd.ml"

    assert instances_ml.exists(), "expected extracted instances command module"
    instances_src = instances_ml.read_text(encoding="utf-8")

    assert "let instances_cmd =" not in c2c_ml
    assert "let clean_stale_cmd =" not in c2c_ml
    assert "let instances_gc_cmd =" not in c2c_ml
    assert "let diag_cmd =" not in c2c_ml
    assert "let instances_deprecated_term =" not in c2c_ml
    assert "C2c_instances_cmd.dev_instances_sub" in c2c_ml
    assert "C2c_instances_cmd.diag" in c2c_ml
    assert "C2c_instances_cmd.diag_cmd" in c2c_ml
    assert "C2c_instances_cmd.instances_deprecated" in c2c_ml
    assert "let instances_cmd =" in instances_src
    assert "let clean_stale_cmd =" in instances_src
    assert "let instances_gc_cmd =" in instances_src
    assert "let diag_cmd =" in instances_src
    assert "let instances_deprecated_term =" in instances_src


def test_managed_lifecycle_commands_are_extracted_from_monolithic_cli():
    """Managed-session lifecycle commands should live outside ocaml/cli/c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    managed_ml = REPO / "ocaml" / "cli" / "c2c_managed_cmd.ml"

    assert managed_ml.exists(), "expected extracted managed lifecycle command module"
    managed_src = managed_ml.read_text(encoding="utf-8")

    for name in [
        "roles_dir",
        "role_file_path",
        "read_role",
        "yaml_scalar",
        "write_role",
        "prompt_for_role",
        "default_kickoff_prompt",
        "agent_file_path",
        "render_role_for_client",
        "resolve_role_pmodel_for_launch",
        "write_agent_file",
        "get_opencode_theme",
        "start_cmd",
        "start",
        "stop_cmd",
        "stop",
        "restart_cmd",
        "restart",
        "reset_thread_cmd",
        "reset_thread",
        "restart_self_cmd",
        "restart_self",
    ]:
        assert_ocaml_value_extracted(c2c_ml, managed_src, name)

    assert_token_reference(c2c_ml, "C2c_managed_cmd.start")
    assert_token_reference(c2c_ml, "C2c_managed_cmd.stop")
    assert_token_reference(c2c_ml, "C2c_managed_cmd.restart")
    assert_token_reference(c2c_ml, "C2c_managed_cmd.reset_thread")
    assert_token_reference(c2c_ml, "C2c_managed_cmd.restart_self")
    assert_token_reference(c2c_ml, "C2c_managed_cmd.restart_self_cmd")


def test_gui_command_is_extracted_from_monolithic_cli():
    """GUI launch and batch-smoke helpers should live outside ocaml/cli/c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    gui_ml = REPO / "ocaml" / "cli" / "c2c_gui_cmd.ml"

    assert gui_ml.exists(), "expected extracted GUI command module"
    gui_src = gui_ml.read_text(encoding="utf-8")

    for name in [
        "find_gui_binary",
        "registration_to_json",
        "room_to_json",
        "gui_batch",
        "gui_cmd",
        "gui",
    ]:
        assert_ocaml_value_extracted(c2c_ml, gui_src, name)

    assert_ocaml_type_extracted(c2c_ml, gui_src, "gui_batch_check")
    assert_token_reference(c2c_ml, "C2c_gui_cmd.gui")


def test_config_and_repo_commands_are_extracted_from_monolithic_cli():
    """Local config and repo supervisor commands should be modular."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    config_ml = REPO / "ocaml" / "cli" / "c2c_config_cmd.ml"

    assert config_ml.exists(), "expected extracted config/repo command module"
    config_src = config_ml.read_text(encoding="utf-8")

    for name in [
        "c2c_config_path",
        "config_read",
        "config_write",
        "config_set",
        "valid_generation_clients",
        "config_show_term",
        "config_generation_client_term",
        "config_show_cmd",
        "config_generation_client_cmd",
        "config_group",
        "repo_set_supervisor_cmd",
        "repo_show_cmd",
        "repo_group",
    ]:
        assert_ocaml_value_extracted(c2c_ml, config_src, name)

    assert_token_reference(c2c_ml, "C2c_config_cmd.config_group")
    assert_token_reference(c2c_ml, "C2c_config_cmd.repo_group")


def test_statefile_and_plugin_commands_are_extracted_from_monolithic_cli():
    """Statefile/debug/plugin plumbing commands should live outside c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    statefile_ml = REPO / "ocaml" / "cli" / "c2c_statefile_cmd.ml"

    assert statefile_ml.exists(), "expected extracted statefile/plugin command module"
    statefile_src = statefile_ml.read_text(encoding="utf-8")

    for name in [
        "statefile_cmd",
        "statefile_top",
        "debug_statefile_log_cmd",
        "debug_statefile_checkpoint_cmd",
        "debug_group",
        "oc_plugin_stream_write_statefile_cmd",
        "oc_plugin_message_json",
        "oc_plugin_drain_inbox_to_spool_cmd",
        "oc_plugin_group",
        "cc_plugin_write_statefile_cmd",
        "cc_plugin_group",
    ]:
        assert_ocaml_value_extracted(c2c_ml, statefile_src, name)

    assert_token_reference(c2c_ml, "C2c_statefile_cmd.statefile_top")
    assert_token_reference(c2c_ml, "C2c_statefile_cmd.debug_group")
    assert_token_reference(c2c_ml, "C2c_statefile_cmd.oc_plugin_group")
    assert_token_reference(c2c_ml, "C2c_statefile_cmd.cc_plugin_group")


def test_supervisor_commands_are_extracted_from_monolithic_cli():
    """Supervisor reply helpers should live outside ocaml/cli/c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    supervisor_ml = REPO / "ocaml" / "cli" / "c2c_supervisor_cmd.ml"

    assert supervisor_ml.exists(), "expected extracted supervisor command module"
    supervisor_src = supervisor_ml.read_text(encoding="utf-8")

    for name in [
        "supervisor_send",
        "supervisor_answer_cmd",
        "supervisor_reject_question_cmd",
        "supervisor_approve_cmd",
        "supervisor_reject_permission_cmd",
        "supervisor_group",
    ]:
        assert_ocaml_value_extracted(c2c_ml, supervisor_src, name)

    assert_token_reference(c2c_ml, "C2c_supervisor_cmd.supervisor_group")


def test_mesh_command_is_extracted_from_monolithic_cli():
    """Relay mesh inspection should live outside ocaml/cli/c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    mesh_ml = REPO / "ocaml" / "cli" / "c2c_mesh_cmd.ml"

    assert mesh_ml.exists(), "expected extracted mesh command module"
    mesh_src = mesh_ml.read_text(encoding="utf-8")

    for name in [
        "mesh_status_cmd",
        "mesh_status",
        "mesh_group",
    ]:
        assert_ocaml_value_extracted(c2c_ml, mesh_src, name)

    assert_token_reference(c2c_ml, "C2c_mesh_cmd.mesh_group")


def test_command_listing_is_extracted_from_monolithic_cli():
    """Safety-tier command listings should live outside ocaml/cli/c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    commands_cmd_ml = REPO / "ocaml" / "cli" / "c2c_commands_cmd.ml"

    assert commands_cmd_ml.exists(), "expected extracted command-listing module"
    commands_cmd_src = commands_cmd_ml.read_text(encoding="utf-8")

    for name in [
        "commands_by_safety_cmd",
        "commands_by_safety",
        "commands_man",
        "fast_path_commands",
    ]:
        assert_ocaml_value_extracted(c2c_ml, commands_cmd_src, name)

    assert_token_reference(c2c_ml, "C2c_commands_cmd.commands_by_safety")
    assert_token_reference(c2c_ml, "C2c_commands_cmd.commands_man")
    assert_token_reference(c2c_ml, "C2c_commands_cmd.fast_path_commands")


def test_sweep_commands_are_extracted_from_monolithic_cli():
    """Sweep and registry-prune commands should live outside ocaml/cli/c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    sweep_ml = REPO / "ocaml" / "cli" / "c2c_sweep_cmd.ml"

    assert sweep_ml.exists(), "expected extracted sweep command module"
    sweep_src = sweep_ml.read_text(encoding="utf-8")

    for name in [
        "instances_dir_base",
        "c2c_start_session_ids",
        "default_prune_patterns",
        "registry_prune_cmd",
        "force_flag",
        "sweep_cmd",
        "sweep_dryrun_run",
        "sweep_dryrun_cmd",
        "sweep_dryrun",
        "sweep",
        "registry_prune",
    ]:
        assert_ocaml_value_extracted(c2c_ml, sweep_src, name)

    assert_token_reference(c2c_ml, "C2c_sweep_cmd.sweep")
    assert_token_reference(c2c_ml, "C2c_sweep_cmd.registry_prune")
    assert_token_reference(c2c_ml, "C2c_sweep_cmd.sweep_dryrun")


def test_hook_commands_are_extracted_from_monolithic_cli():
    """Claude Code hook command assembly should live outside ocaml/cli/c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    hook_ml = REPO / "ocaml" / "cli" / "c2c_hook_cmd.ml"

    assert hook_ml.exists(), "expected extracted hook command module"
    hook_src = hook_ml.read_text(encoding="utf-8")

    for name in [
        "min_hook_runtime_ms",
        "sleep_to_min_runtime",
        "hook_post_tool_cmd",
        "hook_post_tool",
        "hook_stop_cmd",
        "hook_stop",
        "hook",
    ]:
        assert_ocaml_value_extracted(c2c_ml, hook_src, name)

    assert_token_reference(c2c_ml, "C2c_hook_cmd.hook")


def test_stats_commands_are_extracted_from_monolithic_cli():
    """Stats command assembly should live outside ocaml/cli/c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    stats_cmd_ml = REPO / "ocaml" / "cli" / "c2c_stats_cmd.ml"

    assert stats_cmd_ml.exists(), "expected extracted stats command module"
    stats_cmd_src = stats_cmd_ml.read_text(encoding="utf-8")

    for name in [
        "stats_cmd",
        "markdown_flag",
        "csv_flag",
        "compact_flag",
        "stats_history_cmd",
        "stats",
    ]:
        assert_ocaml_value_extracted(c2c_ml, stats_cmd_src, name)

    assert_token_reference(c2c_ml, "C2c_stats_cmd.stats")


def test_skills_commands_are_extracted_from_monolithic_cli():
    """Skills command assembly and fast paths should live outside ocaml/cli/c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    skills_ml = REPO / "ocaml" / "cli" / "c2c_skills_cmd.ml"

    assert skills_ml.exists(), "expected extracted skills command module"
    skills_src = skills_ml.read_text(encoding="utf-8")

    for name in [
        "skills_dir",
        "list_subdirs",
        "read_first_lines",
        "parse_skill_frontmatter",
        "skills_list_cmd",
        "skills_serve_cmd",
        "skills_group",
        "fast_path_skills_list",
        "fast_path_skills_serve",
    ]:
        assert_ocaml_value_extracted(c2c_ml, skills_src, name)

    assert_token_reference(c2c_ml, "C2c_skills_cmd.skills_group")
    assert_token_reference(c2c_ml, "C2c_skills_cmd.fast_path_skills_list")
    assert_token_reference(c2c_ml, "C2c_skills_cmd.fast_path_skills_serve")


def test_migrate_broker_command_is_extracted_from_monolithic_cli():
    """Broker migration command assembly should live outside ocaml/cli/c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    migrate_ml = REPO / "ocaml" / "cli" / "c2c_migrate_cmd.ml"

    assert migrate_ml.exists(), "expected extracted migrate-broker command module"
    migrate_src = migrate_ml.read_text(encoding="utf-8")

    for name in [
        "legacy_broker_root",
        "sync_sidecar_for_migration",
        "mcp_config_rewriter_run",
        "suggest_shell_export_run",
        "migrate_broker_run",
        "migrate_broker_cmd",
        "migrate_broker",
    ]:
        assert_ocaml_value_extracted(c2c_ml, migrate_src, name)

    assert_token_reference(c2c_ml, "C2c_migrate_cmd.migrate_broker")


def test_history_command_is_extracted_from_monolithic_cli():
    """Inbox archive history command assembly should live outside ocaml/cli/c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    history_ml = REPO / "ocaml" / "cli" / "c2c_history_cmd.ml"

    assert history_ml.exists(), "expected extracted history command module"
    history_src = history_ml.read_text(encoding="utf-8")

    for name in [
        "history_cmd",
        "history",
    ]:
        assert_ocaml_value_extracted(c2c_ml, history_src, name)

    assert_token_reference(c2c_ml, "C2c_history_cmd.history")


def test_list_glyphs_command_is_extracted_from_monolithic_cli():
    """Glyph registry command assembly should live outside ocaml/cli/c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    glyphs_ml = REPO / "ocaml" / "cli" / "c2c_glyphs_cmd.ml"

    assert glyphs_ml.exists(), "expected extracted glyphs command module"
    glyphs_src = glyphs_ml.read_text(encoding="utf-8")

    for name in [
        "list_glyphs_cmd",
        "list_glyphs",
    ]:
        assert_ocaml_value_extracted(c2c_ml, glyphs_src, name)

    assert_token_reference(c2c_ml, "C2c_glyphs_cmd.list_glyphs")


def test_broker_status_commands_are_extracted_from_monolithic_cli():
    """Small broker/status inspection commands should live outside c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    broker_cmd_ml = REPO / "ocaml" / "cli" / "c2c_broker_cmd.ml"

    assert broker_cmd_ml.exists(), "expected extracted broker/status command module"
    broker_cmd_src = broker_cmd_ml.read_text(encoding="utf-8")

    for name in [
        "get_tmux_location_cmd",
        "tail_log_cmd",
        "server_info_cmd",
        "my_rooms_cmd",
        "dead_letter_cmd",
        "prune_rooms_cmd",
        "tail_log",
        "server_info",
        "my_rooms",
        "dead_letter",
        "prune_rooms",
        "get_tmux_location",
    ]:
        assert_ocaml_value_extracted(c2c_ml, broker_cmd_src, name)

    assert_token_reference(c2c_ml, "C2c_broker_cmd.tail_log")
    assert_token_reference(c2c_ml, "C2c_broker_cmd.server_info")
    assert_token_reference(c2c_ml, "C2c_broker_cmd.my_rooms")
    assert_token_reference(c2c_ml, "C2c_broker_cmd.dead_letter")
    assert_token_reference(c2c_ml, "C2c_broker_cmd.prune_rooms")
    assert_token_reference(c2c_ml, "C2c_broker_cmd.get_tmux_location")


def test_git_wrapper_command_is_extracted_from_monolithic_cli():
    """Git attribution/signing wrapper command assembly should be modular."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    git_cmd_ml = REPO / "ocaml" / "cli" / "c2c_git_cmd.ml"

    assert git_cmd_ml.exists(), "expected extracted git wrapper command module"
    git_cmd_src = git_cmd_ml.read_text(encoding="utf-8")

    for name in [
        "has_author_flag",
        "has_sign_flag",
        "is_signing_subcmd",
        "git_cmd",
        "git",
    ]:
        assert_ocaml_value_extracted(c2c_ml, git_cmd_src, name)

    assert_token_reference(c2c_ml, "C2c_git_cmd.git")


def test_host_utility_commands_are_extracted_from_monolithic_cli():
    """Host setup and broker smoke commands should live outside c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    host_cmd_ml = REPO / "ocaml" / "cli" / "c2c_host_cmd.ml"

    assert host_cmd_ml.exists(), "expected extracted host utility command module"
    host_cmd_src = host_cmd_ml.read_text(encoding="utf-8")

    for name in [
        "setcap_cmd",
        "setcap",
        "smoke_test_cmd",
        "smoke_test",
    ]:
        assert_ocaml_value_extracted(c2c_ml, host_cmd_src, name)

    assert_token_reference(c2c_ml, "C2c_host_cmd.setcap")
    assert_token_reference(c2c_ml, "C2c_host_cmd.smoke_test")
    assert_token_reference(c2c_ml, "C2c_host_cmd.smoke_test_cmd")


def test_relay_pins_commands_are_extracted_from_monolithic_cli():
    """Relay TOFU pin operator commands should live outside c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    relay_pins_ml = REPO / "ocaml" / "cli" / "c2c_relay_pins_cmd.ml"

    assert relay_pins_ml.exists(), "expected extracted relay-pins command module"
    relay_pins_src = relay_pins_ml.read_text(encoding="utf-8")

    for name in [
        "relay_pins_delete_cmd",
        "relay_pins_delete",
        "relay_pins_rotate_cmd",
        "relay_pins_rotate",
        "relay_pins_list_cmd",
        "relay_pins",
    ]:
        assert_ocaml_value_extracted(c2c_ml, relay_pins_src, name)

    assert_token_reference(c2c_ml, "C2c_relay_pins_cmd.relay_pins")


def test_refresh_peer_command_is_extracted_from_monolithic_cli():
    """Stale-registration repair command assembly should be modular."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    refresh_ml = REPO / "ocaml" / "cli" / "c2c_refresh_peer_cmd.ml"

    assert refresh_ml.exists(), "expected extracted refresh-peer command module"
    refresh_src = refresh_ml.read_text(encoding="utf-8")

    for name in [
        "refresh_peer_run",
        "refresh_peer_cmd",
        "refresh_peer",
    ]:
        assert_ocaml_value_extracted(c2c_ml, refresh_src, name)

    assert_token_reference(c2c_ml, "C2c_refresh_peer_cmd.refresh_peer")


def test_serve_commands_are_extracted_from_monolithic_cli():
    """MCP stdio command assembly should live outside c2c.ml."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    serve_ml = REPO / "ocaml" / "cli" / "c2c_serve_cmd.ml"

    assert serve_ml.exists(), "expected extracted serve/MCP command module"
    serve_src = serve_ml.read_text(encoding="utf-8")

    for name in [
        "serve_cmd",
        "serve",
        "mcp",
    ]:
        assert_ocaml_value_extracted(c2c_ml, serve_src, name)

    assert_token_reference(c2c_ml, "C2c_serve_cmd.serve")
    assert_token_reference(c2c_ml, "C2c_serve_cmd.mcp")


def test_inbox_commands_are_extracted_from_monolithic_cli():
    """Inbox, compaction, and pending-reply command assembly should be modular."""
    c2c_ml = (REPO / "ocaml" / "cli" / "c2c.ml").read_text(encoding="utf-8")
    inbox_ml = REPO / "ocaml" / "cli" / "c2c_inbox_cmd.ml"

    assert inbox_ml.exists(), "expected extracted inbox command module"
    inbox_src = inbox_ml.read_text(encoding="utf-8")

    for name in [
        "set_compact_cmd",
        "clear_compact_cmd",
        "open_pending_reply_cmd",
        "check_pending_reply_cmd",
        "poll_inbox_cmd",
        "peek_inbox_cmd",
        "set_compact",
        "clear_compact",
        "open_pending_reply",
        "check_pending_reply",
        "poll_inbox",
        "peek_inbox",
    ]:
        assert_ocaml_value_extracted(c2c_ml, inbox_src, name)

    assert_token_reference(c2c_ml, "C2c_inbox_cmd.set_compact")
    assert_token_reference(c2c_ml, "C2c_inbox_cmd.clear_compact")
    assert_token_reference(c2c_ml, "C2c_inbox_cmd.open_pending_reply")
    assert_token_reference(c2c_ml, "C2c_inbox_cmd.check_pending_reply")
    assert_token_reference(c2c_ml, "C2c_inbox_cmd.poll_inbox")
    assert_token_reference(c2c_ml, "C2c_inbox_cmd.peek_inbox")
