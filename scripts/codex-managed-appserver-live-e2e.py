#!/usr/bin/env python3
"""B144 — MANAGED app-server transport live E2E for Codex.

Proves the DEFAULT managed codex delivery path end-to-end by launching a real
supervised session through `c2c new codex` (the app-server supervisor +
stock remote TUI), NOT the raw app-server seams the T003/T004/T007 dev drivers
exercise. This is the "full supervisor" complement to
scripts/codex-ingress-dogfood.py / codex-autoturn-e2e.py / codex-draft-
preservation-e2e.py (which drive the seams via dev drivers) and to
scripts/codex-hooks-live-e2e.py (the hook-fallback transport).

WHAT THIS PROVES (against the installed codex, default >= 0.144):
  * ARRIVAL-TIME model-visible injection + eligible LOCAL AUTO-TURN: a local
    peer DM carrying a unique marker + an echo instruction is answered by the
    model in the supervised TUI transcript WITHOUT any human keystroke — i.e.
    the mail was injected on arrival AND the T007 dispatcher started a gated
    turn that made it model-visible (one scenario proves both).
  * DRAFT PRESERVATION: a multibyte/multiline composer draft typed before the
    DM (never submitted) is preserved byte-for-byte across the auto-turn.
  * CLEAN TEARDOWN / DEREGISTRATION: after `c2c stop`, no orphan
    `codex app-server` / `codex --remote` process from this instance survives
    and the broker registration for the instance alias is gone.

MUST run from inside tmux (per repo CLAUDE.md: never `c2c start/new codex` from
a bare shell). The supervisor is launched via scripts/c2c_tmux.py's launch flow
in a dedicated pane; the harness drives + observes it via tmux capture/send-keys
and the c2c CLI against the live broker.

Isolation / safety: uses a dedicated tmux window + a unique instance alias +
a disposable broker root, and tears everything down on exit (try/finally),
reporting before/after codex process counts. Never touches unrelated sessions.

GATE (opt-in): `run` mode is a NO-OP (SKIP, exit 0) unless
`C2C_CODEX_APPSERVER_LIVE=1`. `preflight` always runs (CI-safe diagnostic).
`run` additionally requires `$TMUX`.

Usage:
  scripts/codex-managed-appserver-live-e2e.py                # preflight (default)
  scripts/codex-managed-appserver-live-e2e.py preflight
  C2C_CODEX_APPSERVER_LIVE=1 scripts/codex-managed-appserver-live-e2e.py run  # live (in tmux)
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

GATE_ENV = "C2C_CODEX_APPSERVER_LIVE"
CODEX = os.environ.get("CODEX_BIN", shutil.which("codex") or "/home/xertrov/.bun/bin/codex")
MODEL = os.environ.get("C2C_APPSERVER_E2E_MODEL", "gpt-5.6-luna")
MIN_CODEX = (0, 144)

# ASCII-only draft with a unique short token: proves the composer survives the
# arrival injection + auto-turn. (The multibyte byte-for-byte case is covered
# rigorously by scripts/codex-draft-preservation-e2e.py / T004; here we avoid
# tmux `send-keys -l` multibyte-width fragility and keep the assertion crisp.)
DRAFT_TOKEN = "DRAFTKEEP" + secrets.token_hex(3).upper()
DRAFT = DRAFT_TOKEN + " do not lose me across the c2c autoturn"

# c2c's own T007 auto-turn nudge text (emitted ONLY when eligible LOCAL mail was
# injected AND a gated turn was started) — its presence proves arrival-time
# injection + auto-turn WITHOUT asking the model to act on message content
# (which the bus-never-RPC safety makes it correctly refuse).
AUTOTURN_SIG = "injected into your thread history"


def _collapse(s: str) -> str:
    return re.sub(r"\s+", "", s)

# Reuse the canonical tmux primitive (no second launcher).
_spec = importlib.util.spec_from_file_location("c2c_tmux", SCRIPT_DIR / "c2c_tmux.py")
c2c_tmux = importlib.util.module_from_spec(_spec)
sys.modules["c2c_tmux"] = c2c_tmux
_spec.loader.exec_module(c2c_tmux)
tmux = c2c_tmux.tmux


def log(*a):
    print(*a, flush=True)


def c2c_bin() -> str:
    built = REPO_ROOT / "_build/default/ocaml/cli/c2c.exe"
    return os.environ.get("C2C_BIN") or (str(built) if built.exists() else (shutil.which("c2c") or "c2c"))


def main_tree_root() -> Path:
    """Root of the MAIN git working tree (schedules land in its .c2c/schedules,
    repo-fingerprint keyed, not the worktree). For a worktree, --git-common-dir
    resolves to <main>/.git, whose parent is the main tree root."""
    try:
        r = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                           cwd=str(REPO_ROOT), text=True, capture_output=True)
        gcd = r.stdout.strip()
        if gcd:
            return Path(gcd).parent
    except Exception:
        pass
    return REPO_ROOT


def parse_codex_version(raw: str) -> tuple[int, int] | None:
    m = re.search(r"(\d+)\.(\d+)", raw)
    return (int(m.group(1)), int(m.group(2))) if m else None


def run_c2c(bin_: str, args: list[str], env: dict[str, str], timeout=30):
    return subprocess.run([bin_, *args], env=env, text=True,
                          capture_output=True, timeout=timeout)


def wait_for(fn, timeout: float, interval: float = 2.0):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(interval)
    return None


def my_codex_pids(broker_root: str) -> list[int]:
    """PIDs of codex processes belonging to THIS run — identified by our unique
    isolated broker root in their environ. Precise (does not depend on a global
    count that fluctuates with a live swarm) and safe to signal."""
    pids: list[int] = []
    out = subprocess.run(["pgrep", "-f", "codex"], capture_output=True, text=True).stdout
    for line in out.split():
        pid = line.strip()
        if not pid.isdigit():
            continue
        try:
            environ = Path(f"/proc/{pid}/environ").read_bytes().decode("utf-8", "replace")
        except Exception:
            continue
        if f"C2C_MCP_BROKER_ROOT={broker_root}" in environ:
            pids.append(int(pid))
    return pids


def sweep_my_codex(broker_root: str) -> int:
    """SIGTERM (then SIGKILL) every codex proc from this run. Returns how many
    were still alive and had to be force-killed (a nonzero value means `c2c stop`
    did not fully reap — recorded as the clean-teardown signal)."""
    import signal
    pids = my_codex_pids(broker_root)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except Exception:
            pass
    time.sleep(3)
    forced = 0
    for pid in my_codex_pids(broker_root):
        forced += 1
        try:
            os.kill(pid, signal.SIGKILL)
        except Exception:
            pass
    return forced


def preflight() -> int:
    fails = 0

    def ok(m): log(f"  ok   {m}")

    def bad(m):
        nonlocal fails
        log(f"  FAIL {m}"); fails += 1

    log("B144 codex managed app-server transport live E2E — PREFLIGHT")
    if shutil.which("tmux"):
        ok(f"tmux present ({subprocess.run(['tmux','-V'],capture_output=True,text=True).stdout.strip()})")
    else:
        bad("tmux missing")

    cx = shutil.which(CODEX) or (CODEX if Path(CODEX).exists() else None)
    if cx:
        v = subprocess.run([CODEX, "--version"], capture_output=True, text=True).stdout.strip()
        ver = parse_codex_version(v)
        if ver and ver >= MIN_CODEX:
            ok(f"codex present: {cx} ({v}) >= {MIN_CODEX[0]}.{MIN_CODEX[1]} (app-server supported)")
        else:
            bad(f"codex too old / unparseable: {v!r} (need >= {MIN_CODEX[0]}.{MIN_CODEX[1]})")
        h = subprocess.run([CODEX, "--help"], capture_output=True, text=True).stdout
        ok("codex --help advertises --remote") if "--remote" in h else bad("codex --help lacks --remote")
    else:
        bad(f"codex not found ({CODEX})")

    b = c2c_bin()
    ok(f"c2c binary: {b}") if (Path(b).exists() or shutil.which(b)) else \
        bad("c2c binary not found (dune build ocaml/cli/c2c.exe or set C2C_BIN)")

    auth = Path.home() / ".codex" / "auth.json"
    ok(f"codex auth.json present: {auth}") if auth.exists() else \
        log(f"  WARN no {auth} — a live turn needs codex auth")

    if (SCRIPT_DIR / "c2c_tmux.py").exists():
        ok("scripts/c2c_tmux.py present (tmux primitive reused)")
    else:
        bad("scripts/c2c_tmux.py missing")

    ok("inside tmux ('run' available)") if os.environ.get("TMUX") else \
        log("  WARN not inside tmux — 'run' must be invoked from a tmux session")

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


def _pane_text(pane: str, lines: int = 400) -> str:
    r = tmux("capture-pane", "-t", pane, "-p", "-S", f"-{lines}", check=False)
    return r.stdout


def run_live() -> int:
    if os.environ.get(GATE_ENV) != "1":
        log(f"SKIP: {GATE_ENV} not set — managed app-server live E2E disabled (no-op).")
        return 0
    if not os.environ.get("TMUX"):
        log("FATAL: 'run' must be invoked from inside tmux (per CLAUDE.md; never c2c new codex from a bare shell).")
        return 2
    if preflight() != 0:
        log("FATAL: preflight failed; fix prerequisites first.")
        return 2

    tag = secrets.token_hex(3)
    tmp = Path(os.environ.get("C2C_APPSERVER_E2E_RUNDIR",
               f"/tmp/claude-1000/-home-xertrov-src-c2c/b144-appserver-{int(time.time())}-{tag}"))
    broker = tmp / "broker"
    broker.mkdir(parents=True, exist_ok=True)

    bin_ = c2c_bin()
    name = f"b144as{tag}"                 # managed instance alias
    marker = "C2C_AS_" + secrets.token_hex(4).upper()
    peer = f"aspeer{tag}"
    peer_sid = f"{peer}sid"

    cli_env = {k: v for k, v in os.environ.items()
               if not (k.startswith("C2C_") or k.startswith("CLAUDE") or k.startswith("CODEX_"))}
    cli_env["C2C_MCP_BROKER_ROOT"] = str(broker)
    cli_env["PATH"] = os.environ["PATH"]

    log(f"[appserver-e2e] isolated broker root = {broker}")
    results = {"injected_and_autoturn": False, "draft_preserved": False,
               "clean_teardown": False, "deregistered": False}
    pane = None
    window = f"b144-appserver-{tag}"
    try:
        # 1. launch the managed supervisor in a dedicated tmux window. Export the
        #    isolated broker root so it registers there; force the app-server
        #    path is the default on a supported codex (no flag needed).
        res = tmux("new-window", "-d", "-n", window, "-P", "-F", "#{pane_id}", "bash", check=False)
        pane = res.stdout.strip()
        if not pane:
            log("[appserver-e2e] FAIL: could not create tmux window"); return 3
        exports = f"export C2C_MCP_BROKER_ROOT={_shq(str(broker))}"
        launch = (f"{exports}; {_shq(bin_)} new codex --alias {name} --yolo "
                  f"-- --sandbox read-only -c model={_shq(MODEL)}")
        log(f"[appserver-e2e] launching managed session '{name}' (model={MODEL}) in tmux window {window}")
        tmux("send-keys", "-t", pane, launch, "Enter", check=False)

        # 2. wait for the supervised session to register (alive) in the broker.
        def find_instance_alias() -> str | None:
            r = run_c2c(bin_, ["list", "--json"], cli_env)
            try:
                regs = json.loads(r.stdout or "[]")
            except Exception:
                return None
            # managed codex registers under the instance alias we chose.
            for reg in regs:
                if reg.get("alias") == name and reg.get("alive"):
                    return name
            # fallback: any codex-* alias that is alive.
            for reg in regs:
                a = reg.get("alias") or ""
                if a.startswith("codex-") and reg.get("alive"):
                    return a
            return None

        inst_alias = wait_for(find_instance_alias, timeout=150, interval=3)
        if not inst_alias:
            log("[appserver-e2e] FAIL: managed session never registered")
            log("[appserver-e2e] pane tail:\n" + _pane_text(pane, 120))
            return 4
        log(f"[appserver-e2e] managed session registered as: {inst_alias}")

        # 3. wait for the frontend TUI to be interactive, then type an UNSUBMITTED
        #    draft into the composer (draft-preservation setup). No Enter.
        time.sleep(8)
        tmux("send-keys", "-t", pane, "-l", DRAFT, check=False)
        time.sleep(2)
        draft_before = _pane_text(pane, 60)
        log(f"[appserver-e2e] typed unsubmitted draft (marker in draft: {DRAFT!r})")

        # 4. a LOCAL peer DM (informational — NOT an RPC-shaped "echo this token"
        #    ask, which the bus-never-RPC safety makes the model correctly
        #    refuse). Arrival-time ingress injects it as DATA and the T007
        #    dispatcher starts a gated turn with NO human keystroke.
        run_c2c(bin_, ["register", "--alias", peer, "--session-id", peer_sid], cli_env)
        send_env = dict(cli_env); send_env["C2C_MCP_SESSION_ID"] = peer_sid
        dm = f"c2c managed app-server E2E probe {marker} (informational; no action required)."
        rs = run_c2c(bin_, ["send", "-F", peer, inst_alias, dm], send_env)
        if rs.returncode != 0:
            log("[appserver-e2e] FAIL: peer->codex send\n" + rs.stdout + rs.stderr)
            return 5
        log(f"[appserver-e2e] local peer '{peer}' sent DM (marker={marker}) to {inst_alias}")

        # 5a. arrival-time injection + eligible LOCAL auto-turn — asserted via
        #     c2c's own auto-turn nudge in the TUI transcript. That nudge is
        #     emitted by the T007 dispatcher ONLY when eligible LOCAL mail was
        #     injected into the thread's model-visible history AND a gated turn
        #     was started, so its presence is authoritative proof of BOTH.
        #     (We do NOT gate on the model acting on the content — bus-never-RPC
        #     makes it correctly refuse an "echo this" ask.)
        def saw_autoturn():
            return AUTOTURN_SIG in _pane_text(pane, 700)
        autoturn = bool(wait_for(saw_autoturn, timeout=150, interval=4))
        results["injected_and_autoturn"] = autoturn

        # Corroborating (informational only, NOT gated): the broker PENDING inbox
        # for the alias. NOTE: for a managed app-server session `peek-inbox
        # --alias` does not reliably reflect the ingress loop's arrival-time
        # consumption (the injected-as-DATA nudge above is the authoritative
        # signal), so this is logged, not asserted.
        def inbox_empty() -> bool:
            rr = run_c2c(bin_, ["peek-inbox", "--alias", inst_alias, "--json"], cli_env, timeout=20)
            try:
                return len(json.loads(rr.stdout or "[]")) == 0
            except Exception:
                return False
        log(f"[appserver-e2e] auto-turn nudge seen={autoturn} "
            f"(informational) broker pending-inbox empty={inbox_empty()}")

        # 5b. draft preserved across the auto-turn: the composer still shows the
        #     unique draft token (whitespace-collapsed to tolerate TUI wrapping).
        draft_after = _pane_text(pane, 80)
        results["draft_preserved"] = (DRAFT_TOKEN in _collapse(draft_after))
        if not results["draft_preserved"]:
            log("[appserver-e2e] draft-before tail:\n" + draft_before[-400:])
            log("[appserver-e2e] draft-after tail:\n" + draft_after[-400:])

        log("[appserver-e2e] ===== delivery RESULTS =====")
        log("      " + json.dumps({k: results[k] for k in ("injected_and_autoturn", "draft_preserved")}))
        if not results["injected_and_autoturn"]:
            log("[appserver-e2e] transcript tail:\n" + _pane_text(pane, 200))

        # 6. clean teardown / deregistration: `c2c stop` must reap the managed
        #    codex processes (measured precisely by our isolated broker root) and
        #    deregister the instance — with NO orphan left behind.
        log(f"[appserver-e2e] stopping managed session '{name}' ...")
        run_c2c(bin_, ["stop", name], cli_env, timeout=60)

        def no_my_procs() -> bool:
            return len(my_codex_pids(str(broker))) == 0
        reaped = wait_for(no_my_procs, timeout=60, interval=3) is not None
        results["clean_teardown"] = reaped

        def deregistered() -> bool:
            r = run_c2c(bin_, ["list", "--json"], cli_env)
            try:
                regs = json.loads(r.stdout or "[]")
            except Exception:
                return False
            return not any((reg.get("alias") == inst_alias and reg.get("alive")) for reg in regs)
        results["deregistered"] = wait_for(deregistered, timeout=30, interval=3) is not None
        log(f"[appserver-e2e] after stop: my codex procs remaining = "
            f"{len(my_codex_pids(str(broker)))} clean={results['clean_teardown']} "
            f"deregistered={results['deregistered']}")

        verdict = all(results.values())
        log("[appserver-e2e] ===== RESULTS =====")
        log("      " + json.dumps(results))
        log(f"[appserver-e2e] VERDICT: {'PASS' if verdict else 'FAIL'}")
        return 0 if verdict else 6
    finally:
        # best-effort: stop the instance again, kill the window.
        try:
            run_c2c(bin_, ["stop", name], cli_env, timeout=30)
        except Exception:
            pass
        try:
            tmux("kill-window", "-t", window, check=False)
        except Exception:
            pass
        # SAFETY: guarantee no orphan survives this run regardless of whether
        # `c2c stop` reaped. Only touches procs carrying our isolated broker
        # root, so a live swarm's codex is never affected. A nonzero forced
        # count is logged as evidence that `c2c stop` alone did not fully reap.
        forced = sweep_my_codex(str(broker))
        if forced:
            log(f"[appserver-e2e] WARNING: force-killed {forced} orphan codex "
                f"proc(s) that `c2c stop` did not reap (see clean_teardown result)")
        # schedule (if `c2c new` created one) lands in the MAIN tree's
        # .c2c/schedules/<name> (repo-fingerprint keyed); clean both candidates.
        shutil.rmtree(main_tree_root() / ".c2c" / "schedules" / name, ignore_errors=True)
        shutil.rmtree(REPO_ROOT / ".c2c" / "schedules" / name, ignore_errors=True)
        shutil.rmtree(tmp, ignore_errors=True)
        log(f"[appserver-e2e] cleanup done ({tmp} + window + schedule removed)")


def _shq(s: str) -> str:
    import shlex
    return shlex.quote(s)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("mode", nargs="?", default="preflight", choices=["preflight", "run"])
    args = ap.parse_args()
    return preflight() if args.mode == "preflight" else run_live()


if __name__ == "__main__":
    sys.exit(main())
