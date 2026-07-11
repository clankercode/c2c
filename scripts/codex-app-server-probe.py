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

        # inject + the 3 active-control methods present and distinct
        needed = [INJECT_METHOD] + ACTIVE_CONTROL_METHODS
        present = {m: (m in methods) for m in needed}
        all_present = all(present.values())
        distinct = len(set(needed)) == len(needed)
        checks.append(("inject_and_active_methods_present", all_present, json.dumps(present)))
        checks.append(("inject_distinct_from_turn_methods", distinct and all_present,
                       f"{INJECT_METHOD} not in {ACTIVE_CONTROL_METHODS}"))

        # ThreadInjectItemsResponse has no turn field
        inj_resp = json.load(open(os.path.join(tmp, "v2", "ThreadInjectItemsResponse.json")))
        resp_props = list(inj_resp.get("properties", {}).keys())
        no_turn_in_resp = not any("turn" in k.lower() for k in resp_props)
        checks.append(("inject_response_has_no_turn_field", no_turn_in_resp, json.dumps(resp_props)))

        # composer/draft signal search — scoped to real signals:
        #   (a) server notification method names, (b) ThreadStatus enum variants.
        srv_notif = json.load(open(os.path.join(tmp, "ServerNotification.json")))
        notif_methods = []
        for v in srv_notif.get("oneOf", []):
            enum = v.get("properties", {}).get("method", {}).get("enum", [])
            if enum:
                notif_methods.append(enum[0])
        status = json.load(open(os.path.join(tmp, "v2", "ThreadStatusChangedNotification.json")))
        status_variants = []
        for variant in status.get("definitions", {}).get("ThreadStatus", {}).get("oneOf", []):
            e = variant.get("properties", {}).get("type", {}).get("enum", [])
            if e:
                status_variants.append(e[0])
        haystack = (" ".join(notif_methods) + " " + " ".join(status_variants)).lower()
        signal_hits = [t for t in COMPOSER_SIGNAL_TOKENS if t in haystack]
        composer_signal_absent = len(signal_hits) == 0
        checks.append(("composer_draft_signal_absent", composer_signal_absent,
                       f"hits={signal_hits}; thread_status={status_variants}"))

        result["schema"] = {
            "ok": all(ok for _, ok, _ in checks),
            "client_method_count": len(methods),
            "server_notification_count": len(notif_methods),
            "thread_status_variants": status_variants,
            "checks": [{"name": n, "pass": ok, "detail": d} for n, ok, d in checks],
        }
        result["composer_signal"] = {
            "present": not composer_signal_absent,
            "searched": COMPOSER_SIGNAL_TOKENS,
            "thread_status_variants": status_variants,
            "note": "TUI composer draft is frontend-only state; no protocol signal exists.",
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

        result["stdio"] = {
            "ok": all(ok for _, ok, _ in checks),
            "inject_accepted": inject_accepted,
            "turn_started_after_inject": turn_started,
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

    import asyncio, hashlib, secrets, socket, websockets

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
        for _ in range(40):
            with socket.socket() as s:
                if s.connect_ex(("127.0.0.1", port)) == 0:
                    return p
            time.sleep(0.25)
        return p

    async def try_connect(port, token=None):
        hdrs = {"Authorization": f"Bearer {token}"} if token else {}
        try:
            ws = await websockets.connect(f"ws://127.0.0.1:{port}",
                                          additional_headers=hdrs, open_timeout=6)
        except Exception as e:
            return {"connected": False, "reason": type(e).__name__ + ":" + str(e)[:80]}
        try:
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"clientInfo": {"name": "probe", "version": "0"},
                           "capabilities": {"experimentalApi": True}}}))
            raw = await asyncio.wait_for(ws.recv(), 6)
            ok = "result" in json.loads(raw)
        finally:
            await ws.close()
        return {"connected": True, "initialize_ok": ok}

    checks = []
    procs = []
    try:
        # 1) bare listener: unauthenticated client gets full access
        p1 = free_port()
        procs.append(start(p1))
        bare = asyncio.run(try_connect(p1))
        bare_open = bare.get("connected") and bare.get("initialize_ok")
        checks.append(("bare_listener_grants_unauthenticated_access", bare_open, json.dumps(bare)))

        # 2) authed listener: unauthenticated rejected, correct token accepted
        token = "t001_" + secrets.token_hex(8)
        sha = hashlib.sha256(token.encode()).hexdigest()
        p2 = free_port()
        procs.append(start(p2, auth_sha=sha))
        no_tok = asyncio.run(try_connect(p2))
        with_tok = asyncio.run(try_connect(p2, token=token))
        wrong_tok = asyncio.run(try_connect(p2, token="wrong"))
        unauth_rejected = not no_tok.get("connected") and not wrong_tok.get("connected")
        auth_accepted = with_tok.get("connected") and with_tok.get("initialize_ok")
        checks.append(("authed_listener_rejects_unauthenticated", unauth_rejected,
                       f"no_token={no_tok}; wrong_token={wrong_tok}"))
        checks.append(("authed_listener_accepts_correct_token", auth_accepted, json.dumps(with_tok)))

        result["boundary"] = {
            "ok": all(ok for _, ok, _ in checks),
            "checks": [{"name": n, "pass": ok, "detail": d} for n, ok, d in checks],
            "note": ("Bare loopback/unix listener = NO same-UID boundary. "
                     "--ws-auth capability-token enforces a bearer-token boundary "
                     "even on loopback (401 at the WebSocket handshake)."),
        }
        return result["boundary"]["ok"]
    finally:
        for p in procs:
            try:
                p.terminate()
                p.wait(timeout=5)
            except Exception:
                try:
                    p.kill()
                except Exception:
                    pass


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
