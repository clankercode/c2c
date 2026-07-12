#!/usr/bin/env python3
"""B144 — HOOK+CLI transport live E2E for Codex.

Proves the hook-fallback delivery path end-to-end against a REAL, interactive
Codex process (NOT a synthetic `c2c hook codex` payload, and NOT the managed
app-server supervisor). The distinction from the app-server E2E is deliberate:
here a *normal* `codex` TUI runs with an isolated CODEX_HOME whose
`config.toml` has the c2c hooks installed (`c2c install codex`), forced onto the
hook path via `C2C_CODEX_FORCE_HOOKS=1`. A peer sends a real DM; the codex
UserPromptSubmit hook fires *naturally* on the next turn, runs `c2c hook codex`,
and delivers the message as hookSpecificOutput.additionalContext.

WHAT THIS PROVES (against the installed codex, default >= 0.144):
  * a real peer DM, queued in the isolated broker, is delivered into the codex
    model's context via the naturally-firing UserPromptSubmit hook (asserted by
    the model echoing a unique marker it could only have seen via the hook), and
  * the inbox is DRAINED by that hook fire (the message is gone afterwards).

TTY backend: tmux (canonical, reproducible) or herdr (`C2C_E2E_TTY=herdr`), both
real PTYs. The hooks path is the same either way; the harness only needs a real
interactive turn boundary to fire the hook.

Isolation / safety: isolated HOME (so `c2c install codex` writes an isolated
`.codex/config.toml`), disposable broker root, real `~/.codex/auth.json` copied
in read-only. Never touches the user's `~/.codex` config or any pre-existing
codex/herdr session. Self-cleaning: kills the codex process + its TTY session
and removes temp dirs on exit (try/finally). Sanitized: no secrets printed.

GATE (opt-in): `run` mode is a NO-OP (SKIP, exit 0) unless
`C2C_CODEX_HOOKS_LIVE=1`. `preflight` always runs (CI-safe diagnostic; launches
nothing). `run` additionally requires the chosen TTY backend to be usable.

Usage:
  scripts/codex-hooks-live-e2e.py                 # preflight (default)
  scripts/codex-hooks-live-e2e.py preflight
  C2C_CODEX_HOOKS_LIVE=1 scripts/codex-hooks-live-e2e.py run   # live (in tmux/herdr)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

GATE_ENV = "C2C_CODEX_HOOKS_LIVE"
CODEX = os.environ.get("CODEX_BIN", shutil.which("codex") or "/home/xertrov/.bun/bin/codex")
MODEL = os.environ.get("C2C_HOOKS_E2E_MODEL", "gpt-5.6-luna")
MIN_CODEX = (0, 144)


def log(*a):
    print(*a, flush=True)


def c2c_bin() -> str:
    built = REPO_ROOT / "_build/default/ocaml/cli/c2c.exe"
    return os.environ.get("C2C_BIN") or (str(built) if built.exists() else (shutil.which("c2c") or "c2c"))


def parse_codex_version(raw: str) -> tuple[int, int] | None:
    m = re.search(r"(\d+)\.(\d+)", raw)
    return (int(m.group(1)), int(m.group(2))) if m else None


# ----------------------------------------------------------------- TTY backends


class TmuxTTY:
    """A dedicated, detached tmux session hosting one codex TUI."""

    name = "tmux"

    def __init__(self, session: str):
        self.session = session
        self._started = False

    @staticmethod
    def usable() -> bool:
        return shutil.which("tmux") is not None

    def _tmux(self, *args, check=True):
        return subprocess.run(["tmux", *args], text=True, check=check,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def start(self, argv: list[str], cwd: str, env: dict[str, str]):
        # A detached session is self-contained (does NOT require the caller to be
        # inside tmux), which keeps the hooks E2E independent of the harness's
        # own terminal. Env is exported via a prefixed shell command.
        exports = " ".join(f"{k}={_shq(v)}" for k, v in env.items())
        cmd = f"cd {_shq(cwd)} && exec env {exports} {' '.join(_shq(a) for a in argv)}"
        self._tmux("new-session", "-d", "-s", self.session, "-x", "220", "-y", "50", "bash", "-lc", cmd)
        self._started = True

    def read(self, lines: int = 400) -> str:
        r = self._tmux("capture-pane", "-t", self.session, "-p", "-S", f"-{lines}", check=False)
        return r.stdout

    def send_text(self, text: str):
        # literal text (no key interpretation); no Enter. A settle beat lets the
        # TUI composer register the paste before the (separate) submit Enter.
        self._tmux("send-keys", "-t", self.session, "-l", text, check=False)
        time.sleep(0.6)

    def submit(self):
        # Extended-keys-safe Enter: with `set -s extended-keys on` a bare
        # `send-keys Enter` encodes as CSI-u (Ctrl+Shift+M) and TUIs (codex,
        # Claude Code) do NOT treat it as submit — the exact footgun documented
        # in scripts/c2c-tmux-enter.sh. Toggle extended-keys off around the Enter.
        helper = REPO_ROOT / "scripts" / "c2c-tmux-enter.sh"
        if helper.exists():
            subprocess.run([str(helper), self.session], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
        prev = self._tmux("show", "-sv", "extended-keys", check=False).stdout.strip() or "off"
        self._tmux("set", "-s", "extended-keys", "off", check=False)
        self._tmux("send-keys", "-t", self.session, "Enter", check=False)
        self._tmux("set", "-s", "extended-keys", prev, check=False)

    def stop(self):
        if self._started:
            self._tmux("kill-session", "-t", self.session, check=False)


class HerdrTTY:
    """A codex TUI hosted by the herdr terminal workspace manager."""

    name = "herdr"

    def __init__(self, agent: str):
        self.agent = agent
        self._started = False

    @staticmethod
    def usable() -> bool:
        if not shutil.which("herdr"):
            return False
        r = subprocess.run(["herdr", "status"], text=True, capture_output=True)
        return r.returncode == 0

    def _herdr(self, *args, check=True):
        return subprocess.run(["herdr", *args], text=True, check=check,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def start(self, argv: list[str], cwd: str, env: dict[str, str]):
        args = ["agent", "start", self.agent, "--cwd", cwd, "--no-focus"]
        for k, v in env.items():
            args += ["--env", f"{k}={v}"]
        args += ["--", *argv]
        self._herdr(*args)
        self._started = True

    def read(self, lines: int = 400) -> str:
        r = self._herdr("agent", "read", self.agent, "--source", "recent",
                        "--lines", str(lines), "--format", "text", check=False)
        return r.stdout

    def send_text(self, text: str):
        self._herdr("agent", "send", self.agent, text, check=False)

    def submit(self):
        # herdr `agent send` writes literal text; a pane run adds Enter. Use the
        # pane API to press Enter on the agent terminal.
        self._herdr("pane", "run", self.agent, "", check=False)

    def stop(self):
        if self._started:
            # No first-class "kill agent"; the process dies with the harness's
            # own SIGTERM sweep of codex procs. Best-effort focus-away.
            pass


def _shq(s: str) -> str:
    import shlex
    return shlex.quote(s)


def pick_tty() -> type:
    choice = os.environ.get("C2C_E2E_TTY", "").strip().lower()
    if choice == "tmux":
        return TmuxTTY
    if choice == "herdr":
        return HerdrTTY
    # auto: prefer herdr if a server is up, else tmux.
    return HerdrTTY if HerdrTTY.usable() else TmuxTTY


# --------------------------------------------------------------------- harness


def run_c2c(bin_: str, args: list[str], env: dict[str, str], timeout=30):
    return subprocess.run([bin_, *args], env=env, text=True,
                          capture_output=True, timeout=timeout)


def wait_for(fn, timeout: float, interval: float = 1.0):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(interval)
    return None


def find_codex_alias(bin_: str, env: dict[str, str]) -> str | None:
    # A vanilla codex hook mints a fresh generated alias of the shape
    # `codex-<word>-<word>-<4char>` (it ignores the installer hint, per
    # test_vanilla_auto_register_ignores_installer_alias_hint). The isolated
    # broker has no other codex-* registration, so match on that prefix.
    r = run_c2c(bin_, ["list", "--json"], env)
    try:
        regs = json.loads(r.stdout or "[]")
    except Exception:
        return None
    for reg in regs:
        a = reg.get("alias") or ""
        if a.startswith("codex-"):
            return a
    return None


def _sched_dir_from_install(stdout: str) -> str | None:
    """Extract the wake.toml schedule dir from `c2c install codex` output, e.g.
    `+ /abs/.c2c/schedules/<alias>/wake.toml (schedule)`."""
    m = re.search(r"\+\s+(\S+/wake\.toml)\s+\(schedule\)", stdout)
    return str(Path(m.group(1)).parent) if m else None


def preflight() -> int:
    fails = 0

    def ok(m): log(f"  ok   {m}")

    def bad(m):
        nonlocal fails
        log(f"  FAIL {m}"); fails += 1

    log("B144 codex hook+CLI transport live E2E — PREFLIGHT")
    cx = shutil.which(CODEX) or (CODEX if Path(CODEX).exists() else None)
    if cx:
        v = subprocess.run([CODEX, "--version"], capture_output=True, text=True).stdout.strip()
        ver = parse_codex_version(v)
        if ver and ver >= MIN_CODEX:
            ok(f"codex present: {cx} ({v}) >= {MIN_CODEX[0]}.{MIN_CODEX[1]}")
        else:
            bad(f"codex version too old / unparseable: {v!r} (need >= {MIN_CODEX[0]}.{MIN_CODEX[1]})")
    else:
        bad(f"codex not found ({CODEX})")

    b = c2c_bin()
    if Path(b).exists() or shutil.which(b):
        ok(f"c2c binary: {b}")
    else:
        bad("c2c binary not found (dune build ocaml/cli/c2c.exe or set C2C_BIN)")

    auth = Path.home() / ".codex" / "auth.json"
    ok(f"codex auth.json present: {auth}") if auth.exists() else \
        log(f"  WARN no {auth} — a live turn needs codex auth")

    tty = pick_tty()
    if tty.usable():
        ok(f"TTY backend usable: {tty.name}")
    else:
        bad(f"TTY backend '{tty.name}' unusable (need tmux, or a running herdr server)")

    log("")
    if os.environ.get(GATE_ENV) == "1":
        log(f"gate {GATE_ENV}=1 (live run enabled)")
    else:
        log(f"gate {GATE_ENV} not set — `run` will SKIP (no-op). Set {GATE_ENV}=1 to run live.")
    if fails == 0:
        log("PREFLIGHT PASS")
        return 0
    log(f"PREFLIGHT FAIL — {fails} missing")
    return 1


def run_live() -> int:
    if os.environ.get(GATE_ENV) != "1":
        log(f"SKIP: {GATE_ENV} not set — hook+CLI live E2E disabled (no-op).")
        return 0
    if preflight() != 0:
        log("FATAL: preflight failed; fix prerequisites first.")
        return 2

    tag = secrets.token_hex(3)
    tmp = Path(os.environ.get("C2C_HOOKS_E2E_RUNDIR",
               f"/tmp/claude-1000/-home-xertrov-src-c2c/b144-hooks-{int(time.time())}-{tag}"))
    home = tmp / "home"
    broker = tmp / "broker"
    home.mkdir(parents=True, exist_ok=True)
    broker.mkdir(parents=True, exist_ok=True)
    (home / ".codex").mkdir(parents=True, exist_ok=True)
    src_auth = Path.home() / ".codex" / "auth.json"
    if src_auth.exists():
        shutil.copy(src_auth, home / ".codex" / "auth.json")

    bin_ = c2c_bin()
    alias_test = f"c2c-hooks-e2e-{tag}"
    marker = "C2C_HOOK_" + secrets.token_hex(4).upper()
    peer = f"hookpeer{tag}"
    peer_sid = f"{peer}sid"

    # env used for c2c CLI ops against the isolated broker (NOT inheriting any
    # ambient c2c/codex identity from the harness's own session).
    base_env = {k: v for k, v in os.environ.items()
                if not (k.startswith("C2C_") or k.startswith("CLAUDE") or k.startswith("CODEX_"))}
    base_env["HOME"] = str(home)
    base_env["C2C_MCP_BROKER_ROOT"] = str(broker)
    base_env["PATH"] = os.environ["PATH"]

    tty = pick_tty()(f"c2c-hooks-e2e-{tag}")
    results: dict[str, bool] = {"delivered": False, "drained": False}
    sched_dir: str | None = None
    try:
        # 1. install c2c codex hooks into the isolated HOME (pre-trusted).
        log(f"[hooks-e2e] installing c2c codex hooks into {home}/.codex ...")
        r = run_c2c(bin_, ["install", "codex", "--alias", alias_test], base_env, timeout=60)
        if r.returncode != 0:
            log("[hooks-e2e] FAIL: c2c install codex\n" + r.stdout + r.stderr)
            return 4
        sched_dir = _sched_dir_from_install(r.stdout)

        # 2. launch a REAL interactive codex under the TTY backend, forced onto
        #    the hook path, pointed at the isolated broker.
        codex_env = dict(base_env)
        codex_env["CODEX_HOME"] = str(home / ".codex")
        codex_env["C2C_CODEX_FORCE_HOOKS"] = "1"
        argv = [CODEX, "--sandbox", "read-only", "-c", f'model="{MODEL}"']
        log(f"[hooks-e2e] launching codex TUI via {tty.name}: model={MODEL} FORCE_HOOKS=1")
        tty.start(argv, cwd=str(REPO_ROOT), env=codex_env)

        # 3. first prompt → SessionStart/UserPromptSubmit hook fires → codex
        #    self-onboards + auto-registers in the isolated broker.
        time.sleep(6)
        tty.send_text("Reply with exactly the word READY and nothing else.")
        tty.submit()

        codex_alias = wait_for(lambda: find_codex_alias(bin_, base_env), timeout=90)
        if not codex_alias:
            log("[hooks-e2e] FAIL: codex never auto-registered in the isolated broker")
            log("[hooks-e2e] TTY tail:\n" + tty.read(120))
            return 5
        log(f"[hooks-e2e] codex auto-registered as: {codex_alias}")

        # 4. a real peer DM addressed to the codex alias, queued in the broker.
        run_c2c(bin_, ["register", "--alias", peer, "--session-id", peer_sid], base_env)
        send_env = dict(base_env); send_env["C2C_MCP_SESSION_ID"] = peer_sid
        dm = f"{marker} — reply with exactly this token and nothing else."
        rs = run_c2c(bin_, ["send", "-F", peer, codex_alias, dm], send_env)
        if rs.returncode != 0:
            log("[hooks-e2e] FAIL: peer->codex send\n" + rs.stdout + rs.stderr)
            return 6
        log(f"[hooks-e2e] peer '{peer}' sent DM (marker={marker}) to {codex_alias}")

        # 5. a SECOND prompt → UserPromptSubmit hook fires NATURALLY → drains the
        #    inbox + emits the c2c envelope as additionalContext, which the model
        #    then echoes.
        time.sleep(2)
        tty.send_text("What message did you just receive over c2c? Echo the exact token.")
        tty.submit()

        # 6a. delivered: the marker appears in the transcript (only possible via
        #     the hook's additionalContext injection).
        def saw_marker():
            return marker in tty.read(400)
        results["delivered"] = bool(wait_for(saw_marker, timeout=120, interval=3))

        # 6b. drained: the codex inbox is empty after the hook fire.
        def inbox_len() -> int:
            rr = run_c2c(bin_, ["peek-inbox", "--alias", codex_alias, "--json"], base_env, timeout=20)
            try:
                return len(json.loads(rr.stdout or "[]"))
            except Exception:
                return -1
        results["drained"] = wait_for(lambda: inbox_len() == 0, timeout=30, interval=2) is not None

        log("[hooks-e2e] ===== RESULTS =====")
        log("      " + json.dumps(results))
        if not results["delivered"]:
            log("[hooks-e2e] transcript tail:\n" + tty.read(160))
        verdict = results["delivered"] and results["drained"]
        log(f"[hooks-e2e] VERDICT: {'PASS' if verdict else 'FAIL'}")
        return 0 if verdict else 7
    finally:
        tty.stop()
        _sweep_codex(codex_home=str(home / ".codex"))
        # Manifest-driven cleanup: `c2c uninstall codex` (HOME=isolated) removes
        # exactly what install wrote, including the wake schedule dir wherever it
        # landed (its absolute path is in the isolated install manifest).
        try:
            run_c2c(bin_, ["uninstall", "codex"], base_env, timeout=30)
        except Exception:
            pass
        # The schedule wake.toml lands in the MAIN git tree's .c2c/schedules
        # (repo-fingerprint keyed, not worktree-relative); uninstall removes the
        # file but leaves the empty dir. Remove the exact dir parsed from install.
        if sched_dir:
            shutil.rmtree(sched_dir, ignore_errors=True)
        shutil.rmtree(REPO_ROOT / ".c2c" / "schedules" / alias_test, ignore_errors=True)
        shutil.rmtree(tmp, ignore_errors=True)
        log(f"[hooks-e2e] cleanup done (codex swept, uninstalled, {tmp} removed)")


def _sweep_codex(codex_home: str):
    """Kill only codex processes whose CODEX_HOME points at our isolated dir."""
    try:
        out = subprocess.run(["pgrep", "-af", "codex"], text=True, capture_output=True).stdout
    except Exception:
        return
    for line in out.splitlines():
        pid = line.split(" ", 1)[0]
        try:
            environ = Path(f"/proc/{pid}/environ").read_bytes().decode("utf-8", "replace")
        except Exception:
            continue
        if f"CODEX_HOME={codex_home}" in environ:
            try:
                os.kill(int(pid), signal.SIGTERM)
            except Exception:
                pass


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("mode", nargs="?", default="preflight", choices=["preflight", "run"])
    args = ap.parse_args()
    return preflight() if args.mode == "preflight" else run_live()


if __name__ == "__main__":
    sys.exit(main())
