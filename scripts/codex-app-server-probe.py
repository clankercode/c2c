#!/usr/bin/env python3
"""codex-app-server-probe.py — reproducible spike probe for the installed Codex
`app-server` remote-TUI / passive-injection surface (backlog P1.M1.E1.T001).

Establishes protocol facts FROM THE INSTALLED BINARY (not memory/web docs) and
asserts the c2c safety invariants required before an app-server-backed managed
Codex path (T002/T003/T007) can proceed. Designed to be rerun unchanged against
a FUTURE codex version to detect drift.

Modes (all print a single machine-readable JSON object on the LAST stdout line):

  schema   (always) generate the app-server JSON schema into a temp dir and
           assert protocol invariants:
             - thread/inject_items, turn/start, turn/steer, turn/interrupt are
               all distinct, present client methods;
             - ThreadInjectItemsResponse carries no turn field;
             - NO composer/draft/unsent signal exists anywhere in the protocol
               (server notifications + ThreadStatus enum) — the TUI composer
               draft is frontend-only state.
  stdio    (default on) drive a disposable stdio app-server and prove
           thread/inject_items is accepted ({}) and emits NO turn/started
           notification (injection starts no turn). No model call, no cost.
  boundary (opt-in, --boundary) bind a loopback ws listener with and without
           --ws-auth capability-token and prove an unauthenticated same-UID
           client is rejected at the WebSocket handshake (HTTP 401) while a
           bare listener grants full unauthenticated control. Needs the
           `websockets` python package.

Exit code 0 iff every selected invariant holds. Any external effect (spawning
codex, binding a port) only happens when this script is actually invoked; the
repo test that wires it in is gated behind C2C_CODEX_APPSERVER_PROBE=1.

Usage:
  scripts/codex-app-server-probe.py                 # schema + stdio
  scripts/codex-app-server-probe.py --boundary      # + loopback ws auth check
  CODEX_BIN=/path/to/codex scripts/codex-app-server-probe.py --json-only
"""
import argparse, json, os, shutil, subprocess, sys, tempfile, threading, time

CODEX = os.environ.get("CODEX_BIN", "codex")

# Invariant catalogue — the method names the c2c safety model depends on.
INJECT_METHOD = "thread/inject_items"
ACTIVE_CONTROL_METHODS = ["turn/start", "turn/steer", "turn/interrupt"]
# Any of these substrings appearing as a protocol *signal* name would be a
# machine-readable composer/draft indicator. (App/marketplace UI fields like
# "composerIcon" are NOT signals and are excluded by the notification/status
# scoping below.)
COMPOSER_SIGNAL_TOKENS = ["draft", "unsent", "composerempty", "pendinginput", "inputbuffer"]


def log(*a):
    print(*a, file=sys.stderr)


# --------------------------------------------------------------------------- #
# schema mode
# --------------------------------------------------------------------------- #
def run_schema_checks(result):
    tmp = tempfile.mkdtemp(prefix="t001-schema-")
    checks = []
    try:
        rc = subprocess.run(
            [CODEX, "app-server", "generate-json-schema", "--experimental", "--out", tmp],
            capture_output=True, text=True)
        if rc.returncode != 0:
            checks.append(("schema_generated", False, rc.stderr.strip()[:200]))
            result["schema"] = {"ok": False, "checks": checks}
            return False
        checks.append(("schema_generated", True, ""))

        client_req = json.load(open(os.path.join(tmp, "ClientRequest.json")))
        methods = set()
        for v in client_req.get("oneOf", []):
            enum = v.get("properties", {}).get("method", {}).get("enum", [])
            if enum:
                methods.add(enum[0])

        # inject + the 3 active-control methods present, and inject is NOT one
        # of the active-control methods (this is the load-bearing distinctness).
        needed = [INJECT_METHOD] + ACTIVE_CONTROL_METHODS
        present = {m: (m in methods) for m in needed}
        all_present = all(present.values())
        inject_not_active = INJECT_METHOD not in ACTIVE_CONTROL_METHODS
        checks.append(("inject_and_active_methods_present", all_present, json.dumps(present)))
        checks.append(("inject_distinct_from_turn_methods", inject_not_active and all_present,
                       f"{INJECT_METHOD} not in {ACTIVE_CONTROL_METHODS}"))

        # ThreadInjectItemsResponse has no turn field
        inj_resp = json.load(open(os.path.join(tmp, "v2", "ThreadInjectItemsResponse.json")))
        resp_props = list(inj_resp.get("properties", {}).keys())
        no_turn_in_resp = not any("turn" in k.lower() for k in resp_props)
        checks.append(("inject_response_has_no_turn_field", no_turn_in_resp, json.dumps(resp_props)))

        # --- composer/draft signal search — WHOLE bundle, not a narrow slice.
        # Walk every generated *.json, collecting the schema "names" that could
        # name a signal: object property keys, $defs/definitions keys, enum
        # string values, and JSON-RPC method const/enum values. Then look for a
        # draft/composer/unsent-style token in that name-space. We exclude the
        # known app/marketplace UI *icon* fields (composerIcon*, showInComposer*)
        # which are not draft-state signals.
        UI_ICON_EXCLUDE = ("composericon", "composericonurl", "showincomposerwhenunlinked")

        def collect_names(node, out):
            if isinstance(node, dict):
                for defs_key in ("definitions", "$defs", "properties"):
                    d = node.get(defs_key)
                    if isinstance(d, dict):
                        out.update(d.keys())
                enum = node.get("enum")
                if isinstance(enum, list):
                    out.update(str(e) for e in enum if isinstance(e, (str, int)))
                const = node.get("const")
                if isinstance(const, str):
                    out.add(const)
                for v in node.values():
                    collect_names(v, out)
            elif isinstance(node, list):
                for v in node:
                    collect_names(v, out)

        names = set()
        scanned_files = 0
        for root, _dirs, files in os.walk(tmp):
            for fn in files:
                if not fn.endswith(".json"):
                    continue
                try:
                    collect_names(json.load(open(os.path.join(root, fn))), names)
                    scanned_files += 1
                except Exception:
                    pass

        def is_signal(name):
            low = name.lower()
            if low in UI_ICON_EXCLUDE:
                return False
            return any(tok in low for tok in COMPOSER_SIGNAL_TOKENS)

        signal_hits = sorted({n for n in names if is_signal(n)})
        # Report any raw *composer* names we saw, so a human can eyeball them.
        composer_named = sorted({n for n in names if "composer" in n.lower()})
        composer_signal_absent = len(signal_hits) == 0

        # Keep the ThreadStatus report — it is the closest thing to a state signal.
        status = json.load(open(os.path.join(tmp, "v2", "ThreadStatusChangedNotification.json")))
        status_variants = []
        for variant in status.get("definitions", {}).get("ThreadStatus", {}).get("oneOf", []):
            e = variant.get("properties", {}).get("type", {}).get("enum", [])
            if e:
                status_variants.append(e[0])

        checks.append(("composer_draft_signal_absent", composer_signal_absent,
                       f"scanned={scanned_files} files; hits={signal_hits}; "
                       f"composer_named={composer_named}; thread_status={status_variants}"))

        result["schema"] = {
            "ok": all(ok for _, ok, _ in checks),
            "client_method_count": len(methods),
            "schema_files_scanned": scanned_files,
            "schema_name_count": len(names),
            "thread_status_variants": status_variants,
            "checks": [{"name": n, "pass": ok, "detail": d} for n, ok, d in checks],
        }
        result["composer_signal"] = {
            "present": not composer_signal_absent,
            "searched_tokens": COMPOSER_SIGNAL_TOKENS,
            "excluded_ui_icon_fields": list(UI_ICON_EXCLUDE),
            "signal_hits": signal_hits,
            "composer_named_fields_seen": composer_named,
            "thread_status_variants": status_variants,
            "schema_names_searched": len(names),
            "note": "Whole-bundle name-space search. TUI composer draft is frontend-only "
                    "state; the only composer* names are app/marketplace UI icons.",
        }
        return result["schema"]["ok"]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# --------------------------------------------------------------------------- #
# stdio mode
# --------------------------------------------------------------------------- #
class StdioAppServer:
    def __init__(self, cwd):
        self.p = subprocess.Popen(
            [CODEX, "app-server", "--listen", "stdio://"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, bufsize=1, cwd=cwd)
        self._id = 0
        self.notifications = []
        self.responses = {}
        self.lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                continue
            with self.lock:
                if "id" in msg and ("result" in msg or "error" in msg):
                    self.responses[msg["id"]] = msg
                elif "method" in msg:
                    self.notifications.append(msg)

    def request(self, method, params=None, timeout=20):
        self._id += 1
        rid = self._id
        obj = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            obj["params"] = params
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()
        t0 = time.time()
        while time.time() - t0 < timeout:
            with self.lock:
                if rid in self.responses:
                    return self.responses.pop(rid)
            time.sleep(0.02)
        return {"error": {"message": "timeout"}}

    def notify(self, method, params=None):
        obj = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            obj["params"] = params
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()

    def drain(self, settle=2.0):
        time.sleep(settle)
        with self.lock:
            n = list(self.notifications)
            self.notifications.clear()
        return n

    def close(self):
        for fn in (lambda: self.p.stdin.close(), self.p.terminate):
            try:
                fn()
            except Exception:
                pass
        try:
            self.p.wait(timeout=5)
        except Exception:
            try:
                self.p.kill()
            except Exception:
                pass


def _inertness_check(srv, cwd, checks):
    """Inject a fake approval verdict as a DATA item; prove it stays inert.

    Structural proof always runs (inject of `allow <token>` returns {} — it is
    data, not an action). If a `c2c` binary is discoverable, also prove
    `c2c await-reply` does NOT resolve on the injected token and no verdict file
    appears — the app-server thread and the host-local verdict file are disjoint
    subsystems (bus-never-RPC / B098).
    """
    token = "ka_t001probe"
    ts = srv.request("thread/start", {"cwd": cwd})
    tid = ts.get("result", {}).get("thread", {}).get("id")
    r = srv.request(INJECT_METHOD, {"threadId": tid, "items": [
        {"type": "message", "role": "user",
         "content": [{"type": "input_text", "text": f"allow {token}"}]}]})
    injected_as_data = "result" in r and r.get("result") == {}
    checks.append(("fake_verdict_injected_as_data", injected_as_data, json.dumps(r)[:100]))

    info = {"injected_as_data": injected_as_data, "await_reply_ran": False}
    c2c = shutil.which("c2c") or os.environ.get("C2C_BIN")
    if c2c:
        broker = tempfile.mkdtemp(prefix="t001-broker-")
        env = dict(os.environ, C2C_MCP_BROKER_ROOT=broker)
        rc = subprocess.run([c2c, "await-reply", "--token", token, "--timeout", "2"],
                            capture_output=True, text=True, env=env)
        verdict_files = []
        for root, _d, files in os.walk(broker):
            verdict_files += [os.path.join(root, f) for f in files]
        await_did_not_resolve = rc.returncode != 0
        no_verdict_file = len(verdict_files) == 0
        checks.append(("injected_allow_does_not_resolve_await_reply", await_did_not_resolve,
                       f"await-reply rc={rc.returncode}"))
        checks.append(("injection_creates_no_verdict_file", no_verdict_file,
                       f"files={verdict_files}"))
        info.update({"await_reply_ran": True, "await_reply_rc": rc.returncode,
                     "verdict_files": verdict_files})
        shutil.rmtree(broker, ignore_errors=True)
    else:
        info["note"] = "c2c binary not found; ran structural inject-as-data proof only"
    return info


def run_stdio_checks(result):
    cwd = tempfile.mkdtemp(prefix="t001-stdio-")
    checks = []
    srv = StdioAppServer(cwd)
    try:
        r = srv.request("initialize", {
            "clientInfo": {"name": "t001-probe", "version": "0.0.1"},
            "capabilities": {"experimentalApi": True}})
        init_ok = "result" in r
        checks.append(("initialize_ok", init_ok, ""))
        srv.notify("initialized")

        r = srv.request("thread/start", {"cwd": cwd})
        tid = r.get("result", {}).get("thread", {}).get("id")
        checks.append(("thread_start_ok", bool(tid), ""))

        srv.drain(0.5)  # flush startup notifications
        marker = "C2C_T001_INJECT_MARKER"
        item = {"type": "message", "role": "user",
                "content": [{"type": "input_text", "text": marker}]}
        r = srv.request(INJECT_METHOD, {"threadId": tid, "items": [item]})
        inject_accepted = "result" in r and r.get("result") == {}
        checks.append(("inject_accepted_empty_result", inject_accepted, json.dumps(r)[:120]))

        post = srv.drain(2.0)
        turn_started = any(n.get("method") == "turn/started" for n in post)
        checks.append(("no_turn_started_after_inject", not turn_started,
                       "methods=" + json.dumps([n.get("method") for n in post])))

        # Positive confirmation: the thread is still idle after inject (not just
        # "we didn't see turn/started"). Guards against a slow/absent notification.
        rr = srv.request("thread/read", {"threadId": tid})
        status_after = rr.get("result", {}).get("thread", {}).get("status", {}).get("type")
        idle_after = status_after == "idle"
        checks.append(("thread_idle_after_inject", idle_after, f"status={status_after}"))

        # Inertness (bus-never-RPC): an injected item whose text is a fake approval
        # verdict is accepted as DATA and — when the c2c binary is available —
        # cannot make `c2c await-reply` succeed nor write a verdict file.
        inert = _inertness_check(srv, cwd, checks)

        result["stdio"] = {
            "ok": all(ok for _, ok, _ in checks),
            "inject_accepted": inject_accepted,
            "turn_started_after_inject": turn_started,
            "thread_idle_after_inject": idle_after,
            "inertness": inert,
            "checks": [{"name": n, "pass": ok, "detail": d} for n, ok, d in checks],
        }
        return result["stdio"]["ok"]
    finally:
        srv.close()
        shutil.rmtree(cwd, ignore_errors=True)


# --------------------------------------------------------------------------- #
# boundary mode (opt-in; needs websockets)
# --------------------------------------------------------------------------- #
def run_boundary_checks(result):
    try:
        import asyncio
        import hashlib
        import secrets
        import socket
        import websockets  # noqa: F401
    except Exception as e:
        result["boundary"] = {"ok": False, "skipped": True, "reason": f"no websockets: {e}"}
        return True  # not a hard failure — boundary mode is opt-in

    import asyncio, hashlib, secrets, signal, socket, websockets

    def free_port():
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        p = s.getsockname()[1]
        s.close()
        return p

    def start(port, auth_sha=None):
        cmd = [CODEX, "app-server", "--listen", f"ws://127.0.0.1:{port}"]
        if auth_sha:
            cmd += ["--ws-auth", "capability-token", "--ws-token-sha256", auth_sha]
        p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        for _ in range(60):
            with socket.socket() as s:
                if s.connect_ex(("127.0.0.1", port)) == 0:
                    return p, True
            time.sleep(0.25)
        return p, False  # never bound

    async def try_connect(port, token=None, do_active=False):
        """Connect (optionally with bearer token), initialize, and — when
        do_active — exercise an active/privileged method (harmless arbitrary
        fs read of /etc/hostname) to prove reachability of active controls.
        Captures the HTTP status on a rejected handshake."""
        hdrs = {"Authorization": f"Bearer {token}"} if token else {}
        try:
            ws = await websockets.connect(f"ws://127.0.0.1:{port}",
                                          additional_headers=hdrs, open_timeout=6)
        except Exception as e:
            status = None
            resp = getattr(e, "response", None)
            if resp is not None:
                status = getattr(resp, "status_code", None)
            return {"connected": False, "http_status": status,
                    "reason": type(e).__name__ + ":" + str(e)[:80]}
        _id = 0
        async def rpc(method, params=None):
            nonlocal _id
            _id += 1
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": _id,
                                      "method": method, "params": params or {}}))
            end = asyncio.get_event_loop().time() + 6
            while asyncio.get_event_loop().time() < end:
                m = json.loads(await asyncio.wait_for(ws.recv(), 6))
                if m.get("id") == _id and ("result" in m or "error" in m):
                    return m
            return {"error": "timeout"}
        try:
            r = await rpc("initialize", {"clientInfo": {"name": "probe", "version": "0"},
                                         "capabilities": {"experimentalApi": True}})
            ok = "result" in r
            out = {"connected": True, "initialize_ok": ok}
            if do_active and ok:
                # arbitrary file read via an ACTIVE (fs) method — no auth presented
                rr = await rpc("fs/readFile", {"path": "/etc/hostname"})
                out["active_fs_read_accepted"] = "result" in rr and "dataBase64" in rr.get("result", {})
            return out
        finally:
            await ws.close()

    def stop(procs):
        for p, _bound in procs:
            for killer in (lambda: os.killpg(os.getpgid(p.pid), signal.SIGTERM),
                           p.terminate,
                           lambda: os.killpg(os.getpgid(p.pid), signal.SIGKILL),
                           p.kill):
                try:
                    killer()
                    p.wait(timeout=4)
                    break
                except Exception:
                    continue

    checks = []
    procs = []
    try:
        # 1) bare listener: unauthenticated client gets full access, INCLUDING an
        #    active fs method — proving no same-UID boundary (not just handshake).
        p1, bound1 = start(free_port_1 := free_port())
        procs.append((p1, bound1))
        checks.append(("bare_listener_bound", bound1, f"port={free_port_1}"))
        bare = asyncio.run(try_connect(free_port_1, do_active=True)) if bound1 else {"connected": False}
        bare_open = bool(bare.get("connected") and bare.get("initialize_ok"))
        bare_active = bool(bare.get("active_fs_read_accepted"))
        checks.append(("bare_listener_grants_unauthenticated_access", bare_open, json.dumps(bare)))
        checks.append(("bare_listener_grants_unauthenticated_active_fs_read", bare_active, json.dumps(bare)))

        # 2) authed listener: unauthenticated -> HTTP 401; correct token -> access.
        token = "t001_" + secrets.token_hex(8)
        sha = hashlib.sha256(token.encode()).hexdigest()
        p2, bound2 = start(free_port_2 := free_port(), auth_sha=sha)
        procs.append((p2, bound2))
        checks.append(("authed_listener_bound", bound2, f"port={free_port_2}"))
        no_tok = asyncio.run(try_connect(free_port_2)) if bound2 else {}
        with_tok = asyncio.run(try_connect(free_port_2, token=token)) if bound2 else {}
        wrong_tok = asyncio.run(try_connect(free_port_2, token="wrong")) if bound2 else {}
        # Explicit 401 (not merely "some exception"): distinguishes auth-reject
        # from connection-refused / server-never-bound.
        unauth_401 = (no_tok.get("http_status") == 401 and wrong_tok.get("http_status") == 401)
        auth_accepted = bool(with_tok.get("connected") and with_tok.get("initialize_ok"))
        checks.append(("authed_listener_rejects_unauthenticated_with_401", unauth_401,
                       f"no_token={no_tok}; wrong_token={wrong_tok}"))
        checks.append(("authed_listener_accepts_correct_token", auth_accepted, json.dumps(with_tok)))

        result["boundary"] = {
            "ok": all(ok for _, ok, _ in checks),
            "checks": [{"name": n, "pass": ok, "detail": d} for n, ok, d in checks],
            "note": ("Bare loopback/unix listener = NO same-UID boundary: an "
                     "unauthenticated same-UID client reached an active fs method. "
                     "--ws-auth capability-token enforces a bearer-token boundary "
                     "even on loopback (HTTP 401 at the WebSocket handshake)."),
        }
        return result["boundary"]["ok"]
    finally:
        stop(procs)


# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--boundary", action="store_true",
                    help="also run the loopback ws auth boundary check (needs websockets)")
    ap.add_argument("--no-stdio", action="store_true", help="skip the stdio inject check")
    ap.add_argument("--json-only", action="store_true", help="suppress human log lines on stderr")
    args = ap.parse_args()

    if shutil.which(CODEX) is None and not os.path.exists(CODEX):
        print(json.dumps({"ok": False, "error": f"codex binary not found: {CODEX}"}))
        return 2

    ver = subprocess.run([CODEX, "--version"], capture_output=True, text=True).stdout.strip()
    result = {"codex_version": ver, "codex_bin": shutil.which(CODEX) or CODEX}

    oks = [run_schema_checks(result)]
    if not args.no_stdio:
        oks.append(run_stdio_checks(result))
    if args.boundary:
        oks.append(run_boundary_checks(result))

    result["ok"] = all(oks)
    print(json.dumps(result, indent=2))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
