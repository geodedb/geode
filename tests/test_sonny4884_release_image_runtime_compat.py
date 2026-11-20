#!/usr/bin/env python3
"""SONNY-4884: release images must be able to start the release binary.

The GPU release image (Dockerfile.release.gpu) was based on
nvidia/cuda:13.4.2-runtime-ubuntu22.04, which ships glibc 2.35. The
x86_64-linux-gnu ReleaseSafe release binary references GLIBC_2.36, so the
dynamic loader rejected it before main ("GLIBC_2.36 not found") and the
published GPU image could not start at all. Nothing in the image build ever
executed the binary, so the incompatibility shipped.

These checks are hermetic (no docker daemon, no network). They drive the real
generator (tools/release_dockerfile_manifest.py) against the real manifest
(release/dockerfile_manifest.json) and the real generated Dockerfiles:

  1. every glibc release base meets the release binary's recorded glibc
     requirement, and the guard rejects the old Ubuntu 22.04 GPU base;
  2. an apt base whose glibc is unknown fails closed;
  3. bases that went through the 64-bit time_t rename install libssl3t64;
  4. every release Dockerfile executes the copied binary (`geode --version`)
     as the non-root runtime user, so a loader incompatibility fails the
     image build instead of publication.
"""

from __future__ import annotations

import copy
import importlib.util
import json
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOL_PATH = REPO_ROOT / "tools" / "release_dockerfile_manifest.py"
MANIFEST_PATH = REPO_ROOT / "release" / "dockerfile_manifest.json"

IN_IMAGE_GEODE_PATH = "/usr/local/bin/geode"
OLD_GPU_BASE = "nvidia/cuda:13.4.2-runtime-ubuntu22.04"
GPU_DOCKERFILE = "Dockerfile.release.gpu"


def _load_tool():
    spec = importlib.util.spec_from_file_location("release_dockerfile_manifest", TOOL_PATH)
    assert spec is not None and spec.loader is not None, f"cannot load {TOOL_PATH}"
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _load_manifest() -> dict:
    return _load_tool().load_manifest(MANIFEST_PATH)


def _compat_errors(manifest: dict) -> list[str]:
    tool = _load_tool()
    check = getattr(tool, "runtime_compat_errors", None)
    assert check is not None, (
        "tools/release_dockerfile_manifest.py has no runtime_compat_errors(): nothing "
        "checks a release base image's glibc against the release binary's requirement"
    )
    return check(manifest)


def _version_tuple(text: str) -> tuple[int, ...]:
    return tuple(int(part) for part in text.split("."))


def _instructions(content: str) -> list[tuple[str, str]]:
    """Return (INSTRUCTION, args) for each Dockerfile instruction, continuations joined."""
    joined = re.sub(r"\\[ \t]*\n", " ", content)
    out: list[tuple[str, str]] = []
    for line in joined.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        keyword, _, args = stripped.partition(" ")
        out.append((keyword.upper(), args.strip()))
    return out


def _final_stage(instructions: list[tuple[str, str]]) -> list[tuple[str, str]]:
    start = max(i for i, (kw, _) in enumerate(instructions) if kw == "FROM")
    return instructions[start:]


def _is_version_smoke(args: str) -> bool:
    if args.startswith("["):
        try:
            argv = json.loads(args)
        except json.JSONDecodeError:
            return False
        return argv == [IN_IMAGE_GEODE_PATH, "--version"]
    return re.fullmatch(rf"{re.escape(IN_IMAGE_GEODE_PATH)}\s+--version", args) is not None


def test_glibc_release_bases_meet_release_binary_requirement() -> None:
    manifest = _load_manifest()
    errors = _compat_errors(manifest)
    assert not errors, "release image runtime compatibility failures:\n" + "\n".join(f"  - {e}" for e in errors)

    tool = _load_tool()
    required = _version_tuple(manifest["release_binary"]["glibc_required"])
    gpu = next(s for s in manifest["dockerfiles"] if s["path"] == GPU_DOCKERFILE)
    profile = tool.base_image_profile(gpu["base_image"])
    assert profile is not None, f"{GPU_DOCKERFILE} base {gpu['base_image']!r} has no known glibc"
    assert profile["glibc"] >= required, (
        f"{GPU_DOCKERFILE} base {gpu['base_image']} ships glibc "
        f"{'.'.join(map(str, profile['glibc']))} < release binary requirement {'.'.join(map(str, required))}"
    )


def test_compat_guard_rejects_ubuntu2204_gpu_base() -> None:
    """The exact SONNY-4884 configuration must be refused, not silently accepted."""
    manifest = copy.deepcopy(_load_manifest())
    gpu = next(s for s in manifest["dockerfiles"] if s["path"] == GPU_DOCKERFILE)
    gpu["base_image"] = OLD_GPU_BASE
    gpu["runtime_packages"] = ["ca-certificates", "libssl3", "libvulkan1"]

    errors = _compat_errors(manifest)
    glibc_errors = [e for e in errors if GPU_DOCKERFILE in e and "2.35" in e]
    assert glibc_errors, f"Ubuntu 22.04 (glibc 2.35) GPU base was not rejected; errors={errors!r}"


def test_compat_guard_fails_closed_on_unknown_glibc_base() -> None:
    manifest = copy.deepcopy(_load_manifest())
    gpu = next(s for s in manifest["dockerfiles"] if s["path"] == GPU_DOCKERFILE)
    gpu["base_image"] = "example.invalid/some-distro:1.0"

    errors = _compat_errors(manifest)
    assert any(GPU_DOCKERFILE in e and "unknown" in e.lower() for e in errors), (
        f"an apt base with no known glibc version must fail closed; errors={errors!r}"
    )


def test_time64_bases_install_libssl3t64() -> None:
    """Ubuntu 24.04 renamed libssl3 -> libssl3t64; the package list must follow."""
    manifest = _load_manifest()
    gpu = next(s for s in manifest["dockerfiles"] if s["path"] == GPU_DOCKERFILE)
    assert "libssl3t64" in gpu["runtime_packages"], (
        f"{GPU_DOCKERFILE} must install libssl3t64 on an Ubuntu 24.04 base; got {gpu['runtime_packages']!r}"
    )

    wrong = copy.deepcopy(manifest)
    wrong_gpu = next(s for s in wrong["dockerfiles"] if s["path"] == GPU_DOCKERFILE)
    wrong_gpu["runtime_packages"] = ["libssl3" if p == "libssl3t64" else p for p in wrong_gpu["runtime_packages"]]
    errors = _compat_errors(wrong)
    assert any(GPU_DOCKERFILE in e and "libssl3t64" in e for e in errors), (
        f"installing pre-rename libssl3 on a time64 base must be rejected; errors={errors!r}"
    )


def test_every_release_dockerfile_executes_binary_as_non_root_user() -> None:
    manifest = _load_manifest()
    failures: list[str] = []
    for spec in manifest["dockerfiles"]:
        path = REPO_ROOT / spec["path"]
        stage = _final_stage(_instructions(path.read_text(encoding="utf-8")))

        copy_idx = next(
            (i for i, (kw, args) in enumerate(stage) if kw == "COPY" and args.split()[-1:] == [IN_IMAGE_GEODE_PATH]),
            None,
        )
        smoke_idx = next((i for i, (kw, args) in enumerate(stage) if kw == "RUN" and _is_version_smoke(args)), None)
        if copy_idx is None:
            failures.append(f"{spec['path']}: final stage never copies the binary to {IN_IMAGE_GEODE_PATH}")
            continue
        if smoke_idx is None:
            failures.append(f"{spec['path']}: build never executes `{IN_IMAGE_GEODE_PATH} --version`")
            continue
        if smoke_idx < copy_idx:
            failures.append(f"{spec['path']}: `--version` smoke runs before the binary is copied")
            continue
        users = [args for kw, args in stage[:smoke_idx] if kw == "USER"]
        if not users or users[-1].split(":")[0] in {"root", "0"}:
            failures.append(f"{spec['path']}: `--version` smoke does not run as the non-root runtime user")

    assert not failures, "release images can ship a binary the runtime loader cannot start:\n" + "\n".join(
        f"  - {f}" for f in failures
    )


if __name__ == "__main__":
    tests = [
        test_glibc_release_bases_meet_release_binary_requirement,
        test_compat_guard_rejects_ubuntu2204_gpu_base,
        test_compat_guard_fails_closed_on_unknown_glibc_base,
        test_time64_bases_install_libssl3t64,
        test_every_release_dockerfile_executes_binary_as_non_root_user,
    ]
    passed = 0
    failed = 0
    for test in tests:
        try:
            test()
            print(f"  PASS: {test.__name__}")
            passed += 1
        except (AssertionError, KeyError) as e:
            print(f"  FAIL: {test.__name__}: {type(e).__name__}: {e}")
            failed += 1
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
