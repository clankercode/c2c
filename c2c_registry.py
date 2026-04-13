#!/usr/bin/env python3
import contextlib
import fcntl
import json
import os
import subprocess
import tempfile
from pathlib import Path


BASE = Path(__file__).resolve().parent
DEFAULT_ALIAS_WORDS_PATH = BASE / "data" / "c2c_alias_words.txt"


def repo_common_cache_path() -> Path:
    override = os.environ.get("C2C_REPO_COMMON_CACHE", "").strip()
    if override:
        return Path(override)
    return Path(tempfile.gettempdir()) / "c2c-repo-common-cache.json"


def load_repo_common_cache() -> dict[str, str]:
    path = repo_common_cache_path()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    if not isinstance(data, dict):
        return {}
    return {str(key): str(value) for key, value in data.items()}


def save_repo_common_cache(cache: dict[str, str]) -> None:
    path = repo_common_cache_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(cache, indent=2, sort_keys=True), encoding="utf-8")


def repo_identity_key() -> str | None:
    try:
        output = subprocess.run(
            ["git", "config", "--get", "remote.origin.url"],
            cwd=BASE,
            capture_output=True,
            text=True,
            check=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None

    value = output.stdout.strip()
    return value or None


def current_repo_common_dir() -> Path:
    try:
        output = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            cwd=BASE,
            capture_output=True,
            text=True,
            check=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return BASE

    common_dir = output.stdout.strip()
    if not common_dir:
        return BASE

    resolved = Path(common_dir)
    if not resolved.is_absolute():
        resolved = (BASE / resolved).resolve()
    return resolved


def repo_common_dir() -> Path:
    resolved = current_repo_common_dir()
    identity = repo_identity_key()
    if identity is None:
        return resolved

    cache = load_repo_common_cache()
    cached = cache.get(identity, "").strip()
    if cached:
        cached_path = Path(cached)
        if cached_path.exists():
            return cached_path

    cache[identity] = str(resolved)
    save_repo_common_cache(cache)
    return resolved


def default_registry_path() -> Path:
    return repo_common_dir() / "c2c" / "registry.yaml"


def registry_path_from_env() -> Path:
    return Path(os.environ.get("C2C_REGISTRY_PATH", default_registry_path()))


def alias_words_path_from_env() -> Path:
    return Path(os.environ.get("C2C_ALIAS_WORDS_PATH", DEFAULT_ALIAS_WORDS_PATH))


def load_registry(path: Path | None = None) -> dict:
    registry_path = path or registry_path_from_env()
    if not registry_path.exists():
        return {"registrations": []}

    lines = registry_path.read_text(encoding="utf-8").splitlines()
    registrations = []
    current = None
    in_registrations = False

    for raw_line in lines:
        line = raw_line.rstrip()
        if not line:
            continue
        if line == "registrations:":
            in_registrations = True
            continue
        if not in_registrations:
            continue
        if line.startswith("  - "):
            current = {}
            registrations.append(current)
            key, value = parse_yaml_key_value(line[4:])
            current[key] = value
            continue
        if line.startswith("    ") and current is not None:
            key, value = parse_yaml_key_value(line[4:])
            current[key] = value

    return {"registrations": registrations}


def load_registry_unlocked(path: Path | None = None) -> dict:
    return load_registry(path)


def save_registry(registry: dict, path: Path | None = None) -> None:
    registry_path = path or registry_path_from_env()
    registry_path.parent.mkdir(parents=True, exist_ok=True)
    content = render_registry_yaml(registry)

    with registry_write_lock(registry_path):
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=registry_path.parent,
            prefix=f".{registry_path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
            temp_path = Path(handle.name)

        os.replace(temp_path, registry_path)


def save_registry_unlocked(registry: dict, path: Path | None = None) -> None:
    registry_path = path or registry_path_from_env()
    registry_path.parent.mkdir(parents=True, exist_ok=True)
    content = render_registry_yaml(registry)

    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=registry_path.parent,
        prefix=f".{registry_path.name}.",
        suffix=".tmp",
        delete=False,
    ) as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
        temp_path = Path(handle.name)

    os.replace(temp_path, registry_path)


def update_registry(mutator, path: Path | None = None):
    registry_path = path or registry_path_from_env()
    registry_path.parent.mkdir(parents=True, exist_ok=True)
    with registry_write_lock(registry_path):
        registry = load_registry_unlocked(registry_path)
        result = mutator(registry)
        save_registry_unlocked(registry, registry_path)
        return result


def load_alias_words(path: Path | None = None) -> list[str]:
    words_path = path or alias_words_path_from_env()
    words = []
    for line in words_path.read_text(encoding="utf-8").splitlines():
        word = line.strip().lower()
        if word:
            words.append(word)
    return words


def allocate_unique_alias(words: list[str], existing_aliases: set[str]) -> str:
    for left in words:
        for right in words:
            alias = f"{left}-{right}"
            if alias not in existing_aliases:
                return alias
    raise ValueError("no aliases available")


def build_registration_record(session_id: str, alias: str) -> dict:
    return {"session_id": session_id, "alias": alias}


def find_registration_by_session_id(registry: dict, session_id: str) -> dict | None:
    for registration in registry.get("registrations", []):
        if registration.get("session_id") == session_id:
            return registration
    return None


def find_registration_by_alias(registry: dict, alias: str) -> dict | None:
    for registration in registry.get("registrations", []):
        if registration.get("alias") == alias:
            return registration
    return None


def load_registration_for_session_id(
    session_id: str, path: Path | None = None
) -> dict | None:
    registry = load_registry(path)
    return find_registration_by_session_id(registry, session_id)


def prune_registrations(registry: dict, live_session_ids: set[str]) -> dict:
    registrations = [
        registration
        for registration in registry.get("registrations", [])
        if registration.get("session_id") in live_session_ids
    ]
    return {"registrations": registrations}


def render_registry_yaml(registry: dict) -> str:
    lines = ["registrations:"]
    for registration in registry.get("registrations", []):
        session_id = yaml_scalar(registration["session_id"])
        alias = yaml_scalar(registration["alias"])
        lines.append(f"  - session_id: {session_id}")
        lines.append(f"    alias: {alias}")
    return "\n".join(lines) + "\n"


def parse_yaml_key_value(line: str) -> tuple[str, str]:
    key, _, raw_value = line.partition(":")
    value = raw_value.strip()
    return key.strip(), parse_yaml_scalar(value)


def parse_yaml_scalar(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] == '"':
        inner = value[1:-1]
        return inner.replace('\\"', '"').replace("\\\\", "\\")
    if len(value) >= 2 and value[0] == value[-1] == "'":
        return value[1:-1]
    return value


def yaml_scalar(value: str) -> str:
    if value and all(character.isalnum() or character in "-_" for character in value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


@contextlib.contextmanager
def registry_write_lock(registry_path: Path):
    lock_path = registry_path.with_suffix(f"{registry_path.suffix}.lock")
    with open(lock_path, "w", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
