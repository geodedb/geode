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

import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from unittest import SkipTest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent

HEALTH_CHECK_SCRIPT = REPO_ROOT / "docker" / "health-check.sh"

# The health probe hardcodes the in-image CLI path; tests substitute a stub
# binary at this exact path so the script's own argv construction is exercised
# verbatim (only the callee is swapped, never the logic under test).
IN_IMAGE_GEODE_PATH = "/usr/local/bin/geode"

# Any CLI flag that src/cli/insecure_tls_gate.zig refuses at argv-parse time in
# a release build (exit 1) unless GEODE_ALLOW_INSECURE_TLS is set.
GATED_TLS_FLAG_RE = re.compile(r"--insecure(?:-tls-skip-verify)?(?![\w-])")

INSECURE_ACK_ENV = "GEODE_ALLOW_INSECURE_TLS"

# A password that satisfies the server's own policy (src/security/
# geode_auth_lib.zig:339-368 requires >= 3 words), which is precisely why a
# valid password is GUARANTEED to word-split through an unquoted expansion.
POLICY_VALID_PASSPHRASE = "correct horse battery staple"


def _skip(reason: str):
    try:
        import pytest  # noqa: PLC0415
    except ImportError:
        raise SkipTest(reason) from None
    pytest.skip(reason)


def _write_argv_recording_stub(bin_path: pathlib.Path, log_path: pathlib.Path) -> None:
    """Install a stub `geode` that appends its argv (as JSON) to log_path."""
    bin_path.parent.mkdir(parents=True, exist_ok=True)
    bin_path.write_text(
        f"#!{sys.executable}\n"
        "import json, sys\n"
        f"with open({str(log_path)!r}, 'a', encoding='utf-8') as fh:\n"
        "    fh.write(json.dumps(sys.argv[1:]) + '\\n')\n",
        encoding="utf-8",
    )
    bin_path.chmod(bin_path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


def _run_health_check(env_overrides: dict[str, str]) -> tuple[int, list[list[str]]]:
    """Execute docker/health-check.sh with a stub CLI and capture its argv.

    Returns (exit_code, [argv_of_each_geode_invocation]). The ONLY modification
    made to the script is rewriting the absolute in-image CLI path to the stub —
    the argument construction under test is untouched. If the script no longer
    invokes the CLI at all (e.g. it was moved onto the unauthenticated HTTP
    liveness endpoint), the invocation list comes back empty.
    """
    content = HEALTH_CHECK_SCRIPT.read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = pathlib.Path(tmp)
        stub = tmpdir / "bin" / "geode"
        log = tmpdir / "argv.jsonl"
        _write_argv_recording_stub(stub, log)

        script = tmpdir / "health-check.sh"
        script.write_text(content.replace(IN_IMAGE_GEODE_PATH, str(stub)), encoding="utf-8")

        env = dict(os.environ)
        env.pop("GEODE_USERNAME", None)
        env.pop("GEODE_PASSWORD", None)
        env["PATH"] = f"{stub.parent}{os.pathsep}{env.get('PATH', '')}"
        env.update(env_overrides)

        proc = subprocess.run(
            ["/bin/sh", str(script)],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        invocations: list[list[str]] = []
        if log.exists():
            invocations = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines() if line.strip()]
        return proc.returncode, invocations


def _iter_dockerfiles_with_healthcheck():
    """Yield (relative_path, content) for every repo Dockerfile with a HEALTHCHECK."""
    for dockerfile in sorted(REPO_ROOT.rglob("Dockerfile*")):
        rel = dockerfile.relative_to(REPO_ROOT)
        rel_str = str(rel)
        # Skip build caches, vendored trees, and sibling worktrees / hidden dirs
        # (a .worktrees/ checkout is a different branch, not this image set).
        if any(part.startswith(".") for part in rel.parts[:-1]):
            continue
        if any(skip in rel_str for skip in ["zig-out", "vendor", "zig-pkg"]):
            continue
        content = dockerfile.read_text(encoding="utf-8")
        if re.search(r"^\s*HEALTHCHECK\s", content, re.MULTILINE):
            yield rel_str, content


def _healthcheck_command(content: str) -> str:
    """Return the (line-continuation joined) HEALTHCHECK instruction text."""
    joined = re.sub(r"\\\s*\n\s*", " ", content)
    match = re.search(r"^\s*HEALTHCHECK\s+(.*)$", joined, re.MULTILINE)
    return match.group(1) if match else ""


def _sets_insecure_ack(content: str) -> bool:
    """True when the image bakes in a truthy GEODE_ALLOW_INSECURE_TLS."""
    joined = re.sub(r"\\\s*\n\s*", " ", content)
    for match in re.finditer(rf"^\s*ENV\s+.*?\b{INSECURE_ACK_ENV}\s*[= ]\s*(\S+)", joined, re.MULTILINE):
        value = match.group(1).strip("\"'")
        if value.lower() in {"1", "true", "yes", "on"}:
            return True
    return False


# Dockerfiles that run a Geode server and MUST use the shared health check
SERVER_DOCKERFILES = [
    "Dockerfile",
    "Dockerfile.base",
    "Dockerfile.ci",
    "Dockerfile.ci.alpine",
    "Dockerfile.ci.gpu",
    "Dockerfile.prebuilt",
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
    # Bug 731 (#1a): this assertion previously REQUIRED `--insecure`, pinning the
    # defect in place. `--insecure` / `--insecure-tls-skip-verify` is refused at
    # argv-parse time (exit 1) by the SEC-CLI-01 gate
    # (src/cli/insecure_tls_gate.zig:35-47) in any non-Debug build — which is
    # what the published images are (.goreleaser.yaml ReleaseSafe ->
    # Dockerfile.release -> geodedb/geode:latest). The probe therefore dies
    # before it ever opens a socket. The contract is the inverse: the shared
    # script may only pass that flag if it also supplies the acknowledgement the
    # gate demands.
    if GATED_TLS_FLAG_RE.search(content):
        assert re.search(rf"^\s*(export\s+)?{INSECURE_ACK_ENV}\s*=", content, re.MULTILINE), (
            "docker/health-check.sh passes a TLS flag the release CLI refuses "
            f"(SEC-CLI-01) without setting {INSECURE_ACK_ENV}; the probe exits 1 "
            "before connecting. Drop the flag (e.g. probe the unauthenticated "
            "GET /health liveness endpoint) or set the acknowledgement."
        )


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


# ---------------------------------------------------------------------------
# Bug 731 (#1): the shipped HEALTHCHECK is broken by default.
#
#   1a  docker/health-check.sh passes `--insecure`, which the release CLI
#       refuses at argv-parse time (SEC-CLI-01) unless GEODE_ALLOW_INSECURE_TLS
#       is set — no Dockerfile or compose file in this repo sets it.
#   1b  the script builds `AUTH_ARGS="$AUTH_ARGS -P $GEODE_PASSWORD"` and
#       expands it UNQUOTED, so a policy-valid (>= 3 word) passphrase is
#       word-split across several argv slots. The CLI binds the first word as
#       the password and silently no-ops the residual positional words.
#   1c  every failed/credential-less probe increments the per-source-IP auth
#       rate limiter (quic_connection_handler.zig:5774/:5787). A probe that can
#       never authenticate never calls recordSuccess, so the limiter oscillates
#       locked -> refill -> locked forever.
# ---------------------------------------------------------------------------


def test_health_check_passes_multiword_password_as_single_argv_regression() -> None:
    """Bug 731 #1b regression: a multi-word passphrase must reach the CLI intact.

    Executes the real script with a stub CLI that records its argv. Currently
    `-P correct horse battery staple` arrives as FIVE argv elements.
    """
    _, invocations = _run_health_check(
        {
            "GEODE_USERNAME": "geode",
            "GEODE_PASSWORD": POLICY_VALID_PASSPHRASE,
        }
    )

    words = POLICY_VALID_PASSPHRASE.split()
    problems: list[str] = []
    for argv in invocations:
        # No argv element may be a bare fragment of the passphrase.
        for idx, arg in enumerate(argv):
            if arg in words and arg != POLICY_VALID_PASSPHRASE:
                problems.append(f"argv[{idx}]={arg!r} is a word-split fragment of the passphrase; full argv={argv!r}")
        # When the password IS forwarded, it must be exactly one element.
        for idx, arg in enumerate(argv):
            if arg in ("-P", "--password"):
                if idx + 1 >= len(argv):
                    problems.append(f"{arg} passed with no value; full argv={argv!r}")
                elif argv[idx + 1] != POLICY_VALID_PASSPHRASE:
                    problems.append(
                        f"{arg} value is {argv[idx + 1]!r}, expected the full "
                        f"passphrase {POLICY_VALID_PASSPHRASE!r}; full argv={argv!r}"
                    )

    assert not problems, "docker/health-check.sh word-splits the password:\n" + "\n".join(f"  - {p}" for p in problems)


def test_health_check_without_credentials_makes_no_authenticated_attempt() -> None:
    """Bug 731 #1c: a credential-less probe must not burn auth-limiter budget.

    With no GEODE_USERNAME/GEODE_PASSWORD (the default for every compose file
    and `docker run` in this repo), the script currently runs
    `geode query "RETURN 1 AS health"` with no credentials. The server counts
    that as a failed authentication on every tick, and because the probe can
    never succeed it never calls recordSuccess — so the per-IP limiter
    re-trips forever.
    """
    _, invocations = _run_health_check({})

    offenders = [
        argv
        for argv in invocations
        if argv and argv[0] == "query" and not ({"-U", "--user", "--username", "-P", "--password"} & set(argv))
    ]
    assert not offenders, (
        "docker/health-check.sh runs the authenticated query path with no credentials:\n"
        + "\n".join(f"  - {argv!r}" for argv in offenders)
        + "\nEvery tick is recorded as a failed auth attempt. Probe the "
        "unauthenticated GET /health liveness endpoint instead."
    )


def test_healthcheck_images_do_not_depend_on_a_refused_cli_flag() -> None:
    """Bug 731 #1a: no image's HEALTHCHECK may hinge on a flag the release CLI refuses.

    For every Dockerfile with a HEALTHCHECK, resolve the effective probe command
    (following the shared script) and require that either it passes no gated TLS
    flag, or the image bakes in a truthy GEODE_ALLOW_INSECURE_TLS.
    """
    shared_script = HEALTH_CHECK_SCRIPT.read_text(encoding="utf-8")
    shared_uses_gated_flag = bool(GATED_TLS_FLAG_RE.search(shared_script))
    shared_self_acks = bool(re.search(rf"^\s*(export\s+)?{INSECURE_ACK_ENV}\s*=", shared_script, re.MULTILINE))

    failures: list[str] = []
    checked = 0
    for rel_str, content in _iter_dockerfiles_with_healthcheck():
        command = _healthcheck_command(content)
        if not command:
            continue
        checked += 1

        uses_gated_flag = bool(GATED_TLS_FLAG_RE.search(command))
        if "health-check.sh" in command and shared_uses_gated_flag and not shared_self_acks:
            uses_gated_flag = True

        if uses_gated_flag and not _sets_insecure_ack(content):
            failures.append(rel_str)

    assert checked > 0, "no Dockerfile with a HEALTHCHECK found — test is not exercising anything"
    assert not failures, (
        "HEALTHCHECK depends on a CLI flag the release binary refuses "
        f"(SEC-CLI-01, exit 1) and the image does not set {INSECURE_ACK_ENV}:\n"
        + "\n".join(f"  - {f}" for f in failures)
    )


def test_health_check_script_is_shellcheck_clean_without_sc2086_suppression() -> None:
    """The `# shellcheck disable=SC2086` at line 32 is what hides bug 731 #1b.

    (.pre-commit-config.yaml also runs shellcheck at --severity=error, which
    filters SC2086 regardless — so the hook is green today either way.)
    """
    shellcheck = shutil.which("shellcheck")
    if shellcheck is None:
        _skip("shellcheck not installed")

    lines = HEALTH_CHECK_SCRIPT.read_text(encoding="utf-8").splitlines(keepends=True)
    stripped = [ln for ln in lines if not re.match(r"^\s*#\s*shellcheck\s+disable=.*SC2086", ln)]

    with tempfile.TemporaryDirectory() as tmp:
        candidate = pathlib.Path(tmp) / "health-check.sh"
        candidate.write_text("".join(stripped), encoding="utf-8")
        proc = subprocess.run(
            [shellcheck, "--shell=sh", str(candidate)],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )

    assert proc.returncode == 0, (
        "docker/health-check.sh is only shellcheck-clean because of a "
        "disable=SC2086 suppression:\n" + proc.stdout + proc.stderr
    )


if __name__ == "__main__":
    # Simple runner for quick validation without pytest
    tests = [
        test_shared_health_check_script_exists,
        test_server_dockerfiles_use_shared_health_check,
        test_no_orphan_inline_health_checks,
        test_dockerfile_base_exists,
        test_release_manifest_check_passes,
        test_health_check_passes_multiword_password_as_single_argv_regression,
        test_health_check_without_credentials_makes_no_authenticated_attempt,
        test_healthcheck_images_do_not_depend_on_a_refused_cli_flag,
        test_health_check_script_is_shellcheck_clean_without_sc2086_suppression,
    ]
    passed = 0
    failed = 0
    skipped = 0
    for test in tests:
        try:
            test()
            print(f"  PASS: {test.__name__}")
            passed += 1
        except AssertionError as e:
            print(f"  FAIL: {test.__name__}: {e}")
            failed += 1
        except BaseException as e:  # noqa: BLE001 - SkipTest / pytest.skip.Exception
            if type(e).__name__ in ("SkipTest", "Skipped"):
                print(f"  SKIP: {test.__name__}: {e}")
                skipped += 1
            else:
                raise
    print(f"\n{passed} passed, {failed} failed, {skipped} skipped")
    sys.exit(1 if failed else 0)
