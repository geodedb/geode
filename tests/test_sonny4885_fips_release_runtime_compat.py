#!/usr/bin/env python3
"""SONNY-4885: the FIPS release image must load the OpenSSL provider it ships.

Dockerfile.release.fips copies the OpenSSL FIPS provider tree (/usr/local/ssl)
from registry.gitlab.com/devnw/ci-catalog/zig-fips:0.16.0. That image builds
OpenSSL 3.6.2 on ubuntu:24.04, and the shipped libcrypto references
GLIBC_2.38 (`__isoc23_strtol`). The runtime stage was debian:bookworm-slim
(glibc 2.36), so the dynamic loader rejected the provider tree ("GLIBC_2.38
not found") and the published FIPS image could not do any cryptography. The
same bytes load on debian:trixie-slim as UID 10000 with the base and FIPS
providers active.

The SONNY-4884 compatibility guard only covered manifest-generated images, and
the `geode --version` smoke step never loads the FIPS provider, so nothing
caught this. These checks are hermetic (no docker daemon, no network). They
drive the real guard in tools/release_dockerfile_manifest.py against the real
manifest and the real Dockerfile.release.fips:

  1. the manifest records the FIPS runtime's glibc requirement (2.38) and the
     provider tree it ships;
  2. the FIPS runtime base ships at least that glibc, and installs the OpenSSL
     3 package under the name its distro uses (libssl3t64 on trixie);
  3. the image build runs the shipped `openssl list -providers` as the
     non-root runtime user and fails unless base and fips are active;
  4. the guard refuses the old bookworm runtime, the pre-rename package name,
     an unknown base, a missing provider-load step, and a root-run step.
"""

from __future__ import annotations

import importlib.util
import pathlib
import re
import sys
import tempfile

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOL_PATH = REPO_ROOT / "tools" / "release_dockerfile_manifest.py"
MANIFEST_PATH = REPO_ROOT / "release" / "dockerfile_manifest.json"

FIPS_DOCKERFILE = "Dockerfile.release.fips"
PROVIDER_TREE = "/usr/local/ssl"
PROVIDER_OPENSSL = f"{PROVIDER_TREE}/bin/openssl"
# Measured on the zig-fips:0.16.0 provider (OpenSSL 3.6.2 libcrypto,
# sha256 d24306277e07fb85fd771254f5762f819803517c24e18a0808447f6e98b9a5e8).
FIPS_PROVIDER_GLIBC = (2, 38)
BOOKWORM_BASE = "debian:bookworm-slim"


def _load_tool():
    spec = importlib.util.spec_from_file_location("release_dockerfile_manifest", TOOL_PATH)
    assert spec is not None and spec.loader is not None, f"cannot load {TOOL_PATH}"
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _manifest() -> dict:
    return _load_tool().load_manifest(MANIFEST_PATH)


def _fips_spec(manifest: dict) -> dict:
    return next(s for s in manifest["dockerfiles"] if s["path"] == FIPS_DOCKERFILE)


def _fips_text() -> str:
    return (REPO_ROOT / FIPS_DOCKERFILE).read_text(encoding="utf-8")


def _manual_errors(manifest: dict, repo_root: pathlib.Path) -> list[str]:
    check = getattr(_load_tool(), "manual_runtime_compat_errors", None)
    assert check is not None, (
        "tools/release_dockerfile_manifest.py has no manual_runtime_compat_errors(): nothing "
        "checks the manual FIPS Dockerfile's runtime base against the provider it ships"
    )
    return check(manifest, repo_root)


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


def _final_base(content: str) -> str:
    _, args = _final_stage(_instructions(content))[0]
    image = [tok for tok in args.split() if not tok.startswith("--")][0]
    return image


def _with_final_base(content: str, base: str) -> str:
    lines = content.splitlines(keepends=True)
    idx = max(i for i, line in enumerate(lines) if line.lstrip().upper().startswith("FROM "))
    lines[idx] = f"FROM {base}\n"
    return "".join(lines)


def _errors_for_variant(content: str) -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        (root / FIPS_DOCKERFILE).write_text(content, encoding="utf-8")
        return _manual_errors(_manifest(), root)


def test_manifest_records_fips_runtime_requirements() -> None:
    spec = _fips_spec(_manifest())
    required = spec.get("glibc_required")
    assert isinstance(required, str) and re.fullmatch(r"\d+\.\d+", required), (
        f"{FIPS_DOCKERFILE} manifest entry must record glibc_required for the shipped "
        f"OpenSSL provider; got {required!r}"
    )
    assert tuple(int(p) for p in required.split(".")) >= FIPS_PROVIDER_GLIBC, (
        f"{FIPS_DOCKERFILE} glibc_required {required} is below the shipped provider's GLIBC_2.38"
    )
    assert spec.get("openssl_provider_tree") == PROVIDER_TREE, (
        f"{FIPS_DOCKERFILE} manifest entry must name the provider tree it ships "
        f"(openssl_provider_tree={PROVIDER_TREE!r}); got {spec.get('openssl_provider_tree')!r}"
    )


def test_fips_runtime_base_loads_shipped_provider() -> None:
    tool = _load_tool()
    base = _final_base(_fips_text())
    profile = tool.base_image_profile(base)
    assert profile is not None, f"{FIPS_DOCKERFILE} runtime base {base!r} has no known glibc"
    assert profile["glibc"] >= FIPS_PROVIDER_GLIBC, (
        f"{FIPS_DOCKERFILE} runtime base {base} ships glibc {'.'.join(map(str, profile['glibc']))}, "
        f"but the shipped OpenSSL provider requires GLIBC_{'.'.join(map(str, FIPS_PROVIDER_GLIBC))}"
    )

    stage = _final_stage(_instructions(_fips_text()))
    installed = {
        pkg for kw, args in stage if kw == "RUN" for pkg in re.findall(r"(?<![\w.-])libssl3(?:t64)?(?![\w.-])", args)
    }
    assert installed == {profile["libssl"]}, (
        f"{FIPS_DOCKERFILE} on {base} must install {profile['libssl']}; installs {sorted(installed)!r}"
    )


def test_fips_image_build_loads_provider_as_runtime_user() -> None:
    stage = _final_stage(_instructions(_fips_text()))
    copy_idx = next(
        (i for i, (kw, args) in enumerate(stage) if kw == "COPY" and args.split()[-1:] == [PROVIDER_TREE]),
        None,
    )
    assert copy_idx is not None, f"{FIPS_DOCKERFILE}: final stage never copies the provider tree to {PROVIDER_TREE}"

    probe_idx = next(
        (i for i, (kw, args) in enumerate(stage) if kw == "RUN" and f"{PROVIDER_OPENSSL} list -providers" in args),
        None,
    )
    assert probe_idx is not None, (
        f"{FIPS_DOCKERFILE}: image build never runs `{PROVIDER_OPENSSL} list -providers`, so a "
        "glibc/provider ABI mismatch ships instead of failing the build"
    )
    probe = stage[probe_idx][1]
    assert "status: active" in probe and re.search(r"\bfips\b", probe) and re.search(r"\bbase\b", probe), (
        f"{FIPS_DOCKERFILE}: provider-load step must fail unless the fips and base providers are active; got {probe!r}"
    )
    assert probe_idx > copy_idx, f"{FIPS_DOCKERFILE}: provider-load step runs before the provider tree is copied"
    users = [args for kw, args in stage[:probe_idx] if kw == "USER"]
    assert users and users[-1].split(":")[0] not in {"root", "0"}, (
        f"{FIPS_DOCKERFILE}: provider-load step must run as the non-root runtime user"
    )


def test_guard_accepts_current_manual_dockerfiles() -> None:
    errors = _manual_errors(_manifest(), REPO_ROOT)
    assert not errors, "manual release image runtime failures:\n" + "\n".join(f"  - {e}" for e in errors)


def test_guard_rejects_bookworm_fips_runtime() -> None:
    """The exact SONNY-4885 configuration must be refused."""
    variant = _with_final_base(_fips_text(), BOOKWORM_BASE).replace("libssl3t64", "libssl3")
    errors = _errors_for_variant(variant)
    assert any(FIPS_DOCKERFILE in e and "2.36" in e and "2.38" in e for e in errors), (
        f"bookworm (glibc 2.36) FIPS runtime was not rejected; errors={errors!r}"
    )


def test_guard_rejects_pre_rename_openssl_package_on_trixie() -> None:
    variant = _with_final_base(_fips_text(), "debian:trixie-slim").replace("libssl3t64", "libssl3")
    errors = _errors_for_variant(variant)
    assert any(FIPS_DOCKERFILE in e and "libssl3t64" in e for e in errors), (
        f"installing pre-rename libssl3 on trixie must be rejected; errors={errors!r}"
    )


def test_guard_fails_closed_on_unknown_fips_base() -> None:
    errors = _errors_for_variant(_with_final_base(_fips_text(), "example.invalid/some-distro:1.0"))
    assert any(FIPS_DOCKERFILE in e and "unknown" in e.lower() for e in errors), (
        f"a FIPS runtime base with no known glibc must fail closed; errors={errors!r}"
    )


def test_guard_rejects_missing_provider_load_step() -> None:
    variant = _fips_text().replace(f"{PROVIDER_OPENSSL} list -providers", "true")
    errors = _errors_for_variant(variant)
    assert any(FIPS_DOCKERFILE in e and "list -providers" in e for e in errors), (
        f"a FIPS image that never loads its provider must be rejected; errors={errors!r}"
    )


def test_guard_rejects_provider_load_as_root() -> None:
    variant = re.sub(r"(?m)^USER geode$", "USER root", _fips_text())
    errors = _errors_for_variant(variant)
    assert any(FIPS_DOCKERFILE in e and "non-root" in e for e in errors), (
        f"a provider-load step run as root must be rejected; errors={errors!r}"
    )


def test_ordinary_release_images_keep_their_requirement() -> None:
    """The FIPS floor applies to the FIPS image only; the generated images keep theirs."""
    manifest = _manifest()
    assert manifest["release_binary"]["glibc_required"] == "2.36", (
        "release_binary.glibc_required must stay the ordinary release binary's measured 2.36"
    )
    generated = [s for s in manifest["dockerfiles"] if not s.get("manual")]
    assert any(s["base_image"] == BOOKWORM_BASE for s in generated), (
        "ordinary release images must stay on debian:bookworm-slim"
    )


if __name__ == "__main__":
    tests = [
        test_manifest_records_fips_runtime_requirements,
        test_fips_runtime_base_loads_shipped_provider,
        test_fips_image_build_loads_provider_as_runtime_user,
        test_guard_accepts_current_manual_dockerfiles,
        test_guard_rejects_bookworm_fips_runtime,
        test_guard_rejects_pre_rename_openssl_package_on_trixie,
        test_guard_fails_closed_on_unknown_fips_base,
        test_guard_rejects_missing_provider_load_step,
        test_guard_rejects_provider_load_as_root,
        test_ordinary_release_images_keep_their_requirement,
    ]
    passed = 0
    failed = 0
    for test in tests:
        try:
            test()
            print(f"  PASS: {test.__name__}")
            passed += 1
        except (AssertionError, KeyError, StopIteration) as e:
            print(f"  FAIL: {test.__name__}: {type(e).__name__}: {e}")
            failed += 1
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
