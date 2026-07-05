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
