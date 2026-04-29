#!/usr/bin/env python3
"""
Mesh test step 5+6 helper: handles Ed25519 identity generation,
registration, and signed send using the relay's HTTP API.
"""
import subprocess
import sys
import json
import time
import os

# Hardcoded for now — these come from mesh-test.sh env
PORT_A = os.environ.get("PORT_A", "18080")
PORT_B = os.environ.get("PORT_B", "18081")
TOKEN = os.environ.get("TOKEN", "mesh-test-token")
RELAY_A = f"http://localhost:{PORT_A}"
RELAY_B = f"http://localhost:{PORT_B}"

def run(cmd):
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.stdout.strip()

def curl_post(url, json_data, extra_headers=None):
    headers = ["Authorization: Bearer " + TOKEN, "Content-Type: application/json"]
    if extra_headers:
        headers.extend(extra_headers)
    header_args = []
    for h in headers:
        header_args.extend(["-H", h])
    body_file = "/tmp/mesh_curl_body.json"
    with open(body_file, "w") as f:
        f.write(json_data)
    # Use -d instead of --data-binary to avoid issues
    cmd = ["curl", "-s", "-X", "POST", url] + header_args + ["-d", f"@{body_file}"]
    print(f"DEBUG curl cmd: {' '.join(cmd)}", file=sys.stderr)
    return run(cmd)

def sign_ed25519_genkeypair():
    return json.loads(run(["python3", "/home/xertrov/src/c2c/.worktrees/relay-mesh-validation/scripts/sign_ed25519.py", "gen-keypair"]))

def sign_ed25519_register(priv_seed_b64, alias, relay_url, ts, nonce):
    result = run(["python3", "/home/xertrov/src/c2c/.worktrees/relay-mesh-validation/scripts/sign_ed25519.py",
                   "sign-register", priv_seed_b64, alias, relay_url, ts, nonce])
    return json.loads(result)

def sign_ed25519_request(priv_seed_b64, alias, method, path, query, body_file, ts, nonce):
    return run(["python3", "/home/xertrov/src/c2c/.worktrees/relay-mesh-validation/scripts/sign_ed25519.py",
                "sign-request", priv_seed_b64, alias, method, path, query, body_file, ts, nonce])

def sign_ed25519_now_rfc3339():
    return run(["python3", "/home/xertrov/src/c2c/.worktrees/relay-mesh-validation/scripts/sign_ed25519.py", "now-rfc3339"])

def sign_ed25519_now_ts():
    return run(["python3", "/home/xertrov/src/c2c/.worktrees/relay-mesh-validation/scripts/sign_ed25519.py", "now-ts"])

def main():
    # Generate alice's Ed25519 keypair
    keys = sign_ed25519_genkeypair()
    priv = keys["priv_seed_b64"]
    pub = keys["pub_b64"]

    # Save priv key for step 6
    with open("/tmp/alice_priv.key", "w") as f:
        f.write(priv)

    # Sign the register blob
    ts = sign_ed25519_now_rfc3339()
    nonce = f"alice-nonce-{int(time.time())}"
    reg = sign_ed25519_register(priv, "alice", RELAY_A, ts, nonce)
    sig = reg["sig_b64"]

    # Build registration payload
    reg_body = {
        "node_id": "node-alice",
        "session_id": "sess-alice",
        "alias": "alice",
        "identity_pk": pub,
        "timestamp": ts,
        "nonce": nonce,
        "signature": sig
    }

    # Register alice
    print(f"=== alice register (signed) ===")
    result = curl_post(f"{RELAY_A}/register", json.dumps(reg_body))
    print(result)

    if '"ok"' not in result:
        print("!!! alice registration FAILED")
        sys.exit(1)

    # Register bob (no Ed25519)
    bob_body = {"node_id": "node-bob", "session_id": "sess-bob", "alias": "bob"}
    print(f"=== bob register ===")
    result = curl_post(f"{RELAY_B}/register", json.dumps(bob_body))
    print(result)

    if '"ok"' not in result:
        print("!!! bob registration FAILED")
        sys.exit(1)

    # Step 6: alice sends signed request to bob@relay-b
    send_body = {
        "from_alias": "alice",
        "to_alias": "bob@relay-b",
        "content": "hello from alice via mesh",
        "message_id": "mesh-test-001"
    }
    with open("/tmp/mesh_send_body.json", "w") as f:
        json.dump(send_body, f)

    req_ts = sign_ed25519_now_ts()
    req_nonce = f"alice-req-{int(time.time())}"
    auth_header = sign_ed25519_request(priv, "alice", "POST", "/send", "", "/tmp/mesh_send_body.json", req_ts, req_nonce)

    print(f"=== alice send (signed) ===")
    result = curl_post(f"{RELAY_A}/send", json.dumps(send_body), [f"Authorization: {auth_header}"])
    print(result)

if __name__ == "__main__":
    main()
