"""Native contact CLI integration, with isolated identities and TLS relay.
Run: python3 scripts/test-contact-deliver-cli.py /absolute/path/to/c2c
"""
import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="contact-cli-", dir=os.environ["TMPDIR"]) as td:
    root = Path(td)
    env = os.environ.copy()
    for k in list(env):
        if k.startswith("C2C_"):
            del env[k]
    env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / "config"))
    def run(*args, who="sender", ok=True):
        e = dict(env, XDG_CONFIG_HOME=str(root / who), C2C_RELAY_IDENTITY_PATH=str(root / who / "c2c" / "identity.json"))
        p = subprocess.run([binary, *args], env=e, text=True, capture_output=True)
        if ok and p.returncode:
            raise AssertionError(f"command {args[0:3]} failed: {p.stderr}")
        return p
    # RED: released CLI has no deliver subcommand.
    help_result = run("relay", "contact", "deliver", "--help")
    assert "--grant-file" in help_result.stdout
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(root / "tls.key"), "-out", str(root / "tls.pem"), "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"], check=True, capture_output=True)
    env["C2C_RELAY_CA_BUNDLE"] = str(root / "tls.pem")
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    url = f"https://localhost:{port}"
    (root / "relay").mkdir()
    (root / "token").write_bytes(os.urandom(32).hex().encode())
    log = open(root / "relay.log", "w")
    server = subprocess.Popen([binary, "relay", "serve", "--listen", f"127.0.0.1:{port}", "--storage", "sqlite", "--persist-dir", str(root / "relay"), "--token-file", str(root / "token"), "--tls-cert", str(root / "tls.pem"), "--tls-key", str(root / "tls.key")], env=env, stdout=log, stderr=log)
    try:
        for _ in range(100):
            p = run("relay", "status", "--relay-url", url, ok=False)
            if p.returncode == 0:
                break
            time.sleep(.1)
        else:
            raise AssertionError("TLS relay did not become healthy")
        for who in ("sender", "recipient", "outsider"):
            run("relay", "register", "--relay-url", url, "--alias", "probe-" + who, who=who)
        def pk(who):
            # Isolated test fixtures only; never use live identities.
            return json.loads((root / who / "c2c" / "identity.json").read_text())["public_key"]
        issued = run("relay", "contact", "issue", "--persist-dir", str(root / "relay"), "--delivery-alias", "probe-recipient", "--recipient-pk", pk("recipient"), "--sender-pk", pk("sender"), "--json")
        grant = root / "grant.json"
        grant.write_text(issued.stdout)
        grant.chmod(0o600)
        args = ("relay", "contact", "deliver", "--relay-url", url, "--alias", "probe-sender", "--grant-file", str(grant), "--message-id", "probe-1", "hello-contact")
        first = json.loads(run(*args).stdout)
        assert first["ok"] is True
        duplicate = json.loads(run(*args).stdout)
        assert duplicate["duplicate"] is True
        denied = run(*tuple("probe-outsider" if x == "probe-sender" else x for x in args), who="outsider", ok=False)
        assert denied.returncode != 0 and "contact_unauthorised" in denied.stdout
        plain = run(*tuple(f"http://localhost:{port}" if x == url else x for x in args), ok=False)
        assert plain.returncode != 0 and "HTTPS" in plain.stderr
        poll = json.loads(run("relay", "dm", "poll", "--relay-url", url, "--alias", "probe-recipient", who="recipient").stdout)
        assert "hello-contact" in json.dumps(poll)
        empty = json.loads(run("relay", "dm", "poll", "--relay-url", url, "--alias", "probe-recipient", who="recipient").stdout)
        assert "hello-contact" not in json.dumps(empty)
        grant.chmod(0o644)
        insecure = run(*args, ok=False)
        assert insecure.returncode != 0 and "owner-only" in insecure.stderr
        grant.chmod(0o600)
        grant_id = json.loads(issued.stdout)["grant_id"]
        run("relay", "contact", "revoke", "--persist-dir", str(root / "relay"), "--recipient-pk", pk("recipient"), "--grant-id", grant_id)
        revoked_args = tuple("probe-2" if x == "probe-1" else x for x in args)
        revoked = run(*revoked_args, ok=False)
        assert revoked.returncode != 0 and "contact_unauthorised" in revoked.stdout
        print("PASS: TLS contact deliver, dedup, wrong sender rejected, HTTP refused, signed poll, inbox drained, insecure file rejected, revoked grant rejected")
    finally:
        server.terminate()
        server.wait(timeout=10)
        log.close()
