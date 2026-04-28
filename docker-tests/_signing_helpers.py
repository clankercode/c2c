"""
#407 S5 — signing key provisioning helpers for E2E cross-container tests.

Provides utilities to:
  - Generate per-alias Ed25519 identity inside a container
  - Read back the public key / fingerprint
  - Sign a fixture peer-PASS artifact inside a container
  - Copy the signed artifact between containers (via docker cp)
  - Verify the artifact inside a container

These helpers are used by test_peer_pass_signing_e2e.py.
The helpers run commands via `docker exec` as the testagent user (uid 1000)
so that identity and artifact paths resolve correctly inside the container.
"""
from __future__ import annotations

import json
import shlex
import subprocess
from typing import Any


C2C_CLI = "/usr/local/bin/c2c"


def _run_shell_in(container: str, script: str, timeout: int = 30) -> subprocess.CompletedProcess:
    """Run an arbitrary shell script inside a container as testagent (uid 999)."""
    env = {
        "C2C_CLI_FORCE": "1",
        "C2C_IN_DOCKER": "1",
        "HOME": "/home/testagent",
        "C2C_MCP_BROKER_ROOT": "/home/testagent/.c2c/broker",
    }
    cmd = ["docker", "exec"]
    for k, v in env.items():
        cmd += ["-e", f"{k}={v}"]
    cmd += ["-u", "999", container, "bash", "-c", script]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def _run_c2c_in(
    container: str,
    argv: list[str],
    timeout: int = 30,
    *,
    as_testagent: bool = True,
) -> subprocess.CompletedProcess:
    """Run c2c CLI inside a named container as the testagent user.

    By default runs as the testagent user (uid 1000) to ensure identity
    files go in /home/testagent/.config/c2c/ and the artifact cache in
    /home/testagent/.cache/c2c/peer-passes/ (matching the container's
    unprivileged runtime user).
    """
    env = {
        "C2C_CLI_FORCE": "1",
        "C2C_IN_DOCKER": "1",
        "HOME": "/home/testagent",
        # Use a testagent-writable broker root so write_allowed_signers_entry succeeds
        "C2C_MCP_BROKER_ROOT": "/home/testagent/.c2c/broker",
    }
    cmd = ["docker", "exec"]
    for k, v in env.items():
        cmd += ["-e", f"{k}={v}"]
    if as_testagent:
        cmd += ["-u", "999"]
    cmd += [container, C2C_CLI] + argv
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def register_on_relay(
    container: str,
    alias: str,
    relay_url: str = "http://relay:7331",
) -> subprocess.CompletedProcess:
    """Register alias on the relay for cross-broker routing.

    Runs: c2c relay register --alias <alias> --relay-url <relay_url>
    """
    return _run_c2c_in(container, [
        "relay", "register",
        "--alias", alias,
        "--relay-url", relay_url,
    ])


def ensure_testagent_dirs(container: str) -> None:
    """Create testagent-writable broker root and home directory structure."""
    subprocess.run(
        ["docker", "exec", container,
         "bash", "-c",
         "mkdir -p /home/testagent/.c2c/broker /home/testagent/.config/c2c /home/testagent/.cache/c2c/peer-passes && chown -R 999:999 /home/testagent"],
        capture_output=True, timeout=10,
    )


def init_identity(
    container: str,
    alias: str,
    relay_url: str = "http://relay:7331",
) -> subprocess.CompletedProcess:
    """Register alias locally AND on relay, creating the broker key path.

    Flow:
      1. relay identity init — creates ~/.config/c2c/identity.json with Ed25519 keypair
      2. c2c register — creates <broker_root>/keys/<alias>.ed25519 (write_allowed_signers_entry)
      3. c2c relay register — registers alias on relay for cross-broker routing

    All three are needed for peer-pass sign to work.

    Runs: c2c relay identity init
          c2c register --alias <alias> --session-id <alias>-session
          c2c relay register --alias <alias> --relay-url <relay_url>
    """
    # Ensure directories exist with correct ownership
    ensure_testagent_dirs(container)

    # Step 1: Create identity.json with Ed25519 keypair (--force if already exists)
    r0 = _run_c2c_in(container, ["relay", "identity", "init", "--force"])
    if r0.returncode != 0:
        return r0
    # Step 2: c2c register — creates broker key path at <broker_root>/keys/<alias>.ed25519
    session_id = f"{alias}-session"
    r1 = _run_c2c_in(container, ["register", "--alias", alias, "--session-id", session_id])
    if r1.returncode != 0:
        return r1
    # Step 3: relay registration — for cross-broker routing
    r2 = register_on_relay(container, alias, relay_url)
    return r2


def get_identity_show(container: str) -> dict[str, Any]:
    """Return identity metadata as a dict from `c2c relay identity show --json`."""
    r = _run_c2c_in(container, ["relay", "identity", "show", "--json"])
    assert r.returncode == 0, f"identity show failed in {container}: {r.stderr}"
    return json.loads(r.stdout)


def get_pubkey(container: str) -> str:
    """Return the base64url-encoded public key for the identity in container."""
    identity = get_identity_show(container)
    pk = identity.get("public_key") or identity.get("pubkey") or identity.get("pk")
    assert pk, f"public key not found in identity show output: {identity}"
    return pk


def get_fingerprint(container: str) -> str:
    """Return the SHA256 fingerprint of the identity in container."""
    r = _run_c2c_in(container, ["relay", "identity", "fingerprint"])
    assert r.returncode == 0, f"fingerprint failed in {container}: {r.stderr}"
    return r.stdout.strip()


def sign_peer_pass(
    container: str,
    sha: str,
    verdict: str = "PASS",
    criteria: str = "",
    skill_version: str = "s5-e2e",
    notes: str = "S5 E2E test artifact",
    allow_self: bool = False,
) -> subprocess.CompletedProcess:
    """Sign a peer-PASS artifact inside container.

    Runs: c2c peer-pass sign <sha> [--verdict PASS|FAIL]
          [--criteria ...] [--skill-version ...] [--notes ...] [--allow-self]
    """
    argv = [
        "peer-pass", "sign", sha,
        "--verdict", verdict,
        "--skill-version", skill_version,
        "--notes", notes,
    ]
    if criteria:
        argv.extend(["--criteria", criteria])
    if allow_self:
        argv.append("--allow-self")
    return _run_c2c_in(container, argv)


def verify_peer_pass(container: str, artifact_path: str) -> tuple[bool, str]:
    """Verify a peer-PASS artifact file inside container.

    Returns (True, stdout) on success, (False, stderr) on failure.
    """
    r = _run_c2c_in(container, ["peer-pass", "verify", artifact_path])
    if r.returncode == 0:
        return True, r.stdout
    return False, r.stderr


def docker_cp(
    src_container: str,
    src_path: str,
    dst_container: str,
    dst_path: str,
) -> subprocess.CompletedProcess:
    """Copy a file between two containers using `docker cp` via host filesystem.

    Docker cp cannot copy directly between containers. We copy src -> host temp
    -> dst in two steps.
    """
    import tempfile
    import os
    with tempfile.NamedTemporaryFile(delete=False, suffix=".artifact") as f:
        host_path = f.name
    try:
        # Step 1: src container -> host
        r1 = subprocess.run(
            ["docker", "cp", f"{src_container}:{src_path}", host_path],
            capture_output=True, text=True, timeout=30,
        )
        if r1.returncode != 0:
            return r1
        # Step 2: host -> dst container
        # Ensure destination directory exists
        dst_dir = os.path.dirname(dst_path)
        subprocess.run(
            ["docker", "exec", dst_container, "mkdir", "-p", dst_dir],
            capture_output=True, text=True, timeout=10,
        )
        return subprocess.run(
            ["docker", "cp", host_path, f"{dst_container}:{dst_path}"],
            capture_output=True, text=True, timeout=30,
        )
    finally:
        if os.path.exists(host_path):
            os.unlink(host_path)


def artifact_path_in_container(container: str, sha: str, alias: str) -> str:
    """Return the on-disk path for a peer-pass artifact given sha + alias.

    Matches the path computed by peer_review.ml artifact_path():
      <git_common_dir_parent>/.c2c/peer-passes/<sha>-<alias>.json

    For the E2E test: the git clone is at /tmp/s5-test-repo-clone, so the
    artifact path is /tmp/s5-test-repo-clone/.c2c/peer-passes/<sha>-<alias>.json

    The peer-pass sign command must run from within the git clone directory.
    """
    return f"/tmp/s5-test-repo-clone/.c2c/peer-passes/{sha}-{alias}.json"


def artifact_copy_across_broker(
    src_container: str,
    dst_container: str,
    sha: str,
    reviewer_alias: str,
) -> tuple[str, str]:
    """Copy a signed peer-pass artifact from src_container to dst_container.

    Both containers mount independent broker volumes (broker-a and broker-b),
    so the artifact file is transferred via docker cp (Docker host filesystem).

    Returns (dst_artifact_path, error_msg). Empty error_msg means success.
    """
    src_path = artifact_path_in_container(src_container, sha, reviewer_alias)
    dst_path = artifact_path_in_container(dst_container, sha, reviewer_alias)
    r = docker_cp(src_container, src_path, dst_container, dst_path)
    if r.returncode != 0:
        return "", f"docker cp failed: {r.stderr}"
    return dst_path, ""


def make_test_commit_in_container(
    container: str,
    repo_path: str = "/tmp/s5-test-repo",
    file_name: str = "s5-fixture.txt",
    commit_msg: str = "S5 test commit",
) -> str:
    """Create a git commit inside a container and return its SHA.

    Creates a bare repo at repo_path, clones it, makes a commit with
    the fixture file, and pushes back to the bare repo so another
    container can fetch it.

    Returns the commit SHA (hex string).
    """
    script = f"""
        set -e
        rm -rf {repo_path} {repo_path}-clone
        git init --bare {repo_path} >/dev/null 2>&1
        git clone {repo_path} {repo_path}-clone >/dev/null 2>&1
        cd {repo_path}-clone
        git config user.email "s5@c2c"
        git config user.name "S5 Test"
        echo "s5-$(date +%s)" > {file_name}
        git add {file_name}
        git commit -m "{commit_msg}" >/dev/null 2>&1
        git push {repo_path} HEAD:refs/heads/s5-test >/dev/null 2>&1 || true
        git rev-parse HEAD
        """
    r = _run_shell_in(container, script)
    assert r.returncode == 0, f"make_test_commit failed in {container}: {r.stderr}"
    sha = r.stdout.strip()
    assert sha, f"empty SHA from commit in {container}"
    return sha


def sign_artifact_in_container(
    container: str,
    sha: str,
    reviewer_alias: str,
    verdict: str = "PASS",
    criteria: str = "s5-e2e",
    notes: str = "S5 E2E test artifact",
    allow_self: bool = True,
    repo_path: str = "/tmp/s5-test-repo-clone",
) -> str:
    """Sign a peer-PASS artifact inside container and return the artifact path.

    Runs `c2c peer-pass sign` from within the git clone so that
    `git_commit_exists sha` (used by validate_signing_allowed) resolves
    the test commit. Uses --allow-self because in the test context the
    signer's alias matches the "reviewer alias" in the artifact.

    Returns the absolute artifact path inside the container.
    """
    argv = [
        "peer-pass", "sign", sha,
        "--verdict", verdict,
        "--criteria", criteria,
        "--notes", notes,
    ]
    if allow_self:
        argv.append("--allow-self")
    # Ensure .c2c/peer-passes dir exists, then run peer-pass sign from git clone
    mkdir_cmd = f"mkdir -p {repo_path}/.c2c/peer-passes"
    cmd = f"{mkdir_cmd} && cd {repo_path} && " + " ".join([C2C_CLI] + [shlex.quote(a) for a in argv])
    r = _run_shell_in(container, cmd)
    assert r.returncode == 0, f"peer-pass sign failed in {container}: {r.stderr}"

    # Verify the artifact exists at the expected path
    artifact_rel = artifact_path_in_container(container, sha, reviewer_alias)
    r2 = _run_shell_in(container, f"test -f {artifact_rel}")
    if r2.returncode != 0:
        # Fallback: glob for most recent matching file
        glob_r = _run_shell_in(container, f"ls -t /home/testagent/.cache/c2c/peer-passes/*{sha}*.json 2>/dev/null | head -1")
        artifact_rel = glob_r.stdout.strip()

    assert artifact_rel, f"no artifact found for SHA {sha} in {container}"
    return artifact_rel


def whoami(container: str) -> str:
    """Return the registered alias for this container's session."""
    r = _run_c2c_in(container, ["whoami"])
    if r.returncode == 0:
        for line in r.stdout.splitlines():
            if line.startswith("alias:"):
                return line.split("alias:")[1].strip()
    return ""
