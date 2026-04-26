import json
import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "cc-quota"


def write_statusline(path: Path, *, session_id: str, five_hour: int, cost: float) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {
                "session_id": session_id,
                "rate_limits": {
                    "five_hour": {
                        "used_percentage": five_hour,
                        "resets_at": 0,
                    },
                    "seven_day": {
                        "used_percentage": 12,
                        "resets_at": 0,
                    },
                },
                "cost": {"total_cost_usd": cost},
            }
        )
        + "\n",
        encoding="utf-8",
    )


def run_quota(tmp_path: Path, env: dict[str, str]) -> str:
    command_env = {
        "PATH": os.environ["PATH"],
        "HOME": str(tmp_path),
        "CLAUDE_CONFIG_DIR": str(tmp_path / ".claude"),
        **env,
    }
    result = subprocess.run(
        [str(SCRIPT)],
        env=command_env,
        text=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return result.stdout


def test_c2c_session_id_does_not_select_stale_claude_session(tmp_path: Path) -> None:
    sl_out = tmp_path / ".claude" / "sl_out"
    old_session = "11111111-1111-4111-8111-111111111111"
    latest_session = "22222222-2222-4222-8222-222222222222"

    write_statusline(
        sl_out / old_session / "input.json",
        session_id=old_session,
        five_hour=10,
        cost=1.11,
    )
    write_statusline(
        sl_out / "last.json",
        session_id=latest_session,
        five_hour=91,
        cost=9.99,
    )

    output = run_quota(tmp_path, {"C2C_MCP_SESSION_ID": old_session})

    assert "5h: 91%" in output
    assert "cost: $9.99" in output
    assert "5h: 10%" not in output


def test_claude_session_id_selects_that_session(tmp_path: Path) -> None:
    sl_out = tmp_path / ".claude" / "sl_out"
    current_session = "33333333-3333-4333-8333-333333333333"
    latest_session = "44444444-4444-4444-8444-444444444444"

    write_statusline(
        sl_out / current_session / "input.json",
        session_id=current_session,
        five_hour=23,
        cost=2.34,
    )
    write_statusline(
        sl_out / "last.json",
        session_id=latest_session,
        five_hour=91,
        cost=9.99,
    )

    output = run_quota(tmp_path, {"CLAUDE_SESSION_ID": current_session})

    assert "5h: 23%" in output
    assert "cost: $2.34" in output
    assert "5h: 91%" not in output
