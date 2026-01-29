"""Utility functions for geodetestlab.

This module provides helper functions for finding binaries, managing ports,
and resolving secrets.
"""

from __future__ import annotations

import os
import socket
import subprocess
from pathlib import Path

from .spec import SecretConfig, TestSpec


class SecretResolutionError(Exception):
    """Raised when a required secret cannot be resolved."""

    pass


def find_geode_binary(custom_path: str | None = None) -> str:
    """Find the Geode binary, checking common locations.

    Parameters
    ----------
    custom_path : Optional[str]
        If provided, use this path directly.

    Returns
    -------
    str
        Path to the Geode binary.

    Raises
    ------
    FileNotFoundError
        If the binary cannot be found.
    """
    if custom_path:
        path = Path(custom_path)
        if path.exists() and path.is_file():
            return str(path.resolve())
        raise FileNotFoundError(f"Specified Geode binary not found: {custom_path}")

    # Search in common locations
    search_paths = [
        # Relative to geodetestlab
        Path(__file__).parent.parent.parent.parent / "zig-out" / "bin" / "geode",
        # Relative to working directory
        Path("./zig-out/bin/geode"),
        Path("../zig-out/bin/geode"),
        Path("../../zig-out/bin/geode"),
        # System paths
        Path("/usr/local/bin/geode"),
        Path("/usr/bin/geode"),
    ]

    # Also check PATH
    path_dirs = os.environ.get("PATH", "").split(os.pathsep)
    for path_dir in path_dirs:
        search_paths.append(Path(path_dir) / "geode")

    for path in search_paths:
        if path.exists() and path.is_file():
            # Verify it's executable
            try:
                result = subprocess.run(
                    [str(path), "--version"],
                    capture_output=True,
                    timeout=5,
                )
                if result.returncode == 0 or b"geode" in result.stdout.lower() or b"geode" in result.stderr.lower():
                    return str(path.resolve())
            except (subprocess.TimeoutExpired, PermissionError, OSError):
                continue

    raise FileNotFoundError(
        "Could not find Geode binary. Tried common locations and PATH. Please specify the path using --geode-binary."
    )


def get_free_port() -> int:
    """Get a free port number.

    Returns
    -------
    int
        An available port number.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("", 0))
        s.listen(1)
        port = s.getsockname()[1]
    return port


def resolve_secrets(spec: TestSpec) -> tuple[dict[str, str], dict[str, str]]:
    """Resolve all secrets referenced in a test specification.

    Parameters
    ----------
    spec : TestSpec
        The test specification containing secret definitions.

    Returns
    -------
    Tuple[Dict[str, str], Dict[str, str]]
        A tuple of (secrets, env_vars) where secrets maps secret names to
        values and env_vars maps environment variable names to values.

    Raises
    ------
    SecretResolutionError
        If a required secret cannot be resolved.
    """
    secrets: dict[str, str] = {}
    env_vars: dict[str, str] = {}

    for name, config in spec.secrets.items():
        value = _resolve_secret(name, config)
        if value is None:
            if config.required:
                raise SecretResolutionError(f"Required secret '{name}' could not be resolved. Source: {config.source}")
        else:
            secrets[name] = value

    # Also resolve any environment variable references in spec.env
    for env_name, env_value in spec.env.items():
        if env_value.startswith("$"):
            # Reference to an environment variable
            ref_name = env_value[1:]
            resolved = os.environ.get(ref_name)
            if resolved:
                env_vars[env_name] = resolved
            elif env_value.startswith("${") and env_value.endswith("}"):
                # ${VAR:-default} syntax
                inner = env_value[2:-1]
                if ":-" in inner:
                    ref_name, default = inner.split(":-", 1)
                    env_vars[env_name] = os.environ.get(ref_name, default)
                else:
                    resolved = os.environ.get(inner)
                    if resolved:
                        env_vars[env_name] = resolved
        else:
            env_vars[env_name] = env_value

    return secrets, env_vars


def _resolve_secret(name: str, config: SecretConfig) -> str | None:
    """Resolve a single secret.

    Parameters
    ----------
    name : str
        The name of the secret.
    config : SecretConfig
        Configuration for resolving the secret.

    Returns
    -------
    Optional[str]
        The resolved secret value, or None if not found.
    """
    if config.source == "env":
        # Environment variable
        env_key = config.key or name
        return os.environ.get(env_key)

    elif config.source == "keyring":
        # System keyring (requires keyring package)
        try:
            import keyring

            service = config.service or "geodetestlab"
            key = config.key or name
            return keyring.get_password(service, key)
        except ImportError:
            return None

    elif config.source == "file":
        # Read from file
        if config.key:
            path = Path(config.key).expanduser()
            if path.exists():
                return path.read_text().strip()
        return None

    return None


def format_duration(ms: float) -> str:
    """Format a duration in milliseconds to a human-readable string.

    Parameters
    ----------
    ms : float
        Duration in milliseconds.

    Returns
    -------
    str
        Formatted duration string.
    """
    if ms < 1:
        return f"{ms * 1000:.1f}us"
    elif ms < 1000:
        return f"{ms:.1f}ms"
    elif ms < 60000:
        return f"{ms / 1000:.2f}s"
    else:
        minutes = int(ms / 60000)
        seconds = (ms % 60000) / 1000
        return f"{minutes}m{seconds:.1f}s"


def sanitize_filename(name: str) -> str:
    """Convert a string to a safe filename.

    Parameters
    ----------
    name : str
        The string to sanitize.

    Returns
    -------
    str
        A sanitized filename-safe string.
    """
    # Replace problematic characters
    replacements = {
        "/": "_",
        "\\": "_",
        ":": "_",
        "*": "_",
        "?": "_",
        '"': "_",
        "<": "_",
        ">": "_",
        "|": "_",
        " ": "_",
    }
    result = name
    for old, new in replacements.items():
        result = result.replace(old, new)
    return result
