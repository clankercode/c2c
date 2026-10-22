#!/usr/bin/env python3
"""B369/B370 proof against an exact compiled native binary (buildboxes only).

  python3 scripts/test-contact-deliver-cli.py /absolute/path/to/c2c.exe

Requires Python 3.9+ and openssl. Runs explicit and shared-send proofs; use
--explicit-only to restrict this driver. Never builds/installs or uses public
relays/operator state. TLS uses TLS on both proxy legs, with a private CA.
Fixtures are cleaned on success, failure, SIGINT and SIGTERM. Output is a final
metadata-only JSON receipt with the tested binary SHA256. Subprocess output and
argv are suppressed on failure: they can contain grants or message bodies.
"""
import argparse
import base64
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import runpy
import signal
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time


class ProofFailure(Exception):
    """Only fixed, non-sensitive labels belong in this exception."""


def require(condition, label):
    if not condition:
        raise ProofFailure(label)


def parse_json(text, label):
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        raise ProofFailure(label) from None


def private_json(path, data):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
        json.dump(data, f)
        f.write("\n")


def binary_digest(binary):
    digest = hashlib.sha256()
    with open(binary, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def terminate(process):
    if process is None or process.poll() is not None:
        return
    # Only fixture Popen children have their own session; never touch services.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)


class Observer(ThreadingHTTPServer):
    """Loopback forwarder recording paths/IDs/verifier hashes, never raw secrets.

    TLS terminates here AND at the native backend, so native transport checks
    still see TLS. An injected 503 occurs AFTER a real successful admission.
    """
    daemon_threads = True
    block_on_close = False

    def __init__(self, fixture):
        self.fixture = fixture
        self.events = []
        self.lock = threading.Lock()
        self.lose_next_contact_response = False
        super().__init__(("127.0.0.1", 0), ObserverHandler)
        if fixture.tls:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(fixture.cert, fixture.key)
            self.socket = context.wrap_socket(self.socket, server_side=True)

    def mark(self):
        with self.lock:
            return len(self.events)

    def since(self, mark):
        with self.lock:
            return list(self.events[mark:])


class ObserverHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.forward()

    def do_POST(self):
        self.forward()

    def forward(self):
        fixture = self.server.fixture
        connection = None
        try:
            length = int(self.headers.get("Content-Length", "0"))
            require(0 <= length <= 1024 * 1024, "observer_request_size")
            payload = self.rfile.read(length)
            metadata = {"path": self.path, "method": self.command}
            if self.path == "/contact/v1/deliver":
                body = parse_json(payload, "observer_contact_json")
                secret = body.get("grant_secret", "")
                raw = base64.urlsafe_b64decode(secret + "=" * (-len(secret) % 4))
                metadata.update(grant_id=base64.urlsafe_b64encode(hashlib.sha256(raw).digest()).decode().rstrip("="),
                                message_id=body.get("message_id"))
            headers = {k: v for k, v in self.headers.items()
                       if k.lower() not in {"connection", "transfer-encoding"}}
            headers["Connection"] = "close"
            if fixture.tls:
                connection = http.client.HTTPSConnection("localhost", fixture.backend_port,
                                                         context=fixture.context, timeout=12)
            else:
                connection = http.client.HTTPConnection("127.0.0.1", fixture.backend_port, timeout=12)
            connection.request(self.command, self.path, body=payload, headers=headers)
            response = connection.getresponse()
            output = response.read()
            metadata["status"] = response.status
            lose = False
            with self.server.lock:
                if self.path == "/contact/v1/deliver" and 200 <= response.status < 300:
                    lose = self.server.lose_next_contact_response
                    self.server.lose_next_contact_response = False
                metadata["response_lost"] = lose
                self.server.events.append(metadata)
            self.send_response(503 if lose else response.status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Connection", "close")
            if lose:
                output = b'{"ok":false,"error_code":"connection_error"}'
            self.send_header("Content-Length", str(len(output)))
            self.end_headers()
            self.wfile.write(output)
        except Exception:
            with self.server.lock:
                self.server.events.append({"path": self.path, "observer_error": True})
            try:
                self.send_error(502, "fixture forwarding failed")
            except OSError:
                pass
        finally:
            self.close_connection = True
            if connection is not None:
                connection.close()


class Fixture:
    peers = ("alice", "bob", "outsider")

    def __init__(self, binary, tls=True, server_flag=None, server_env=None):
        self.binary = str(Path(binary).resolve(strict=True))
        self.tls, self.server_flag, self.server_env = tls, server_flag, server_env
        self.temporary = self.server = self.observer = self.observer_thread = None
        self.checks = []

    def __enter__(self):
        try:
            self.temporary = tempfile.TemporaryDirectory(prefix="c2c-contact-proof-")
            self.root = Path(self.temporary.name).resolve()
            self.storage = self.root / "relay-db"
            self.storage.mkdir(mode=0o700)
            self.token = os.urandom(32).hex()
            self.token_file = self.root / "relay-token"
            with os.fdopen(os.open(self.token_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
                f.write(self.token + "\n")
            self.cert, self.key = self.root / "tls.pem", self.root / "tls.key"
            self.base_env = {k: os.environ[k] for k in ("PATH", "LANG", "LC_ALL", "TZ", "SYSTEMROOT") if k in os.environ}
            self.base_env.update(TERM="dumb", NO_COLOR="1", TMPDIR=str(self.root))
            # HOME, every XDG root, identity and broker are isolated per actor.
            # No ambient C2C_*, client IDs, HTTP proxies or SSH state survive.
            for peer in (*self.peers, "server"):
                for child in ("home", "config", "state", "data", "cache", "run", "broker", "identity"):
                    (self.root / peer / child).mkdir(mode=0o700, parents=True)
            if self.tls:
                self.command(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                              "-keyout", str(self.key), "-out", str(self.cert), "-days", "1",
                              "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
                             self.env("server"), "tls_fixture_certificate")
                self.key.chmod(0o600)
                self.context = ssl.create_default_context(cafile=str(self.cert))
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                self.backend_port = sock.getsockname()[1]
            self.start_server(self.server_flag, self.server_env)
            self.observer = Observer(self)
            self.url = ("https" if self.tls else "http") + f"://localhost:{self.observer.server_port}"
            self.observer_thread = threading.Thread(target=self.observer.serve_forever, daemon=True)
            self.observer_thread.start()
            self.host_id = parse_json(self.run("host-id", "--json").stdout, "host_id_json").get("host_id", "")
            require(re.fullmatch(r"[0-9a-f]{12}", self.host_id) is not None, "opaque_host_id")
            for peer in self.peers:
                self.run("register", "--alias", self.alias(peer), "--json", who=peer)
                self.run("relay", "register", "--relay-url", self.url, "--alias", self.alias(peer),
                         "--node-id", self.node(peer), "--session-id", self.sid(peer), who=peer)
                # Valid but different default key catches ignored identity overrides.
                default = self.root / peer / "config/c2c/identity.json"
                self.run("relay", "identity", "init", "--path", str(default), who=peer)
                require(parse_json(default.read_text(), "default_identity_json")["public_key"] != self.pk(peer),
                        "distinct_identity_override_fixture")
            return self
        except BaseException:
            self.close()
            raise

    def __exit__(self, *_args):
        self.close()

    def close(self):
        try:
            if self.observer_thread is not None:
                self.observer.shutdown()
                self.observer.server_close()
                self.observer_thread.join(timeout=5)
                self.observer_thread = None
            elif self.observer is not None:
                self.observer.server_close()
        finally:
            try:
                terminate(self.server)
            finally:
                self.server = None
                if self.temporary is not None:
                    self.temporary.cleanup()
                    self.temporary = None

    @staticmethod
    def alias(who):
        return "contact-proof-" + who

    @staticmethod
    def sid(who):
        return "contact-proof-session-" + who

    @staticmethod
    def node(who):
        return "contact-proof-node-" + who

    def route(self, who):
        return self.alias(who) + "@" + self.host_id

    def env(self, who="alice", extra=None):
        base = self.root / who
        env = dict(self.base_env, HOME=str(base / "home"), XDG_CONFIG_HOME=str(base / "config"),
                   XDG_STATE_HOME=str(base / "state"), XDG_DATA_HOME=str(base / "data"),
                   XDG_CACHE_HOME=str(base / "cache"), XDG_RUNTIME_DIR=str(base / "run"),
                   C2C_STATE_HOME=str(base / "state"), C2C_MCP_BROKER_ROOT=str(base / "broker"),
                   C2C_MCP_SESSION_ID=self.sid(who), C2C_MCP_CLIENT_PID=str(os.getpid()),
                   C2C_MCP_CLIENT_TYPE="unknown", C2C_MCP_AUTO_REGISTER_ALIAS=self.alias(who),
                   C2C_MCP_AUTO_DRAIN_CHANNEL="0", C2C_RELAY_IDENTITY_PATH=str(base / "identity/key.json"),
                   C2C_RELAY_TOKEN=self.token)
        if self.tls:
            env["C2C_RELAY_CA_BUNDLE"] = str(self.cert)
        if hasattr(self, "url"):
            env["C2C_RELAY_URL"] = self.url
        if extra:
            env.update(extra)
        return env

    def pk(self, who):
        return parse_json((self.root / who / "identity/key.json").read_text(), "identity_json")["public_key"]

    def command(self, argv, env, label, ok=True, input_text=None):
        try:
            result = subprocess.run(argv, env=env, cwd=self.root, text=True, input=input_text,
                                    capture_output=True, timeout=45)
        except (OSError, subprocess.TimeoutExpired):
            raise ProofFailure(label + "_execution") from None
        if ok:
            require(result.returncode == 0, label + "_exit")
        return result

    def run(self, *args, who="alice", ok=True, extra=None, input_text=None):
        verbs = {"relay", "contact", "deliver", "import", "export", "disable", "stored", "issue",
                 "revoke", "list", "dm", "send", "peek", "poll", "connect", "register", "identity", "init",
                 "mcp", "host-id", "peek-inbox", "poll-inbox"}
        # Never interpolate arguments, command bodies or subprocess diagnostics.
        label = "cli_" + "_".join(str(x) for x in args[:3] if str(x) in verbs)
        return self.command([self.binary, *map(str, args)], self.env(who, extra), label, ok, input_text)

    def start_server(self, flag=None, env_value=None):
        terminate(self.server)
        self.server = None
        args = [self.binary, "relay", "serve", "--listen", f"127.0.0.1:{self.backend_port}",
                "--storage", "sqlite", "--persist-dir", str(self.storage),
                "--token-file", str(self.token_file), "--gc-interval", "0"]
        if self.tls:
            args.extend(["--tls-cert", str(self.cert), "--tls-key", str(self.key)])
        if flag:
            args.append(flag)
        extra = {} if env_value is None else {"C2C_RELAY_ALLOW_CONTACT_HTTP": env_value}
        self.server = subprocess.Popen(args, env=self.env("server", extra), cwd=self.root,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            require(self.server.poll() is None, "native_relay_startup")
            connection = None
            try:
                connection = (http.client.HTTPSConnection("localhost", self.backend_port, context=self.context, timeout=.5)
                              if self.tls else http.client.HTTPConnection("127.0.0.1", self.backend_port, timeout=.5))
                connection.request("GET", "/health")
                response = connection.getresponse()
                response.read()
                if response.status == 200:
                    return
            except (OSError, http.client.HTTPException):
                pass
            finally:
                if connection:
                    connection.close()
            time.sleep(.1)
        raise ProofFailure("native_relay_health_deadline")

    def issue(self, sender="alice", recipient="bob", lifetime=3600, rotate_grant_id=None):
        data = parse_json(self.run("relay", "contact", "issue", "--persist-dir", self.storage,
                                  "--relay-url", self.url, "--recipient-route", self.route(recipient),
                                  "--delivery-alias", self.alias(recipient), "--recipient-pk", self.pk(recipient),
                                  "--sender-pk", self.pk(sender), "--expires-in", str(lifetime), "--json",
                                  *(["--rotate-grant-id", rotate_grant_id] if rotate_grant_id else [])).stdout,
                          "issued_artifact_json")
        expected = dict(artifact_version=1, protocol="c2c-contact/1", scope="dm-first-contact",
                        relay_url=self.url, recipient_route=self.route(recipient), delivery_alias=self.alias(recipient),
                        recipient_pk=self.pk(recipient), sender_pk=self.pk(sender))
        require(all(data.get(k) == v for k, v in expected.items()), "enriched_artifact_bindings")
        require(isinstance(data.get("expires_at"), (int, float)) and data["expires_at"] > time.time(), "artifact_expiry")
        require(isinstance(data.get("generation"), int) and data["generation"] > 0, "artifact_generation")
        require(all(isinstance(data.get(k), str) and len(data[k]) == 43 for k in ("grant_secret", "grant_id")),
                "artifact_grant_shape")
        path = self.root / ("grant-" + os.urandom(8).hex() + ".json")
        private_json(path, data)
        return path, data

    def import_grant(self, path, who="alice", recipient="bob", flags=(), extra=None, ok=True, url=None, route=None):
        return self.run("relay", "contact", "import", "--relay-url", url or self.url,
                        "--to", route or self.route(recipient), "--grant-file", path, *flags,
                        who=who, extra=extra, ok=ok)

    def deliver(self, path, message_id, body, who="alice", flags=(), extra=None, ok=True):
        return self.run("relay", "contact", "deliver", "--relay-url", self.url, "--alias", self.alias(who),
                        "--grant-file", path, "--message-id", message_id, *flags, body, who=who, extra=extra, ok=ok)

    def direct(self, message_id, body, who="alice", recipient="bob", extra=None, ok=True):
        return self.run("relay", "dm", "send", "--relay-url", self.url, "--alias", self.alias(who),
                        "--message-id", message_id, self.route(recipient), body, who=who, extra=extra, ok=ok)

    def poll(self, who="bob"):
        data = parse_json(self.run("relay", "dm", "poll", "--relay-url", self.url, "--alias", self.alias(who),
                                   "--node-id", self.node(who), "--session-id", self.sid(who), who=who).stdout,
                          "relay_inbox_json")
        require(data.get("ok") is True and isinstance(data.get("messages"), list), "relay_inbox_shape")
        return data["messages"]

    def accepted(self, result, label="contact_accepted", duplicate=None):
        data = parse_json(result.stdout, label + "_json")
        require(result.returncode == 0 and data.get("ok") is True, label)
        if duplicate is not None:
            require((data.get("duplicate") is True) == duplicate, label + "_duplicate")
        return data

    def denied(self, result, label, contains=None):
        require(result.returncode != 0, label + "_exit")
        if contains:
            require(contains.lower() in (result.stdout + result.stderr).lower(), label + "_reason")

    def assert_network(self, mark, count=None, grant_id=None, message_id=None):
        events = self.observer.since(mark)
        require(not any(e.get("observer_error") for e in events), "observer_transport_integrity")
        require(not any(e["path"].split("?")[0] == "/send" for e in events), "no_legacy_send_fallback")
        contacts = [e for e in events if e["path"] == "/contact/v1/deliver"]
        if count is not None:
            require(len(contacts) == count, "contact_request_count")
        if grant_id is not None:
            require(bool(contacts) and all(e.get("grant_id") == grant_id for e in contacts), "selected_grant_on_wire")
        if message_id is not None:
            require(bool(contacts) and all(e.get("message_id") == message_id for e in contacts), "stable_message_id_on_wire")
        return contacts

    def expect_message(self, rows, body, sender="alice", count=1):
        matches = [row for row in rows if row.get("content") == body]
        require(len(matches) == count, "recipient_message_count")
        require(all(row.get("from_alias") == self.route(sender) for row in matches), "relay_canonical_sender_route")

    def check(self, label):
        self.checks.append(("tls_" if self.tls else "http_") + label)


def explicit_tls(binary):
    with Fixture(binary) as f:
        f.run("relay", "contact", "deliver", "--help")
        path, grant = f.issue()
        mark = f.observer.mark()
        f.accepted(f.deliver(path, "explicit-1", "explicit TLS contact"), duplicate=False)
        f.accepted(f.deliver(path, "explicit-1", "explicit TLS contact"), duplicate=True)
        f.assert_network(mark, count=2, grant_id=grant["grant_id"], message_id="explicit-1")
        f.expect_message(f.poll(), "explicit TLS contact")
        f.expect_message(f.poll(), "explicit TLS contact", count=0)
        f.check("explicit_delivery_dedup_canonical_sender_and_drain")
        # Now rejected locally, rather than old draft's contact_unauthorised.
        mark = f.observer.mark()
        f.denied(f.deliver(path, "wrong-identity", "must not arrive", who="outsider", ok=False),
                 "wrong_sender_local_refusal", "contact sender mismatch")
        path.chmod(0o644)
        f.denied(f.deliver(path, "unsafe-file", "must not arrive", ok=False), "unsafe_file_refusal", "owner-only")
        path.chmod(0o600)
        f.denied(f.deliver(path, "explicit-1", "changed payload must not arrive", ok=False),
                 "id_conflict_refusal", "payload conflict")
        f.assert_network(mark, count=0)
        require(not f.poll(), "refused_messages_not_delivered")
        f.check("local_identity_permissions_and_payload_conflict_refused")
        f.run("relay", "contact", "revoke", "--persist-dir", f.storage, "--recipient-pk", f.pk("bob"),
              "--grant-id", grant["grant_id"])
        mark = f.observer.mark()
        f.denied(f.deliver(path, "revoked-1", "revoked must not arrive", ok=False),
                 "revoked_grant_refusal", "contact_unauthorised")
        f.assert_network(mark, count=1, grant_id=grant["grant_id"])
        require(not f.poll(), "revoked_message_not_delivered")
        f.check("revocation_without_legacy_fallback")
        return f.checks


def explicit_http(binary):
    with Fixture(binary, tls=False) as f:
        path, grant = f.issue()
        mark = f.observer.mark()
        f.denied(f.deliver(path, "http-default", "plaintext default denied", ok=False),
                 "client_http_default_refusal", "explicit local consent")
        f.denied(f.import_grant(path, ok=False), "import_http_default_refusal", "explicit local consent")
        f.assert_network(mark, count=0)
        f.check("client_deliver_and_import_http_denied_by_default")
        mark = f.observer.mark()
        f.denied(f.deliver(path, "http-server-default", "server default denied", flags=("--allow-http",), ok=False),
                 "server_http_default_refusal", "contact_unauthorised")
        f.assert_network(mark, count=1, grant_id=grant["grant_id"])
        require(not f.poll(), "server_default_no_delivery")
        f.check("server_http_independently_denied_by_default")
        f.start_server("--require-contact-https", "1")
        mark = f.observer.mark()
        f.denied(f.deliver(path, "http-server-strict", "strict server denied", flags=("--allow-http",), ok=False),
                 "server_strict_overrides_env", "contact_unauthorised")
        f.assert_network(mark, count=1)
        f.check("server_require_https_overrides_environment")
        f.start_server("--allow-contact-http", "0")
        mark = f.observer.mark()
        f.denied(f.deliver(path, "http-client-strict", "strict client denied", flags=("--require-https",),
                           extra={"C2C_CONTACT_ALLOW_HTTP": "1"}, ok=False),
                 "client_strict_overrides_env", "explicit local consent")
        f.denied(f.import_grant(path, flags=("--require-https",), extra={"C2C_CONTACT_ALLOW_HTTP": "1"}, ok=False),
                 "import_strict_overrides_env", "explicit local consent")
        f.assert_network(mark, count=0)
        mark = f.observer.mark()
        f.accepted(f.deliver(path, "http-explicit", "both explicitly allow HTTP", flags=("--allow-http",)))
        f.assert_network(mark, count=1, grant_id=grant["grant_id"])
        f.expect_message(f.poll(), "both explicitly allow HTTP")
        f.check("explicit_flags_and_client_require_https_precedence")
        f.start_server(None, "1")
        f.accepted(f.deliver(path, "http-env", "explicit client environment fallback",
                             extra={"C2C_CONTACT_ALLOW_HTTP": "1"}))
        f.expect_message(f.poll(), "explicit client environment fallback")
        f.check("server_and_explicit_client_environment_fallback")
        return f.checks


def main(shared_only=False):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", help="absolute path of the exact already-compiled native binary")
    if not shared_only:
        parser.add_argument("--explicit-only", action="store_true")
    args = parser.parse_args()
    require(Path(args.binary).is_absolute(), "explicit_absolute_binary_required")
    binary = str(Path(args.binary).resolve(strict=True))
    require(os.access(binary, os.X_OK), "native_binary_executable")
    digest = binary_digest(binary)
    checks = []
    if not shared_only:
        checks.extend(explicit_tls(binary))
        checks.extend(explicit_http(binary))
    if shared_only or not args.explicit_only:
        shared = runpy.run_path(str(Path(__file__).with_name("contact-shared-send-proof.py")))
        try:
            checks.extend(shared["shared_proof"](binary))
        except shared["helpers"]["ProofFailure"] as error:
            raise ProofFailure(str(error)) from None
    require(binary_digest(binary) == digest, "tested_binary_unchanged")
    print(json.dumps({"ok": True, "proof": "B369-B370-native-contact", "binary_sha256": digest,
                      "checks": checks, "check_count": len(checks), "fixtures_cleaned": True}, sort_keys=True))


def entrypoint(shared_only=False):
    def interrupted(_signum, _frame):
        raise ProofFailure("interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main(shared_only)
    except (Exception, KeyboardInterrupt) as error:
        label = str(error) if isinstance(error, ProofFailure) else "fixture_or_proof_error"
        print(json.dumps({"ok": False, "proof": "B369-B370-native-contact", "failed_check": label}), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(entrypoint())
