"""Architecture guards for the OCaml CLI refactor."""

from pathlib import Path


REPO = Path(__file__).resolve().parents[1]


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

    assert init_ml.exists(), "expected extracted init/setup command module"
    init_src = init_ml.read_text(encoding="utf-8")

    assert "let init_cmd =" not in c2c_ml
    assert "let completion_cmd =" not in c2c_ml
    assert "let self_update_cmd =" not in c2c_ml
    assert "let install =" not in c2c_ml
    assert "let repo_config_path () =" not in c2c_ml
    assert "C2c_init_cmd.init" in c2c_ml
    assert "C2c_init_cmd.install" in c2c_ml
    assert "C2c_init_cmd.self_update" in c2c_ml
    assert "C2c_init_cmd.completion_cmd" in c2c_ml
    assert "C2c_init_cmd.repo_config_path" in c2c_ml
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
