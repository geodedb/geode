#!/usr/bin/env python3
"""Verify that Geode server Dockerfiles use the shared health-check script.

Issue #549: Health check logic was duplicated across 13+ Dockerfiles.
This test ensures all server-role Dockerfiles reference docker/health-check.sh
instead of inlining the HEALTHCHECK CMD.

Excluded Dockerfiles (not server-role or special cases):
  - Dockerfile.dev         (development environment, no server)
  - Dockerfile.gpu         (benchmark runner, no health check needed)
  - docker-integration/Dockerfile.client-*  (client containers)
  - docker-integration/Dockerfile.geodetestlab  (test runner)
  - tests/ha/Dockerfile.runner  (test runner, not a server)
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent

# Dockerfiles that run a Geode server and MUST use the shared health check
SERVER_DOCKERFILES = [
    "Dockerfile",
    "Dockerfile.base",
    "Dockerfile.ci",
    "Dockerfile.ci.alpine",
    "Dockerfile.ci.gpu",
    "Dockerfile.prebuilt",
    "Dockerfile.prod",
    "Dockerfile.reliable",
    "Dockerfile.simple",
    "Dockerfile.release",
    "Dockerfile.release.alpine",
    "Dockerfile.release.gpu",
    "docker-integration/Dockerfile.server",
]

# Pattern for the OLD inline health check (should NOT appear in server Dockerfiles)
INLINE_HEALTHCHECK_RE = re.compile(r'CMD\s+/usr/local/bin/geode\s+query\s+"RETURN 1 AS health"')

# Pattern for the NEW shared health check script reference
SHARED_HEALTHCHECK_RE = re.compile(r"health-check\.sh")


def test_shared_health_check_script_exists() -> None:
    script = REPO_ROOT / "docker" / "health-check.sh"
    assert script.exists(), f"Shared health check script not found: {script}"
    content = script.read_text(encoding="utf-8")
    assert "GEODE_HEALTH_PORT" in content, "Script must support GEODE_HEALTH_PORT env var"
    assert "GEODE_USERNAME" in content, "Script must support GEODE_USERNAME env var"
    assert "GEODE_PASSWORD" in content, "Script must support GEODE_PASSWORD env var"
    assert "--insecure" in content, "Script must use --insecure for localhost health checks"


def test_server_dockerfiles_use_shared_health_check() -> None:
    failures: list[str] = []
    for rel_path in SERVER_DOCKERFILES:
        dockerfile = REPO_ROOT / rel_path
        if not dockerfile.exists():
            failures.append(f"MISSING: {rel_path}")
            continue
        content = dockerfile.read_text(encoding="utf-8")

        # Must reference the shared script
        if not SHARED_HEALTHCHECK_RE.search(content):
            failures.append(f"MISSING shared script ref: {rel_path}")

        # Must NOT have the old inline health check
        if INLINE_HEALTHCHECK_RE.search(content):
            failures.append(f"STILL HAS inline health check: {rel_path}")

    assert not failures, "Dockerfile health check consolidation failures:\n" + "\n".join(f"  - {f}" for f in failures)


def test_no_orphan_inline_health_checks() -> None:
    """Ensure no other Dockerfiles in the repo still have the inline health check."""
    failures: list[str] = []
    for dockerfile in sorted(REPO_ROOT.rglob("Dockerfile*")):
        # Skip non-server files that legitimately don't use health checks
        rel = dockerfile.relative_to(REPO_ROOT)
        rel_str = str(rel)
        if any(
            skip in rel_str
            for skip in [
                "Dockerfile.dev",
                "Dockerfile.gpu",
                "Dockerfile.client-",
                "Dockerfile.geodetestlab",
                "Dockerfile.runner",
                ".zig-cache",
                "zig-out",
                "vendor",
            ]
        ):
            continue
        content = dockerfile.read_text(encoding="utf-8")
        if INLINE_HEALTHCHECK_RE.search(content):
            failures.append(str(rel))

    assert not failures, "Dockerfiles still using inline health check:\n" + "\n".join(f"  - {f}" for f in failures)


def test_dockerfile_base_exists() -> None:
    base = REPO_ROOT / "Dockerfile.base"
    assert base.exists(), "Dockerfile.base not found"
    content = base.read_text(encoding="utf-8")
    assert "health-check.sh" in content, "Dockerfile.base must use shared health check script"
    assert "debian:bookworm-slim" in content, "Dockerfile.base must use debian:bookworm-slim"
    assert "useradd" in content or "adduser" in content, "Dockerfile.base must create geode user"


def test_release_manifest_check_passes() -> None:
    """Verify the release Dockerfile manifest is in sync after our changes."""
    import subprocess

    result = subprocess.run(
        [
            sys.executable,
            str(REPO_ROOT / "tools" / "release_dockerfile_manifest.py"),
            "check",
            "--manifest",
            str(REPO_ROOT / "release" / "dockerfile_manifest.json"),
            "--repo-root",
            str(REPO_ROOT),
        ],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"Release manifest check failed:\nstdout: {result.stdout}\nstderr: {result.stderr}"


if __name__ == "__main__":
    # Simple runner for quick validation without pytest
    tests = [
        test_shared_health_check_script_exists,
        test_server_dockerfiles_use_shared_health_check,
        test_no_orphan_inline_health_checks,
        test_dockerfile_base_exists,
        test_release_manifest_check_passes,
    ]
    passed = 0
    failed = 0
    for test in tests:
        try:
            test()
            print(f"  PASS: {test.__name__}")
            passed += 1
        except AssertionError as e:
            print(f"  FAIL: {test.__name__}: {e}")
            failed += 1
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
