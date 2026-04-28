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
import subprocess
from typing import Any


C2C_CLI = "/usr/local/bin/c2c"


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
    }
    cmd = ["docker", "exec"]
    if as_testagent:
        cmd += ["sudo", "-u", "testagent"]
    for k, v in env.items():
        cmd += ["-e", f"{k}={v}"]
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


def init_identity(
    container: str,
    alias: str,
    relay_url: str = "http://relay:7331",
) -> subprocess.CompletedProcess:
    """Register alias locally AND on relay, creating the broker key path.

    `c2c register` creates the per-alias signing key at
    <broker_root>/keys/<alias>.ed25519 (via write_allowed_signers_entry).
    `c2c relay register` registers the alias on the relay for cross-broker
    routing. Both are needed for peer-pass sign to work.

    Runs: c2c register --alias <alias>
          c2c relay register --alias <alias> --relay-url <relay_url>
    """
    # c2c register — creates broker key path at <broker_root>/keys/<alias>.ed25519
    r1 = _run_c2c_in(container, ["register", "--alias", alias])
    # relay registration — for cross-broker routing
    r2 = register_on_relay(container, alias, relay_url)
    # Return first failure, or success
    return r1 if r1.returncode != 0 else r2


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
    """Copy a file between two containers using `docker cp`.

    Works across independent containers (different broker volumes) because
    docker cp copies via the Docker host filesystem, not through container
    networking.
    """
    return subprocess.run(
        ["docker", "cp", f"{src_container}:{src_path}", f"{dst_container}:{dst_path}"],
        capture_output=True,
        text=True,
        timeout=30,
    )


def artifact_path_in_container(container: str, sha: str, alias: str) -> str:
    """Return the on-disk path for a peer-pass artifact given sha + alias.

    Matches the path computed by peer_review.ml artifact_path():
      ~/.cache/c2c/peer-passes/<sha>-<alias>.json

    In the E2E containers the testagent user's home is /home/testagent,
    so this resolves to:
      /home/testagent/.cache/c2c/peer-passes/<sha>-<alias>.json

    This is independent of C2C_MCP_BROKER_ROOT (/var/lib/c2c) — the
    identity keys live in ~/.config/c2c/ and the artifact cache in
    ~/.cache/c2c/ per the relay-identity layer-3 spec.
    """
    return f"/home/testagent/.cache/c2c/peer-passes/{sha}-{alias}.json"


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
    r = _run_c2c_in(container, [
        "bash", "-c",
        f"""
        set -e
        rm -rf {repo_path}
        git init --bare {repo_path}
        clone={repo_path}-clone
        rm -rf $clone
        git clone {repo_path} $clone
        cd $clone
        git config user.email "s5@c2c"
        git config user.name "S5 Test"
        echo "s5-$(date +%s)" > {file_name}
        git add {file_name}
        git commit -m "{commit_msg}"
        git push {repo_path} HEAD:refs/heads/s5-test
        git rev-parse HEAD
        """
    ])
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
    # Run from the git clone directory so git_commit_exists finds the SHA
    r = _run_c2c_in(container, [
        "bash", "-c",
        f"cd {repo_path} && " + " ".join([C2C_CLI] + argv)
    ])
    assert r.returncode == 0, f"peer-pass sign failed in {container}: {r.stderr}"

    # Verify the artifact exists at the expected path
    artifact_rel = artifact_path_in_container(container, sha, reviewer_alias)
    r2 = _run_c2c_in(container, ["test", "-f", artifact_rel])
    if r2.returncode != 0:
        # Fallback: glob for most recent matching file
        glob_r = _run_c2c_in(container, [
            "bash", "-c",
            f"ls -t /home/testagent/.cache/c2c/peer-passes/*{sha}*.json 2>/dev/null | head -1"
        ])
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
