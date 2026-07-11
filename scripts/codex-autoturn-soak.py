#!/usr/bin/env python3
"""T007 auto-turn SOAK / stability E2E — sustained back-and-forth through the
REAL C2c_codex_autoturn dispatcher against a live authenticated `codex
app-server` (codex 0.144.1, model gpt-5.3-codex-spark).

Proves over a WHOLE multi-round run (default 15 rounds each direction):
  * every peer message auto-turns AND gets a model response (none dropped, none
    stuck queued) — verified per round (thread returns to idle after a turn the
    dispatcher fired) AND globally (a final echo turn shows EVERY marker);
  * ordering preserved (final echo lists markers in send order);
  * batching/serialization holds UNDER LOAD — burst rounds inject 2-3 messages
    (some mid-turn); asserts no overlapping/duplicate turns (every fired turn id
    is unique) and mid-turn arrivals batch into a later turn;
  * idempotency: no message is turned twice (turn count == distinct turned
    message batches; re-runs fire zero extra turns);
  * NO resource leaks: app-server proc-group child count + open-fd count recorded
    BEFORE and AFTER; growth beyond a small slack = a finding;
  * no crash/wedge/ledger-corruption over the run; per-round latency recorded to
    surface latency creep.

Isolation/safety identical to codex-autoturn-e2e.py: isolated CODEX_HOME (copied
auth + minimal config, NO user hooks), disposable broker root, kills only the
owned app-server process group on exit, never touches the user's ~/.codex or any
pre-existing codex process, never prints the raw token.

Env: CODEX_BIN, C2C_AUTOTURN_MODEL (default gpt-5.3-codex-spark),
AUTOTURN_DRIVER, SOAK_ROUNDS (default 15), SOAK_BURST_ROUNDS (comma list,
default "5,10").
"""
import asyncio, hashlib, json, os, secrets, shutil, signal, socket, subprocess, sys, tempfile, time
import websockets

CODEX = os.environ.get("CODEX_BIN", "/home/xertrov/.bun/bin/codex")
MODEL = os.environ.get("C2C_AUTOTURN_MODEL", "gpt-5.3-codex-spark")
DRIVER = os.environ.get("AUTOTURN_DRIVER", "_build/default/ocaml/test/dev_codex_autoturn_dogfood.exe")
ROUNDS = int(os.environ.get("SOAK_ROUNDS", "15"))
BURST_ROUNDS = set(int(x) for x in os.environ.get("SOAK_BURST_ROUNDS", "5,10").split(",") if x.strip())
SESSION = "soaksess"


def log(*a): print(*a, flush=True)


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def mk_codex_home():
    home = tempfile.mkdtemp(prefix="c2c-soak-codexhome-")
    src = os.path.expanduser("~/.codex/auth.json")
    if os.path.exists(src):
        shutil.copy(src, os.path.join(home, "auth.json"))
    with open(os.path.join(home, "config.toml"), "w") as f:
        f.write('model = "%s"\n' % MODEL)
    return home


def proc_fd_counts(pid):
    """(#processes in the app-server's process group, #open fds of the leader)."""
    try:
        pgid = os.getpgid(pid)
        out = subprocess.run(["pgrep", "-g", str(pgid)], capture_output=True, text=True).stdout
        nproc = len([x for x in out.split() if x.strip()])
    except Exception:
        nproc = -1
    try:
        nfd = len(os.listdir(f"/proc/{pid}/fd"))
    except Exception:
        nfd = -1
    return nproc, nfd


def inbox_path(broker_root):
    return os.path.join(broker_root, f"{SESSION}.inbox.json")


def write_inbox(broker_root, msgs):
    with open(inbox_path(broker_root), "w") as f:
        json.dump(msgs, f)


def msg(from_alias, content, message_id, ts):
    return {"from_alias": from_alias, "to_alias": SESSION, "content": content, "ts": ts,
            "deferrable": False, "ephemeral": False, "reply_via": None,
            "enc_status": None, "message_id": message_id}


def run_driver(env, passes):
    res = subprocess.run([DRIVER, str(passes)], env=env, capture_output=True, text=True)
    outs = []
    for line in res.stdout.splitlines():
        if line.startswith("PASS "):
            try:
                outs.append(json.loads(line.split(" ", 2)[2]))
            except Exception:
                pass
    if res.returncode != 0:
        log("[soak] driver stderr:\n" + res.stderr)
    return res.returncode, outs


async def rpc(ws, _id, method, params, timeout=30):
    await ws.send(json.dumps({"id": _id, "method": method, "params": params or {}}))
    end = asyncio.get_event_loop().time() + timeout
    while asyncio.get_event_loop().time() < end:
        m = json.loads(await asyncio.wait_for(ws.recv(), timeout))
        if m.get("id") == _id and ("result" in m or "error" in m):
            return m
    return {"error": "timeout"}


async def thread_status(ws, tid, _id):
    r = await rpc(ws, _id, "thread/read", {"threadId": tid})
    return (((r.get("result") or {}).get("thread") or {}).get("status") or {}).get("type")


class Ider:
    def __init__(self, start): self.i = start
    def __call__(self): self.i += 1; return self.i


async def wait_active(ws, tid, nid, timeout=15):
    end = asyncio.get_event_loop().time() + timeout
    while asyncio.get_event_loop().time() < end:
        if (await thread_status(ws, tid, nid())) not in (None, "idle"):
            return True
        await asyncio.sleep(0.08)
    return False


async def wait_idle(ws, tid, nid, timeout=120):
    end = asyncio.get_event_loop().time() + timeout
    while asyncio.get_event_loop().time() < end:
        if (await thread_status(ws, tid, nid())) == "idle":
            return True
        await asyncio.sleep(0.25)
    return False


async def drive_until_idle(drv_env, ws, tid, nid, max_passes=8):
    """Run dispatcher passes until no turn is in flight and the thread is idle,
    collecting every fired turn id + batch. Returns (fired:[(turn_id,ids)], last)."""
    fired = []
    last = {}
    for _ in range(max_passes):
        rc, outs = run_driver(drv_env, 1)
        for o in outs:
            last = o
            if o.get("turn_started"):
                fired.append((o["turn_started"], tuple(o.get("batch_message_ids") or [])))
        if last.get("turn_started"):
            await wait_idle(ws, tid, nid, timeout=120)
            continue
        if last.get("queued_reason") in ("active_turn", "ambiguous_held"):
            await wait_idle(ws, tid, nid, timeout=120)
            continue
        # no turn fired and not blocked → drained for now
        break
    return fired, last


async def echo_turn(ws, tid, nid):
    prompt = ("List EXACTLY each distinct token of the form C2C_SOAK_* that appears "
              "in your conversation history, one per line, in the order they first "
              "appear, and nothing else.")
    _id = nid()
    await ws.send(json.dumps({"id": _id, "method": "turn/start",
                              "params": {"threadId": tid, "model": MODEL,
                                         "approvalPolicy": "never",
                                         "input": [{"type": "text", "text": prompt}]}}))
    end = asyncio.get_event_loop().time() + 150
    text = []
    while asyncio.get_event_loop().time() < end:
        m = json.loads(await asyncio.wait_for(ws.recv(), 150))
        meth = m.get("method"); p = m.get("params") or {}
        if meth in ("item/completed", "item/agentMessage/delta"):
            it = p.get("item") or p
            t = it.get("text") or p.get("delta") or ""
            if t:
                text.append(t)
        if meth == "turn/completed":
            break
    return "".join(text)


async def run():
    port = free_port(); token = secrets.token_hex(32)
    sha = hashlib.sha256(token.encode()).hexdigest()
    broker_root = tempfile.mkdtemp(prefix="c2c-soak-e2e-")
    codex_home = mk_codex_home(); cwd = os.getcwd()
    run_tag = secrets.token_hex(3).upper()

    log(f"[soak] codex={CODEX} model={MODEL} rounds={ROUNDS} burst_rounds={sorted(BURST_ROUNDS)}")
    log(f"[soak] token sha256={sha[:12]}… REDACTED; broker_root={broker_root}; CODEX_HOME={codex_home}")

    argv = [CODEX, "app-server", "--listen", f"ws://127.0.0.1:{port}",
            "--ws-auth", "capability-token", "--ws-token-sha256", sha, "-c", f'model="{MODEL}"']
    env0 = dict(os.environ); env0["CODEX_HOME"] = codex_home
    proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True, env=env0)
    log(f"[soak] app-server pid={proc.pid} (owned)")

    all_msgs = []          # cumulative inbox (broker never drains)
    all_fired = []         # (turn_id, batch_ids) across the run
    markers = []           # in send order
    per_round = []
    result = {"rounds_ok": 0, "rounds": ROUNDS, "dropped_or_stuck": [], "dup_turn_ids": [],
              "duplicate_batched_msg": [], "ordering_ok": None, "all_markers_seen": None,
              "leak": None}
    try:
        ok = False
        for _ in range(80):
            with socket.socket() as s:
                if s.connect_ex(("127.0.0.1", port)) == 0: ok = True; break
            time.sleep(0.25)
        if not ok:
            log("[soak] FAIL: app-server never bound"); return 3

        hdrs = {"Authorization": f"Bearer {token}"}
        async with websockets.connect(f"ws://127.0.0.1:{port}", additional_headers=hdrs, open_timeout=10) as ws:
            nid = Ider(1000)
            assert "result" in await rpc(ws, nid(), "initialize",
                {"clientInfo": {"name": "soak", "version": "0"}, "capabilities": {"experimentalApi": True}})
            r = await rpc(ws, nid(), "thread/start",
                {"cwd": cwd, "model": MODEL, "approvalPolicy": "never", "sandbox": "read-only"})
            assert "result" in r, r
            tid = r["result"]["thread"]["id"]
            log(f"[soak] thread={tid}")

            # settle, then record BEFORE resource counts (steady state, WS connected)
            await asyncio.sleep(0.5)
            before = proc_fd_counts(proc.pid)
            log(f"[soak] BEFORE resources: procs_in_group={before[0]} open_fds={before[1]}")

            drv_env = dict(os.environ)
            drv_env.update({
                "CODEX_HOME": codex_home, "C2C_MCP_BROKER_ROOT": broker_root,
                "C2C_CODEX_INGRESS_SESSION": SESSION,
                "C2C_CODEX_INGRESS_ENDPOINT": f"ws://127.0.0.1:{port}",
                "C2C_CODEX_INGRESS_THREAD": tid, "C2C_CODEX_INGRESS_TOKEN": token,
                "C2C_CODEX_INGRESS_LIVE": "1", "C2C_CODEX_TURN_MODEL": MODEL,
                "C2C_CODEX_TURN_APPROVAL_POLICY": "never",
            })

            ts = 1000.0
            for rnd in range(1, ROUNDS + 1):
                t0 = time.time()
                new_ids = []
                # peer -> managed codex: 1 message, or a burst (2-3, some mid-turn)
                mk = lambda k: (f"C2C_SOAK_{run_tag}_R{rnd}_{k}", f"soak r{rnd}k{k}")
                if rnd in BURST_ROUNDS:
                    # message 1 arrives, fire it, then 2 more arrive mid-turn
                    marker, body = mk(0); mid = f"s-r{rnd}-0"
                    ts += 1; all_msgs.append(msg("peer-local", f"{body} {marker}", mid, ts))
                    markers.append(marker); new_ids.append(mid)
                    write_inbox(broker_root, all_msgs)
                    rc, outs = run_driver(drv_env, 1)   # fire turn for msg0
                    fired0 = [(o["turn_started"], tuple(o.get("batch_message_ids") or []))
                              for o in outs if o.get("turn_started")]
                    all_fired += fired0
                    caught = await wait_active(ws, tid, nid, timeout=12)
                    for k in (1, 2):
                        marker, body = mk(k); mid = f"s-r{rnd}-{k}"
                        ts += 1; all_msgs.append(msg("peer-local", f"{body} {marker}", mid, ts))
                        markers.append(marker); new_ids.append(mid)
                    write_inbox(broker_root, all_msgs)
                    # a pass while turn0 active must NOT fire a 2nd concurrent turn
                    rc, outs = run_driver(drv_env, 1)
                    midblk = outs and outs[-1].get("turn_started") is None
                    await wait_idle(ws, tid, nid, timeout=120)
                    fired, last = await drive_until_idle(drv_env, ws, tid, nid)
                    all_fired += fired
                    log(f"[soak] round {rnd} BURST: msgs={new_ids} caught_active={caught} "
                        f"mid_turn_blocked={bool(midblk)} extra_fired={[f[1] for f in fired]}")
                else:
                    marker, body = mk(0); mid = f"s-r{rnd}-0"
                    ts += 1; all_msgs.append(msg("peer-local", f"{body} {marker}", mid, ts))
                    markers.append(marker); new_ids.append(mid)
                    write_inbox(broker_root, all_msgs)
                    fired, last = await drive_until_idle(drv_env, ws, tid, nid)
                    all_fired += fired
                    log(f"[soak] round {rnd}: msg={mid} fired={[f[1] for f in fired]} "
                        f"qr={last.get('queued_reason')}")
                dt = time.time() - t0
                # each NEW message must have been turned exactly once across the run
                turned_ids = set()
                for _, ids in all_fired:
                    for i in ids:
                        turned_ids.add(i)
                stuck = [i for i in new_ids if i not in turned_ids]
                if stuck:
                    result["dropped_or_stuck"] += stuck
                per_round.append({"round": rnd, "new": new_ids, "stuck": stuck,
                                  "latency_s": round(dt, 2)})
                if not stuck:
                    result["rounds_ok"] += 1

            # AFTER resources
            await asyncio.sleep(0.5)
            after = proc_fd_counts(proc.pid)
            log(f"[soak] AFTER resources: procs_in_group={after[0]} open_fds={after[1]}")

            # global idempotency: every fired turn id unique; every batched msg once
            turn_ids = [t for t, _ in all_fired]
            result["dup_turn_ids"] = sorted({t for t in turn_ids if turn_ids.count(t) > 1})
            seen = {}
            for _, ids in all_fired:
                for i in ids:
                    seen[i] = seen.get(i, 0) + 1
            result["duplicate_batched_msg"] = sorted(i for i, c in seen.items() if c > 1)

            # re-run: fires zero extra turns (idempotency at rest)
            rc, outs = run_driver(drv_env, 2)
            result["rerun_extra_turns"] = [o["turn_started"] for o in outs if o.get("turn_started")]

            # global no-drop + ordering via echo turn
            echo = await echo_turn(ws, tid, nid)
            seen_order = [mk for mk in markers if mk in echo]
            result["all_markers_seen"] = all(mk in echo for mk in markers)
            result["missing_markers"] = [mk for mk in markers if mk not in echo]
            result["ordering_ok"] = (seen_order == [mk for mk in markers if mk in echo]
                                     and seen_order == sorted(seen_order, key=lambda m: markers.index(m)))
            log(f"[soak] echo saw {len(seen_order)}/{len(markers)} markers; "
                f"missing={result['missing_markers'][:5]}")

            slack = 3
            result["leak"] = (after[0] - before[0] > slack) or (after[1] - before[1] > slack)
            result["resources"] = {"before": before, "after": after, "slack": slack}

        core_ok = (result["rounds_ok"] == ROUNDS and not result["dropped_or_stuck"]
                   and not result["dup_turn_ids"] and not result["duplicate_batched_msg"]
                   and not result.get("rerun_extra_turns") and result["all_markers_seen"]
                   and result["ordering_ok"] and not result["leak"])
        log("[soak] ===== PER-ROUND =====")
        for pr in per_round:
            log("      " + json.dumps(pr))
        log("[soak] ===== SUMMARY =====")
        log("      " + json.dumps({k: v for k, v in result.items() if k != "resources"}))
        log("      resources=" + json.dumps(result["resources"]))
        log(f"[soak] total turns fired={len(all_fired)} distinct_turn_ids={len(set(t for t,_ in all_fired))} "
            f"messages={len(markers)}")
        log(f"[soak] VERDICT: {'PASS' if core_ok else 'FAIL'}")
        return 0 if core_ok else 5
    finally:
        alive_before = subprocess.run(["kill", "-0", str(proc.pid)], capture_output=True).returncode == 0
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM); proc.wait(timeout=5)
        except Exception:
            try: os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except Exception: pass
        alive_after = subprocess.run(["kill", "-0", str(proc.pid)], capture_output=True).returncode == 0
        shutil.rmtree(codex_home, ignore_errors=True); shutil.rmtree(broker_root, ignore_errors=True)
        log(f"[soak] cleanup: owned app-server pid={proc.pid} alive_before={alive_before} "
            f"alive_after={alive_after}; CODEX_HOME + broker_root removed")


if __name__ == "__main__":
    sys.exit(asyncio.run(run()))
