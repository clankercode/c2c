#!/usr/bin/env python3
"""Muse parity E2E — install/hook/CLI/doctor/uninstall against the real binary.

Proves the Muse (muse) c2c integration end-to-end *as a user runs it*,
against the freshly built `_build/default/ocaml/cli/c2c.exe`, in a fully
isolated environment under /tmp (own HOME, XDG dirs, and broker roots — the
real broker and HOME are never touched, and nothing here runs `c2c sweep`):

  1. `c2c install muse` into the isolated home writes the /c2c skill plus a
     hooks transport (plugin bundle installed+approved, or the settings.json
     hooks fallback when the muse plugins gate is absent).
  2. A `c2c hook muse` SessionStart payload auto-registers the session
     (client_type=muse, registered_by=muse-hook), auto-joins the default
     social room (swarm-lounge), and refreshes ~/.config/c2c/default-alias.
  3. Mid-session hooks NEVER drain (Stop: muse 1.4.7 rejects its
     additionalContext — proved via `muse plugins hook test`;
     PostToolUse: a live TUI drain ate mail). Both peek and count-nudge
     with no bodies — Stop one-shot decision:block (silent when
     stop_hook_active), PostToolUse debounced additionalContext — and
     the mail stays queued until `c2c poll-inbox` retrieves it. The one
     hook drain surface is SessionStart (step 2's backlog path).
  4. `c2c peek-inbox` / `poll-inbox` / `list` / `whoami` work for the
     hook-registered identity.
  5. `c2c doctor hooks --json` and `c2c health --json` run and parse, with
     the muse rows reporting the isolated install.
  6. `c2c uninstall muse --dry-run` lists the artifacts it would remove,
     including broker leftovers (default-session statefile), and notes the
     muse registrations it deliberately leaves untouched — removing nothing.

Each step prints `STEP<n> <name>: PASS|FAIL` with its unique token(s); any
failure in steps 1-6 exits non-zero.

LIVE-TUI leg (after steps 1-6): launches a real muse TUI via
`c2c start muse` inside a dedicated detached tmux server (helpers imported
from scripts/c2c_tmux.py; never a bare `c2c start` from a shell, never a
nested tmux client), sends a DM carrying a unique token, prompts the model
to run a tool call and then repeat the token if a c2c message showed it
one, and PASSes only when the full token is observed in the pane capture
(model-visible delivery). An inbox that merely drained is NOT a pass —
that is also the signature of drain-and-discard — so it prints
`LIVE-TUI: FAIL mail-drained-but-not-model-visible`. When a safety
precondition is unmet (no tmux/muse, auth unavailable, no registration)
it prints `LIVE-TUI: BLOCKED <reason>`; the run still exits 0 if steps 1-6
passed — an unobserved live leg is reported, never faked.
Disable it with `--skip-live` or `C2C_MUSE_PARITY_LIVE=0`.

Fake identities: session ids are `muse-parity-*`; the peer alias is
`parity-peer-<tag>` because a literal `muse-*` alias is rejected by the
broker (reserved for auto-generated muse identities — the hook mints the
self alias, which this script discovers rather than assumes).

Usage:
  scripts/muse-parity-e2e.py                 # run (steps 1-6 + live attempt)
  scripts/muse-parity-e2e.py run --skip-live # steps 1-6 only
  scripts/muse-parity-e2e.py preflight       # diagnostic only, launches nothing
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
REAL_HOME = Path(os.environ.get("HOME") or Path.home())

_spec = importlib.util.spec_from_file_location("c2c_tmux", SCRIPT_DIR / "c2c_tmux.py")
c2c_tmux = importlib.util.module_from_spec(_spec)
sys.modules["c2c_tmux"] = c2c_tmux
_spec.loader.exec_module(c2c_tmux)
tmux = c2c_tmux.tmux


def log(*a):
    print(*a, flush=True)


def c2c_bin() -> str | None:
    """The REAL built binary only — no silent PATH fallback (a stale
    ~/.local/bin/c2c proving nothing about this worktree is the failure
    mode this E2E exists to avoid). C2C_BIN overrides explicitly."""
    if os.environ.get("C2C_BIN"):
        return os.environ["C2C_BIN"]
    built = REPO_ROOT / "_build/default/ocaml/cli/c2c.exe"
    return str(built) if built.exists() else None


def run_c2c(bin_: str, args: list[str], env: dict[str, str], cwd: str,
            inp: str | None = None, timeout=60):
    return subprocess.run(
        [bin_, *args], env=env, cwd=cwd, input=inp, text=True,
        capture_output=True, timeout=timeout,
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


def isolated_env(home: Path, broker: Path | None, global_broker: Path | None,
                 instances: Path) -> dict[str, str]:
    """Ambient env minus every identity/broker leak from the caller's own
    agent session, repointed at the isolated home (+ pinned brokers when
    given). TMUX is dropped so nothing mistakes a pane for an identity."""
    env = {
        k: v for k, v in os.environ.items()
        if not (k.startswith(("C2C_", "CLAUDE", "MUSE_", "CODEX_"))
                or k in ("TMUX", "TMUX_PANE"))
    }
    env.update({
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_DATA_HOME": str(home / ".local" / "share"),
        "XDG_STATE_HOME": str(home / ".local" / "state"),
        "XDG_CACHE_HOME": str(home / ".cache"),
        "C2C_INSTANCES_DIR": str(instances),
        "TERM": "dumb",
    })
    if broker is not None:
        env["C2C_MCP_BROKER_ROOT"] = str(broker)
    if global_broker is not None:
        env["C2C_SESSIONS_BROKER_ROOT"] = str(global_broker)
    return env


def parse_hook_context(stdout: str) -> tuple[str, str] | None:
    """(hookEventName, additionalContext) from a hook's stdout, or None."""
    try:
        j = json.loads((stdout or "").strip())
        hso = j["hookSpecificOutput"]
        return hso.get("hookEventName") or "", hso.get("additionalContext") or ""
    except Exception:
        return None


def hook_payload(event: str, sid: str, cwd: Path, turn_id: str | None = None,
                 stop_hook_active: bool | None = None) -> str:
    fields = {
        "hook_event_name": event,
        "session_id": sid,
        "cwd": str(cwd),
        "model": "unknown",
        "permission_mode": "default",
    }
    if turn_id:
        fields["turn_id"] = turn_id
    if stop_hook_active is not None:
        fields["stop_hook_active"] = stop_hook_active
    return json.dumps(fields)


class Steps:
    """STEP<n> PASS/FAIL bookkeeping; a failed step records its evidence."""

    def __init__(self):
        self.results: dict[str, bool] = {}
        self.failures: list[str] = []

    def report(self, n: int, name: str, ok: bool, token: str, detail: str = ""):
        self.results[name] = ok
        log(f"STEP{n} {name}: {'PASS' if ok else 'FAIL'} token={token}"
            + (f" {detail}" if detail else ""))
        if not ok:
            self.failures.append(f"STEP{n} {name} token={token} {detail}".strip())

    def expect(self, cond, what: str, evidence: str = ""):
        if not cond:
            raise AssertionError(f"{what}" + (f" — {evidence[:1200]}" if evidence else ""))


def preflight() -> int:
    fails = 0

    def ok(m):
        log(f"  ok   {m}")

    def bad(m):
        nonlocal fails
        log(f"  FAIL {m}")
        fails += 1

    log("muse parity E2E — PREFLIGHT")
    b = c2c_bin()
    if b and Path(b).exists():
        ok(f"built c2c binary: {b}")
    else:
        bad("built binary missing — run: "
            "scripts/dune-build-locked.sh build ./ocaml/cli/c2c.exe")

    if shutil.which("tmux"):
        v = subprocess.run(["tmux", "-V"], capture_output=True, text=True).stdout.strip()
        ok(f"tmux present ({v})")
    else:
        log("  WARN tmux missing — live TUI leg will print BLOCKED")

    muse = shutil.which("muse")
    if muse:
        v = subprocess.run([muse, "--version"], capture_output=True, text=True).stdout.strip()
        ok(f"muse present: {muse} ({v or 'version unknown'})")
    else:
        log("  WARN muse not on PATH — install leg must take the "
            "settings-fallback transport; live leg will print BLOCKED")

    if (SCRIPT_DIR / "c2c_tmux.py").exists():
        ok("scripts/c2c_tmux.py present")
    else:
        bad("scripts/c2c_tmux.py missing")

    auth = REAL_HOME / ".config" / "muse" / "auth.json"
    if auth.exists():
        ok("muse auth.json present in real home (live leg may copy it, contents never printed)")
    else:
        log(f"  WARN no {auth} — live leg will try the echo provider or print BLOCKED")

    if os.environ.get("TMUX"):
        log("  note inside tmux — live leg uses a dedicated detached tmux "
            "server (no nested client), so this is safe")
    elif os.environ.get("HERDR_ENV"):
        log("  note inside herdr (not tmux) — live leg uses a dedicated "
            "detached tmux server, so no nesting occurs")

    log("")
    log("PREFLIGHT PASS" if fails == 0 else f"PREFLIGHT FAIL — {fails} missing")
    return 0 if fails == 0 else 1


def run_steps(bin_: str, tmp: Path, tag: str) -> Steps:
    steps = Steps()
    home, broker = tmp / "home", tmp / "broker"
    global_broker, proj = tmp / "global-broker", tmp / "proj"
    for d in (home, broker, global_broker, proj, tmp / "instances"):
        d.mkdir(parents=True, exist_ok=True)
    env = isolated_env(home, broker, global_broker, tmp / "instances")
    cwd = str(proj)

    sid = f"muse-parity-{tag}-sid"
    # `muse-*` aliases are reserved for auto-generated muse identities, so
    # the peer registers as parity-peer- (session ids keep muse-parity-*).
    peer, peer_sid = f"parity-peer-{tag}", f"muse-parity-peer-{tag}-sid"
    alias: str | None = None  # hook-minted; discovered in step 2

    # ---- STEP 1: c2c install muse into the isolated home ----------------
    tok1 = f"MUSEPARITY-{tag.upper()}-INSTALL"
    try:
        r = run_c2c(bin_, ["install", "muse"], env, cwd, timeout=180)
        steps.expect(r.returncode == 0, "install rc!=0", r.stdout + r.stderr)
        skill = home / ".config/muse/skills/c2c/SKILL.md"
        steps.expect(skill.is_file(), f"skill missing at {skill}")
        skill_text = skill.read_text()
        steps.expect("c2c whoami" in skill_text, "skill lacks whoami guidance")
        bundle = home / ".c2c/clients/muse/plugin/.muse-plugin/plugin.json"
        steps.expect(bundle.is_file(), f"plugin bundle missing at {bundle}")
        manifest = json.loads(bundle.read_text())
        steps.expect(manifest.get("name") == "c2c", "bundle name != c2c")
        hooks = (manifest.get("capabilities") or {}).get("hooks") or []
        steps.expect(
            [h.get("event") for h in hooks]
            == ["SessionStart", "Stop", "PostToolUse", "SessionEnd"],
            f"bundle hook events wrong: {hooks}")
        steps.expect(
            all(h.get("command") == ["c2c", "hook", "muse"] for h in hooks),
            "bundle hook command is not the c2c argv array")
        installed = home / ".local/share/muse/plugins/installed.json"
        settings = home / ".config/muse/settings.json"
        settings_text = settings.read_text() if settings.is_file() else ""
        plugin_transport = (
            installed.is_file()
            and '"c2c"' in installed.read_text()
            and "plugin:c2c:hook:" in settings_text)
        settings_transport = "c2c hook muse" in settings_text
        steps.expect(plugin_transport or settings_transport,
                     "neither plugin nor settings-fallback transport installed",
                     f"installed.json={installed.is_file()} settings={settings_text[:400]}")
        steps.expect("c2c-mcp-server" not in settings_text,
                     "MCP written by default (must be opt-in only)")
        transport = "plugin" if plugin_transport else "settings-fallback"
        steps.report(1, "install", True, tok1, f"transport={transport}")
    except AssertionError as e:
        steps.report(1, "install", False, tok1, str(e))
        return steps  # later steps have nothing to stand on

    # ---- STEP 2: SessionStart hook registers + auto-joins + alias file ---
    tok2 = f"MUSEPARITY-{tag.upper()}-SESSIONSTART"
    try:
        r = run_c2c(bin_, ["hook", "muse"], env, cwd,
                    inp=hook_payload("SessionStart", sid, proj), timeout=30)
        steps.expect(r.returncode == 0, "SessionStart rc!=0", r.stderr)
        parsed = parse_hook_context(r.stdout)
        steps.expect(parsed is not None, "no hookSpecificOutput", r.stdout)
        event, context = parsed
        steps.expect(event == "SessionStart", f"hookEventName={event!r}")
        steps.expect(sid in context, "onboarding lacks session id", context)
        steps.expect("does NOT wake an idle" in context,
                     "onboarding over-claims idle delivery", context)
        regs = json.loads(run_c2c(bin_, ["list", "--json"], env, cwd).stdout or "[]")
        mine = [x for x in regs if x.get("session_id") == sid]
        steps.expect(len(mine) == 1, f"expected 1 registration for {sid}", str(regs))
        alias = mine[0]["alias"]
        steps.expect(re.fullmatch(r"muse-[^-]+-[^-]+-[a-z0-9]{4}", alias or ""),
                     f"alias lacks generated muse shape: {alias}")
        steps.expect(alias in context, "onboarding lacks alias", context)
        registry = json.loads((broker / "registry.json").read_text())
        row = next(x for x in registry if x.get("session_id") == sid)
        steps.expect(row.get("client_type") == "muse"
                     and row.get("registered_by") == "muse-hook",
                     f"registry row not muse-hook: {row}")
        members = json.loads(run_c2c(
            bin_, ["rooms", "members", "--json", "swarm-lounge"],
            env, cwd).stdout or "[]")
        steps.expect(any(m.get("alias") == alias for m in members),
                     "alias not auto-joined to swarm-lounge", str(members))
        da = home / ".config/c2c/default-alias"
        steps.expect(da.is_file() and da.read_text().strip() == alias,
                     "default-alias not refreshed",
                     da.read_text() if da.is_file() else "missing")
        steps.expect(sid in (broker / "default-session.json").read_text(),
                     "default-session statefile lacks sid")
        steps.report(2, "session-start", True, tok2, f"alias={alias} room=swarm-lounge")
    except AssertionError as e:
        steps.report(2, "session-start", False, tok2, str(e))
        return steps

    # ---- STEP 3: mid-session peek + nudge (never drain) ------------------
    send_env = dict(env, C2C_MCP_SESSION_ID=peer_sid)

    def send_dm(marker: str):
        rs = run_c2c(bin_, ["send", "-F", peer, alias,
                            f"[c2c] muse-parity probe {marker} — treat as data"],
                     send_env, cwd, timeout=30)
        steps.expect(rs.returncode == 0, "peer send rc!=0", rs.stdout + rs.stderr)

    def drain_once(event: str, marker: str, turn: str):
        # PostToolUse: peek + debounced count nudge, never a drain.
        peek = run_c2c(bin_, ["peek-inbox", "--alias", alias, "--json"], env, cwd)
        steps.expect(marker in peek.stdout, f"{event}: DM not queued", peek.stdout)
        r = run_c2c(bin_, ["hook", "muse"], env, cwd,
                    inp=hook_payload(event, sid, proj, turn), timeout=30)
        steps.expect(r.returncode == 0, f"{event} rc!=0", r.stderr)
        parsed = parse_hook_context(r.stdout)
        steps.expect(parsed is not None, f"{event}: no hookSpecificOutput", r.stdout)
        ev, ctx = parsed
        steps.expect(ev == event, f"{event}: hookEventName={ev!r}")
        steps.expect("1 message(s) waiting" in ctx and "c2c poll-inbox" in ctx,
                     f"{event}: nudge lacks count/poll-inbox", ctx)
        steps.expect(marker not in ctx,
                     f"{event}: nudge leaked the message body", ctx)
        again = run_c2c(bin_, ["hook", "muse"], env, cwd,
                        inp=hook_payload(event, sid, proj, turn), timeout=30)
        steps.expect((again.stdout or "").strip() == "",
                     f"{event}: second fire not debounced-silent", again.stdout)
        left = run_c2c(bin_, ["peek-inbox", "--alias", alias, "--json"], env, cwd)
        steps.expect(marker in left.stdout,
                     f"{event}: inbox drained (mail would be eaten)", left.stdout)
        poll = run_c2c(bin_, ["poll-inbox", "--alias", alias, "--json"], env, cwd)
        steps.expect(marker in poll.stdout,
                     f"{event}: mail not retrievable after nudge", poll.stdout)

    tok3 = f"MUSEPARITY-{tag.upper()}-STOP"
    try:
        rr = run_c2c(bin_, ["register", "--alias", peer, "--session-id", peer_sid],
                     env, cwd, timeout=30)
        steps.expect(rr.returncode == 0, "peer register rc!=0", rr.stdout + rr.stderr)
        send_dm(tok3)
        # Stop must NEVER drain (muse rejects its additionalContext):
        # expect a one-shot decision:block count nudge, no body, mail kept.
        peek = run_c2c(bin_, ["peek-inbox", "--alias", alias, "--json"], env, cwd)
        steps.expect(tok3 in peek.stdout, "Stop: DM not queued", peek.stdout)
        r = run_c2c(bin_, ["hook", "muse"], env, cwd,
                    inp=hook_payload("Stop", sid, proj, "turn-stop-1"),
                    timeout=30)
        steps.expect(r.returncode == 0, "Stop rc!=0", r.stderr)
        out = json.loads(r.stdout or "{}")
        steps.expect(out.get("decision") == "block",
                     "Stop: no decision:block nudge", r.stdout)
        reason = out.get("reason") or ""
        steps.expect("1 message(s) waiting" in reason
                     and "c2c poll-inbox" in reason,
                     "Stop: nudge lacks count/poll-inbox", reason)
        steps.expect(tok3 not in reason and tok3 not in r.stdout,
                     "Stop: nudge leaked the message body", r.stdout)
        steps.expect(parse_hook_context(r.stdout) is None,
                     "Stop: emitted additionalContext (muse rejects it)",
                     r.stdout)
        left = run_c2c(bin_, ["peek-inbox", "--alias", alias, "--json"], env, cwd)
        steps.expect(tok3 in left.stdout,
                     "Stop: inbox drained (mail would be eaten)", left.stdout)
        # stop_hook_active => silent (no block loop), mail still queued.
        r2 = run_c2c(bin_, ["hook", "muse"], env, cwd,
                     inp=hook_payload("Stop", sid, proj, "turn-stop-2",
                                      stop_hook_active=True),
                     timeout=30)
        steps.expect((r2.stdout or "").strip() == "",
                     "Stop: stop_hook_active not silent", r2.stdout)
        poll = run_c2c(bin_, ["poll-inbox", "--alias", alias, "--json"], env, cwd)
        steps.expect(tok3 in poll.stdout,
                     "Stop: mail not retrievable after nudge", poll.stdout)
        steps.report(3, "stop-nudge-nodrain", True, tok3, f"from={peer} to={alias}")
    except AssertionError as e:
        steps.report(3, "stop-nudge-nodrain", False, tok3, str(e))

    tok3b = f"MUSEPARITY-{tag.upper()}-PTU"
    try:
        send_dm(tok3b)
        drain_once("PostToolUse", tok3b, "turn-ptu-1")
        steps.report(3, "posttooluse-nudge-nodrain", True, tok3b,
                     f"from={peer} to={alias}")
    except AssertionError as e:
        steps.report(3, "posttooluse-nudge-nodrain", False, tok3b, str(e))

    # ---- STEP 4: peek / poll-inbox / list / whoami ------------------------
    tok4 = f"MUSEPARITY-{tag.upper()}-CLI"
    try:
        send_dm(tok4)
        peek1 = run_c2c(bin_, ["peek-inbox", "--alias", alias, "--json"], env, cwd)
        steps.expect(tok4 in peek1.stdout, "peek lacks queued DM", peek1.stdout)
        peek2 = run_c2c(bin_, ["peek-inbox", "--alias", alias, "--json"], env, cwd)
        steps.expect(tok4 in peek2.stdout, "peek drained (must be non-destructive)",
                     peek2.stdout)
        poll = run_c2c(bin_, ["poll-inbox", "--alias", alias, "--json"], env, cwd)
        steps.expect(poll.returncode == 0 and tok4 in poll.stdout,
                     "poll-inbox did not drain DM", poll.stdout + poll.stderr)
        after = run_c2c(bin_, ["peek-inbox", "--alias", alias, "--json"], env, cwd)
        steps.expect(json.loads(after.stdout or "[]") == [],
                     "inbox not empty after poll", after.stdout)
        regs = json.loads(run_c2c(bin_, ["list", "--json"], env, cwd).stdout or "[]")
        aliases = {x.get("alias") for x in regs}
        steps.expect({alias, peer} <= aliases, "list lacks self/peer", str(regs))
        who = run_c2c(bin_, ["whoami", "--json"],
                      dict(env, C2C_MCP_SESSION_ID=sid), cwd)
        steps.expect(who.returncode == 0, "whoami rc!=0", who.stdout + who.stderr)
        steps.expect(json.loads(who.stdout).get("alias") == alias,
                     "whoami alias mismatch", who.stdout)
        # Bare whoami (no session env): with TWO registrations in the broker
        # it must either resolve to this session (statefile fallback) or
        # refuse fail-closed listing this session as a candidate (B187) —
        # presenting the PEER's identity as ours is the failure.
        bare = run_c2c(bin_, ["whoami", "--json"], env, cwd)
        if bare.returncode == 0:
            steps.expect(json.loads(bare.stdout).get("alias") == alias,
                         "bare whoami borrowed another identity", bare.stdout)
        else:
            steps.expect(sid in bare.stdout and alias in bare.stdout,
                         "bare whoami refusal does not name this session",
                         bare.stdout + bare.stderr)
        steps.report(4, "cli-surface", True, tok4, f"alias={alias} peer={peer}")
    except AssertionError as e:
        steps.report(4, "cli-surface", False, tok4, str(e))

    # ---- STEP 5: doctor hooks + health parse, no crash --------------------
    tok5 = f"MUSEPARITY-{tag.upper()}-DOCTOR"
    try:
        doc = run_c2c(bin_, ["doctor", "hooks", "--json"],
                      dict(env, C2C_MCP_SESSION_ID=sid), cwd, timeout=120)
        steps.expect(doc.returncode not in (124, 125),
                     f"doctor hooks crashed rc={doc.returncode}", doc.stderr)
        steps.expect(doc.returncode == 0, "doctor hooks rc!=0",
                     doc.stdout + doc.stderr)
        muse = (json.loads(doc.stdout) or {}).get("muse") or {}
        steps.expect(muse.get("installed") is True
                     and muse.get("skill_exists") is True,
                     "doctor does not see muse install", json.dumps(muse)[:800])
        steps.expect((muse.get("muse_regs") or 0) >= 1,
                     "doctor does not see muse registration", json.dumps(muse)[:800])
        steps.expect(muse.get("wake_class") in ("NONE", "CONDITIONAL"),
                     "doctor wake class missing/other-claiming",
                     json.dumps(muse)[:800])
        health = run_c2c(bin_, ["health", "--json"], env, cwd, timeout=60)
        steps.expect(health.returncode == 0, "health rc!=0",
                     health.stdout + health.stderr)
        hj = json.loads(health.stdout)
        steps.expect(hj.get("broker_root") == str(broker),
                     "health reports wrong broker", health.stdout[:600])
        steps.expect((hj.get("registrations") or 0) >= 2,
                     "health registrations < 2", health.stdout[:600])
        muse_rows = [p for p in hj.get("plugins") or []
                     if str(p.get("message", "")).startswith("muse:")]
        steps.expect(muse_rows and muse_rows[0].get("status") == "green",
                     "health muse row not green", json.dumps(muse_rows)[:400])
        steps.report(5, "doctor-health", True, tok5,
                     f"wake_class={muse.get('wake_class')} regs={hj.get('registrations')}")
    except AssertionError as e:
        steps.report(5, "doctor-health", False, tok5, str(e))

    # ---- STEP 6: uninstall --dry-run lists broker leftovers, removes none -
    tok6 = f"MUSEPARITY-{tag.upper()}-UNINSTALL"
    try:
        skill = home / ".config/muse/skills/c2c/SKILL.md"
        human = run_c2c(bin_, ["uninstall", "muse", "--dry-run"], env, cwd, timeout=60)
        steps.expect(human.returncode == 0, "uninstall dry-run rc!=0",
                     human.stdout + human.stderr)
        steps.expect("registration(s) left untouched" in human.stderr,
                     "dry-run does not note broker registrations left behind",
                     human.stdout + human.stderr)
        js = run_c2c(bin_, ["uninstall", "muse", "--dry-run", "--json"],
                     env, cwd, timeout=60)
        steps.expect(js.returncode == 0, "uninstall dry-run --json rc!=0",
                     js.stdout + js.stderr)
        uj = json.loads(js.stdout)
        steps.expect(uj.get("ok") is True and uj.get("dry_run") is True,
                     "uninstall JSON not ok/dry_run", js.stdout)
        removed = uj.get("removed") or []
        steps.expect(str(skill) in removed, "dry-run omits skill", js.stdout)
        steps.expect(str(broker / "default-session.json") in removed,
                     "dry-run omits broker leftover default-session.json", js.stdout)
        steps.expect(skill.is_file(), "dry-run actually removed the skill")
        steps.report(6, "uninstall-dry-run", True, tok6,
                     f"would_remove={len(removed)}")
    except AssertionError as e:
        steps.report(6, "uninstall-dry-run", False, tok6, str(e))

    return steps


def live_tui_leg(bin_: str, tmp: Path, tag: str, skip: bool) -> None:
    """Real-TUI leg. Prints exactly one LIVE-TUI line; never raises and
    never changes the exit code. PASS requires the DM token observed
    model-visible (in the pane capture, which includes the model's own
    reply repeating it); a drained-but-unseen inbox is FAIL, not PASS."""
    token = f"MUSEPARITYLIVE-{tag.upper()}"
    if skip or os.environ.get("C2C_MUSE_PARITY_LIVE") == "0":
        log(f"LIVE-TUI: BLOCKED disabled-by-operator token={token}")
        return
    if not shutil.which("tmux"):
        log(f"LIVE-TUI: BLOCKED no-tmux token={token}")
        return
    muse_bin = shutil.which("muse")
    if not muse_bin:
        log(f"LIVE-TUI: BLOCKED no-muse-binary token={token}")
        return
    # Nesting guard: a dedicated tmux *server* (-L) with a detached session
    # never starts a tmux client inside the caller's pane, so being inside
    # tmux/herdr already is safe; a bare `c2c start` never happens here.
    nested_note = ("inside-tmux" if os.environ.get("TMUX")
                   else "inside-herdr" if os.environ.get("HERDR_ENV")
                   else "bare-shell")

    live = tmp / "live"
    home, proj = live / "home", live / "proj"
    for d in (home, proj, live / "instances", live / "tmux", live / "bin"):
        d.mkdir(parents=True, exist_ok=True)
    # No pinned broker roots: muse scrubs C2C_* from hook env, so the hook,
    # `c2c start`, and our CLI probes must all resolve the same broker from
    # the isolated HOME + proj cwd fingerprint (~/.c2c/repos/<fp>/broker).
    env = isolated_env(home, None, None, live / "instances")
    try:  # PATH shim so the installed plugin's bare `c2c hook muse` is THIS build
        (live / "bin" / "c2c").symlink_to(Path(bin_).resolve())
    except OSError as e:
        log(f"LIVE-TUI: BLOCKED path-shim-failed ({e}) token={token}")
        return
    env["PATH"] = f"{live / 'bin'}:{env.get('PATH', '')}"
    cwd = str(proj)
    subprocess.run(["git", "init", "-q", "."], cwd=cwd, check=False,
                   capture_output=True, timeout=15)

    auth_copy: Path | None = None
    sock, sess = f"museparity{tag}", f"muse-parity-{tag}"
    live_name = f"parity-live-{tag}"
    peer, peer_sid = f"parity-livepeer-{tag}", f"muse-parity-livepeer-{tag}-sid"

    def ltmux(*a, check=False):
        return tmux("-L", sock, *a, check=check)

    def capture(lines: int = 120) -> str:
        r = ltmux("capture-pane", "-t", sess, "-p", "-S", f"-{lines}")
        return r.stdout or ""

    def submit():
        # Extended-keys-safe Enter on OUR server (c2c-tmux-enter.sh targets
        # the default server; see scripts/codex-hooks-live-e2e.py TmuxTTY).
        prev = (ltmux("show", "-sv", "extended-keys").stdout or "off").strip()
        ltmux("set", "-s", "extended-keys", "off")
        ltmux("send-keys", "-t", sess, "Enter")
        ltmux("set", "-s", "extended-keys", prev or "off")

    try:
        r = run_c2c(bin_, ["install", "muse"], env, cwd, timeout=180)
        if r.returncode != 0:
            log(f"LIVE-TUI: BLOCKED live-install-failed token={token}")
            return
        # Auth for the isolated home: copy (never print) the real auth file
        # when present — codex-hooks-live-e2e.py precedent. Without it the
        # echo provider is tried; the copy is deleted in `finally`.
        real_auth = REAL_HOME / ".config/muse/auth.json"
        provider_args = ["--provider", "echo"]
        if real_auth.is_file():
            auth_copy = home / ".config/muse/auth.json"
            auth_copy.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(real_auth, auth_copy)
            auth_copy.chmod(0o600)
            provider_args = []  # real provider/model from copied auth+settings
            try:  # carry non-secret first-run keys so the TUI doesn't stall
                real_settings = json.loads(
                    (REAL_HOME / ".config/muse/settings.json").read_text())
                mine_path = home / ".config/muse/settings.json"
                mine = json.loads(mine_path.read_text()) if mine_path.is_file() else {}
                for k in ("model", "provider",
                          "contributor_mode_disclosure_acknowledged",
                          "contributor_mode_enabled"):
                    if k in real_settings and k not in mine:
                        mine[k] = real_settings[k]
                mine_path.write_text(json.dumps(mine, indent=2) + "\n")
            except Exception:
                pass
        # Pre-seed a role file so `c2c start` never blocks on its prompt
        # (scripts/c2c_tmux.py cmd_launch pattern).
        roles = proj / ".c2c" / "roles"
        roles.mkdir(parents=True, exist_ok=True)
        (roles / f"{live_name}.md").write_text(
            "You are a short-lived muse-parity E2E test session. "
            "Answer prompts in one short line; take no other action.\n")

        pane_env = dict(env, TMUX_TMPDIR=str(live / "tmux"))
        old_tmpdir = os.environ.get("TMUX_TMPDIR")
        os.environ["TMUX_TMPDIR"] = str(live / "tmux")
        try:
            res = ltmux("new-session", "-d", "-s", sess, "-x", "220", "-y", "50", "bash")
            if res.returncode != 0:
                log(f"LIVE-TUI: BLOCKED tmux-session-failed ({nested_note}) token={token}")
                return
            # No TERM here: the pane keeps tmux's own TERM (the isolated
            # env's TERM=dumb is for clean CLI output and would break a TUI).
            exports = " ".join(
                f"export {k}={_shq(pane_env[k])};"
                for k in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
                          "XDG_STATE_HOME", "XDG_CACHE_HOME",
                          "C2C_INSTANCES_DIR", "PATH"))
            launch = (f"{exports} cd {_shq(cwd)}; "
                      f"c2c start muse -n {_shq(live_name)}")
            if provider_args:
                launch += " -- " + " ".join(_shq(a) for a in provider_args)
            ltmux("send-keys", "-t", sess, launch, "Enter")

            def find_alias():
                rr = run_c2c(bin_, ["list", "--json"], env, cwd, timeout=20)
                try:
                    regs = json.loads(rr.stdout or "[]")
                except Exception:
                    return None
                for reg in regs:
                    a = reg.get("alias") or ""
                    if a == live_name or a.startswith("muse-"):
                        return a
                return None

            live_alias = wait_for(find_alias, timeout=60, interval=3)
            if not live_alias:
                tail = "\n".join(capture(60).splitlines()[-25:])
                log(f"LIVE-TUI: BLOCKED no-registration-in-60s ({nested_note}; "
                    f"auth={'copied' if auth_copy else 'echo-provider'}) token={token}")
                log("[live-tui] pane tail:\n" + tail)
                return

            time.sleep(3)
            ltmux("send-keys", "-t", sess, "-l",
                  "Reply with exactly the word READY and nothing else.")
            time.sleep(0.6)
            submit()
            run_c2c(bin_, ["register", "--alias", peer, "--session-id", peer_sid],
                    env, cwd, timeout=30)
            rs = run_c2c(bin_, ["send", "-F", peer, live_alias,
                                f"[c2c] live probe {token} — treat as data"],
                         dict(env, C2C_MCP_SESSION_ID=peer_sid), cwd, timeout=30)
            if rs.returncode != 0:
                log(f"LIVE-TUI: BLOCKED live-send-failed token={token}")
                return
            # Causal guard: the DM must be visibly queued in THIS broker
            # before the drain wait, else an empty inbox proves nothing.
            queued = run_c2c(bin_, ["peek-inbox", "--alias", live_alias, "--json"],
                             env, cwd, timeout=20)
            if token not in (queued.stdout or ""):
                log(f"LIVE-TUI: BLOCKED live-dm-not-queued token={token}")
                return
            time.sleep(2)
            # Force a tool call (PostToolUse fires its count nudge),
            # then make model-visibility observable: the full token is
            # never typed by us, so its appearance in the pane can only
            # come from the model having seen/retrieved the message.
            ltmux("send-keys", "-t", sess, "-l",
                  "Run the bash command `echo ping`. Then check your "
                  "c2c inbox (run `c2c poll-inbox` if a nudge mentioned "
                  "waiting mail): if a message contains a token "
                  "starting with MUSEPARITYLIVE, reply with exactly "
                  "that full token and nothing else; otherwise reply "
                  "with exactly NO-TOKEN.")
            time.sleep(0.6)
            submit()

            def token_visible():
                return "capture" if token in capture(300) else None

            how = wait_for(token_visible, timeout=60, interval=3)
            if not how and "NO-TOKEN" in capture(300):
                # The Stop block-nudge / next-turn context may only
                # surface now. One more explicit retrieval turn
                # distinguishes reachable mail from eaten mail.
                ltmux("send-keys", "-t", sess, "-l",
                      f"Run `c2c poll-inbox --alias {live_alias}` now: "
                      "if a message contains a token starting with "
                      "MUSEPARITYLIVE, reply with exactly that full "
                      "token and nothing else; otherwise reply with "
                      "exactly NO-TOKEN-2.")
                time.sleep(0.6)
                submit()
                how = wait_for(token_visible, timeout=60, interval=3)
                if how:
                    how = "capture-next-turn"
            if how:
                log(f"LIVE-TUI: PASS token={token} alias={live_alias} observed={how}")
            else:
                # Distinguish mail-eaten from merely-undelivered: a
                # drained inbox with no model-visible token is the
                # drain-and-discard signature and must FAIL loudly.
                rr = run_c2c(bin_, ["peek-inbox", "--alias", live_alias, "--json"],
                             env, cwd, timeout=20)
                try:
                    drained = json.loads(rr.stdout or "[]") == []
                except Exception:
                    drained = False
                tail = "\n".join(capture(80).splitlines()[-25:])
                if drained:
                    log(f"LIVE-TUI: FAIL mail-drained-but-not-model-visible "
                        f"alias={live_alias} token={token}")
                else:
                    log(f"LIVE-TUI: BLOCKED delivery-not-observed-in-90s "
                        f"(mail still queued) alias={live_alias} token={token}")
                log("[live-tui] pane tail:\n" + tail)
        finally:
            # Kill our server while TMUX_TMPDIR still points at its socket
            # dir — after the restore, `-L <sock>` would miss it entirely.
            try:
                run_c2c(bin_, ["stop", live_name], env, cwd, timeout=30)
            except Exception:
                pass
            try:
                tmux("-L", sock, "kill-server", check=False)
            except Exception:
                pass
            if old_tmpdir is None:
                os.environ.pop("TMUX_TMPDIR", None)
            else:
                os.environ["TMUX_TMPDIR"] = old_tmpdir
    except Exception as e:  # the live leg must never crash the run
        log(f"LIVE-TUI: BLOCKED exception-{type(e).__name__} token={token}")
    finally:
        if auth_copy is not None:
            try:
                auth_copy.unlink()
            except OSError:
                pass


def run_live(skip_live: bool) -> int:
    bin_ = c2c_bin()
    if not bin_ or not Path(bin_).exists():
        log("FATAL: built binary missing — run: "
            "scripts/dune-build-locked.sh build ./ocaml/cli/c2c.exe")
        return 2
    if preflight() != 0:
        log("FATAL: preflight failed; fix prerequisites first.")
        return 2

    tag = secrets.token_hex(3)
    tmp = Path(os.environ.get(
        "C2C_MUSE_PARITY_RUNDIR", f"/tmp/muse-parity-e2e-{int(time.time())}-{tag}"))
    # Isolation guards: refuse to run anywhere but /tmp with a fake home.
    if not str(tmp.resolve()).startswith("/tmp/") or tmp.resolve() == REAL_HOME:
        log(f"FATAL: rundir {tmp} is not an isolated /tmp path")
        return 2
    tmp.mkdir(parents=True, exist_ok=True)
    log(f"[muse-parity] binary={bin_}")
    log(f"[muse-parity] rundir={tmp} (isolated HOME/brokers beneath it; "
        "real HOME/broker untouched)")

    steps = run_steps(bin_, tmp, tag)
    verdict = bool(steps.results) and all(steps.results.values()) \
        and len(steps.results) == 7
    log("[muse-parity] ===== RESULTS =====")
    log("      " + json.dumps(steps.results))
    log(f"VERDICT: {'PASS' if verdict else 'FAIL'} (steps 1-6)")

    live_tui_leg(bin_, tmp, tag, skip_live)

    keep = os.environ.get("C2C_MUSE_PARITY_KEEP") == "1" or not verdict
    if keep:
        log(f"[muse-parity] rundir kept for inspection: {tmp}")
    else:
        shutil.rmtree(tmp, ignore_errors=True)
        log(f"[muse-parity] cleanup done ({tmp} removed)")
    return 0 if verdict else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("mode", nargs="?", default="run",
                    choices=["preflight", "run"])
    ap.add_argument("--skip-live", action="store_true",
                    help="skip the live tmux TUI leg (prints LIVE-TUI: BLOCKED)")
    args = ap.parse_args()
    return preflight() if args.mode == "preflight" else run_live(args.skip_live)


if __name__ == "__main__":
    sys.exit(main())
