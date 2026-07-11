#!/usr/bin/env python3
"""T003 passive-ingress dogfood — drives the REAL C2c_codex_ingress adapter
against a live, authenticated `codex app-server` and proves the injected c2c
message becomes model-visible, plus that a same-message_id retry produces no
second injection (one model-visible item).

Split of responsibilities (deliberate):
  * The ADAPTER under test (OCaml dev_codex_ingress_dogfood.exe → real_client)
    ONLY performs thread/inject_items over the T002-style authenticated seam.
  * THIS harness owns the app-server lifecycle + thread creation + the
    verification turn (turn/start). turn/start is a harness action, NEVER the
    adapter's — the adapter has no turn surface at all.

Sanitized: never prints the raw bearer token (only that a token was minted).
Self-cleaning: kills the app-server process group on exit.
"""
import asyncio, hashlib, json, os, secrets, signal, socket, subprocess, sys, tempfile, time
import websockets

CODEX = os.environ.get("CODEX_BIN", "codex")
MODEL = os.environ.get("C2C_DOGFOOD_MODEL", "gpt-5.3-codex-spark")
DRIVER = os.environ.get(
    "INGRESS_DRIVER",
    "_build/default/ocaml/test/dev_codex_ingress_dogfood.exe")
SESSION = "dogfoodsess"


def log(*a):
    print(*a, flush=True)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def seed_inbox(broker_root, marker_a, marker_b):
    """Write two messages into the canonical broker inbox (source of truth).
    Msg A has NO message_id (legacy → adapter must assign+persist one, exercising
    persist-first). Msg B carries a fixed message_id."""
    path = os.path.join(broker_root, f"{SESSION}.inbox.json")
    msgs = [
        {"from_alias": "peer-a", "to_alias": SESSION,
         "content": f"first message {marker_a}", "ts": 1000.0,
         "deferrable": False, "ephemeral": False,
         "reply_via": None, "enc_status": None, "message_id": None},
        {"from_alias": "peer-b", "to_alias": SESSION,
         "content": f"second message {marker_b}", "ts": 1001.0,
         "deferrable": False, "ephemeral": False,
         "reply_via": None, "enc_status": None, "message_id": "dog-b-fixed"},
    ]
    with open(path, "w") as f:
        json.dump(msgs, f)
    return path


async def rpc(ws, _id, method, params):
    await ws.send(json.dumps({"id": _id, "method": method, "params": params or {}}))
    end = asyncio.get_event_loop().time() + 30
    notes = []
    while asyncio.get_event_loop().time() < end:
        m = json.loads(await asyncio.wait_for(ws.recv(), 30))
        if m.get("id") == _id and ("result" in m or "error" in m):
            return m, notes
        notes.append(m)
    return {"error": "timeout"}, notes


async def collect_until(ws, want_method, timeout=90):
    """Drain notifications, collecting agentMessage text, until want_method."""
    end = asyncio.get_event_loop().time() + timeout
    text = []
    while asyncio.get_event_loop().time() < end:
        m = json.loads(await asyncio.wait_for(ws.recv(), timeout))
        meth = m.get("method")
        p = m.get("params") or {}
        if meth in ("item/completed", "item/agentMessage/delta"):
            it = p.get("item") or p
            t = it.get("text") or p.get("delta") or ""
            if t:
                text.append(t)
        if meth == want_method:
            break
    return "".join(text)


async def run():
    port = free_port()
    token = secrets.token_hex(32)
    sha = hashlib.sha256(token.encode()).hexdigest()
    broker_root = tempfile.mkdtemp(prefix="c2c-ingress-dogfood-")
    cwd = os.getcwd()
    marker_a = "C2C_DOG_A_" + secrets.token_hex(4).upper()
    marker_b = "C2C_DOG_B_" + secrets.token_hex(4).upper()

    log(f"[dogfood] codex={CODEX} model={MODEL} endpoint=ws://127.0.0.1:{port}")
    log(f"[dogfood] capability token minted (sha256={sha[:12]}… REDACTED); broker_root={broker_root}")

    # 1. start authed app-server (T002 flags), pin the model, session leader for pgroup cleanup
    argv = [CODEX, "app-server", "--listen", f"ws://127.0.0.1:{port}",
            "--ws-auth", "capability-token", "--ws-token-sha256", sha,
            "-c", f'model="{MODEL}"']
    proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True)
    before_ct = subprocess.run(["pgrep", "-cf", "codex app-server"],
                               capture_output=True, text=True).stdout.strip()
    log(f"[dogfood] app-server pid={proc.pid} (app-server procs now: {before_ct})")
    ok = False
    try:
        for _ in range(80):
            with socket.socket() as s:
                if s.connect_ex(("127.0.0.1", port)) == 0:
                    ok = True
                    break
            time.sleep(0.25)
        if not ok:
            log("[dogfood] FAIL: app-server never bound")
            return 3

        hdrs = {"Authorization": f"Bearer {token}"}
        async with websockets.connect(f"ws://127.0.0.1:{port}",
                                      additional_headers=hdrs, open_timeout=10) as ws:
            r, _ = await rpc(ws, 1, "initialize",
                             {"clientInfo": {"name": "dogfood", "version": "0"},
                              "capabilities": {"experimentalApi": True}})
            assert "result" in r, f"initialize failed: {r}"
            r, _ = await rpc(ws, 2, "thread/start",
                             {"cwd": cwd, "model": MODEL,
                              "approvalPolicy": "never", "sandbox": "read-only"})
            assert "result" in r, f"thread/start failed: {r}"
            thread_id = r["result"]["thread"]["id"]
            log(f"[dogfood] thread started: {thread_id}")

            # 2. seed the broker inbox BEFORE injection (persist-first source of truth)
            inbox_path = seed_inbox(broker_root, marker_a, marker_b)
            log("[dogfood] BEFORE injection — broker inbox pending state:")
            log("          " + json.dumps(json.load(open(inbox_path))))

            # 3. run the REAL adapter: 2 delivery passes (pass 2 = same-message_id retry)
            env = dict(os.environ)
            env.update({
                "C2C_MCP_BROKER_ROOT": broker_root,
                "C2C_CODEX_INGRESS_SESSION": SESSION,
                "C2C_CODEX_INGRESS_ENDPOINT": f"ws://127.0.0.1:{port}",
                "C2C_CODEX_INGRESS_THREAD": thread_id,
                "C2C_CODEX_INGRESS_TOKEN": token,
                "C2C_CODEX_INGRESS_LIVE": "1",
            })
            log("[dogfood] running REAL adapter (dev_codex_ingress_dogfood.exe, 2 passes)…")
            res = subprocess.run([DRIVER, "2"], env=env, capture_output=True, text=True)
            log("[dogfood] adapter stdout:")
            for line in res.stdout.splitlines():
                log("          " + line)
            if res.returncode != 0:
                log("[dogfood] adapter stderr:\n" + res.stderr)
                return 4

            # 4. verification turn (HARNESS action, not the adapter): ask the model
            #    to echo any C2C_DOG_* tokens it can see in its history.
            prompt = ("Some data items were appended to your conversation history. "
                      "Reply with EXACTLY each distinct token of the form C2C_DOG_* "
                      "that you can see, one per line, and nothing else.")
            await ws.send(json.dumps({"id": 3, "method": "turn/start",
                                      "params": {"threadId": thread_id,
                                                 "model": MODEL,
                                                 "approvalPolicy": "never",
                                                 "input": [{"type": "text", "text": prompt}]}}))
            answer = await collect_until(ws, "turn/completed", timeout=120)
            log("[dogfood] AFTER injection — model turn output (model-visible evidence):")
            log("          " + repr(answer.strip()[:400]))
            saw_a = marker_a in answer
            saw_b = marker_b in answer
            log(f"[dogfood] marker A ({marker_a}) model-visible: {saw_a}")
            log(f"[dogfood] marker B ({marker_b}) model-visible: {saw_b}")
            verdict = saw_a and saw_b
            log(f"[dogfood] VERDICT: {'PASS' if verdict else 'FAIL'} "
                f"(both injected c2c messages observed model-visible: {verdict})")
            return 0 if verdict else 5
    finally:
        # cleanup: kill the app-server process group
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            proc.wait(timeout=5)
        except Exception:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except Exception:
                pass
        after_ct = subprocess.run(["pgrep", "-cf", "codex app-server"],
                                  capture_output=True, text=True).stdout.strip()
        log(f"[dogfood] cleanup done — app-server procs remaining: {after_ct}")


if __name__ == "__main__":
    sys.exit(asyncio.run(run()))
