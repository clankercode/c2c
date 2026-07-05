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
