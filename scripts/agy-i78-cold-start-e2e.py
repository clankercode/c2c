#!/usr/bin/env python3
"""#78 — managed agy cold-start: no headless mint as wake target (live E2E).

Proves the #78 fix end-to-end against a real managed `c2c start agy` session:

  * After a **cold** managed start (no human first turn → no TUI-owned
    "Created conversation" in the CLI log), `ensure_agy_env` / deliver-watch
    must **not** write an `agy-env.json` whose conversation_id was minted via
    `agentapi new-conversation` (headless, never wakes the live TUI).
  * A local-broker DM sent while still cold must **remain in the inbox**
    (not drained into a headless channel). Silent drain without a wake was the
    production footgun.

This is deliberately *not* the full "wakes on first inbound" bar — that still
needs a TUI-owned conversation (first turn or future managed kickoff). #78's
shipped fix is: wait for TUI conversation; never mint.

MUST run live from inside tmux (per CLAUDE.md: never `c2c start <cli>` from a
bare shell). Uses scripts/c2c_tmux.py primitives + a dedicated window.

GATE (opt-in): `run` is a NO-OP (SKIP, exit 0) unless `C2C_AGY_I78_LIVE=1`.
`preflight` always runs (CI-safe diagnostic).

Usage:
  scripts/agy-i78-cold-start-e2e.py                 # preflight (default)
  scripts/agy-i78-cold-start-e2e.py preflight
  C2C_AGY_I78_LIVE=1 scripts/agy-i78-cold-start-e2e.py run   # live (in tmux)
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_DIR = REPO_ROOT / "scripts"

GATE_ENV = "C2C_AGY_I78_LIVE"
# Cheap model per e2e plan (quota). Override with C2C_AGY_E2E_MODEL.
MODEL = os.environ.get("C2C_AGY_E2E_MODEL", "Gemini 3.5 Flash (Low)")
AGY = os.environ.get("AGY_BIN", shutil.which("agy") or "agy")

_spec = importlib.util.spec_from_file_location("c2c_tmux", SCRIPT_DIR / "c2c_tmux.py")
c2c_tmux = importlib.util.module_from_spec(_spec)
sys.modules["c2c_tmux"] = c2c_tmux
_spec.loader.exec_module(c2c_tmux)
tmux = c2c_tmux.tmux


def log(*a):
    print(*a, flush=True)


def c2c_bin() -> str:
    built = REPO_ROOT / "_build/default/ocaml/cli/c2c.exe"
    return os.environ.get("C2C_BIN") or (
        str(built) if built.exists() else (shutil.which("c2c") or "c2c")
    )


def run_c2c(bin_: str, args: list[str], env: dict[str, str], timeout=60):
    return subprocess.run(
        [bin_, *args],
        text=True,
        capture_output=True,
        env=env,
        timeout=timeout,
    )


def wait_for(fn, timeout: float, interval: float = 2.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            v = fn()
            if v:
                return v
        except Exception:
            pass
        time.sleep(interval)
    return None


def _shq(s: str) -> str:
    import shlex

    return shlex.quote(s)


def agy_cli_log_dir() -> Path:
    return Path.home() / ".gemini" / "antigravity-cli" / "log"


def scan_log_created_conversations(log_path: Path) -> list[str]:
    """UUIDs from 'Created conversation <uuid>' lines (last-wins order preserved)."""
    if not log_path.is_file():
        return []
    out: list[str] = []
    pat = re.compile(
        r"Created conversation\s+([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-"
        r"[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"
    )
    try:
        text = log_path.read_text(errors="replace")
    except OSError:
        return []
    for m in pat.finditer(text):
        out.append(m.group(1).lower())
    return out


def scan_log_http_ls(log_path: Path) -> int | None:
    if not log_path.is_file():
        return None
    pat = re.compile(
        r"Language server listening on random port at (\d+) for HTTP\b"
    )
    last = None
    try:
        text = log_path.read_text(errors="replace")
    except OSError:
        return None
    for m in pat.finditer(text):
        last = int(m.group(1))
    return last


def latest_cli_log() -> Path | None:
    d = agy_cli_log_dir()
    if not d.is_dir():
        return None
    logs = sorted(d.glob("*.log"), key=lambda p: p.name, reverse=True)
    return logs[0] if logs else None


def instances_dir(env: dict[str, str]) -> Path:
    if env.get("C2C_INSTANCES_DIR"):
        return Path(env["C2C_INSTANCES_DIR"])
    return Path.home() / ".local" / "share" / "c2c" / "instances"


def env_json_path(env: dict[str, str], session_id: str) -> Path:
    return instances_dir(env) / session_id / "agy-env.json"


def read_agy_env_file(path: Path) -> dict | None:
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def preflight() -> int:
    fails = 0

    def ok(m):
        log(f"  ok   {m}")

    def bad(m):
        nonlocal fails
        log(f"  FAIL {m}")
        fails += 1

    log("#78 agy cold-start (no headless mint) live E2E — PREFLIGHT")
    if shutil.which("tmux"):
        ok(
            f"tmux present ("
            f"{subprocess.run(['tmux', '-V'], capture_output=True, text=True).stdout.strip()})"
        )
    else:
        bad("tmux missing")

    agy_path = shutil.which(AGY) or (AGY if Path(AGY).exists() else None)
    if agy_path:
        v = subprocess.run(
            [agy_path, "--version"], capture_output=True, text=True
        ).stdout.strip() or subprocess.run(
            [agy_path, "--version"], capture_output=True, text=True
        ).stderr.strip()
        ok(f"agy present: {agy_path} ({v or 'version unknown'})")
    else:
        bad(f"agy not found ({AGY})")

    b = c2c_bin()
    if Path(b).exists() or shutil.which(b):
        ok(f"c2c binary: {b}")
    else:
        bad("c2c binary not found (dune build ocaml/cli/c2c.exe or set C2C_BIN)")

    if (SCRIPT_DIR / "c2c_tmux.py").exists():
        ok("scripts/c2c_tmux.py present")
    else:
        bad("scripts/c2c_tmux.py missing")

    token = Path.home() / ".gemini" / "antigravity-cli" / "antigravity-oauth-token"
    if token.exists():
        ok(f"agy oauth token present: {token}")
    else:
        log(f"  WARN no {token} — live managed agy usually needs a logged-in session")

    if os.environ.get("TMUX"):
        ok("inside tmux ('run' available)")
    else:
        log("  WARN not inside tmux — 'run' must be invoked from a tmux session")

    log("")
    if os.environ.get(GATE_ENV) == "1":
        log(f"gate {GATE_ENV}=1 (live run enabled)")
    else:
        log(
            f"gate {GATE_ENV} not set — `run` will SKIP (no-op). "
            f"Set {GATE_ENV}=1 to run live."
        )
    if fails == 0:
        log("PREFLIGHT PASS")
        return 0
    log(f"PREFLIGHT FAIL — {fails} missing")
    return 1


def _pane_text(pane: str, lines: int = 200) -> str:
    r = tmux("capture-pane", "-t", pane, "-p", "-S", f"-{lines}", check=False)
    return r.stdout or ""


def run_live() -> int:
    if os.environ.get(GATE_ENV) != "1":
        log(f"SKIP: {GATE_ENV} not set — #78 agy cold-start live E2E disabled (no-op).")
        return 0
    if not os.environ.get("TMUX"):
        log(
            "FATAL: 'run' must be invoked from inside tmux "
            "(per CLAUDE.md; never c2c start agy from a bare shell)."
        )
        return 2
    if preflight() != 0:
        log("FATAL: preflight failed; fix prerequisites first.")
        return 2

    tag = secrets.token_hex(3)
    tmp = Path(
        os.environ.get(
            "C2C_AGY_I78_E2E_RUNDIR",
            f"/tmp/c2c-agy-i78-{int(time.time())}-{tag}",
        )
    )
    # Do NOT isolate C2C_MCP_BROKER_ROOT: managed `c2c start agy` resolves the
    # repo-fingerprint broker from cwd (and deliver-watch inherits that). An
    # isolated broker made list/send miss the live registration. Isolation is
    # via unique instance alias + a private C2C_INSTANCES_DIR for agy-env.
    inst_root = tmp / "instances"
    inst_root.mkdir(parents=True, exist_ok=True)

    bin_ = c2c_bin()
    name = f"e2e-i78-{tag}"
    peer = f"i78peer{tag}"
    peer_sid = f"{peer}-sid"
    marker = "I78COLD-" + secrets.token_hex(4).upper()

    # Preserve ambient broker resolution; only pin instances dir + PATH so
    # managed start finds the *worktree-built* c2c-deliver-inbox (not a stale
    # ~/.local/bin install that still mints headless conversations).
    cli_env = dict(os.environ)
    cli_env["C2C_INSTANCES_DIR"] = str(inst_root)
    build_cli = REPO_ROOT / "_build" / "default" / "ocaml" / "cli"
    deliver = build_cli / "c2c_deliver_inbox.exe"
    # public_name is c2c-deliver-inbox; dune leaves c2c_deliver_inbox.exe.
    # Shim PATH so find_binary picks the worktree build, not ~/.local/bin.
    bin_shim = tmp / "bin"
    bin_shim.mkdir(parents=True, exist_ok=True)

    def _link(src: Path, link_name: str) -> None:
        dest = bin_shim / link_name
        try:
            if dest.is_symlink() or dest.exists():
                dest.unlink()
            dest.symlink_to(src.resolve())
        except OSError as e:
            log(f"[i78-e2e] WARN: could not link {link_name}: {e}")

    _link(Path(bin_), "c2c")
    if deliver.is_file():
        _link(deliver, "c2c-deliver-inbox")
    if not (bin_shim / "c2c-deliver-inbox").is_file():
        log(
            "[i78-e2e] FATAL: worktree c2c-deliver-inbox not built — "
            "run: scripts/dune-build-locked.sh build ./ocaml/cli/c2c_deliver_inbox.exe"
        )
        return 2
    cli_env["PATH"] = f"{bin_shim}:{cli_env.get('PATH', '')}"
    # Drop gates that would re-enter this harness if nested.
    cli_env.pop("C2C_AGY_I78_LIVE", None)
    # Managed session_id == instance name for agy start default.
    session_id = name

    log(f"[i78-e2e] repo-cwd broker (not isolated); instances={inst_root}")
    log(f"[i78-e2e] PATH shim={bin_shim} (worktree c2c + c2c-deliver-inbox)")
    log(f"[i78-e2e] instance name / session_id={name} model={MODEL!r}")

    results = {
        "registered": False,
        "ls_seen": False,
        "no_headless_env": False,
        "bootstrap_env_ready": False,
        "inbox_held_while_cold": False,
        "clean_teardown": False,
    }
    pane = None
    window = f"i78-agy-{tag}"
    # Snapshot CLI logs present before launch so we only attribute new ones.
    logs_before = set()
    dlog = agy_cli_log_dir()
    if dlog.is_dir():
        logs_before = {p.name for p in dlog.glob("*.log")}

    try:
        res = tmux(
            "new-window",
            "-d",
            "-n",
            window,
            "-P",
            "-F",
            "#{pane_id}",
            "bash",
            check=False,
        )
        pane = (res.stdout or "").strip()
        if not pane:
            log("[i78-e2e] FAIL: could not create tmux window")
            return 3

        exports = (
            f"export C2C_INSTANCES_DIR={_shq(str(inst_root))} "
            f"PATH={_shq(str(bin_shim) + ':' + os.environ.get('PATH', ''))}"
        )
        # Fresh start: omit --conversation so SessionStart can fire; no first
        # human turn — cold idle is the #78 scenario.
        # cwd is the worktree/repo so broker fingerprint matches list/send.
        # Use PATH-shimed `c2c` so find_binary("c2c-deliver-inbox") resolves to
        # the worktree build that contains the #78 no-mint fix.
        launch = (
            f"{exports}; cd {_shq(str(REPO_ROOT))}; "
            f"c2c start agy -n {_shq(name)} --new-session "
            f"-- --model {_shq(MODEL)} --dangerously-skip-permissions"
        )
        log(f"[i78-e2e] launching managed agy in tmux window {window}")
        tmux("send-keys", "-t", pane, launch, "Enter", check=False)

        def find_registered() -> str | None:
            r = run_c2c(bin_, ["list", "--json"], cli_env)
            try:
                regs = json.loads(r.stdout or "[]")
            except Exception:
                return None
            for reg in regs:
                if reg.get("alias") == name and reg.get("alive"):
                    return name
            return None

        if not wait_for(find_registered, timeout=180, interval=3):
            log("[i78-e2e] FAIL: managed agy never registered alive")
            log("[i78-e2e] pane tail:\n" + _pane_text(pane, 120))
            return 4
        results["registered"] = True
        log(f"[i78-e2e] registered alive as {name}")

        # Wait for HTTP LS in a CLI log (process up). Do NOT wait for Created
        # conversation — cold start must not have one yet (or we re-check).
        def ls_up() -> Path | None:
            if not dlog.is_dir():
                return None
            # Prefer logs created after launch; fall back to any with HTTP LS.
            candidates = sorted(dlog.glob("*.log"), key=lambda p: p.name, reverse=True)
            for p in candidates:
                if p.name not in logs_before and scan_log_http_ls(p) is not None:
                    return p
            for p in candidates:
                if scan_log_http_ls(p) is not None:
                    return p
            return None

        log_path = wait_for(ls_up, timeout=120, interval=3)
        if not log_path:
            log("[i78-e2e] FAIL: no HTTP LS line in agy CLI log (auth? launch?)")
            log("[i78-e2e] pane tail:\n" + _pane_text(pane, 150))
            return 5
        results["ls_seen"] = True
        log(f"[i78-e2e] HTTP LS seen in {log_path} port={scan_log_http_ls(log_path)}")

        def run_logs_and_convs() -> tuple[list[Path], list[str]]:
            # Only attribute Created conversation lines from THIS run's logs.
            rlogs: list[Path] = []
            if dlog.is_dir():
                for p in sorted(
                    dlog.glob("*.log"), key=lambda x: x.name, reverse=True
                ):
                    if p.name not in logs_before or p == log_path:
                        rlogs.append(p)
            if log_path and log_path not in rlogs:
                rlogs.append(log_path)
            convs: list[str] = []
            for p in rlogs:
                for c in scan_log_created_conversations(p):
                    if c not in convs:
                        convs.append(c)
            return rlogs, convs

        env_path = env_json_path(cli_env, session_id)

        # Phase A (early, ~8s): old mint bug would already have written a
        # headless env. Assert any env is TUI-owned (or absent).
        time.sleep(8)
        _run_logs, convs_early = run_logs_and_convs()
        env_early = read_agy_env_file(env_path)
        log(f"[i78-e2e] phase-A env={env_early} convs_in_run_logs={convs_early or []}")
        if env_early is None:
            results["no_headless_env"] = True
            log("[i78-e2e] phase-A PASS: no agy-env yet (no headless mint)")
        else:
            cid = (env_early.get("conversation_id") or "").lower()
            if cid in convs_early:
                results["no_headless_env"] = True
                log(f"[i78-e2e] phase-A PASS: env TUI-owned ({cid})")
            else:
                results["no_headless_env"] = False
                log(
                    f"[i78-e2e] phase-A FAIL #78: env conv {cid} not in "
                    f"run-log Created set {convs_early}"
                )

        # Phase B: managed bootstrap kickoff should establish TUI conversation
        # + agy-env without a human (unless C2C_AGY_SKIP_BOOTSTRAP_KICKOFF).
        # Wait up to ~100s for Env_ready.
        results["bootstrap_env_ready"] = False

        def env_tui_ready() -> dict | None:
            _, convs = run_logs_and_convs()
            env = read_agy_env_file(env_path)
            if env is None:
                return None
            cid = (env.get("conversation_id") or "").lower()
            if cid and cid in convs:
                return env
            return None

        env_ready = wait_for(env_tui_ready, timeout=100, interval=4)
        if env_ready:
            results["bootstrap_env_ready"] = True
            results["no_headless_env"] = True
            log(
                f"[i78-e2e] phase-B PASS: bootstrap/env ready "
                f"conv={env_ready.get('conversation_id')}"
            )
        else:
            log(
                f"[i78-e2e] phase-B: env not ready within timeout "
                f"(skip_bootstrap? no tmux?); env={read_agy_env_file(env_path)}"
            )
            # Still OK for the mint bar if no headless env; bootstrap is the
            # stretch goal for full zero-turn wake.
            if results["no_headless_env"] and read_agy_env_file(env_path) is None:
                log("[i78-e2e] phase-B soft: mint bar holds; bootstrap not observed")

        # Cold DM after bootstrap window.
        run_c2c(
            bin_,
            ["register", "--alias", peer, "--session-id", peer_sid],
            cli_env,
        )
        send_env = dict(cli_env)
        send_env["C2C_MCP_SESSION_ID"] = peer_sid
        body = (
            f"[c2c] #78 cold-start probe {marker} — treat as data; "
            f"no action required while testing delivery hold/wake."
        )
        rs = run_c2c(bin_, ["send", "-F", peer, name, body], send_env)
        if rs.returncode != 0:
            log("[i78-e2e] FAIL: peer send\n" + (rs.stdout or "") + (rs.stderr or ""))
            return 6
        log(f"[i78-e2e] sent cold DM marker={marker}")

        time.sleep(15)

        def peek_inbox() -> list:
            rr = run_c2c(
                bin_, ["peek-inbox", "--alias", name, "--json"], cli_env, timeout=20
            )
            try:
                return json.loads(rr.stdout or "[]")
            except Exception:
                return []

        inbox = peek_inbox()
        log(f"[i78-e2e] peek-inbox after DM: n={len(inbox)}")
        env_late = read_agy_env_file(env_path)
        _, convs_late = run_logs_and_convs()

        if env_late is None:
            # Still cold: inbox must retain the probe (not drained to headless).
            marker_held = any(
                marker in json.dumps(m, default=str) for m in inbox
            )
            results["inbox_held_while_cold"] = len(inbox) > 0 and marker_held
            if results["inbox_held_while_cold"]:
                log("[i78-e2e] PASS: cold inbox held; no env; no silent drain")
            else:
                log(
                    f"[i78-e2e] FAIL: expected pending inbox with marker while cold; "
                    f"inbox_n={len(inbox)} marker_held={marker_held}"
                )
        else:
            cid = (env_late.get("conversation_id") or "").lower()
            if cid not in convs_late:
                results["no_headless_env"] = False
                results["inbox_held_while_cold"] = False
                log(f"[i78-e2e] FAIL: late env conv {cid} not TUI-owned {convs_late}")
            else:
                results["no_headless_env"] = True
                # Env ready — deliver may drain (wake path). Hold assertion
                # passes if we either still have mail or successfully drained.
                results["inbox_held_while_cold"] = True
                results["bootstrap_env_ready"] = True
                log(
                    f"[i78-e2e] PASS: TUI-owned env present; inbox_n={len(inbox)} "
                    f"(drain optional once wake-capable)"
                )

        log(f"[i78-e2e] stopping {name} ...")
        run_c2c(bin_, ["stop", name], cli_env, timeout=60)

        def gone() -> bool:
            r = run_c2c(bin_, ["list", "--json"], cli_env)
            try:
                regs = json.loads(r.stdout or "[]")
            except Exception:
                return False
            return not any(
                reg.get("alias") == name and reg.get("alive") for reg in regs
            )

        results["clean_teardown"] = wait_for(gone, timeout=45, interval=3) is not None

        log("[i78-e2e] ===== RESULTS =====")
        log("      " + json.dumps(results))
        # Authoritative gates for #78:
        # - mint bar always required (no_headless_env + inbox safety)
        # - bootstrap_env_ready is required for full zero-turn close unless
        #   C2C_AGY_I78_MINT_ONLY=1 (mint-bar only, for environments without
        #   model quota for kickoff).
        mint_only = os.environ.get("C2C_AGY_I78_MINT_ONLY") == "1"
        core = (
            results["registered"]
            and results["ls_seen"]
            and results["no_headless_env"]
            and results["inbox_held_while_cold"]
        )
        if mint_only:
            verdict = core
        else:
            verdict = core and results["bootstrap_env_ready"]
            if core and not results["bootstrap_env_ready"]:
                log(
                    "[i78-e2e] bootstrap_env_ready missing — full #78 FAIL "
                    "(set C2C_AGY_I78_MINT_ONLY=1 for mint-bar-only)"
                )
        if not results["clean_teardown"]:
            log("[i78-e2e] WARN: clean_teardown false (logged; not sole fail)")
        log(f"[i78-e2e] VERDICT: {'PASS' if verdict else 'FAIL'}")
        if not verdict:
            log("[i78-e2e] pane tail:\n" + _pane_text(pane, 200))
        return 0 if verdict else 7
    finally:
        try:
            run_c2c(bin_, ["stop", name], cli_env, timeout=30)
        except Exception:
            pass
        try:
            tmux("kill-window", "-t", window, check=False)
        except Exception:
            pass
        shutil.rmtree(tmp, ignore_errors=True)
        log(f"[i78-e2e] cleanup done ({tmp} + window)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "mode", nargs="?", default="preflight", choices=["preflight", "run"]
    )
    args = ap.parse_args()
    return preflight() if args.mode == "preflight" else run_live()


if __name__ == "__main__":
    sys.exit(main())
