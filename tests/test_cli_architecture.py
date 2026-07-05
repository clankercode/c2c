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
